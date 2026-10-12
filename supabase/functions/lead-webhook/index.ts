// Receives leads from:
//  1. Google Ads lead forms (Google's built-in webhook, "Webhook key" = landing key)
//  2. Landing pages / website forms for Meta and Google ads (POST with ?key=LANDING_KEY)
//
// The key in the page is the "landing key" (More > Lead sources). It is public by nature, so it is a
// different key from the server-only WEBHOOK_KEY, and the number of leads per visitor / phone / day is limited.
// Landing page form example:
//   <form method="POST" action="https://<project>.supabase.co/functions/v1/lead-webhook?key=<LANDING_KEY>">
//     <input name="name"> <input name="phone"> <input name="email">
//     <input type="hidden" name="_redirect" value="https://your-site/thank-you">
//   </form>
// Put utm_source=facebook / utm_source=google in the ad's URL and copy it into a hidden
// "utm_source" field so the CRM knows which ad platform the lead came from.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

type Fields = Record<string, string>;

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const type = req.headers.get("content-type") ?? "";
  if (type.includes("application/x-www-form-urlencoded") || type.includes("multipart/form-data")) {
    const form = await req.formData();
    const out: Record<string, unknown> = {};
    for (const [k, v] of form.entries()) {
      if (typeof v === "string") out[k] = v;
    }
    return out;
  }
  const text = await req.text();
  if (!text) return {};
  try {
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return Object.fromEntries(new URLSearchParams(text));
  }
}

// Flatten one level of nesting ({"fields": {"name": "x"}} -> "name": "x").
function flatten(data: Record<string, unknown>): Fields {
  const out: Fields = {};
  for (const [k, v] of Object.entries(data)) {
    if (v == null) continue;
    if (typeof v === "object" && !Array.isArray(v)) {
      for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) {
        if (v2 != null && typeof v2 !== "object") out[k2] = String(v2).trim();
        else if (v2 && typeof v2 === "object" && "value" in (v2 as object)) {
          out[k2] = String((v2 as { value: unknown }).value ?? "").trim();
        }
      }
    } else {
      out[k] = Array.isArray(v) ? v.join(", ") : String(v).trim();
    }
  }
  return out;
}

const norm = (k: string) => k.toLowerCase().replace(/[^a-z]/g, "");

function take(fields: Fields, used: Set<string>, exact: string[], contains: RegExp, exclude?: RegExp) {
  for (const want of exact) {
    for (const k of Object.keys(fields)) {
      if (!used.has(k) && norm(k) === want && fields[k]) {
        used.add(k);
        return fields[k];
      }
    }
  }
  for (const k of Object.keys(fields)) {
    const n = norm(k);
    if (!used.has(k) && contains.test(n) && !(exclude && exclude.test(n)) && fields[k]) {
      used.add(k);
      return fields[k];
    }
  }
  return "";
}

function detectSource(fields: Fields, explicit: string): string {
  const allowed = ["meta_form", "meta_landing", "google_form", "google_landing", "website"];
  if (allowed.includes(explicit)) return explicit;
  const s = (fields.utm_source ?? "").toLowerCase();
  if (/facebook|instagram|meta|^fb|^ig$/.test(s) || fields.fbclid) return "meta_landing";
  if (/google|adwords|youtube|gads/.test(s) || fields.gclid || fields.gbraid || fields.wbraid) {
    return "google_landing";
  }
  return "website";
}

let cachedKey: { value: string; at: number } | null = null;

