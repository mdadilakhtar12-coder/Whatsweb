// REST API for an outside AI assistant: the work behind the "api" function.
//   Every request carries "Authorization: Bearer <key>" (keys are made in the app, More > API & webhooks).
//   Reading and the small writes are database functions (api_* in migration 0017); WhatsApp messages go out through
//   the same sender the app uses. Nothing in here deletes anything.
// No Deno and no network of its own: everything comes in through `Deps`, so it can be tested alone.
import { cleanParam, compileText, type Lead, SAMPLES, type Spec } from "./wa_logic.ts";

// deno-lint-ignore no-explicit-any
export type Any = any;

export type Deps = {
  // deno-lint-ignore no-explicit-any
  db: any;
  now: () => number;
  /** the WhatsApp connection (null = not connected) */
  loadCfg: () => Promise<unknown | null>;
  sendText: (cfg: unknown, lead: Lead, text: string, keyName: string) => Promise<{ ok: boolean; id?: string; error?: string }>;
  sendTemplate: (
    cfg: unknown,
    lead: Lead,
    tpl: Any,
    values: string[] | null,
    keyName: string,
  ) => Promise<{ ok: boolean; id?: string; error?: string }>;
};

export const KEY_PATTERN = /^lcrm_[0-9a-f]{64}$/;
export const LIMIT_PER_MINUTE = 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function respond(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

export function fail(status: number, code: string, message: string, extra: Record<string, unknown> = {}): Response {
  return respond(status, { error: { code, message, ...extra } });
}

class HttpError extends Error {
  constructor(public status: number, public code: string, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}
const bad = (code: string, message: string) => new HttpError(400, code, message);

// ---------------------------------------------------------------------------
// Cursors and parameters
// ---------------------------------------------------------------------------

export function encodeCursor(after: { at: string; id: string | number } | null): string | null {
  if (!after) return null;
  return btoa(JSON.stringify([after.at, after.id])).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeCursor(c: string | null): { at: string; id: string } | null {
  if (!c) return null;
  try {
    const raw = atob(c.replace(/-/g, "+").replace(/_/g, "/"));
    const [at, id] = JSON.parse(raw) as [string, string | number];
    if (typeof at !== "string" || Number.isNaN(Date.parse(at)) || (typeof id !== "string" && typeof id !== "number")) throw new Error("x");
    if (!/^[0-9a-f-]{36}$/i.test(String(id)) && !/^\d{1,15}$/.test(String(id))) throw new Error("x");
    return { at, id: String(id) };
  } catch {
    throw bad("invalid_cursor", "The cursor is not valid. Use the next_cursor of the previous page exactly as it was given.");
  }
}

function intParam(q: URLSearchParams, name: string, def: number, min: number, max: number): number {
  const v = q.get(name);
  if (v == null || v === "") return def;
  if (!/^\d{1,6}$/.test(v)) throw bad("invalid_parameter", `"${name}" must be a whole number from ${min} to ${max}.`);
  const n = Number(v);
  if (n < min || n > max) throw bad("invalid_parameter", `"${name}" must be a whole number from ${min} to ${max}.`);
  return n;
}

function isoParam(q: URLSearchParams, name: string): string | null {
  const v = q.get(name);
  if (v == null || v === "") return null;
  const t = Date.parse(v);
  if (Number.isNaN(t)) throw bad("invalid_parameter", `"${name}" must be a time like 2026-10-08T10:30:00Z (ISO 8601).`);
  return new Date(t).toISOString();
}

function paging(q: URLSearchParams, defLimit: number) {
  const cursor = decodeCursor(q.get("cursor"));
  return {
    limit: intParam(q, "limit", defLimit, 1, 200),
    after_at: cursor?.at ?? null,
    after_id: cursor?.id ?? null,
  };
}

function order(q: URLSearchParams, def: "asc" | "desc"): "asc" | "desc" {
  const v = (q.get("order") ?? def).toLowerCase();
  if (v !== "asc" && v !== "desc") throw bad("invalid_parameter", '"order" must be asc or desc.');
  return v;
}

async function readJson(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > 64 * 1024) throw new HttpError(413, "too_big", "The request body is too big.");
  if (!text.trim()) throw bad("invalid_json", "Send a JSON body.");
  try {
    const v = JSON.parse(text);
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("x");
    return v as Record<string, unknown>;
  } catch {
    throw bad("invalid_json", "The body is not valid JSON (an object like {\"text\": \"...\"} is expected).");
  }
}

// ---------------------------------------------------------------------------
// Templates as the AI sees them
// ---------------------------------------------------------------------------

const AUTOMATIC = new Set(["first_name", "name", "phone", "email", "agent_name"]);

export function describeTemplate(t: Any) {
  const spec = (t.spec ?? {}) as Spec;
  const body = compileText(spec.body ?? "");
  const h = spec.header ?? {};
  const header = h.type && h.type !== "none"
    ? { type: h.type, text: h.type === "text" ? compileText(h.text ?? "").text : undefined, filename: h.filename }
    : null;
  return {
    id: t.id,
    name: t.name,
    language: t.language,
    category: t.category,
    status: t.status,
    header,
    body: body.text,
    footer: spec.footer ?? null,
    // {{1}}, {{2}} ... of the body, in order. fill "automatic": the CRM fills it from the student's own details when
    // "variables" is left out; "required": you must send "variables".
    variables: body.vars.map((v, i) => ({
      index: i + 1,
      source: v,
      fill: AUTOMATIC.has(v) || v.startsWith("extra.") ? "automatic" : "required",
      example: spec.examples?.[v] ?? SAMPLES[v] ?? null,
    })),
    buttons: (spec.buttons ?? []).map((b) => ({
      type: b.type,
      text: b.text ?? null,
      url: b.type === "url" ? compileText(b.url ?? "").text : undefined,
      phone: b.type === "phone" ? b.phone : undefined,
    })),
  };
}

// ---------------------------------------------------------------------------
// The router
// ---------------------------------------------------------------------------

type Key = { key_id: string; name: string; scopes: string[] };

export async function handle(deps: Deps, req: Request): Promise<Response> {
  const url = new URL(req.url);
  if ((req.headers.get("x-forwarded-proto") ?? "https").toLowerCase() === "http") {
    return fail(400, "https_required", "Use https:// only.");
  }
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.lastIndexOf("api");
  const route = at >= 0 ? parts.slice(at + 1) : parts;
  if (route[0] !== "v1") return fail(404, "not_found", "Unknown address. The API lives under /api/v1/.");
  const path = route.slice(1);
  const method = req.method.toUpperCase();

  // ---- the key -------------------------------------------------------------
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!KEY_PATTERN.test(token)) {
    return fail(401, "invalid_key", 'Send your API key as "Authorization: Bearer <API_KEY>".');
  }
  const { data: gate, error: gateError } = await deps.db.rpc("api_check", { p_hash: await sha256Hex(token) });
  if (gateError || !gate) return fail(500, "server_error", "Could not check the key. Try again.");
  if (gate.error === "invalid_key" || gate.error === "revoked_key") {
    return fail(401, gate.error, gate.error === "revoked_key" ? "This API key was revoked." : "This API key is not valid.");
  }
  if (gate.error === "rate_limited") {
    const wait = String(gate.retry_after ?? 60);
    return respond(429, { error: { code: "rate_limited", message: `Too many requests: ${LIMIT_PER_MINUTE} a minute are allowed per key.`, retry_after_seconds: Number(wait) } }, {
      "Retry-After": wait,
      "X-RateLimit-Limit": String(LIMIT_PER_MINUTE),
      "X-RateLimit-Remaining": "0",
    });
  }
  const key = gate as Key & { remaining: number };
  const rate = { "X-RateLimit-Limit": String(LIMIT_PER_MINUTE), "X-RateLimit-Remaining": String(key.remaining ?? 0) };

  let leadId: string | null = null;
  let summary: string | null = null;
  let res: Response;
  try {
    const out = await route2(deps, key, method, path, url.searchParams, req, (id) => (leadId = id), (s) => (summary = s));
    res = out;
  } catch (e) {
    if (e instanceof HttpError) {
      res = fail(e.status, e.code, e.message, e.extra);
    } else {
      console.error(e);
      res = fail(500, "server_error", "Something went wrong on our side. Try again.");
    }
  }
  // Every call that changes something (and every refused send) is written down with the key.
  const writes = method !== "GET";
  if (writes) {
    try {
      await deps.db.from("api_log").insert({
        key_id: key.key_id,
        key_name: key.name,
        method,
        path: "/" + path.join("/"),
        status: res.status,
        lead_id: leadId && UUID.test(leadId) ? leadId : null,
        summary: summary ?? (res.status >= 400 ? "refused" : null),
      });
    } catch (e) {
      console.error("api_log", e);
    }
  }
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(rate)) if (!headers.has(k)) headers.set(k, v);
  return new Response(res.body, { status: res.status, headers });
}

