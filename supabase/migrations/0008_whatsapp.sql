-- WhatsApp Cloud API (the admin's own Meta account):
--   * message templates (made in the app, approved by Meta)
--   * automatic message when a lead arrives (on/off), follow-ups when nobody replies
--   * inbox: every message in and out, with sent / delivered / read ticks
--   * automatic replies (buttons / lists) that move the lead to a status / Hot-Warm-Cold
--   * broadcast to a filtered group of leads, and numbers for the dashboard
-- The secrets (access token, app secret) live in wa_config, which only the edge functions can read.

-- ---------------------------------------------------------------------------
-- Secrets (never readable from the app)
-- ---------------------------------------------------------------------------

create table public.wa_config (
  id int primary key default 1 check (id = 1),
  access_token text,
  app_secret text,
  app_id text,
  phone_number_id text,
  waba_id text,
  verify_token text not null default replace(gen_random_uuid()::text, '-', ''),
  updated_at timestamptz not null default now()
);
alter table public.wa_config enable row level security;
revoke all on public.wa_config from anon, authenticated;
insert into public.wa_config (id) values (1);

-- Settings the admin edits ('whatsapp') and what the server learned from Meta ('whatsapp_status').
insert into public.app_settings (key, value) values
  ('whatsapp', jsonb_build_object(
    'auto_send', false,
    'auto_template_id', null,
    'auto_sources', jsonb_build_array('meta_form', 'meta_landing', 'google_form', 'google_landing', 'website'),
    'rules', '[]'::jsonb,
    'button_via_api', false,
    'welcome_node_id', null,
    'followups', jsonb_build_object(
      'enabled', false, 'start_hour', 9, 'end_hour', 21,
      'steps', jsonb_build_array(
        jsonb_build_object('after_hours', 24, 'template_id', null),
        jsonb_build_object('after_hours', 72, 'template_id', null))),
    'price_marketing', 0.9,
    'price_utility', 0.15)),
  ('whatsapp_status', '{"connected": false}'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Lead columns (the inbox and the ticks read these)
-- ---------------------------------------------------------------------------

alter table public.leads
  -- of the latest message we sent: none, queued, sent, delivered, read, failed, no_whatsapp; or replied
  add column wa_state text not null default 'none',
  add column wa_opt_out boolean not null default false,
  add column wa_last_inbound_at timestamptz,
  add column wa_last_message_at timestamptz,
  add column wa_last_text text,
  add column wa_last_direction text,
  add column wa_unread int not null default 0,
  -- when the first automatic message went out: follow-ups count from here
  add column wa_first_sent_at timestamptz,
  add column wa_followup_step int not null default 0;

create index leads_wa_last_idx on public.leads (wa_last_message_at desc) where wa_last_message_at is not null;
create index leads_wa_followup_idx on public.leads (wa_followup_step, wa_first_sent_at) where wa_first_sent_at is not null;

alter table public.lead_activities drop constraint lead_activities_type_check;
alter table public.lead_activities add constraint lead_activities_type_check check (type in (
  'created', 'remark', 'status', 'call', 'whatsapp', 'sms', 'email',
  'assigned', 'reminder', 'duplicate', 'edit', 'temperature', 'lost_reason', 'wa'
));

-- ---------------------------------------------------------------------------
-- Templates
-- ---------------------------------------------------------------------------

create table public.wa_templates (
  id uuid primary key default gen_random_uuid(),
  -- Meta's name: lowercase letters, digits and underscores
  name text not null check (name ~ '^[a-z0-9_]+$' and length(name) <= 512),
  language text not null default 'en',
  category text not null default 'MARKETING' check (category in ('MARKETING', 'UTILITY')),
  -- {header: {type, text, media_path, media_type, filename, handle}, body, footer,
  --  buttons: [{type: quick_reply|url|phone|copy_code, text, url, phone, example, action}]}
  spec jsonb not null default '{}'::jsonb,
  -- DRAFT, PENDING, APPROVED, REJECTED, PAUSED, DISABLED
  status text not null default 'DRAFT',
  reason text,
  meta_id text,
  quality text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (name, language)
);

alter table public.wa_templates enable row level security;
create policy wa_templates_select on public.wa_templates
  for select to authenticated using ((select public.is_member()));
create policy wa_templates_admin on public.wa_templates
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Automatic replies (text / buttons / list) the lead gets after pressing a button
-- ---------------------------------------------------------------------------

create table public.wa_nodes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('text', 'buttons', 'list')),
  header text,
  body text not null,
  footer text,
  media_path text,
  media_type text check (media_type in ('image', 'video', 'document')),
  filename text,
  -- [{title, action}] up to 3
  buttons jsonb not null default '[]'::jsonb,
  list_button text,
  -- [{title, rows: [{title, description, action}]}]
  sections jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.wa_nodes enable row level security;
create policy wa_nodes_select on public.wa_nodes
  for select to authenticated using ((select public.is_member()));
create policy wa_nodes_admin on public.wa_nodes
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

create table public.wa_broadcasts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  template_id uuid references public.wa_templates (id) on delete set null,
  filter jsonb not null default '{}'::jsonb,
  total int not null default 0,
  -- sending, done, cancelled
  status text not null default 'sending',
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.wa_broadcasts enable row level security;
create policy wa_broadcasts_admin on public.wa_broadcasts
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create table public.wa_messages (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads (id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  -- auto, followup, broadcast, manual, bot (automatic reply), inbound
  kind text not null default 'manual',
  -- text, template, image, video, document, audio, interactive, button, location, sticker, reaction, unknown
  type text not null default 'text',
  body text,
  template_id uuid references public.wa_templates (id) on delete set null,
  template_name text,
  broadcast_id uuid references public.wa_broadcasts (id) on delete set null,
  node_id uuid references public.wa_nodes (id) on delete set null,
  wa_id text unique,
  media_path text,
  mime text,
  filename text,
  -- queued, sent, delivered, read, failed, received
  status text not null default 'queued',
  error text,
  error_code int,
  sent_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz
);

create index wa_messages_lead_idx on public.wa_messages (lead_id, created_at);
create index wa_messages_created_idx on public.wa_messages (created_at);
create index wa_messages_template_idx on public.wa_messages (template_id) where template_id is not null;
create index wa_messages_broadcast_idx on public.wa_messages (broadcast_id) where broadcast_id is not null;

alter table public.wa_messages enable row level security;
-- You see the messages of the leads you can see (agents: their own leads). Writes go through the edge functions.
create policy wa_messages_select on public.wa_messages
  for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id));

