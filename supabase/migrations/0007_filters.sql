-- Filters: which landing page / form / Excel file a lead came from.
--   * every Excel upload becomes an "import batch" (like a folder per file)
--   * lead_source_list() gives the filter its choices (source + page/form/campaign)

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  total int not null default 0,
  added int not null default 0,
  duplicates int not null default 0,
  invalid int not null default 0
);

alter table public.import_batches enable row level security;
create policy batches_admin on public.import_batches
  for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

alter table public.leads add column import_batch_id uuid references public.import_batches (id) on delete set null;
create index leads_batch_idx on public.leads (import_batch_id) where import_batch_id is not null;
create index leads_source_idx on public.leads (source, source_detail);

-- Start a batch before sending the file's rows in chunks.
create or replace function public.create_import_batch(p_name text, p_total int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'Only admin can import leads';
  end if;
  insert into import_batches (name, total)
  values (coalesce(nullif(trim(p_name), ''), 'Excel import'), coalesce(p_total, 0))
  returning id into v_id;
  return v_id;
end;
$$;

-- Same signature plus the batch (the old 3-argument version is replaced).
drop function if exists public.import_leads(jsonb, uuid, text);

create or replace function public.import_leads(
  p_rows jsonb,
  p_assign_to uuid default null,
  p_source_detail text default null,
  p_batch_id uuid default null
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

    insert into leads (name, phone, email, source, source_detail, assigned_to, extra, created_by, import_batch_id)
    values (
      coalesce(r ->> 'name', ''),
      r ->> 'phone',
      v_email,
      'excel',
      p_source_detail,
      p_assign_to,
      coalesce(r -> 'extra', '{}'::jsonb),
      auth.uid(),
      p_batch_id
    );
    v_added := v_added + 1;
  end loop;

  perform set_config('app.skip_notify', 'off', true);
  if p_batch_id is not null then
    update import_batches
       set added = added + v_added, duplicates = duplicates + v_dupes, invalid = invalid + v_invalid
     where id = p_batch_id;
  end if;
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

-- Removes the leads of a file that nobody has worked on yet (still "New", never contacted).
create or replace function public.delete_import_batch(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted int;
  v_kept int;
begin
  if not is_admin() then
    raise exception 'Only admin can delete an import';
  end if;
  delete from leads
   where import_batch_id = p_id
     and status = 'New'
     and last_contacted_at is null
     and next_follow_up_at is null;
  get diagnostics v_deleted = row_count;
  select count(*) into v_kept from leads where import_batch_id = p_id;
  if v_kept = 0 then
    delete from import_batches where id = p_id;
  end if;
  return jsonb_build_object('deleted', v_deleted, 'kept', v_kept);
end;
$$;

-- Choices for the "landing page / form / file" filter. Runs as the caller, so an agent
-- only counts (and sees) their own leads.
create or replace function public.lead_source_list()
returns table (source text, source_detail text, total bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select l.source, l.source_detail, count(*)
    from leads l
   group by l.source, l.source_detail
   order by count(*) desc, l.source, l.source_detail;
$$;

revoke execute on function public.create_import_batch(text, int) from public, anon;
revoke execute on function public.import_leads(jsonb, uuid, text, uuid) from public, anon;
revoke execute on function public.delete_import_batch(uuid) from public, anon;
revoke execute on function public.lead_source_list() from public, anon;
grant execute on function public.create_import_batch(text, int) to authenticated;
grant execute on function public.import_leads(jsonb, uuid, text, uuid) to authenticated;
grant execute on function public.delete_import_batch(uuid) to authenticated;
grant execute on function public.lead_source_list() to authenticated;
