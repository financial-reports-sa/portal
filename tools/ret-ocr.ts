// قراءة فاتورة المرتجع من الصورة — Supabase → Edge Functions → اسمها: ret-ocr (Verify JWT: OFF)
// تستخدم نفس المفتاح ANTHROPIC_API_KEY. الكاشير يصوّر الفاتورة ← ترجع رقم الفاتورة والوقت والمبلغ
const MODEL = Deno.env.get("OCR_MODEL") || "claude-sonnet-5-5";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const TOOL = { name: "invoice", description: "بيانات الفاتورة المقروءة من الصورة", input_schema: { type: "object", required: ["inv_no", "time", "ampm", "amount"], properties: {
  inv_no: { type: "string", description: "رقم الفاتورة الطويل (12 رقم تقريباً، مثل 260020170435) المطبوع تحت «فاتورة ضريبية مبسطة» على نفس سطر اسم الكاشير. ليس Bill No (رقم الطلب القصير مثل 0:33) ولا الرقم الضريبي ولا الجوال. أرقام إنجليزية فقط، أو فارغ إذا غير واضح" },
  time: { type: "string", description: "وقت الفاتورة كما هو مطبوع بالضبط HH:MM بدون تحويل (مثلاً 11:10). من سطر التاريخ والوقت جنب «كاشير». اقرأ كل رقم بعناية. فارغ إذا غير واضح" },
  ampm: { type: "string", enum: ["ص", "م", ""], description: "الحرف المطبوع بعد الوقت: ص (صباحاً) أو م (مساءً)، فارغ إذا ما فيه" },
  amount: { type: "number", description: "المبلغ الإجمالي المستحق للفاتورة كاملة شامل الضريبة (Net/الإجمالي في أسفل الفاتورة) — ليس سعر أول صنف. صفر إذا غير واضح أو ما يظهر في الصورة" },
  items: { type: "array", description: "أصناف الفاتورة من جدول الأصناف، بالترتيب", items: { type: "object", required: ["name", "qty", "unit"], properties: {
    name: { type: "string", description: "اسم الصنف حرفياً كما هو مطبوع — لا تخترع أسماء" }, qty: { type: "number", description: "الكمية" }, unit: { type: "number", description: "سعر الوحدة شامل الضريبة" } } } },
} } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false }, 405);
  const key = Deno.env.get("ANTHROPIC_API_KEY"), sb = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!key || !sb || !anon) return json({ ok: false, message: "no_key" }, 500);
  let b: { branch?: string; pin?: string; img?: string };
  try { b = await req.json(); } catch { return json({ ok: false, message: "bad_json" }, 400); }
  const m = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(b.img || "");
  if (!b.branch || !b.pin || !m || m[2].length > 1600000) return json({ ok: false, message: "bad_request" }, 400);
  const a = await fetch(`${sb}/rest/v1/rpc/ret_ocr_ok`, { method: "POST", headers: { apikey: anon, Authorization: `Bearer ${anon}`, "Content-Type": "application/json" }, body: JSON.stringify({ p_branch: b.branch, p_pin: b.pin }) });
  const aj = a.ok ? await a.json() : null;
  if (!aj || !aj.ok) return json({ ok: false, message: (aj && aj.message) || "auth" }, 200);
  const ask = (model: string) => fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model, max_tokens: 1200, tools: [TOOL], tool_choice: { type: "tool", name: "invoice" },
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: m[1], data: m[2] } },
        { type: "text", text: "هذي فاتورة مطعم سعودية (حرارية). اقرأ رقم الفاتورة ووقتها والمبلغ المستحق وجدول الأصناف واحفظها بالأداة invoice. لا تخمّن: إذا شي غير واضح اتركه فارغ." },
      ] }] }),
  });
  let r = await ask(MODEL);
  if (!r.ok) { console.error("upstream", MODEL, r.status, (await r.text()).slice(0, 300)); r = await ask("claude-haiku-4-5-20251001"); }
  if (!r.ok) { const t = (await r.text()).slice(0, 300); console.error("upstream2", r.status, t); return json({ ok: false, message: "upstream " + r.status }, 200); }
  const j = await r.json();
  const tu = (j.content || []).find((c: { type: string; name?: string }) => c.type === "tool_use" && c.name === "invoice");
  const x = (tu && tu.input) || {};
  const inv = String(x.inv_no || "").replace(/[٠-٩]/g, (d: string) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(/\D/g, "").slice(0, 30);
  const tm = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(String(x.time || "").replace(/[٠-٩]/g, (d: string) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).trim());
  let hh = tm ? Number(tm[1]) : 0;
  if (tm && hh <= 12) { if (x.ampm === "م" && hh < 12) hh += 12; if (x.ampm === "ص" && hh === 12) hh = 0; }
  const amt = Number(x.amount);
  const items = (Array.isArray(x.items) ? x.items : []).slice(0, 30).map((i: { name?: unknown; qty?: unknown; unit?: unknown }) => ({ name: String(i.name || "").slice(0, 60), qty: Math.max(0, Math.min(999, Math.round(Number(i.qty) || 0))), unit: Math.max(0, Math.round((Number(i.unit) || 0) * 100) / 100) })).filter((i: { name: string; qty: number; unit: number }) => i.name && i.qty > 0 && i.unit > 0);
  const okInv = /^\d{10,14}$/.test(inv), srv = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (okInv && srv) await fetch(`${sb}/rest/v1/rpc/ret_ocr_mark`, { method: "POST", headers: { apikey: srv, Authorization: `Bearer ${srv}`, "Content-Type": "application/json" }, body: JSON.stringify({ p_branch: b.branch, p_pin: b.pin, p_inv: inv, p_time: tm ? `${String(hh).padStart(2, "0")}:${tm[2]}` : null }) }).catch(() => null);
  return json({ ok: true, items, inv: okInv ? inv : "", time: tm ? `${String(hh).padStart(2, "0")}:${tm[2]}` : "", amount: isFinite(amt) && amt > 0 && amt < 50000 ? Math.round(amt * 100) / 100 : 0 });
});
