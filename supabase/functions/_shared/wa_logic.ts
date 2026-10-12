// WhatsApp helpers with no network or database calls (so they are easy to test).

export type Lead = {
  id: string;
  name: string;
  phone: string | null;
  email: string | null;
  source: string;
  source_detail: string | null;
  extra: Record<string, unknown> | null;
  assigned_to: string | null;
  wa_last_inbound_at: string | null;
  wa_opt_out: boolean;
  wa_first_sent_at: string | null;
  status: string;
};

export type Action = {
  status?: string;
  temperature?: "hot" | "warm" | "cold";
  lost_reason?: string;
  next?: string; // id of an automatic reply (wa_nodes)
  callback_hours?: number; // remind the agent to call back in N hours
  optout?: boolean;
  note?: string;
};

export type Button = {
  type: "quick_reply" | "url" | "phone" | "copy_code";
  text?: string;
  url?: string;
  phone?: string;
  example?: string;
  action?: Action;
};

export type Header = {
  type?: "none" | "text" | "image" | "video" | "document" | "location";
  text?: string;
  media_path?: string;
  filename?: string;
  handle?: string; // Meta's sample file id, set when the template is submitted
  latitude?: number;
  longitude?: number;
  name?: string;
  address?: string;
};

export type Spec = {
  header?: Header;
  body?: string;
  footer?: string;
  buttons?: Button[];
  /** Example text for each custom variable ("ask.semester": "Semester 3"), shown to Meta when the template is reviewed. */
  examples?: Record<string, string>;
};

// ---------------------------------------------------------------------------
// Phone numbers and variables
// ---------------------------------------------------------------------------

/** Digits with country code and no "+", the way the Cloud API wants them. */
export function waNumber(phone: string): string {
  let d = (phone ?? "").replace(/\D/g, "");
  if (d.length === 10) d = "91" + d;
  else if (d.length === 11 && d.startsWith("0")) d = "91" + d.slice(1);
  return d;
}

export const SAMPLES: Record<string, string> = {
  first_name: "Rahul",
  name: "Rahul Sharma",
  phone: "9876543210",
  email: "rahul@example.com",
  agent_name: "Priya",
};

export function sampleFor(variable: string, examples?: Record<string, string>): string {
  return examples?.[variable]?.trim() || SAMPLES[variable] || "Sample";
}

/** The value of {first_name}, {name}, {phone}, {email}, {agent_name}, {extra.City} for one lead. */
export function resolveVar(variable: string, lead: Lead, agentName: string, asked?: Record<string, string>): string {
  const name = (lead.name ?? "").trim();
  let v = "";
  switch (variable) {
    case "first_name":
      v = name.split(/\s+/)[0] ?? "";
      if (!v) v = "Student";
      break;
    case "name":
      v = name || "Student";
      break;
    case "phone":
      v = lead.phone ?? "";
      break;
    case "email":
      v = lead.email ?? "";
      break;
    case "agent_name":
      v = agentName;
      break;
    default:
      if (variable.startsWith("ask.")) {
        // typed in by the person sending the message
        v = asked?.[variable.slice(4)] ?? "";
      } else if (variable.startsWith("extra.")) {
        const key = variable.slice(6).toLowerCase();
        const found = Object.entries(lead.extra ?? {}).find(([k]) => k.toLowerCase() === key);
        v = found ? String(found[1] ?? "") : "";
      }
  }
  v = v.replace(/[\n\t]+/g, " ").replace(/ {4,}/g, "   ").trim();
  return v || "-"; // Meta rejects empty values
}

/** One value for Meta: one line, not too long, never empty. */
export function cleanParam(v: unknown): string {
  return String(v ?? "").replace(/[\n\t]+/g, " ").replace(/ {4,}/g, "   ").trim().slice(0, 1000) || "-";
}

/** "Hi {first_name}" -> "Hi {{1}}" and the list of variables, in order. */
export function compileText(text: string): { text: string; vars: string[] } {
  const vars: string[] = [];
  const clean = (text ?? "").replace(/\{\{\s*([a-z_][a-z0-9_.]*)\s*\}\}/gi, "{$1}");
  const out = clean.replace(/\{([a-z_][a-z0-9_.]*)\}/gi, (_m, v: string) => {
    vars.push(v.toLowerCase());
    return `{{${vars.length}}}`;
  });
  return { text: out, vars };
}

