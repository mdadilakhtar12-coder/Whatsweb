// Claude connector (MCP server): Claude reads, and ASKS for changes that the owner approves in the CRM app.
//
//   POST /functions/v1/crm-mcp/<secret>    JSON-RPC from the Claude app (a custom connector points here)
//
// The secret is app_settings.integrations.mcp_token (More > Claude connector in the app; it can be replaced).
// Reading tools run in the database (mcp_read); writing tools only leave a request (mcp_propose) that the owner
// approves in the app. Each kind has a switch (integrations.mcp_perms); a tool whose switch is off is not listed.
// This file only checks the secret and the arguments. Every call is recorded in mcp_log and rate limited there.
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleRpc, type Rpc, safeEqual, secretFromPath, ToolError } from "../_shared/mcp_logic.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, mcp-session-id, mcp-protocol-version, accept",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

let cached: { token: string; perms: Record<string, boolean>; at: number } | null = null;

// deno-lint-ignore no-explicit-any
async function settings(db: any) {
  if (!cached || Date.now() - cached.at > 10_000) {
    const { data } = await db.from("app_settings").select("value").eq("key", "integrations").maybeSingle();
    const v = (data?.value ?? {}) as Record<string, unknown>;
    const perms = (v.mcp_perms && typeof v.mcp_perms === "object" ? v.mcp_perms : {}) as Record<string, boolean>;
    cached = { token: String(v.mcp_token ?? ""), perms, at: Date.now() };
  }
  return cached;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Same answer for "wrong" and "not set up": nobody learns anything by guessing.
  const given = secretFromPath(new URL(req.url).pathname);
  const current = await settings(db);
  if (!given || current.token.length < 32 || !safeEqual(given, current.token)) return json({ error: "Not found" }, 404);

  // This server does not stream: the client may ask and is told so.
  if (req.method === "GET" || req.method === "DELETE") return new Response(null, { status: 405, headers: { ...cors, Allow: "POST" } });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const text = await req.text();
  if (text.length > 100_000) return json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Too big" } }, 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }

  // The database answers {error: "..."} for things Claude can understand and fix: those go back as they are.
  const answer = (data: unknown, error: { message: string } | null) => {
    if (error) throw new Error(error.message);
    const a = data as Record<string, unknown>;
    if (a && typeof a.error === "string") throw new ToolError(a.error);
    return a;
  };
  const deps = {
    call: async (tool: string, args: Record<string, unknown>) => {
      const { data, error } = await db.rpc("mcp_read", { p_tool: tool, p_args: args });
      return answer(data, error);
    },
    propose: async (kind: string, args: Record<string, unknown>, reason: string | null) => {
      const { data, error } = await db.rpc("mcp_propose", { p_kind: kind, p_args: args, p_reason: reason });
      return answer(data, error);
    },
    perms: async () => (await settings(db)).perms,
    lookups: async () => {
      const [replies, statuses, templates] = await Promise.all([
        db.from("wa_nodes").select("id, name"),
        db.from("lead_statuses").select("name, sort_order").order("sort_order"),
        db.from("wa_templates").select("name, language"),
      ]);
      return {
        replies: (replies.data ?? []) as { id: string; name: string }[],
        statuses: ((statuses.data ?? []) as { name: string }[]).map((s) => s.name),
        templates: (templates.data ?? []) as { name: string; language: string }[],
      };
    },
  };

  if (Array.isArray(body)) {
    const answers = (await Promise.all(body.slice(0, 20).map((m) => handleRpc(m as Rpc, deps)))).filter((a) => a !== null);
    return answers.length ? json(answers) : new Response(null, { status: 202, headers: cors });
  }
  const reply = await handleRpc(body as Rpc, deps);
  return reply ? json(reply) : new Response(null, { status: 202, headers: cors });
});
