// What Claude may build in the WhatsApp part of the CRM: a template (saved as a DRAFT), the automatic replies its
// buttons lead to, and an automatic reminder rule. No network or database here: the caller gives the lists of what
// already exists (replies, statuses, templates), so it can be tested alone.
//
// The owner reads the "lines" made here before he approves; they are made from the checked request, not written by Claude.
import { type Spec, validateSpec } from "./wa_logic.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

export type Lookups = {
  replies: { id: string; name: string }[];
  statuses: string[];
  templates: { name: string; language: string }[];
};

export type Fail = { ok: false; error: string };
export type Built = { ok: true; args: Record<string, unknown>; lines: string[] } | Fail;
const bad = (error: string): Fail => ({ ok: false, error });

export const LANGUAGES = ["en", "en_US", "en_GB", "hi", "mr", "gu", "bn", "ta", "te", "kn", "ml", "pa", "ur"];
const LANGUAGE_NAMES: Record<string, string> = {
  en: "English", en_US: "English (US)", en_GB: "English (UK)", hi: "Hindi", mr: "Marathi", gu: "Gujarati", bn: "Bengali",
  ta: "Tamil", te: "Telugu", kn: "Kannada", ml: "Malayalam", pa: "Punjabi", ur: "Urdu",
};

/** Variables that work in an automatic reply (the details typed in when sending, {ask.x}, do not). */
const REPLY_VARS = /^(first_name|name|phone|email|agent_name|extra\.[a-z0-9_]+)$/i;

function clean(v: unknown, key: string, min: number, max: number, required = false): string | null | Fail {
  if (v === undefined || v === null || v === "") return required ? bad(`"${key}" is needed`) : null;
  if (typeof v !== "string") return bad(`"${key}" must be text`);
  // deno-lint-ignore no-control-regex
  const t = v.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim();
  if (t.length < min || t.length > max) return bad(`"${key}" must be ${min} to ${max} characters (it is ${t.length})`);
  return t;
}

const isBad = (x: unknown): x is Fail => typeof x === "object" && x !== null && "ok" in x && (x as Fail).ok === false;

