-- Claude connector, part 2: Claude can ASK for changes; the admin decides in the CRM app.
--   * Every kind of request has its own switch (integrations.mcp_perms), all off until the admin turns them on.
--   * Claude never changes anything itself: it writes a request into mcp_actions. The admin opens it in the app,
--     sees what it will do, and taps Approve or Reject. Approving runs the work with the admin's own login.
--   * Not offered at all: deleting, team / roles / passwords, keys and tokens, WhatsApp connection, the switches themselves.
--   * More reading: WhatsApp chats and the list of approved templates (chats have their own switch).

-- ---------------------------------------------------------------------------
-- Rate limit: a request now means a few calls in a row, so 60 a minute and 2000 a day
-- ---------------------------------------------------------------------------

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
  if v_min >= 60 or v_day >= 2000 then
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
-- Switches
-- ---------------------------------------------------------------------------

create or replace function private.mcp_perm(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value -> 'mcp_perms' ->> p_key)::boolean from app_settings where key = 'integrations'), false);
$$;

create or replace function public.mcp_set_perm(p_key text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if p_key not in ('read_chats', 'add_leads', 'edit_leads', 'change_status', 'add_remark', 'set_reminder', 'assign', 'wa_text', 'wa_template') then
    raise exception 'Unknown permission';
  end if;
  insert into app_settings (key, value)
  values ('integrations', jsonb_build_object('mcp_perms', jsonb_build_object(p_key, coalesce(p_on, false))))
  on conflict (key) do update
    set value = jsonb_set(app_settings.value, '{mcp_perms}',
                          coalesce(app_settings.value -> 'mcp_perms', '{}'::jsonb) || jsonb_build_object(p_key, coalesce(p_on, false))),
        updated_at = now();
end;
$$;

-- The most WhatsApp messages Claude's requests may add up to in one day (India time).
create or replace function public.mcp_set_wa_cap(p_cap int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if p_cap is null or p_cap < 1 or p_cap > 5000 then
    raise exception 'Choose a number from 1 to 5000';
  end if;
  insert into app_settings (key, value)
  values ('integrations', jsonb_build_object('mcp_wa_cap', p_cap))
  on conflict (key) do update set value = app_settings.value || excluded.value, updated_at = now();
end;
$$;

revoke execute on function public.mcp_set_perm(text, boolean) from public, anon;
revoke execute on function public.mcp_set_wa_cap(int) from public, anon;
grant execute on function public.mcp_set_perm(text, boolean) to authenticated;
grant execute on function public.mcp_set_wa_cap(int) to authenticated;

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

create table public.mcp_actions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  kind text not null check (kind in ('add_leads', 'edit_lead', 'set_status', 'add_remark', 'set_reminder', 'assign', 'wa_text', 'wa_template')),
  -- made by the server from the checked request, not written by Claude
  title text not null,
  -- exactly what the app will do (checked and resolved: lead ids, agent ids, real phone numbers)
  args jsonb not null,
  -- what the admin reads: {lines: [...], highlight: "...", recipients: n}
  preview jsonb not null default '{}'::jsonb,
  -- Claude's own words about why (shown with a label; never trusted)
  reason text,
  status text not null default 'pending' check (status in ('pending', 'running', 'done', 'failed', 'rejected', 'expired')),
  decided_at timestamptz,
  result text
);
create index mcp_actions_created_idx on public.mcp_actions (created_at desc);
create index mcp_actions_pending_idx on public.mcp_actions (created_at) where status = 'pending';
alter table public.mcp_actions enable row level security;
revoke all on public.mcp_actions from anon, authenticated;
grant select on public.mcp_actions to authenticated;
create policy mcp_actions_select on public.mcp_actions for select to authenticated using ((select public.is_admin()));

-- Approve: takes the request (only once, only while it waits and has not expired) and hands back what to do.
create or replace function public.mcp_claim_action(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row mcp_actions;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update mcp_actions
     set status = 'running', decided_at = now()
   where id = p_id and status = 'pending' and expires_at > now()
  returning * into v_row;
  if not found then
    raise exception 'This request was already decided, or it has expired';
  end if;
  return jsonb_build_object('id', v_row.id, 'kind', v_row.kind, 'args', v_row.args, 'preview', v_row.preview, 'title', v_row.title);
end;
$$;

create or replace function public.mcp_finish_action(p_id uuid, p_ok boolean, p_result text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update mcp_actions
     set status = case when p_ok then 'done' else 'failed' end, result = left(coalesce(p_result, ''), 500)
   where id = p_id and status = 'running';
end;
$$;

create or replace function public.mcp_reject_action(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update mcp_actions set status = 'rejected', decided_at = now() where id = p_id and status = 'pending';
  if not found then
    raise exception 'This request was already decided, or it has expired';
  end if;
end;
$$;

revoke execute on function public.mcp_claim_action(uuid) from public, anon;
revoke execute on function public.mcp_finish_action(uuid, boolean, text) from public, anon;
revoke execute on function public.mcp_reject_action(uuid) from public, anon;
grant execute on function public.mcp_claim_action(uuid) to authenticated;
grant execute on function public.mcp_finish_action(uuid, boolean, text) to authenticated;
grant execute on function public.mcp_reject_action(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Checking a request (one function for each kind). Each returns
--   {title, args, preview: {lines: [...], highlight}, recipients?}
-- or stops with a message Claude can act on.
-- ---------------------------------------------------------------------------

create or replace function private.mcp_who(l leads)
returns text
language sql
stable
as $$
  select coalesce(nullif(l.name, ''), l.phone, l.email, 'a lead');
$$;

-- Names of agents -> their ids, in the order given. One agent per name.
create or replace function private.mcp_agents(p_names jsonb)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
  v_ids uuid[] := '{}';
  v_found uuid[];
begin
  for v_name in select jsonb_array_elements_text(coalesce(p_names, '[]'::jsonb)) loop
    select array_agg(p.id) into v_found
      from profiles p
     where p.is_active and position(lower(trim(v_name)) in lower(p.full_name)) > 0;
    if v_found is null then
      raise exception 'There is no active team member called "%". Use crm_info to see the names.', v_name;
    end if;
    if array_length(v_found, 1) > 1 then
      -- "Ra" fits Ravi and Rahul: an exact name wins, otherwise ask for more letters
      select array_agg(p.id) into v_found from profiles p where p.is_active and lower(p.full_name) = lower(trim(v_name));
      if v_found is null or array_length(v_found, 1) <> 1 then
        raise exception 'More than one team member fits "%". Write the full name.', v_name;
      end if;
    end if;
    v_ids := v_ids || v_found[1];
  end loop;
  return v_ids;
end;
$$;

-- Lead ids that must all exist
create or replace function private.mcp_lead_ids(p_ids jsonb, p_max int)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_have int;
begin
  select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(p_ids, '[]'::jsonb)) x;
  if v_ids is null or array_length(v_ids, 1) = 0 then
    raise exception 'Give at least one lead id (from crm_leads)';
  end if;
  if array_length(v_ids, 1) > p_max then
    raise exception 'At most % leads in one request', p_max;
  end if;
  select count(*) into v_have from leads where id = any (v_ids);
  if v_have <> array_length(v_ids, 1) then
    raise exception '% of these lead ids do not exist', array_length(v_ids, 1) - v_have;
  end if;
  return v_ids;
end;
$$;

create or replace function private.mcp_day(p timestamptz)
returns text
language sql
immutable
as $$
  select to_char(p at time zone 'Asia/Kolkata', 'FMDD Mon YYYY, FMHH12:MI AM');
$$;

create or replace function private.mcp_prep_add_leads(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb := '[]'::jsonb;
  r jsonb;
  v_key text;
  v_email text;
  v_total int := 0;
  v_new int := 0;
  v_dupes int := 0;
  v_invalid int := 0;
  v_lines jsonb := '[]'::jsonb;
  v_agent uuid[];
  v_seen text[] := '{}';
  v_campaign text := nullif(trim(a ->> 'campaign'), '');
begin
  if jsonb_typeof(a -> 'leads') <> 'array' or jsonb_array_length(a -> 'leads') = 0 then
    raise exception 'Give the leads to add';
  end if;
  if jsonb_array_length(a -> 'leads') > 50 then
    raise exception 'At most 50 leads in one request';
  end if;
  if a ->> 'agent' is not null then
    v_agent := private.mcp_agents(jsonb_build_array(a ->> 'agent'));
  end if;

  for r in select * from jsonb_array_elements(a -> 'leads') loop
    v_total := v_total + 1;
    v_key := phone_key(r ->> 'phone');
    v_email := nullif(lower(trim(r ->> 'email')), '');
    if (v_key is null or length(v_key) < 10) and v_email is null then
      v_invalid := v_invalid + 1;
      continue;
    end if;
    if (v_key is not null and (exists (select 1 from leads where phone_key = v_key) or v_key = any (v_seen)))
       or (v_key is null and exists (select 1 from leads where lower(email) = v_email)) then
      v_dupes := v_dupes + 1;
      continue;
    end if;
    if v_key is not null then
      v_seen := v_seen || v_key;
    end if;
    v_new := v_new + 1;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'name', left(coalesce(r ->> 'name', ''), 80), 'phone', r ->> 'phone', 'email', v_email));
    if v_new <= 15 then
      v_lines := v_lines || to_jsonb(coalesce(nullif(r ->> 'name', ''), '(no name)') || ' · ' || coalesce(r ->> 'phone', v_email));
    end if;
  end loop;

  if v_new = 0 then
    raise exception 'Nothing to add: % already in the CRM, % without a valid phone or e-mail', v_dupes, v_invalid;
  end if;
  if v_new > 15 then
    v_lines := v_lines || to_jsonb('… and ' || (v_new - 15) || ' more');
  end if;
  if v_dupes > 0 then
    v_lines := v_lines || to_jsonb(v_dupes || ' already in the CRM (skipped)');
  end if;
  if v_invalid > 0 then
    v_lines := v_lines || to_jsonb(v_invalid || ' without a valid phone or e-mail (skipped)');
  end if;
  if v_agent is not null then
    v_lines := v_lines || to_jsonb('Given to: ' || (select full_name from profiles where id = v_agent[1]));
  end if;
  if v_campaign is not null then
    v_lines := v_lines || to_jsonb('Campaign label: ' || v_campaign);
  end if;

  return jsonb_build_object(
    'title', 'Add ' || v_new || ' new lead' || case when v_new = 1 then '' else 's' end,
    'args', jsonb_build_object('rows', v_rows, 'assign_to', v_agent[1], 'campaign', coalesce(v_campaign, 'Added by Claude')),
    'preview', jsonb_build_object('lines', v_lines));
end;
$$;

create or replace function private.mcp_prep_edit_lead(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
  v_values jsonb := '{}'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_key text;
  v_other leads;
begin
  select * into v_lead from leads where id = (a ->> 'lead_id')::uuid;
  if not found then
    raise exception 'No lead with this id';
  end if;
  if a ->> 'name' is not null then
    v_values := v_values || jsonb_build_object('name', left(trim(a ->> 'name'), 80));
    v_lines := v_lines || to_jsonb('Name: ' || coalesce(nullif(v_lead.name, ''), '(none)') || '  →  ' || left(trim(a ->> 'name'), 80));
  end if;
  if a ->> 'phone' is not null then
    v_key := phone_key(a ->> 'phone');
    if v_key is null or length(v_key) < 10 then
      raise exception 'This is not a valid phone number';
    end if;
    select * into v_other from leads where phone_key = v_key and id <> v_lead.id;
    if found then
      raise exception 'Another lead already has this number (%)', private.mcp_who(v_other);
    end if;
    v_values := v_values || jsonb_build_object('phone', a ->> 'phone');
    v_lines := v_lines || to_jsonb('Phone: ' || coalesce(v_lead.phone, '(none)') || '  →  ' || (a ->> 'phone'));
  end if;
  if a ->> 'email' is not null then
    v_values := v_values || jsonb_build_object('email', lower(trim(a ->> 'email')));
    v_lines := v_lines || to_jsonb('E-mail: ' || coalesce(v_lead.email, '(none)') || '  →  ' || lower(trim(a ->> 'email')));
  end if;
  if v_values = '{}'::jsonb then
    raise exception 'Say what to change: name, phone or email';
  end if;
  return jsonb_build_object(
    'title', 'Change the details of ' || private.mcp_who(v_lead),
    'args', jsonb_build_object('lead_id', v_lead.id, 'values', v_values),
    'preview', jsonb_build_object('lines', v_lines));
end;
$$;

create or replace function private.mcp_prep_set_status(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[] := private.mcp_lead_ids(a -> 'lead_ids', 50);
  v_status text := nullif(trim(a ->> 'status'), '');
  v_temp text := nullif(lower(trim(a ->> 'temperature')), '');
  v_reason text := nullif(trim(a ->> 'lost_reason'), '');
  v_st lead_statuses;
  v_lines jsonb := '[]'::jsonb;
  v_values jsonb := '{}'::jsonb;
  l leads;
  v_n int := 0;
begin
  if v_status is null and v_temp is null then
    raise exception 'Say the new status and / or hot, warm, cold';
  end if;
  if v_status is not null then
    select * into v_st from lead_statuses where lower(name) = lower(v_status);
    if not found then
      raise exception 'There is no status "%". Use crm_info to see them.', v_status;
    end if;
    v_status := v_st.name;
    if v_st.ask_reason and v_reason is null then
      raise exception 'The status "%" needs a reason: give lost_reason', v_status;
    end if;
    v_values := v_values || jsonb_build_object('status', v_status);
    if v_st.ask_reason then
      v_values := v_values || jsonb_build_object('lost_reason', left(v_reason, 80));
    end if;
  end if;
  if v_temp is not null then
    if v_temp not in ('hot', 'warm', 'cold', 'none') then
      raise exception 'Temperature must be hot, warm, cold or none';
    end if;
    v_values := v_values || jsonb_build_object('temperature', case when v_temp = 'none' then null else v_temp end);
  end if;

  for l in select * from leads where id = any (v_ids) order by created_at desc loop
    v_n := v_n + 1;
    if v_n <= 12 then
      v_lines := v_lines || to_jsonb(private.mcp_who(l) || ':  '
        || case when v_status is not null then l.status || ' → ' || v_status else '' end
        || case when v_temp is not null then (case when v_status is not null then '   ' else '' end)
             || coalesce(l.temperature, 'no tag') || ' → ' || v_temp else '' end);
    end if;
  end loop;
  if v_n > 12 then
    v_lines := v_lines || to_jsonb('… and ' || (v_n - 12) || ' more');
  end if;
  if v_values ? 'lost_reason' then
    v_lines := v_lines || to_jsonb('Reason: ' || (v_values ->> 'lost_reason'));
  end if;
  return jsonb_build_object(
    'title', 'Change ' || v_n || ' lead' || case when v_n = 1 then '' else 's' end
             || case when v_status is not null then ' to "' || v_status || '"' else '' end
             || case when v_temp is not null then (case when v_status is not null then ' and ' else ' to ' end) || v_temp else '' end,
    'args', jsonb_build_object('lead_ids', to_jsonb(v_ids), 'values', v_values),
    'preview', jsonb_build_object('lines', v_lines));
end;
$$;

create or replace function private.mcp_prep_add_remark(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
  v_text text := trim(coalesce(a ->> 'text', ''));
begin
  select * into v_lead from leads where id = (a ->> 'lead_id')::uuid;
  if not found then
    raise exception 'No lead with this id';
  end if;
  if length(v_text) < 1 or length(v_text) > 500 then
    raise exception 'The remark must be 1 to 500 characters';
  end if;
  return jsonb_build_object(
    'title', 'Write a remark on ' || private.mcp_who(v_lead),
    'args', jsonb_build_object('lead_id', v_lead.id, 'text', v_text),
    'preview', jsonb_build_object('lines', jsonb_build_array(v_text)));
end;
$$;

create or replace function private.mcp_prep_set_reminder(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
  v_at timestamptz;
  v_for uuid;
  v_message text := nullif(left(trim(coalesce(a ->> 'message', '')), 200), '');
begin
  select * into v_lead from leads where id = (a ->> 'lead_id')::uuid;
  if not found then
    raise exception 'No lead with this id';
  end if;
  v_at := (replace(a ->> 'when', 'T', ' ')::timestamp) at time zone 'Asia/Kolkata';
  if v_at <= now() then
    raise exception 'That time is already past (India time)';
  end if;
  if v_at > now() + interval '1 year' then
    raise exception 'The reminder is more than a year away';
  end if;
  if a ->> 'agent' is not null then
    v_for := (private.mcp_agents(jsonb_build_array(a ->> 'agent')))[1];
  else
    v_for := v_lead.assigned_to;
  end if;
  return jsonb_build_object(
    'title', 'Set a reminder for ' || private.mcp_who(v_lead),
    'args', jsonb_build_object('lead_id', v_lead.id, 'at', v_at, 'note', v_message, 'user_id', v_for),
    'preview', jsonb_build_object('lines', jsonb_build_array(
      'When: ' || private.mcp_day(v_at),
      'For: ' || coalesce((select full_name from profiles where id = v_for), 'you (the lead has no agent)'),
      'Note: ' || coalesce(v_message, '(none)'))));
end;
$$;

create or replace function private.mcp_prep_assign(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[] := private.mcp_lead_ids(a -> 'lead_ids', 100);
  v_agents uuid[] := private.mcp_agents(a -> 'agents');
  v_lines jsonb := '[]'::jsonb;
  v_names text;
  v_n int := array_length(v_ids, 1);
  v_moved int;
begin
  if coalesce(array_length(v_agents, 1), 0) = 0 then
    raise exception 'Say who gets the leads';
  end if;
  if (select count(distinct x) from unnest(v_agents) x) <> array_length(v_agents, 1) then
    raise exception 'The same team member is named twice';
  end if;
  select string_agg(full_name, ', ' order by ord) into v_names
    from unnest(v_agents) with ordinality as t(id, ord) join profiles p on p.id = t.id;
  select count(*) into v_moved from leads l
   where l.id = any (v_ids) and l.assigned_to is not null and l.assigned_to <> all (v_agents);
  v_lines := v_lines || to_jsonb(v_n || ' lead' || case when v_n = 1 then '' else 's' end || ' will be given to: ' || v_names
                                 || case when array_length(v_agents, 1) > 1 then ' (shared one by one in turn)' else '' end);
  if v_moved > 0 then
    v_lines := v_lines || to_jsonb(v_moved || ' of them are taken from another agent');
  end if;
  v_lines := v_lines || (
    select coalesce(jsonb_agg(to_jsonb(private.mcp_who(l) || ':  ' || coalesce((select full_name from profiles where id = l.assigned_to), 'nobody') || ' → ' || v_names)
                              order by l.created_at desc), '[]'::jsonb)
      from leads l
     where l.id in (select id from leads where id = any (v_ids) order by created_at desc limit 8)
       and array_length(v_agents, 1) = 1);
  return jsonb_build_object(
    'title', 'Give ' || v_n || ' lead' || case when v_n = 1 then '' else 's' end || ' to ' || v_names,
    'args', jsonb_build_object('lead_ids', to_jsonb(v_ids), 'agent_ids', to_jsonb(v_agents)),
    'preview', jsonb_build_object('lines', v_lines));
end;
$$;

create or replace function private.mcp_wa_ready()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    raise exception 'WhatsApp is not connected in the CRM';
  end if;
end;
$$;

create or replace function private.mcp_prep_wa_text(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
  v_text text := trim(coalesce(a ->> 'text', ''));
begin
  perform private.mcp_wa_ready();
  select * into v_lead from leads where id = (a ->> 'lead_id')::uuid;
  if not found then
    raise exception 'No lead with this id';
  end if;
  if v_lead.phone is null then
    raise exception 'This lead has no phone number';
  end if;
  if v_lead.wa_opt_out then
    raise exception 'This student asked to stop WhatsApp messages';
  end if;
  if v_lead.wa_last_inbound_at is null or v_lead.wa_last_inbound_at < now() - interval '24 hours' then
    raise exception 'The 24-hour window is closed (the student has not written in the last 24 hours). Ask for a template instead.';
  end if;
  if length(v_text) < 1 or length(v_text) > 1000 then
    raise exception 'The message must be 1 to 1000 characters';
  end if;
  return jsonb_build_object(
    'title', 'WhatsApp message to ' || private.mcp_who(v_lead),
    'args', jsonb_build_object('lead_id', v_lead.id, 'text', v_text),
    'preview', jsonb_build_object('lines', jsonb_build_array(v_text), 'highlight', 'Goes out at once, free (inside the 24-hour window)'),
    'recipients', 1);
end;
$$;

create or replace function private.mcp_prep_wa_template(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tpl wa_templates;
  v_entries jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  l leads;
  e jsonb;
  v_key text;
  v_n int := 0;
  v_skipped int := 0;
  v_lines jsonb := '[]'::jsonb;
  v_price numeric;
  v_values jsonb := coalesce(a -> 'values', '{}'::jsonb);
  v_new_numbers int := 0;
begin
  perform private.mcp_wa_ready();
  select * into v_tpl from wa_templates where lower(name) = lower(trim(a ->> 'template')) and status = 'APPROVED' order by created_at desc limit 1;
  if not found then
    raise exception 'There is no approved template called "%". Use crm_templates to see them.', a ->> 'template';
  end if;
  perform private.wa_check_asked(v_tpl.id, v_values);

  for l in select * from leads where id = any (coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(coalesce(a -> 'lead_ids', '[]'::jsonb)) x), '{}')) loop
    if l.phone is null or l.wa_opt_out or l.phone_key = any (v_seen) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_seen := v_seen || l.phone_key;
    v_entries := v_entries || jsonb_build_array(jsonb_build_object('phone', l.phone, 'name', l.name));
    v_n := v_n + 1;
    if v_n <= 12 then
      v_lines := v_lines || to_jsonb(private.mcp_who(l));
    end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(a -> 'numbers', '[]'::jsonb)) loop
    v_key := phone_key(e ->> 'phone');
    if v_key is null or length(v_key) < 10 then
      raise exception '"%" is not a valid phone number', e ->> 'phone';
    end if;
    if v_key = any (v_seen) then
      continue;
    end if;
    if exists (select 1 from leads where phone_key = v_key and wa_opt_out) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_seen := v_seen || v_key;
    if not exists (select 1 from leads where phone_key = v_key) then
      v_new_numbers := v_new_numbers + 1;
    end if;
    v_entries := v_entries || jsonb_build_array(jsonb_build_object('phone', e ->> 'phone', 'name', coalesce(e ->> 'name', '')));
    v_n := v_n + 1;
    if v_n <= 12 then
      v_lines := v_lines || to_jsonb(coalesce(nullif(e ->> 'name', ''), '(new)') || ' · ' || (e ->> 'phone'));
    end if;
  end loop;

  if v_n = 0 then
    raise exception 'Nobody to send to (no phone number, or they asked to stop)';
  end if;
  if v_n > 50 then
    raise exception 'At most 50 people in one request';
  end if;
  if v_n > 12 then
    v_lines := v_lines || to_jsonb('… and ' || (v_n - 12) || ' more');
  end if;
  if v_skipped > 0 then
    v_lines := v_lines || to_jsonb(v_skipped || ' left out (no phone, asked to stop, or listed twice)');
  end if;
  if v_new_numbers > 0 then
    v_lines := v_lines || to_jsonb(v_new_numbers || ' number' || case when v_new_numbers = 1 then ' is' else 's are' end || ' not in the CRM yet and will be added as new leads');
  end if;
  select coalesce((value ->> case when v_tpl.category = 'UTILITY' then 'price_utility' else 'price_marketing' end)::numeric,
                  case when v_tpl.category = 'UTILITY' then 0.15 else 0.9 end)
    into v_price from app_settings where key = 'whatsapp';
  v_price := coalesce(v_price, case when v_tpl.category = 'UTILITY' then 0.15 else 0.9 end);
  v_lines := v_lines || to_jsonb('Template: ' || v_tpl.name || ' (' || initcap(lower(v_tpl.category)) || ')');
  v_lines := v_lines || to_jsonb('Message: ' || left(coalesce(v_tpl.spec ->> 'body', ''), 300));
  if v_values <> '{}'::jsonb then
    v_lines := v_lines || to_jsonb('Filled in: ' || (select string_agg(k || ' = ' || v, ', ') from jsonb_each_text(v_values) t(k, v)));
  end if;
  return jsonb_build_object(
    'title', 'WhatsApp template "' || v_tpl.name || '" to ' || v_n || ' ' || case when v_n = 1 then 'person' else 'people' end,
    'args', jsonb_build_object('template_id', v_tpl.id, 'template_name', v_tpl.name, 'entries', v_entries, 'values', v_values),
    'preview', jsonb_build_object('lines', v_lines, 'highlight', 'Costs about ₹' || round(v_n * v_price) || ' (₹' || v_price || ' each)'),
    'recipients', v_n);
end;
$$;

-- ---------------------------------------------------------------------------
-- Claude asks. Only this function writes requests, and only service_role may call it.
-- ---------------------------------------------------------------------------

create or replace function public.mcp_propose(p_kind text, p_args jsonb, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perm text;
  v_gate text;
  v_prep jsonb;
  v_id uuid;
  v_today timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_cap int;
  v_used int;
  v_n int;
begin
  v_perm := case p_kind
    when 'add_leads' then 'add_leads' when 'edit_lead' then 'edit_leads' when 'set_status' then 'change_status'
    when 'add_remark' then 'add_remark' when 'set_reminder' then 'set_reminder' when 'assign' then 'assign'
    when 'wa_text' then 'wa_text' when 'wa_template' then 'wa_template' else null end;
  if v_perm is null then
    return jsonb_build_object('error', 'Unknown request');
  end if;
  v_gate := private.mcp_gate('propose_' || p_kind, jsonb_build_object('kind', p_kind));
  if v_gate is not null then
    return jsonb_build_object('error', v_gate);
  end if;
  if not private.mcp_perm(v_perm) then
    return jsonb_build_object('error', 'This permission is switched off. The owner can switch it on in the CRM app: More > Claude connector > Permissions.');
  end if;

  update mcp_actions set status = 'expired' where status = 'pending' and expires_at < now();
  select count(*) into v_n from mcp_actions where status = 'pending';
  if v_n >= 20 then
    return jsonb_build_object('error', 'Too many requests are waiting for the owner. Ask the owner to approve or reject some first.');
  end if;
  select count(*) into v_n from mcp_actions where created_at > now() - interval '1 day';
  if v_n >= 100 then
    return jsonb_build_object('error', 'Too many requests today. Try again tomorrow.');
  end if;

  begin
    v_prep := case p_kind
      when 'add_leads' then private.mcp_prep_add_leads(p_args)
      when 'edit_lead' then private.mcp_prep_edit_lead(p_args)
      when 'set_status' then private.mcp_prep_set_status(p_args)
      when 'add_remark' then private.mcp_prep_add_remark(p_args)
      when 'set_reminder' then private.mcp_prep_set_reminder(p_args)
      when 'assign' then private.mcp_prep_assign(p_args)
      when 'wa_text' then private.mcp_prep_wa_text(p_args)
      when 'wa_template' then private.mcp_prep_wa_template(p_args)
    end;
  exception when others then
    return jsonb_build_object('error', sqlerrm);
  end;

  -- WhatsApp: a day's limit for everything Claude asks for
  if p_kind in ('wa_text', 'wa_template') then
    v_cap := coalesce((select (value ->> 'mcp_wa_cap')::int from app_settings where key = 'integrations'), 200);
    select coalesce(sum((preview ->> 'recipients')::int), 0) into v_used
      from mcp_actions where kind in ('wa_text', 'wa_template') and created_at >= v_today and status in ('pending', 'running', 'done');
    if v_used + (v_prep ->> 'recipients')::int > v_cap then
      return jsonb_build_object('error', 'The daily WhatsApp limit for Claude (' || v_cap || ') would be passed: ' || v_used
        || ' already asked for today. The owner can raise it in the CRM app.');
    end if;
  end if;

  insert into mcp_actions (kind, title, args, preview, reason)
  values (p_kind, v_prep ->> 'title', v_prep -> 'args',
          (v_prep -> 'preview') || case when v_prep ? 'recipients' then jsonb_build_object('recipients', (v_prep ->> 'recipients')::int) else '{}'::jsonb end,
          left(nullif(trim(coalesce(p_reason, '')), ''), 300))
  returning id into v_id;

  perform private.push((
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', a.id,
             'title', 'Claude needs your OK',
             'body', v_prep ->> 'title',
             'data', jsonb_build_object('open', 'claude'))), '[]'::jsonb)
      from private.admin_ids() a(id)));

  return jsonb_build_object(
    'request_id', v_id,
    'status', 'waiting_for_owner',
    'summary', v_prep ->> 'title',
    'message', 'NOT DONE YET. This is only a request. The owner must open the CRM app > More > Claude connector > Requests and tap Approve. '
               || 'Tell the owner, and check later with crm_requests.');
end;
$$;

revoke execute on function public.mcp_propose(text, jsonb, text) from public, anon, authenticated;
grant execute on function public.mcp_propose(text, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
-- Reading: chats, templates and the state of Claude's own requests
-- (mcp_call from migration 0013 gets these tools; the permission is checked here)
-- ---------------------------------------------------------------------------

create or replace function private.mcp_read_more(p_tool text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce((p_args ->> 'limit')::int, 25), 1), 60);
  v_lead leads;
begin
  if p_tool in ('crm_chats', 'crm_chat') and not private.mcp_perm('read_chats') then
    return jsonb_build_object('error', 'Reading WhatsApp chats is switched off. The owner can switch it on in the CRM app: More > Claude connector > Permissions.');
  end if;

  if p_tool = 'crm_chats' then
    return jsonb_build_object('chats', (
      select coalesce(jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at desc), '[]'::jsonb) from (
        select l.id, l.name, private.mcp_phone(l.phone) as phone,
               (select p.full_name from profiles p where p.id = l.assigned_to) as agent,
               case when l.wa_last_direction = 'in' then 'student wrote last' else 'we wrote last' end as last,
               private.mcp_text(l.wa_last_text, 160) as last_message, private.mcp_ts(l.wa_last_message_at) as at,
               l.wa_unread as unread, l.wa_state as state,
               (l.wa_last_inbound_at is not null and l.wa_last_inbound_at > now() - interval '24 hours') as can_reply_freely,
               l.wa_opt_out as stopped, l.wa_last_message_at as sort_at
          from leads l
         where l.wa_last_message_at is not null
           and (not coalesce((p_args ->> 'unread_only')::boolean, false) or l.wa_unread > 0)
         order by l.wa_last_message_at desc
         limit v_limit) x));
  end if;

  if p_tool = 'crm_chat' then
    select * into v_lead from leads where id = (p_args ->> 'lead_id')::uuid;
    if not found then
      return jsonb_build_object('error', 'No lead with this id');
    end if;
    return jsonb_build_object(
      'lead', jsonb_build_object('id', v_lead.id, 'name', v_lead.name, 'phone', private.mcp_phone(v_lead.phone),
                                 'status', v_lead.status, 'stopped_whatsapp', v_lead.wa_opt_out,
                                 'can_reply_freely', (v_lead.wa_last_inbound_at is not null and v_lead.wa_last_inbound_at > now() - interval '24 hours')),
      'messages', (select coalesce(jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at), '[]'::jsonb) from (
        select m.direction, m.kind, m.type, private.mcp_text(m.body, 500) as text, m.template_name as template, m.status,
               private.mcp_ts(m.created_at) as at, m.created_at as sort_at
          from wa_messages m where m.lead_id = v_lead.id order by m.created_at desc limit v_limit) x));
  end if;

  if p_tool = 'crm_templates' then
    return jsonb_build_object('templates', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) from (
        select t.name, t.category, t.language, t.spec ->> 'body' as body,
               coalesce((select jsonb_agg(distinct lower(m[1])) from regexp_matches(
                           coalesce(t.spec ->> 'body', '') || ' ' || coalesce(t.spec -> 'header' ->> 'text', ''), '\{ask\.([A-Za-z][A-Za-z0-9_]*)\}', 'g') m), '[]'::jsonb) as fill_in,
               t.spec -> 'header' ->> 'type' as header
          from wa_templates t where t.status = 'APPROVED') x),
      'note', 'fill_in lists the details you must give in "values" when sending. {first_name}, {name} and similar are filled by the CRM.');
  end if;

  if p_tool = 'crm_requests' then
    update mcp_actions set status = 'expired' where status = 'pending' and expires_at < now();
    return jsonb_build_object('requests', (
      select coalesce(jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at desc), '[]'::jsonb) from (
        select a.id as request_id, a.kind, a.title, a.status, private.mcp_ts(a.created_at) as asked_at,
               private.mcp_ts(a.decided_at) as decided_at, a.result, a.created_at as sort_at
          from mcp_actions a
         where (p_args ->> 'request_id' is null or a.id = (p_args ->> 'request_id')::uuid)
         order by a.created_at desc limit 20) x),
      'status_meaning', jsonb_build_object('pending', 'waiting for the owner', 'running', 'approved, being done now',
                                          'done', 'done', 'failed', 'approved but it did not work (see result)',
                                          'rejected', 'the owner said no', 'expired', 'nobody answered within 24 hours'));
  end if;

  return jsonb_build_object('error', 'Unknown tool');
