-- Send a template to phone numbers typed in the app (no lead needed first):
-- unknown numbers become leads (source "Added manually", detail "WhatsApp quick send"), then the
-- template goes out like a small broadcast, so the replies land in Chats as usual.

create or replace function private.wa_auto_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
  v_default uuid;
  v_n int;
begin
  -- "Send to numbers" sends its own message: no welcome message on top of it
  if current_setting('app.skip_wa_auto', true) = 'on' then
    return null;
  end if;
  select value into v_cfg from app_settings where key = 'whatsapp';
  if not coalesce((v_cfg ->> 'auto_send')::boolean, false)
     or not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    return null;
  end if;
  v_default := nullif(v_cfg ->> 'auto_template_id', '')::uuid;

  insert into wa_outbox (lead_id, template_id, kind)
  select n.id,
         coalesce(
           -- a different template for a particular landing page / form: "match" is part of its name
           (select nullif(r ->> 'template_id', '')::uuid
              from jsonb_array_elements(coalesce(v_cfg -> 'rules', '[]'::jsonb)) r
             where coalesce(r ->> 'match', '') <> ''
               and n.source_detail ilike '%' || (r ->> 'match') || '%'
             limit 1),
           v_default),
         'auto'
    from new_rows n
   where n.phone is not null
     and not n.wa_opt_out
     and n.source in (select jsonb_array_elements_text(coalesce(v_cfg -> 'auto_sources', '[]'::jsonb)))
     and coalesce(
           (select nullif(r ->> 'template_id', '')::uuid
              from jsonb_array_elements(coalesce(v_cfg -> 'rules', '[]'::jsonb)) r
             where coalesce(r ->> 'match', '') <> ''
               and n.source_detail ilike '%' || (r ->> 'match') || '%'
             limit 1),
           v_default) is not null;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform private.wa_kick();
  end if;
  return null;
end;
$$;

create or replace function public.wa_send_to_numbers(p_template uuid, p_entries jsonb, p_name text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e jsonb;
  v_key text;
  v_id uuid;
  v_optout boolean;
  v_ids uuid[] := '{}';
  v_new int := 0;
  v_existing int := 0;
  v_invalid int := 0;
  v_stopped int := 0;
  v_b uuid;
begin
  if not is_admin() then
    raise exception 'Only admin can send to numbers';
  end if;
  if not exists (select 1 from wa_templates where id = p_template and status = 'APPROVED') then
    raise exception 'Choose a template that Meta has approved';
  end if;
  if not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    raise exception 'Connect WhatsApp first (More > WhatsApp)';
  end if;
  if jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception 'Enter at least one phone number';
  end if;
  if jsonb_array_length(p_entries) > 500 then
    raise exception 'Up to 500 numbers at a time';
  end if;

  perform set_config('app.skip_wa_auto', 'on', true);
  perform set_config('app.skip_notify', 'on', true);

  for e in select * from jsonb_array_elements(p_entries) loop
    v_key := phone_key(e ->> 'phone');
    if v_key is null or length(v_key) < 10 then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    v_id := null;
    select id, wa_opt_out into v_id, v_optout from leads where phone_key = v_key limit 1;
    if v_id is null then
      insert into leads (name, phone, source, source_detail, created_by)
      values (coalesce(e ->> 'name', ''), e ->> 'phone', 'manual', 'WhatsApp quick send', auth.uid())
      returning id into v_id;
      v_new := v_new + 1;
    elsif v_optout then
      v_stopped := v_stopped + 1;
      continue;
    else
      v_existing := v_existing + 1;
    end if;
    if not (v_id = any(v_ids)) then
      v_ids := v_ids || v_id;
    end if;
  end loop;

  perform set_config('app.skip_wa_auto', 'off', true);
  perform set_config('app.skip_notify', 'off', true);

  if coalesce(array_length(v_ids, 1), 0) > 0 then
    insert into wa_broadcasts (name, template_id, filter, total)
    values (coalesce(nullif(trim(p_name), ''), 'Quick send'), p_template, '{}'::jsonb, array_length(v_ids, 1))
    returning id into v_b;
    insert into wa_outbox (lead_id, template_id, kind, broadcast_id)
    select unnest(v_ids), p_template, 'broadcast', v_b;
    perform private.wa_kick();
  end if;

  return jsonb_build_object(
    'sending', coalesce(array_length(v_ids, 1), 0),
    'new_leads', v_new,
    'existing', v_existing,
    'invalid', v_invalid,
    'stopped', v_stopped,
    'broadcast_id', v_b);
end;
$$;

revoke execute on function public.wa_send_to_numbers(uuid, jsonb, text) from public, anon;
grant execute on function public.wa_send_to_numbers(uuid, jsonb, text) to authenticated;