/** The text with every {variable} filled in (what the student reads). */
export function fillText(text: string, lead: Lead, agentName: string, asked?: Record<string, string>): string {
  const { text: t, vars } = compileText(text);
  return t.replace(/\{\{(\d+)\}\}/g, (_m, n: string) => resolveVar(vars[Number(n) - 1], lead, agentName, asked));
}

/** Names of the variables that are typed in when the message is sent: {ask.semester} -> "semester". */
export function askNames(spec: Spec): string[] {
  const texts = [
    spec.header?.type === "text" ? spec.header.text ?? "" : "",
    spec.body ?? "",
    ...(spec.buttons ?? []).filter((b) => b.type === "url").map((b) => b.url ?? ""),
  ];
  const out = new Set<string>();
  for (const t of texts) {
    for (const v of compileText(t).vars) if (v.startsWith("ask.")) out.add(v.slice(4));
  }
  return [...out];
}

/** The typed-in values, cleaned: lower-case names, one line, at most 200 characters. */
export function cleanAsked(values: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (values && typeof values === "object") {
    for (const [k, v] of Object.entries(values as Record<string, unknown>)) {
      const text = String(v ?? "").replace(/[\n\t]+/g, " ").trim().slice(0, 200);
      if (text) out[k.toLowerCase()] = text;
    }
  }
  return out;
}

/** Names of {ask.x} variables that have no value. */
export function missingAsked(spec: Spec, asked: Record<string, string>): string[] {
  return askNames(spec).filter((n) => !asked[n]);
}

// ---------------------------------------------------------------------------
// Template -> what Meta wants when the template is created
// ---------------------------------------------------------------------------

/** Quick replies first, then link / call / copy-code buttons (Meta wants quick replies together). */
export function orderedButtons(spec: Spec): { btn: Button; specIndex: number }[] {
  const all = (spec.buttons ?? []).map((btn, specIndex) => ({ btn, specIndex }));
  const rank = (t: string) => ({ quick_reply: 0, url: 1, phone: 2, copy_code: 3 }[t] ?? 9);
  return all
    .filter((b) => b.btn.type !== "quick_reply" || (b.btn.text ?? "").trim() !== "")
    .sort((a, b) => rank(a.btn.type) - rank(b.btn.type) || a.specIndex - b.specIndex);
}

/** A link like https://site.com/apply?c={first_name} -> base and the variable at the very end. */
export function splitUrl(url: string): { base: string; variable: string | null } {
  const m = (url ?? "").trim().match(/^(.*?)\{([a-z_][a-z0-9_.]*)\}$/i);
  return m ? { base: m[1], variable: m[2].toLowerCase() } : { base: (url ?? "").trim(), variable: null };
}

