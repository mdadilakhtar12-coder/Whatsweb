-- Guards against fake leads sent to the public landing-page address:
--   * the landing page gets its own key (landing_key), separate from the server-only key
--   * per visitor / per phone / per day limits (landing_allow), checked by the lead-webhook function
--   * a daily cap on automatic WhatsApp messages (money), with a notification when it is reached

create table if not exists private.landing_hits (
  id bigserial primary key,
  ip text,
  phone_key text,
  ok boolean not null default true,
  at timestamptz not null default now()
);
create index if not exists landing_hits_ip_idx on private.landing_hits (ip, at);
create index if not exists landing_hits_phone_idx on private.landing_hits (phone_key, at);
create index if not exists landing_hits_at_idx on private.landing_hits (at);

-- 'ok', 'rate' (this visitor / phone is sending too much) or 'cap' (too many leads today).
create or replace function public.landing_allow(p_ip text, p_phone text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := phone_key(p_phone);
  v_cap int;
  v_today int;
  v_ip int := 0;
  v_same int := 0;
  v_alert timestamptz;
begin
  delete from private.landing_hits where at < now() - interval '1 day';

  select coalesce((value ->> 'landing_daily_cap')::int, 300),
         nullif(value ->> 'landing_cap_alert_at', '')::timestamptz
    into v_cap, v_alert
    from app_settings where key = 'integrations';
  v_cap := coalesce(v_cap, 300);

  -- one visitor (address) or one phone number cannot flood the form
  if coalesce(p_ip, '') <> '' then
    select count(*) into v_ip from private.landing_hits where ip = p_ip and at > now() - interval '10 minutes';
  end if;
  if v_key is not null then
    select count(*) into v_same from private.landing_hits where phone_key = v_key and at > now() - interval '10 minutes';
  end if;
  if v_ip >= 20 or v_same >= 2 then
    insert into private.landing_hits (ip, phone_key, ok) values (nullif(p_ip, ''), v_key, false);
    return 'rate';
  end if;

  select count(*) into v_today from private.landing_hits where ok and at > now() - interval '1 day';
  if v_today >= v_cap then
    insert into private.landing_hits (ip, phone_key, ok) values (nullif(p_ip, ''), v_key, false);
    if v_alert is null or v_alert < now() - interval '12 hours' then
      update app_settings
         set value = value || jsonb_build_object('landing_cap_alert_at', now())
       where key = 'integrations';
      perform private.push((
        select coalesce(jsonb_agg(jsonb_build_object(
                 'user_id', a.id,
                 'title', 'Landing page limit reached',
                 'body', v_cap || ' leads in 24 hours. New ones are paused. If this is fake traffic, change the landing key (ask Claude).',
                 'data', jsonb_build_object('open', 'leads'))), '[]'::jsonb)
          from private.admin_ids() a(id)));
    end if;
    return 'cap';
  end if;

  insert into private.landing_hits (ip, phone_key, ok) values (nullif(p_ip, ''), v_key, true);
  return 'ok';
end;
$$;

revoke execute on function public.landing_allow(text, text) from public, anon, authenticated;
grant execute on function public.landing_allow(text, text) to service_role;

-- Automatic WhatsApp: daily cap (settable: whatsapp.auto_daily_cap, default 300)
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
  v_cap int;
  v_before int;
  v_new int;
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

  -- Spending guard: at most auto_daily_cap automatic messages in 24 hours (fake or very many leads).
  v_cap := coalesce((v_cfg ->> 'auto_daily_cap')::int, 300);
  select count(*) into v_before from wa_outbox where kind = 'auto' and created_at > now() - interval '24 hours';
  select count(*) into v_new from new_rows;
  if v_before + v_new > v_cap
     and coalesce(nullif(v_cfg ->> 'auto_cap_alert_at', '')::timestamptz, '-infinity') < now() - interval '12 hours' then
    update app_settings
       set value = value || jsonb_build_object('auto_cap_alert_at', now())
     where key = 'whatsapp';
    perform private.push((
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id', a.id,
               'title', 'Automatic WhatsApp limit reached',
               'body', 'More than ' || v_cap || ' automatic messages in 24 hours. Check the leads. If they are real, the limit can be raised.',
               'data', jsonb_build_object('open', 'leads'))), '[]'::jsonb)
        from private.admin_ids() a(id)));
  end if;
  if v_before >= v_cap then
    return null;
  end if;

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
    from (select * from new_rows order by created_at limit greatest(v_cap - v_before, 0)) n
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
