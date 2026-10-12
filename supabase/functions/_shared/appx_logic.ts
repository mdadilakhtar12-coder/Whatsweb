// AIFM Education app (Appx): reading what the Appx CMS webhooks send. No network and no database here, so it
// can be tested alone.
//
// In the Appx CMS (Integrations > Webhooks) each event has its own webhook. The owner types the key names
// himself and picks the field for each key, so the names are read leniently (Name, name, student_name ...)
// and unknown fields are ignored. The kind of event comes from the end of the address
// (.../appx/<secret>/purchase), because the Appx payload does not say which event it is.

// deno-lint-ignore no-explicit-any
type Any = any;

export const KINDS = ["signup", "demo", "contact", "purchase", "cancelled", "refund"] as const;
export type Kind = typeof KINDS[number];

export type Applied = {
  name: string | null;
  phone: string | null;
  email: string | null;
  state: string | null;
  district: string | null;
  item: string | null;
  product_type: string | null;
  amount: number | null;
  txn_id: string | null;
  payment_mode: string | null;
  coupon: string | null;
  invoice: string | null;
  purchased_at: string | null;
  expires_at: string | null;
  status: string | null;
  link: string | null;
  refund_amount: number | null;
  info: Record<string, string>;
};

const norm = (k: string) => k.toLowerCase().replace(/[^a-z0-9]/g, "");

const KIND_NAMES: Record<string, Kind> = {
  signup: "signup", signups: "signup", usersignup: "signup", register: "signup", registration: "signup",
  demo: "demo", demos: "demo", demolead: "demo", demoleads: "demo",
  contact: "contact", contactus: "contact", websitecontact: "contact", websitecontactsubmission: "contact", enquiry: "contact",
  purchase: "purchase", purchased: "purchase", successfulpurchase: "purchase", success: "purchase", sale: "purchase", paid: "purchase",
  cancelled: "cancelled", canceled: "cancelled", cancel: "cancelled", cancelledpayment: "cancelled", canceledpayment: "cancelled",
  failed: "cancelled", paymentfailed: "cancelled",
  refund: "refund", refunded: "refund", paymentrefund: "refund",
};

/** "purchase", "Successful Purchase", "payment-refund" ... -> the kind, or null when it is not one we know. */
export function kindOf(v: unknown): Kind | null {
  return KIND_NAMES[norm(String(v ?? ""))] ?? null;
}

/** The part after the secret: /functions/v1/appx/<secret>/<kind>. */
export function partsFromPath(pathname: string): { secret: string; kind: string } {
  const parts = pathname.split("/").filter(Boolean);
  const i = parts.lastIndexOf("appx");
  return i >= 0 ? { secret: parts[i + 1] ?? "", kind: parts[i + 2] ?? "" } : { secret: "", kind: "" };
}

/**
 * What the webhook sent, as one flat list of text values: JSON ({"Name": "Asha"}, also one level inside "data"),
 * or a form (name=Asha&number=98...), plus whatever is in the address after "?". The body wins over the address.
 */
export function readFields(text: string, query: URLSearchParams): Record<string, string> {
  const out: Record<string, string> = {};
  const put = (k: string, v: unknown) => {
    if (v == null || typeof v === "object") return;
    const s = String(v).trim();
    if (s !== "" && out[k] === undefined) out[k] = s.slice(0, 2000);
  };
  const walk = (o: Any, depth: number) => {
    if (!o || typeof o !== "object" || Array.isArray(o)) return;
    for (const [k, v] of Object.entries(o)) {
      if (v && typeof v === "object" && !Array.isArray(v)) {
        if (depth < 2) walk(v, depth + 1);
      } else put(k, v);
    }
  };
  const trimmed = text.trim();
  let parsed: Any = null;
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      parsed = JSON.parse(trimmed);
    } catch { /* maybe a form */ }
  }
  if (parsed && typeof parsed === "object") {
    walk(Array.isArray(parsed) ? parsed[0] : parsed, 0);
  } else if (trimmed) {
    try {
      for (const [k, v] of new URLSearchParams(trimmed)) put(k, v);
    } catch { /* not a form either */ }
  }
  for (const [k, v] of query) put(k, v);
  return out;
}

function pick(f: Map<string, string>, ...names: string[]): string | null {
  for (const n of names) {
    const v = f.get(n);
    if (v !== undefined && v !== "") return v;
  }
  return null;
}

