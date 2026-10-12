-- REST API for an outside AI assistant + outgoing webhooks.
--   * The edge function "api" is the only door: every request carries "Authorization: Bearer <key>".
--     Keys are made in the app (More > API & webhooks), shown once, stored only as a hash, and can be revoked.
--     60 requests a minute per key.
--   * Reading and the small writes (note, status) are the functions api_* below; they run as the service role only.
--     Sending WhatsApp goes through the same sender the app uses (edge function code), never around it.
--   * Outgoing webhooks: the events below are queued in webhook_deliveries (signed and sent by the edge function,
--     tried again up to 3 times), and every try is visible in the app.
-- Nothing here deletes anything.

-- ---------------------------------------------------------------------------
-- Keys and settings
-- ---------------------------------------------------------------------------

create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  -- first characters of the key, so the admin can tell the keys apart
  prefix text not null,
  -- sha256 of the key: the key itself is never stored
  key_hash text not null unique,
  -- read: students, activities, messages, courses, templates   write: notes, status   send: WhatsApp messages
  scopes text[] not null default array['read', 'write', 'send'],
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
alter table public.api_keys enable row level security;
revoke all on public.api_keys from anon, authenticated;
-- the admin sees everything about a key except the hash
grant select (id, name, prefix, scopes, created_at, last_used_at, revoked_at) on public.api_keys to authenticated;
create policy api_keys_select on public.api_keys for select to authenticated using ((select public.is_admin()));

create table public.api_hits (
  key_id uuid not null references public.api_keys (id) on delete cascade,
  minute timestamptz not null,
  n int not null default 0,
  primary key (key_id, minute)
);
alter table public.api_hits enable row level security;
revoke all on public.api_hits from anon, authenticated;

-- Every call that changes something (a message sent, a note, a status) and every refused send.
create table public.api_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  key_id uuid references public.api_keys (id) on delete set null,
  key_name text,
  method text not null,
  path text not null,
  status int not null,
  lead_id uuid references public.leads (id) on delete set null,
  summary text
);
create index api_log_at_idx on public.api_log (at desc);
alter table public.api_log enable row level security;
revoke all on public.api_log from anon, authenticated;
grant select on public.api_log to authenticated;
create policy api_log_select on public.api_log for select to authenticated using ((select public.is_admin()));

-- One row: the webhook address + secret (only the server reads them) and the daily send limit.
create table public.api_config (
  id int primary key default 1 check (id = 1),
  webhook_url text,
  webhook_secret text,
  webhook_enabled boolean not null default false,
  -- the most messages the API may send in 24 hours (all keys together): a leaked key cannot spam the number
  send_cap int not null default 200 check (send_cap between 0 and 5000),
  updated_at timestamptz not null default now()
);
alter table public.api_config enable row level security;
revoke all on public.api_config from anon, authenticated;
insert into public.api_config (id) values (1);

create table public.webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  event text not null,
  lead_id uuid references public.leads (id) on delete set null,
  payload jsonb not null,
  -- pending, sending, retry, ok, failed
  status text not null default 'pending',
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  last_code int,
  last_error text,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);
create index webhook_deliveries_due_idx on public.webhook_deliveries (next_attempt_at) where status in ('pending', 'retry', 'sending');
create index webhook_deliveries_seq_idx on public.webhook_deliveries (seq desc);
alter table public.webhook_deliveries enable row level security;
revoke all on public.webhook_deliveries from anon, authenticated;
grant select on public.webhook_deliveries to authenticated;
create policy webhook_deliveries_select on public.webhook_deliveries for select to authenticated using ((select public.is_admin()));

-- Who sent a WhatsApp message: the AI assistant (and which key).
alter table public.wa_messages
  add column via text check (via in ('api')),
  add column api_key_name text;

-- ---------------------------------------------------------------------------
-- Settings from the app (admin)
-- ---------------------------------------------------------------------------

-- Makes a key. The key is returned ONCE here and cannot be read again.
create or replace function public.api_key_create(p_name text, p_scopes text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := 'lcrm_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_scopes text[];
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'Give the key a name';
  end if;
  select coalesce(array_agg(distinct s order by s), '{}') into v_scopes
    from unnest(coalesce(p_scopes, array['read'])) s where s in ('read', 'write', 'send');
  if array_length(v_scopes, 1) is null then
    raise exception 'Choose at least one thing the key may do';
  end if;
  if (select count(*) from api_keys where revoked_at is null) >= 20 then
    raise exception 'Too many active keys (20). Revoke one you do not use.';
  end if;
  insert into api_keys (name, prefix, key_hash, scopes)
  values (left(trim(p_name), 60), left(v_key, 9), encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), v_scopes)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'key', v_key, 'scopes', to_jsonb(v_scopes));
