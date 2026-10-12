-- OPTIONAL (Phase 2): every 10 minutes pull recent Meta Instant Form leads,
-- in case a webhook was missed. Replace the two <...> values, then run in the SQL Editor.
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'meta-leads-sync',
  '*/10 * * * *',
  $$
  select net.http_get(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/meta-leads?action=sync&hours=3&key=<WEBHOOK_KEY>'
  );
  $$
);

-- To stop it later:  select cron.unschedule('meta-leads-sync');
