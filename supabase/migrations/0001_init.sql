-- WhatsWeb — database schema
-- Applied automatically by scripts/supabase-deploy.sh (GitHub Actions). It can also be run
-- once by hand in Supabase: Dashboard → SQL Editor → New query → paste → Run.
-- The first user (Authentication → Users → Add user) automatically becomes admin.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Normalise Indian / international phone numbers to +<countrycode><number>.
create or replace function public.normalize_phone(p text)
returns text
language plpgsql
immutable
as $$
declare
  -- Excel sometimes turns 9876543210 into "9876543210.0"
  d text := regexp_replace(regexp_replace(coalesce(p, ''), '\.0+$', ''), '\D', '', 'g');
begin
  if d = '' then
    return null;
  end if;
  if left(d, 2) = '00' then
    d := substr(d, 3);
    return '+' || d;
  end if;
  if length(d) = 10 then
    return '+91' || d;
  end if;
  if length(d) = 11 and left(d, 1) = '0' then
    return '+91' || substr(d, 2);
  end if;
  if length(d) = 12 and left(d, 2) = '91' then
    return '+' || d;
  end if;
  if length(d) > 10 then
    return '+' || d;
  end if;
  return d;
end;
$$;

-- Last 10 digits of the number: the same person entered as 098765 43210,
-- +91 9876543210 or 9876543210 gets the same key.
create or replace function public.phone_key(p text)
returns text
language sql
immutable
as $$
  select nullif(right(regexp_replace(coalesce(public.normalize_phone(p), ''), '\D', '', 'g'), 10), '');
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  email text,
  role text not null default 'agent' check (role in ('admin', 'agent')),
  is_active boolean not null default true,
  last_auto_assigned_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.lead_statuses (
  id serial primary key,
  name text not null unique,
  color text not null default '#607D8B',
  sort_order int not null default 0,
  is_closed boolean not null default false
);

insert into public.lead_statuses (name, color, sort_order, is_closed) values
  ('New',            '#1E88E5', 1, false),
  ('No Answer',      '#FB8C00', 2, false),
  ('Interested',     '#43A047', 3, false),
  ('Call Back',      '#8E24AA', 4, false),
  ('Not Interested', '#E53935', 5, true),
  ('Admission Done', '#00897B', 6, true),
  ('Wrong Number',   '#6D4C41', 7, true);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  phone text,
  email text,
  -- last 10 digits, used to detect the same person coming in twice
  phone_key text generated always as (public.phone_key(phone)) stored,
  -- meta_form, meta_landing, google_form, google_landing, website, excel, manual
  source text not null default 'manual',
  source_detail text,
  status text not null default 'New' references public.lead_statuses (name) on update cascade,
  assigned_to uuid references public.profiles (id) on delete set null,
  assigned_at timestamptz,
  last_contacted_at timestamptz,
  next_follow_up_at timestamptz,
  external_id text unique,
  extra jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index leads_phone_key_uniq on public.leads (phone_key) where phone_key is not null;
create index leads_assigned_created_idx on public.leads (assigned_to, created_at desc);
create index leads_created_idx on public.leads (created_at desc);
create index leads_status_idx on public.leads (status);
create index leads_email_idx on public.leads (lower(email));

create table public.lead_activities (
  id bigint generated always as identity primary key,
  lead_id uuid not null references public.leads (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete set null default auth.uid(),
  type text not null check (type in (
    'created', 'remark', 'status', 'call', 'whatsapp', 'sms', 'email',
    'assigned', 'reminder', 'duplicate', 'edit'
  )),
  body text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index lead_activities_lead_idx on public.lead_activities (lead_id, created_at desc);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  -- small integer the phone uses as the notification id
  notify_id int generated always as identity,
  lead_id uuid not null references public.leads (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  remind_at timestamptz not null,
  note text,
  is_done boolean not null default false,
  created_at timestamptz not null default now()
);

create index reminders_user_idx on public.reminders (user_id, is_done, remind_at);
create index reminders_lead_idx on public.reminders (lead_id);

create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value) values
  ('auto_assign', '{"enabled": false, "agent_ids": []}'::jsonb),
  ('templates', jsonb_build_object(
    'whatsapp', 'Hi {name}, thank you for your enquiry. When is a good time to talk?',
    'sms', 'Hi {name}, thank you for your enquiry. Please call us back at your convenience.',
    'email_subject', 'Regarding your enquiry',
    'email_body', E'Hi {name},\n\nThank you for your enquiry. Please let us know a good time to talk.\n\nRegards'
  ));

-- ---------------------------------------------------------------------------
-- Role helpers (security definer so they can read profiles regardless of RLS)
-- ---------------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'admin' and is_active
  );
