-- Webinar.gg: who registered, who paid, who came.
--   * Webinar.gg calls the edge function "webinar-gg" (secret address) for every registration / payment /
--     refund; the function hands each event to webinar_apply() below.
--   * A student is matched to a lead by e-mail. No lead with that e-mail -> a new lead (source "webinar").
--   * Each lead shows one summary (webinar_state, webinar_paid, ...); the details are in the two tables.
--   * Attendance is copied from the Webinar.gg API every hour (webinar_set_attendance).
--   * The Webinar.gg API token lives in webinar_config, which only the edge function can read.
-- Webinar payments are kept apart from course admission: they never change the lead's status.

-- ---------------------------------------------------------------------------
-- History entry type
-- ---------------------------------------------------------------------------

alter table public.lead_activities drop constraint lead_activities_type_check;
alter table public.lead_activities add constraint lead_activities_type_check check (type in (
  'created', 'remark', 'status', 'call', 'whatsapp', 'sms', 'email',
  'assigned', 'reminder', 'duplicate', 'edit', 'temperature', 'lost_reason', 'wa', 'webinar'
));

-- ---------------------------------------------------------------------------
-- Summary on the lead
-- ---------------------------------------------------------------------------

alter table public.leads
  add column webinar_state text check (webinar_state in ('registered', 'paid', 'failed', 'refunded', 'cancelled', 'waitlisted')),
  add column webinar_paid numeric not null default 0,
  add column webinar_title text,
  add column webinar_attended boolean,
  add column webinar_at timestamptz;

create index leads_webinar_state_idx on public.leads (webinar_state) where webinar_state is not null;

-- Only the webinar sync writes the webinar fields: an agent cannot mark a lead "Paid" from the app.
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
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Set by the edge function only: the Webinar.gg API token and the amount unit.
create table public.webinar_config (
  id int primary key default 1 check (id = 1),
  api_token text,
  -- Webinar.gg may send 14900 for Rs 149 (paise). 100 then turns it into rupees.
  amount_divisor numeric not null default 1 check (amount_divisor >= 1),
  last_sync_at timestamptz,
  last_sync_note text,
  updated_at timestamptz not null default now()
);
alter table public.webinar_config enable row level security;
revoke all on public.webinar_config from anon, authenticated;
insert into public.webinar_config (id) values (1);