function need(key: Key, scope: "read" | "write" | "send") {
  if (!key.scopes.includes(scope)) {
    throw new HttpError(403, "insufficient_scope", `This key may not do this: it has no "${scope}" permission. The owner can make a new key with it.`);
  }
}

function studentId(s: string | undefined): string {
  if (!s || !UUID.test(s)) throw new HttpError(404, "student_not_found", "No student with this id.");
  return s.toLowerCase();
}

async function route2(
  deps: Deps,
  key: Key,
  method: string,
  path: string[],
  q: URLSearchParams,
  req: Request,
  setLead: (id: string) => void,
  setSummary: (s: string) => void,
): Promise<Response> {
  const db = deps.db;
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(name, args);
    if (error) {
      console.error(name, error.message);
      throw new HttpError(500, "server_error", "Something went wrong on our side. Try again.");
    }
    return data as Any;
  };
  const notAllowed = () => {
    throw new HttpError(405, "method_not_allowed", "This address does not accept this method.");
  };
  const [a, b, c] = path;

  // ---- students ------------------------------------------------------------
  if (a === "students" && path.length === 1) {
    if (method !== "GET") notAllowed();
    need(key, "read");
    const created = isoParam(q, "created_after");
    const phone = q.get("phone");
    if (phone && phone.replace(/\D/g, "").length < 7) throw bad("invalid_parameter", '"phone" must be a phone number.');
    const r = await rpc("api_students", {
      p: {
        created_after: created,
        phone: phone ?? null,
        email: q.get("email") ?? null,
        status: q.get("status") ?? null,
        ...paging(q, 50),
      },
    });
    return respond(200, { data: r.data, has_more: r.has_more, next_cursor: encodeCursor(r.next_after) });
  }

  if (a === "students" && path.length >= 2) {
    const id = studentId(b);
    setLead(id);
    if (path.length === 2) {
      if (method === "GET") {
        need(key, "read");
        const s = await rpc("api_student_get", { p_id: id });
        if (!s) throw new HttpError(404, "student_not_found", "No student with this id.");
        return respond(200, s);
      }
      if (method === "PATCH") {
        need(key, "write");
        const body = await readJson(req);
        const status = body.status ?? body.stage;
        if (typeof status !== "string" || !status.trim()) {
          throw bad("invalid_body", 'Send {"status": "interested"} (or "stage"). See GET /statuses for the valid names.');
        }
        const r = await rpc("api_set_status", { p_lead: id, p_status: status, p_key_name: key.name });
        if (!r) throw new HttpError(404, "student_not_found", "No student with this id.");
        if (r.error) throw new HttpError(r.status ?? 422, r.error, r.message, { valid: r.valid });
        setSummary(`status ${r.previous_status} -> ${r.status}`);
        return respond(200, r);
      }
      return notAllowed();
    }
    if (path.length === 3) {
      if (c === "activities") {
        if (method !== "GET") notAllowed();
        need(key, "read");
        const r = await rpc("api_activities", { p_id: id, p: { ...paging(q, 100), order: order(q, "desc") } });
        if (!r) throw new HttpError(404, "student_not_found", "No student with this id.");
        return respond(200, { data: r.data, has_more: r.has_more, next_cursor: encodeCursor(r.next_after) });
      }
      if (c === "messages") {
        if (method !== "GET") notAllowed();
        need(key, "read");
        const r = await rpc("api_messages", { p_id: id, p: { ...paging(q, 100), order: order(q, "asc") } });
        if (!r) throw new HttpError(404, "student_not_found", "No student with this id.");
        return respond(200, { data: r.data, has_more: r.has_more, next_cursor: encodeCursor(r.next_after) });
      }
      if (c === "window") {
        if (method !== "GET") notAllowed();
        need(key, "read");
        const r = await rpc("api_window", { p_id: id });
        if (!r) throw new HttpError(404, "student_not_found", "No student with this id.");
        return respond(200, r);
      }
      if (c === "notes") {
        if (method !== "POST") notAllowed();
        need(key, "write");
        const body = await readJson(req);
        const text = typeof body.text === "string" ? body.text.trim() : "";
        if (!text) throw bad("invalid_body", 'Send {"text": "your note"}.');
        if (text.length > 2000) throw bad("invalid_body", "The note is too long (2000 characters at most).");
        const r = await rpc("api_add_note", { p_lead: id, p_text: text, p_key_name: key.name });
        if (!r) throw new HttpError(404, "student_not_found", "No student with this id.");
        setSummary("note added");
        return respond(201, r);
      }
    }
    throw new HttpError(404, "not_found", "Unknown address.");
  }

  // ---- courses, statuses ---------------------------------------------------------
  if (a === "courses" && path.length === 1) {
    if (method !== "GET") notAllowed();
    need(key, "read");
    return respond(200, { data: await rpc("api_courses", {}) });
  }
  if (a === "statuses" && path.length === 1) {
    if (method !== "GET") notAllowed();
    need(key, "read");
    return respond(200, { data: await rpc("api_statuses", {}) });
  }

  // ---- WhatsApp -------------------------------------------------------------------
  if (a === "whatsapp" && b === "templates" && path.length === 2) {
    if (method !== "GET") notAllowed();
    need(key, "read");
    const { data, error } = await db.from("wa_templates").select("id, name, language, category, status, spec").eq("status", "APPROVED").order("name");
    if (error) throw new HttpError(500, "server_error", "Something went wrong on our side. Try again.");
    return respond(200, { data: (data ?? []).map(describeTemplate) });
  }

  if (a === "whatsapp" && b === "send-text" && path.length === 2) {
    if (method !== "POST") notAllowed();
    need(key, "send");
    const body = await readJson(req);
    const id = studentId(typeof body.student_id === "string" ? body.student_id : undefined);
    setLead(id);
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text) throw bad("invalid_body", 'Send {"student_id": "...", "text": "your message"}.');
    if (text.length > 4096) throw bad("invalid_body", "The message is too long (4096 characters at most).");
    const check = await rpc("api_send_check", { p_lead: id, p_kind: "text" });
    if (!check.ok) throw new HttpError(check.status ?? 409, check.error, check.message, { last_student_message_at: check.last_student_message_at });
    const cfg = await deps.loadCfg();
    if (!cfg) throw new HttpError(503, "whatsapp_not_connected", "WhatsApp is not connected in the CRM.");
    const r = await deps.sendText(cfg, check.lead as Lead, text, key.name);
    if (!r.ok) {
      setSummary(`text not sent: ${r.error ?? "error"}`);
      throw new HttpError(502, "whatsapp_error", r.error ?? "WhatsApp did not accept the message.");
    }
    setSummary("text sent");
    return respond(200, { ok: true, message_id: r.id, student_id: id, sent_by: "ai_assistant" });
  }

  if (a === "whatsapp" && b === "send-template" && path.length === 2) {
    if (method !== "POST") notAllowed();
    need(key, "send");
    const body = await readJson(req);
    const id = studentId(typeof body.student_id === "string" ? body.student_id : undefined);
    setLead(id);
    const name = typeof body.template_name === "string" ? body.template_name.trim() : "";
    if (!name) throw bad("invalid_body", 'Send {"student_id": "...", "template_name": "...", "language": "en", "variables": ["..."]}.');
    const language = typeof body.language === "string" ? body.language.trim() : "";
    let values: string[] | null = null;
    if (body.variables != null) {
      if (!Array.isArray(body.variables) || body.variables.length > 20 ||
        body.variables.some((v) => typeof v !== "string" && typeof v !== "number")) {
        throw bad("invalid_body", '"variables" must be a list of up to 20 texts, like ["Rahul", "Semester 3"].');
      }
      values = body.variables.map((v) => cleanParam(v));
    }

    const check = await rpc("api_send_check", { p_lead: id, p_kind: "template" });
    if (!check.ok) throw new HttpError(check.status ?? 409, check.error, check.message);

    const { data: found, error } = await db.from("wa_templates").select("*").eq("status", "APPROVED").ilike("name", name);
    if (error) throw new HttpError(500, "server_error", "Something went wrong on our side. Try again.");
    const same = ((found ?? []) as Any[]).filter((t) => String(t.name).toLowerCase() === name.toLowerCase());
    const tpl = language ? same.find((t) => String(t.language).toLowerCase() === language.toLowerCase()) : same.length === 1 ? same[0] : undefined;
    if (!tpl) {
      const languages = same.map((t) => t.language);
      throw new HttpError(
        404,
        "template_not_found",
        same.length > 1 && !language
          ? `The template "${name}" exists in several languages (${languages.join(", ")}): send "language".`
          : `No approved template "${name}"${language ? ` in language "${language}"` : ""}. See GET /whatsapp/templates.`,
      );
    }

    const spec = (tpl.spec ?? {}) as Spec;
    const bodyVars = compileText(spec.body ?? "").vars;
    // header and button variables cannot be sent through the API: they come from the student's details
    const others = [
      ...(spec.header?.type === "text" ? compileText(spec.header.text ?? "").vars : []),
      ...(spec.buttons ?? []).filter((x) => x.type === "url").flatMap((x) => compileText(x.url ?? "").vars),
    ];
    const needsAsk = (vars: string[]) => vars.filter((v) => v.startsWith("ask."));
    if (needsAsk(others).length) {
      throw new HttpError(422, "template_not_supported", `This template has a heading or button variable that must be typed in by a person (${needsAsk(others).join(", ")}). Use another template.`);
    }
    if (values) {
      if (values.length !== bodyVars.length) {
        throw new HttpError(422, "variables_mismatch", `This template has ${bodyVars.length} variable(s) in its body ({{1}}...{{${bodyVars.length}}}) but ${values.length} were sent.`, {
          expected: bodyVars.length,
          variables: describeTemplate(tpl).variables,
        });
      }
    } else if (needsAsk(bodyVars).length) {
      throw new HttpError(422, "variables_required", `This template needs "variables": ${needsAsk(bodyVars).join(", ")} must be sent.`, {
        expected: bodyVars.length,
        variables: describeTemplate(tpl).variables,
      });
    }

    const cfg = await deps.loadCfg();
    if (!cfg) throw new HttpError(503, "whatsapp_not_connected", "WhatsApp is not connected in the CRM.");
    const r = await deps.sendTemplate(cfg, check.lead as Lead, tpl, values, key.name);
    if (!r.ok) {
      setSummary(`template ${tpl.name} not sent: ${r.error ?? "error"}`);
      throw new HttpError(502, "whatsapp_error", r.error ?? "WhatsApp did not accept the message.");
    }
    setSummary(`template ${tpl.name} sent`);
    return respond(200, { ok: true, message_id: r.id, student_id: id, template_name: tpl.name, language: tpl.language, sent_by: "ai_assistant" });
  }

  throw new HttpError(404, "not_found", "Unknown address. See the API documentation in the app (More > API & webhooks).");
}

