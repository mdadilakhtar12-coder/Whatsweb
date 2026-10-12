// AIFM Education app (Appx)  ->  CRM: the work behind the "appx" function (receiving events, trying again).
// No Deno or network calls of its own: everything it needs comes in through `Ctx` (the same one the
// Webinar.gg function uses), so it can be tested alone.
import { type Ctx, json } from "./webinar_core.ts";
import { extract, forDatabase, kindOf, readFields, sha256Hex } from "./appx_logic.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

export const MAX_ATTEMPTS = 5;
const BUCKET_MS = 10 * 60_000;

/**
 * One webhook call. The event is written first (so it cannot get lost), then put into the CRM.
 * The same delivery twice within ten minutes is dropped; a student who cancels again later is a new event.
 */
export async function receive(
  ctx: Ctx,
  req: Request,
  kindText: string,
  opts: { test?: boolean; onSaved?: (id: number) => void } = {},
): Promise<Response> {
  const db = ctx.db;
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > 256 * 1024) return json({ error: "Too big" }, 413);
  const text = await req.text();
  if (text.length > 256 * 1024) return json({ error: "Too big" }, 413);

  const kind = kindOf(kindText);
  const fields = readFields(text, new URL(req.url).searchParams);
  const key = (opts.test ? "test:" : "") + await sha256Hex(`${kindText}|${JSON.stringify(fields)}|${Math.floor(ctx.now() / BUCKET_MS)}`);

  const { data: row, error } = await db.from("appx_events").insert({
    event_key: key,
    kind: kind ?? (String(kindText || "(none)").slice(0, 40)),
    body: fields as Any,
    outcome: kind ? "received" : "ignored",
    processed_at: kind ? null : new Date().toISOString(),
  }).select("id").single();
  if (error) {
    if (error.code === "23505") return json({ ok: true, duplicate: true });
    console.error("appx event not saved", error.message);
    // Appx may try again later.
    return json({ error: "Could not save" }, 500);
  }

  opts.onSaved?.(row.id as number);
  if (kind) {
    const job = processEvent(ctx, row.id as number).catch((e) => console.error("appx event", e));
    if (ctx.waitUntil) ctx.waitUntil(job);
    else await job;
  }
  return json({ ok: true });
}

/** Puts one saved event into the CRM. Safe to run again. */
export async function processEvent(ctx: Ctx, id: number) {
  const db = ctx.db;
  const { data: row } = await db.from("appx_events").select("*").eq("id", id).maybeSingle();
  if (!row || row.outcome === "ok" || row.outcome === "ignored") return;
  const kind = kindOf(row.kind);
  if (!kind) {
    await db.from("appx_events").update({ outcome: "ignored", processed_at: new Date().toISOString() }).eq("id", id);
    return;
  }
  const attempts = (row.attempts as number) + 1;
  try {
    const applied = forDatabase(kind, extract((row.body ?? {}) as Record<string, string>));
    const { data, error } = await db.rpc("appx_apply", { p_kind: kind, p_ts: row.created_at, p_d: applied as Any });
    if (error) throw new Error(error.message);
    const status = String((data as Any)?.status ?? "");
    if (status === "invalid") {
      // Nothing to identify the person by: trying again cannot help.
      await db.from("appx_events").update({
        outcome: "error", error: String((data as Any)?.reason ?? "invalid"), attempts: MAX_ATTEMPTS,
        processed_at: new Date().toISOString(),
      }).eq("id", id);
      return;
    }
    await db.from("appx_events").update({
      outcome: status === "ignored" ? "ignored" : "ok", error: null, attempts, processed_at: new Date().toISOString(),
    }).eq("id", id);
  } catch (e) {
    await db.from("appx_events").update({
      outcome: "error", error: (e instanceof Error ? e.message : String(e)).slice(0, 500), attempts,
      processed_at: new Date().toISOString(),
    }).eq("id", id);
  }
}

