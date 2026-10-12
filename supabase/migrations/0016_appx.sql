-- AIFM Education app (Appx): signups, demo requests, purchases, cancelled payments, refunds.
--   * The Appx CMS (Integrations > Webhooks) calls the edge function "appx" (secret address, one webhook per
--     event); the function hands each event to appx_apply() below.
--   * A student is matched to a lead by phone, then by e-mail. Nobody found -> a new lead (source "appx").
--   * A purchase can mark the lead "Admission Done" (switch in the app) and stops the automatic reminders.
--   * Each lead shows one summary (appx_state, appx_paid, appx_item ...); the details are in appx_purchases.

-- ---------------------------------------------------------------------------
-- History entry type
-- ---------------------------------------------------------------------------

alter table public.lead_activities drop constraint lead_activities_type_check;
alter table public.lead_activities add constraint lead_activities_type_check check (type in (
  'created', 'remark', 'status', 'call', 'whatsapp', 'sms', 'email',
  'assigned', 'reminder', 'duplicate', 'edit', 'temperature', 'lost_reason', 'wa', 'webinar', 'appx'
));

-- ---------------------------------------------------------------------------
-- Summary on the lead
-- ---------------------------------------------------------------------------

alter table public.leads
  add column appx_state text check (appx_state in ('signed_up', 'purchased', 'cancelled', 'refunded')),
  add column appx_paid numeric not null default 0,
  add column appx_item text,
  add column appx_at timestamptz;

create index leads_appx_state_idx on public.leads (appx_state) where appx_state is not null;

-- Only the Appx connection writes the Appx fields: an agent cannot mark a lead "Purchased" from the app.
create or replace function public.leads_before_write()
returns trigger
language plpgsql
as $$
begin
  new.phone := normalize_phone(new.phone);
  new.email := nullif(lower(trim(new.email)), '');
  new.name := trim(coalesce(new.name, ''));
  if tg_op = 'INSERT' then
    if new.assigned_to is not null then
      new.assigned_at := now();
    end if;
  else
    new.updated_at := now();
    if new.assigned_to is distinct from old.assigned_to then
      new.assigned_at := case when new.assigned_to is null then null else now() end;
    end if;
  end if;

  if auth.uid() is not null and coalesce(current_setting('app.webinar_write', true), '') <> 'on' then
    if tg_op = 'INSERT' then
      new.webinar_state := null;
      new.webinar_paid := 0;
      new.webinar_title := null;
      new.webinar_attended := null;
      new.webinar_at := null;
    else
      new.webinar_state := old.webinar_state;
      new.webinar_paid := old.webinar_paid;
      new.webinar_title := old.webinar_title;
      new.webinar_attended := old.webinar_attended;
      new.webinar_at := old.webinar_at;
    end if;
  end if;

  if auth.uid() is not null and coalesce(current_setting('app.appx_write', true), '') <> 'on' then
    if tg_op = 'INSERT' then
      new.appx_state := null;
      new.appx_paid := 0;
      new.appx_item := null;
      new.appx_at := null;
    else
      new.appx_state := old.appx_state;
      new.appx_paid := old.appx_paid;
      new.appx_item := old.appx_item;
      new.appx_at := old.appx_at;
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Two settings the admin can change in the app.
create table public.appx_config (
  id int primary key default 1 check (id = 1),
  -- a purchase sets the lead's status to "Admission Done"
  set_status boolean not null default true,
  -- purchases below this amount (rupees) do not change the status (a Rs 99 test series is not an admission)
  min_amount numeric not null default 0 check (min_amount >= 0),
  updated_at timestamptz not null default now()
);
alter table public.appx_config enable row level security;
revoke all on public.appx_config from anon, authenticated;
insert into public.appx_config (id) values (1);

