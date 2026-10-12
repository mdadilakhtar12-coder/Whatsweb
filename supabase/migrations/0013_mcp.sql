-- Claude connector (MCP): Claude, in the admin's own Claude app, can read the CRM's numbers and leads.
--   * Only reading. Claude gets seven fixed tools (crm_overview, crm_leads, ...), never the database itself.
--   * Phone numbers and e-mails are hidden unless the admin switches them on (integrations.mcp_show_contacts).
--   * Every call is written to mcp_log (the admin sees it in the app) and is rate limited.
--   * The connector address contains a secret (integrations.mcp_token); the admin can replace it any time.

create table public.mcp_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  tool text not null,
  args jsonb not null default '{}'::jsonb
);
create index mcp_log_at_idx on public.mcp_log (at desc);
alter table public.mcp_log enable row level security;
revoke all on public.mcp_log from anon, authenticated;
grant select on public.mcp_log to authenticated;
create policy mcp_log_select on public.mcp_log for select to authenticated using ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Admin settings (from the app)
-- ---------------------------------------------------------------------------

create or replace function public.mcp_rotate_token()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  insert into app_settings (key, value)
  values ('integrations', jsonb_build_object('mcp_token', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')))
  on conflict (key) do update
    set value = app_settings.value || excluded.value, updated_at = now();
end;
$$;

create or replace function public.mcp_set_contacts(p_show boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  insert into app_settings (key, value)
  values ('integrations', jsonb_build_object('mcp_show_contacts', coalesce(p_show, false)))
  on conflict (key) do update
    set value = app_settings.value || excluded.value, updated_at = now();
end;
$$;

revoke execute on function public.mcp_rotate_token() from public, anon;
revoke execute on function public.mcp_set_contacts(boolean) from public, anon;
grant execute on function public.mcp_rotate_token() to authenticated;
grant execute on function public.mcp_set_contacts(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Webinar numbers: one calculation for the app (admin) and for Claude
-- ---------------------------------------------------------------------------

create or replace function private.webinar_stats_core(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_totals jsonb;
  v_webinars jsonb;
begin
  select jsonb_build_object(
    'registered', (select count(*) from webinar_registrations r
                    where not r.is_test
                      and coalesce(r.registered_at, r.created_at) >= p_from and coalesce(r.registered_at, r.created_at) < p_to),
    'paid', (select count(*) from webinar_payments p
              where not p.is_test and p.status = 'paid' and p.verified is not false
                and coalesce(p.paid_at, p.created_at) >= p_from and coalesce(p.paid_at, p.created_at) < p_to),
    'revenue', (select coalesce(sum(greatest(coalesce(p.ticket_amount, p.total_charged, 0) - p.refunded_amount, 0)), 0)
                  from webinar_payments p
                 where not p.is_test and p.status = 'paid' and p.verified is not false
                   and coalesce(p.paid_at, p.created_at) >= p_from and coalesce(p.paid_at, p.created_at) < p_to),
    'failed', (select count(*) from webinar_payments p
                where not p.is_test and p.status = 'failed'
                  and coalesce(p.status_at, p.created_at) >= p_from and coalesce(p.status_at, p.created_at) < p_to
                  and not exists (select 1 from webinar_payments q where q.registration_id = p.registration_id and q.status = 'paid')),
    'refunded', (select coalesce(sum(p.refunded_amount), 0) from webinar_payments p
                  where not p.is_test and p.refunded_amount > 0
                    and coalesce(p.status_at, p.created_at) >= p_from and coalesce(p.status_at, p.created_at) < p_to),
    'attended', (select count(*) from webinar_registrations r
                  where not r.is_test and r.attended is true
                    and coalesce(r.registered_at, r.created_at) >= p_from and coalesce(r.registered_at, r.created_at) < p_to),
    'missed', (select count(*) from webinar_registrations r
                where not r.is_test and r.attended is false
                  and coalesce(r.registered_at, r.created_at) >= p_from and coalesce(r.registered_at, r.created_at) < p_to))
    into v_totals;

  select coalesce(jsonb_agg(row_to_json(x) order by x.last_reg desc), '[]'::jsonb) into v_webinars
  from (
    select r.webinar_id,
           max(r.webinar_title) as title,
           count(*) as registered,
           count(*) filter (where exists (select 1 from webinar_payments p where p.registration_id = r.registration_id and p.status = 'paid' and p.verified is not false)) as paid,
           coalesce(sum((select sum(greatest(coalesce(p.ticket_amount, p.total_charged, 0) - p.refunded_amount, 0))
                           from webinar_payments p
                          where p.registration_id = r.registration_id and p.status = 'paid' and p.verified is not false)), 0) as revenue,
           count(*) filter (where r.attended is true) as attended,
           max(coalesce(r.registered_at, r.created_at)) as last_reg
      from webinar_registrations r
     where not r.is_test
       and coalesce(r.registered_at, r.created_at) >= p_from and coalesce(r.registered_at, r.created_at) < p_to
     group by r.webinar_id
     order by max(coalesce(r.registered_at, r.created_at)) desc
     limit 10
  ) x;

  return v_totals || jsonb_build_object('webinars', v_webinars);
end;
$$;
create or replace function public.webinar_stats(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can see these numbers';
  end if;
  return private.webinar_stats_core(p_from, p_to);
end;
$$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.mcp_show_contacts()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value ->> 'mcp_show_contacts')::boolean from app_settings where key = 'integrations'), false);
$$;

-- 91••••••10
create or replace function private.mcp_phone(p text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when nullif(p, '') is null then null
    when private.mcp_show_contacts() then p
    else left(regexp_replace(p, '\D', '', 'g'), 2) || '••••••' || right(regexp_replace(p, '\D', '', 'g'), 2)
  end;
$$;

-- r***@gmail.com
create or replace function private.mcp_email(p text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when nullif(p, '') is null then null
    when private.mcp_show_contacts() or position('@' in p) = 0 then p
    else left(p, 1) || '***' || substr(p, position('@' in p))
  end;
$$;

-- A piece of free text (remark, message): cut short, and with numbers / e-mails hidden when contacts are hidden.
create or replace function private.mcp_text(p text, p_len int default 300)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p is null then null
    when private.mcp_show_contacts() then left(p, p_len)
    else left(
      regexp_replace(
        regexp_replace(p, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email hidden]', 'g'),
        '\+?\d([\s\-]?\d){9,}', '[number hidden]', 'g'),
      p_len)
  end;
$$;

-- 2026-10-06 17:45 (India time)
create or replace function private.mcp_ts(p timestamptz)
returns text
language sql
immutable
as $$
  select to_char(p at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI');
$$;

-- [from, to) for "today", "last_7_days", ... or from / to dates, in India time
create or replace function private.mcp_range(p_args jsonb, p_default text default 'today')
returns timestamptz[]
language plpgsql
stable
as $$
declare
  v_today timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_month timestamptz := date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_range text := coalesce(nullif(p_args ->> 'range', ''), p_default);
begin
  if nullif(p_args ->> 'from', '') is not null then
    return array[
      ((p_args ->> 'from')::date)::timestamp at time zone 'Asia/Kolkata',
      ((coalesce(nullif(p_args ->> 'to', ''), p_args ->> 'from'))::date + 1)::timestamp at time zone 'Asia/Kolkata'];
  end if;
  return case v_range
    when 'today' then array[v_today, v_today + interval '1 day']
    when 'yesterday' then array[v_today - interval '1 day', v_today]
    when 'last_7_days' then array[v_today - interval '6 days', v_today + interval '1 day']
    when 'last_30_days' then array[v_today - interval '29 days', v_today + interval '1 day']
    when 'this_month' then array[v_month, v_month + interval '1 month']
    when 'last_month' then array[v_month - interval '1 month', v_month]
    when 'all' then array['2000-01-01'::timestamptz, v_today + interval '1 day']
    else null
  end;
end;
$$;

-- Rate limit and record of every call. Returns null when fine, else the reason.
create or replace function private.mcp_gate(p_tool text, p_args jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_min int;
  v_day int;
  v_alert timestamptz;
begin
  delete from mcp_log where at < now() - interval '60 days';
  select count(*) filter (where at > now() - interval '1 minute'),
         count(*) filter (where at > now() - interval '1 day')
    into v_min, v_day
    from mcp_log;
  if v_min >= 30 or v_day >= 1500 then
    select nullif(value ->> 'mcp_alert_at', '')::timestamptz into v_alert from app_settings where key = 'integrations';
    if v_alert is null or v_alert < now() - interval '12 hours' then
      update app_settings set value = value || jsonb_build_object('mcp_alert_at', now()) where key = 'integrations';
      perform private.push((
        select coalesce(jsonb_agg(jsonb_build_object(
                 'user_id', a.id,
                 'title', 'Claude connector: too many requests',
                 'body', 'The limit was reached. If you did not ask Claude this much, replace the connector address (More > Claude connector).',
                 'data', jsonb_build_object('open', 'more'))), '[]'::jsonb)
          from private.admin_ids() a(id)));
    end if;
    return 'Too many requests. Wait a minute and try again.';
  end if;
  insert into mcp_log (tool, args) values (p_tool, coalesce(p_args, '{}'::jsonb));
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- The tools. Called only by the edge function "crm-mcp" (arguments are already checked there).
-- ---------------------------------------------------------------------------

create or replace function public.mcp_call(p_tool text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_gate text;
  v_range timestamptz[];
  v_from timestamptz;
  v_to timestamptz;
  v_won text[] := coalesce((select array_agg(name) from lead_statuses where is_won), '{}');
  v_limit int := least(greatest(coalesce((v_args ->> 'limit')::int, 25), 1), 50);
  v_offset int := least(greatest(coalesce((v_args ->> 'offset')::int, 0), 0), 100000);
  v_agent text := nullif(trim(v_args ->> 'agent'), '');
  v_search text := nullif(trim(v_args ->> 'search'), '');
  v_campaign text := nullif(trim(v_args ->> 'campaign'), '');
  v_show boolean := private.mcp_show_contacts();
  v_total int;
  v_rows jsonb;
  v_lead leads;
  v_digits text;
begin
  if p_tool not in ('crm_info', 'crm_overview', 'crm_team', 'crm_leads', 'crm_lead', 'crm_webinar', 'crm_whatsapp') then
    return jsonb_build_object('error', 'Unknown tool');
  end if;
  v_gate := private.mcp_gate(p_tool, v_args);
  if v_gate is not null then
    return jsonb_build_object('error', v_gate);
  end if;

  v_range := private.mcp_range(v_args, case when p_tool = 'crm_leads' then 'all' else 'today' end);
  if v_range is null then
    return jsonb_build_object('error', 'Unknown range');
  end if;
  v_from := v_range[1];
  v_to := v_range[2];

  -- ---- what exists: statuses, team, sources ------------------------------------
  if p_tool = 'crm_info' then
    return jsonb_build_object(
      'time_zone', 'Asia/Kolkata (all times are India time)',
      'contacts_hidden', not v_show,
      'total_leads', (select count(*) from leads),
      'statuses', (select coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'closed', s.is_closed, 'admission_done', s.is_won)
                                             order by s.sort_order, s.id), '[]'::jsonb) from lead_statuses s),
      'team', (select coalesce(jsonb_agg(jsonb_build_object('name', p.full_name, 'role', p.role,
                                                            'daily_call_target', p.daily_call_target,
                                                            'monthly_admission_target', p.monthly_admission_target)
                                         order by p.full_name), '[]'::jsonb) from profiles p where p.is_active),
      'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', x.source, 'campaign', x.detail, 'leads', x.n)
                                            order by x.n desc), '[]'::jsonb)
                    from (select l.source, l.source_detail as detail, count(*) as n from leads l group by 1, 2 order by 3 desc limit 40) x),
      'hot_warm_cold', jsonb_build_array('hot', 'warm', 'cold'));
  end if;

  -- ---- numbers for a period (same as the app's dashboard) ----------------------------
  if p_tool = 'crm_overview' then
    return jsonb_build_object(
      'period', private.mcp_ts(v_from) || ' to ' || private.mcp_ts(v_to - interval '1 minute'),
      'totals', jsonb_build_object(
        'leads_in_crm', (select count(*) from leads),
        'new_leads', (select count(*) from leads l where l.created_at >= v_from and l.created_at < v_to),
        'calls_made', (select count(*) from lead_activities a
                        where a.type = 'call' and coalesce(a.meta ->> 'direction', 'out') = 'out'
                          and a.created_at >= v_from and a.created_at < v_to),
        'admissions', (select count(*) from lead_activities a
                        where a.type = 'status' and a.created_at >= v_from and a.created_at < v_to
                          and a.meta ->> 'to' = any (v_won)),
        'unassigned_leads', (select count(*) from leads l where l.assigned_to is null),
        'new_and_never_called', (select count(*) from leads l where l.status = 'New' and l.last_contacted_at is null),
        'overdue_follow_ups', (select count(*) from reminders r where not r.is_done and r.remind_at < now())),
      'leads_by_status_now', (select coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb)
                                from (select status, count(*) as n from leads group by status) s),
      'new_leads_by_source', (select coalesce(jsonb_agg(row_to_json(x) order by x.leads desc), '[]'::jsonb)
                                from (select l.source, count(*) as leads,
                                             count(*) filter (where l.status = any (v_won)) as admission_done
                                        from leads l where l.created_at >= v_from and l.created_at < v_to group by l.source) x),
      'new_leads_by_campaign', (select coalesce(jsonb_agg(row_to_json(x) order by x.leads desc), '[]'::jsonb)
                                  from (select coalesce(nullif(l.source_detail, ''), 'Unknown') as campaign, l.source, count(*) as leads,
                                               count(*) filter (where l.status = any (v_won)) as admission_done
                                          from leads l where l.created_at >= v_from and l.created_at < v_to
                                         group by 1, 2 order by 3 desc limit 15) x),
      'why_leads_were_lost', (select coalesce(jsonb_agg(row_to_json(x) order by x.count desc), '[]'::jsonb)
                                from (select a.body as reason, count(*) as count from lead_activities a
                                       where a.type = 'lost_reason' and a.created_at >= v_from and a.created_at < v_to group by a.body) x));
  end if;

  -- ---- each agent ---------------------------------------------------------------------
  if p_tool = 'crm_team' then
    return jsonb_build_object(
      'period', private.mcp_ts(v_from) || ' to ' || private.mcp_ts(v_to - interval '1 minute'),
      'agents', (select coalesce(jsonb_agg(row_to_json(x) order by x.calls desc), '[]'::jsonb) from (
        select p.full_name as name, p.role, p.daily_call_target, p.monthly_admission_target,
               count(a.id) filter (where a.type = 'call' and coalesce(a.meta ->> 'direction', 'out') = 'out') as calls,
               count(a.id) filter (where a.type = 'call' and a.meta ->> 'direction' in ('out', 'in')
                                     and (a.meta ->> 'duration')::int > 0) as connected_calls,
               round(coalesce(sum((a.meta ->> 'duration')::int) filter (where a.type = 'call'), 0) / 60.0) as talk_minutes,
               count(a.id) filter (where a.type in ('whatsapp', 'sms', 'email')) as messages_opened,
               count(distinct a.lead_id) filter (where a.type in ('call', 'whatsapp', 'sms', 'email')) as leads_contacted,
               count(a.id) filter (where a.type = 'status' and a.meta ->> 'to' = any (v_won)) as admissions,
               (select count(*) from leads l where l.assigned_to = p.id) as leads_assigned,
               (select count(*) from leads l where l.assigned_to = p.id and l.status = 'New' and l.last_contacted_at is null) as new_and_never_called,
               (select count(*) from reminders r where r.user_id = p.id and not r.is_done and r.remind_at < now()) as overdue_follow_ups
          from profiles p
          left join lead_activities a on a.user_id = p.id and a.created_at >= v_from and a.created_at < v_to
         where p.is_active
         group by p.id) x));
  end if;

  -- ---- a list of leads ------------------------------------------------------------------
  if p_tool = 'crm_leads' then
    v_digits := regexp_replace(coalesce(v_search, ''), '\D', '', 'g');
    select coalesce(max(x.total), 0),
           coalesce(jsonb_agg(to_jsonb(x) - 'total' - 'sort_at' order by x.sort_at desc), '[]'::jsonb)
      into v_total, v_rows
      from (
        select l.id, l.name,
               private.mcp_phone(l.phone) as phone, private.mcp_email(l.email) as email,
               l.source, l.source_detail as campaign, l.status, l.temperature,
               (select p.full_name from profiles p where p.id = l.assigned_to) as agent,
               private.mcp_ts(l.created_at) as came_in,
               private.mcp_ts(l.last_contacted_at) as last_contacted,
               private.mcp_ts(l.next_follow_up_at) as next_follow_up,
               l.lost_reason, l.wa_state as whatsapp, l.webinar_state as webinar,
               case when l.webinar_state is null then null else l.webinar_paid end as webinar_paid,
               l.webinar_attended,
               l.created_at as sort_at,
               count(*) over () as total
          from leads l
         where l.created_at >= v_from and l.created_at < v_to
           and (v_args ->> 'status' is null or l.status = v_args ->> 'status')
           and (v_args ->> 'temperature' is null or l.temperature = v_args ->> 'temperature')
           and (v_args ->> 'source' is null or l.source = v_args ->> 'source')
           and (v_campaign is null or position(lower(v_campaign) in lower(coalesce(l.source_detail, ''))) > 0)
           and (v_agent is null
                or (lower(v_agent) = 'unassigned' and l.assigned_to is null)
                or l.assigned_to in (select p.id from profiles p where position(lower(v_agent) in lower(p.full_name)) > 0))
           and (v_args ->> 'webinar' is null or l.webinar_state = v_args ->> 'webinar')
           and (v_args ->> 'attended' is null
                or (v_args ->> 'attended' = 'yes' and l.webinar_attended is true)
                or (v_args ->> 'attended' = 'no' and l.webinar_attended is false))
           and (not coalesce((v_args ->> 'never_called')::boolean, false) or (l.status = 'New' and l.last_contacted_at is null))
           and (not coalesce((v_args ->> 'overdue_follow_up')::boolean, false)
                or exists (select 1 from reminders r where r.lead_id = l.id and not r.is_done and r.remind_at < now()))
           -- searching by e-mail or phone would reveal the hidden contact details one letter at a time
           and (v_search is null
                or position(lower(v_search) in lower(l.name)) > 0
                or (v_show and position(lower(v_search) in lower(coalesce(l.email, ''))) > 0)
                or (v_show and length(v_digits) >= 4 and position(v_digits in coalesce(l.phone_key, '')) > 0))
         order by l.created_at desc
         offset v_offset limit v_limit) x;
    return jsonb_build_object('total_matching', v_total, 'shown', jsonb_array_length(v_rows), 'offset', v_offset,
                              'contacts_hidden', not v_show, 'leads', v_rows);
  end if;

  -- ---- one lead in detail -------------------------------------------------------------------
  if p_tool = 'crm_lead' then
    select * into v_lead from leads where id = (v_args ->> 'lead_id')::uuid;
    if not found then
      return jsonb_build_object('error', 'No lead with this id');
    end if;
    return jsonb_build_object(
      'lead', jsonb_build_object(
        'id', v_lead.id, 'name', v_lead.name,
        'phone', private.mcp_phone(v_lead.phone), 'email', private.mcp_email(v_lead.email),
        'source', v_lead.source, 'campaign', v_lead.source_detail, 'status', v_lead.status, 'temperature', v_lead.temperature,
        'agent', (select p.full_name from profiles p where p.id = v_lead.assigned_to),
        'came_in', private.mcp_ts(v_lead.created_at), 'last_contacted', private.mcp_ts(v_lead.last_contacted_at),
        'next_follow_up', private.mcp_ts(v_lead.next_follow_up_at), 'lost_reason', v_lead.lost_reason,
        -- details from the lead form (without contact fields while contacts are hidden)
        'form_details', (select coalesce(jsonb_object_agg(e.key, private.mcp_text(e.value #>> '{}', 200)), '{}'::jsonb)
                           from jsonb_each(v_lead.extra) e
                          where v_show or e.key !~* '(phone|mobile|email|mail|whatsapp|contact|number|tel)'),
        'whatsapp_state', v_lead.wa_state, 'stopped_whatsapp', v_lead.wa_opt_out,
        'webinar', case when v_lead.webinar_state is null then null else jsonb_build_object(
          'state', v_lead.webinar_state, 'paid_rupees', v_lead.webinar_paid, 'title', v_lead.webinar_title, 'attended', v_lead.webinar_attended) end),
      'history', (select coalesce(jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at desc), '[]'::jsonb) from (
                    select a.type, private.mcp_text(coalesce(a.body, case when a.type = 'status' then (a.meta ->> 'from') || ' -> ' || (a.meta ->> 'to') end), 300) as text,
                           coalesce((select p.full_name from profiles p where p.id = a.user_id), 'System') as by,
                           private.mcp_ts(a.created_at) as at, a.created_at as sort_at
                      from lead_activities a where a.lead_id = v_lead.id order by a.created_at desc limit 25) x),
      'open_reminders', (select coalesce(jsonb_agg(jsonb_build_object('when', private.mcp_ts(r.remind_at), 'note', private.mcp_text(r.note, 200),
                                                                      'for', (select p.full_name from profiles p where p.id = r.user_id))
                                                   order by r.remind_at), '[]'::jsonb)
                           from reminders r where r.lead_id = v_lead.id and not r.is_done),
      'whatsapp_messages', (select coalesce(jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at desc), '[]'::jsonb) from (
                              select m.direction, m.type, private.mcp_text(m.body, 200) as text, m.status, private.mcp_ts(m.created_at) as at, m.created_at as sort_at
                                from wa_messages m where m.lead_id = v_lead.id order by m.created_at desc limit 10) x),
      'webinar_payments', (select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'rupees', coalesce(p.ticket_amount, p.total_charged),
                                                                        'refunded', p.refunded_amount, 'when', private.mcp_ts(coalesce(p.paid_at, p.created_at)))
                                                     order by p.created_at desc), '[]'::jsonb)
                             from webinar_payments p where p.lead_id = v_lead.id and not p.is_test));
  end if;

  if p_tool = 'crm_webinar' then
    return jsonb_build_object('period', private.mcp_ts(v_from) || ' to ' || private.mcp_ts(v_to - interval '1 minute'),
                              'note', 'money is in rupees, after refunds',
                              'webinar', private.webinar_stats_core(v_from, v_to),
                              'payments_not_found_in_webinar_gg', (select count(*) from webinar_payments where status = 'paid' and verified is false and not is_test));
  end if;

  if p_tool = 'crm_whatsapp' then
    return jsonb_build_object(
      'period', private.mcp_ts(v_from) || ' to ' || private.mcp_ts(v_to - interval '1 minute'),
      'messages', (select jsonb_build_object(
          'sent', count(*) filter (where m.direction = 'out' and m.status <> 'failed'),
          'delivered', count(*) filter (where m.direction = 'out' and m.delivered_at is not null),
          'opened', count(*) filter (where m.direction = 'out' and m.read_at is not null),
          'failed', count(*) filter (where m.direction = 'out' and m.status = 'failed'),
          'received_from_students', count(*) filter (where m.direction = 'in'),
          'students_who_replied', count(distinct m.lead_id) filter (where m.direction = 'in'))
        from wa_messages m where m.created_at >= v_from and m.created_at < v_to),
      'by_kind', (select coalesce(jsonb_agg(row_to_json(x) order by x.sent desc), '[]'::jsonb) from (
                    select m.kind, count(*) filter (where m.status <> 'failed') as sent,
                           count(*) filter (where m.delivered_at is not null) as delivered,
                           count(*) filter (where m.read_at is not null) as opened,
                           count(*) filter (where m.status = 'failed') as failed
                      from wa_messages m where m.direction = 'out' and m.created_at >= v_from and m.created_at < v_to group by m.kind) x),
      'by_template', (select coalesce(jsonb_agg(row_to_json(x) order by x.sent desc), '[]'::jsonb) from (
                        select coalesce(m.template_name, '?') as template, count(*) filter (where m.status <> 'failed') as sent,
                               count(*) filter (where m.delivered_at is not null) as delivered,
                               count(*) filter (where m.read_at is not null) as opened,
                               count(*) filter (where m.status = 'failed') as failed
                          from wa_messages m where m.direction = 'out' and m.type = 'template' and m.created_at >= v_from and m.created_at < v_to
                         group by 1 limit 15) x),
      'leads_by_whatsapp_state_now', (select coalesce(jsonb_object_agg(s.wa_state, s.n), '{}'::jsonb)
                                        from (select wa_state, count(*) as n from leads where wa_state <> 'none' group by wa_state) s));
  end if;

  return jsonb_build_object('error', 'Unknown tool');
end;
$$;

revoke execute on function public.mcp_call(text, jsonb) from public, anon, authenticated;
grant execute on function public.mcp_call(text, jsonb) to service_role;
