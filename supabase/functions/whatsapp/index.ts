// WhatsApp Cloud API, called by the app (with the logged-in user's token) and by the database
// (x-webhook-key) to send what is queued.
//
// App actions:
//   admin:  connect, status, disconnect, sync_templates, submit_template, delete_template
//   anyone: send (text / template / media / reply), mark_read
// Database: process (sends the queued automatic messages, follow-ups and broadcasts)
import {
  BUCKET,
  type Cfg,
  type Db,
  graph,
  loadCfg,
  logActivity,
  type NodeRow,
  sendMedia,
  sendNode,
  sendTemplate,
  sendText,
  serviceClient,
  type TemplateRow,
  WaError,
} from "../_shared/wa.ts";
import {
  buildComponents,
  cleanAsked,
  friendlyError,
  guessMime,
  type Lead,
  missingAsked,
  specFromComponents,
  validateSpec,
  windowOpen,
} from "../_shared/wa_logic.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

class UserError extends Error {}

type Body = Record<string, unknown>;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const db = serviceClient();
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request" }, 400);
  }

  try {
    // From the database: send what is queued.
    const systemKey = req.headers.get("x-webhook-key");
    if (systemKey) {
      if (systemKey !== Deno.env.get("WEBHOOK_KEY")) return json({ error: "Invalid key" }, 401);
      if (body.action === "process") return json(await processOutbox(db));
      return json({ error: "Unknown action" }, 400);
    }

    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: authError } = await db.auth.getUser(token);
    if (authError || !userData.user) return json({ error: "Please log in again" }, 401);
    const { data: me } = await db.from("profiles").select("id, role, is_active").eq("id", userData.user.id).single();
    if (!me || !me.is_active) return json({ error: "Your account is switched off" }, 403);
    const isAdmin = me.role === "admin";
    const action = String(body.action ?? "");

    const adminActions = ["connect", "status", "disconnect", "sync_templates", "submit_template", "delete_template"];
    if (adminActions.includes(action) && !isAdmin) return json({ error: "Only admin can do this" }, 403);

    switch (action) {
      case "status":
        return json(await status(db));
      case "connect":
        return json(await connect(db, body));
      case "disconnect": {
        await setStatus(db, { connected: false });
        return json(await status(db));
      }
      case "sync_templates": {
        const cfg = await needCfg(db);
        return json({ count: await syncTemplates(db, cfg) });
      }
      case "submit_template":
        return json(await submitTemplate(db, await needCfg(db), String(body.template_id)));
      case "delete_template":
        return json(await deleteTemplate(db, await needCfg(db), String(body.template_id)));
      case "send":
        return json(await sendFromApp(db, me.id, isAdmin, body));
      case "mark_read":
        return json(await markRead(db, me.id, isAdmin, String(body.lead_id)));
      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (!(e instanceof UserError) && !(e instanceof WaError)) console.error(e);
    return json({ error: message }, e instanceof UserError || e instanceof WaError ? 400 : 500);
  }
});

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

async function needCfg(db: Db): Promise<Cfg> {
  const cfg = await loadCfg(db);
  if (!cfg) throw new UserError("Save the access token and Phone Number ID first (More > WhatsApp > Connect)");
  return cfg;
}

async function setStatus(db: Db, patch: Record<string, unknown>) {
  const { data } = await db.from("app_settings").select("value").eq("key", "whatsapp_status").maybeSingle();
  const value = { ...(data?.value ?? {}), ...patch };
  await db.from("app_settings").upsert({ key: "whatsapp_status", value, updated_at: new Date().toISOString() });
}

async function status(db: Db) {
  const { data: c } = await db.from("wa_config").select("*").eq("id", 1).single();
  const { data: st } = await db.from("app_settings").select("value").eq("key", "whatsapp_status").maybeSingle();
  return {
    webhook_url: `${Deno.env.get("SUPABASE_URL")}/functions/v1/whatsapp-webhook`,
    verify_token: c?.verify_token,
    phone_number_id: c?.phone_number_id ?? "",
    waba_id: c?.waba_id ?? "",
    app_id: c?.app_id ?? "",
    token_saved: c?.access_token ? "••••" + String(c.access_token).slice(-4) : null,
    secret_saved: !!c?.app_secret,
    status: st?.value ?? {},
  };
}