create table public.appx_purchases (
  txn_id text primary key,
  lead_id uuid references public.leads (id) on delete set null,
  phone text,
  email text,
  item text,
  product_type text,
  amount numeric,
  payment_mode text,
  coupon text,
  invoice text,
  purchased_at timestamptz,
  expires_at timestamptz,
  status text not null default 'paid' check (status in ('paid', 'refunded')),
  status_at timestamptz,
  refunded_amount numeric not null default 0,
  is_test boolean generated always as (left(txn_id, 5) = 'test_') stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index appx_purchases_lead_idx on public.appx_purchases (lead_id);
create index appx_purchases_item_idx on public.appx_purchases (item);

-- Every event is written here first, then processed (a failed one is tried again every hour).
create table public.appx_events (
  id bigint generated always as identity primary key,
  event_key text not null unique,
  kind text not null,
  -- received (waiting), ok, ignored, error
  outcome text not null default 'received',
  error text,
  attempts int not null default 0,
  body jsonb,
  is_test boolean generated always as (left(event_key, 5) = 'test:') stored,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index appx_events_open_idx on public.appx_events (created_at) where outcome in ('received', 'error');
create index appx_events_kind_idx on public.appx_events (kind, created_at);

alter table public.appx_purchases enable row level security;
alter table public.appx_events enable row level security;
revoke all on public.appx_purchases, public.appx_events from anon, authenticated;
grant select on public.appx_purchases, public.appx_events to authenticated;

-- An agent sees the purchases of the leads they can see; only the admin sees the raw events.
create policy appx_purchases_select on public.appx_purchases
  for select to authenticated using (exists (select 1 from public.leads l where l.id = lead_id));
create policy appx_events_select on public.appx_events
  for select to authenticated using ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.ax_note(p_lead uuid, p_body text, p_meta jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into lead_activities (lead_id, user_id, type, body, meta)
  values (p_lead, null, 'appx', p_body, coalesce(p_meta, '{}'::jsonb));
$$;

-- The lead of this phone / e-mail; a new one (source "appx") if there is none.
-- Returns {id, new}. A lead that exists keeps what it has; only empty name / phone / e-mail are filled.
create or replace function private.ax_lead_for(p_name text, p_phone text, p_email text, p_detail text, p_extra jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := phone_key(p_phone);
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_id uuid;
  v_res jsonb;
begin
  if v_key is not null then
    select id into v_id from leads where phone_key = v_key order by created_at limit 1;
  end if;
  if v_id is null and v_email is not null then
    select id into v_id from leads where lower(email) = v_email order by created_at limit 1;
  end if;
  if v_id is not null then
    update leads
       set email = coalesce(email, v_email),
           phone = coalesce(phone, nullif(trim(p_phone), '')),
           name = case when name = '' then coalesce(v_name, '') else name end
     where id = v_id
       and ((email is null and v_email is not null) or (phone is null and v_key is not null) or (name = '' and v_name is not null));
    return jsonb_build_object('id', v_id, 'new', false);
  end if;
  if v_key is null and v_email is null then
    return jsonb_build_object('id', null, 'new', false);
  end if;
  v_res := public.ingest_lead(coalesce(v_name, ''), p_phone, v_email, 'appx', p_detail, null, coalesce(p_extra, '{}'::jsonb));
  return jsonb_build_object('id', nullif(v_res ->> 'id', '')::uuid, 'new', v_res ->> 'status' = 'created');
end;
$$;

-- What a lead shows: bought or not, how much (after refunds), what, and when.
create or replace function private.ax_refresh(p_lead uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid_n int;
  v_refunded_n int;
  v_paid numeric;
  v_item text;
  v_at timestamptz;
  v_state text;
begin
  if p_lead is null then
    return;
  end if;
  perform set_config('app.appx_write', 'on', true);

  select count(*) filter (where status = 'paid'),
         count(*) filter (where status = 'refunded'),
         coalesce(sum(greatest(coalesce(amount, 0) - refunded_amount, 0)) filter (where status = 'paid'), 0),
         max(coalesce(status_at, purchased_at, created_at))
    into v_paid_n, v_refunded_n, v_paid, v_at
    from appx_purchases where lead_id = p_lead;
  if v_paid_n = 0 and v_refunded_n = 0 then
    return;
  end if;
  select item into v_item from appx_purchases
   where lead_id = p_lead and status = 'paid'
   order by coalesce(purchased_at, created_at) desc limit 1;
  v_state := case when v_paid_n > 0 then 'purchased' else 'refunded' end;

  update leads
     set appx_state = v_state, appx_paid = v_paid, appx_item = v_item, appx_at = v_at
   where id = p_lead
     and (appx_state is distinct from v_state or appx_paid is distinct from v_paid
          or appx_item is distinct from v_item or appx_at is distinct from v_at);
end;
$$;

-- Sets the summary state without touching the money (signup, cancelled payment).
create or replace function private.ax_state(p_lead uuid, p_state text, p_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_lead is null then
    return;
  end if;
  perform set_config('app.appx_write', 'on', true);
  update leads
     set appx_state = p_state, appx_at = greatest(coalesce(appx_at, p_at), p_at)
   where id = p_lead
     and case p_state
           when 'signed_up' then appx_state is null
           when 'cancelled' then appx_state is null or appx_state in ('signed_up', 'cancelled')
           else false
         end;
end;
$$;

-- ---------------------------------------------------------------------------
-- One event from the app (the edge function gives it in a fixed shape)
-- p_kind: signup | demo | contact | purchase | cancelled | refund
-- p_d: name, phone, email, state, district, item, product_type, amount, txn_id, payment_mode, coupon, invoice,
--      purchased_at, expires_at, status, link, info (object), refund_amount
-- ---------------------------------------------------------------------------

create or replace function public.appx_apply(p_kind text, p_ts timestamptz, p_d jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kind text := lower(trim(coalesce(p_kind, '')));
  v_ts timestamptz := coalesce(p_ts, now());
  v_name text := nullif(trim(coalesce(p_d ->> 'name', '')), '');
  v_phone text := nullif(trim(coalesce(p_d ->> 'phone', '')), '');
  v_email text := nullif(lower(trim(coalesce(p_d ->> 'email', ''))), '');
  v_item text := nullif(trim(coalesce(p_d ->> 'item', '')), '');
  v_txn text := nullif(trim(coalesce(p_d ->> 'txn_id', '')), '');
  v_amount numeric := nullif(p_d ->> 'amount', '')::numeric;
  v_refund numeric := nullif(p_d ->> 'refund_amount', '')::numeric;
  v_when timestamptz := nullif(p_d ->> 'purchased_at', '')::timestamptz;
  v_expires timestamptz := nullif(p_d ->> 'expires_at', '')::timestamptz;
  v_extra jsonb;
  v_info jsonb := case when jsonb_typeof(p_d -> 'info') = 'object' then p_d -> 'info' else '{}'::jsonb end;
  v_cfg appx_config;
  v_found jsonb;
  v_lead uuid;
  v_new boolean := false;
  v_label text;
  v_detail text;
  v_row appx_purchases;
  v_is_new_purchase boolean := false;
  v_agent uuid;
  v_full boolean;
  v_test boolean := left(coalesce(v_txn, ''), 5) = 'test_' or coalesce(v_email, '') like 'appx-test-%@example.com';
  v_status text;
begin
  if v_kind not in ('signup', 'demo', 'contact', 'purchase', 'cancelled', 'refund') then
    return jsonb_build_object('status', 'ignored');
  end if;
  if phone_key(v_phone) is null and v_email is null then
    return jsonb_build_object('status', 'invalid', 'reason', 'no phone and no e-mail');
  end if;
  if v_test then
    perform set_config('app.skip_notify', 'on', true);
  end if;

  -- same person, one event at a time
  perform pg_advisory_xact_lock(hashtext('appx:' || coalesce(phone_key(v_phone), v_email, '')));
  select * into v_cfg from appx_config where id = 1;
  v_label := coalesce(v_item, 'a course');

  v_extra := jsonb_strip_nulls(jsonb_build_object(
    'state', nullif(trim(coalesce(p_d ->> 'state', '')), ''),
    'district', nullif(trim(coalesce(p_d ->> 'district', '')), '')) || v_info);

  if v_kind = 'refund' then
    -- the refund event has no name: find the purchase by its transaction, else by the person
    select * into v_row from appx_purchases where txn_id = v_txn for update;
    if not found then
      select id into v_lead from leads
       where (phone_key(v_phone) is not null and phone_key = phone_key(v_phone))
          or (v_email is not null and lower(email) = v_email)
       order by created_at limit 1;
      select * into v_row from appx_purchases
       where lead_id = v_lead and status = 'paid'
       order by coalesce(purchased_at, created_at) desc limit 1 for update;
    end if;
    if not found then
      return jsonb_build_object('status', 'invalid', 'reason', 'refund for a purchase we do not know');
    end if;
    v_lead := v_row.lead_id;
    v_label := coalesce(v_row.item, 'a course');
    v_full := v_refund is null or v_refund >= coalesce(v_row.amount, 0);
    v_status := case when v_full then 'refunded' else 'paid' end;
    if v_row.refunded_amount is distinct from coalesce(v_refund, v_row.amount, 0) or v_row.status <> v_status then
      update appx_purchases
         set refunded_amount = coalesce(v_refund, v_row.amount, 0),
             status = v_status,
             status_at = v_ts, updated_at = now()
       where txn_id = v_row.txn_id
      returning * into v_row;
      if v_lead is not null then
        perform private.ax_note(v_lead, 'Refunded ' || private.wg_money(v_row.refunded_amount) || ' for ' || v_label,
          jsonb_build_object('kind', v_kind, 'txn_id', v_row.txn_id, 'amount', v_row.refunded_amount));
      end if;
    end if;
    perform private.ax_refresh(v_lead);
    return jsonb_build_object('status', 'ok', 'lead_id', v_lead, 'new_lead', false);
  end if;

  v_detail := case v_kind
    when 'signup' then 'App signup'
    when 'demo' then 'App demo: ' || v_label
    when 'contact' then 'Website contact'
    when 'cancelled' then 'App payment cancelled: ' || v_label
    else 'App purchase: ' || v_label end;
  v_found := private.ax_lead_for(v_name, v_phone, v_email, v_detail, v_extra);
  v_lead := nullif(v_found ->> 'id', '')::uuid;
  v_new := coalesce((v_found ->> 'new')::boolean, false);
  if v_lead is null then
    return jsonb_build_object('status', 'invalid', 'reason', 'could not make a lead');
  end if;

  if v_kind = 'signup' then
    perform private.ax_state(v_lead, 'signed_up', v_ts);
    perform private.ax_note(v_lead, 'Signed up in the AIFM Education app',
      jsonb_build_object('kind', v_kind) || case when v_extra = '{}'::jsonb then '{}'::jsonb else jsonb_build_object('details', v_extra) end);

  elsif v_kind = 'demo' then
    perform private.ax_note(v_lead, 'Asked for a demo of ' || v_label,
      jsonb_build_object('kind', v_kind, 'link', p_d ->> 'link'));

  elsif v_kind = 'contact' then
    perform private.ax_note(v_lead, 'Sent the contact form on the website', jsonb_build_object('kind', v_kind));

  elsif v_kind = 'cancelled' then
    perform private.ax_state(v_lead, 'cancelled', v_ts);
    perform private.ax_note(v_lead, 'Payment cancelled for ' || v_label,
      jsonb_build_object('kind', v_kind, 'link', p_d ->> 'link', 'status', p_d ->> 'status'));
    select assigned_to into v_agent from leads where id = v_lead;
    -- a follow-up for the agent, once (not for tests or old events)
    if v_agent is not null and not v_test and v_ts > now() - interval '2 days'
       and not exists (select 1 from reminders r where r.lead_id = v_lead and not r.is_done and r.note like 'Payment cancelled%') then
      insert into reminders (lead_id, user_id, remind_at, note)
      values (v_lead, v_agent, now() + interval '1 hour', 'Payment cancelled in the app: ' || v_label);
      perform private.push(jsonb_build_array(jsonb_build_object(
        'user_id', v_agent, 'title', '⚠️ Payment cancelled',
        'body', coalesce(nullif((select name from leads where id = v_lead), ''), 'A student') || ' cancelled the payment for ' || v_label,
        'data', jsonb_build_object('lead_id', v_lead))));
    end if;

  elsif v_kind = 'purchase' then
    v_txn := coalesce(v_txn, 'appx:' || coalesce(phone_key(v_phone), v_email, '') || '|' || coalesce(v_item, '') || '|'
                      || to_char(coalesce(v_when, v_ts) at time zone 'Asia/Kolkata', 'YYYY-MM-DD'));
    select * into v_row from appx_purchases where txn_id = v_txn for update;
    v_is_new_purchase := not found;
    if v_is_new_purchase then
      insert into appx_purchases (txn_id, lead_id, phone, email, item, product_type, amount, payment_mode, coupon, invoice,
                                  purchased_at, expires_at, status_at)
      values (v_txn, v_lead, v_phone, v_email, v_item, nullif(trim(coalesce(p_d ->> 'product_type', '')), ''), v_amount,
              nullif(trim(coalesce(p_d ->> 'payment_mode', '')), ''), nullif(trim(coalesce(p_d ->> 'coupon', '')), ''),
              nullif(trim(coalesce(p_d ->> 'invoice', '')), ''), coalesce(v_when, v_ts), v_expires, v_ts)
      returning * into v_row;
    else
      update appx_purchases
         set lead_id = coalesce(lead_id, v_lead), item = coalesce(v_item, item), amount = coalesce(v_amount, amount),
             expires_at = coalesce(v_expires, expires_at), updated_at = now()
       where txn_id = v_txn
      returning * into v_row;
    end if;

    if v_is_new_purchase then
      perform private.ax_note(v_lead, 'Bought ' || v_label || ' for ' || private.wg_money(v_amount),
        jsonb_build_object('kind', v_kind, 'txn_id', v_txn, 'amount', v_amount, 'coupon', v_row.coupon, 'expires_at', v_expires));
      select assigned_to, status into v_agent, v_status from leads where id = v_lead;
      if v_cfg.set_status and coalesce(v_amount, 0) >= v_cfg.min_amount and v_status <> 'Admission Done'
         and exists (select 1 from lead_statuses where name = 'Admission Done') then
        update leads set status = 'Admission Done' where id = v_lead;
      end if;
      if v_agent is not null and not v_test and v_ts > now() - interval '2 days' then
        perform private.push(jsonb_build_array(jsonb_build_object(
          'user_id', v_agent, 'title', '💰 App purchase',
          'body', coalesce(nullif((select name from leads where id = v_lead), ''), 'A student') || ' bought ' || v_label || ' for ' || private.wg_money(v_amount),
          'data', jsonb_build_object('lead_id', v_lead))));
      end if;
    end if;
    perform private.ax_refresh(v_lead);
  end if;

  return jsonb_build_object('status', 'ok', 'lead_id', v_lead, 'new_lead', v_new);
end;
$$;

revoke execute on function public.appx_apply(text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.appx_apply(text, timestamptz, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- For the app (admin)
-- ---------------------------------------------------------------------------

create or replace function public.appx_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cfg appx_config;
  v_last appx_events;
begin
  if not is_admin() then
    raise exception 'Only admin can see this';
  end if;
  select * into v_cfg from appx_config where id = 1;
  select * into v_last from appx_events order by id desc limit 1;
  return jsonb_build_object(
    'set_status', v_cfg.set_status,
    'min_amount', v_cfg.min_amount,
    'last_event', v_last.kind,
    'last_event_at', v_last.created_at,
    'last_outcome', v_last.outcome,
    'events_24h', (select count(*) from appx_events where created_at > now() - interval '24 hours' and not is_test),
    'errors', (select count(*) from appx_events where outcome = 'error' and not is_test),
    'waiting', (select count(*) from appx_events where outcome = 'received' and created_at < now() - interval '2 minutes'),
    'signups', (select count(*) from appx_events where kind = 'signup' and outcome = 'ok' and not is_test),
    'purchases', (select count(*) from appx_purchases where status = 'paid' and not is_test));
end;
$$;

create or replace function public.appx_set_config(p_set_status boolean, p_min_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if p_min_amount is null or p_min_amount < 0 or p_min_amount > 10000000 then
    raise exception 'Use an amount in rupees (0 or more)';
  end if;
  update appx_config set set_status = coalesce(p_set_status, set_status), min_amount = p_min_amount, updated_at = now() where id = 1;
end;
$$;

-- Numbers: signups, demo requests, purchases, money after refunds, cancelled payments; per course.
create or replace function public.appx_stats(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_totals jsonb;
  v_items jsonb;
begin
  if not is_admin() then
    raise exception 'Only admin can see these numbers';
  end if;

  select jsonb_build_object(
    'signups', (select count(*) from appx_events e where e.kind = 'signup' and e.outcome = 'ok' and not e.is_test
                 and e.created_at >= p_from and e.created_at < p_to),
    'demos', (select count(*) from appx_events e where e.kind = 'demo' and e.outcome = 'ok' and not e.is_test
               and e.created_at >= p_from and e.created_at < p_to),
    'contacts', (select count(*) from appx_events e where e.kind = 'contact' and e.outcome = 'ok' and not e.is_test
                  and e.created_at >= p_from and e.created_at < p_to),
    'cancelled', (select count(*) from appx_events e where e.kind = 'cancelled' and e.outcome = 'ok' and not e.is_test
                   and e.created_at >= p_from and e.created_at < p_to),
    'purchases', (select count(*) from appx_purchases p where not p.is_test and p.status = 'paid'
                   and coalesce(p.purchased_at, p.created_at) >= p_from and coalesce(p.purchased_at, p.created_at) < p_to),
    'revenue', (select coalesce(sum(greatest(coalesce(p.amount, 0) - p.refunded_amount, 0)), 0) from appx_purchases p
                 where not p.is_test and p.status = 'paid'
                   and coalesce(p.purchased_at, p.created_at) >= p_from and coalesce(p.purchased_at, p.created_at) < p_to),
    'refunded', (select coalesce(sum(p.refunded_amount), 0) from appx_purchases p
                  where not p.is_test and p.refunded_amount > 0
                    and coalesce(p.status_at, p.created_at) >= p_from and coalesce(p.status_at, p.created_at) < p_to))
    into v_totals;

  select coalesce(jsonb_agg(row_to_json(x) order by x.revenue desc, x.purchases desc), '[]'::jsonb) into v_items
  from (
    select coalesce(p.item, '(no name)') as item,
           count(*) as purchases,
           coalesce(sum(greatest(coalesce(p.amount, 0) - p.refunded_amount, 0)), 0) as revenue
      from appx_purchases p
     where not p.is_test and p.status = 'paid'
       and coalesce(p.purchased_at, p.created_at) >= p_from and coalesce(p.purchased_at, p.created_at) < p_to
     group by coalesce(p.item, '(no name)')
     order by 3 desc, 2 desc
     limit 10
  ) x;

  return v_totals || jsonb_build_object('items', v_items);
end;
$$;

-- "Send a test" in the app makes a test student; this removes everything the tests made (and only that).
create or replace function public.appx_clear_tests()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_leads int;
  v_buys int;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  delete from appx_purchases where is_test;
  get diagnostics v_buys = row_count;
  delete from appx_events where is_test;
  delete from leads where source = 'appx' and phone is null and email like 'appx-test-%@example.com';
  get diagnostics v_leads = row_count;
  return jsonb_build_object('leads', v_leads, 'purchases', v_buys);
end;
$$;

revoke execute on function public.appx_overview() from public, anon;
revoke execute on function public.appx_set_config(boolean, numeric) from public, anon;
revoke execute on function public.appx_stats(timestamptz, timestamptz) from public, anon;
revoke execute on function public.appx_clear_tests() from public, anon;
grant execute on function public.appx_overview() to authenticated;
grant execute on function public.appx_set_config(boolean, numeric) to authenticated;
grant execute on function public.appx_stats(timestamptz, timestamptz) to authenticated;
grant execute on function public.appx_clear_tests() to authenticated;

-- ---------------------------------------------------------------------------
-- A broadcast can go to "bought in the app" or to "everyone who has not bought"
-- ---------------------------------------------------------------------------

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
     and (p_filter ->> 'wa' is null or l.wa_state = p_filter ->> 'wa')
     and (p_filter ->> 'webinar' is null or l.webinar_state = p_filter ->> 'webinar')
     and (p_filter ->> 'attended' is null
          or (p_filter ->> 'attended' = 'yes' and l.webinar_attended is true)
          or (p_filter ->> 'attended' = 'no' and l.webinar_attended is false))
     and (p_filter ->> 'appx' is null
          or (p_filter ->> 'appx' = 'not_purchased' and l.appx_state is distinct from 'purchased')
          or l.appx_state = p_filter ->> 'appx');
$$;

-- ---------------------------------------------------------------------------
-- Every hour: events that failed once are tried again
-- ---------------------------------------------------------------------------

create or replace function private.ax_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  -- old log lines (the leads and purchases themselves are never removed)
  delete from appx_events where outcome in ('ok', 'ignored') and created_at < now() - interval '120 days';

  if not exists (select 1 from appx_events where outcome in ('received', 'error') and attempts < 5) then
    return;
  end if;
  select value into v_url from private.config where key = 'functions_url';
  select value ->> 'webhook_key' into v_key from app_settings where key = 'integrations';
  if v_url is null or v_key is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/appx',
    body := '{"action": "retry"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key),
    timeout_milliseconds := 60000
  );
exception when others then
  raise warning 'ax_tick: %', sqlerrm;
end;
$$;

do $$
begin
  perform cron.schedule('whatsweb-appx', '17 * * * *', 'select private.ax_tick()');
exception when others then
  raise warning 'Could not schedule the Appx retry (%): failed events stay until the next event', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- The automatic reminder never goes to someone who has bought in the app
-- ---------------------------------------------------------------------------

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
         and l.appx_state is distinct from 'purchased'
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
