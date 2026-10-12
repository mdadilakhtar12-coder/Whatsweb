-- Hot/Warm/Cold, lost reasons, call log, several message templates, dashboard,
-- targets / leaderboard, in-app update and app lock settings.

-- ---------------------------------------------------------------------------
-- Leads: temperature and the reason a lead was lost
-- ---------------------------------------------------------------------------

alter table public.leads
  add column temperature text check (temperature in ('hot', 'warm', 'cold')),
  add column lost_reason text;

create index leads_temperature_idx on public.leads (temperature) where temperature is not null;

-- won = counts as an admission; ask_reason = asks "why?" when chosen
alter table public.lead_statuses
  add column is_won boolean not null default false,
  add column ask_reason boolean not null default false;

update public.lead_statuses set is_won = true where name = 'Admission Done';
update public.lead_statuses set ask_reason = true where name = 'Not Interested';

insert into public.app_settings (key, value) values
  ('lost_reasons', jsonb_build_object('reasons', jsonb_build_array(
    'Fees too high', 'Too far', 'Joined somewhere else', 'Wrong course',
    'Wants online classes', 'Parents not agreeing', 'Just enquiring'))),
  ('security', '{"require_pin": false}'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- History entries for the new fields
-- ---------------------------------------------------------------------------

alter table public.lead_activities drop constraint lead_activities_type_check;
alter table public.lead_activities add constraint lead_activities_type_check check (type in (
  'created', 'remark', 'status', 'call', 'whatsapp', 'sms', 'email',
  'assigned', 'reminder', 'duplicate', 'edit', 'temperature', 'lost_reason'
));

create or replace function public.leads_after_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into lead_activities (lead_id, user_id, type, body, meta)
    values (new.id, auth.uid(), 'created', null,
            jsonb_build_object('source', new.source, 'source_detail', new.source_detail));
    if new.assigned_to is not null then
      insert into lead_activities (lead_id, user_id, type, meta)
      values (new.id, auth.uid(), 'assigned', jsonb_build_object('to', new.assigned_to));
    end if;
    return new;
  end if;

  if new.assigned_to is distinct from old.assigned_to then
    insert into lead_activities (lead_id, user_id, type, meta)
    values (new.id, auth.uid(), 'assigned',
            jsonb_build_object('from', old.assigned_to, 'to', new.assigned_to));
    -- pending reminders follow the lead to its new owner
    if new.assigned_to is not null then
      update reminders
         set user_id = new.assigned_to
       where lead_id = new.id and not is_done and user_id = old.assigned_to;
    end if;
  end if;

  -- when a status is renamed the old name no longer exists: skip, that is not a real change
  if new.status is distinct from old.status
     and exists (select 1 from lead_statuses where name = old.status) then
    insert into lead_activities (lead_id, user_id, type, meta)
    values (new.id, auth.uid(), 'status', jsonb_build_object('from', old.status, 'to', new.status));
  end if;

  if new.temperature is distinct from old.temperature then
    insert into lead_activities (lead_id, user_id, type, meta)
    values (new.id, auth.uid(), 'temperature',
            jsonb_build_object('from', old.temperature, 'to', new.temperature));
  end if;

  if new.lost_reason is distinct from old.lost_reason and new.lost_reason is not null then
    insert into lead_activities (lead_id, user_id, type, body, meta)
    values (new.id, auth.uid(), 'lost_reason', new.lost_reason, jsonb_build_object('status', new.status));
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Several message templates per channel (admin manages them)
-- ---------------------------------------------------------------------------

create table public.message_templates (
  id uuid primary key default gen_random_uuid(),
  channel text not null check (channel in ('whatsapp', 'sms', 'email')),
  name text not null,
  subject text,
  body text not null default '',
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

alter table public.message_templates enable row level security;

create policy templates_select on public.message_templates
  for select to authenticated using ((select public.is_member()));
create policy templates_admin on public.message_templates
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Carry over the single templates from the first version.
insert into public.message_templates (channel, name, subject, body, sort_order)
select t.channel, 'Default', t.subject, t.body, 1
from public.app_settings s,
lateral (values
  ('whatsapp', null, s.value ->> 'whatsapp'),
  ('sms', null, s.value ->> 'sms'),
  ('email', s.value ->> 'email_subject', s.value ->> 'email_body')
) as t(channel, subject, body)
where s.key = 'templates' and coalesce(t.body, '') <> '';

-- ---------------------------------------------------------------------------
-- Call log from the phone: one history row per call, duplicates ignored
-- ---------------------------------------------------------------------------

create unique index lead_activities_call_log_uniq
  on public.lead_activities (lead_id, user_id, created_at)
  where type = 'call' and (meta ->> 'source') = 'log';

-- p_calls: [{"number": "...", "direction": "out|in|missed|rejected", "duration": 35, "at": "2026-..."}]
-- Returns how many calls were new. A not-answered outgoing call moves a "New" lead to "No Answer".
create or replace function public.log_calls(p_calls jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb;
  v_lead leads%rowtype;
  v_key text;
  v_at timestamptz;
  v_dir text;
  v_dur int;
  v_id bigint;
  v_count int := 0;
  v_admin boolean := is_admin();
begin
  if not is_member() then
    raise exception 'Not allowed';
  end if;

  for c in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    v_key := phone_key(c ->> 'number');
    v_dir := c ->> 'direction';
    v_dur := greatest(coalesce((c ->> 'duration')::int, 0), 0);
    v_at := (c ->> 'at')::timestamptz;
    if v_key is null or v_at is null or v_dir not in ('out', 'in', 'missed', 'rejected') then
      continue;
    end if;

    select * into v_lead from leads
     where phone_key = v_key and (v_admin or assigned_to = auth.uid());
    if not found or v_at < v_lead.created_at - interval '1 hour' then
      continue;
    end if;

    v_id := null;
    insert into lead_activities (lead_id, user_id, type, meta, created_at)
    values (v_lead.id, auth.uid(), 'call',
            jsonb_build_object('direction', v_dir, 'duration', v_dur, 'source', 'log'), v_at)
    on conflict do nothing
    returning id into v_id;
    if v_id is null then
      continue;
    end if;
    v_count := v_count + 1;

    if v_dir = 'out' or (v_dir = 'in' and v_dur > 0) then
      update leads
         set last_contacted_at = greatest(coalesce(last_contacted_at, v_at), v_at)
       where id = v_lead.id;
    end if;

    if v_dir = 'out' and v_dur = 0 and v_lead.status = 'New'
       and exists (select 1 from lead_statuses where name = 'No Answer') then
      update leads set status = 'No Answer' where id = v_lead.id;
    end if;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Targets, leaderboard and the admin dashboard
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column daily_call_target int check (daily_call_target >= 0),
  add column monthly_admission_target int check (monthly_admission_target >= 0);

-- Everyone in the team sees the leaderboard (calls, talk time, admissions per person).
create or replace function public.leaderboard(p_from timestamptz, p_to timestamptz)
returns table (
  user_id uuid,
  name text,
  calls bigint,
  connected bigint,
  talk_seconds bigint,
  admissions bigint,
  daily_call_target int,
  monthly_admission_target int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.full_name,
    count(a.id) filter (where a.type = 'call' and coalesce(a.meta ->> 'direction', 'out') = 'out'),
    count(a.id) filter (where a.type = 'call' and a.meta ->> 'direction' in ('out', 'in')
                          and (a.meta ->> 'duration')::int > 0),
    coalesce(sum((a.meta ->> 'duration')::int) filter (where a.type = 'call'), 0)::bigint,
    count(a.id) filter (where a.type = 'status'
                          and a.meta ->> 'to' in (select s.name from lead_statuses s where s.is_won)),
    p.daily_call_target,
    p.monthly_admission_target
  from profiles p
  left join lead_activities a
    on a.user_id = p.id and a.created_at >= p_from and a.created_at < p_to
  where p.is_active and is_member()
  group by p.id
  order by 3 desc, 5 desc;
$$;

-- Admin only: everything the dashboard shows, for leads/activity between p_from and p_to.
create or replace function public.dashboard_stats(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_agents jsonb;
  v_sources jsonb;
  v_campaigns jsonb;
  v_reasons jsonb;
  v_totals jsonb;
begin
  if not is_admin() then
    raise exception 'Only admin can see the dashboard';
  end if;

  select coalesce(jsonb_agg(row_to_json(x) order by x.calls desc), '[]'::jsonb) into v_agents
  from (
    select
      p.id as user_id,
      p.full_name as name,
      p.daily_call_target,
      p.monthly_admission_target,
      count(a.id) filter (where a.type = 'call' and coalesce(a.meta ->> 'direction', 'out') = 'out') as calls,
      count(a.id) filter (where a.type = 'call' and a.meta ->> 'direction' in ('out', 'in')
                            and (a.meta ->> 'duration')::int > 0) as connected,
      coalesce(sum((a.meta ->> 'duration')::int) filter (where a.type = 'call'), 0) as talk_seconds,
      count(a.id) filter (where a.type in ('whatsapp', 'sms', 'email')) as messages,
      count(distinct a.lead_id) filter (where a.type in ('call', 'whatsapp', 'sms', 'email')) as leads_contacted,
      count(a.id) filter (where a.type = 'status'
                            and a.meta ->> 'to' in (select s.name from lead_statuses s where s.is_won)) as admissions,
      (select count(*) from leads l where l.assigned_to = p.id) as open_leads,
      (select count(*) from leads l
        where l.assigned_to = p.id and l.status = 'New' and l.last_contacted_at is null) as not_called,
      (select count(*) from reminders r
        where r.user_id = p.id and not r.is_done and r.remind_at < now()) as overdue_followups
    from profiles p
    left join lead_activities a
      on a.user_id = p.id and a.created_at >= p_from and a.created_at < p_to
    where p.is_active
    group by p.id
  ) x;

  select coalesce(jsonb_agg(row_to_json(x) order by x.leads desc), '[]'::jsonb) into v_sources
  from (
    select l.source,
           count(*) as leads,
           count(*) filter (where l.status in (select s.name from lead_statuses s where s.is_won)) as admissions
    from leads l
    where l.created_at >= p_from and l.created_at < p_to
    group by l.source
  ) x;

  select coalesce(jsonb_agg(row_to_json(x) order by x.leads desc), '[]'::jsonb) into v_campaigns
  from (
    select coalesce(nullif(l.source_detail, ''), 'Unknown') as campaign,
           l.source,
           count(*) as leads,
           count(*) filter (where l.status in (select s.name from lead_statuses s where s.is_won)) as admissions
    from leads l
    where l.created_at >= p_from and l.created_at < p_to
    group by 1, 2
    order by 3 desc
    limit 15
  ) x;

  select coalesce(jsonb_agg(row_to_json(x) order by x.count desc), '[]'::jsonb) into v_reasons
  from (
    select a.body as reason, count(*) as count
    from lead_activities a
    where a.type = 'lost_reason' and a.created_at >= p_from and a.created_at < p_to
    group by a.body
  ) x;

  select jsonb_build_object(
    'new_leads', (select count(*) from leads l where l.created_at >= p_from and l.created_at < p_to),
    'unassigned', (select count(*) from leads l where l.assigned_to is null),
    'not_called', (select count(*) from leads l where l.status = 'New' and l.last_contacted_at is null),
    'admissions', (select count(*) from lead_activities a
                    where a.type = 'status' and a.created_at >= p_from and a.created_at < p_to
                      and a.meta ->> 'to' in (select s.name from lead_statuses s where s.is_won)),
    'calls', (select count(*) from lead_activities a
               where a.type = 'call' and coalesce(a.meta ->> 'direction', 'out') = 'out'
                 and a.created_at >= p_from and a.created_at < p_to)
  ) into v_totals;

  return jsonb_build_object(
    'totals', v_totals,
    'agents', v_agents,
    'sources', v_sources,
    'campaigns', v_campaigns,
    'lost_reasons', v_reasons
  );
end;
$$;

revoke execute on function public.log_calls(jsonb) from public, anon;
revoke execute on function public.leaderboard(timestamptz, timestamptz) from public, anon;
revoke execute on function public.dashboard_stats(timestamptz, timestamptz) from public, anon;
grant execute on function public.log_calls(jsonb) to authenticated;
grant execute on function public.leaderboard(timestamptz, timestamptz) to authenticated;
grant execute on function public.dashboard_stats(timestamptz, timestamptz) to authenticated;
