-- Claude can build a whole WhatsApp flow (part 3 of the Claude connector):
--   * a template as a DRAFT (the owner sends it to Meta himself), with its buttons,
--   * the automatic replies those buttons lead to (and what each button does: reply, status, hot/warm/cold ...),
--   * an automatic reminder rule: "N minutes after a lead from landing page X arrives, if he has not paid, send template T".
-- A reminder rule is saved PAUSED; the owner switches it on in More > WhatsApp once Meta has approved the template.
-- Everything still goes through "Claude's requests": nothing is made until the owner taps Approve.

alter table public.mcp_actions drop constraint mcp_actions_kind_check;
alter table public.mcp_actions add constraint mcp_actions_kind_check check (kind in (
  'add_leads', 'edit_lead', 'set_status', 'add_remark', 'set_reminder', 'assign', 'wa_text', 'wa_template', 'wa_flow', 'wa_rule'));

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
  if p_key not in ('read_chats', 'add_leads', 'edit_leads', 'change_status', 'add_remark', 'set_reminder', 'assign',
                   'wa_text', 'wa_template', 'wa_build', 'wa_rules') then
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

-- ---------------------------------------------------------------------------
-- Checking a flow request. The edge function has already checked the shape, made the ids and written the lines
-- the owner reads; this is the second look, against the real tables.
-- ---------------------------------------------------------------------------

