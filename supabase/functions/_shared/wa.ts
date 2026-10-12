// WhatsApp Cloud API: talking to Meta and saving what happened.
// Used by the "whatsapp" function (app + sender) and "whatsapp-webhook" (Meta calls us).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type Action,
  friendlyError,
  fillText,
  type Lead,
  NO_WHATSAPP_CODES,
  RETRY_CODES,
  sendComponents,
  type Spec,
  cleanParam,
  compileText,
  templatePreview,
  waNumber,
} from "./wa_logic.ts";

export const GRAPH = "https://graph.facebook.com/v23.0";
export const BUCKET = "wa-media";

export type Db = SupabaseClient;

export type Cfg = {
  access_token: string;
  app_secret: string | null;
  app_id: string | null;
  phone_number_id: string;
  waba_id: string | null;
  verify_token: string;
};

export type TemplateRow = {
  id: string;
  name: string;
  language: string;
  category: string;
  spec: Spec;
  status: string;
  meta_id: string | null;
};

export type NodeRow = {
  id: string;
  name: string;
  kind: "text" | "buttons" | "list";
  header: string | null;
  body: string;
  footer: string | null;
  media_path: string | null;
  media_type: "image" | "video" | "document" | null;
  filename: string | null;
  buttons: { title: string; action?: Action }[];
  list_button: string | null;
  sections: { title?: string; rows: { title: string; description?: string; action?: Action }[] }[];
};

export type Result = { ok: boolean; id?: string; error?: string; code?: number; retry?: boolean };

