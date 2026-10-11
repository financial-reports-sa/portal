// دالة إرسال إشعارات الجوال — Supabase → Edge Functions → اسمها: push (Verify JWT: OFF)
// بدون أي اتصال بقاعدة البيانات: القاعدة ترسل لها المفاتيح والأجهزة ونص الإشعار، وهي توقّع وترسل فقط.
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.method === "GET") {
      if (new URL(req.url).searchParams.has("gen")) return json(webpush.generateVAPIDKeys());
      return json({ ok: true });
    }
    const { vapid, subs, payload } = await req.json();
    if (!vapid?.pub || !vapid?.priv) return json({ error: "no keys" }, 400);
    webpush.setVapidDetails("mailto:admin@unifiedplatform.app", vapid.pub, vapid.priv);
    const body = JSON.stringify(payload || {});
    const gone: string[] = [];
    let sent = 0;
    await Promise.all((subs || []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 86400, urgency: "high" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) gone.push(s.endpoint);
        else console.error("push failed", code, (e as { body?: string }).body || String(e));
      }
    }));
    return json({ sent, gone });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
