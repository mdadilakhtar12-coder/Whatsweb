// Meta calls this address when a student writes, when a message is delivered / read,
// and when a template is approved or rejected.
// Set in Meta: WhatsApp > Configuration > Webhook (address and verify token are shown in the app).
import {
  adminIds,
  BUCKET,
  type Cfg,
  type Db,
  graph,
  loadCfg,
  logActivity,
  type NodeRow,
  push,
  runAction,
  sendNode,
  sendText,
  serviceClient,
} from "../_shared/wa.ts";
import {
  type Action,
  extFor,
  friendlyError,
  isStart,
  isStop,
  type Lead,
  NO_WHATSAPP_CODES,
  parseRef,
  type Spec,
  validSignature,
} from "../_shared/wa_logic.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

Deno.serve(async (req) => {
  const db = serviceClient();

  // Meta checks the address once when it is saved.
  if (req.method === "GET") {
    const url = new URL(req.url);
    const { data } = await db.from("wa_config").select("verify_token").eq("id", 1).maybeSingle();
    if (url.searchParams.get("hub.mode") === "subscribe" && data && url.searchParams.get("hub.verify_token") === data.verify_token) {
      return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = new Uint8Array(await req.arrayBuffer());
  const { data: c } = await db.from("wa_config").select("app_secret").eq("id", 1).maybeSingle();
  if (!c?.app_secret) return new Response("Save the App Secret in the app first", { status: 401 });
  if (!(await validSignature(c.app_secret, raw, req.headers.get("x-hub-signature-256")))) {
    return new Response("Bad signature", { status: 401 });
  }

  let body: Any;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  // Answer Meta quickly; the work carries on in the background.
  const job = handle(db, body).catch((e) => console.error("webhook", e));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as Any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(job);
  else await job;
  return new Response("ok", { status: 200 });
});

async function handle(db: Db, body: Any) {
  const cfg = await loadCfg(db);
  for (const entry of body.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const v = change.value ?? {};
      switch (change.field) {
        case "messages":
          for (const st of v.statuses ?? []) await onStatus(db, st).catch((e) => console.error("status", e));
          if (cfg) {
            for (const m of v.messages ?? []) await onMessage(db, cfg, m, v.contacts ?? []).catch((e) => console.error("message", e));
          }
          break;
        case "message_template_status_update":
          await onTemplateStatus(db, v);
          break;
        case "message_template_quality_update":
          await db.from("wa_templates").update({ quality: String(v.new_quality_score ?? "") || null })
            .eq("meta_id", String(v.message_template_id));
          break;
        case "phone_number_quality_update":
          await mergeStatus(db, { tier: v.current_limit ?? undefined, quality_event: v.event ?? undefined });
          break;
      }
    }
  }
}

async function mergeStatus(db: Db, patch: Record<string, unknown>) {
  const clean = Object.fromEntries(Object.entries(patch).filter(([, x]) => x !== undefined));
  const { data } = await db.from("app_settings").select("value").eq("key", "whatsapp_status").maybeSingle();
  await db.from("app_settings").upsert({
    key: "whatsapp_status",
    value: { ...(data?.value ?? {}), ...clean },
    updated_at: new Date().toISOString(),
  });
}

// ---------------------------------------------------------------------------
// sent / delivered / read / failed
// ---------------------------------------------------------------------------

const RANK: Record<string, number> = { queued: 0, sent: 1, delivered: 2, read: 3 };

async function onStatus(db: Db, st: Any) {
  const find = () =>
    db.from("wa_messages").select("id, lead_id, status, kind, type, delivered_at").eq("wa_id", st.id).maybeSingle();
  let { data: msg } = await find();
  if (!msg) {
    // The tick can arrive a moment before the send is saved.
    await new Promise((r) => setTimeout(r, 1500));
    ({ data: msg } = await find());
  }
  if (!msg) return;
  const ts = new Date(Number(st.timestamp) * 1000).toISOString();
  const isTemplate = msg.type === "template";

  if (st.status === "failed") {
    const e = st.errors?.[0] ?? {};
    const code = Number(e.code ?? 0);
    const text = friendlyError(code, e.error_data?.details || e.message || e.title || "Not delivered");
    await db.from("wa_messages").update({ status: "failed", error: text, error_code: code, failed_at: ts }).eq("id", msg.id);
    if (isTemplate) {
      await db.from("leads")
        .update({ wa_state: NO_WHATSAPP_CODES.has(code) ? "no_whatsapp" : "failed" })
        .eq("id", msg.lead_id)
        .in("wa_state", ["none", "queued", "sent", "delivered"]);
    }
    if (msg.kind === "auto") await logActivity(db, msg.lead_id, `Automatic WhatsApp not delivered: ${text}`);
    return;
  }

  const next = String(st.status);
  if (!(next in RANK) || next === "queued") return;
  if (msg.status === "failed") return;
  const patch: Record<string, unknown> = {};
  if (RANK[next] > (RANK[msg.status] ?? 0)) patch.status = next;
  if (next === "sent") patch.sent_at = ts;
  if (next === "delivered" || next === "read") patch.delivered_at = msg.delivered_at ?? ts;
  if (next === "read") patch.read_at = ts;
  if (Object.keys(patch).length) await db.from("wa_messages").update(patch).eq("id", msg.id);

  // The tick on the lead card follows the latest template message (never goes backwards, never over a reply).
  if (isTemplate && (next === "delivered" || next === "read")) {
    const from = next === "read" ? ["none", "queued", "sent", "delivered"] : ["none", "queued", "sent"];
    await db.from("leads").update({ wa_state: next }).eq("id", msg.lead_id).in("wa_state", from);
  }
}

// ---------------------------------------------------------------------------
// A message from a student
// ---------------------------------------------------------------------------

async function onMessage(db: Db, cfg: Cfg, m: Any, contacts: Any[]) {
  const { data: dup } = await db.from("wa_messages").select("id").eq("wa_id", m.id).maybeSingle();
  if (dup) return; // Meta sends some messages twice

  const from = String(m.from ?? "");
  if (!from) return;
  let { data: lead } = await db.from("leads").select("*").eq("phone_key", from.slice(-10)).limit(1).maybeSingle();
  let isNew = false;
  if (!lead) {
    const profileName = contacts.find((c) => c.wa_id === from)?.profile?.name ?? "";
    const ad = m.referral;
    const { data: res } = await db.rpc("ingest_lead", {
      p_name: profileName,
      p_phone: "+" + from,
      p_email: null,
      p_source: "whatsapp",
      p_source_detail: ad?.headline || ad?.source_url || "WhatsApp message",
      p_external_id: null,
      p_extra: ad ? { ad_headline: ad.headline ?? "", ad_link: ad.source_url ?? "" } : {},
    });
    if (res?.id) {
      ({ data: lead } = await db.from("leads").select("*").eq("id", res.id).maybeSingle());
      isNew = true;
    }
  }
  if (!lead) return;

  const ts = new Date(Number(m.timestamp) * 1000).toISOString();
  let type = String(m.type ?? "unknown");
  let text = "";
  let label = "";
  let ref: string | null = null;
  let mediaId: string | undefined;
  let mime: string | undefined;
  let filename: string | undefined;

  switch (type) {
    case "text":
      text = m.text?.body ?? "";
      break;
    case "button":
      text = m.button?.text ?? "";
      ref = m.button?.payload ?? null;
      break;
    case "interactive": {
      const r = m.interactive?.button_reply ?? m.interactive?.list_reply;
      text = r?.title ?? "";
      ref = r?.id ?? null;
      break;
    }
    case "image":
    case "video":
    case "document":
    case "audio":
    case "sticker": {
      const x = m[type] ?? {};
      mediaId = x.id;
      mime = x.mime_type;
      filename = x.filename;
      text = x.caption ?? "";
      label = { image: "🖼 Photo", video: "🎬 Video", document: "📄 " + (x.filename ?? "Document"), audio: "🎤 Voice message", sticker: "Sticker" }[type] ?? "";
      break;
    }
    case "location": {
      const l = m.location ?? {};
      text = `📍 ${[l.name, l.address].filter(Boolean).join(", ") || `${l.latitude}, ${l.longitude}`}`;
      break;
    }
    case "reaction":
      text = m.reaction?.emoji ?? "";
      break;
    default:
      type = "unknown";
      text = "Message type not supported";
  }

  const { data: row } = await db
    .from("wa_messages")
    .insert({
      lead_id: lead.id, direction: "in", kind: "inbound", type, body: text, wa_id: m.id,
      status: "received", mime, filename, created_at: ts,
    })
    .select("id")
    .single();
  if (type === "reaction") return; // a thumbs-up is not a reply

  if (mediaId && row) await saveMedia(db, cfg, lead.id, row.id, mediaId, m.id, mime, filename);

  const preview = text || label || "Message";
  await db.from("leads").update({
    wa_state: "replied",
    wa_last_inbound_at: ts,
    wa_last_message_at: ts,
    wa_last_text: preview.replace(/\s+/g, " ").slice(0, 140),
    wa_last_direction: "in",
    wa_unread: (lead.wa_unread ?? 0) + 1,
  }).eq("id", lead.id);

  // STOP / START
  if (type === "text" && isStop(text)) {
    await db.from("leads").update({ wa_opt_out: true }).eq("id", lead.id);
    await logActivity(db, lead.id, "Asked to stop WhatsApp messages");
    await sendText(db, cfg, lead as Lead, "You will not get any more messages from us. Reply START if you change your mind.", "bot", null);
  } else if (type === "text" && isStart(text)) {
    await db.from("leads").update({ wa_opt_out: false }).eq("id", lead.id);
    await logActivity(db, lead.id, "WhatsApp messages switched on again");
    await sendText(db, cfg, lead as Lead, "Thank you! You will get our messages again.", "bot", null);
  } else {
    const action = await findAction(db, ref, m, text);
    if (action) await runAction(db, cfg, lead as Lead, action, text);
    if (isNew) {
      const { data: s } = await db.from("app_settings").select("value").eq("key", "whatsapp").maybeSingle();
      const nodeId = s?.value?.welcome_node_id;
      if (nodeId) {
        const { data: node } = await db.from("wa_nodes").select("*").eq("id", nodeId).maybeSingle();
        if (node) await sendNode(db, cfg, lead as Lead, node as NodeRow, "bot");
      }
    }
  }

  // Tell the agent (or the admins if nobody has the lead yet).
  const { data: fresh } = await db.from("leads").select("assigned_to, name, phone").eq("id", lead.id).single();
  const targets = fresh?.assigned_to ? [fresh.assigned_to as string] : await adminIds(db);
  await push(targets.map((user_id) => ({
    user_id,
    title: `💬 ${fresh?.name || fresh?.phone || "New message"}`,
    body: preview.slice(0, 120),
    data: { lead_id: lead.id, chat: "1" },
  })));
}

/** Which button or list row did the student press, and what should happen. */
async function findAction(db: Db, ref: string | null, m: Any, text: string): Promise<Action | undefined> {
  const r = parseRef(ref);
  if (r?.kind === "template") {
    const { data } = await db.from("wa_templates").select("spec").eq("id", r.id).maybeSingle();
    return (data?.spec as Spec | undefined)?.buttons?.[r.index]?.action;
  }
  if (r?.kind === "node_button" || r?.kind === "node_row") {
    const { data: node } = await db.from("wa_nodes").select("buttons, sections").eq("id", r.id).maybeSingle();
    if (!node) return undefined;
    return r.kind === "node_button" ? node.buttons?.[r.index]?.action : node.sections?.[r.section]?.rows?.[r.row]?.action;
  }
  // A template made in Meta's own screen: match the button by its words.
  if (m.type === "button" && m.context?.id) {
    const { data: orig } = await db.from("wa_messages").select("template_id").eq("wa_id", m.context.id).maybeSingle();
    if (orig?.template_id) {
      const { data: t } = await db.from("wa_templates").select("spec").eq("id", orig.template_id).maybeSingle();
      const btn = (t?.spec as Spec | undefined)?.buttons?.find((b) => b.type === "quick_reply" && (b.text ?? "").trim() === text.trim());
      return btn?.action;
    }
  }
  return undefined;
}

/** Photos, PDFs and voice messages from the student are kept so the agent can open them. */
async function saveMedia(
  db: Db, cfg: Cfg, leadId: string, rowId: string, mediaId: string, wamid: string,
  mime?: string, filename?: string,
) {
  try {
    const info = await graph(cfg, `/${mediaId}`);
    if (Number(info.file_size ?? 0) > 20 * 1024 * 1024) return;
    const res = await fetch(info.url, { headers: { Authorization: `Bearer ${cfg.access_token}` } });
    if (!res.ok) return;
    const bytes = new Uint8Array(await res.arrayBuffer());
    const path = `in/${leadId}/${wamid.replace(/[^A-Za-z0-9]/g, "")}.${extFor(mime ?? info.mime_type, filename)}`;
    const { error } = await db.storage.from(BUCKET).upload(path, bytes, {
      contentType: (mime ?? info.mime_type ?? "application/octet-stream").split(";")[0],
      upsert: true,
    });
    if (!error) await db.from("wa_messages").update({ media_path: path, mime: mime ?? info.mime_type }).eq("id", rowId);
  } catch (e) {
    console.error("media", e);
  }
}

// ---------------------------------------------------------------------------
// Template approved / rejected
// ---------------------------------------------------------------------------

const TEMPLATE_STATES: Record<string, string> = {
  APPROVED: "APPROVED", REJECTED: "REJECTED", PENDING: "PENDING", PAUSED: "PAUSED", DISABLED: "DISABLED",
  IN_APPEAL: "PENDING", FLAGGED: "APPROVED", REINSTATED: "APPROVED", PENDING_DELETION: "DISABLED",
};

async function onTemplateStatus(db: Db, v: Any) {
  const status = TEMPLATE_STATES[String(v.event)];
  if (!status) return;
  const reason = v.reason && v.reason !== "NONE" ? String(v.reason) : (v.other_info?.description ?? null);
  const patch = { status, reason, updated_at: new Date().toISOString() };

  let { data: rows } = await db.from("wa_templates").update(patch).eq("meta_id", String(v.message_template_id)).select("id, name");
  if (!rows?.length && v.message_template_name) {
    ({ data: rows } = await db.from("wa_templates").update({ ...patch, meta_id: String(v.message_template_id) })
      .eq("name", v.message_template_name).eq("language", v.message_template_language ?? "en").select("id, name"));
  }
  const name = rows?.[0]?.name ?? v.message_template_name ?? "Template";
  if (status === "APPROVED" || status === "REJECTED") {
    await push((await adminIds(db)).map((user_id) => ({
      user_id,
      title: status === "APPROVED" ? `✅ Template "${name}" approved` : `❌ Template "${name}" rejected`,
      body: status === "APPROVED" ? "You can use it now" : (reason ?? "Open More > WhatsApp > Templates"),
      data: { open: "whatsapp" },
    })));
  }
}