// ---------------------------------------------------------------------------
// Outgoing webhooks: sign and send what the database queued
// ---------------------------------------------------------------------------

export type WebhookDeps = {
  // deno-lint-ignore no-explicit-any
  db: any;
  fetch: typeof fetch;
  now: () => number;
};

/** Public https addresses only (a second check; the app already refuses the others when it saves). */
export function safeWebhookUrl(u: string | null | undefined): boolean {
  if (!u) return false;
  let url: URL;
  try {
    url = new URL(u);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") return false;
  const h = url.hostname.toLowerCase();
  if (h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || h.endsWith(".localhost") || !h.includes(".")) return false;
  if (/^\[/.test(h) || h.includes(":")) return false; // IPv6 addresses
  if (/^\d+\.\d+\.\d+\.\d+$/.test(h)) {
    const [p, q2] = h.split(".").map(Number);
    if (p === 10 || p === 127 || p === 0 || (p === 169 && q2 === 254) || (p === 192 && q2 === 168) || (p === 172 && q2 >= 16 && q2 <= 31)) return false;
  }
  return true;
}

/** The first characters of what the address answered (at most `max`), never more than a few KB are read. */
export async function readStart(res: Response, max: number): Promise<string | null> {
  try {
    if (!res.body) return null;
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let text = "";
    let bytes = 0;
    while (text.length < max && bytes < 8192) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.length;
      text += decoder.decode(value, { stream: true });
    }
    try {
      await reader.cancel();
    } catch { /* not important */ }
    // one clean piece of text: no control characters (they would break the log), at most `max` characters
    const clean = text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "").slice(0, max);
    return clean === "" ? null : clean;
  } catch {
    return null;
  }
}