$$;

create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from profiles where id = auth.uid() and is_active);
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Every new auth user gets a profile. The very first one becomes admin.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from profiles where role = 'admin') then 'agent' else 'admin' end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Accounts created before this script ran (e.g. from the dashboard) get a profile too.
-- The oldest one becomes admin.
insert into public.profiles (id, full_name, email, role)
select
  u.id,
  coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), split_part(u.email, '@', 1)),
  u.email,
  case when row_number() over (order by u.created_at) = 1 then 'admin' else 'agent' end
from auth.users u
on conflict (id) do nothing;

-- Never leave the team without an active admin.
create or replace function public.keep_one_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.role = 'admin' and old.is_active
     and (new.role <> 'admin' or not new.is_active)
     and not exists (
       select 1 from profiles where role = 'admin' and is_active and id <> old.id
     ) then
    raise exception 'At least one active admin is required';
  end if;
  return new;
end;
$$;

create trigger profiles_keep_one_admin
  before update on public.profiles
  for each row execute function public.keep_one_admin();

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
  return new;
end;
$$;

create trigger leads_before_write
  before insert or update on public.leads
  for each row execute function public.leads_before_write();

-- Write history entries for creation, assignment and status changes.
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
  return new;
end;
$$;

create trigger leads_after_write
  after insert or update on public.leads
  for each row execute function public.leads_after_write();

-- Keep leads.next_follow_up_at in sync with open reminders.
create or replace function public.reminders_after_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead uuid := coalesce(new.lead_id, old.lead_id);
begin
  update leads
     set next_follow_up_at = (
       select min(remind_at) from reminders where lead_id = v_lead and not is_done
     )
   where id = v_lead;

  if tg_op = 'INSERT' then
    insert into lead_activities (lead_id, user_id, type, body, meta)
    values (new.lead_id, auth.uid(), 'reminder', new.note,
            jsonb_build_object('remind_at', new.remind_at, 'for', new.user_id));
  end if;
  return null;
end;
$$;

create trigger reminders_after_write
  after insert or update or delete on public.reminders
  for each row execute function public.reminders_after_write();

-- ---------------------------------------------------------------------------
-- Row level security
-- Admin sees everything. An agent sees only leads assigned to them.
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.lead_statuses enable row level security;
alter table public.leads enable row level security;
alter table public.lead_activities enable row level security;
alter table public.reminders enable row level security;
alter table public.app_settings enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated using (id = (select auth.uid()) or (select public.is_member()));
create policy profiles_update on public.profiles
  for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy statuses_select on public.lead_statuses
  for select to authenticated using ((select public.is_member()));
create policy statuses_admin on public.lead_statuses
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy leads_select on public.leads
  for select to authenticated
  using ((select public.is_admin()) or (assigned_to = (select auth.uid()) and (select public.is_member())));
create policy leads_insert on public.leads
  for insert to authenticated
  with check ((select public.is_admin()) or (assigned_to = (select auth.uid()) and (select public.is_member())));
create policy leads_update on public.leads
  for update to authenticated
  using ((select public.is_admin()) or (assigned_to = (select auth.uid()) and (select public.is_member())))
  with check ((select public.is_admin()) or (assigned_to = (select auth.uid()) and (select public.is_member())));
create policy leads_delete on public.leads
  for delete to authenticated using ((select public.is_admin()));

create policy activities_select on public.lead_activities
  for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id));
create policy activities_insert on public.lead_activities
  for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.leads l where l.id = lead_id));
create policy activities_admin on public.lead_activities
  for delete to authenticated using ((select public.is_admin()));

create policy reminders_select on public.reminders
  for select to authenticated
  using ((select public.is_admin()) or (user_id = (select auth.uid()) and (select public.is_member())));
create policy reminders_insert on public.reminders
  for insert to authenticated
  with check (
    ((select public.is_admin()) or user_id = (select auth.uid()))
    and exists (select 1 from public.leads l where l.id = lead_id)
  );