function checkReplyVars(text: string, where: string): string | null {
  for (const m of text.matchAll(/\{\s*([^{}]*?)\s*\}/g)) {
    if (!REPLY_VARS.test(m[1])) return `${where}: {${m[1]}} cannot be used in an automatic reply (use {first_name}, {name}, {phone}, {email}, {agent_name} or {extra.field})`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Buttons: what happens when a student taps one
// ---------------------------------------------------------------------------

type ActionIn = { reply?: unknown; status?: unknown; temperature?: unknown; lost_reason?: unknown; callback_hours?: unknown; optout?: unknown };

function parseAction(x: ActionIn, where: string, ids: Map<string, string>, lk: Lookups): { action: Record<string, unknown> } | Fail {
  const action: Record<string, unknown> = {};
  if (x.reply !== undefined && x.reply !== null && x.reply !== "") {
    const ref = String(x.reply).trim();
    const id = ids.get(ref.toLowerCase());
    if (!id) return bad(`${where}: the reply "${ref}" does not exist. Give it in "replies" with this key, or use the exact name of an existing reply (see crm_wa_system).`);
    action.next = id;
  }
  if (x.status !== undefined && x.status !== null && x.status !== "") {
    const wanted = String(x.status).trim().toLowerCase();
    const found = lk.statuses.find((s) => s.toLowerCase() === wanted);
    if (!found) return bad(`${where}: there is no status "${x.status}". The statuses are: ${lk.statuses.join(", ")}`);
    action.status = found;
  }
  if (x.temperature !== undefined && x.temperature !== null && x.temperature !== "") {
    const t = String(x.temperature).trim().toLowerCase();
    if (!["hot", "warm", "cold"].includes(t)) return bad(`${where}: temperature must be hot, warm or cold`);
    action.temperature = t;
  }
  if (x.lost_reason !== undefined && x.lost_reason !== null && x.lost_reason !== "") {
    const r = clean(x.lost_reason, "lost_reason", 1, 80);
    if (isBad(r)) return r;
    if (r) action.lost_reason = r;
  }
  if (x.callback_hours !== undefined && x.callback_hours !== null && x.callback_hours !== "") {
    const n = Number(x.callback_hours);
    if (!Number.isInteger(n) || n < 1 || n > 168) return bad(`${where}: callback_hours must be a whole number from 1 to 168`);
    action.callback_hours = n;
  }
  if (x.optout === true) action.optout = true;
  return { action };
}

/** "sends reply "Fees info", tags Hot, status Interested" */
function doesText(action: Record<string, unknown>, names: Map<string, string>): string {
  const parts: string[] = [];
  if (action.next) parts.push(`sends the reply "${names.get(String(action.next)) ?? "?"}"`);
  if (action.status) parts.push(`sets the status to ${action.status}`);
  if (action.temperature) parts.push(`tags the lead ${String(action.temperature)[0].toUpperCase()}${String(action.temperature).slice(1)}`);
  if (action.lost_reason) parts.push(`notes the reason "${action.lost_reason}"`);
  if (action.callback_hours) parts.push(`reminds the agent to call in ${action.callback_hours} h`);
  if (action.optout) parts.push("stops all messages to this student");
  return parts.length ? parts.join(", ") : "does nothing else";
}

// ---------------------------------------------------------------------------
// The flow: template + replies
// ---------------------------------------------------------------------------

export function buildFlow(input: Record<string, unknown>, lk: Lookups, newId: () => string = () => crypto.randomUUID()): Built {
  const tplIn = input.template;
  const repliesIn = input.replies;
  if ((tplIn === undefined || tplIn === null) && (!Array.isArray(repliesIn) || repliesIn.length === 0)) {
    return bad('Give a "template" and / or "replies" to build');
  }
  if (tplIn !== undefined && tplIn !== null && (typeof tplIn !== "object" || Array.isArray(tplIn))) return bad('"template" must be an object');
  if (repliesIn !== undefined && repliesIn !== null && !Array.isArray(repliesIn)) return bad('"replies" must be a list');
  const replyList = (repliesIn ?? []) as Any[];
  if (replyList.length > 12) return bad("At most 12 replies in one request");

  // ---- the ids: every reply made here gets one now, so buttons can point to it
  const ids = new Map<string, string>();
  for (const r of lk.replies) ids.set(r.name.trim().toLowerCase(), r.id);
  const newKeys = new Map<string, string>();
  const newNames = new Set<string>();
  for (const [i, r] of replyList.entries()) {
    if (!r || typeof r !== "object") return bad(`Reply ${i + 1} must be an object`);
    const key = String(r.key ?? "").trim().toLowerCase();
    if (!/^[a-z0-9_]{1,30}$/.test(key)) return bad(`Reply ${i + 1}: "key" is needed (small letters, numbers, _ ; for example fees)`);
    if (newKeys.has(key)) return bad(`Two replies have the key "${key}"`);
    const name = clean(r.name ?? key, "name", 1, 60);
    if (isBad(name) || !name) return isBad(name) ? name : bad(`Reply "${key}" needs a name`);
    if (lk.replies.some((x) => x.name.trim().toLowerCase() === name.toLowerCase()) || newNames.has(name.toLowerCase())) {
      return bad(`A reply called "${name}" already exists. Choose another name (or point to the old one by its exact name).`);
    }
    newNames.add(name.toLowerCase());
    newKeys.set(key, newId());
  }
  // a button may point to a reply of this request by its key, or to an old reply by its exact name
  for (const [key, id] of newKeys) ids.set(key, id);

  const replies: Record<string, unknown>[] = [];
  const names = new Map<string, string>();
  for (const r of lk.replies) names.set(r.id, r.name);

  for (const r of replyList) {
    const key = String(r.key).trim().toLowerCase();
    const id = newKeys.get(key)!;
    const name = clean(r.name ?? key, "name", 1, 60) as string;
    names.set(id, name);
    const where = `Reply "${name}"`;
    const kind = String(r.kind ?? "text");
    if (!["text", "buttons", "list"].includes(kind)) return bad(`${where}: kind must be text, buttons or list`);
    const body = clean(r.body, "body", 1, 1024, true);
    if (isBad(body)) return bad(`${where}: ${body.error}`);
    const header = clean(r.header, "header", 1, 60);
    const footer = clean(r.footer, "footer", 1, 60);
    if (isBad(header)) return bad(`${where}: ${header.error}`);
    if (isBad(footer)) return bad(`${where}: ${footer.error}`);
    for (const [label, t] of [["body", body], ["header", header], ["footer", footer]] as const) {
      const e = t ? checkReplyVars(t as string, `${where} ${label}`) : null;
      if (e) return bad(e);
    }
    const node: Record<string, unknown> = { id, name, kind, header, body, footer, buttons: [], list_button: null, sections: [] };

    if (kind === "text") {
      if (r.buttons || r.sections) return bad(`${where}: a "text" reply has no buttons. Use kind "buttons" (up to 3) or "list".`);
    } else if (kind === "buttons") {
      if (!Array.isArray(r.buttons) || r.buttons.length < 1 || r.buttons.length > 3) return bad(`${where}: a "buttons" reply needs 1 to 3 buttons`);
      const buttons: Record<string, unknown>[] = [];
      for (const [i, b] of (r.buttons as Any[]).entries()) {
        const title = clean(b?.title, "title", 1, 20, true);
        if (isBad(title)) return bad(`${where}, button ${i + 1}: ${title.error} (button names are 20 characters at most)`);
        const a = parseAction(b ?? {}, `${where}, button "${title}"`, ids, lk);
        if ("ok" in a) return a;
        buttons.push({ title, action: a.action });
      }
      node.buttons = buttons;
    } else {
      const lb = clean(r.list_button ?? "Choose", "list_button", 1, 20);
      if (isBad(lb) || !lb) return isBad(lb) ? bad(`${where}: ${lb.error}`) : bad(`${where}: list_button is needed`);
      node.list_button = lb;
      if (!Array.isArray(r.sections) || r.sections.length < 1 || r.sections.length > 10) return bad(`${where}: a "list" reply needs 1 to 10 sections`);
      let rows = 0;
      const sections: Record<string, unknown>[] = [];
      for (const [si, s] of (r.sections as Any[]).entries()) {
        const title = clean(s?.title ?? "Options", "section title", 1, 24);
        if (isBad(title) || !title) return bad(`${where}: section ${si + 1} needs a title of up to 24 characters`);
        if (!Array.isArray(s?.rows) || s.rows.length < 1) return bad(`${where}: section "${title}" needs rows`);
        const out: Record<string, unknown>[] = [];
        for (const [ri, row] of (s.rows as Any[]).entries()) {
          rows++;
          const rt = clean(row?.title, "row title", 1, 24, true);
          if (isBad(rt)) return bad(`${where}, section "${title}", row ${ri + 1}: ${rt.error} (24 characters at most)`);
          const desc = clean(row?.description, "description", 1, 72);
          if (isBad(desc)) return bad(`${where}, row "${rt}": ${desc.error}`);
          const a = parseAction(row ?? {}, `${where}, row "${rt}"`, ids, lk);
          if ("ok" in a) return a;
          out.push({ title: rt, description: desc, action: a.action });
        }
        sections.push({ title, rows: out });
      }
      if (rows > 10) return bad(`${where}: a list has at most 10 rows in all (this one has ${rows})`);
      node.sections = sections;
    }
    replies.push(node);
  }

  // ---- the template
  let template: Record<string, unknown> | null = null;
  const lines: string[] = [];
  if (tplIn) {
    const t = tplIn as Any;
    const name = String(t.name ?? "").trim();
    if (!/^[a-z0-9_]{1,60}$/.test(name)) return bad('Template "name": small letters, numbers and _ only, up to 60 characters (like bsc_maths_sem1_reminder)');
    const language = String(t.language ?? "en").trim();
    if (!LANGUAGES.includes(language)) return bad(`Template "language" must be one of: ${LANGUAGES.join(", ")}`);
    const category = String(t.category ?? "MARKETING").trim().toUpperCase();
    if (!["MARKETING", "UTILITY"].includes(category)) return bad('Template "category" must be MARKETING or UTILITY');
    if (lk.templates.some((x) => x.name === name && x.language === language)) {
      return bad(`A template called "${name}" already exists in this language. Choose another name.`);
    }
    const body = clean(t.body, "body", 1, 1024, true);
    if (isBad(body)) return bad(`Template: ${body.error}`);
    const headerText = clean(t.header, "header", 1, 60);
    const footer = clean(t.footer, "footer", 1, 60);
    if (isBad(headerText)) return bad(`Template: ${headerText.error}`);
    if (isBad(footer)) return bad(`Template: ${footer.error}`);

    const buttons: Record<string, unknown>[] = [];
    if (t.buttons !== undefined && t.buttons !== null && !Array.isArray(t.buttons)) return bad('Template "buttons" must be a list');
    for (const [i, b] of ((t.buttons ?? []) as Any[]).entries()) {
      const type = String(b?.type ?? "quick_reply");
      const where = `Template button ${i + 1}`;
      if (!["quick_reply", "url", "phone", "copy_code"].includes(type)) return bad(`${where}: type must be quick_reply, url, phone or copy_code`);
      if (type === "copy_code") {
        const ex = clean(b.example ?? b.code, "code", 1, 15, true);
        if (isBad(ex)) return bad(`${where}: ${ex.error}`);
        buttons.push({ type, example: ex });
        continue;
      }
      const text = clean(b?.text, "text", 1, 25, true);
      if (isBad(text)) return bad(`${where}: ${text.error} (button names are 25 characters at most)`);
      if (type === "url") {
        const url = clean(b.url, "url", 1, 2000, true);
        if (isBad(url)) return bad(`${where}: ${url.error}`);
        buttons.push({ type, text, url });
      } else if (type === "phone") {
        const phone = clean(b.phone, "phone", 1, 20, true);
        if (isBad(phone)) return bad(`${where}: ${phone.error}`);
        buttons.push({ type, text, phone });
      } else {
        const a = parseAction(b, `${where} "${text}"`, ids, lk);
        if ("ok" in a) return a;
        buttons.push({ type, text, action: a.action });
      }
    }

    const examples: Record<string, string> = {};
    if (t.examples !== undefined && t.examples !== null) {
      if (typeof t.examples !== "object" || Array.isArray(t.examples)) return bad('Template "examples" must be like {"ask.semester": "Semester 3"}');
      for (const [k, v] of Object.entries(t.examples as Record<string, unknown>)) {
        const val = clean(typeof v === "string" || typeof v === "number" ? String(v) : "", k, 1, 100);
        if (isBad(val) || !val) return bad(`Example for "${k}" must be 1 to 100 characters`);
        examples[k.trim().toLowerCase()] = val;
      }
    }

    const spec: Spec = {
      header: headerText ? { type: "text", text: headerText } : { type: "none" },
      body: body as string,
      footer: (footer as string | null) ?? "",
      buttons: buttons as Any,
      examples,
    };
    const problem = validateSpec(name, spec);
    if (problem) return bad(`Template: ${problem}`);
    // keep only the examples that belong to a variable the text really uses
    const used = new Set<string>();
    for (const txt of [spec.header?.text ?? "", spec.body ?? "", ...buttons.map((b) => String(b.url ?? ""))]) {
      for (const m of txt.matchAll(/\{\s*([a-z_][a-z0-9_.]*)\s*\}/gi)) used.add(m[1].toLowerCase());
    }
    spec.examples = Object.fromEntries(Object.entries(examples).filter(([k]) => used.has(k)));

    template = { name, language, category, spec };

    lines.push(`Template "${name}" · ${category === "UTILITY" ? "Utility" : "Marketing"} · ${LANGUAGE_NAMES[language] ?? language} · saved as a DRAFT`);
    if (headerText) lines.push(`Heading: ${headerText}`);
    lines.push(`Message: ${spec.body}`);
    if (footer) lines.push(`Footer: ${footer}`);
    for (const b of buttons) {
      if (b.type === "quick_reply") lines.push(`Button "${b.text}": when tapped it ${doesText((b.action ?? {}) as Record<string, unknown>, names)}`);
      else if (b.type === "url") lines.push(`Button "${b.text}": opens ${b.url}`);
      else if (b.type === "phone") lines.push(`Button "${b.text}": calls ${b.phone}`);
      else lines.push(`Button "Copy code": copies ${b.example}`);
    }
  }
  if (replies.length) {
    lines.push(`${replies.length} automatic repl${replies.length === 1 ? "y" : "ies"} (sent only when a student taps a button; no Meta approval needed):`);
    for (const n of replies) {
      const kind = n.kind === "text" ? "message" : n.kind === "buttons" ? "message with buttons" : "list";
      lines.push(`"${n.name}" (${kind}): ${String(n.body).slice(0, 160)}${String(n.body).length > 160 ? "…" : ""}`);
      for (const b of (n.buttons as Any[])) lines.push(`    – "${b.title}": ${doesText(b.action, names)}`);
      for (const s of (n.sections as Any[])) for (const row of s.rows) lines.push(`    – "${row.title}": ${doesText(row.action, names)}`);
    }
  }
  return { ok: true, args: { template, replies }, lines };
}

// ---------------------------------------------------------------------------
// The automatic reminder rule
// ---------------------------------------------------------------------------

export const ONLY_IF = ["not_paid", "no_reply", "not_paid_no_reply", "always"];

export function buildRule(input: Record<string, unknown>): Built {
  const name = clean(input.name, "name", 1, 60, true);
  if (isBad(name)) return name;
  const landing = clean(input.landing, "landing", 0, 80);
  if (isBad(landing)) return landing;
  const source = clean(input.source, "source", 1, 40);
  if (isBad(source)) return source;
  const template = clean(input.template, "template", 1, 80, true);
  if (isBad(template)) return template;
  const after = Number(input.after_minutes);
  if (!Number.isInteger(after) || after < 5 || after > 4320) return bad('"after_minutes" must be a whole number from 5 to 4320 (3 days)');
  const only = String(input.only_if ?? "not_paid").trim().toLowerCase();
  if (!ONLY_IF.includes(only)) return bad(`"only_if" must be one of: ${ONLY_IF.join(", ")}`);
  const start = input.start_hour === undefined ? 9 : Number(input.start_hour);
  const end = input.end_hour === undefined ? 21 : Number(input.end_hour);
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || start > 23 || end < 1 || end > 24 || end <= start) {
    return bad('"start_hour" (0-23) and "end_hour" (1-24) must be whole numbers, the end after the start');
  }
  return {
    ok: true,
    args: { name, landing: landing ?? "", source, after_minutes: after, only_if: only, template, start_hour: start, end_hour: end },
    lines: [],
  };
}

// ---------------------------------------------------------------------------
// What Claude is told about the system (crm_wa_guide)
// ---------------------------------------------------------------------------

export const WA_GUIDE = {
  summary:
    "WhatsApp in this CRM runs on the owner's own WhatsApp Cloud API number. The CRM sends TEMPLATES (approved by Meta) to start a chat, " +
    "and free AUTOMATIC REPLIES when a student taps a button. You can design all of it here; the owner approves each request in the CRM app.",
  templates: {
    why: "A first message, or any message more than 24 hours after the student last wrote, must be a template that Meta has approved. Approval takes minutes to hours and Meta can reject.",
    category: {
      MARKETING: "Offers, promotion, reminders to buy or register. Costs about Rs 0.9 a message.",
      UTILITY: "Information about something the student asked for or did (confirmation, schedule, receipt). About Rs 0.15. Do not call a promotion Utility: Meta changes the category and may reject it.",
    },
    fields: {
      name: "small letters, digits and _ only, for example bsc_maths_sem1_reminder",
      language: LANGUAGES,
      header: "optional text heading, up to 60 characters, at most one variable. Picture, video, PDF and location headings need a file: the owner adds those himself in the template editor.",
      body: "1 to 1024 characters. It must NOT start or end with a {variable}: put words before and after it.",
      footer: "optional, up to 60 characters",
      buttons: [
        "quick_reply: text up to 25 characters. When tapped, the CRM can run an action (below). Up to 10.",
        "url: text + https link (a {variable} may only be at the very end). Up to 2.",
        "phone: text + number like +919876543210. Only 1.",
        "copy_code: a code up to 15 characters the student can copy. Only 1.",
      ],
    },
    variables: {
      "{first_name} {name} {phone} {email} {agent_name}": "filled from the lead for every student",
      "{extra.city}": "a field of the landing-page form (the field name after extra.)",
      "{ask.semester}": "typed by the person who sends it, each time. Needs an example text for Meta. NOT possible in automatic messages.",
    },
    examples: 'Give "examples" like {"ask.semester": "Semester 3", "extra.city": "Patna"} for variables that need an example.',
  },
  button_actions: {
    note: "Each quick-reply button of a template, and each button or row of an automatic reply, can do any of these when the student taps it.",
    reply: "send an automatic reply (by its key in this request, or the exact name of an existing reply)",
    status: "set the lead's status (use the exact names from crm_info)",
    temperature: "tag the lead hot, warm or cold",
    lost_reason: "write a reason (for example Fees too high)",
    callback_hours: "remind the agent to call back in N hours (1 to 168)",
    optout: "stop all messages to this student",
  },
  automatic_replies: {
    note: "Free text sent right after a tap (the student just wrote, so the 24-hour window is open). No Meta approval. Replies can lead to other replies, so a whole conversation can be built.",
    text: "kind 'text': just a message (up to 1024 characters)",
    buttons: "kind 'buttons': a message with 1 to 3 buttons, each name up to 20 characters",
    list: "kind 'list': a message and a button (up to 20 characters) that opens a list: up to 10 sections, 10 rows in all, row title up to 24 characters, description up to 72",
    variables: "{first_name}, {name}, {phone}, {email}, {agent_name}, {extra.field}. Not {ask.x}.",
  },
  automatic_reminder_rule: {
    what: "'N minutes after a lead from landing page X arrives, if he has not paid, send template T.'",
    fields: {
      landing: "part of the landing page / campaign name of the lead (see landing_pages_and_campaigns in crm_wa_system); empty = every new lead",
      after_minutes: "5 to 4320",
      only_if: {
        not_paid: "the student has not paid the webinar fee (Webinar.gg) yet",
        no_reply: "the student has not written to the owner on WhatsApp",
        not_paid_no_reply: "both",
        always: "no condition",
      },
      template: "the name of an existing template (it must be APPROVED by Meta before the rule can be switched on)",
      start_hour_end_hour: "sending hours in India time (default 9 to 21). A lead who arrives at night is reminded in the morning, up to 3 days later.",
    },
    safety: "The rule is saved PAUSED. The owner switches it on in More > WhatsApp > Automatic reminders after Meta approves the template. It only reaches leads that arrive after it is switched on. Each lead gets it once. Closed leads and students who asked to stop are skipped.",
    note: "A paid student needs no message: the owner decides that later. The 'paid' fact comes from Webinar.gg, matched by e-mail.",
  },
  not_possible_here: [
    "sending the template to Meta (the owner does it: More > WhatsApp > Templates > open it > Save & send to Meta)",
    "pictures, videos, PDFs and locations in headings",
    "switching the welcome message or follow-ups on or off, changing existing templates or replies, deleting anything",
  ],
  how_to_work: [
    "1. Read crm_wa_system (what exists now) and this guide.",
    "2. Ask the owner about the situation: which landing page or campaign, what the goal is, language and tone, which buttons, what each button should lead to, which status or hot/warm/cold tag it sets.",
    "3. Do not invent facts (fees, dates, links, offers): use only what the owner told you.",
    "4. Write the WHOLE plan in the chat: the template text, every button, every reply, and the rule's timing and condition. Change it until the owner says it is right.",
    "5. Only then call crm_whatsapp_build (template + replies in ONE request). Tell the owner to approve it in the CRM app, then to open the draft template and send it to Meta himself.",
    "6. When the owner says Meta approved the template, call crm_whatsapp_rule. He switches it on in the app.",
  ],
};