export function serviceClient(): Db {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function loadCfg(db: Db): Promise<Cfg | null> {
  const { data } = await db.from("wa_config").select("*").eq("id", 1).maybeSingle();
  if (!data?.access_token || !data.phone_number_id) return null;
  return data as Cfg;
}

export class WaError extends Error {
  code: number;
  constructor(message: string, code = 0) {
    super(message);
    this.code = code;
  }
}

// ---------------------------------------------------------------------------
// Graph API
// ---------------------------------------------------------------------------

export async function graph(
  cfg: Pick<Cfg, "access_token">,
  path: string,
  opts: {
    method?: string;
    body?: unknown;
    query?: Record<string, string | number>;
    raw?: Uint8Array;
    headers?: Record<string, string>;
    auth?: string;
  } = {},
  // deno-lint-ignore no-explicit-any
): Promise<any> {
  const url = new URL(path.startsWith("http") ? path : GRAPH + path);
  for (const [k, v] of Object.entries(opts.query ?? {})) url.searchParams.set(k, String(v));
  const res = await fetch(url, {
    method: opts.method ?? "GET",
    headers: {
      Authorization: opts.auth ?? `Bearer ${cfg.access_token}`,
      ...(opts.body ? { "Content-Type": "application/json" } : {}),
      ...opts.headers,
    },
    body: (opts.raw as BodyInit | undefined) ?? (opts.body ? JSON.stringify(opts.body) : undefined),
  });
  const text = await res.text();
  // deno-lint-ignore no-explicit-any
  let json: any = {};
  try {
    json = JSON.parse(text);
  } catch {
    // not JSON
  }
  if (!res.ok || json.error) {
    const e = json.error ?? {};
    const msg = e.error_user_msg || e.error_data?.details || e.message || `Meta said ${res.status}`;
    throw new WaError(String(msg), Number(e.code ?? res.status));
  }
  return json;
}

export async function sendRaw(cfg: Cfg, to: string, payload: Record<string, unknown>): Promise<string> {
  const r = await graph(cfg, `/${cfg.phone_number_id}/messages`, {
    method: "POST",
    body: { messaging_product: "whatsapp", recipient_type: "individual", to, ...payload },
  });
  const id = r.messages?.[0]?.id as string | undefined;
  if (!id) throw new WaError("Meta did not return a message id");
  return id;
}

export async function signedUrl(db: Db, path: string, seconds = 3600): Promise<string> {
  const { data, error } = await db.storage.from(BUCKET).createSignedUrl(path, seconds);
  if (error || !data) throw new Error(`File not found: ${path}`);
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Saving and sending
// ---------------------------------------------------------------------------

const agentNames = new Map<string, string>();

export async function agentName(db: Db, id: string | null): Promise<string> {
  if (!id) return "our team";
  const hit = agentNames.get(id);
  if (hit) return hit;
  const { data } = await db.from("profiles").select("full_name").eq("id", id).maybeSingle();
  const name = (data?.full_name as string | undefined)?.trim() || "our team";
  agentNames.set(id, name);
  return name;
}

type Rec = {
  kind: string;
  type: string;
  body: string;
  template_id?: string;
  template_name?: string;
  broadcast_id?: string | null;
  node_id?: string;
  sent_by?: string | null;
  media_path?: string;
  mime?: string;
  filename?: string;
  /** 'api': sent through the REST API by the AI assistant (and with which key) */
  via?: string;
  api_key_name?: string;
};

const oneLine = (s: string) => s.replace(/\s+/g, " ").trim().slice(0, 140);

/** Records the message, sends it, and records what Meta answered. */
export async function deliver(
  db: Db,
  cfg: Cfg,
  lead: Lead,
  payload: Record<string, unknown>,
  rec: Rec,
  opts: { setState?: boolean; touch?: boolean } = {},
): Promise<Result> {
  const now = new Date().toISOString();
  const { data: row, error: insertError } = await db
    .from("wa_messages")
    .insert({ lead_id: lead.id, direction: "out", status: "queued", ...rec })
    .select("id")
    .single();
  if (insertError || !row) return { ok: false, error: insertError?.message ?? "Could not save the message" };

  try {
    const wamid = await sendRaw(cfg, waNumber(lead.phone ?? ""), payload);
    await db.from("wa_messages").update({ wa_id: wamid, status: "sent", sent_at: now }).eq("id", row.id);
    const upd: Record<string, unknown> = {
      wa_last_message_at: now,
      wa_last_text: oneLine(rec.body),
      wa_last_direction: "out",
    };
    if (opts.setState !== false) upd.wa_state = "sent";
    if (opts.touch) upd.last_contacted_at = now;
    await db.from("leads").update(upd).eq("id", lead.id);
    return { ok: true, id: row.id };
  } catch (e) {
    const code = e instanceof WaError ? e.code : 0;
    const message = friendlyError(code, e instanceof Error ? e.message : String(e));
    if (RETRY_CODES.has(code)) {
      // Not sent: forget this attempt, the caller tries again later.
      await db.from("wa_messages").delete().eq("id", row.id);
      return { ok: false, error: message, code, retry: true };
    }
    await db.from("wa_messages").update({ status: "failed", error: message, error_code: code, failed_at: now }).eq("id", row.id);
    const upd: Record<string, unknown> = { wa_last_message_at: now, wa_last_text: oneLine(rec.body), wa_last_direction: "out" };
    if (opts.setState !== false) upd.wa_state = NO_WHATSAPP_CODES.has(code) ? "no_whatsapp" : "failed";
    await db.from("leads").update(upd).eq("id", lead.id);
    return { ok: false, id: row.id, error: message, code };
  }
}

export async function sendTemplate(
  db: Db,
  cfg: Cfg,
  lead: Lead,
  tpl: TemplateRow,
  opts: {
    kind: string;
    broadcastId?: string | null;
    userId?: string | null;
    touch?: boolean;
    asked?: Record<string, string>;
    /** The REST API: the values of {{1}}, {{2}} ... of the body, in order (instead of the student's own details) */
    bodyValues?: string[];
    /** extra columns of the saved message (via / api_key_name) */
    extra?: { via?: string; api_key_name?: string };
  },
): Promise<Result> {
  const spec = tpl.spec ?? {};
  const agent = await agentName(db, lead.assigned_to);
  const h = spec.header ?? {};
  let components;
  try {
    const mediaUrl = h.media_path && (h.type === "image" || h.type === "video" || h.type === "document")
      ? await signedUrl(db, h.media_path)
      : null;
    components = sendComponents(spec, tpl.id, lead, agent, mediaUrl, opts.asked);
    if (opts.bodyValues) components = withBodyValues(components, opts.bodyValues);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const payload = {
    type: "template",
    template: { name: tpl.name, language: { code: tpl.language }, ...(components.length ? { components } : {}) },
  };
  return deliver(db, cfg, lead, payload, {
    kind: opts.kind,
    type: "template",
    body: opts.bodyValues ? previewWithValues(spec, lead, agent, opts.bodyValues) : templatePreview(spec, lead, agent, opts.asked),
    template_id: tpl.id,
    template_name: tpl.name,
    broadcast_id: opts.broadcastId ?? null,
    sent_by: opts.userId ?? null,
    ...opts.extra,
  }, { touch: opts.touch });
}

/** The body parameters of the components replaced by these values (in order). */
// deno-lint-ignore no-explicit-any
function withBodyValues(components: any[], values: string[]): any[] {
  return components.map((c) =>
    c.type === "body" ? { ...c, parameters: values.map((v) => ({ type: "text", text: cleanParam(v) })) } : c
  );
}

/** What shows in the chat: the template with the given values in the body. */
function previewWithValues(spec: Spec, lead: Lead, agent: string, values: string[]): string {
  const body = compileText(spec.body ?? "").text.replace(/\{\{(\d+)\}\}/g, (_m, n: string) => `[[VAR${n}]]`);
  const text = templatePreview({ ...spec, body }, lead, agent, {});
  return text.replace(/\[\[VAR(\d+)\]\]/g, (_m, n: string) => cleanParam(values[Number(n) - 1]));
}

export function sendText(
  db: Db,
  cfg: Cfg,
  lead: Lead,
  text: string,
  kind: string,
  userId: string | null,
  touch = false,
  extra?: { via?: string; api_key_name?: string },
) {
  return deliver(db, cfg, lead, { type: "text", text: { body: text, preview_url: true } }, {
    kind,
    type: "text",
    body: text,
    sent_by: userId,
    ...extra,
  }, { setState: false, touch });
}

export async function sendMedia(
  db: Db,
  cfg: Cfg,
  lead: Lead,
  media: { path: string; type: "image" | "video" | "document" | "audio"; filename?: string; caption?: string; mime?: string },
  kind: string,
  userId: string | null,
  touch = false,
): Promise<Result> {
  let link: string;
  try {
    link = await signedUrl(db, media.path);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  const obj: Record<string, unknown> = { link };
  if (media.caption && media.type !== "audio") obj.caption = media.caption;
  if (media.type === "document" && media.filename) obj.filename = media.filename;
  const label = { image: "🖼 Photo", video: "🎬 Video", document: "📄 " + (media.filename ?? "Document"), audio: "🎤 Audio" }[media.type];
  return deliver(db, cfg, lead, { type: media.type, [media.type]: obj }, {
    kind,
    type: media.type,
    body: media.caption ? `${label}\n${media.caption}` : label,
    sent_by: userId,
    media_path: media.path,
    mime: media.mime,
    filename: media.filename,
  }, { setState: false, touch });
}

/** One automatic reply: text, buttons or a list (the student pressed something, so the window is open). */
export async function sendNode(
  db: Db,
  cfg: Cfg,
  lead: Lead,
  node: NodeRow,
  kind = "bot",
  userId: string | null = null,
  touch = false,
): Promise<Result> {
  const agent = await agentName(db, lead.assigned_to);
  const fill = (t: string | null | undefined) => (t ? fillText(t, lead, agent) : "");
  const body = fill(node.body);
  const rec = { kind, type: node.kind === "text" ? "text" : "interactive", body, node_id: node.id, sent_by: userId };

  if (node.media_path && node.media_type && node.kind === "text") {
    const r = await sendMedia(db, cfg, lead, {
      path: node.media_path,
      type: node.media_type,
      filename: node.filename ?? undefined,
      caption: body,
    }, kind, userId, touch);
    return r;
  }
  if (node.kind === "text") {
    return deliver(db, cfg, lead, { type: "text", text: { body, preview_url: true } }, rec, { setState: false, touch });
  }

  // deno-lint-ignore no-explicit-any
  const interactive: any = { body: { text: body.slice(0, 1024) } };
  if (node.footer) interactive.footer = { text: fill(node.footer).slice(0, 60) };

  if (node.kind === "buttons") {
    interactive.type = "button";
    if (node.media_path && node.media_type) {
      const link = await signedUrl(db, node.media_path);
      interactive.header = node.media_type === "document"
        ? { type: "document", document: { link, filename: node.filename ?? "file" } }
        : { type: node.media_type, [node.media_type]: { link } };
    } else if (node.header) {
      interactive.header = { type: "text", text: fill(node.header).slice(0, 60) };
    }
    interactive.action = {
      buttons: node.buttons.slice(0, 3).map((b, i) => ({
        type: "reply",
        reply: { id: `n:${node.id}:b${i}`, title: fill(b.title).slice(0, 20) },
      })),
    };
  } else {
    interactive.type = "list";
    if (node.header) interactive.header = { type: "text", text: fill(node.header).slice(0, 60) };
    interactive.action = {
      button: (node.list_button || "Choose").slice(0, 20),
      sections: node.sections.slice(0, 10).map((s, si) => ({
        title: (s.title || "Options").slice(0, 24),
        rows: s.rows.slice(0, 10).map((r, ri) => ({
          id: `n:${node.id}:r${si}.${ri}`,
          title: fill(r.title).slice(0, 24),
          ...(r.description ? { description: fill(r.description).slice(0, 72) } : {}),
        })),
      })),
    };
  }
  return deliver(db, cfg, lead, { type: "interactive", interactive }, rec, { setState: false, touch });
}

// ---------------------------------------------------------------------------
// Side effects
// ---------------------------------------------------------------------------

export async function logActivity(db: Db, leadId: string, body: string, meta: Record<string, unknown> = {}) {
  await db.from("lead_activities").insert({ lead_id: leadId, user_id: null, type: "wa", body, meta });
}

export async function push(
  messages: { user_id: string; title: string; body?: string; data?: Record<string, unknown> }[],
) {
  const key = Deno.env.get("WEBHOOK_KEY");
  if (!key || messages.length === 0) return;
  try {
    await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/push`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-webhook-key": key },
      body: JSON.stringify({ messages }),
    });
  } catch (e) {
    console.error("push failed", e);
  }
}

export async function adminIds(db: Db): Promise<string[]> {
  const { data } = await db.from("profiles").select("id").eq("role", "admin").eq("is_active", true);
  return (data ?? []).map((r: { id: string }) => r.id);
}

/** What happens when the student presses a button or picks a list row. */
export async function runAction(db: Db, cfg: Cfg, lead: Lead, action: Action | undefined, label: string) {
  if (!action) return;
  const upd: Record<string, unknown> = {};
  const done: string[] = [];

  if (action.status) {
    const { data } = await db.from("lead_statuses").select("name").eq("name", action.status).maybeSingle();
    if (data) {
      upd.status = action.status;
      done.push(`status ${action.status}`);
    }
  }
  if (action.temperature) {
    upd.temperature = action.temperature;
    done.push(action.temperature);
  }
  if (action.lost_reason) {
    upd.lost_reason = action.lost_reason;
    done.push(action.lost_reason);
  }
  if (action.optout) {
    upd.wa_opt_out = true;
    done.push("no more WhatsApp messages");
  }
  if (Object.keys(upd).length) await db.from("leads").update(upd).eq("id", lead.id);

  if (action.callback_hours && action.callback_hours > 0) {
    const owner = lead.assigned_to ?? (await adminIds(db))[0];
    if (owner) {
      await db.from("reminders").insert({
        lead_id: lead.id,
        user_id: owner,
        remind_at: new Date(Date.now() + action.callback_hours * 3600_000).toISOString(),
        note: action.note || `Asked for a call on WhatsApp ("${label}")`,
      });
      done.push(`call reminder in ${action.callback_hours}h`);
    }
  }

  if (action.next && !action.optout) {
    const { data: node } = await db.from("wa_nodes").select("*").eq("id", action.next).maybeSingle();
    if (node) await sendNode(db, cfg, lead, node as NodeRow, "bot");
  }

  if (done.length) await logActivity(db, lead.id, `WhatsApp "${label}" → ${done.join(", ")}`, { label });
}