/** One try for one delivery. The body that is signed is exactly the text that is sent. */
export async function sendOne(
  deps: WebhookDeps,
  cfg: { webhook_url: string | null; webhook_secret: string | null; webhook_auth?: string | null },
  d: { id: string; event: string; payload: unknown },
): Promise<{ ok: boolean; code: number; error: string | null; body: string | null }> {
  if (!safeWebhookUrl(cfg.webhook_url)) return { ok: false, code: 0, error: "The webhook address is not a public https address", body: null };
  const body = JSON.stringify(d.payload);
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "User-Agent": "WhatsWeb-Webhook/1",
    "X-WhatsWeb-Event": d.event,
    "X-WhatsWeb-Delivery": d.id,
  };
  if (cfg.webhook_secret) headers["X-WhatsWeb-Signature"] = await hmacHex(cfg.webhook_secret, body);
  // the receiving address may want its own credential: sent exactly as the owner typed it (no "Bearer " added)
  if (cfg.webhook_auth) headers["Authorization"] = cfg.webhook_auth;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 10_000);
  try {
    const res = await deps.fetch(cfg.webhook_url!, { method: "POST", headers, body, signal: ctl.signal, redirect: "manual" });
    const answer = await readStart(res, 300);
    if (res.status >= 200 && res.status < 300) return { ok: true, code: res.status, error: null, body: answer };
    return {
      ok: false,
      code: res.status,
      error: res.status >= 300 && res.status < 400 ? `Redirected (${res.status}): redirects are not followed` : `The address answered ${res.status}`,
      body: answer,
    };
  } catch (e) {
    return { ok: false, code: 0, error: ctl.signal.aborted ? "No answer within 10 seconds" : (e instanceof Error ? e.message : String(e)).slice(0, 200), body: null };
  } finally {
    clearTimeout(timer);
  }
}

/** Takes what is due (new events and retries) and sends it. Safe to call often. */
export async function deliverDue(deps: WebhookDeps, max = 25) {
  const db = deps.db;
  const { data: c } = await db.from("api_config").select("webhook_url, webhook_secret, webhook_auth, webhook_enabled").eq("id", 1).maybeSingle();
  // switched off: leave everything queued (nothing is lost: switch it on and it goes)
  if (!c?.webhook_enabled || !c?.webhook_url) return { claimed: 0, ok: 0, failed: 0 };
  const { data: rows } = await db.rpc("api_claim_deliveries", { p_limit: max });
  const list = (rows ?? []) as { id: string; event: string; payload: unknown }[];
  let ok = 0;
  let failed = 0;
  const run = async (d: { id: string; event: string; payload: unknown }) => {
    const r = await sendOne(deps, c, d);
    await db.rpc("api_delivery_result", { p_id: d.id, p_ok: r.ok, p_code: r.code, p_error: r.error, p_body: r.body });
    if (r.ok) ok++;
    else failed++;
  };
  // five at a time
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(5, list.length) }, async () => {
    while (i < list.length) await run(list[i++]);
  }));
  return { claimed: list.length, ok, failed };
}
