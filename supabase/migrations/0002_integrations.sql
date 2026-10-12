-- The webhook key (stored under app_settings.key = 'integrations') is admin-only:
-- agents can read the other settings (templates) but not this one.
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings
  for select to authenticated
  using ((select public.is_member()) and (key <> 'integrations' or (select public.is_admin())));
