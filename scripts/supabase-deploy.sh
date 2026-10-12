#!/usr/bin/env bash
# Sets up / updates the Supabase project. Run by GitHub Actions on every push.
#   - applies new files from supabase/migrations (each file only once)
#   - deploys the edge functions
#   - turns off public sign-up (only the admin creates accounts)
#   - creates the webhook key once and stores it for the app's "Lead sources" screen
#
# Needs: SUPABASE_ACCESS_TOKEN, PROJECT_REF, and the supabase CLI on PATH.
set -euo pipefail

API="https://api.supabase.com/v1/projects/$PROJECT_REF"

sql() {
  jq -n --arg q "$1" '{query: $q}' |
    curl -sS --fail-with-body -X POST "$API/database/query" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d @-
}

echo "== Database"
sql "create schema if not exists private;
     create table if not exists private.applied_migrations (
       name text primary key,
       applied_at timestamptz not null default now()
     );" >/dev/null

for file in supabase/migrations/*.sql; do
  name=$(basename "$file")
  count=$(sql "select count(*)::int as n from private.applied_migrations where name = '$name'" | jq -r '.[0].n')
  if [ "$count" = "0" ]; then
    echo "Applying $name"
    # One request = one transaction: the file and its bookkeeping row go in together.
    sql "$(cat "$file")
insert into private.applied_migrations (name) values ('$name');" >/dev/null
  else
    echo "Already applied: $name"
  fi
done

echo "== Login settings"
curl -sS --fail-with-body -X PATCH "$API/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"disable_signup": true}' >/dev/null
echo "Public sign-up is off"

echo "== Edge functions"
supabase functions deploy --project-ref "$PROJECT_REF"
# The database calls the "push" function through this address.
sql "insert into private.config (key, value)
     values ('functions_url', 'https://$PROJECT_REF.supabase.co/functions/v1')
     on conflict (key) do update set value = excluded.value;" >/dev/null

echo "== Push notifications"
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  supabase secrets set --project-ref "$PROJECT_REF" \
    "FIREBASE_SERVICE_ACCOUNT=$(printf '%s' "$FIREBASE_SERVICE_ACCOUNT" | jq -c .)" >/dev/null
  echo "Firebase service account set"
else
  echo "FIREBASE_SERVICE_ACCOUNT secret not set - push notifications stay off"
fi

echo "== Webhook key"
if supabase secrets list --project-ref "$PROJECT_REF" | grep -q WEBHOOK_KEY; then
  echo "Webhook key already set"
else
  key=$(openssl rand -hex 20)
  # Database first: if setting the secret fails, the next run makes a fresh key for both.
  sql "insert into public.app_settings (key, value)
       values ('integrations', jsonb_build_object('webhook_key', '$key'))
       on conflict (key) do update
         set value = public.app_settings.value || excluded.value, updated_at = now();" >/dev/null
  supabase secrets set --project-ref "$PROJECT_REF" "WEBHOOK_KEY=$key" >/dev/null
  echo "Webhook key created (admin can see it in the app: More > Lead sources)"
fi

echo "== Landing page key"
# The key that goes into public landing pages. Separate from WEBHOOK_KEY, which stays on the server.
landing=$(openssl rand -hex 20)
sql "update public.app_settings
        set value = value || jsonb_build_object('landing_key', '$landing'), updated_at = now()
      where key = 'integrations' and coalesce(value ->> 'landing_key', '') = '';" >/dev/null
echo "Landing key ready (admin can see it in the app: More > Lead sources)"

echo "== Webinar.gg address"
# The secret part of the address Webinar.gg sends registrations and payments to (More > Lead sources > Webinar.gg).
webinar=$(openssl rand -hex 32)
sql "update public.app_settings
        set value = value || jsonb_build_object('webinar_token', '$webinar'), updated_at = now()
      where key = 'integrations' and coalesce(value ->> 'webinar_token', '') = '';" >/dev/null
echo "Webinar.gg address ready (admin can see it in the app: More > Lead sources)"

echo "== AIFM Education app (Appx) address"
# The secret part of the address the Appx CMS webhooks send to (More > AIFM Education app).
appx=$(openssl rand -hex 32)
sql "update public.app_settings
        set value = value || jsonb_build_object('appx_token', '$appx'), updated_at = now()
      where key = 'integrations' and coalesce(value ->> 'appx_token', '') = '';" >/dev/null
echo "Appx address ready (admin can see it in the app: More > AIFM Education app)"

echo "== Claude connector address"
# The secret part of the address the Claude app connects to (More > Claude connector).
mcp=$(openssl rand -hex 32)
sql "update public.app_settings
        set value = value || jsonb_build_object('mcp_token', '$mcp'), updated_at = now()
      where key = 'integrations' and coalesce(value ->> 'mcp_token', '') = '';" >/dev/null
echo "Claude connector address ready (admin can see it in the app: More > Claude connector)"
