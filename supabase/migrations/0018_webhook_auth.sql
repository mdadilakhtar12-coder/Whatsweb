-- Outgoing webhook: an optional "Authorization" header for the receiving address, and a record of every try
-- (the answer code and the first 300 characters of what the address said), so a 401 / 403 is visible.

alter table public.api_config add column webhook_auth text;

-- One row for every try of a delivery.
create table public.webhook_attempts (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.webhook_deliveries (id) on delete cascade,
  attempt int not null,
  at timestamptz not null default now(),
  -- 0 = no answer at all (see error)
  code int not null default 0,
  -- the first 300 characters of the answer
  body text,
  error text
);
create index webhook_attempts_delivery_idx on public.webhook_attempts (delivery_id, attempt);
alter table public.webhook_attempts enable row level security;
revoke all on public.webhook_attempts from anon, authenticated;
grant select on public.webhook_attempts to authenticated;
create policy webhook_attempts_select on public.webhook_attempts for select to authenticated using ((select public.is_admin()));

-- The settings: the header value is never given back, only whether one is saved.
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
    'auth_saved', c.webhook_auth is not null,
    'webhook_enabled', c.webhook_enabled,
    'send_cap', c.send_cap,
    'sent_24h', (select count(*) from wa_messages where via = 'api' and created_at > now() - interval '24 hours'),
    'pending_webhooks', (select count(*) from webhook_deliveries where status in ('pending', 'retry', 'sending')),
    'failed_webhooks', (select count(*) from webhook_deliveries where status = 'failed' and created_at > now() - interval '7 days'));
end;
$$;

drop function public.api_webhook_set(text, text, boolean);

-- p_secret / p_auth: null = leave as it is, '' = remove it.
-- p_auth is sent exactly as typed (no prefix is added) as the "Authorization" header of every delivery.
create or replace function public.api_webhook_set(p_url text, p_secret text, p_enabled boolean, p_auth text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(trim(coalesce(p_url, '')), '');
  v_host text;
  v_auth text := btrim(p_auth, E' \t\r\n');
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
  -- a header value is one line of visible characters (nothing that could add another header)
  if v_auth is not null and v_auth <> '' and (v_auth ~ '[\x00-\x1f\x7f]' or length(v_auth) > 2000) then
    raise exception 'The Authorization value must be one line (up to 2000 characters)';
  end if;
  update api_config
     set webhook_url = v_url,
         webhook_secret = case when p_secret is null then webhook_secret else nullif(trim(p_secret), '') end,
         webhook_auth = case when p_auth is null then webhook_auth else nullif(v_auth, '') end,
         webhook_enabled = p_enabled,
         updated_at = now()
   where id = 1;
end;
$$;

revoke execute on function public.api_webhook_set(text, text, boolean, text) from public, anon;
grant execute on function public.api_webhook_set(text, text, boolean, text) to authenticated;

-- The result of one try: now with the start of the answer, kept for every try.
drop function public.api_delivery_result(uuid, boolean, int, text);

create or replace function public.api_delivery_result(p_id uuid, p_ok boolean, p_code int, p_error text, p_body text default null)
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
  insert into webhook_attempts (delivery_id, attempt, code, body, error)
  values (p_id, (select count(*) + 1 from webhook_attempts where delivery_id = p_id), coalesce(p_code, 0),
          left(p_body, 300), case when p_ok then null else left(coalesce(p_error, 'failed'), 300) end);
  update webhook_deliveries
     set status = v_status, attempts = attempts + 1, locked_at = null, last_code = p_code,
         last_error = case when p_ok then null else left(coalesce(p_error, 'failed'), 300) end,
         next_attempt_at = coalesce(v_next, next_attempt_at),
         delivered_at = case when p_ok then now() else delivered_at end
   where id = p_id;
  return v_status;
end;
$$;

revoke execute on function public.api_delivery_result(uuid, boolean, int, text, text) from public, anon, authenticated;
grant execute on function public.api_delivery_result(uuid, boolean, int, text, text) to service_role;