create table public.webinar_registrations (
  registration_id text primary key,
  webinar_id text,
  webinar_title text,
  email text,
  name text,
  lead_id uuid references public.leads (id) on delete set null,
  -- as Webinar.gg says: approved, pending, rejected, waitlisted, cancelled ...
  status text,
  status_at timestamptz,
  payment_status text,
  registered_at timestamptz,
  attended boolean,
  attendance_checked_at timestamptz,
  -- made by "Send a test" in the app: never counted in the numbers, never asked from Webinar.gg
  is_test boolean generated always as (left(registration_id, 5) = 'test_') stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index webinar_registrations_lead_idx on public.webinar_registrations (lead_id);
create index webinar_registrations_webinar_idx on public.webinar_registrations (webinar_id);
create index webinar_registrations_email_idx on public.webinar_registrations (email);

create table public.webinar_payments (
  payment_id text primary key,
  registration_id text,
  order_id text,
  webinar_id text,
  email text,
  lead_id uuid references public.leads (id) on delete set null,
  status text not null check (status in ('paid', 'failed', 'refunded')),
  status_at timestamptz,
  currency text,
  -- in rupees (the amounts as received, divided by webinar_config.amount_divisor)
  ticket_amount numeric,
  processing_fee numeric,
  total_charged numeric,
  refunded_amount numeric not null default 0,
  refund_status text,
  -- the amounts exactly as Webinar.gg sent them: {ticket, fee, total, refunded}
  raw jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  -- null: not checked yet, true: Webinar.gg API confirms it, false: the API does not know this person
  verified boolean,
  is_test boolean generated always as (left(payment_id, 5) = 'test_' or left(coalesce(registration_id, ''), 5) = 'test_') stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index webinar_payments_lead_idx on public.webinar_payments (lead_id);
create index webinar_payments_registration_idx on public.webinar_payments (registration_id);
create index webinar_payments_webinar_idx on public.webinar_payments (webinar_id);

-- Every event is written here first (the same delivery twice is dropped), then processed.
create table public.webinar_events (
  id bigint generated always as identity primary key,
  event_key text not null unique,
  event text,
  event_at timestamptz,
  -- received (waiting), ok, ignored, error
  outcome text not null default 'received',
  error text,
  attempts int not null default 0,
  body jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index webinar_events_open_idx on public.webinar_events (created_at) where outcome in ('received', 'error');

alter table public.webinar_registrations enable row level security;
alter table public.webinar_payments enable row level security;
alter table public.webinar_events enable row level security;
revoke all on public.webinar_registrations, public.webinar_payments, public.webinar_events from anon, authenticated;
grant select on public.webinar_registrations, public.webinar_payments, public.webinar_events to authenticated;

-- An agent sees the webinar details of the leads they can see; only the admin sees the raw events.
create policy webinar_registrations_select on public.webinar_registrations
  for select to authenticated using (exists (select 1 from public.leads l where l.id = lead_id));
create policy webinar_payments_select on public.webinar_payments
  for select to authenticated using (exists (select 1 from public.leads l where l.id = lead_id));
create policy webinar_events_select on public.webinar_events
  for select to authenticated using ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.wg_divisor()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select amount_divisor from webinar_config where id = 1), 1);
$$;

-- 149 -> "₹149", 149.5 -> "₹149.5"
create or replace function private.wg_money(p_amount numeric, p_currency text default 'INR')
returns text
language sql
immutable
as $$
  select case when coalesce(upper(nullif(trim(p_currency), '')), 'INR') = 'INR' then '₹' else upper(trim(p_currency)) || ' ' end
         || trim(trailing '.' from regexp_replace(round(coalesce(p_amount, 0), 2)::text, '(\.\d*?)0+$', '\1'));
$$;

create or replace function private.wg_num(p numeric)
returns numeric
language sql
stable
as $$
  select case when p is null then null else round(p / private.wg_divisor(), 2) end;
$$;

create or replace function private.wg_note(p_lead uuid, p_body text, p_meta jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into lead_activities (lead_id, user_id, type, body, meta)
  values (p_lead, null, 'webinar', p_body, coalesce(p_meta, '{}'::jsonb));
$$;

-- What a lead shows: the newest registration, the money paid (after refunds), whether they came.
create or replace function private.wg_refresh(p_lead uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg webinar_registrations;
  v_paid numeric;
  v_paid_n int;
  v_refunded_n int;
  v_failed_n int;
  v_state text;
  v_at timestamptz;
begin
  if p_lead is null then
    return;
  end if;
  perform set_config('app.webinar_write', 'on', true);

  select * into v_reg
    from webinar_registrations
   where lead_id = p_lead
   order by coalesce(registered_at, created_at) desc, created_at desc
   limit 1;

  -- a payment that Webinar.gg's API says does not exist (verified = false) does not count
  select count(*) filter (where status = 'paid'),
         count(*) filter (where status = 'refunded'),
         count(*) filter (where status = 'failed')
    into v_paid_n, v_refunded_n, v_failed_n
    from webinar_payments
   where lead_id = p_lead and verified is not false;
  select coalesce(sum(greatest(coalesce(ticket_amount, total_charged, 0) - refunded_amount, 0)), 0) into v_paid
    from webinar_payments
   where lead_id = p_lead and verified is not false and status = 'paid';

  select max(greatest(coalesce(r.status_at, r.created_at), r.updated_at)) into v_at
    from webinar_registrations r where r.lead_id = p_lead;

  v_state := case
    when v_paid_n > 0 then 'paid'
    when v_refunded_n > 0 then 'refunded'
    when v_reg.registration_id is null and v_failed_n = 0 then null
    when lower(coalesce(v_reg.status, '')) in ('cancelled', 'canceled', 'rejected', 'declined') then 'cancelled'
    when lower(coalesce(v_reg.status, '')) in ('waitlisted', 'waitlist') then 'waitlisted'
    when v_failed_n > 0 then 'failed'
    else 'registered'
  end;

  update leads
     set webinar_state = v_state,
         webinar_paid = v_paid,
         webinar_title = v_reg.webinar_title,
         webinar_attended = v_reg.attended,
         webinar_at = v_at
   where id = p_lead
     and (webinar_state is distinct from v_state or webinar_paid is distinct from v_paid
          or webinar_title is distinct from v_reg.webinar_title
          or webinar_attended is distinct from v_reg.attended or webinar_at is distinct from v_at);
end;
$$;

-- The lead for this e-mail; a new one (source "webinar") if there is none.
create or replace function private.wg_lead_for(p_email text, p_name text, p_title text, p_reg text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_res jsonb;
begin
  if p_email is null then
    return null;
  end if;
  select id into v_id from leads where lower(email) = p_email order by created_at limit 1;
  if v_id is null then
    v_res := public.ingest_lead(coalesce(p_name, ''), null, p_email, 'webinar', p_title,
                                case when p_reg is null then null else 'webinar:' || p_reg end, '{}'::jsonb);
    v_id := nullif(v_res ->> 'id', '')::uuid;
  end if;
  if v_id is not null and p_name is not null then
    update leads set name = p_name where id = v_id and name = '';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- One event from Webinar.gg (the edge function gives it in a fixed shape)
-- p_d: registration_id, webinar_id, webinar_title, email, name, status, payment_status, registered_at,
--      payment_id, order_id, ticket_amount, processing_fee, total_charged, currency,
--      refunded_amount, refund_status
-- ---------------------------------------------------------------------------

create or replace function public.webinar_apply(p_event text, p_ts timestamptz, p_d jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event text := lower(trim(coalesce(p_event, '')));
  v_ts timestamptz := coalesce(p_ts, now());
  v_email text := nullif(lower(trim(coalesce(p_d ->> 'email', ''))), '');
  v_wid text := nullif(trim(coalesce(p_d ->> 'webinar_id', '')), '');
  v_title text := nullif(trim(coalesce(p_d ->> 'webinar_title', '')), '');
  v_name text := nullif(trim(coalesce(p_d ->> 'name', '')), '');
  v_reg text := nullif(trim(coalesce(p_d ->> 'registration_id', '')), '');
  v_pay text := nullif(trim(coalesce(p_d ->> 'payment_id', '')), '');
  v_order text := nullif(trim(coalesce(p_d ->> 'order_id', '')), '');
  v_status text := nullif(lower(trim(coalesce(p_d ->> 'status', ''))), '');
  v_pstatus text := nullif(lower(trim(coalesce(p_d ->> 'payment_status', ''))), '');
  v_currency text := nullif(upper(trim(coalesce(p_d ->> 'currency', ''))), '');
  v_registered timestamptz := nullif(p_d ->> 'registered_at', '')::timestamptz;
  v_ticket numeric := nullif(p_d ->> 'ticket_amount', '')::numeric;
  v_fee numeric := nullif(p_d ->> 'processing_fee', '')::numeric;
  v_total numeric := nullif(p_d ->> 'total_charged', '')::numeric;
  v_refunded numeric := nullif(p_d ->> 'refunded_amount', '')::numeric;
  v_rstatus text := nullif(trim(coalesce(p_d ->> 'refund_status', '')), '');
  v_lead uuid;
  v_agent uuid;
  v_reg_row webinar_registrations;
  v_pay_row webinar_payments;
  v_new_reg boolean := false;
  v_was_paid boolean := false;
  v_is_new_lead boolean;
  v_label text;
  v_amount numeric;
  v_full boolean;
  v_test boolean := left(coalesce(p_d ->> 'registration_id', ''), 5) = 'test_';
begin
  if v_event not in ('registration.created', 'registration.payment.completed', 'registration.payment.failed',
                     'registration.refunded', 'registration.status.changed') then
    return jsonb_build_object('status', 'ignored');
  end if;

  -- a test from the app: no push messages
  if v_test then
    perform set_config('app.skip_notify', 'on', true);
  end if;

  -- same person, one event at a time
  perform pg_advisory_xact_lock(hashtext('webinar:' || coalesce(v_email, v_reg, v_pay, '')));

  -- a registration needs an id: the real one, or "email + webinar" when Webinar.gg did not send it
  if v_reg is null and v_email is not null then
    select registration_id into v_reg
      from webinar_registrations
     where email = v_email and coalesce(webinar_id, '') = coalesce(v_wid, '')
     order by created_at desc limit 1;
    if v_reg is null then
      v_reg := 'email:' || v_email || '|' || coalesce(v_wid, '');
    end if;
  end if;
  if v_reg is null and v_pay is not null then
    select registration_id into v_reg from webinar_payments where payment_id = v_pay;
  end if;
  if v_reg is null then
    return jsonb_build_object('status', 'invalid', 'reason', 'no registration id and no e-mail');
  end if;

  select * into v_reg_row from webinar_registrations where registration_id = v_reg for update;
  v_new_reg := not found;

  -- the real id arrived after payments were saved under "email + webinar": move them over
  if v_new_reg and v_email is not null and left(v_reg, 6) <> 'email:' then
    update webinar_registrations
       set registration_id = v_reg
     where registration_id = 'email:' || v_email || '|' || coalesce(v_wid, '');
    if found then
      update webinar_payments set registration_id = v_reg
       where registration_id = 'email:' || v_email || '|' || coalesce(v_wid, '');
      select * into v_reg_row from webinar_registrations where registration_id = v_reg for update;
      v_new_reg := false;
    end if;
  end if;

  -- e-mail: from this event, else from what we already know
  v_email := coalesce(v_email, v_reg_row.email);
  v_wid := coalesce(v_wid, v_reg_row.webinar_id);
  v_title := coalesce(v_title, v_reg_row.webinar_title);
  v_lead := v_reg_row.lead_id;
  if v_lead is null then
    v_is_new_lead := v_email is not null and not exists (select 1 from leads where lower(email) = v_email);
    v_lead := private.wg_lead_for(v_email, v_name, v_title, v_reg);
  elsif v_name is not null then
    update leads set name = v_name where id = v_lead and name = '';
  end if;

  if v_new_reg then
    insert into webinar_registrations (registration_id, webinar_id, webinar_title, email, name, lead_id,
                                       status, status_at, payment_status, registered_at)
    values (v_reg, v_wid, v_title, v_email, v_name, v_lead,
            case when v_event in ('registration.created', 'registration.status.changed') then v_status end,
            case when v_event in ('registration.created', 'registration.status.changed') and v_status is not null then v_ts end,
            v_pstatus, coalesce(v_registered, case when v_event = 'registration.created' then v_ts end));
  else
    update webinar_registrations
       set webinar_id = coalesce(v_wid, webinar_id),
           webinar_title = coalesce(v_title, webinar_title),
           email = coalesce(v_email, email),
           name = coalesce(v_name, name),
           lead_id = coalesce(lead_id, v_lead),
           registered_at = coalesce(registered_at, v_registered, case when v_event = 'registration.created' then v_ts end),
           payment_status = case when v_pstatus is not null and v_ts >= coalesce(status_at, '-infinity') then v_pstatus else payment_status end,
           status = case when v_event in ('registration.created', 'registration.status.changed') and v_status is not null
                              and v_ts >= coalesce(status_at, '-infinity') then v_status else status end,
           status_at = case when v_event in ('registration.created', 'registration.status.changed') and v_status is not null
                                 and v_ts >= coalesce(status_at, '-infinity') then v_ts else status_at end,
           updated_at = now()
     where registration_id = v_reg;
  end if;

  v_label := coalesce(v_title, 'a webinar');

  if v_event = 'registration.created' then
    if v_new_reg and v_lead is not null then
      perform private.wg_note(v_lead, 'Registered for ' || v_label,
        jsonb_build_object('event', v_event, 'registration_id', v_reg, 'webinar_id', v_wid));
    end if;

  elsif v_event = 'registration.status.changed' then
    if v_lead is not null and v_status is not null then
      perform private.wg_note(v_lead, 'Webinar registration is now "' || v_status || '" (' || v_label || ')',
        jsonb_build_object('event', v_event, 'registration_id', v_reg, 'status', v_status));
    end if;

  elsif v_event in ('registration.payment.completed', 'registration.payment.failed') then
    v_pay := coalesce(v_pay, v_order,
                      case when v_event = 'registration.payment.failed' then 'failed:' || v_reg || ':' || floor(extract(epoch from v_ts))::text
                           else 'paid:' || v_reg end);
    select * into v_pay_row from webinar_payments where payment_id = v_pay for update;
    v_was_paid := found and v_pay_row.status = 'paid';
    if not found then
      insert into webinar_payments (payment_id, registration_id, order_id, webinar_id, email, lead_id, status, status_at, currency,
                                    ticket_amount, processing_fee, total_charged, raw, paid_at)
      values (v_pay, v_reg, v_order, v_wid, v_email, v_lead,
              case when v_event = 'registration.payment.completed' then 'paid' else 'failed' end, v_ts, v_currency,
              private.wg_num(v_ticket), private.wg_num(v_fee), private.wg_num(v_total),
              jsonb_strip_nulls(jsonb_build_object('ticket', v_ticket, 'fee', v_fee, 'total', v_total)),
              case when v_event = 'registration.payment.completed' then v_ts end);
    else
      update webinar_payments
         set registration_id = coalesce(registration_id, v_reg),
             order_id = coalesce(v_order, order_id),
             webinar_id = coalesce(v_wid, webinar_id),
             email = coalesce(v_email, email),
             lead_id = coalesce(lead_id, v_lead),
             currency = coalesce(v_currency, currency),
             ticket_amount = coalesce(private.wg_num(v_ticket), ticket_amount),
             processing_fee = coalesce(private.wg_num(v_fee), processing_fee),
             total_charged = coalesce(private.wg_num(v_total), total_charged),
             raw = raw || jsonb_strip_nulls(jsonb_build_object('ticket', v_ticket, 'fee', v_fee, 'total', v_total)),
             -- an older event must not undo a newer one (events can arrive out of order)
             status = case when v_ts >= coalesce(status_at, '-infinity')
                           then case when v_event = 'registration.payment.completed' then 'paid' else 'failed' end
                           else status end,
             paid_at = case when v_event = 'registration.payment.completed' and paid_at is null then v_ts else paid_at end,
             status_at = greatest(coalesce(status_at, v_ts), v_ts),
             updated_at = now()
       where payment_id = v_pay;
    end if;

    select * into v_pay_row from webinar_payments where payment_id = v_pay;
    if v_lead is not null then
      if v_event = 'registration.payment.completed' and v_pay_row.status = 'paid' and not v_was_paid then
        v_amount := coalesce(v_pay_row.ticket_amount, v_pay_row.total_charged);
        perform private.wg_note(v_lead, 'Paid ' || private.wg_money(v_amount, v_pay_row.currency) || ' for ' || v_label,
          jsonb_build_object('event', v_event, 'payment_id', v_pay, 'amount', v_amount, 'webinar_id', v_wid));
        select assigned_to into v_agent from leads where id = v_lead;
        if v_agent is not null and not v_test and v_ts > now() - interval '2 days' then
          perform private.push(jsonb_build_array(jsonb_build_object(
            'user_id', v_agent,
            'title', '💰 Webinar payment',
            'body', coalesce(nullif((select name from leads where id = v_lead), ''), v_email, 'A student') || ' paid ' ||
                    private.wg_money(v_amount, v_pay_row.currency) || ' for ' || v_label,
            'data', jsonb_build_object('lead_id', v_lead))));
        end if;
      elsif v_event = 'registration.payment.failed' and v_pay_row.status = 'failed' then
        perform private.wg_note(v_lead, 'Webinar payment did not go through (' || v_label || ')',
          jsonb_build_object('event', v_event, 'payment_id', v_pay, 'webinar_id', v_wid));
      end if;
    end if;

  elsif v_event = 'registration.refunded' then
    select * into v_pay_row from webinar_payments
     where payment_id = coalesce(v_pay, '') or (v_order is not null and order_id = v_order)
     order by (payment_id = coalesce(v_pay, '')) desc
     limit 1 for update;
    if not found then
      select * into v_pay_row from webinar_payments
       where registration_id = v_reg and status in ('paid', 'refunded')
       order by status_at desc limit 1 for update;
    end if;
    if not found then
      -- the refund came before the payment: keep it, the payment event (older) will not undo it
      insert into webinar_payments (payment_id, registration_id, order_id, webinar_id, email, lead_id, status, status_at, currency,
                                    ticket_amount, processing_fee, total_charged, refunded_amount, refund_status, raw)
      values (coalesce(v_pay, v_order, 'paid:' || v_reg), v_reg, v_order, v_wid, v_email, v_lead, 'refunded', v_ts, v_currency,
              private.wg_num(v_ticket), private.wg_num(v_fee), private.wg_num(v_total),
              coalesce(private.wg_num(v_refunded), private.wg_num(v_ticket), private.wg_num(v_total), 0), v_rstatus,
              jsonb_strip_nulls(jsonb_build_object('ticket', v_ticket, 'fee', v_fee, 'total', v_total, 'refunded', v_refunded)))
      returning * into v_pay_row;
    else
      -- no refund amount given = the whole payment; a smaller amount = part of it
      v_amount := coalesce(private.wg_num(v_refunded), v_pay_row.ticket_amount, v_pay_row.total_charged, 0);
      v_full := v_refunded is null or v_amount >= coalesce(v_pay_row.ticket_amount, v_pay_row.total_charged, 0);
      if v_ts >= coalesce(v_pay_row.status_at, '-infinity') or v_pay_row.status = 'refunded' then
        update webinar_payments
           set refunded_amount = v_amount,
               refund_status = coalesce(v_rstatus, refund_status),
               status = case when v_full then 'refunded' else 'paid' end,
               raw = raw || jsonb_strip_nulls(jsonb_build_object('refunded', v_refunded)),
               status_at = greatest(coalesce(status_at, v_ts), v_ts),
               updated_at = now()
         where payment_id = v_pay_row.payment_id
        returning * into v_pay_row;
      end if;
    end if;
    if v_lead is not null then
      perform private.wg_note(v_lead, 'Refunded ' || private.wg_money(v_pay_row.refunded_amount, v_pay_row.currency) || ' (' || v_label || ')',
        jsonb_build_object('event', v_event, 'payment_id', v_pay_row.payment_id, 'amount', v_pay_row.refunded_amount));
    end if;
  end if;

  perform private.wg_refresh(v_lead);
  return jsonb_build_object('status', 'ok', 'lead_id', v_lead, 'new_lead', coalesce(v_is_new_lead, false),
                            'registration_id', v_reg);
end;
$$;

revoke execute on function public.webinar_apply(text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.webinar_apply(text, timestamptz, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Attendance and checks from the Webinar.gg API
-- p_rows: [{"email": "...", "name": "...", "attended": true | false | null}]
-- ---------------------------------------------------------------------------

create or replace function public.webinar_set_attendance(p_webinar text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  reg record;
  v_found int := 0;
  v_changed int := 0;
  v_total int := 0;
begin
  for r in
    select lower(trim(x.email)) as email, nullif(trim(x.name), '') as name, x.attended
      from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb)) as x(email text, name text, attended boolean)
     where nullif(trim(x.email), '') is not null
  loop
    v_total := v_total + 1;
    for reg in
      select * from webinar_registrations
       where webinar_id = p_webinar and email = r.email for update
    loop
      v_found := v_found + 1;
      if reg.attended is distinct from r.attended then
        update webinar_registrations set attended = r.attended, updated_at = now() where registration_id = reg.registration_id;
        v_changed := v_changed + 1;
        if reg.lead_id is not null and r.attended is not null then
          perform private.wg_note(reg.lead_id,
            case when r.attended then 'Attended ' else 'Did not attend ' end || coalesce(reg.webinar_title, 'the webinar'),
            jsonb_build_object('webinar_id', p_webinar, 'attended', r.attended));
        end if;
      end if;
      if r.name is not null then
        update webinar_registrations set name = coalesce(nullif(name, ''), r.name) where registration_id = reg.registration_id;
        if reg.lead_id is not null then
          perform set_config('app.webinar_write', 'on', true);
          update leads set name = r.name where id = reg.lead_id and name = '';
        end if;
      end if;
      perform private.wg_refresh(reg.lead_id);
    end loop;
  end loop;

  update webinar_registrations set attendance_checked_at = now() where webinar_id = p_webinar;
  return jsonb_build_object('invites', v_total, 'matched', v_found, 'changed', v_changed);
end;
$$;

revoke execute on function public.webinar_set_attendance(text, jsonb) from public, anon, authenticated;
grant execute on function public.webinar_set_attendance(text, jsonb) to service_role;

-- Payments that the Webinar.gg API did (true) or did not (false) list.
create or replace function public.webinar_verify(p_payment_ids text[], p_ok boolean)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int := 0;
  r record;
begin
  for r in
    update webinar_payments set verified = p_ok, updated_at = now()
     where payment_id = any(p_payment_ids) and verified is distinct from p_ok
    returning lead_id
  loop
    v_n := v_n + 1;
    perform private.wg_refresh(r.lead_id);
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.webinar_verify(text[], boolean) from public, anon, authenticated;
grant execute on function public.webinar_verify(text[], boolean) to service_role;

-- Webinars whose attendance should be copied now: new ones, and the ones from the last 10 days every hour.
create or replace function public.webinar_scan_list(p_force boolean default false)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(w.webinar_id order by w.last_check nulls first), '{}')
    from (
      select r.webinar_id,
             min(r.attendance_checked_at) as last_check,
             max(coalesce(r.registered_at, r.created_at)) as last_reg
        from webinar_registrations r
       where r.webinar_id is not null and not r.is_test
       group by r.webinar_id
    ) w
   where (p_force and w.last_reg > now() - interval '90 days')
      or w.last_check is null
      or (w.last_reg > now() - interval '10 days' and w.last_check < now() - interval '50 minutes')
      -- a payment nobody has checked yet
      or exists (select 1 from webinar_payments p
                  where p.webinar_id = w.webinar_id and p.verified is null and p.status = 'paid');
$$;

revoke execute on function public.webinar_scan_list(boolean) from public, anon, authenticated;
grant execute on function public.webinar_scan_list(boolean) to service_role;

-- ---------------------------------------------------------------------------
-- For the app (admin)
-- ---------------------------------------------------------------------------

create or replace function public.webinar_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cfg webinar_config;
  v_last webinar_events;
begin
  if not is_admin() then
    raise exception 'Only admin can see this';
  end if;
  select * into v_cfg from webinar_config where id = 1;
  select * into v_last from webinar_events order by id desc limit 1;
  return jsonb_build_object(
    'token_saved', v_cfg.api_token is not null,
    'amount_divisor', v_cfg.amount_divisor,
    'last_sync_at', v_cfg.last_sync_at,
    'last_sync_note', v_cfg.last_sync_note,
    'last_event', v_last.event,
    'last_event_at', v_last.created_at,
    'last_outcome', v_last.outcome,
    'events_24h', (select count(*) from webinar_events where created_at > now() - interval '24 hours'),
    'errors', (select count(*) from webinar_events where outcome = 'error'),
    'waiting', (select count(*) from webinar_events where outcome = 'received' and created_at < now() - interval '2 minutes'),
    'registrations', (select count(*) from webinar_registrations where not is_test),
    'paid', (select count(*) from webinar_payments where status = 'paid' and verified is not false and not is_test),
    'unverified', (select count(*) from webinar_payments where status = 'paid' and verified is false and not is_test));
end;
$$;

-- Changing the unit corrects every saved amount at once.
create or replace function public.webinar_set_divisor(p_divisor numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  if p_divisor is null or p_divisor < 1 or p_divisor > 1000 then
    raise exception 'Use 1 (rupees) or 100 (paise)';
  end if;
  update webinar_config set amount_divisor = p_divisor, updated_at = now() where id = 1;
  update webinar_payments
     set ticket_amount = round((raw ->> 'ticket')::numeric / p_divisor, 2),
         processing_fee = round((raw ->> 'fee')::numeric / p_divisor, 2),
         total_charged = round((raw ->> 'total')::numeric / p_divisor, 2),
         refunded_amount = case when status = 'refunded' and raw ? 'refunded' then round((raw ->> 'refunded')::numeric / p_divisor, 2)
                                when status = 'refunded' then round(coalesce((raw ->> 'ticket')::numeric, (raw ->> 'total')::numeric, 0) / p_divisor, 2)
                                when raw ? 'refunded' then round((raw ->> 'refunded')::numeric / p_divisor, 2)
                                else refunded_amount end
   where raw <> '{}'::jsonb;
  for r in select distinct lead_id from webinar_payments where lead_id is not null loop
    perform private.wg_refresh(r.lead_id);
  end loop;
end;
$$;

revoke execute on function public.webinar_overview() from public, anon;
revoke execute on function public.webinar_set_divisor(numeric) from public, anon;
grant execute on function public.webinar_overview() to authenticated;
grant execute on function public.webinar_set_divisor(numeric) to authenticated;

-- Numbers for the dashboard: how many registered, paid, came; money after refunds; per webinar.
create or replace function public.webinar_stats(p_from timestamptz, p_to timestamptz)
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
  if not is_admin() then
    raise exception 'Only admin can see these numbers';
  end if;

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

-- "Send a test" in the app makes a test student; this removes everything the tests made (and only that).
create or replace function public.webinar_clear_tests()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_leads int;
  v_regs int;
begin
  if not is_admin() then
    raise exception 'Only admin can do this';
  end if;
  delete from webinar_payments where is_test;
  delete from webinar_registrations where is_test;
  get diagnostics v_regs = row_count;
  delete from webinar_events where event_key like 'test:%';
  -- the test students: made by the test, still without a phone number and with the test e-mail
  delete from leads
   where source = 'webinar' and phone is null and email like 'webinar-test-%@example.com';
  get diagnostics v_leads = row_count;
  return jsonb_build_object('leads', v_leads, 'registrations', v_regs);
end;
$$;

revoke execute on function public.webinar_stats(timestamptz, timestamptz) from public, anon;
revoke execute on function public.webinar_clear_tests() from public, anon;
grant execute on function public.webinar_stats(timestamptz, timestamptz) to authenticated;
grant execute on function public.webinar_clear_tests() to authenticated;

-- ---------------------------------------------------------------------------
-- A broadcast can go to "paid, did not attend" and the like
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
          or (p_filter ->> 'attended' = 'no' and l.webinar_attended is false));
$$;

-- ---------------------------------------------------------------------------
-- A landing-page lead that has the e-mail of a webinar-only lead (no phone yet) joins that lead
-- instead of becoming a second one.
-- ---------------------------------------------------------------------------

create or replace function public.ingest_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_source text,
  p_source_detail text default null,
  p_external_id text default null,
  p_extra jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := phone_key(p_phone);
  v_email text := nullif(lower(trim(p_email)), '');
  v_existing uuid;
  v_cfg jsonb;
  v_agent uuid;
  v_id uuid;
begin
  if p_external_id is not null then
    select id into v_existing from leads where external_id = p_external_id;
    if found then
      return jsonb_build_object('status', 'exists', 'id', v_existing);
    end if;
  end if;

  if v_key is null and v_email is null then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_key is not null then
    select id into v_existing from leads where phone_key = v_key;
    if v_existing is null and v_email is not null then
      select id into v_existing from leads
       where lower(email) = v_email and phone_key is null
       order by created_at limit 1;
    end if;
  else
    select id into v_existing from leads where lower(email) = v_email limit 1;
  end if;

  if v_existing is not null then
    insert into lead_activities (lead_id, user_id, type, body, meta)
    values (v_existing, null, 'duplicate', 'Enquired again',
            jsonb_build_object('source', p_source, 'source_detail', p_source_detail,
                               'name', p_name, 'extra', p_extra));
    update leads
       set email = coalesce(email, v_email),
           phone = coalesce(phone, nullif(trim(p_phone), '')),
           name = case when name = '' then coalesce(p_name, '') else name end
     where id = v_existing;
    return jsonb_build_object('status', 'duplicate', 'id', v_existing);
  end if;

  select value into v_cfg from app_settings where key = 'auto_assign';
  if coalesce((v_cfg ->> 'enabled')::boolean, false) then
    select p.id into v_agent
      from profiles p
     where p.is_active
       and p.id::text in (select jsonb_array_elements_text(v_cfg -> 'agent_ids'))
     order by p.last_auto_assigned_at nulls first, p.created_at
     limit 1
     for update;
    if v_agent is not null then
      update profiles set last_auto_assigned_at = now() where id = v_agent;
    end if;
  end if;

  insert into leads (name, phone, email, source, source_detail, external_id, extra, assigned_to)
  values (coalesce(p_name, ''), p_phone, v_email, p_source, p_source_detail, p_external_id,
          coalesce(p_extra, '{}'::jsonb), v_agent)
  returning id into v_id;

  return jsonb_build_object('status', 'created', 'id', v_id, 'assigned_to', v_agent);
end;
$$;

revoke execute on function public.ingest_lead(text, text, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_lead(text, text, text, text, text, text, jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- Every hour: events that failed once are tried again, attendance is copied from Webinar.gg
-- ---------------------------------------------------------------------------

create or replace function private.wg_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  -- old log lines (the registrations and payments themselves are never removed)
  delete from webinar_events where outcome in ('ok', 'ignored') and created_at < now() - interval '120 days';

  if not exists (select 1 from webinar_events) and not exists (select 1 from webinar_config where api_token is not null) then
    return;
  end if;
  select value into v_url from private.config where key = 'functions_url';
  select value ->> 'webhook_key' into v_key from app_settings where key = 'integrations';
  if v_url is null or v_key is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/webinar-gg',
    body := '{"action": "sync"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key),
    timeout_milliseconds := 150000
  );
exception when others then
  raise warning 'wg_tick: %', sqlerrm;
end;
$$;

do $$
begin
  perform cron.schedule('whatsweb-webinar', '7 * * * *', 'select private.wg_tick()');
exception when others then
  raise warning 'Could not schedule the Webinar.gg sync (%): attendance stays manual', sqlerrm;
end $$;