end;
$$;

create or replace function public.api_key_revoke(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update api_keys set revoked_at = now() where id = p_id and revoked_at is null;
end;
$$;

create or replace function public.api_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c api_config;
begin
  if not is_admin() then
    raise exception 'Only admin can see this';
  end if;
  select * into c from api_config where id = 1;
  return jsonb_build_object(
    'webhook_url', c.webhook_url,
    'secret_saved', c.webhook_secret is not null,
    'webhook_enabled', c.webhook_enabled,
    'send_cap', c.send_cap,
    'sent_24h', (select count(*) from wa_messages where via = 'api' and created_at > now() - interval '24 hours'),
    'pending_webhooks', (select count(*) from webhook_deliveries where status in ('pending', 'retry', 'sending')),
    'failed_webhooks', (select count(*) from webhook_deliveries where status = 'failed' and created_at > now() - interval '7 days'));
end;
$$;

-- p_secret: null = leave as it is, '' = remove it
create or replace function public.api_webhook_set(p_url text, p_secret text, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(trim(coalesce(p_url, '')), '');
  v_host text;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if v_url is not null then
    if v_url !~* '^https://[^/\s]+' or length(v_url) > 500 then
      raise exception 'The address must start with https://';
    end if;
    v_host := lower(substring(v_url from '^https://([^/:?#]+)'));
    if v_host in ('localhost', '0.0.0.0') or v_host ~ '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
       or v_host !~ '\.' or v_host ~ '\.(local|internal|localhost)$' then
      raise exception 'That address points inside a private network. Use the public https address.';
    end if;
  end if;
  if p_enabled and v_url is null then
    raise exception 'Paste the webhook address first';
  end if;
  update api_config
     set webhook_url = v_url,
         webhook_secret = case when p_secret is null then webhook_secret else nullif(trim(p_secret), '') end,
         webhook_enabled = p_enabled,
         updated_at = now()
   where id = 1;
end;
$$;

create or replace function public.api_set_cap(p_cap int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if p_cap is null or p_cap < 0 or p_cap > 5000 then
    raise exception 'Use a number from 0 to 5000';
  end if;
  update api_config set send_cap = p_cap, updated_at = now() where id = 1;
end;
$$;

-- Try a delivery again (a failed one, or any other)
create or replace function public.api_delivery_retry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  update webhook_deliveries
     set status = 'pending', attempts = 0, next_attempt_at = now(), locked_at = null, last_error = null
   where id = p_id and status in ('failed', 'ok');
  perform private.api_kick();
end;
$$;

revoke execute on function public.api_key_create(text, text[]) from public, anon;
revoke execute on function public.api_key_revoke(uuid) from public, anon;
revoke execute on function public.api_settings() from public, anon;
revoke execute on function public.api_webhook_set(text, text, boolean) from public, anon;
revoke execute on function public.api_set_cap(int) from public, anon;
revoke execute on function public.api_delivery_retry(uuid) from public, anon;
grant execute on function public.api_key_create(text, text[]) to authenticated;
grant execute on function public.api_key_revoke(uuid) to authenticated;
grant execute on function public.api_settings() to authenticated;
grant execute on function public.api_webhook_set(text, text, boolean) to authenticated;
grant execute on function public.api_set_cap(int) to authenticated;
grant execute on function public.api_delivery_retry(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The door: which key is this, may it come in now (60 a minute)
-- ---------------------------------------------------------------------------

create or replace function public.api_check(p_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k api_keys;
  v_n int;
begin
  select * into k from api_keys where key_hash = p_hash;
  if not found then
    return jsonb_build_object('error', 'invalid_key');
  end if;
  if k.revoked_at is not null then
    return jsonb_build_object('error', 'revoked_key');
  end if;
  insert into api_hits (key_id, minute, n) values (k.id, date_trunc('minute', now()), 1)
  on conflict (key_id, minute) do update set n = api_hits.n + 1
  returning n into v_n;
  if v_n > 60 then
    return jsonb_build_object('error', 'rate_limited', 'retry_after', greatest(ceil(extract(epoch from (date_trunc('minute', now()) + interval '1 minute' - now())))::int, 1));
  end if;
  if k.last_used_at is null or k.last_used_at < now() - interval '1 minute' then
    update api_keys set last_used_at = now() where id = k.id;
  end if;
  return jsonb_build_object('ok', true, 'key_id', k.id, 'name', k.name, 'scopes', to_jsonb(k.scopes), 'remaining', 60 - v_n);
end;
$$;

revoke execute on function public.api_check(text) from public, anon, authenticated;
grant execute on function public.api_check(text) to service_role;

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- A student as the list shows him.
create or replace function private.api_student(l leads, p_full boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', l.id,
    'name', l.name,
    'phone', l.phone,
    'email', l.email,
    'created_at', l.created_at,
    'source', l.source,
    'source_detail', l.source_detail,
    'semester', (select e.value from jsonb_each_text(coalesce(l.extra, '{}'::jsonb)) e
                  where lower(e.key) in ('semester', 'sem') and nullif(trim(e.value), '') is not null limit 1),
    'status', l.status,
    'opted_out', l.wa_opt_out,
    'purchased_courses', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'name', p.item, 'amount', p.amount, 'purchased_at', p.purchased_at,
                                   'expires_at', p.expires_at) order by p.purchased_at desc nulls last), '[]'::jsonb)
                            from appx_purchases p where p.lead_id = l.id and p.status = 'paid' and not p.is_test))
  || case when p_full then jsonb_build_object(
    'temperature', l.temperature,
    'lost_reason', l.lost_reason,
    'assigned_to', (select p.full_name from profiles p where p.id = l.assigned_to),
    'last_contacted_at', l.last_contacted_at,
    'next_follow_up_at', l.next_follow_up_at,
    'app_state', l.appx_state,
    'app_paid_rupees', l.appx_paid,
    'webinar_state', l.webinar_state,
    'webinar_paid_rupees', l.webinar_paid,
    'webinar_attended', l.webinar_attended,
    'whatsapp_state', l.wa_state,
    'whatsapp_window_open', coalesce(l.wa_last_inbound_at > now() - interval '24 hours', false),
    'form_details', coalesce(l.extra, '{}'::jsonb))
  else '{}'::jsonb end;
$$;

-- p: created_after, phone, email, status, limit, after_at, after_id
create or replace function public.api_students(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce((p ->> 'limit')::int, 50), 1), 200);
  v_after_at timestamptz := nullif(p ->> 'after_at', '')::timestamptz;
  v_after_id uuid := nullif(p ->> 'after_id', '')::uuid;
  v_created timestamptz := nullif(p ->> 'created_after', '')::timestamptz;
  v_key text := phone_key(nullif(p ->> 'phone', ''));
  v_email text := nullif(lower(trim(coalesce(p ->> 'email', ''))), '');
  v_status text := nullif(trim(coalesce(p ->> 'status', '')), '');
  v_rows jsonb;
  v_more boolean;
  v_last_at timestamptz;
  v_last_id uuid;