-- Queue of template messages waiting to go out (automatic, follow-up, broadcast).
create table public.wa_outbox (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads (id) on delete cascade,
  template_id uuid not null references public.wa_templates (id) on delete cascade,
  -- auto, followup, broadcast
  kind text not null,
  broadcast_id uuid references public.wa_broadcasts (id) on delete cascade,
  step int,
  send_at timestamptz not null default now(),
  -- pending, sending, sent, failed, skipped
  status text not null default 'pending',
  attempts int not null default 0,
  error text,
  locked_at timestamptz,
  created_at timestamptz not null default now()
);
create index wa_outbox_pending_idx on public.wa_outbox (send_at) where status in ('pending', 'sending');
create index wa_outbox_broadcast_idx on public.wa_outbox (broadcast_id) where broadcast_id is not null;
alter table public.wa_outbox enable row level security;
revoke all on public.wa_outbox from anon, authenticated;

-- Live updates in the open chat.
do $$
begin
  alter publication supabase_realtime add table public.wa_messages;
exception when others then
  raise warning 'Could not add wa_messages to realtime (%): chats refresh every few seconds instead', sqlerrm;
end $$;

-- Pictures / PDFs for templates and replies.
insert into storage.buckets (id, name, public)
values ('wa-media', 'wa-media', false)
on conflict (id) do nothing;

