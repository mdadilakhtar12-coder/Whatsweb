// Sends all leads and their history as CSV files to the admin's Google Drive,
// through the Google Apps Script web app configured in app_settings.backup = {url, key}.
// Called by the database (nightly schedule and the "Backup now" button) with x-webhook-key.
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

async function all(table: string, select: string, order: string): Promise<Row[]> {
  const rows: Row[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await supabase.from(table).select(select).order(order).range(from, from + 999);
    if (error) throw new Error(`${table}: ${error.message}`);
    rows.push(...((data ?? []) as Row[]));
    if (!data || data.length < 1000) return rows;
  }
}

function csv(header: string[], rows: unknown[][]): string {
  const cell = (v: unknown) => {
    const s = v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v);
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  // BOM so Excel opens Hindi / special characters correctly
  return "﻿" + [header, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
}

async function saveStatus(values: Row) {
  const { data } = await supabase.from("app_settings").select("value").eq("key", "backup").maybeSingle();
  await supabase.from("app_settings").upsert({
    key: "backup",
    value: { ...(data?.value ?? {}), ...values },
    updated_at: new Date().toISOString(),
  });
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("WEBHOOK_KEY");
  if (!expected || req.headers.get("x-webhook-key") !== expected) return json({ error: "Invalid key" }, 401);

  const { data: setting } = await supabase.from("app_settings").select("value").eq("key", "backup").maybeSingle();
  const url = setting?.value?.url as string | undefined;
  const key = setting?.value?.key as string | undefined;
  if (!url || !key) return json({ skipped: "Backup is not set up" });

  try {
    const [profiles, leads, activities] = await Promise.all([
      all("profiles", "id, full_name", "id"),
      all("leads", "*", "created_at"),
      all("lead_activities", "id, lead_id, user_id, type, body, meta, created_at", "id"),
    ]);
    const names = new Map(profiles.map((p) => [p.id, p.full_name]));
    const leadNames = new Map(leads.map((l) => [l.id, l.name || l.phone || l.email]));

    const date = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" });
    const files = [
      {
        name: `leads_${date}.csv`,
        content: csv(
          ["Name", "Phone", "Email", "Status", "Hot/Warm/Cold", "Reason", "Source", "Campaign / form",
            "Assigned to", "Created", "Last contacted", "Next follow-up", "Other details", "Lead ID"],
          leads.map((l) => [
            l.name, l.phone, l.email, l.status, l.temperature, l.lost_reason, l.source, l.source_detail,
            names.get(l.assigned_to) ?? "", l.created_at, l.last_contacted_at, l.next_follow_up_at, l.extra, l.id,
          ]),
        ),
      },
      {
        name: `history_${date}.csv`,
        content: csv(
          ["When", "Lead", "By", "What", "Text", "Details", "Lead ID"],
          activities.map((a) => [
            a.created_at, leadNames.get(a.lead_id) ?? "", names.get(a.user_id) ?? "System", a.type, a.body, a.meta,
            a.lead_id,
          ]),
        ),
      },
    ];

    // Apps Script answers POST with a redirect to the result; fetch follows it.
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, files }),
    });
    const text = await res.text();
    let reply: Row = {};
    try {
      reply = JSON.parse(text);
    } catch {
      throw new Error(`Google replied: ${text.slice(0, 200)}`);
    }
    if (!reply.ok) throw new Error(reply.error ?? "Google Drive did not accept the backup");

    await saveStatus({
      last_at: new Date().toISOString(),
      last_status: "ok",
      last_error: null,
      folder_url: reply.folder ?? null,
      last_counts: { leads: leads.length, history: activities.length },
    });
    return json({ ok: true, leads: leads.length, history: activities.length });
  } catch (e) {
    const message = (e as Error).message;
    await saveStatus({ last_at: new Date().toISOString(), last_status: "error", last_error: message });
    return json({ error: message }, 500);
  }
});
