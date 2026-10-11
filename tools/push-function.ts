// دالة إرسال إشعارات الجوال — Supabase → Edge Functions → اسمها: push
// تولّد مفاتيح الإرسال بنفسها أول مرة وتحفظها في جدول push_config (لا تحتاج أي أسرار يدوية)
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

function serverKey(): string {
  const e = Deno.env;
  let k = e.get("SUPABASE_SERVICE_ROLE_KEY") || e.get("SUPABASE_SECRET_KEY") || "";
  if (!k) { try { const o = JSON.parse(e.get("SUPABASE_SECRET_KEYS") || "{}"); k = o.default || Object.values(o)[0] as string || ""; } catch (_) { /* */ } }
  return k;
}
const sb = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), {
  auth: { persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-hook",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function config() {
  let { data } = await sb.from("push_config").select("*").eq("id", 1).maybeSingle();
  if (!data) throw new Error("شغّل ملف push.sql أولاً");
  if (!data.public_key || !data.private_key) {
    const k = webpush.generateVAPIDKeys();
    await sb.from("push_config").update({ public_key: k.publicKey, private_key: k.privateKey }).eq("id", 1).is("public_key", null);
    ({ data } = await sb.from("push_config").select("*").eq("id", 1).maybeSingle());
  }
  return data!;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const c = await config();
    if (req.method === "GET") return json({ key: c.public_key });
    if (req.headers.get("x-hook") !== c.hook_secret) return json({ error: "forbidden" }, 403);

    const { users, title, body, url, tag } = await req.json();
    if (!Array.isArray(users) || !users.length) return json({ sent: 0 });
    webpush.setVapidDetails("mailto:admin@unifiedplatform.app", c.public_key, c.private_key);
    const { data: subs } = await sb.from("push_subs").select("*").in("user_id", users);
    const payload = JSON.stringify({ title, body, url, tag });
    let sent = 0;
    await Promise.all((subs || []).map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint);
      }
    }));
    return json({ sent });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