create policy "Team can read WhatsApp media"
  on storage.objects for select to authenticated
  using (bucket_id = 'wa-media' and (select public.is_member()));
-- Admin: template / reply pictures anywhere. Agents: only files they attach in a chat ("out/...").
create policy "Team can add WhatsApp media"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'wa-media'
              and ((select public.is_admin()) or (name like 'out/%' and (select public.is_member()))));
create policy "Admin can replace WhatsApp media"
  on storage.objects for update to authenticated
  using (bucket_id = 'wa-media' and (select public.is_admin()));
create policy "Admin can remove WhatsApp media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'wa-media' and (select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Waking the sender (edge function "whatsapp") after commit
-- ---------------------------------------------------------------------------

create or replace function private.wa_kick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from private.config where key = 'functions_url';
  select value ->> 'webhook_key' into v_key from app_settings where key = 'integrations';
  if v_url is null or v_key is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/whatsapp',
    body := '{"action": "process"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key),
    timeout_milliseconds := 120000
  );
exception when others then
  raise warning 'wa_kick: %', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- A new lead arrives -> queue the welcome template at once (if switched on)
-- ---------------------------------------------------------------------------

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

create trigger leads_wa_auto
  after insert on public.leads
  referencing new table as new_rows
  for each statement execute function private.wa_auto_send();

-- ---------------------------------------------------------------------------
-- Follow-ups: nobody replied -> the next template after N hours (inside working hours)
-- ---------------------------------------------------------------------------

create or replace function private.wa_followups()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
  v_f jsonb;
  v_steps jsonb;
  v_hour int := extract(hour from now() at time zone 'Asia/Kolkata');
  v_i int;
  v_tpl uuid;
  v_hours int;
  v_n int;
  v_total int := 0;
begin
  select value into v_cfg from app_settings where key = 'whatsapp';
  v_f := v_cfg -> 'followups';
  if not coalesce((v_f ->> 'enabled')::boolean, false)
     or not coalesce((select (value ->> 'connected')::boolean from app_settings where key = 'whatsapp_status'), false) then
    return;
  end if;
  if v_hour < coalesce((v_f ->> 'start_hour')::int, 9) or v_hour >= coalesce((v_f ->> 'end_hour')::int, 21) then
    return;
  end if;
  v_steps := coalesce(v_f -> 'steps', '[]'::jsonb);

  for v_i in 0 .. jsonb_array_length(v_steps) - 1 loop
    v_tpl := nullif(v_steps -> v_i ->> 'template_id', '')::uuid;
    v_hours := coalesce((v_steps -> v_i ->> 'after_hours')::int, 24);
    continue when v_tpl is null;

    with due as (
      update leads l
         set wa_followup_step = v_i + 1
       where l.wa_followup_step = v_i
         and l.wa_first_sent_at is not null
         and l.wa_first_sent_at <= now() - make_interval(hours => v_hours)
         and l.wa_first_sent_at > now() - interval '30 days'
         and l.phone is not null
         and not l.wa_opt_out
         and l.wa_state not in ('replied', 'no_whatsapp')
         and (l.wa_last_inbound_at is null or l.wa_last_inbound_at < l.wa_first_sent_at)
         and exists (select 1 from lead_statuses s where s.name = l.status and not s.is_closed)
      returning l.id
    )
    insert into wa_outbox (lead_id, template_id, kind, step)
    select id, v_tpl, 'followup', v_i from due;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
  end loop;

  if v_total > 0 then
    perform private.wa_kick();
  end if;
end;
$$;

-- Every minute: send what is due (also picks up anything that got stuck) and queue follow-ups.
create or replace function private.wa_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform private.wa_followups();
  if exists (select 1 from wa_outbox
              where (status = 'pending' and send_at <= now())
                 or (status = 'sending' and locked_at < now() - interval '5 minutes')) then
    perform private.wa_kick();
  end if;
end;
$$;

