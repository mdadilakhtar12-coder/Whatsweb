// Webinar.gg: reading what it sends. No network and no database here, so it can be tested alone.
//
// The shape of the webhook ({ event, timestamp, data }) and of the invite list (firstName, lastName, email,
// attended) follows what the Webinar.gg docs describe. Field names are read leniently (registrationId,
// registration_id, registration.id ...) and unknown fields are ignored, so a small change on their side
// does not break the connection.

// deno-lint-ignore no-explicit-any
type Any = any;

export type Applied = {
  registration_id: string | null;
  webinar_id: string | null;
  webinar_title: string | null;
  email: string | null;
  name: string | null;
  status: string | null;
  payment_status: string | null;
  registered_at: string | null;
  payment_id: string | null;
  order_id: string | null;
  ticket_amount: number | null;
  processing_fee: number | null;
  total_charged: number | null;
  currency: string | null;
  refunded_amount: number | null;
  refund_status: string | null;
};

export type WgEvent = { event: string; ts: string | null; data: Record<string, unknown> };

/** The events that change something. Everything else (webinar.started ...) is only written to the log. */
export const HANDLED = [
  "registration.created",
  "registration.payment.completed",
  "registration.payment.failed",
  "registration.refunded",
  "registration.status.changed",
];

const norm = (k: string) => k.toLowerCase().replace(/[^a-z0-9]/g, "");

/** A time as an ISO string. Accepts ISO text, seconds or milliseconds since 1970. */
export function toIso(v: unknown): string | null {
  if (v == null || v === "") return null;
  let d: Date;
  if (typeof v === "number" || (typeof v === "string" && /^\d{9,16}(\.\d+)?$/.test(v.trim()))) {
    const n = Number(v);
    d = new Date(n > 1e11 ? n : n * 1000);
  } else {
    d = new Date(String(v));
  }
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** {event, timestamp, data}; null when it is not an object at all. */
export function parseEvent(raw: unknown): WgEvent | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const event = String(o.event ?? o.type ?? o.eventType ?? "").trim().toLowerCase();
  const data = o.data && typeof o.data === "object" && !Array.isArray(o.data) ? (o.data as Record<string, unknown>) : {};
  return { event, ts: toIso(o.timestamp ?? o.createdAt ?? o.time), data };
}

// Nested objects that describe the person: their fields are also known by the bare name (user.email -> email).
const PERSON = ["user", "attendee", "registrant", "customer", "student", "person", "contact", "invite", "registration", "profile"];

/**
 * Every simple value in the object (up to two levels down), keyed by its name without punctuation.
 * A value inside an object is known as "<object><name>" (registration.id -> registrationid), and, for the
 * objects that describe the person, also by its bare name. The top level wins.
 */
export function flat(data: unknown): Map<string, unknown> {
  const out = new Map<string, unknown>();
  const walk = (o: Any, parent: string, depth: number) => {
    if (!o || typeof o !== "object" || Array.isArray(o)) return;
    for (const [k, v] of Object.entries(o)) {
      const key = norm(k);
      if (v != null && typeof v === "object" && !Array.isArray(v)) {
        // an amount sent as {amount: 149, currency: "INR"}
        const inner = v as Record<string, unknown>;
        const val = inner.amount ?? inner.value ?? inner.total;
        if (val != null && typeof val !== "object" && (depth === 0 || !out.has(key))) out.set(key, val);
        if (depth < 2) walk(v, key, depth + 1);
      } else if (v != null && !Array.isArray(v)) {
        if (depth === 0) {
          out.set(key, v);
        } else {
          if (!out.has(parent + key)) out.set(parent + key, v);
          if (PERSON.includes(parent) && !out.has(key)) out.set(key, v);
        }
      }
    }
  };
  walk(data, "", 0);
  return out;
}

function pick(f: Map<string, unknown>, ...names: string[]): unknown {
  for (const n of names) {
    const v = f.get(norm(n));
    if (v != null && String(v).trim() !== "") return v;
  }
  return null;
}

function text(v: unknown): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s : null;
}

/** 149, "149", "₹1,499.50" -> number. */
export function amount(v: unknown): number | null {
  if (v == null || v === "") return null;
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  const n = Number(String(v).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(n) && /\d/.test(String(v)) ? n : null;
}

export function emailOf(v: unknown): string | null {
  const s = text(v)?.toLowerCase() ?? null;
  return s && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) ? s : null;
}

