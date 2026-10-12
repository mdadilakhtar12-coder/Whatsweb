-- Push notifications (Firebase Cloud Messaging):
--   * new lead assigned  -> the agent at once
--   * new unassigned lead from ads -> admins
--   * every morning 9:00 IST -> each person's follow-ups for the day
--   * lead not called within N minutes -> the agent and admins (optionally re-assign)
-- The database decides who gets what; the "push" edge function only delivers.

do $$
begin
  create extension if not exists pg_net with schema extensions;
  create extension if not exists pg_cron;
exception when others then
  raise warning 'pg_net / pg_cron could not be enabled (%): push notifications stay off', sqlerrm;
end $$;

create schema if not exists private;

-- Set by scripts/supabase-deploy.sh: functions_url = https://<ref>.supabase.co/functions/v1
create table if not exists private.config (
  key text primary key,
  value text not null
);

-- ---------------------------------------------------------------------------
-- Phones that receive notifications
-- ---------------------------------------------------------------------------

create table public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);
alter table public.device_tokens enable row level security;
-- No policies: the app goes through the two functions below.

create or replace function public.register_device(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_member() or coalesce(p_token, '') = '' then
    return;
  end if;
  -- The same phone may have been used by someone else before: it now belongs to this user.
  insert into device_tokens (token, user_id, updated_at)
  values (p_token, auth.uid(), now())
  on conflict (token) do update set user_id = excluded.user_id, updated_at = now();
end;
$$;

create or replace function public.unregister_device(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from device_tokens where token = p_token and user_id = auth.uid();
$$;

revoke execute on function public.register_device(text) from public, anon;
revoke execute on function public.unregister_device(text) from public, anon;
grant execute on function public.register_device(text) to authenticated;
grant execute on function public.unregister_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Sending: hand the messages to the "push" edge function (after commit, async)
-- p_messages: [{"user_id": "...", "title": "...", "body": "...", "data": {"lead_id": "..."}}]
-- ---------------------------------------------------------------------------

create or replace function private.push(p_messages jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  if p_messages is null or jsonb_array_length(p_messages) = 0 then
    return;
  end if;
  select value into v_url from private.config where key = 'functions_url';
  select value ->> 'webhook_key' into v_key from app_settings where key = 'integrations';
  if v_url is null or v_key is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/push',
    body := jsonb_build_object('messages', p_messages),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key)
  );
end;
$$;

create or replace function private.admin_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from profiles where role = 'admin' and is_active;
$$;

-- ---------------------------------------------------------------------------
-- New / re-assigned leads (one message per person, even for many leads at once)
-- ---------------------------------------------------------------------------

create or replace function private.notify_new_leads()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
  v_messages jsonb;
  v_admin_messages jsonb;
begin
  if current_setting('app.skip_notify', true) = 'on' then
    return null;
  end if;

  -- Who got new leads in this statement (old_rows only exists for UPDATE).
  if tg_op = 'INSERT' then
    select jsonb_agg(jsonb_build_object('id', n.id, 'assigned_to', n.assigned_to,
                                        'who', coalesce(nullif(n.name, ''), n.phone, n.email)))
      into v_rows
      from new_rows n
     where n.assigned_to is not null and n.assigned_to is distinct from auth.uid();
  else
    select jsonb_agg(jsonb_build_object('id', n.id, 'assigned_to', n.assigned_to,
                                        'who', coalesce(nullif(n.name, ''), n.phone, n.email)))
      into v_rows
      from new_rows n join old_rows o on o.id = n.id
     where n.assigned_to is not null
       and n.assigned_to is distinct from o.assigned_to
       and n.assigned_to is distinct from auth.uid();
  end if;

  select jsonb_agg(jsonb_build_object(
           'user_id', c.assigned_to,
           'title', case when c.cnt = 1 then 'New lead: ' || c.first_name else c.cnt || ' new leads for you' end,
           'body', case when c.cnt = 1 then 'Call now — the sooner, the better' else 'Open WhatsWeb and start calling' end,
           'data', case when c.cnt = 1 then jsonb_build_object('lead_id', c.first_id) else '{}'::jsonb end))
    into v_messages
  from (
    select assigned_to, count(*) as cnt, min(who) as first_name, min(id::text) as first_id
    from jsonb_to_recordset(coalesce(v_rows, '[]'::jsonb)) as x(id uuid, assigned_to uuid, who text)
    group by assigned_to
  ) c;

  -- Leads from ads that nobody got automatically: tell the admins.
  if tg_op = 'INSERT' and auth.uid() is null then
    select jsonb_agg(jsonb_build_object(
             'user_id', a.id,
             'title', case when u.cnt = 1 then 'New lead: ' || u.first_name else u.cnt || ' new leads' end,
             'body', 'Not assigned yet — open WhatsWeb to assign',
             'data', case when u.cnt = 1 then jsonb_build_object('lead_id', u.first_id) else '{}'::jsonb end))
      into v_admin_messages
    from (
      select count(*) as cnt,
             min(coalesce(nullif(name, ''), phone, email)) as first_name,
             min(id::text) as first_id
      from new_rows
      where assigned_to is null
      having count(*) > 0
    ) u
    cross join private.admin_ids() a(id);
  end if;

  perform private.push(coalesce(v_messages, '[]'::jsonb) || coalesce(v_admin_messages, '[]'::jsonb));
  return null;
end;
$$;

create trigger leads_notify_insert
  after insert on public.leads
  referencing new table as new_rows
  for each statement execute function private.notify_new_leads();

create trigger leads_notify_update
  after update on public.leads
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.notify_new_leads();

-- Assign in one statement, so sharing 50 leads sends one message per person, not 50.
create or replace function public.assign_leads(p_lead_ids uuid[], p_agent_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agents uuid[];
  v_n int;
  v_count int;
begin
  if not is_admin() then
    raise exception 'Only admin can assign leads';
  end if;

  select array_agg(id order by ord) into v_agents
    from unnest(coalesce(p_agent_ids, '{}')) with ordinality as a(id, ord)
   where exists (select 1 from profiles p where p.id = a.id and p.is_active);
  v_n := coalesce(array_length(v_agents, 1), 0);

  update leads l
     set assigned_to = case when v_n = 0 then null else v_agents[((t.ord - 1) % v_n) + 1] end
    from unnest(coalesce(p_lead_ids, '{}')) with ordinality as t(id, ord)
   where l.id = t.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Excel import: one message at the end instead of one per row.
create or replace function public.import_leads(
  p_rows jsonb,
  p_assign_to uuid default null,
  p_source_detail text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_key text;
  v_email text;
  v_existing uuid;
  v_added int := 0;
  v_dupes int := 0;
  v_invalid int := 0;
begin
  if not is_admin() then
    raise exception 'Only admin can import leads';
  end if;
  perform set_config('app.skip_notify', 'on', true);

  for r in select * from jsonb_array_elements(p_rows) loop
    v_key := phone_key(r ->> 'phone');
    v_email := nullif(lower(trim(r ->> 'email')), '');

    if v_key is null and v_email is null then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    v_existing := null;
    if v_key is not null then
      select id into v_existing from leads where phone_key = v_key;
    else
      select id into v_existing from leads where lower(email) = v_email limit 1;
    end if;

    if v_existing is not null then
      v_dupes := v_dupes + 1;
      continue;
    end if;

    insert into leads (name, phone, email, source, source_detail, assigned_to, extra, created_by)
    values (
      coalesce(r ->> 'name', ''),
      r ->> 'phone',
      v_email,
      'excel',
      p_source_detail,
      p_assign_to,
      coalesce(r -> 'extra', '{}'::jsonb),
      auth.uid()
    );
    v_added := v_added + 1;
  end loop;

  perform set_config('app.skip_notify', 'off', true);
  if v_added > 0 and p_assign_to is not null and p_assign_to <> auth.uid() then
    perform private.push(jsonb_build_array(jsonb_build_object(
      'user_id', p_assign_to,
      'title', v_added || ' new leads for you',
      'body', 'Imported from ' || coalesce(p_source_detail, 'Excel') || ' — open WhatsWeb and start calling',
      'data', '{}'::jsonb)));
  end if;

  return jsonb_build_object('added', v_added, 'duplicates', v_dupes, 'invalid', v_invalid);
end;
$$;

-- ---------------------------------------------------------------------------
-- Morning summary (9:00 IST)
-- ---------------------------------------------------------------------------

create or replace function private.daily_summary()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_start timestamptz := v_today::timestamp at time zone 'Asia/Kolkata';
  v_messages jsonb;
begin
  select jsonb_agg(jsonb_build_object(
           'user_id', s.id,
           'title', 'Good morning, ' || split_part(s.full_name, ' ', 1) || ' 👋',
           'body', concat_ws(' · ',
             s.today || ' follow-up' || case when s.today = 1 then '' else 's' end || ' today',
             case when s.overdue > 0 then s.overdue || ' overdue' end,
             case when s.not_called > 0 then s.not_called || ' new not called' end,
             case when s.is_admin and s.unassigned > 0 then s.unassigned || ' unassigned' end),
           'data', jsonb_build_object('open', 'followups')))
    into v_messages
  from (
    select p.id, p.full_name, p.role = 'admin' as is_admin,
      (select count(*) from reminders r where r.user_id = p.id and not r.is_done
          and r.remind_at >= v_start and r.remind_at < v_start + interval '1 day') as today,
      (select count(*) from reminders r where r.user_id = p.id and not r.is_done
          and r.remind_at < v_start) as overdue,
      (select count(*) from leads l where l.assigned_to = p.id and l.status = 'New'
          and l.last_contacted_at is null) as not_called,
      (select count(*) from leads l where l.assigned_to is null) as unassigned
    from profiles p
    where p.is_active
  ) s
  where s.today + s.overdue + s.not_called + (case when s.is_admin then s.unassigned else 0 end) > 0;

  perform private.push(v_messages);
end;
$$;

-- ---------------------------------------------------------------------------
-- Speed to lead: alert when a new lead is not called quickly; optionally re-assign
-- ---------------------------------------------------------------------------

alter table public.leads add column sla_alerted_at timestamptz;

insert into public.app_settings (key, value) values
  ('speed_to_lead', '{"alert_minutes": 15, "reassign_minutes": 0, "start_hour": 9, "end_hour": 21}'::jsonb)
on conflict (key) do nothing;

create or replace function private.sla_check()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
  v_alert int;
  v_reassign int;
  v_hour int := extract(hour from now() at time zone 'Asia/Kolkata');
  v_messages jsonb := '[]'::jsonb;
  v_part jsonb;
  v_lead record;
  v_agent uuid;
  v_pool uuid[];
begin
  select value into v_cfg from app_settings where key = 'speed_to_lead';
  v_alert := coalesce((v_cfg ->> 'alert_minutes')::int, 15);
  v_reassign := coalesce((v_cfg ->> 'reassign_minutes')::int, 0);
  if v_alert <= 0
     or v_hour < coalesce((v_cfg ->> 'start_hour')::int, 9)
     or v_hour >= coalesce((v_cfg ->> 'end_hour')::int, 21) then
    return;
  end if;

  -- 1. Optionally give long-waiting leads to someone else.
  if v_reassign > 0 then
    select coalesce(array_agg(p.id), '{}') into v_pool
      from profiles p
     where p.is_active
       and (p.role = 'agent'
            or p.id::text in (select jsonb_array_elements_text(
                 (select value -> 'agent_ids' from app_settings where key = 'auto_assign'))));

    for v_lead in
      select l.id, l.assigned_to from leads l
       where l.status = 'New' and l.last_contacted_at is null and l.assigned_to is not null
         and l.assigned_at < now() - make_interval(mins => v_reassign)
       for update skip locked
    loop
      select p.id into v_agent
        from profiles p
       where p.id = any(v_pool) and p.id <> v_lead.assigned_to
       order by p.last_auto_assigned_at nulls first, p.created_at
       limit 1;
      if v_agent is null then
        exit;
      end if;
      update profiles set last_auto_assigned_at = now() where id = v_agent;
      update leads set assigned_to = v_agent, sla_alerted_at = null where id = v_lead.id;
    end loop;
  end if;

  -- 2. Remind the agent about each lead waiting too long (once per lead).
  with late as (
    update leads l
       set sla_alerted_at = now()
     where l.status = 'New' and l.last_contacted_at is null and l.assigned_to is not null
       and l.sla_alerted_at is null
       and l.assigned_at < now() - make_interval(mins => v_alert)
    returning l.id, l.assigned_to, coalesce(nullif(l.name, ''), l.phone, l.email) as who, l.assigned_at
  ),
  per_agent as (
    select assigned_to, count(*) as cnt, min(who) as who, min(id::text) as first_id,
           max(extract(epoch from now() - assigned_at) / 60)::int as mins
    from late group by assigned_to
  ),
  agent_msgs as (
    select jsonb_build_object(
             'user_id', a.assigned_to,
             'title', case when a.cnt = 1 then '⏰ Call ' || a.who || ' now'
                           else '⏰ ' || a.cnt || ' new leads waiting for your call' end,
             'body', 'Waiting ' || a.mins || ' min — quick calls get more admissions',
             'data', case when a.cnt = 1 then jsonb_build_object('lead_id', a.first_id) else '{}'::jsonb end) as m
    from per_agent a
  ),
  admin_msgs as (
    select jsonb_build_object(
             'user_id', ad.id,
             'title', (select sum(cnt) from per_agent) || ' lead(s) not called for ' || v_alert || '+ min',
             'body', (select string_agg(coalesce(p.full_name, '?') || ' ' || a.cnt, ', ')
                        from per_agent a left join profiles p on p.id = a.assigned_to),
             'data', jsonb_build_object('open', 'dashboard')) as m
    from private.admin_ids() ad(id)
    where exists (select 1 from per_agent)
  )
  select coalesce(jsonb_agg(m), '[]'::jsonb) into v_part
    from (select m from agent_msgs union all select m from admin_msgs) x;
  v_messages := v_messages || v_part;

  -- 3. Leads from ads that nobody took (once per lead).
  with waiting as (
    update leads l
       set sla_alerted_at = now()
     where l.assigned_to is null and l.sla_alerted_at is null
       and l.created_at < now() - make_interval(mins => v_alert)
    returning l.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', ad.id,
           'title', (select count(*) from waiting) || ' lead(s) still unassigned',
           'body', 'Waiting ' || v_alert || '+ min — open WhatsWeb to assign',
           'data', jsonb_build_object('open', 'leads'))), '[]'::jsonb)
    into v_part
  from private.admin_ids() ad(id)
  where exists (select 1 from waiting);
  v_messages := v_messages || v_part;

  perform private.push(v_messages);
end;
$$;

-- ---------------------------------------------------------------------------
-- Schedules (pg_cron runs in UTC; 03:30 UTC = 09:00 IST)
-- ---------------------------------------------------------------------------

do $$
begin
  perform cron.schedule('whatsweb-daily-summary', '30 3 * * *', 'select private.daily_summary()');
  perform cron.schedule('whatsweb-speed-to-lead', '*/5 * * * *', 'select private.sla_check()');
exception when others then
  raise warning 'Could not schedule jobs (%): morning summary / speed-to-lead alerts stay off', sqlerrm;
end $$;