do $$
begin
  perform cron.schedule('whatsweb-whatsapp', '* * * * *', 'select private.wa_tick()');
exception when others then
  raise warning 'Could not schedule the WhatsApp sender (%): follow-ups and broadcasts stay off', sqlerrm;
end $$;

-- The sender takes a batch of queued messages (several senders never get the same one).
create or replace function public.wa_claim_outbox(p_limit int)
returns setof public.wa_outbox
language sql
security definer
set search_path = public
as $$
  update wa_outbox o
     set status = 'sending', locked_at = now(), attempts = o.attempts + 1
   where o.id in (
     select id from wa_outbox
      where (status = 'pending' and send_at <= now())
         or (status = 'sending' and locked_at < now() - interval '5 minutes')
      order by send_at
      limit greatest(p_limit, 1)
      for update skip locked)
  returning o.*;
$$;

revoke execute on function public.wa_claim_outbox(int) from public, anon, authenticated;
grant execute on function public.wa_claim_outbox(int) to service_role;

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------

-- filter: {status, temperature, assignee (id or "unassigned"), source, source_detail, batch_id, from, to, wa}
create or replace function private.wa_audience(p_filter jsonb)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select l.id
    from leads l
   where l.phone is not null
     and not l.wa_opt_out
     and (p_filter ->> 'status' is null or l.status = p_filter ->> 'status')
     and (p_filter ->> 'temperature' is null or l.temperature = p_filter ->> 'temperature')
     and (p_filter ->> 'assignee' is null
          or (p_filter ->> 'assignee' = 'unassigned' and l.assigned_to is null)
          or l.assigned_to::text = p_filter ->> 'assignee')
     and (p_filter ->> 'source' is null or l.source = p_filter ->> 'source')
     and (p_filter ->> 'source_detail' is null or l.source_detail = p_filter ->> 'source_detail')
     and (p_filter ->> 'batch_id' is null or l.import_batch_id::text = p_filter ->> 'batch_id')
     and (p_filter ->> 'from' is null or l.created_at >= (p_filter ->> 'from')::timestamptz)
     and (p_filter ->> 'to' is null or l.created_at < (p_filter ->> 'to')::timestamptz)
     and (p_filter ->> 'wa' is null or l.wa_state = p_filter ->> 'wa');
$$;