/** What the database function expects, whatever the names Webinar.gg used. */
export function extract(event: string, data: Record<string, unknown>): Applied {
  const f = flat(data);
  const first = text(pick(f, "firstName", "first_name"));
  const last = text(pick(f, "lastName", "last_name"));
  const joined = [first, last].filter(Boolean).join(" ").trim();
  const isReg = event === "registration.created" || event === "registration.status.changed";

  // a bare "id" is the registration only in the registration events
  const registrationId = text(pick(f, "registrationId", "registration_id", "registrationid", "inviteId")) ??
    (isReg ? text(pick(f, "id")) : null);
  const paymentId = text(pick(f, "paymentId", "payment_id", "razorpayPaymentId", "transactionId"));

  return {
    registration_id: registrationId,
    webinar_id: text(pick(f, "webinarId", "webinar_id", "webinarid", "webinarSlug")),
    webinar_title: text(pick(f, "webinarTitle", "webinar_title", "webinarName", "title")),
    email: emailOf(pick(f, "email", "attendeeEmail", "userEmail", "registrantEmail")),
    name: text(pick(f, "name", "fullName", "attendeeName", "userName")) ?? (joined || null),
    status: text(pick(f, "newStatus", "status", "registrationStatus"))?.toLowerCase() ?? null,
    payment_status: text(pick(f, "paymentStatus", "payment_status"))?.toLowerCase() ?? null,
    registered_at: toIso(pick(f, "registeredAt", "registered_at", "createdAt")),
    payment_id: paymentId,
    order_id: text(pick(f, "orderId", "order_id", "paymentOrderId", "razorpayOrderId")),
    ticket_amount: amount(pick(f, "ticketAmount", "ticket_amount", "ticketPrice", "paymentAmount", "amount")),
    processing_fee: amount(pick(f, "processingFee", "processing_fee", "fee")),
    total_charged: amount(pick(f, "totalCharged", "total_charged", "totalAmount", "total")),
    currency: text(pick(f, "currency"))?.toUpperCase() ?? null,
    refunded_amount: amount(pick(f, "refundedAmount", "refunded_amount", "refundAmount", "amountRefunded")),
    refund_status: text(pick(f, "refundStatus", "refund_status")),
  };
}

// ---------------------------------------------------------------------------
// The invite list of a webinar (attendance)
// ---------------------------------------------------------------------------

export type Invite = { email: string; name: string | null; attended: boolean | null };

function asBool(v: unknown): boolean | null {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v === 1 ? true : v === 0 ? false : null;
  if (typeof v === "string") {
    const s = v.trim().toLowerCase();
    if (["true", "yes", "1", "attended"].includes(s)) return true;
    if (["false", "no", "0"].includes(s)) return false;
  }
  return null;
}

function findList(body: Any, depth = 0): Any[] | null {
  if (Array.isArray(body)) return body;
  if (!body || typeof body !== "object" || depth > 3) return null;
  for (const k of ["data", "invites", "items", "results", "rows", "registrations", "content", "docs"]) {
    if (k in body) {
      const found = findList(body[k], depth + 1);
      if (found) return found;
    }
  }
  for (const v of Object.values(body)) {
    if (Array.isArray(v) && v.length > 0 && typeof v[0] === "object") return v;
  }
  return null;
}

/** The first value under one of these names, looking into nested objects (not into lists). */
function deepFind(o: Any, names: string[], depth: number): unknown {
  if (!o || typeof o !== "object" || Array.isArray(o) || depth < 0) return null;
  const want = names.map(norm);
  for (const [k, v] of Object.entries(o)) {
    if (want.includes(norm(k)) && v != null && typeof v !== "object") return v;
  }
  for (const v of Object.values(o)) {
    const found = deepFind(v, names, depth - 1);
    if (found != null) return found;
  }
  return null;
}

/** One page of invites: the people, and (when the answer says so) how many pages there are. */
export function parseInvites(body: unknown): { items: Invite[]; totalPages: number | null; raw: number } {
  const list = findList(body) ?? [];
  const items: Invite[] = [];
  for (const row of list) {
    if (!row || typeof row !== "object") continue;
    const f = flat(row);
    const email = emailOf(pick(f, "email", "attendeeEmail", "userEmail"));
    if (!email) continue;
    const first = text(pick(f, "firstName", "first_name"));
    const last = text(pick(f, "lastName", "last_name"));
    const name = [first, last].filter(Boolean).join(" ").trim() || text(pick(f, "name", "fullName"));
    items.push({ email, name, attended: asBool(pick(f, "attended", "hasAttended", "didAttend")) });
  }
  const pages = amount(deepFind(body, ["totalPages", "pageCount", "pages", "lastPage"], 3));
  return { items, totalPages: pages != null && pages >= 1 ? Math.floor(pages) : null, raw: list.length };
}

/** After reading page `page` (0, 1, 2 ...), is there another one? */
export function hasMorePages(page: number, raw: number, limit: number, totalPages: number | null): boolean {
  if (raw === 0) return false;
  if (totalPages != null) return page + 1 < totalPages;
  return raw >= limit;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** Compare two secrets without stopping at the first difference. */
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The secret part of …/functions/v1/webinar-gg/<token>. */
export function tokenFromPath(pathname: string): string {
  const parts = pathname.split("/").filter(Boolean);
  const i = parts.lastIndexOf("webinar-gg");
  return i >= 0 ? (parts[i + 1] ?? "") : "";
}