create or replace function private.mcp_prep_wa_flow(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tpl jsonb := a -> 'template';
  v_replies jsonb := coalesce(a -> 'replies', '[]'::jsonb);
  v_has_tpl boolean := v_tpl is not null and jsonb_typeof(v_tpl) = 'object';
  v_n int;
  v_bad text;
  v_title text;
begin
  if jsonb_typeof(v_replies) <> 'array' then
    raise exception 'The replies must be a list';
  end if;
  v_n := jsonb_array_length(v_replies);
  if not v_has_tpl and v_n = 0 then
    raise exception 'Give a template and / or auto-replies to build';
  end if;
  if v_n > 12 then
    raise exception 'At most 12 auto-replies in one request';
  end if;
  if v_has_tpl and exists (select 1 from wa_templates where name = v_tpl ->> 'name' and language = coalesce(v_tpl ->> 'language', 'en')) then
    raise exception 'A template called "%" already exists in this language. Choose another name.', v_tpl ->> 'name';
  end if;

  -- every status named in a button must exist
  select s #>> '{}' into v_bad
    from jsonb_path_query(a - 'lines', '$.**.status') s
   where not exists (select 1 from lead_statuses where name = s #>> '{}')
   limit 1;
  if v_bad is not null then
    raise exception 'There is no status "%". Use crm_info to see them.', v_bad;
  end if;
  -- every reply a button leads to must exist (an old one, or one made in this request)
  select s #>> '{}' into v_bad
    from jsonb_path_query(a - 'lines', '$.**.next') s
   where not exists (select 1 from wa_nodes where id::text = s #>> '{}')
     and not exists (select 1 from jsonb_array_elements(v_replies) r where r ->> 'id' = s #>> '{}')
   limit 1;
  if v_bad is not null then
    raise exception 'A button leads to a reply that does not exist';
  end if;

  v_title := case
    when v_has_tpl and v_n > 0 then 'Build WhatsApp template "' || (v_tpl ->> 'name') || '" and ' || v_n || ' auto-repl' || case when v_n = 1 then 'y' else 'ies' end
    when v_has_tpl then 'Build WhatsApp template "' || (v_tpl ->> 'name') || '"'
    else 'Add ' || v_n || ' WhatsApp auto-repl' || case when v_n = 1 then 'y' else 'ies' end
  end;
  return jsonb_build_object(
    'title', v_title,
    'args', a - 'lines',
    'preview', jsonb_build_object(
      'lines', coalesce(a -> 'lines', '[]'::jsonb),
      'highlight', case when v_has_tpl then 'Nothing goes to Meta or to students. The template is saved as a DRAFT: you send it to Meta yourself.'
                        else 'Nothing is sent to anyone. The replies only go out when a student taps a button.' end));
end;
$$;

create or replace function private.mcp_after_text(p_minutes int)
returns text
language sql
immutable
as $$
  select case
    when p_minutes < 60 then p_minutes || ' minute' || case when p_minutes = 1 then '' else 's' end
    when p_minutes % 60 = 0 then (p_minutes / 60) || ' hour' || case when p_minutes = 60 then '' else 's' end
    else (p_minutes / 60) || ' h ' || (p_minutes % 60) || ' min'
  end;
$$;

create or replace function private.mcp_hour_text(p_hour int)
returns text
language sql
immutable
as $$
  select case when p_hour % 24 = 0 then '12 AM' when p_hour % 24 < 12 then (p_hour % 24) || ' AM' when p_hour % 24 = 12 then '12 PM' else (p_hour % 24 - 12) || ' PM' end;
$$;

create or replace function private.mcp_prep_wa_rule(a jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tpl wa_templates;
  v_name text := trim(coalesce(a ->> 'name', ''));
  v_match text := trim(coalesce(a ->> 'landing', ''));
  v_source text := nullif(trim(coalesce(a ->> 'source', '')), '');
  v_after int := (a ->> 'after_minutes')::int;
  v_only text := coalesce(a ->> 'only_if', 'not_paid');
  v_start int := coalesce((a ->> 'start_hour')::int, 9);
  v_end int := coalesce((a ->> 'end_hour')::int, 21);
  v_lines jsonb := '[]'::jsonb;
  v_rule jsonb;
begin
  if v_name = '' or length(v_name) > 60 then
    raise exception 'Give the rule a name (up to 60 characters)';
  end if;
  if v_after is null or v_after < 5 or v_after > 4320 then
    raise exception 'after_minutes must be from 5 to 4320 (3 days)';
  end if;
  if v_only not in ('not_paid', 'no_reply', 'not_paid_no_reply', 'always') then
    raise exception 'only_if must be not_paid, no_reply, not_paid_no_reply or always';
  end if;
  if v_start < 0 or v_start > 23 or v_end < 1 or v_end > 24 or v_end <= v_start then
    raise exception 'The sending hours are not valid (start 0-23, end 1-24, end after start)';
  end if;
  select * into v_tpl from wa_templates
   where lower(name) = lower(trim(a ->> 'template')) order by (language = 'en') desc, created_at desc limit 1;
  if not found then
    raise exception 'There is no template called "%". Build it first (crm_whatsapp_build) and let the owner approve that request.', a ->> 'template';
  end if;
  if v_tpl.status in ('REJECTED', 'DISABLED', 'PAUSED') then
    raise exception 'The template "%" is % at Meta and cannot be used', v_tpl.name, lower(v_tpl.status);
  end if;
  if coalesce(v_tpl.spec ->> 'body', '') || ' ' || coalesce(v_tpl.spec -> 'header' ->> 'text', '') ~* '\{ask\.' then
    raise exception 'This template has fill-in details ({ask.x}). An automatic message cannot ask anyone for them.';
  end if;

  v_lines := v_lines
    || to_jsonb('Who: ' || case when v_match = '' then 'every new lead' else 'leads whose landing page / campaign name contains "' || v_match || '"' end
                || case when v_source is not null then ' (source: ' || v_source || ')' else '' end)
    || to_jsonb('When: ' || private.mcp_after_text(v_after) || ' after the lead arrives')
    || to_jsonb('Only if: ' || case v_only
         when 'not_paid' then 'the student has not paid the webinar fee yet'
         when 'no_reply' then 'the student has not written to you on WhatsApp'
         when 'not_paid_no_reply' then 'the student has not paid and has not written to you'
         else 'always' end)
    || to_jsonb('Sends: template "' || v_tpl.name || '" (' || initcap(lower(v_tpl.category)) || ', ' || v_tpl.status || ')')
    || to_jsonb('Between ' || private.mcp_hour_text(v_start) || ' and ' || private.mcp_hour_text(v_end) || ' India time. A lead who arrives at night gets it in the morning (up to 3 days later).')
    || to_jsonb('Closed leads (admission done, not interested ...) and students who asked to stop are skipped.'::text)
    || to_jsonb('It starts PAUSED. After Meta approves the template, you switch it on in More > WhatsApp > Automatic reminders.'::text);

  v_rule := jsonb_build_object(
    'id', replace(gen_random_uuid()::text, '-', ''),
    'name', v_name, 'match', v_match, 'source', v_source, 'after_minutes', v_after, 'only_if', v_only,
    'template_id', v_tpl.id, 'template_name', v_tpl.name, 'start_hour', v_start, 'end_hour', v_end,
    'enabled', false, 'by', 'claude');
  return jsonb_build_object(
    'title', 'Automatic reminder "' || v_name || '"',
    'args', v_rule,
    'preview', jsonb_build_object('lines', v_lines, 'highlight', 'Saved paused: nothing is sent until you switch it on.'));
end;
$$;

-- ---------------------------------------------------------------------------
-- What Claude may look at to learn the system: templates (with what each button does), replies, automation
-- ---------------------------------------------------------------------------

-- 'sends reply "Fees info", status Interested, hot'
create or replace function private.mcp_does(a jsonb)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(concat_ws(', ',
    case when a ->> 'next' is not null then 'sends reply "' || coalesce((select name from wa_nodes where id::text = a ->> 'next'), '(deleted reply)') || '"' end,
    case when a ->> 'status' is not null then 'status ' || (a ->> 'status') end,
    case when a ->> 'temperature' is not null then a ->> 'temperature' end,
    case when a ->> 'lost_reason' is not null then 'reason "' || (a ->> 'lost_reason') || '"' end,
    case when a ->> 'callback_hours' is not null then 'reminds the agent to call in ' || (a ->> 'callback_hours') || ' h' end,
    case when (a ->> 'optout')::boolean then 'stops messages' end), ''), 'nothing');
$$;

create or replace function private.mcp_wa_system()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'templates', (select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) from (
      select t.name, t.language, t.category, t.status, t.reason as meta_reason,
             t.spec -> 'header' ->> 'type' as header_type, t.spec -> 'header' ->> 'text' as header_text,
             t.spec ->> 'body' as body, t.spec ->> 'footer' as footer,
             t.spec -> 'examples' as examples,
             (select coalesce(jsonb_agg(jsonb_build_object(
                'type', b ->> 'type', 'text', b ->> 'text', 'url', b ->> 'url', 'phone', b ->> 'phone',
                'when_tapped', case when b ->> 'type' = 'quick_reply' then private.mcp_does(b -> 'action') end)), '[]'::jsonb)
                from jsonb_array_elements(coalesce(t.spec -> 'buttons', '[]'::jsonb)) b) as buttons
        from wa_templates t) x),
    'replies', (select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) from (
      select n.id, n.name, n.kind, n.header, n.body, n.footer, n.media_type,
             (select coalesce(jsonb_agg(jsonb_build_object('title', b ->> 'title', 'when_tapped', private.mcp_does(b -> 'action'))), '[]'::jsonb)
                from jsonb_array_elements(n.buttons) b) as buttons,
             n.list_button,
             (select coalesce(jsonb_agg(jsonb_build_object('section', s ->> 'title', 'rows', (
                select coalesce(jsonb_agg(jsonb_build_object('title', r ->> 'title', 'description', r ->> 'description', 'when_tapped', private.mcp_does(r -> 'action'))), '[]'::jsonb)
                  from jsonb_array_elements(coalesce(s -> 'rows', '[]'::jsonb)) r))), '[]'::jsonb)
                from jsonb_array_elements(n.sections) s) as list_sections
        from wa_nodes n) x),
    'automation', (select jsonb_build_object(
        'welcome_message_on', coalesce((value ->> 'auto_send')::boolean, false),
        'welcome_template', (select name from wa_templates where id::text = value ->> 'auto_template_id'),
        'welcome_by_landing_page', (select coalesce(jsonb_agg(jsonb_build_object('page_contains', r ->> 'match',
                                      'template', (select name from wa_templates where id::text = r ->> 'template_id'))), '[]'::jsonb)
                                      from jsonb_array_elements(coalesce(value -> 'rules', '[]'::jsonb)) r),
        'follow_ups_on', coalesce((value -> 'followups' ->> 'enabled')::boolean, false),
        'follow_ups', (select coalesce(jsonb_agg(jsonb_build_object('after_hours', st ->> 'after_hours',
                         'template', (select name from wa_templates where id::text = st ->> 'template_id'))), '[]'::jsonb)
                         from jsonb_array_elements(coalesce(value -> 'followups' -> 'steps', '[]'::jsonb)) st),
        'automatic_reminders', (select coalesce(jsonb_agg(jsonb_build_object(
                         'name', nd ->> 'name', 'on', coalesce((nd ->> 'enabled')::boolean, false),
                         'page_contains', nd ->> 'match', 'after_minutes', nd ->> 'after_minutes', 'only_if', nd ->> 'only_if',
                         'template', nd ->> 'template_name')), '[]'::jsonb)
                         from jsonb_array_elements(coalesce(value -> 'nudges', '[]'::jsonb)) nd))
      from app_settings where key = 'whatsapp'),
    'statuses', (select coalesce(jsonb_agg(name order by sort_order, id), '[]'::jsonb) from lead_statuses),
    'landing_pages_and_campaigns', (select coalesce(jsonb_agg(jsonb_build_object('source', x.source, 'name', x.d, 'leads', x.n) order by x.n desc), '[]'::jsonb)
                                      from (select source, source_detail as d, count(*) as n from leads where source_detail is not null group by 1, 2 order by 3 desc limit 30) x));
$$;

-- ---------------------------------------------------------------------------
-- The automatic reminder: "N minutes after a lead arrives, if he has not paid, send template T"
-- Rules live in app_settings.whatsapp.nudges. Each runs only for leads that arrived after it was switched on.
-- ---------------------------------------------------------------------------

alter table public.wa_outbox add column rule_id text;
create index wa_outbox_rule_idx on public.wa_outbox (rule_id, lead_id) where rule_id is not null;

create or replace function private.wa_nudges()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
  n jsonb;
  v_hour int := extract(hour from now() at time zone 'Asia/Kolkata');
  v_cap int;
  v_used int;
  v_tpl uuid;
  v_count int;
  v_total int := 0;
begin
  select value into v_cfg from app_settings where key = 'whatsapp';
  if jsonb_typeof(v_cfg -> 'nudges') is distinct from 'array'
     or not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    return;
  end if;
  -- the same spending guard as the welcome message
  v_cap := coalesce((v_cfg ->> 'auto_daily_cap')::int, 300);
  select count(*) into v_used from wa_outbox where kind in ('auto', 'nudge') and created_at > now() - interval '24 hours';

  for n in select * from jsonb_array_elements(v_cfg -> 'nudges') loop
    continue when not coalesce((n ->> 'enabled')::boolean, false);
    continue when nullif(n ->> 'enabled_at', '') is null or nullif(n ->> 'id', '') is null;
    continue when v_hour < coalesce((n ->> 'start_hour')::int, 9) or v_hour >= coalesce((n ->> 'end_hour')::int, 21);
    continue when v_used >= v_cap;
    v_tpl := nullif(n ->> 'template_id', '')::uuid;
    continue when v_tpl is null or not exists (select 1 from wa_templates where id = v_tpl and status = 'APPROVED');

    with due as (
      select l.id
        from leads l
       where l.created_at >= (n ->> 'enabled_at')::timestamptz
         and l.created_at <= now() - make_interval(mins => coalesce((n ->> 'after_minutes')::int, 60))
         and l.created_at > now() - interval '3 days'
         and l.phone is not null
         and not l.wa_opt_out
         and l.wa_state <> 'no_whatsapp'
         and (coalesce(n ->> 'match', '') = '' or position(lower(n ->> 'match') in lower(coalesce(l.source_detail, ''))) > 0)
         and (coalesce(n ->> 'source', '') = '' or l.source = n ->> 'source')
         and case coalesce(n ->> 'only_if', 'not_paid')
               when 'not_paid' then l.webinar_state is distinct from 'paid'
               when 'no_reply' then l.wa_last_inbound_at is null
               when 'not_paid_no_reply' then l.webinar_state is distinct from 'paid' and l.wa_last_inbound_at is null
               else true
             end
         and exists (select 1 from lead_statuses s where s.name = l.status and not s.is_closed)
         and not exists (select 1 from wa_outbox o where o.lead_id = l.id and o.rule_id = n ->> 'id')
       order by l.created_at
       limit greatest(v_cap - v_used, 0)
    )
    insert into wa_outbox (lead_id, template_id, kind, rule_id)
    select id, v_tpl, 'nudge', n ->> 'id' from due;
    get diagnostics v_count = row_count;
    v_total := v_total + v_count;
    v_used := v_used + v_count;
  end loop;

  if v_total > 0 then
    perform private.wa_kick();
  end if;
end;
$$;

-- Every minute: queue follow-ups and reminders, then send what is due
create or replace function private.wa_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform private.wa_followups();
  perform private.wa_nudges();
  if exists (select 1 from wa_outbox
              where (status = 'pending' and send_at <= now())
                 or (status = 'sending' and locked_at < now() - interval '5 minutes')) then
    perform private.wa_kick();
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The three functions that already exist, now knowing the two new kinds
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
    when 'wa_text' then 'wa_text' when 'wa_template' then 'wa_template'
    when 'wa_flow' then 'wa_build' when 'wa_rule' then 'wa_rules' else null end;
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
      when 'wa_flow' then private.mcp_prep_wa_flow(p_args)
      when 'wa_rule' then private.mcp_prep_wa_rule(p_args)
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

  if p_tool = 'crm_wa_system' then
    if not private.mcp_perm('wa_build') then
      return jsonb_build_object('error', 'Building WhatsApp templates and replies is switched off. The owner can switch it on in the CRM app: More > Claude connector > Permissions.');
    end if;
    return private.mcp_wa_system();
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
  if p_tool in ('crm_chats', 'crm_chat', 'crm_templates', 'crm_requests', 'crm_wa_system') then
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
                        from unnest(array['read_chats', 'add_leads', 'edit_leads', 'change_status', 'add_remark', 'set_reminder', 'assign', 'wa_text', 'wa_template', 'wa_build', 'wa_rules']) k
                       where private.mcp_perm(k)),
      'changes_need_owner_approval', true);
  end if;
  return v_res;
end;
$$;