begin
  with page as (
    select l.created_at as at, l.id, private.api_student(l) as j,
           row_number() over (order by l.created_at, l.id) as rn
      from leads l
     where (v_created is null or l.created_at > v_created)
       and (p ->> 'phone' is null or (v_key is not null and l.phone_key = v_key))
       and (v_email is null or lower(l.email) = v_email)
       and (v_status is null or lower(l.status) = lower(v_status))
       and (v_after_at is null or (l.created_at, l.id) > (v_after_at, v_after_id))
     order by l.created_at, l.id
     limit v_limit + 1
  )
  select coalesce(jsonb_agg(j order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*) > v_limit,
         (array_agg(at order by rn) filter (where rn = v_limit))[1],
         (array_agg(id order by rn) filter (where rn = v_limit))[1]
    into v_rows, v_more, v_last_at, v_last_id
    from page;
  return jsonb_build_object('data', v_rows, 'has_more', v_more,
    'next_after', case when v_more then jsonb_build_object('at', v_last_at, 'id', v_last_id) else null end);
end;
$$;

create or replace function public.api_student_get(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  l leads;
begin
  select * into l from leads where id = p_id;
  if not found then
    return null;
  end if;
  return private.api_student(l, true);
end;
$$;

-- The timeline: what the student did (signed up, asked for a demo, bought ...) and what we did.
-- p: limit, order (asc|desc), after_at, after_id
create or replace function public.api_activities(p_id uuid, p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce((p ->> 'limit')::int, 100), 1), 200);
  v_desc boolean := lower(coalesce(p ->> 'order', 'desc')) <> 'asc';
  v_after_at timestamptz := nullif(p ->> 'after_at', '')::timestamptz;
  v_after_id bigint := nullif(p ->> 'after_id', '')::bigint;
  v_rows jsonb;
  v_more boolean;
  v_last_at timestamptz;
  v_last_id bigint;
begin
  if not exists (select 1 from leads where id = p_id) then
    return null;
  end if;
  with page as (
    select a.id, a.created_at as at,
           jsonb_build_object(
             'id', a.id,
             'at', a.created_at,
             'type', case a.type
                       when 'appx' then case a.meta ->> 'kind'
                                          when 'signup' then 'signup'
                                          when 'demo' then 'demo_requested'
                                          when 'contact' then 'contact_form'
                                          when 'cancelled' then 'payment_cancelled'
                                          when 'purchase' then 'purchase'
                                          when 'refund' then 'refund'
                                          else 'app_activity' end
                       when 'webinar' then 'webinar'
                       when 'remark' then case when a.meta ->> 'via' = 'api' then 'ai_note' else 'note' end
                       when 'status' then 'status_change'
                       when 'wa' then 'whatsapp_event'
                       else a.type end,
             'text', case a.type
                       when 'status' then 'Status changed from ' || coalesce(a.meta ->> 'from', '?') || ' to ' || coalesce(a.meta ->> 'to', '?')
                       when 'created' then 'Lead created' || coalesce(' from ' || (a.meta ->> 'source'), '')
                       when 'assigned' then case when a.meta ->> 'to' is null then 'Unassigned'
                                                 else 'Assigned to ' || coalesce((select p3.full_name from profiles p3 where p3.id::text = a.meta ->> 'to'), 'an agent') end
                       when 'temperature' then 'Marked ' || coalesce(a.meta ->> 'to', 'no tag')
                       when 'lost_reason' then 'Lost reason: ' || coalesce(a.body, '')
                       else a.body end,
             'by', case when a.meta ->> 'via' = 'api' then 'ai_assistant'
                        when a.user_id is not null then coalesce((select p2.full_name from profiles p2 where p2.id = a.user_id), 'agent')
                        else 'system' end,
             'details', case when a.type in ('appx', 'webinar') then coalesce(a.meta, '{}'::jsonb) else '{}'::jsonb end) as j,
           row_number() over (order by case when v_desc then a.created_at end desc, case when v_desc then a.id end desc,
                                       case when not v_desc then a.created_at end asc, case when not v_desc then a.id end asc) as rn
      from lead_activities a
     where a.lead_id = p_id
       and (v_after_at is null
            or (v_desc and (a.created_at, a.id) < (v_after_at, v_after_id))
            or (not v_desc and (a.created_at, a.id) > (v_after_at, v_after_id)))
     order by case when v_desc then a.created_at end desc, case when v_desc then a.id end desc,
              case when not v_desc then a.created_at end asc, case when not v_desc then a.id end asc
     limit v_limit + 1
  )
  select coalesce(jsonb_agg(j order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*) > v_limit,
         (array_agg(at order by rn) filter (where rn = v_limit))[1],
         (array_agg(id order by rn) filter (where rn = v_limit))[1]
    into v_rows, v_more, v_last_at, v_last_id
    from page;
  return jsonb_build_object('data', v_rows, 'has_more', v_more,
    'next_after', case when v_more then jsonb_build_object('at', v_last_at, 'id', v_last_id) else null end);
end;
$$;

-- The WhatsApp conversation. p: limit, order (asc|desc), after_at, after_id
create or replace function public.api_messages(p_id uuid, p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce((p ->> 'limit')::int, 100), 1), 200);
  v_desc boolean := lower(coalesce(p ->> 'order', 'asc')) = 'desc';
  v_after_at timestamptz := nullif(p ->> 'after_at', '')::timestamptz;
  v_after_id uuid := nullif(p ->> 'after_id', '')::uuid;
  v_rows jsonb;
  v_more boolean;
  v_last_at timestamptz;
  v_last_id uuid;
begin
  if not exists (select 1 from leads where id = p_id) then
    return null;
  end if;
  with page as (
    select m.id, m.created_at as at,
           jsonb_build_object(
             'id', m.id,
             'at', m.created_at,
             'direction', case m.direction when 'in' then 'incoming' else 'outgoing' end,
             'type', m.type,
             'text', m.body,
             'template_name', m.template_name,
             'button_click', m.direction = 'in' and m.type in ('button', 'interactive'),
             'sent_by', case when m.direction = 'in' then 'student'
                             when m.via = 'api' then 'ai_assistant'
                             when m.kind in ('auto', 'followup', 'broadcast', 'bot', 'nudge') then 'automation'
                             else 'agent' end,
             'status', m.status,
             'sent_at', m.sent_at, 'delivered_at', m.delivered_at, 'read_at', m.read_at,
             'error', m.error) as j,
           row_number() over (order by case when v_desc then m.created_at end desc, case when v_desc then m.id end desc,
                                       case when not v_desc then m.created_at end asc, case when not v_desc then m.id end asc) as rn
      from wa_messages m
     where m.lead_id = p_id
       and (v_after_at is null
            or (v_desc and (m.created_at, m.id) < (v_after_at, v_after_id))
            or (not v_desc and (m.created_at, m.id) > (v_after_at, v_after_id)))
     order by case when v_desc then m.created_at end desc, case when v_desc then m.id end desc,
              case when not v_desc then m.created_at end asc, case when not v_desc then m.id end asc
     limit v_limit + 1
  )
  select coalesce(jsonb_agg(j order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*) > v_limit,
         (array_agg(at order by rn) filter (where rn = v_limit))[1],
         (array_agg(id order by rn) filter (where rn = v_limit))[1]
    into v_rows, v_more, v_last_at, v_last_id
    from page;
  return jsonb_build_object('data', v_rows, 'has_more', v_more,
    'next_after', case when v_more then jsonb_build_object('at', v_last_at, 'id', v_last_id) else null end);
end;
$$;

create or replace function public.api_window(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  l leads;
  v_open boolean;
begin
  select * into l from leads where id = p_id;
  if not found then
    return null;
  end if;
  v_open := l.wa_last_inbound_at is not null and l.wa_last_inbound_at > now() - interval '24 hours';
  return jsonb_build_object(
    'student_id', l.id,
    'window_open', v_open,
    'last_student_message_at', l.wa_last_inbound_at,
    'closes_at', case when v_open then l.wa_last_inbound_at + interval '24 hours' else null end,
    'opted_out', l.wa_opt_out,
    'can_send_text', v_open and not l.wa_opt_out and l.phone is not null,
    'can_send_template', not l.wa_opt_out and l.phone is not null);
end;
$$;

-- The courses we know of: every course that someone bought, asked a demo for, or tried to buy.
create or replace function public.api_courses()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with ev as (
    select coalesce(nullif(trim(e.body ->> 'itemName'), ''), nullif(trim(e.body ->> 'item_name'), ''), nullif(trim(e.body ->> 'item'), '')) as item,
           coalesce(nullif(trim(e.body ->> 'purchaseLink'), ''), nullif(trim(e.body ->> 'purchase_link'), ''), nullif(trim(e.body ->> 'link'), '')) as link,
           e.created_at
      from appx_events e
     where e.kind in ('cancelled', 'demo') and e.outcome = 'ok' and not e.is_test
  ), links as (
    select distinct on (item) item, link from ev where item is not null and link is not null order by item, created_at desc
  ), buys as (
    select p.item,
           (array_agg(p.amount order by p.purchased_at desc nulls last))[1] as price,
           count(*) filter (where p.status = 'paid') as purchases
      from appx_purchases p
     where p.item is not null and not p.is_test
     group by p.item
  ), names as (
    select item from buys union select item from links union select item from ev where item is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', trim(both '-' from lower(regexp_replace(n.item, '[^a-zA-Z0-9]+', '-', 'g'))),
           'name', n.item,
           'semester', (regexp_match(n.item, '(?i)(?:sem(?:ester)?)\s*[-:]?\s*(\d+)'))[1],
           'price', b.price,
           'link', l.link,
           'purchases', coalesce(b.purchases, 0)) order by n.item), '[]'::jsonb)
    from names n
    left join buys b on b.item = n.item
    left join links l on l.item = n.item;
$$;

revoke execute on function private.api_student(leads, boolean) from public, anon, authenticated;
revoke execute on function public.api_students(jsonb), public.api_student_get(uuid), public.api_activities(uuid, jsonb),
  public.api_messages(uuid, jsonb), public.api_window(uuid), public.api_courses() from public, anon, authenticated;
grant execute on function public.api_students(jsonb), public.api_student_get(uuid), public.api_activities(uuid, jsonb),
  public.api_messages(uuid, jsonb), public.api_window(uuid), public.api_courses() to service_role;

-- ---------------------------------------------------------------------------
-- Sending: the checks that come before a message (the sending itself is edge function code)
-- p_kind: text (needs the 24-hour window) or template
-- ---------------------------------------------------------------------------

create or replace function public.api_send_check(p_lead uuid, p_kind text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  l leads;
  c api_config;
  v_sent int;
begin
  select * into l from leads where id = p_lead;
  if not found then
    return jsonb_build_object('error', 'student_not_found', 'status', 404, 'message', 'No student with this id.');
  end if;
  if l.phone is null then
    return jsonb_build_object('error', 'no_phone', 'status', 422, 'message', 'This student has no phone number.');
  end if;
  if l.wa_opt_out then
    return jsonb_build_object('error', 'opted_out', 'status', 403,
      'message', 'This student asked to stop WhatsApp messages (opted out). Nothing can be sent to them.');
  end if;
  if p_kind = 'text' and not (l.wa_last_inbound_at is not null and l.wa_last_inbound_at > now() - interval '24 hours') then
    return jsonb_build_object('error', 'window_closed', 'status', 409,
      'message', 'The 24-hour customer service window is closed: the student has not written in the last 24 hours. '
                 'Send an approved template with POST /whatsapp/send-template instead.',
      'last_student_message_at', l.wa_last_inbound_at);
  end if;
  select * into c from api_config where id = 1;
  select count(*) into v_sent from wa_messages where via = 'api' and created_at > now() - interval '24 hours';
  if v_sent >= c.send_cap then
    return jsonb_build_object('error', 'daily_limit', 'status', 429,
      'message', 'The daily limit for messages sent through the API is reached (' || c.send_cap || '). The owner can raise it in the app.');
  end if;
  return jsonb_build_object('ok', true, 'lead', to_jsonb(l));
end;
$$;

revoke execute on function public.api_send_check(uuid, text) from public, anon, authenticated;
grant execute on function public.api_send_check(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Writing (small, and always marked as the AI assistant's)
-- ---------------------------------------------------------------------------

create or replace function public.api_add_note(p_lead uuid, p_text text, p_key_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_at timestamptz;
begin
  if not exists (select 1 from leads where id = p_lead) then
    return null;
  end if;
  insert into lead_activities (lead_id, user_id, type, body, meta)
  values (p_lead, null, 'remark', left(trim(p_text), 2000), jsonb_build_object('via', 'api', 'key', p_key_name))
  returning id, created_at into v_id, v_at;
  return jsonb_build_object('id', v_id, 'student_id', p_lead, 'text', left(trim(p_text), 2000), 'created_at', v_at, 'by', 'ai_assistant');
end;
$$;

-- The status as the CRM names it. "converted" -> Admission Done, "not_interested" -> Not Interested, ...
create or replace function private.api_status_name(p text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.name from lead_statuses s
      where regexp_replace(lower(s.name), '[^a-z0-9]+', '', 'g') = regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '', 'g')
      limit 1),
    (select s.name from lead_statuses s
      where regexp_replace(lower(s.name), '[^a-z0-9]+', '', 'g') =
            case regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '', 'g')
              when 'converted' then 'admissiondone'
              when 'admitted' then 'admissiondone'
              when 'noanswer' then 'noanswer'
              when 'callback' then 'callback'
              else null end
      limit 1));
$$;

create or replace function public.api_set_status(p_lead uuid, p_status text, p_key_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := private.api_status_name(p_status);
  l leads;
  v_old text;
begin
  select * into l from leads where id = p_lead;
  if not found then
    return null;
  end if;
  if v_name is null then
    return jsonb_build_object('error', 'invalid_status', 'status', 422,
      'message', 'Unknown status. Use one of: ' || (select string_agg(name, ', ' order by sort_order) from lead_statuses) || '.',
      'valid', (select jsonb_agg(name order by sort_order) from lead_statuses));
  end if;
  v_old := l.status;
  if v_old is distinct from v_name then
    update leads set status = v_name where id = p_lead;
    insert into lead_activities (lead_id, user_id, type, body, meta)
    values (p_lead, null, 'remark', 'AI assistant changed the status from ' || v_old || ' to ' || v_name,
            jsonb_build_object('via', 'api', 'key', p_key_name));
  end if;
  return jsonb_build_object('student_id', p_lead, 'status', v_name, 'previous_status', v_old, 'changed', v_old is distinct from v_name);
end;
$$;

create or replace function public.api_statuses()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'closed', is_closed) order by sort_order), '[]'::jsonb) from lead_statuses;
$$;

