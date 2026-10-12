// Delivers push notifications through Firebase Cloud Messaging (HTTP v1).
// Called by the database (private.push) with:
//   {"messages": [{"user_id": "...", "title": "...", "body": "...", "data": {"lead_id": "..."}}]}
// Secrets: WEBHOOK_KEY (sent as x-webhook-key), FIREBASE_SERVICE_ACCOUNT (service account JSON).
import { createClient } from "npm:@supabase/supabase-js@2";

type Message = { user_id: string; title: string; body?: string; data?: Record<string, unknown> };
type ServiceAccount = { project_id: string; client_email: string; private_key: string };

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function base64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cachedToken: { value: string; expires: number } | null = null;

// OAuth access token for FCM, signed with the service account key (cached ~55 minutes).
async function accessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expires > now + 60) return cachedToken.value;

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  const jwt = `${header}.${claims}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Google token: ${body.error_description ?? body.error ?? res.status}`);
  cachedToken = { value: body.access_token, expires: now + (body.expires_in ?? 3600) };
  return cachedToken.value;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  const expected = Deno.env.get("WEBHOOK_KEY");
  if (!expected || req.headers.get("x-webhook-key") !== expected) return json({ error: "Invalid key" }, 401);

  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!raw) return json({ skipped: "FIREBASE_SERVICE_ACCOUNT is not set" });
  const sa = JSON.parse(raw) as ServiceAccount;

  let messages: Message[];
  try {
    messages = ((await req.json()).messages ?? []) as Message[];
  } catch {
    return json({ error: "Bad JSON" }, 400);
  }
  if (messages.length === 0) return json({ sent: 0 });

  const userIds = [...new Set(messages.map((m) => m.user_id))];
  const { data: devices, error } = await supabase
    .from("device_tokens")
    .select("token, user_id")
    .in("user_id", userIds);
  if (error) return json({ error: error.message }, 500);

  const token = await accessToken(sa);
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  const stale: string[] = [];
  let sent = 0;
  let failed = 0;

  await Promise.all(messages.flatMap((m) =>
    (devices ?? []).filter((d) => d.user_id === m.user_id).map(async (d) => {
      // FCM data values must be strings.
      const data: Record<string, string> = {};
      for (const [k, v] of Object.entries(m.data ?? {})) data[k] = String(v);
      const res = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          message: {
            token: d.token,
            notification: { title: m.title, body: m.body ?? "" },
            data,
            android: {
              priority: "HIGH",
              notification: { channel_id: "leads", icon: "ic_stat_lead", sound: "default" },
            },
          },
        }),
      });
      if (res.ok) {
        sent++;
        return;
      }
      failed++;
      const body = await res.text();
      // The app was uninstalled or the token changed: forget this phone.
      if (res.status === 404 || body.includes("UNREGISTERED") || body.includes("registration-token-not-registered")) {
        stale.push(d.token);
      } else {
        console.error(`FCM ${res.status}: ${body}`);
      }
    })
  ));

  if (stale.length > 0) await supabase.from("device_tokens").delete().in("token", stale);
  return json({ sent, failed, removed: stale.length });
});