create policy reminders_update on public.reminders
  for update to authenticated
  using ((select public.is_admin()) or (user_id = (select auth.uid()) and (select public.is_member())))
  with check ((select public.is_admin()) or user_id = (select auth.uid()));
create policy reminders_delete on public.reminders
  for delete to authenticated
  using ((select public.is_admin()) or (user_id = (select auth.uid()) and (select public.is_member())));

create policy settings_select on public.app_settings
  for select to authenticated using ((select public.is_member()));
create policy settings_admin on public.app_settings
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Functions called by the app
-- ---------------------------------------------------------------------------

-- Add one lead by hand. Agents always get the lead themselves.
create or replace function public.create_lead(
  p_name text,
  p_phone text,
  p_email text default null,
  p_assign_to uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := normalize_phone(p_phone);
  v_email text := nullif(lower(trim(p_email)), '');
  v_key text := phone_key(p_phone);
  v_existing leads%rowtype;
  v_assign uuid := p_assign_to;
  v_id uuid;
begin
  if not is_member() then
    raise exception 'Not allowed';
  end if;
  if v_key is null and v_email is null then
    raise exception 'Phone or email is required';
  end if;
  if not is_admin() then
    v_assign := auth.uid();
  end if;

  if v_key is not null then
    select * into v_existing from leads where phone_key = v_key;
  else
    select * into v_existing from leads where lower(email) = v_email limit 1;
  end if;

  if found then
    if is_admin() or v_existing.assigned_to = auth.uid() then
      return jsonb_build_object('status', 'duplicate', 'id', v_existing.id);
    end if;
    return jsonb_build_object('status', 'duplicate_other');
  end if;

  insert into leads (name, phone, email, source, assigned_to, created_by)
  values (coalesce(p_name, ''), v_phone, v_email, 'manual', v_assign, auth.uid())
  returning id into v_id;

  return jsonb_build_object('status', 'created', 'id', v_id);
end;
$$;

-- Bulk import from Excel/CSV (admin only).
-- p_rows: [{"name": "...", "phone": "...", "email": "...", "extra": {...}}, ...]
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

  return jsonb_build_object('added', v_added, 'duplicates', v_dupes, 'invalid', v_invalid);
end;
$$;

-- Assign (or unassign) many leads at once. Several agents = shared out one by one.
create or replace function public.assign_leads(p_lead_ids uuid[], p_agent_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agents uuid[];
  v_n int;
  v_count int := 0;
  i int;
begin
  if not is_admin() then
    raise exception 'Only admin can assign leads';
  end if;

  select array_agg(id order by ord) into v_agents
    from unnest(coalesce(p_agent_ids, '{}')) with ordinality as a(id, ord)
   where exists (select 1 from profiles p where p.id = a.id and p.is_active);
  v_n := coalesce(array_length(v_agents, 1), 0);

  for i in 1 .. coalesce(array_length(p_lead_ids, 1), 0) loop
    update leads
       set assigned_to = case when v_n = 0 then null else v_agents[((i - 1) % v_n) + 1] end
     where id = p_lead_ids[i];
    if found then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- Lead counts per agent and status (agents only see their own).
create or replace function public.lead_counts()
returns table (assigned_to uuid, status text, total bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select l.assigned_to, l.status, count(*) from leads l group by 1, 2;
$$;

-- ---------------------------------------------------------------------------
-- Used only by the webhook functions (service role), never by the app.
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

-- Supabase grants EXECUTE to anon/authenticated by default; lock things down.
revoke execute on function public.ingest_lead(text, text, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_lead(text, text, text, text, text, text, jsonb)
  to service_role;

revoke execute on function public.create_lead(text, text, text, uuid) from public, anon;
revoke execute on function public.import_leads(jsonb, uuid, text) from public, anon;
revoke execute on function public.assign_leads(uuid[], uuid[]) from public, anon;
revoke execute on function public.lead_counts() from public, anon;
grant execute on function public.create_lead(text, text, text, uuid) to authenticated;
grant execute on function public.import_leads(jsonb, uuid, text) to authenticated;
grant execute on function public.assign_leads(uuid[], uuid[]) to authenticated;
grant execute on function public.lead_counts() to authenticated;