revoke execute on function public.api_add_note(uuid, text, text), public.api_set_status(uuid, text, text), public.api_statuses()
  from public, anon, authenticated;
grant execute on function public.api_add_note(uuid, text, text), public.api_set_status(uuid, text, text), public.api_statuses()
  to service_role;
revoke execute on function private.api_status_name(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Outgoing webhooks: the events are queued here, the edge function signs and sends them
-- ---------------------------------------------------------------------------

create or replace function private.api_kick()
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
    url := v_url || '/api',
    body := '{"action": "deliver"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key),
    timeout_milliseconds := 60000
  );
exception when others then
  raise warning 'api_kick: %', sqlerrm;
end;
$$;

-- Queues one event for the address the admin pasted. Never stops the thing that caused it.
create or replace function private.api_emit(p_event text, p_lead uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c api_config;
  l leads;
  v_id uuid := gen_random_uuid();
begin
  select * into c from api_config where id = 1;
  if not c.webhook_enabled or c.webhook_url is null then
    return;
  end if;
  select * into l from leads where id = p_lead;
  if not found then
    return;
  end if;
  -- the made-up students of the "Send a test" buttons
  if coalesce(l.email, '') like 'appx-test-%@example.com' or coalesce(l.email, '') like 'webinar-test-%@example.com' then
    return;
  end if;
  insert into webhook_deliveries (id, event, lead_id, payload)
  values (v_id, p_event, p_lead, jsonb_build_object(
    'id', v_id,
    'event', p_event,
    'timestamp', now(),
    'student_id', l.id,
    'student', jsonb_build_object('id', l.id, 'name', l.name, 'phone', l.phone),
    'data', coalesce(p_data, '{}'::jsonb)));
  perform private.api_kick();
exception when others then
  raise warning 'api_emit: %', sqlerrm;
end;
$$;

revoke execute on function private.api_kick() from public, anon, authenticated;
revoke execute on function private.api_emit(text, uuid, jsonb) from public, anon, authenticated;

-- student.created: not for a bulk import (thousands at once)
create or replace function private.api_on_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.import_batch_id is null then
    perform private.api_emit('student.created', new.id, jsonb_build_object(
      'email', new.email, 'source', new.source, 'source_detail', new.source_detail, 'status', new.status,
      'created_at', new.created_at));
  end if;
  return null;
exception when others then
  raise warning 'api_on_lead: %', sqlerrm;
  return null;
end;
$$;

create trigger leads_api_created after insert on public.leads
  for each row execute function private.api_on_lead();

-- student.activity: what the student did in the app (signup, demo, cancelled payment, refund, webinar).
-- A purchase is course.purchased, and the AI's own notes are never events (no loops).
create or replace function private.api_on_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type in ('appx', 'webinar') and coalesce(new.meta ->> 'kind', '') <> 'purchase' then
    perform private.api_emit('student.activity', new.lead_id, jsonb_build_object(
      'activity', case new.type
                    when 'appx' then case new.meta ->> 'kind'
                                       when 'signup' then 'signup'
                                       when 'demo' then 'demo_requested'
                                       when 'contact' then 'contact_form'
                                       when 'cancelled' then 'payment_cancelled'
                                       when 'refund' then 'refund'
                                       else 'app_activity' end
                    else 'webinar' end,
      'text', new.body,
      'details', coalesce(new.meta, '{}'::jsonb)));
  end if;
  return null;
exception when others then
  raise warning 'api_on_activity: %', sqlerrm;
  return null;
end;
$$;

create trigger lead_activities_api after insert on public.lead_activities
  for each row execute function private.api_on_activity();

create or replace function private.api_on_purchase()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'paid' and not new.is_test and new.lead_id is not null then
    perform private.api_emit('course.purchased', new.lead_id, jsonb_build_object(
      'course', new.item, 'amount', new.amount, 'currency', 'INR', 'transaction_id', new.txn_id,
      'payment_mode', new.payment_mode, 'coupon', new.coupon, 'purchased_at', new.purchased_at, 'expires_at', new.expires_at));
  end if;
  return null;
exception when others then
  raise warning 'api_on_purchase: %', sqlerrm;
  return null;
end;
$$;

create trigger appx_purchases_api after insert on public.appx_purchases
  for each row execute function private.api_on_purchase();

-- whatsapp.reply (text) and whatsapp.button_click (a quick-reply button or a list row)
create or replace function private.api_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.direction = 'in' then
    if new.type = 'text' then
      perform private.api_emit('whatsapp.reply', new.lead_id, jsonb_build_object(
        'message_id', new.id, 'text', new.body, 'received_at', new.created_at,
        -- STOP / opt-out words: the student is switched off right after this and cannot be messaged
        'opt_out_request', coalesce(new.body, '') ~* '^\s*(stop|unsubscribe|cancel|opt\s*-?out|stop\s+messages?|band\s+karo|mat\s+bhejo)\s*[.!]*\s*$'));
    elsif new.type in ('button', 'interactive') then
      perform private.api_emit('whatsapp.button_click', new.lead_id, jsonb_build_object(
        'message_id', new.id, 'button_text', new.body, 'received_at', new.created_at));
    end if;
  end if;
  return null;
exception when others then
  raise warning 'api_on_message: %', sqlerrm;
  return null;
end;
$$;

create trigger wa_messages_api after insert on public.wa_messages
  for each row execute function private.api_on_message();

-- The edge function takes due deliveries (and gives them back with the result)
create or replace function public.api_claim_deliveries(p_limit int)
returns setof public.webhook_deliveries
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with due as (
    select d.id from webhook_deliveries d
     where (d.status in ('pending', 'retry') and d.next_attempt_at <= now())
        or (d.status = 'sending' and d.locked_at < now() - interval '3 minutes')
     order by d.seq
     limit greatest(p_limit, 1)
     for update skip locked
  )
  update webhook_deliveries d
     set status = 'sending', locked_at = now()
    from due
   where d.id = due.id
  returning d.*;
end;
$$;

-- Up to 3 more tries after the first one: after 1 minute, 5 minutes, 15 minutes.
create or replace function public.api_delivery_result(p_id uuid, p_ok boolean, p_code int, p_error text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  d webhook_deliveries;
  v_status text;
  v_next timestamptz;
begin
  select * into d from webhook_deliveries where id = p_id for update;
  if not found then
    return null;
  end if;
  if p_ok then
    v_status := 'ok';
  elsif d.attempts + 1 >= 4 then
    v_status := 'failed';
  else
    v_status := 'retry';
    v_next := now() + case d.attempts when 0 then interval '1 minute' when 1 then interval '5 minutes' else interval '15 minutes' end;
  end if;
  update webhook_deliveries
     set status = v_status, attempts = attempts + 1, locked_at = null, last_code = p_code,
         last_error = case when p_ok then null else left(coalesce(p_error, 'failed'), 300) end,
         next_attempt_at = coalesce(v_next, next_attempt_at),
         delivered_at = case when p_ok then now() else delivered_at end
   where id = p_id;
  return v_status;
end;
$$;

-- "Send a test event" in the app: queues one made-up event
create or replace function public.api_webhook_test()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
  c api_config;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  select * into c from api_config where id = 1;
  if c.webhook_url is null or not c.webhook_enabled then
    raise exception 'Paste the webhook address, switch it on and save first';
  end if;
  insert into webhook_deliveries (id, event, payload)
  values (v_id, 'webhook.test', jsonb_build_object(
    'id', v_id, 'event', 'webhook.test', 'timestamp', now(),
    'student_id', '00000000-0000-0000-0000-000000000000',
    'student', jsonb_build_object('id', '00000000-0000-0000-0000-000000000000', 'name', 'Test Student', 'phone', '+910000000000'),
    'data', jsonb_build_object('message', 'This is a test from WhatsWeb. Nothing happened to any student.')));
  perform private.api_kick();
end;
$$;

revoke execute on function public.api_claim_deliveries(int), public.api_delivery_result(uuid, boolean, int, text) from public, anon, authenticated;
grant execute on function public.api_claim_deliveries(int), public.api_delivery_result(uuid, boolean, int, text) to service_role;
revoke execute on function public.api_webhook_test() from public, anon;
grant execute on function public.api_webhook_test() to authenticated;

-- Every minute: deliveries that are due (retries), and old rows are cleared
create or replace function private.api_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from api_hits where minute < now() - interval '1 hour';
  delete from webhook_deliveries where status in ('ok', 'failed') and created_at < now() - interval '30 days';
  delete from api_log where at < now() - interval '180 days';
  if exists (select 1 from webhook_deliveries
              where (status in ('pending', 'retry') and next_attempt_at <= now())
                 or (status = 'sending' and locked_at < now() - interval '3 minutes')) then
    perform private.api_kick();
  end if;
exception when others then
  raise warning 'api_tick: %', sqlerrm;
end;
$$;

do $$
begin
  perform cron.schedule('whatsweb-api', '* * * * *', 'select private.api_tick()');
exception when others then
  raise warning 'Could not schedule the webhook delivery (%): failed webhooks are only retried when a new event comes', sqlerrm;
end $$;