/** Every hour: events that failed (or never got processed) once. */
export async function retry(ctx: Ctx) {
  const { data: open } = await ctx.db.from("appx_events").select("id")
    .in("outcome", ["received", "error"]).lt("attempts", MAX_ATTEMPTS)
    .lt("created_at", new Date(ctx.now() - 2 * 60_000).toISOString())
    .order("id").limit(200);
  for (const r of open ?? []) await processEvent(ctx, r.id as number);
  return { retried: (open ?? []).length };
}

/**
 * "Send a test" in the app: a made-up student signs up, buys a ₹499 course (the same purchase is sent twice),
 * cancels a payment and gets a refund. It goes through exactly the same path as a real event. Test rows are left
 * out of the numbers, and "Remove test data" in the app deletes them.
 */
export async function sendTest(ctx: Ctx) {
  const db = ctx.db;
  const stamp = ctx.now().toString(36);
  const email = `appx-test-${stamp}@example.com`;
  const txn = `test_txn_${stamp}`;
  const direct: Ctx = { ...ctx, waitUntil: null };
  const send = async (kind: string, body: Record<string, unknown>) => {
    let id = 0;
    const res = await receive(
      direct,
      new Request(`https://local/appx/test/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
      kind,
      { test: true, onSaved: (i) => id = i },
    );
    const out = await res.json().catch(() => ({}));
    return { status: res.status, duplicate: !!(out as Any).duplicate, id };
  };

  const a = await send("signup", { Name: "TEST Appx student", Email: email, State: "Bihar" });
  const b = await send("purchase", { Name: "TEST Appx student", Email: email, "Item Name": "TEST course (you can delete this)", "Payment Amount": "499", "Transaction ID": txn, "Payment Mode": "UPI" });
  const c = await send("purchase", { Name: "TEST Appx student", Email: email, "Item Name": "TEST course (you can delete this)", "Payment Amount": "499", "Transaction ID": txn, "Payment Mode": "UPI" });
  const d = await send("cancelled", { Name: "TEST Appx student", Email: email, "Item Name": "TEST other course" });
  if ([a, b, c, d].some((x) => x.status !== 200)) {
    return { ok: false, lines: ["❌ The address did not answer correctly"], email };
  }

  const lines: string[] = [];
  let ok = true;
  const check = (good: boolean, yes: string, no: string) => {
    lines.push((good ? "✅ " : "❌ ") + (good ? yes : no));
    if (!good) ok = false;
  };
  const { data: evs } = await db.from("appx_events").select("id, kind, outcome, error").in("id", [a.id, b.id, d.id]);
  const byId = new Map<number, Any>((evs ?? []).map((e: Any) => [e.id as number, e]));
  const why = (x: Any) => x?.error ?? x?.outcome ?? "?";
  check(byId.get(a.id)?.outcome === "ok", "Signup received and saved", `Signup not saved: ${why(byId.get(a.id))}`);
  check(byId.get(b.id)?.outcome === "ok", "Purchase received and saved", `Purchase not saved: ${why(byId.get(b.id))}`);
  check(byId.get(d.id)?.outcome === "ok", "Cancelled payment received and saved", `Cancelled payment not saved: ${why(byId.get(d.id))}`);
  check(c.duplicate, "The same purchase sent twice was recognised (counted once)", "A repeated purchase was not recognised");

  const { data: lead } = await db.from("leads").select("id, status, appx_state, appx_paid, source").eq("email", email).maybeSingle();
  const { count } = await db.from("appx_purchases").select("txn_id", { count: "exact", head: true }).eq("txn_id", txn);
  check(!!lead, "A lead was made (source: appx)", "No lead was made");
  check(lead?.appx_state === "purchased" && Number(lead?.appx_paid) === 499 && count === 1,
    "The lead shows Purchased ₹499 (one purchase)",
    `The lead shows "${lead?.appx_state ?? "nothing"}" and ₹${lead?.appx_paid ?? 0} (expected purchased, ₹499)`);
  lines.push(`Test student: ${email}`);
  lines.push("Look for the lead named TEST Appx student in Leads. Tap Remove test data when you have seen it.");
  return { ok, lines, email, lead_id: (lead?.id as string | undefined) ?? null };
}
