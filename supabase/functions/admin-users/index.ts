// Admin-only: create team members, change name/role/password, activate/deactivate.
// Called from the app's Team screen with the logged-in admin's token.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: userData, error: authError } = await supabase.auth.getUser(token);
  if (authError || !userData.user) return json({ error: "Please log in again" }, 401);

  const { data: me } = await supabase
    .from("profiles")
    .select("role, is_active")
    .eq("id", userData.user.id)
    .single();
  if (!me || me.role !== "admin" || !me.is_active) {
    return json({ error: "Only admin can manage the team" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request" }, 400);
  }

  if (body.action === "create") {
    const email = String(body.email ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    const fullName = String(body.full_name ?? "").trim() || email.split("@")[0];
    const role = body.role === "admin" ? "admin" : "agent";

    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json({ error: "Login ID must look like an email, e.g. ravi@mycrm.in" }, 400);
    }
    if (password.length < 6) return json({ error: "Password must be at least 6 characters" }, 400);

    const { data, error } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (error) return json({ error: error.message }, 400);

    // The database trigger already created the profile as an agent.
    const { error: profileError } = await supabase
      .from("profiles")
      .update({ full_name: fullName, role })
      .eq("id", data.user.id);
    if (profileError) return json({ error: profileError.message }, 400);

    return json({ id: data.user.id });
  }

  if (body.action === "update") {
    const id = String(body.user_id ?? "");
    if (!id) return json({ error: "user_id is required" }, 400);

    const profilePatch: Record<string, unknown> = {};
    if (typeof body.full_name === "string" && body.full_name.trim()) {
      profilePatch.full_name = body.full_name.trim();
    }
    if (body.role === "admin" || body.role === "agent") profilePatch.role = body.role;
    if (typeof body.is_active === "boolean") profilePatch.is_active = body.is_active;

    if (Object.keys(profilePatch).length > 0) {
      const { error } = await supabase.from("profiles").update(profilePatch).eq("id", id);
      if (error) return json({ error: error.message }, 400);
    }

    const authPatch: Record<string, unknown> = {};
    if (typeof body.password === "string" && body.password !== "") {
      if (body.password.length < 6) {
        return json({ error: "Password must be at least 6 characters" }, 400);
      }
      authPatch.password = body.password;
    }
    // A deactivated member cannot log in again.
    if (typeof body.is_active === "boolean") {
      authPatch.ban_duration = body.is_active ? "none" : "876000h";
    }
    if (Object.keys(authPatch).length > 0) {
      const { error } = await supabase.auth.admin.updateUserById(id, authPatch);
      if (error) return json({ error: error.message }, 400);
    }

    return json({ ok: true });
  }

  return json({ error: "Unknown action" }, 400);
});