function clean(v: unknown): string | null {
  const s = String(v ?? "").replace(/\s+/g, "").trim();
  return s === "" ? null : s;
}

async function connect(db: Db, body: Body) {
  // Only the boxes that were filled are changed, so a saved token stays when it is left empty.
  const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
  for (const k of ["access_token", "app_secret", "app_id", "phone_number_id", "waba_id"]) {
    const v = clean(body[k]);
    if (v) patch[k] = v;
  }
  await db.from("wa_config").update(patch).eq("id", 1);

  const cfg = await needCfg(db);
  if (cfg.waba_id && cfg.phone_number_id === cfg.waba_id) {
    await setStatus(db, { connected: false, error: "Phone number ID and Business Account ID are the same" });
    throw new UserError(
      "Phone number ID and WhatsApp Business Account ID are the same number. They must be two different numbers: " +
        "both are on Meta developer site > WhatsApp > API Setup.",
    );
  }
  const warnings: string[] = [];
  // deno-lint-ignore no-explicit-any
  let info: any;
  try {
    info = await graph(cfg, `/${cfg.phone_number_id}`, {
      query: { fields: "display_phone_number,verified_name,quality_rating,name_status,messaging_limit_tier" },
    });
  } catch (e) {
    if (e instanceof WaError && e.code === 100) {
      info = await graph(cfg, `/${cfg.phone_number_id}`, { query: { fields: "display_phone_number,verified_name,quality_rating" } });
    } else {
      const message = e instanceof WaError ? friendlyError(e.code, e.message) : e instanceof Error ? e.message : String(e);
      await setStatus(db, { connected: false, error: message });
      throw new UserError(message);
    }
  }

  if (!info.display_phone_number) {
    await setStatus(db, { connected: false, error: "That is not a phone number ID" });
    throw new UserError("Meta did not recognise that Phone number ID. Copy the Phone number ID again from WhatsApp > API Setup.");
  }

  if (cfg.waba_id) {
    try {
      await graph(cfg, `/${cfg.waba_id}/subscribed_apps`, { method: "POST" });
    } catch (e) {
      warnings.push("Could not connect the app to this WhatsApp account: " + (e instanceof Error ? e.message : e));
    }
  } else {
    warnings.push("WhatsApp Business Account ID is missing: templates and replies will not work");
  }
  if (!cfg.app_secret) warnings.push("App secret is missing: replies and delivery ticks cannot be checked");
  if (!cfg.app_id) warnings.push("App ID is missing: only needed for templates with a picture, video or PDF heading");

  await setStatus(db, {
    connected: true,
    error: null,
    display_phone: info.display_phone_number ?? null,
    verified_name: info.verified_name ?? null,
    quality: info.quality_rating ?? null,
    name_status: info.name_status ?? null,
    tier: info.messaging_limit_tier ?? null,
    checked_at: new Date().toISOString(),
  });

  let templates = 0;
  if (cfg.waba_id) {
    try {
      templates = await syncTemplates(db, cfg);
    } catch (e) {
      warnings.push("Could not read the templates: " + (e instanceof Error ? e.message : e));
    }
  }
  return { ...(await status(db)), warnings, templates };
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

async function syncTemplates(db: Db, cfg: Cfg): Promise<number> {
  if (!cfg.waba_id) throw new UserError("WhatsApp Business Account ID is missing");
  // deno-lint-ignore no-explicit-any
  const all: any[] = [];
  let path = `/${cfg.waba_id}/message_templates`;
  let query: Record<string, string | number> | undefined = {
    fields: "id,name,language,category,status,components,rejected_reason,quality_score",
    limit: 100,
  };
  for (let page = 0; page < 5; page++) {
    const r = await graph(cfg, path, { query });
    all.push(...(r.data ?? []));
    if (!r.paging?.next) break;
    path = r.paging.next;
    query = undefined;
  }
  const { data: existing } = await db.from("wa_templates").select("id, name, language");
  const now = new Date().toISOString();
  let count = 0;
  for (const t of all) {
    if (t.category !== "MARKETING" && t.category !== "UTILITY") continue;
    const patch = {
      status: String(t.status),
      reason: t.rejected_reason && t.rejected_reason !== "NONE" ? String(t.rejected_reason) : null,
      meta_id: String(t.id),
      quality: t.quality_score?.score ?? null,
      category: t.category,
      updated_at: now,
    };
    const row = (existing ?? []).find((e: { name: string; language: string }) => e.name === t.name && e.language === t.language);
    if (row) {
      await db.from("wa_templates").update(patch).eq("id", row.id);
    } else {
      await db.from("wa_templates").insert({ ...patch, name: t.name, language: t.language, spec: specFromComponents(t.components ?? []) });
    }
    count++;
  }
  return count;
}

async function uploadHandle(db: Db, cfg: Cfg, path: string, filename?: string): Promise<string> {
  if (!cfg.app_id) throw new UserError("Save the App ID in More > WhatsApp > Connect (needed for a picture, video or PDF heading)");
  const { data: blob, error } = await db.storage.from(BUCKET).download(path);
  if (error || !blob) throw new UserError("The heading file could not be found: choose it again");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const mime = blob.type && blob.type !== "application/octet-stream" ? blob.type : guessMime(path);
  const session = await graph(cfg, `/${cfg.app_id}/uploads`, {
    method: "POST",
    query: { file_length: bytes.length, file_type: mime, file_name: filename ?? path.split("/").pop() ?? "file" },
  });
  const done = await graph(cfg, `/${session.id}`, {
    method: "POST",
    raw: bytes,
    auth: `OAuth ${cfg.access_token}`,
    headers: { file_offset: "0" },
  });
  if (!done.h) throw new UserError("Meta did not accept the heading file");
  return String(done.h);
}

async function submitTemplate(db: Db, cfg: Cfg, id: string) {
  if (!cfg.waba_id) throw new UserError("WhatsApp Business Account ID is missing (More > WhatsApp > Connect)");
  const { data: t } = await db.from("wa_templates").select("*").eq("id", id).single();
  if (!t) throw new UserError("Template not found");
  const problem = validateSpec(t.name, t.spec ?? {});
  if (problem) throw new UserError(problem);

  const spec = structuredClone(t.spec ?? {});
  const h = spec.header ?? {};
  if ((h.type === "image" || h.type === "video" || h.type === "document") && h.media_path) {
    h.handle = await uploadHandle(db, cfg, h.media_path, h.filename);
    spec.header = h;
  }
  const components = buildComponents(spec);
  const now = new Date().toISOString();

  let metaId: string | null = t.meta_id;
  let state = "PENDING";
  let category = t.category;
  if (t.meta_id && t.status !== "DRAFT") {
    await graph(cfg, `/${t.meta_id}`, { method: "POST", body: { components } });
  } else {
    const r = await graph(cfg, `/${cfg.waba_id}/message_templates`, {
      method: "POST",
      body: { name: t.name, language: t.language, category: t.category, allow_category_change: true, components },
    });
    metaId = r.id ? String(r.id) : null;
    state = r.status ? String(r.status) : "PENDING";
    if (r.category === "MARKETING" || r.category === "UTILITY") category = r.category;
  }
  await db.from("wa_templates").update({ spec, status: state, meta_id: metaId, category, reason: null, updated_at: now }).eq("id", id);
  return { status: state };
}

async function deleteTemplate(db: Db, cfg: Cfg, id: string) {
  const { data: t } = await db.from("wa_templates").select("*").eq("id", id).single();
  if (!t) return { deleted: true };
  let warning: string | null = null;
  if (t.status !== "DRAFT" && cfg.waba_id) {
    try {
      await graph(cfg, `/${cfg.waba_id}/message_templates`, {
        method: "DELETE",
        query: { name: t.name, ...(t.meta_id ? { hsm_id: t.meta_id } : {}) },
      });
    } catch (e) {
      warning = "Meta said: " + (e instanceof Error ? e.message : e);
    }
  }
  await db.from("wa_templates").delete().eq("id", id);
  return { deleted: true, warning };
}

// ---------------------------------------------------------------------------
// Sending from the app (inbox)
// ---------------------------------------------------------------------------

/** The lead, only if this user is allowed to see it (admin: every lead, agent: their own). */
async function visibleLead(db: Db, userId: string, isAdmin: boolean, leadId: string): Promise<Lead> {
  const { data } = await db.from("leads").select("*").eq("id", leadId).maybeSingle();
  if (!data || (!isAdmin && data.assigned_to !== userId)) throw new UserError("Lead not found");
  if (!data.phone) throw new UserError("This lead has no phone number");
  return data as Lead;
}

async function sendFromApp(db: Db, userId: string, isAdmin: boolean, body: Body) {
  const cfg = await needCfg(db);
  const lead = await visibleLead(db, userId, isAdmin, String(body.lead_id));
  const mode = String(body.mode ?? "");
  const closed = "The 24-hour reply window is closed. Send an approved template to start the chat again.";

  if (mode === "text") {
    const text = String(body.text ?? "").trim();
    if (!text) throw new UserError("Write a message");
    if (!windowOpen(lead)) throw new UserError(closed);
    return await sendText(db, cfg, lead, text, "manual", userId, true);
  }

  if (mode === "template") {
    if (lead.wa_opt_out) throw new UserError("This student asked to stop WhatsApp messages");
    const { data: tpl } = await db.from("wa_templates").select("*").eq("id", String(body.template_id)).maybeSingle();
    if (!tpl || tpl.status !== "APPROVED") throw new UserError("Choose a template that Meta has approved");
    // Variables that are typed in when sending ({ask.semester}).
    const asked = cleanAsked(body.values);
    const missing = missingAsked((tpl as TemplateRow).spec ?? {}, asked);
    if (missing.length) throw new UserError(`Fill in: ${missing.join(", ")}`);
    return await sendTemplate(db, cfg, lead, tpl as TemplateRow, { kind: "manual", userId, touch: true, asked });
  }

  if (mode === "media") {
    if (!windowOpen(lead)) throw new UserError(closed);
    const path = String(body.path ?? "");
    if (!isAdmin && !path.startsWith("out/")) throw new UserError("Not allowed");
    const type = String(body.media_type ?? "document");
    if (!["image", "video", "document", "audio"].includes(type)) throw new UserError("Unsupported file");
    return await sendMedia(db, cfg, lead, {
      path,
      type: type as "image" | "video" | "document" | "audio",
      filename: body.filename ? String(body.filename) : undefined,
      caption: body.caption ? String(body.caption) : undefined,
      mime: body.mime ? String(body.mime) : undefined,
    }, "manual", userId, true);
  }

  if (mode === "reply") {
    if (!windowOpen(lead)) throw new UserError(closed);
    const { data: node } = await db.from("wa_nodes").select("*").eq("id", String(body.node_id)).maybeSingle();
    if (!node) throw new UserError("Reply not found");
    return await sendNode(db, cfg, lead, node as NodeRow, "manual", userId, true);
  }

  throw new UserError("Unknown message type");
}

async function markRead(db: Db, userId: string, isAdmin: boolean, leadId: string) {
  const lead = await visibleLead(db, userId, isAdmin, leadId).catch(() => null);
  if (!lead) return { ok: true };
  await db.from("leads").update({ wa_unread: 0 }).eq("id", leadId);
  // Blue ticks on the student's phone for their latest message.
  if (windowOpen(lead)) {
    const cfg = await loadCfg(db);
    const { data: last } = await db
      .from("wa_messages")
      .select("wa_id")
      .eq("lead_id", leadId)
      .eq("direction", "in")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (cfg && last?.wa_id) {
      try {
        await graph(cfg, `/${cfg.phone_number_id}/messages`, {
          method: "POST",
          body: { messaging_product: "whatsapp", status: "read", message_id: last.wa_id },
        });
      } catch {
        // not important
      }
    }
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// The sender: automatic messages, follow-ups and broadcasts
// ---------------------------------------------------------------------------

type OutboxRow = {
  id: string;
  lead_id: string;
  template_id: string;
  kind: string;
  broadcast_id: string | null;
  attempts: number;
  params: Record<string, string> | null;
  rule_id: string | null;
};

async function runPool<T>(items: T[], size: number, fn: (item: T) => Promise<void>) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      try {
        await fn(item);
      } catch (e) {
        console.error("sender", e);
      }
    }
  }));
}