end;
$$;

-- ---------------------------------------------------------------------------
-- What the edge function calls for reading (the older tools go on to mcp_call)
-- ---------------------------------------------------------------------------

create or replace function public.mcp_read(p_tool text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_gate text;
  v_res jsonb;
begin
  if p_tool in ('crm_chats', 'crm_chat', 'crm_templates', 'crm_requests') then
    v_gate := private.mcp_gate(p_tool, v_args);
    if v_gate is not null then
      return jsonb_build_object('error', v_gate);
    end if;
    return private.mcp_read_more(p_tool, v_args);
  end if;

  v_res := public.mcp_call(p_tool, v_args);

  -- the last WhatsApp messages of a lead are chats: only while reading chats is switched on
  if p_tool = 'crm_lead' and v_res ? 'whatsapp_messages' and not private.mcp_perm('read_chats') then
    v_res := (v_res - 'whatsapp_messages') || jsonb_build_object('whatsapp_messages', 'hidden: reading WhatsApp chats is switched off in the CRM app');
  end if;
  -- so Claude knows what it may ask for
  if p_tool = 'crm_info' and v_res ? 'total_leads' then
    v_res := v_res || jsonb_build_object(
      'switched_on', (select coalesce(jsonb_agg(k order by k), '[]'::jsonb)
                        from unnest(array['read_chats', 'add_leads', 'edit_leads', 'change_status', 'add_remark', 'set_reminder', 'assign', 'wa_text', 'wa_template']) k
                       where private.mcp_perm(k)),
      'changes_need_owner_approval', true);
  end if;
  return v_res;
end;
$$;

revoke execute on function public.mcp_read(text, jsonb) from public, anon, authenticated;
grant execute on function public.mcp_read(text, jsonb) to service_role;
