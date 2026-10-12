-- Daily backup to the admin's Google Drive (through a small Google Apps Script the admin
-- deploys in their own Google account; its address + key are stored in app_settings.backup).

-- Backup and webhook settings are admin-only.
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings
  for select to authenticated
  using ((select public.is_member())
         and (key not in ('integrations', 'backup') or (select public.is_admin())));

create or replace function private.run_backup()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  if coalesce((select value ->> 'url' from app_settings where key = 'backup'), '') = '' then
    return;
  end if;
  select value into v_url from private.config where key = 'functions_url';
  select value ->> 'webhook_key' into v_key from app_settings where key = 'integrations';
  if v_url is null or v_key is null then
    return;
  end if;
  perform net.http_post(
    url := v_url || '/backup',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-key', v_key),
    timeout_milliseconds := 60000
  );
end;
$$;

-- "Backup now" button (admin).
create or replace function public.request_backup()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only admin can start a backup';
  end if;
  perform private.run_backup();
end;
$$;

revoke execute on function public.request_backup() from public, anon;
grant execute on function public.request_backup() to authenticated;

-- Every night at 2:00 IST (20:30 UTC).
do $$
begin
  perform cron.schedule('whatsweb-backup', '30 20 * * *', 'select private.run_backup()');
exception when others then
  raise warning 'Could not schedule the backup (%)', sqlerrm;
end $$;
