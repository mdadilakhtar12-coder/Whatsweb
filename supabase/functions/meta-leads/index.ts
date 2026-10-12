// Meta (Facebook / Instagram) Instant Form leads.
//
//   GET  ?hub.mode=subscribe...          -> Meta webhook verification (META_VERIFY_TOKEN)
//   POST (from Meta, "leadgen" webhook)  -> fetch the lead from Graph API and save it
//   GET/POST ?action=sync&key=WEBHOOK_KEY[&hours=48]
//                                        -> pull recent leads from every form of the page
//                                           (backup for missed webhooks; run it on a schedule)
//
// Secrets: META_PAGE_ID, META_PAGE_TOKEN, META_VERIFY_TOKEN, META_APP_SECRET (optional but
// recommended), WEBHOOK_KEY, META_GRAPH_VERSION (optional, default v23.0).
import { createClient } from "npm:@supabase/supabase-js@2";

type MetaLead = {
  id: string;
  created_time?: string;
  form_id?: string;
  campaign_name?: string;
  ad_name?: string;
  platform?: string;
  field_data?: Array<{ name: string; values?: string[] }>;
};

const graphVersion = Deno.env.get("META_GRAPH_VERSION") ?? "v23.0";
const graph = `https://graph.facebook.com/${graphVersion}`;
const pageToken = Deno.env.get("META_PAGE_TOKEN") ?? "";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function graphGet(pathOrUrl: string): Promise<Record<string, unknown>> {
  const url = pathOrUrl.startsWith("https://")
    ? pathOrUrl
    : `${graph}/${pathOrUrl}${pathOrUrl.includes("?") ? "&" : "?"}access_token=${encodeURIComponent(pageToken)}`;
  const res = await fetch(url);
  const body = await res.json();
  if (!res.ok || body.error) {
    throw new Error(body.error?.message ?? `Graph API error ${res.status}`);
  }
  return body;
}

const leadFields = "id,created_time,field_data,form_id,campaign_name,ad_name,platform";
const basicLeadFields = "id,created_time,field_data,form_id";

async function fetchLead(leadId: string): Promise<MetaLead> {
  try {
    return await graphGet(`${leadId}?fields=${leadFields}`) as MetaLead;
  } catch {
    // campaign/ad names need extra permissions; fall back to the basics
    return await graphGet(`${leadId}?fields=${basicLeadFields}`) as MetaLead;
  }
}

async function saveLead(lead: MetaLead, formName?: string): Promise<string> {
  const fields: Record<string, string> = {};
  for (const f of lead.field_data ?? []) {
    fields[f.name] = (f.values ?? []).join(", ").trim();
  }
  const pick = (...names: string[]) => {
    for (const n of names) {
      if (fields[n]) {
        const v = fields[n];
        delete fields[n];
        return v;
      }
    }
    return "";
  };

  const firstName = pick("first_name");
  const lastName = pick("last_name");
  const name = pick("full_name", "name") || [firstName, lastName].filter(Boolean).join(" ");
  const phone = pick("phone_number", "phone", "mobile_number", "whatsapp_number");
  const email = pick("email", "work_email");

  const extra: Record<string, string> = { ...fields };
  if (lead.platform) extra.platform = lead.platform;
  if (lead.form_id) extra.form_id = lead.form_id;
  if (lead.created_time) extra.submitted_at = lead.created_time;
  if (lead.ad_name) extra.ad_name = lead.ad_name;

  const { data, error } = await supabase.rpc("ingest_lead", {
    p_name: name,
    p_phone: phone,
    p_email: email,
    p_source: "meta_form",
    p_source_detail: lead.campaign_name || formName || (lead.form_id ? `Form ${lead.form_id}` : null),
    p_external_id: `meta_${lead.id}`,
    p_extra: extra,
  });
  if (error) throw new Error(error.message);
  return data?.status ?? "unknown";
}

async function verifySignature(raw: string, header: string | null): Promise<boolean> {
  const secret = Deno.env.get("META_APP_SECRET");
  if (!secret) return true;
  if (!header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const hex = Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
  return hex === header.slice("sha256=".length);
}

async function sync(hours: number) {
  const pageId = Deno.env.get("META_PAGE_ID");
  if (!pageId || !pageToken) throw new Error("META_PAGE_ID / META_PAGE_TOKEN secrets are not set");

  const since = Math.floor(Date.now() / 1000) - hours * 3600;
  const filter = encodeURIComponent(
    JSON.stringify([{ field: "time_created", operator: "GREATER_THAN", value: since }]),
  );
  const counts: Record<string, number> = {};
  let forms = 0;

  let next: string | undefined = `${pageId}/leadgen_forms?fields=id,name&limit=100`;
  while (next) {
    const page = await graphGet(next);
    for (const form of (page.data as Array<{ id: string; name?: string }>) ?? []) {
      forms++;
      let leadsNext: string | undefined =
        `${form.id}/leads?fields=${basicLeadFields}&filtering=${filter}&limit=100`;
      while (leadsNext) {
        const leadsPage = await graphGet(leadsNext);
        for (const lead of (leadsPage.data as MetaLead[]) ?? []) {
          const status = await saveLead(lead, form.name);
          counts[status] = (counts[status] ?? 0) + 1;
        }
        leadsNext = (leadsPage.paging as { next?: string } | undefined)?.next;
      }
    }
    next = (page.paging as { next?: string } | undefined)?.next;
  }
  return { forms, ...counts };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Scheduled / manual sync
  if (url.searchParams.get("action") === "sync") {
    if (url.searchParams.get("key") !== Deno.env.get("WEBHOOK_KEY")) {
      return json({ error: "Invalid key" }, 401);
    }
    try {
      const hours = Number(url.searchParams.get("hours") ?? "48") || 48;
      return json({ ok: true, ...(await sync(hours)) });
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  }

  // Webhook verification handshake
  if (req.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe" &&
      url.searchParams.get("hub.verify_token") === Deno.env.get("META_VERIFY_TOKEN");
    return ok
      ? new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 })
      : new Response("Forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = await req.text();
  if (!(await verifySignature(raw, req.headers.get("x-hub-signature-256")))) {
    return new Response("Bad signature", { status: 401 });
  }

  let payload: { entry?: Array<{ changes?: Array<{ field?: string; value?: { leadgen_id?: string } }> }> };
  try {
    payload = JSON.parse(raw);
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  const results: string[] = [];
  for (const entry of payload.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const leadId = change.value?.leadgen_id;
      if (change.field !== "leadgen" || !leadId) continue;
      try {
        results.push(await saveLead(await fetchLead(leadId)));
      } catch (e) {
        // Logged in Supabase → Edge Functions → Logs; the scheduled sync picks it up later.
        console.error(`lead ${leadId}: ${(e as Error).message}`);
        results.push("error");
      }
    }
  }
  // Always 200 so Meta does not keep retrying; failures are recovered by the sync.
  return json({ ok: true, results });
});