// deno-lint-ignore no-explicit-any
async function landingKey(supabase: any): Promise<string> {
  if (cachedKey && Date.now() - cachedKey.at < 60_000) return cachedKey.value;
  const { data } = await supabase.from("app_settings").select("value").eq("key", "integrations").maybeSingle();
  const value = String((data?.value as Record<string, unknown> | undefined)?.landing_key ?? "");
  cachedKey = { value, at: Date.now() };
  return value;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const url = new URL(req.url);
  const data = await readBody(req);
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  // The landing key lives in the database (app_settings.integrations.landing_key).
  const expectedKey = await landingKey(supabase);
  if (!expectedKey) return json({ error: "Landing key is not set up yet (run the GitHub build once)" }, 500);
  const visitor = (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for") ?? "")
    .split(",")[0].trim();

  // ---- Google Ads lead form -------------------------------------------------
  if (Array.isArray(data.user_column_data)) {
    if (data.google_key !== expectedKey) return json({ error: "Invalid key" }, 401);

    const byId: Fields = {};
    const extra: Fields = {};
    for (const col of data.user_column_data as Array<Record<string, unknown>>) {
      const id = String(col.column_id ?? "").toUpperCase();
      const value = String(col.string_value ?? "").trim();
      if (["FULL_NAME", "FIRST_NAME", "LAST_NAME", "PHONE_NUMBER", "EMAIL"].includes(id)) {
        byId[id] = value;
      } else {
        extra[String(col.column_name ?? id)] = value;
      }
    }
    const name = byId.FULL_NAME || [byId.FIRST_NAME, byId.LAST_NAME].filter(Boolean).join(" ");
    if (data.gcl_id) extra.gclid = String(data.gcl_id);

    const { data: result, error } = await supabase.rpc("ingest_lead", {
      p_name: name,
      p_phone: byId.PHONE_NUMBER ?? "",
      p_email: byId.EMAIL ?? "",
      p_source: "google_form",
      p_source_detail: data.is_test ? "TEST lead from Google Ads" : `Google campaign ${data.campaign_id ?? ""}`.trim(),
      p_external_id: data.lead_id ? `google_${data.lead_id}` : null,
      p_extra: extra,
    });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, result });
  }

  // ---- Landing page / website form -----------------------------------------
  const fields = flatten(data);
  for (const [k, v] of url.searchParams.entries()) {
    if (!(k in fields)) fields[k] = v;
  }

  const key = req.headers.get("x-webhook-key") ?? fields.key ?? "";
  if (key !== expectedKey) return json({ error: "Invalid key" }, 401);

  const redirect = fields._redirect ?? "";
  const done = (body: unknown) =>
    /^https?:\/\//.test(redirect)
      ? new Response(null, { status: 303, headers: { ...cors, Location: redirect } })
      : json(body);

  // Honeypot field for bots: real visitors never fill it.
  if (fields._gotcha) return done({ ok: true });

  const used = new Set<string>(["key", "_redirect", "_gotcha", "source"]);
  const firstName = take(fields, used, ["firstname", "fname"], /^first/);
  const lastName = take(fields, used, ["lastname", "lname", "surname"], /^last/);
  let name = take(fields, used, ["name", "fullname", "yourname", "studentname"], /name/,
    /utm|form|page|campaign|ad|company|course|city/);
  if (!name) name = [firstName, lastName].filter(Boolean).join(" ");
  const phone = take(fields, used, ["phone", "mobile", "phonenumber", "mobilenumber", "whatsapp", "tel"],
    /phone|mobile|whatsapp|contact|number/);
  const email = take(fields, used, ["email", "emailaddress", "youremail"], /mail/);

  // Limits against fake leads: too many from one visitor or one phone, or too many in a day.
  const gate = await supabase.rpc("landing_allow", { p_ip: visitor, p_phone: phone });
  if (gate.data === "rate" || gate.data === "cap") return done({ ok: true });

  const source = detectSource(fields, fields.source ?? "");
  const detail = fields.utm_campaign || fields.form_name || fields.page || fields.utm_source || "";

  const extra: Fields = {};
  for (const [k, v] of Object.entries(fields)) {
    if (!used.has(k) && v) extra[k] = v;
  }

  const { data: result, error } = await supabase.rpc("ingest_lead", {
    p_name: name,
    p_phone: phone,
    p_email: email,
    p_source: source,
    p_source_detail: detail || null,
    p_external_id: null,
    p_extra: extra,
  });
  if (error) return json({ error: error.message }, 500);
  if (result?.status === "invalid") return json({ error: "Phone or email is required" }, 400);
  return done({ ok: true, result });
});
