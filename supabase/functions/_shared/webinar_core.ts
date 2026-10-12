// Webinar.gg  ->  CRM: the work behind the "webinar-gg" function (receiving events, copying attendance).
// No Deno or network calls of its own: everything it needs comes in through `Ctx`, so it can be tested alone.
import {
  extract,
  HANDLED,
  hasMorePages,
  type Invite,
  parseEvent,
  parseInvites,
  sha256Hex,
} from "./webinar_logic.ts";

// deno-lint-ignore no-explicit-any
export type Any = any;
// deno-lint-ignore no-explicit-any
export type Db = any;

export type Ctx = {
  db: Db;
  env: (key: string) => string | undefined;
  fetch: typeof fetch;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
  /** keeps a job running after the answer has been sent (edge runtime), or null to wait for it */
  waitUntil: ((p: Promise<unknown>) => void) | null;
};

export const API = "https://webinar-api.webinar.gg/api/v1";
export const PAGE = 20;
const MAX_PAGES = 250; // 5000 people per webinar and run
const BUDGET_MS = 100_000;
const SPACING_MS = 600; // 100 calls a minute: under the 120 limit
export const MAX_ATTEMPTS = 5;

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-key",
      "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
      "Content-Type": "application/json",
    },
  });
}

export class UserError extends Error {}

// ---------------------------------------------------------------------------
// Webhook
// ---------------------------------------------------------------------------

export async function receive(
  ctx: Ctx,
  req: Request,
  opts: { test?: boolean; onSaved?: (id: number) => void } = {},
): Promise<Response> {
  const db = ctx.db;
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > 512 * 1024) return json({ error: "Too big" }, 413);
  const text = await req.text();
  if (text.length > 512 * 1024) return json({ error: "Too big" }, 413);

  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const ev = parseEvent(raw);
  const handled = !!ev && HANDLED.includes(ev.event);

  // Written first: from here on the event cannot get lost. The same delivery twice is dropped here.
  const { data: row, error } = await db.from("webinar_events").insert({
    event_key: (opts.test ? "test:" : "") + await sha256Hex(text),
    event: ev?.event || "(unknown)",
    event_at: ev?.ts ?? null,
    body: raw as Any,
    outcome: handled ? "received" : "ignored",
    processed_at: handled ? null : new Date().toISOString(),
  }).select("id").single();
  if (error) {
    if (error.code === "23505") return json({ ok: true, duplicate: true });
    console.error("webinar event not saved", error.message);
    // Webinar.gg may try again later.
    return json({ error: "Could not save" }, 500);
  }

  opts.onSaved?.(row.id as number);
  if (handled) {
    const job = processEvent(ctx, row.id as number).catch((e) => console.error("webinar event", e));
    if (ctx.waitUntil) ctx.waitUntil(job);
    else await job;
  }
  return json({ ok: true });
}

/** Puts one saved event into the CRM. Safe to run again. */
export async function processEvent(ctx: Ctx, id: number) {
  const db = ctx.db;
  const { data: row } = await db.from("webinar_events").select("*").eq("id", id).maybeSingle();
  if (!row || row.outcome === "ok" || row.outcome === "ignored") return;
  const ev = parseEvent(row.body);
  if (!ev) {
    await db.from("webinar_events").update({ outcome: "ignored", processed_at: new Date().toISOString() }).eq("id", id);
    return;
  }
  const attempts = (row.attempts as number) + 1;
  try {
    const applied = extract(ev.event, ev.data);
    const { data, error } = await db.rpc("webinar_apply", {
      p_event: ev.event,
      p_ts: ev.ts ?? row.created_at,
      p_d: applied as Any,
    });
    if (error) throw new Error(error.message);
    const status = String((data as Any)?.status ?? "");
    if (status === "invalid") {
      // Nothing to identify the person by: trying again cannot help.
      await db.from("webinar_events").update({
        outcome: "error", error: String((data as Any)?.reason ?? "invalid"), attempts: MAX_ATTEMPTS,
        processed_at: new Date().toISOString(),
      }).eq("id", id);
      return;
    }
    await db.from("webinar_events").update({
      outcome: status === "ignored" ? "ignored" : "ok", error: null, attempts, processed_at: new Date().toISOString(),
    }).eq("id", id);
  } catch (e) {
    await db.from("webinar_events").update({
      outcome: "error", error: (e instanceof Error ? e.message : String(e)).slice(0, 500), attempts,
      processed_at: new Date().toISOString(),
    }).eq("id", id);
  }
}