create or replace function public.wa_audience_count(p_filter jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  return (select count(*) from private.wa_audience(p_filter));
end;
$$;

create or replace function public.wa_create_broadcast(p_template uuid, p_name text, p_filter jsonb)
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

  insert into wa_broadcasts (name, template_id, filter)
  values (coalesce(nullif(trim(p_name), ''), 'Broadcast'), p_template, coalesce(p_filter, '{}'::jsonb))
  returning id into v_id;

  insert into wa_outbox (lead_id, template_id, kind, broadcast_id)
  select a, p_template, 'broadcast', v_id from private.wa_audience(coalesce(p_filter, '{}'::jsonb)) a;
  get diagnostics v_n = row_count;

  update wa_broadcasts set total = v_n, status = case when v_n = 0 then 'done' else 'sending' end where id = v_id;
  if v_n > 0 then
    perform private.wa_kick();
  end if;
  return jsonb_build_object('id', v_id, 'total', v_n);
end;
$$;

create or replace function public.wa_cancel_broadcast(p_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update wa_outbox set status = 'skipped', error = 'Cancelled'
   where broadcast_id = p_id and status = 'pending';
  get diagnostics v_n = row_count;
  update wa_broadcasts set status = 'cancelled' where id = p_id;
  return v_n;
end;
$$;

create or replace function public.wa_broadcast_list()
returns table (
  id uuid, name text, template_name text, created_at timestamptz, status text,
  total int, pending bigint, sent bigint, delivered bigint, read bigint, failed bigint, replied bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  return query
  select b.id, b.name, t.name, b.created_at, b.status, b.total,
         (select count(*) from wa_outbox o where o.broadcast_id = b.id and o.status in ('pending', 'sending')),
         count(m.id) filter (where m.status <> 'failed'),
         count(m.id) filter (where m.delivered_at is not null),
         count(m.id) filter (where m.read_at is not null),
         count(m.id) filter (where m.status = 'failed')
           + (select count(*) from wa_outbox o where o.broadcast_id = b.id and o.status = 'failed'
                 and not exists (select 1 from wa_messages mm where mm.broadcast_id = b.id and mm.lead_id = o.lead_id)),
         count(distinct m.lead_id) filter (where exists (
           select 1 from wa_messages r
            where r.lead_id = m.lead_id and r.direction = 'in' and r.created_at > m.created_at))
    from wa_broadcasts b
    left join wa_templates t on t.id = b.template_id
    left join wa_messages m on m.broadcast_id = b.id and m.direction = 'out'
   group by b.id, t.name
   order by b.created_at desc
   limit 50;
end;
$$;

-- ---------------------------------------------------------------------------
-- Numbers for the dashboard
-- ---------------------------------------------------------------------------

create or replace function public.wa_stats(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_totals jsonb;
  v_kinds jsonb;
  v_templates jsonb;
  v_states jsonb;
begin
  if not is_admin() then
    raise exception 'Only admin can see these numbers';
  end if;

  select jsonb_build_object(
    'sent', count(*) filter (where m.direction = 'out' and m.status <> 'failed'),
    'delivered', count(*) filter (where m.direction = 'out' and m.delivered_at is not null),
    'read', count(*) filter (where m.direction = 'out' and m.read_at is not null),
    'failed', count(*) filter (where m.direction = 'out' and m.status = 'failed'),
    'inbound', count(*) filter (where m.direction = 'in'),
    'replied_leads', count(distinct m.lead_id) filter (where m.direction = 'in'),
    'templates_sent', count(*) filter (where m.direction = 'out' and m.type = 'template' and m.status <> 'failed'))
    into v_totals
    from wa_messages m
   where m.created_at >= p_from and m.created_at < p_to;

  select coalesce(jsonb_agg(row_to_json(x) order by x.sent desc), '[]'::jsonb) into v_kinds
  from (
    select m.kind,
           count(*) filter (where m.status <> 'failed') as sent,
           count(*) filter (where m.delivered_at is not null) as delivered,
           count(*) filter (where m.read_at is not null) as read,
           count(*) filter (where m.status = 'failed') as failed
      from wa_messages m
     where m.direction = 'out' and m.created_at >= p_from and m.created_at < p_to
     group by m.kind
  ) x;

  select coalesce(jsonb_agg(row_to_json(x) order by x.sent desc), '[]'::jsonb) into v_templates
  from (
    select coalesce(m.template_name, '?') as name,
           count(*) filter (where m.status <> 'failed') as sent,
           count(*) filter (where m.delivered_at is not null) as delivered,
           count(*) filter (where m.read_at is not null) as read,
           count(*) filter (where m.status = 'failed') as failed,
           count(*) filter (where exists (
             select 1 from wa_messages r
              where r.lead_id = m.lead_id and r.direction = 'in'
                and r.created_at > m.created_at and r.created_at < m.created_at + interval '3 days')) as replied
      from wa_messages m
     where m.direction = 'out' and m.type = 'template' and m.created_at >= p_from and m.created_at < p_to
     group by 1
     limit 20
  ) x;

  select coalesce(jsonb_object_agg(s.wa_state, s.n), '{}'::jsonb) into v_states
  from (select wa_state, count(*) as n from leads where wa_state <> 'none' group by wa_state) s;

  return jsonb_build_object('totals', v_totals, 'kinds', v_kinds, 'templates', v_templates, 'states', v_states);
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.wa_audience_count(jsonb)',
    'public.wa_create_broadcast(uuid, text, jsonb)',
    'public.wa_cancel_broadcast(uuid)',
    'public.wa_broadcast_list()',
    'public.wa_stats(timestamptz, timestamptz)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
