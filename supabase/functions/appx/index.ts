// AIFM Education app (Appx)  ->  CRM.
//
//   POST  /functions/v1/appx/<secret>/<kind>   The Appx CMS (Integrations > Webhooks) sends signups, purchases,
//                                             cancelled payments, demo requests, contact forms and refunds here.
//                                             <kind>: signup | purchase | cancelled | demo | contact | refund.
//                                             The secret is app_settings.integrations.appx_token
//                                             (shown in the app: More > AIFM Education app).
//   POST  /functions/v1/appx                   the app (admin): send_test
//                                             the database (x-webhook-key): retry, every hour
//
// The webhook answers 200 as soon as the event is written to appx_events (a repeat delivery is recognised
// there and dropped); the rest happens in the background. An event that fails is tried again by the hourly
// retry, so a bad moment never loses a purchase.
import { createClient } from "npm:@supabase/supabase-js@2";
import { type Ctx, json } from "../_shared/webinar_core.ts";
import { partsFromPath, safeEqual } from "../_shared/appx_logic.ts";
import { receive, retry, sendTest } from "../_shared/appx_core.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-key",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

let cachedSecret: { value: string; at: number } | null = null;

// deno-lint-ignore no-explicit-any
async function webhookSecret(db: any): Promise<string> {
  if (cachedSecret && Date.now() - cachedSecret.at < 60_000) return cachedSecret.value;
  const { data } = await db.from("app_settings").select("value").eq("key", "integrations").maybeSingle();
  const value = String((data?.value as Record<string, unknown> | undefined)?.appx_token ?? "");
  cachedSecret = { value, at: Date.now() };
  return value;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const ctx: Ctx = {
    db,
    env: (k) => Deno.env.get(k),
    fetch: (...a) => fetch(...a),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    now: () => Date.now(),
    // deno-lint-ignore no-explicit-any
    waitUntil: (globalThis as any).EdgeRuntime?.waitUntil ? (p) => (globalThis as any).EdgeRuntime.waitUntil(p) : null,
  };
  const { secret, kind } = partsFromPath(new URL(req.url).pathname);

  // ---- Appx (the address carries the secret) ----------------------------------
  if (secret) {
    const expected = await webhookSecret(db);
    // The same answer for "wrong" and "not set up": nobody learns anything by guessing.
    if (!expected || expected.length < 20 || !safeEqual(secret, expected)) return json({ error: "Not found" }, 404);
    if (req.method === "GET") return json({ ok: true, message: "The Appx address is working. Appx must send events with POST." });
    if (req.method !== "POST") return json({ error: "Use POST" }, 405);
    return await receive(ctx, req, kind);
  }

  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request" }, 400);
  }

  try {
    // ---- the database (hourly) -------------------------------------------------
    const systemKey = req.headers.get("x-webhook-key");
    if (systemKey) {
      const real = Deno.env.get("WEBHOOK_KEY") ?? "";
      if (!real || !safeEqual(systemKey, real)) return json({ error: "Invalid key" }, 401);
      if (body.action === "retry") return json(await retry(ctx));
      return json({ error: "Unknown action" }, 400);
    }

    // ---- the app (admin) ---------------------------------------------------------
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: authError } = await db.auth.getUser(jwt);
    if (authError || !userData.user) return json({ error: "Please log in again" }, 401);
    const { data: me } = await db.from("profiles").select("id, role, is_active").eq("id", userData.user.id).single();
    if (!me || !me.is_active || me.role !== "admin") return json({ error: "Only admin can do this" }, 403);

    switch (String(body.action ?? "")) {
      case "send_test":
        return json(await sendTest(ctx));
      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
