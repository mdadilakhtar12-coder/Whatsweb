-- Template variables that are typed in when the message is sent: {ask.semester}, {ask.paper}...
--   * wa_outbox.params keeps the typed values for a broadcast / quick send
--   * broadcast and "send to numbers" take the values (the same for everyone in that send)

alter table public.wa_outbox add column params jsonb not null default '{}'::jsonb;

-- Raises an error if the template has {ask.x} variables that p_params does not fill.
create or replace function private.wa_check_asked(p_template uuid, p_params jsonb)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_spec jsonb;
  v_text text;
  v_missing text[];
begin
  select spec into v_spec from wa_templates where id = p_template;
  v_text := coalesce(v_spec ->> 'body', '') || ' ' || coalesce(v_spec -> 'header' ->> 'text', '') || ' ' ||
            coalesce((select string_agg(b ->> 'url', ' ') from jsonb_array_elements(coalesce(v_spec -> 'buttons', '[]'::jsonb)) b), '');
  select array_agg(distinct lower(m[1])) into v_missing
    from regexp_matches(v_text, '\{ask\.([a-z][a-z0-9_]*)\}', 'gi') m
   where btrim(coalesce(p_params ->> lower(m[1]), '')) = '';
  if v_missing is not null then
    raise exception 'Fill in: %', array_to_string(v_missing, ', ');
  end if;
end;
$$;

drop function public.wa_create_broadcast(uuid, text, jsonb);
drop function public.wa_send_to_numbers(uuid, jsonb, text);

create or replace function public.wa_create_broadcast(
  p_template uuid,
  p_name text,
  p_filter jsonb,
  p_params jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_n int;
begin
  if not is_admin() then
    raise exception 'Only admin can send a broadcast';
  end if;
  if not exists (select 1 from wa_templates where id = p_template and status = 'APPROVED') then
    raise exception 'Choose a template that Meta has approved';
  end if;
  if not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    raise exception 'Connect WhatsApp first (More > WhatsApp)';
  end if;

  perform private.wa_check_asked(p_template, p_params);

  insert into wa_broadcasts (name, template_id, filter)
  values (coalesce(nullif(trim(p_name), ''), 'Broadcast'), p_template, coalesce(p_filter, '{}'::jsonb))
  returning id into v_id;

  insert into wa_outbox (lead_id, template_id, kind, broadcast_id, params)
  select a, p_template, 'broadcast', v_id, coalesce(p_params, '{}'::jsonb) from private.wa_audience(coalesce(p_filter, '{}'::jsonb)) a;
  get diagnostics v_n = row_count;

  update wa_broadcasts set total = v_n, status = case when v_n = 0 then 'done' else 'sending' end where id = v_id;
  if v_n > 0 then
    perform private.wa_kick();
  end if;
  return jsonb_build_object('id', v_id, 'total', v_n);
end;
$$;

create or replace function public.wa_send_to_numbers(
  p_template uuid,
  p_entries jsonb,
  p_name text default null,
  p_params jsonb default '{}'::jsonb
)
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

  perform private.wa_check_asked(p_template, p_params);

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
    insert into wa_outbox (lead_id, template_id, kind, broadcast_id, params)
    select unnest(v_ids), p_template, 'broadcast', v_b, coalesce(p_params, '{}'::jsonb);
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

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.wa_create_broadcast(uuid, text, jsonb, jsonb)',
    'public.wa_send_to_numbers(uuid, jsonb, text, jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