async function processOutbox(db: Db) {
  const cfg = await loadCfg(db);
  if (!cfg) return { skipped: "WhatsApp is not connected" };
  const templates = new Map<string, TemplateRow | null>();
  const started = Date.now();
  let sent = 0;
  let failed = 0;

  while (Date.now() - started < 100_000) {
    const { data: rows, error } = await db.rpc("wa_claim_outbox", { p_limit: 24 });
    if (error) {
      console.error(error.message);
      break;
    }
    if (!rows || rows.length === 0) break;
    await runPool(rows as OutboxRow[], 8, async (row) => {
      if (await handleOutbox(db, cfg, row, templates)) sent++;
      else failed++;
    });
  }

  // A broadcast is done when nothing of it is waiting any more.
  const { data: open } = await db.from("wa_broadcasts").select("id").eq("status", "sending");
  for (const b of open ?? []) {
    const { count } = await db
      .from("wa_outbox")
      .select("id", { count: "exact", head: true })
      .eq("broadcast_id", b.id)
      .in("status", ["pending", "sending"]);
    if (!count) await db.from("wa_broadcasts").update({ status: "done" }).eq("id", b.id).eq("status", "sending");
  }
  return { sent, failed };
}

async function handleOutbox(db: Db, cfg: Cfg, row: OutboxRow, templates: Map<string, TemplateRow | null>): Promise<boolean> {
  const finish = (status: string, error: string | null = null) =>
    db.from("wa_outbox").update({ status, error, locked_at: null }).eq("id", row.id);

  const { data: lead } = await db.from("leads").select("*").eq("id", row.lead_id).maybeSingle();
  if (!lead || !lead.phone) {
    await finish("skipped", "No phone number");
    return false;
  }
  if (lead.wa_opt_out) {
    await finish("skipped", "Asked to stop messages");
    return false;
  }
  if (row.kind === "auto" && lead.wa_first_sent_at) {
    await finish("skipped", "Already welcomed");
    return false;
  }
  // An automatic reminder ("has not paid") is not sent to someone who paid while it waited.
  if (row.kind === "nudge" && (lead.webinar_state === "paid") && row.rule_id) {
    const { data: cfg } = await db.from("app_settings").select("value").eq("key", "whatsapp").maybeSingle();
    // deno-lint-ignore no-explicit-any
    const rule = ((cfg?.value?.nudges ?? []) as any[]).find((n) => n.id === row.rule_id);
    if (rule && ["not_paid", "not_paid_no_reply"].includes(rule.only_if ?? "not_paid")) {
      await finish("skipped", "Paid in the meantime");
      return false;
    }
  }

  if (!templates.has(row.template_id)) {
    const { data } = await db.from("wa_templates").select("*").eq("id", row.template_id).maybeSingle();
    templates.set(row.template_id, (data as TemplateRow) ?? null);
  }
  const tpl = templates.get(row.template_id);
  if (!tpl || tpl.status !== "APPROVED") {
    const why = "Template is not approved by Meta";
    await finish("failed", why);
    if (row.kind === "auto") await logActivity(db, lead.id, `Automatic WhatsApp not sent: ${why}`);
    return false;
  }

  // Values typed in by the admin for this broadcast / quick send.
  const asked = cleanAsked(row.params);
  const missing = missingAsked(tpl.spec ?? {}, asked);
  if (missing.length) {
    const why = `Template needs values for: ${missing.join(", ")} (only manual sends and broadcasts can ask for them)`;
    await finish("failed", why);
    if (row.kind === "auto") await logActivity(db, lead.id, `Automatic WhatsApp not sent: ${why}`);
    return false;
  }
  const r = await sendTemplate(db, cfg, lead as Lead, tpl, { kind: row.kind, broadcastId: row.broadcast_id, asked });
  if (r.ok) {
    await finish("sent");
    if (row.kind === "auto") {
      await db.from("leads").update({ wa_first_sent_at: new Date().toISOString() }).eq("id", lead.id);
      await logActivity(db, lead.id, `Automatic WhatsApp sent: ${tpl.name}`, { template: tpl.name });
    }
    if (row.kind === "nudge") await logActivity(db, lead.id, `Reminder WhatsApp sent: ${tpl.name}`, { template: tpl.name, rule: row.rule_id });
    return true;
  }
  if (r.retry && row.attempts < 6) {
    await db
      .from("wa_outbox")
      .update({ status: "pending", error: r.error ?? null, locked_at: null, send_at: new Date(Date.now() + 3 * 60_000).toISOString() })
      .eq("id", row.id);
    return false;
  }
  await finish("failed", r.error ?? "Not sent");
  if (row.kind === "auto") await logActivity(db, lead.id, `Automatic WhatsApp not delivered: ${r.error}`);
  if (row.kind === "nudge") await logActivity(db, lead.id, `Reminder WhatsApp not delivered: ${r.error}`);
  return false;
}
