-- In-app update: the GitHub build uploads the APK to this private bucket;
-- logged-in team members can download it.

insert into storage.buckets (id, name, public)
values ('app', 'app', false)
on conflict (id) do nothing;

create policy "Team can download the app"
  on storage.objects for select to authenticated
  using (bucket_id = 'app' and (select public.is_member()));