export function validateSpec(name: string, spec: Spec): string | null {
  if (!/^[a-z0-9_]+$/.test(name)) return "Template name: only small letters, numbers and _ (like course_details)";
  const body = (spec.body ?? "").trim();
  if (!body) return "Write the message text";
  if (body.length > 1024) return "Message text can be at most 1024 characters";
  const h = spec.header ?? {};
  if (h.type === "text") {
    const t = compileText(h.text ?? "");
    if (!t.text.trim()) return "Write the heading text or choose No heading";
    if (t.text.length > 60) return "Heading can be at most 60 characters";
    if (t.vars.length > 1) return "Heading can have only one {variable}";
  }
  if ((h.type === "image" || h.type === "video" || h.type === "document") && !h.media_path) {
    return `Choose the ${h.type} for the heading`;
  }
  if (h.type === "location" && (h.latitude == null || h.longitude == null)) return "Enter the location";
  if ((spec.footer ?? "").length > 60) return "Footer can be at most 60 characters";
  if (/\{\{?\d+\}?\}/.test(body)) return "Use names like {first_name} in the text, not {{1}}";
  const compiledBody = compileText(body).text.trim();
  if (/^\{\{\d+\}\}/.test(compiledBody) || /\{\{\d+\}\}$/.test(compiledBody)) {
    return "The message cannot start or end with a {variable}: Meta rejects that. Add a few words before and after it";
  }
  const asks = askNames(spec);
  if (asks.length > 5) return "At most 5 variables can be filled in when sending";
  for (const n of asks) {
    if (!/^[a-z][a-z0-9_]{0,23}$/.test(n)) return `Variable name "${n}": use small letters, numbers and _ only`;
    if (!(spec.examples?.[`ask.${n}`] ?? "").trim()) return `Write an example for {ask.${n}} (for Meta), like Semester 3`;
  }
  const btns = orderedButtons(spec);
  if (btns.length > 10) return "At most 10 buttons";
  let urls = 0, phones = 0, copies = 0;
  for (const { btn } of btns) {
    const t = (btn.text ?? "").trim();
    if (btn.type !== "copy_code" && (!t || t.length > 25)) return "Each button needs a name of up to 25 characters";
    if (btn.type === "url") {
      urls++;
      const { base, variable } = splitUrl(btn.url ?? "");
      if (!/^https:\/\//i.test(base)) return "Link buttons must start with https://";
      if (/\{/.test(base)) return "In a link, the {variable} can only be at the very end";
      if (variable === null && /[{}]/.test(btn.url ?? "")) return "Check the link";
    }
    if (btn.type === "phone") {
      phones++;
      if (!/^\+\d{8,15}$/.test((btn.phone ?? "").replace(/[\s-]/g, ""))) return "Call button: number like +919876543210";
    }
    if (btn.type === "copy_code") {
      copies++;
      if (!(btn.example ?? "").trim() || (btn.example ?? "").length > 15) return "Copy-code button: code of up to 15 characters";
    }
  }
  if (urls > 2) return "At most 2 link buttons";
  if (phones > 1) return "At most 1 call button";
  if (copies > 1) return "At most 1 copy-code button";
  return null;
}

/** Components for POST /{waba}/message_templates. */
// deno-lint-ignore no-explicit-any
export function buildComponents(spec: Spec): any[] {
  // deno-lint-ignore no-explicit-any
  const comps: any[] = [];
  const h = spec.header ?? {};
  if (h.type === "text") {
    const c = compileText(h.text ?? "");
    // deno-lint-ignore no-explicit-any
    const comp: any = { type: "HEADER", format: "TEXT", text: c.text };
    if (c.vars.length) comp.example = { header_text: [sampleFor(c.vars[0], spec.examples)] };
    comps.push(comp);
  } else if (h.type === "image" || h.type === "video" || h.type === "document") {
    comps.push({ type: "HEADER", format: h.type.toUpperCase(), example: { header_handle: [h.handle] } });
  } else if (h.type === "location") {
    comps.push({ type: "HEADER", format: "LOCATION" });
  }

  const b = compileText(spec.body ?? "");
  // deno-lint-ignore no-explicit-any
  const body: any = { type: "BODY", text: b.text };
  if (b.vars.length) body.example = { body_text: [b.vars.map((v) => sampleFor(v, spec.examples))] };
  comps.push(body);

  if ((spec.footer ?? "").trim()) comps.push({ type: "FOOTER", text: spec.footer!.trim() });

  const buttons = orderedButtons(spec).map(({ btn }) => {
    switch (btn.type) {
      case "quick_reply":
        return { type: "QUICK_REPLY", text: btn.text!.trim() };
      case "url": {
        const { base, variable } = splitUrl(btn.url!);
        return variable
          ? { type: "URL", text: btn.text!.trim(), url: base + "{{1}}", example: [base + sampleFor(variable, spec.examples)] }
          : { type: "URL", text: btn.text!.trim(), url: base };
      }
      case "phone":
        return { type: "PHONE_NUMBER", text: btn.text!.trim(), phone_number: (btn.phone ?? "").replace(/[\s-]/g, "") };
      default:
        return { type: "COPY_CODE", example: btn.example!.trim() };
    }
  });
  if (buttons.length) comps.push({ type: "BUTTONS", buttons });
  return comps;
}

/** Template made in Meta's own screen -> our spec (so it can be used and its buttons given actions). */
// deno-lint-ignore no-explicit-any
export function specFromComponents(components: any[]): Spec {
  const spec: Spec = { buttons: [] };
  for (const c of components ?? []) {
    if (c.type === "HEADER") {
      const f = String(c.format ?? "").toLowerCase();
      if (f === "text") spec.header = { type: "text", text: unnumber(c.text ?? "", c.example?.header_text?.[0]) };
      else if (["image", "video", "document", "location"].includes(f)) spec.header = { type: f as Header["type"] };
    } else if (c.type === "BODY") {
      spec.body = unnumber(c.text ?? "", ...(c.example?.body_text?.[0] ?? []));
    } else if (c.type === "FOOTER") {
      spec.footer = c.text;
    } else if (c.type === "BUTTONS") {
      for (const b of c.buttons ?? []) {
        if (b.type === "QUICK_REPLY") spec.buttons!.push({ type: "quick_reply", text: b.text });
        else if (b.type === "URL") spec.buttons!.push({ type: "url", text: b.text, url: String(b.url ?? "").replace("{{1}}", "{first_name}") });
        else if (b.type === "PHONE_NUMBER") spec.buttons!.push({ type: "phone", text: b.text, phone: b.phone_number });
        else if (b.type === "COPY_CODE") spec.buttons!.push({ type: "copy_code", example: b.example });
      }
    }
  }
  return spec;
}

// {{1}} typed in Meta's own screen becomes {first_name}; {{2}}, {{3}}... become {extra.var2}...
function unnumber(text: string, ..._samples: unknown[]): string {
  return text.replace(/\{\{(\d+)\}\}/g, (_m, n: string) => (n === "1" ? "{first_name}" : `{extra.var${n}}`));
}

// ---------------------------------------------------------------------------
// Template -> what the Cloud API wants when it is sent
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
export function sendComponents(
  spec: Spec,
  templateId: string,
  lead: Lead,
  agentName: string,
  mediaUrl: string | null,
  asked?: Record<string, string>,
  // deno-lint-ignore no-explicit-any
): any[] {
  // deno-lint-ignore no-explicit-any
  const comps: any[] = [];
  const h = spec.header ?? {};
  if (h.type === "text") {
    const c = compileText(h.text ?? "");
    if (c.vars.length) {
      comps.push({ type: "header", parameters: [{ type: "text", text: resolveVar(c.vars[0], lead, agentName, asked) }] });
    }
  } else if (h.type === "image" || h.type === "video" || h.type === "document") {
    if (!mediaUrl) throw new Error("This template needs its heading file: open it, choose the file and save");
    const media: Record<string, unknown> = { link: mediaUrl };
    if (h.type === "document" && h.filename) media.filename = h.filename;
    comps.push({ type: "header", parameters: [{ type: h.type, [h.type]: media }] });
  } else if (h.type === "location") {
    comps.push({
      type: "header",
      parameters: [{
        type: "location",
        location: { latitude: h.latitude, longitude: h.longitude, name: h.name ?? "", address: h.address ?? "" },
      }],
    });
  }

  const b = compileText(spec.body ?? "");
  if (b.vars.length) {
    comps.push({
      type: "body",
      parameters: b.vars.map((v) => ({ type: "text", text: resolveVar(v, lead, agentName, asked) })),
    });
  }

  orderedButtons(spec).forEach(({ btn, specIndex }, index) => {
    if (btn.type === "quick_reply") {
      comps.push({
        type: "button", sub_type: "quick_reply", index: String(index),
        parameters: [{ type: "payload", payload: `t:${templateId}:${specIndex}` }],
      });
    } else if (btn.type === "url") {
      const { variable } = splitUrl(btn.url ?? "");
      if (variable) {
        comps.push({
          type: "button", sub_type: "url", index: String(index),
          parameters: [{ type: "text", text: encodeURIComponent(resolveVar(variable, lead, agentName, asked)) }],
        });
      }
    } else if (btn.type === "copy_code") {
      comps.push({
        type: "button", sub_type: "copy_code", index: String(index),
        parameters: [{ type: "coupon_code", coupon_code: btn.example }],
      });
    }
  });
  return comps;
}

/** What shows in the chat for a template message. */
export function templatePreview(spec: Spec, lead: Lead, agentName: string, asked?: Record<string, string>): string {
  const parts: string[] = [];
  const h = spec.header ?? {};
  if (h.type === "text" && h.text) parts.push(`*${fillText(h.text, lead, agentName, asked)}*`);
  else if (h.type === "image") parts.push("🖼 Image");
  else if (h.type === "video") parts.push("🎬 Video");
  else if (h.type === "document") parts.push(`📄 ${h.filename ?? "Document"}`);
  else if (h.type === "location") parts.push("📍 Location");
  parts.push(fillText(spec.body ?? "", lead, agentName, asked));
  if (spec.footer) parts.push(spec.footer);
  return parts.join("\n");
}

// ---------------------------------------------------------------------------
// Replies from the student
// ---------------------------------------------------------------------------

/** "t:<template id>:<button>" or "n:<reply id>:b<i>" / "n:<reply id>:r<section>.<row>" */
export type Ref =
  | { kind: "template"; id: string; index: number }
  | { kind: "node_button"; id: string; index: number }
  | { kind: "node_row"; id: string; section: number; row: number };

export function parseRef(s: string | undefined | null): Ref | null {
  if (!s) return null;
  let m = s.match(/^t:([0-9a-f-]{36}):(\d+)$/i);
  if (m) return { kind: "template", id: m[1], index: Number(m[2]) };
  m = s.match(/^n:([0-9a-f-]{36}):b(\d+)$/i);
  if (m) return { kind: "node_button", id: m[1], index: Number(m[2]) };
  m = s.match(/^n:([0-9a-f-]{36}):r(\d+)\.(\d+)$/i);
  if (m) return { kind: "node_row", id: m[1], section: Number(m[2]), row: Number(m[3]) };
  return null;
}

const STOP_WORDS = /^\s*(stop|unsubscribe|cancel|opt\s*-?out|stop\s+messages?|band\s+karo|mat\s+bhejo)\s*[.!]*\s*$/i;
const START_WORDS = /^\s*(start|subscribe|unstop|resume)\s*[.!]*\s*$/i;

export const isStop = (t: string) => STOP_WORDS.test(t ?? "");
export const isStart = (t: string) => START_WORDS.test(t ?? "");

/** Free-form messages are allowed for 24 hours after the student last wrote. */
export function windowOpen(lead: Pick<Lead, "wa_last_inbound_at">, now = Date.now()): boolean {
  return !!lead.wa_last_inbound_at && now - new Date(lead.wa_last_inbound_at).getTime() < 24 * 3600 * 1000;
}

/** Errors that mean "try again in a few minutes". */
export const RETRY_CODES = new Set([4, 17, 32, 613, 130429, 131048, 131056, 80007, 133016]);
/** The number is not on WhatsApp. */
export const NO_WHATSAPP_CODES = new Set([131026, 131030]);

export function friendlyError(code: number | undefined, message: string): string {
  switch (code) {
    case 131026: return "This number is not on WhatsApp";
    case 131047: return "More than 24 hours since the student wrote: only a template can be sent";
    case 131049: return "Meta did not deliver this marketing message (the student has received too many). Try later.";
    case 131042: return "Meta payment problem: check the payment method in WhatsApp Manager";
    case 131048: case 131056: return "Too many messages to this number, will retry";
    case 130429: case 80007: return "WhatsApp sending limit reached, will retry";
    case 132000: case 132005: case 132007: case 132012: case 132015: case 132016: return "Template text did not match: " + message;
    case 132001: return "Template not found or not approved yet";
    case 190: return "Access token expired or wrong: save a new token in More > WhatsApp";
    case 100: return message;
    default: return message;
  }
}

// ---------------------------------------------------------------------------
// Meta's signature on every webhook call
// ---------------------------------------------------------------------------

/** X-Hub-Signature-256 is "sha256=" + HMAC-SHA256(app secret, raw body) in hex. */
export async function validSignature(secret: string, raw: Uint8Array, header: string | null): Promise<boolean> {
  if (!secret || !header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw as BufferSource));
  const hex = Array.from(sig).map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = header.slice(7).toLowerCase();
  if (given.length !== hex.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

const MIME_EXT: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "video/mp4": "mp4", "video/3gpp": "3gp",
  "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/amr": "amr", "audio/aac": "aac", "audio/mp4": "m4a",
  "application/pdf": "pdf",
};
export const extFor = (mime: string | undefined, filename?: string) =>
  (filename?.includes(".") ? filename.split(".").pop() : undefined) ?? MIME_EXT[(mime ?? "").split(";")[0]] ?? "bin";

export function guessMime(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return ({ jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", mp4: "video/mp4", pdf: "application/pdf" } as Record<string, string>)[ext] ??
    "application/octet-stream";
}