// ---------------------------------------------------------------------------
// Hourly: retry events, copy attendance, check payments
// ---------------------------------------------------------------------------

async function apiToken(ctx: Ctx): Promise<string | null> {
  const db = ctx.db;
  const fromEnv = (ctx.env("WEBINAR_GG_TOKEN") ?? "").trim();
  if (fromEnv) return fromEnv;
  const { data } = await db.from("webinar_config").select("api_token").eq("id", 1).maybeSingle();
  return (data?.api_token as string | null) ?? null;
}

class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

/** One page of the invite list. Calls are spaced so the limit (120 a minute) is never reached. */
async function fetchInvites(ctx: Ctx, token: string, webinarId: string, page: number): Promise<Any> {
  const wait = SPACING_MS - (ctx.now() - lastCall);
  if (wait > 0) await ctx.sleep(wait);
  lastCall = ctx.now();
  const res = await ctx.fetch(`${API}/webinar/${encodeURIComponent(webinarId)}/invite?page=${page}&limit=${PAGE}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });
  if (!res.ok) {
    throw new ApiError(res.status === 401 || res.status === 403
      ? "Webinar.gg did not accept the API token"
      : res.status === 404
      ? "Webinar not found in Webinar.gg"
      : res.status === 429
      ? "Webinar.gg says: too many requests"
      : `Webinar.gg answered ${res.status}`, res.status);
  }
  return await res.json();
}

let lastCall = 0;

export async function runSync(ctx: Ctx, force: boolean) {
  const db = ctx.db;
  const started = ctx.now();
  const notes: string[] = [];
  const summary = { retried: 0, webinars: 0, people: 0, changed: 0, unmatched: 0, confirmed: 0, missing: 0 };

  // 1. Events that failed (or never got processed) once
  const { data: open } = await db.from("webinar_events").select("id")
    .in("outcome", ["received", "error"]).lt("attempts", MAX_ATTEMPTS)
    .lt("created_at", new Date(ctx.now() - 2 * 60_000).toISOString())
    .order("id").limit(200);
  for (const r of open ?? []) {
    await processEvent(ctx, r.id as number);
    summary.retried++;
  }
  if (summary.retried) notes.push(`${summary.retried} saved event(s) processed again`);

  // 2. Attendance and payment checks from the Webinar.gg API
  const token = await apiToken(ctx);
  if (!token) {
    notes.push("No Webinar.gg API token saved: attendance is not copied");
  } else {
    const { data: list } = await db.rpc("webinar_scan_list", { p_force: force });
    const webinars = (list as string[] | null) ?? [];
    for (const w of webinars) {
      if (ctx.now() - started > BUDGET_MS) {
        notes.push("Stopped early (time): the rest follows in the next hour");
        break;
      }
      try {
        const r = await syncWebinar(ctx, token, w, started + BUDGET_MS);
        summary.webinars++;
        summary.people += r.people;
        summary.changed += r.changed;
        summary.unmatched += r.unmatched;
        summary.confirmed += r.confirmed;
        summary.missing += r.missing;
        if (r.note) notes.push(r.note);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        notes.push(`Webinar ${w}: ${msg}`);
        // A wrong token or a busy API: no use asking for the other webinars now.
        if (e instanceof ApiError && (e.status === 401 || e.status === 403 || e.status === 429)) break;
      }
    }
  }

  const note = notes.length ? notes.join(". ") : "All fine";
  await db.from("webinar_config").update({ last_sync_at: new Date().toISOString(), last_sync_note: note.slice(0, 500) }).eq("id", 1);
  return { ...summary, note };
}

async function syncWebinar(ctx: Ctx, token: string, webinarId: string, deadline: number) {
  const db = ctx.db;
  const people: Invite[] = [];
  let complete = false;
  let before = "";
  for (let page = 0; page < MAX_PAGES && ctx.now() < deadline; page++) {
    const body = await fetchInvites(ctx, token, webinarId, page);
    const { items, totalPages, raw } = parseInvites(body);
    // an API that ignores "page" would send the same people again and again
    const signature = items.map((i) => i.email).join(",");
    if (page > 0 && signature === before) {
      complete = true;
      break;
    }
    before = signature;
    people.push(...items);
    if (!hasMorePages(page, raw, PAGE, totalPages)) {
      complete = true;
      break;
    }
  }

  let note = "";
  if (people.length === 0) {
    // Nothing readable came back: do not change anything (and never call a payment "not found").
    return { people: 0, changed: 0, unmatched: 0, confirmed: 0, missing: 0, note: `Webinar ${webinarId}: the list was empty or not readable` };
  }

  const { data: att, error } = await db.rpc("webinar_set_attendance", {
    p_webinar: webinarId,
    p_rows: people.map((p) => ({ email: p.email, name: p.name, attended: p.attended })) as Any,
  });
  if (error) throw new Error(error.message);
  const matched = Number((att as Any)?.matched ?? 0);
  const changed = Number((att as Any)?.changed ?? 0);

  // Payments of this webinar nobody has checked: is the person in Webinar.gg's list?
  const known = new Set(people.map((p) => p.email));
  const { data: payments } = await db.from("webinar_payments").select("payment_id, email, created_at")
    .eq("webinar_id", webinarId).eq("status", "paid").is("verified", null).limit(2000);
  const ok: string[] = [];
  const missing: { payment_id: string; email: string | null }[] = [];
  for (const p of payments ?? []) {
    const email = String(p.email ?? "").toLowerCase();
    if (email && known.has(email)) ok.push(p.payment_id as string);
    // only judged when the whole list was read, and not for the first half hour (their list may be a little behind)
    else if (complete && ctx.now() - new Date(p.created_at as string).getTime() > 30 * 60_000) {
      missing.push({ payment_id: p.payment_id as string, email: email || null });
    }
  }
  if (ok.length) await db.rpc("webinar_verify", { p_payment_ids: ok, p_ok: true });
  if (missing.length) {
    await db.rpc("webinar_verify", { p_payment_ids: missing.map((m) => m.payment_id), p_ok: false });
    await alertAdmins(ctx, "Webinar payment not found in Webinar.gg",
      `${missing.length} payment(s) were reported but the person is not in the Webinar.gg list${missing[0].email ? ` (${missing[0].email})` : ""}. They are not counted as paid. Please check.`);
    note = `${missing.length} payment(s) not found in Webinar.gg`;
  }
  if (!complete) note = (note ? note + ". " : "") + `Webinar ${webinarId}: only part of the list was read (it continues in the next hour)`;

  return {
    people: people.length,
    changed,
    unmatched: Math.max(people.length - matched, 0),
    confirmed: ok.length,
    missing: missing.length,
    note,
  };
}

async function alertAdmins(ctx: Ctx, title: string, body: string) {
  const db = ctx.db;
  const key = ctx.env("WEBHOOK_KEY");
  if (!key) return;
  const { data } = await db.from("profiles").select("id").eq("role", "admin").eq("is_active", true);
  const messages = (data ?? []).map((r: { id: string }) => ({ user_id: r.id, title, body, data: {} }));
  if (messages.length === 0) return;
  try {
    await ctx.fetch(`${ctx.env("SUPABASE_URL")}/functions/v1/push`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-webhook-key": key },
      body: JSON.stringify({ messages }),
    });
  } catch (e) {
    console.error("push failed", e);
  }
}

// ---------------------------------------------------------------------------
// From the app (admin)
// ---------------------------------------------------------------------------

export async function saveToken(db: Db, token: unknown) {
  const t = String(token ?? "").trim().replace(/^Bearer\s+/i, "");
  if (t.length < 16 || t.length > 4000 || /\s/.test(t)) throw new UserError("That does not look like a Webinar.gg token. Copy it again.");
  await db.from("webinar_config").update({ api_token: t, updated_at: new Date().toISOString() }).eq("id", 1);
  return { saved: true };
}

export async function clearToken(db: Db) {
  await db.from("webinar_config").update({ api_token: null, updated_at: new Date().toISOString() }).eq("id", 1);
  return { saved: false };
}

/**
 * "Send a test" in the app: a made-up student registers and pays (₹149), then the same payment is sent
 * again. It goes through exactly the same path as a real event. Test rows carry "test_" ids, are left out
 * of the numbers, and "Remove test data" in the app deletes them.
 */
export async function sendTest(ctx: Ctx) {
  const db = ctx.db;
  const stamp = ctx.now().toString(36);
  const email = `webinar-test-${stamp}@example.com`;
  const at = (plus: number) => new Date(ctx.now() + plus).toISOString();
  const reg = `test_reg_${stamp}`;
  const created = {
    event: "registration.created",
    timestamp: at(0),
    data: {
      registrationId: reg, webinarId: "test_webinar", webinarTitle: "TEST webinar (you can delete this)",
      name: "TEST Webinar.gg", email, status: "approved", paymentStatus: "pending", registeredAt: at(0),
    },
  };
  const paid = {
    event: "registration.payment.completed",
    timestamp: at(1000),
    data: {
      registrationId: reg, webinarId: "test_webinar", email, paymentId: `test_pay_${stamp}`, orderId: `test_order_${stamp}`,
      ticketAmount: 149, processingFee: 3, totalCharged: 152, currency: "INR", status: "paid",
    },
  };
  const direct: Ctx = { ...ctx, waitUntil: null };
  const ids: number[] = [];
  const dup: boolean[] = [];
  for (const ev of [created, paid, paid]) {
    const res = await receive(direct, new Request("https://local/test", { method: "POST", body: JSON.stringify(ev) }), {
      test: true,
      onSaved: (id) => ids.push(id),
    });
    const body = await res.json().catch(() => ({}));
    dup.push(!!(body as Any).duplicate);
    if (res.status !== 200) return { ok: false, lines: [`❌ The address answered ${res.status}`], email };
  }
  const lines: string[] = [];
  let ok = true;
  const check = (good: boolean, yes: string, no: string) => {
    lines.push((good ? "✅ " : "❌ ") + (good ? yes : no));
    if (!good) ok = false;
  };

  const { data: evs } = await db.from("webinar_events").select("id, event, outcome, error").in("id", ids);
  const byId = new Map<number, Any>((evs ?? []).map((e: Any) => [e.id as number, e]));
  const e1 = byId.get(ids[0]);
  const e2 = byId.get(ids[1]);
  check(e1?.outcome === "ok", "Registration received and saved", `Registration not saved: ${e1?.error ?? e1?.outcome ?? "?"}`);
  check(e2?.outcome === "ok", "Payment received and saved", `Payment not saved: ${e2?.error ?? e2?.outcome ?? "?"}`);
  check(dup[2] === true, "The same payment sent twice was recognised (counted once)", "A repeated payment was not recognised");

  const { data: regRow } = await db.from("webinar_registrations").select("lead_id").eq("registration_id", reg).maybeSingle();
  let leadId: string | null = null;
  if (regRow?.lead_id) {
    leadId = regRow.lead_id as string;
    const { data: lead } = await db.from("leads").select("webinar_state, webinar_paid, source").eq("id", leadId).maybeSingle();
    check(lead?.webinar_state === "paid" && Number(lead?.webinar_paid) === 149, "A lead was made and shows Paid ₹149",
      `The lead shows "${lead?.webinar_state ?? "nothing"}" and ₹${lead?.webinar_paid ?? 0} (expected paid, ₹149)`);
  } else {
    check(false, "", "No lead was made");
  }
  lines.push(`Test student: ${email}`);
  lines.push("Look for the lead named TEST Webinar.gg in Leads. Tap Remove test data when you have seen it.");
  return { ok, lines, email, lead_id: leadId };
}