/** "₹ 4,999.00", "Rs. 499", "499 INR" -> a number; null if there is none. */
export function amount(v: unknown): number | null {
  if (v == null || v === "") return null;
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  const m = String(v).replace(/,/g, "").match(/-?\d+(\.\d+)?/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

export function emailOf(v: unknown): string | null {
  const s = String(v ?? "").trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) ? s : null;
}

/** Digits only (and a leading +): the database makes the final 10-digit key. */
export function phoneOf(v: unknown): string | null {
  const s = String(v ?? "").trim();
  const digits = s.replace(/\D/g, "").replace(/^0+(?=\d{10}$)/, "");
  if (digits.length < 7 || digits.length > 15) return null;
  return (s.startsWith("+") ? "+" : "") + digits;
}

/**
 * A date from the app as an ISO string. Accepts ISO text, "2026-10-08 10:44:00", "08-10-2026 10:44" or
 * "08/10/2026" (day first, as in India), seconds or milliseconds since 1970. A time without a zone is India time.
 */
export function whenOf(v: unknown): string | null {
  if (v == null || v === "") return null;
  const s = String(v).trim();
  if (/^\d{9,16}(\.\d+)?$/.test(s)) {
    const n = Number(s);
    const d = new Date(n > 1e11 ? n : n * 1000);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }
  const ist = (y: number, mo: number, d: number, h = 0, mi = 0, se = 0) => {
    const t = Date.UTC(y, mo - 1, d, h, mi, se) - 330 * 60_000;
    const dt = new Date(t);
    return Number.isNaN(dt.getTime()) || mo < 1 || mo > 12 || d < 1 || d > 31 ? null : dt.toISOString();
  };
  let m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?$/i);
  if (m) {
    let h = Number(m[4] ?? 0);
    if (m[7]) h = (h % 12) + (m[7].toLowerCase() === "pm" ? 12 : 0);
    return ist(Number(m[3]), Number(m[2]), Number(m[1]), h, Number(m[5] ?? 0), Number(m[6] ?? 0));
  }
  m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?$/);
  if (m) return ist(Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4] ?? 0), Number(m[5] ?? 0), Number(m[6] ?? 0));
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** The fields the database function needs, from whatever names the owner gave the keys. */
export function extract(f0: Record<string, string>): Applied {
  const f = new Map<string, string>();
  for (const [k, v] of Object.entries(f0)) if (!f.has(norm(k))) f.set(norm(k), v);

  const info: Record<string, string> = {};
  for (let i = 1; i <= 5; i++) {
    const v = pick(f, `info${i}`);
    if (v) info[`info${i}`] = v;
  }
  return {
    name: pick(f, "name", "studentname", "username", "fullname", "customername"),
    phone: phoneOf(pick(f, "number", "phone", "mobile", "phonenumber", "mobilenumber", "userphone", "studentphone", "contactnumber")),
    email: emailOf(pick(f, "email", "emailid", "useremail", "studentemail", "mail")),
    state: pick(f, "state"),
    district: pick(f, "district", "city"),
    item: pick(f, "itemname", "item", "course", "coursename", "coursetitle", "product", "productname"),
    product_type: pick(f, "producttype"),
    amount: amount(pick(f, "paymentamount", "amount", "price", "total", "totalamount")),
    txn_id: pick(f, "transactionid", "txnid", "transaction", "paymentid", "orderid"),
    payment_mode: pick(f, "paymentmode", "mode"),
    coupon: pick(f, "couponcode", "coupon"),
    invoice: pick(f, "invoicenumber", "invoiceno", "invoice"),
    purchased_at: whenOf(pick(f, "purchasedate", "datetime", "date", "timestamp", "createdat")),
    expires_at: whenOf(pick(f, "expirydate", "expiry", "validtill", "expiresat")),
    status: pick(f, "status"),
    link: pick(f, "purchaselink", "link", "url"),
    // a refund event calls the amount just "Amount": it is read as the refund amount by the caller
    refund_amount: amount(pick(f, "refundamount", "amount", "paymentamount")),
    info,
  };
}

// ---------------------------------------------------------------------------

export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The JSON the database function takes (appx_apply). `amount` of a refund is the refund amount. */
export function forDatabase(kind: Kind, a: Applied): Record<string, unknown> {
  const o: Record<string, unknown> = { ...a };
  if (kind === "refund") {
    o.amount = null;
  } else {
    o.refund_amount = null;
  }
  if (Object.keys(a.info).length === 0) delete o.info;
  return o;
}
