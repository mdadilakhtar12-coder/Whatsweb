// REST API for an outside AI assistant, and the outgoing webhooks.
//
//   https://<project>.supabase.co/functions/v1/api/v1/...   the REST API (Authorization: Bearer <key>)
//   POST /functions/v1/api  {"action": "deliver"}           the database (x-webhook-key): send the queued webhooks
//
// Keys, the webhook address and the secret are set in the app (More > API & webhooks). This function never
// deletes anything, never reads a key back (only its hash is stored) and answers JSON only.
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadCfg, sendTemplate, sendText } from "../_shared/wa.ts";
import { deliverDue, fail, handle, respond } from "../_shared/api_core.ts";
import type { Cfg, Db, TemplateRow } from "../_shared/wa.ts";
import type { Lead } from "../_shared/wa_logic.ts";

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  const db: Db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const path = new URL(req.url).pathname.split("/").filter(Boolean);

  // ---- the database: send the queued webhooks ---------------------------------------
  const systemKey = req.headers.get("x-webhook-key");
  if (systemKey) {
    const real = Deno.env.get("WEBHOOK_KEY") ?? "";
    if (!real || !safeEqual(systemKey, real)) return fail(401, "invalid_key", "Invalid key");
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch { /* empty */ }
    if (body.action !== "deliver") return fail(400, "unknown_action", "Unknown action");
    return respond(200, await deliverDue({ db, fetch: (...a) => fetch(...a), now: () => Date.now() }));
  }

  // ---- the REST API ---------------------------------------------------------------------
  if (!path.includes("v1")) return fail(404, "not_found", "The API lives under /api/v1/.");
  return await handle({
    db,
    now: () => Date.now(),
    loadCfg: () => loadCfg(db),
    sendText: (cfg, lead, text, keyName) =>
      sendText(db, cfg as Cfg, lead as Lead, text, "manual", null, false, { via: "api", api_key_name: keyName }),
    sendTemplate: (cfg, lead, tpl, values, keyName) =>
      sendTemplate(db, cfg as Cfg, lead as Lead, tpl as TemplateRow, {
        kind: "manual",
        userId: null,
        touch: false,
        asked: {},
        bodyValues: values ?? undefined,
        extra: { via: "api", api_key_name: keyName },
      }),
  }, req);
});
