// MyHub — تقييم صور النظافة بالذكاء الاصطناعي — Supabase → Edge Functions → اسمها: clean-ai (اترك Verify JWT شغّال)
// يستخدم نفس Secret الموجود: ANTHROPIC_API_KEY (لا يُكتب هنا أبداً). اختياري: Secret باسم CLEAN_AI_MODEL لتغيير النموذج
// SUPABASE_URL و SUPABASE_ANON_KEY و SUPABASE_SERVICE_ROLE_KEY متوفرة تلقائياً داخل Edge Functions
const MODEL = Deno.env.get("CLEAN_AI_MODEL") || "claude-sonnet-5-5";
const FALLBACK = "claude-haiku-4-5-20251001";
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SRV = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const j = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const SYSTEM = `أنت مفتش نظافة صارم وعادل لمطاعم بروست ووجبات سريعة في السعودية.
تستلم بنود قائمة نظافة (فتح أو منتصف اليوم أو إغلاق)، ولكل بند منفّذ 3 صور صوّرها الموظف كإثبات.
قيّم كل بند من 1 إلى 5 بناءً على الصور فقط:
5 = نظيف تماماً ومرتب بلا أي ملاحظة.
4 = نظيف مع ملاحظة بسيطة جداً.
3 = مقبول لكن فيه أوساخ أو بقع أو فوضى واضحة في جزء.
2 = غير نظيف: دهون، بقايا أكل، أرضية متسخة، نفايات، أدوات غير مرتبة.
1 = متسخ جداً، أو الصور لا تخص البند، أو صورة مكررة لنفس اللقطة، أو صور مظلمة/مهزوزة لا يمكن الحكم منها، أو صورة لشاشة أو صورة قديمة.
المرجع: اشتراطات الصحة العامة للمنشآت الغذائية الصادرة عن وزارة البلديات والإسكان (البلدية)، ومنها:
- الأرضيات والجدران والأسقف نظيفة وخالية من الدهون والبقع والتشققات المتسخة.
- أسطح التحضير والطاولات والأدوات نظيفة وجافة، والقلايات والشوايات والشفاطات خالية من تراكم الدهون والكربون.
- النفايات في حاويات مغطاة وغير ممتلئة، ولا نفايات أو بقايا أكل على الأرض.
- المواد الغذائية مغطاة ومرتفعة عن الأرض، ولا تخزين عشوائي، ولا خلط بين النيء والمطبوخ.
- دورات المياه ومغاسل الأيدي نظيفة ومزودة بالصابون والمناديل.
- لا أي أثر لحشرات أو قوارض، ولا مياه راكدة.
أي مخالفة لهذه الاشتراطات تظهر في الصور تنزل تقييم البند، واذكرها في الملاحظة.
قواعد:
- لا تعطي 5 إلا إذا كانت الصور الثلاث واضحة وتثبت النظافة فعلاً. التقييم الزائف ممنوع؛ المطلوب تقييم عادل.
- انتبه إذا تكررت نفس الصورة أو نفس اللقطة في أكثر من بند، واعتبرها غشاً (1).
- إذا الصورة لا تطابق عنوان البند (مثلاً البند «تنظيف القلايات» والصور لأرضية الصالة) أعطه 1 أو 2 واذكر السبب.
- الملاحظة لكل بند: جملة قصيرة جداً بالعربي توضح وش شفت (مثلاً «دهون واضحة على جانب القلاية»).
- الملخص: سطرين بالعربي، يذكر أبرز الملاحظات السلبية أولاً، بلهجة رسمية مختصرة.
سجّل النتيجة بأداة report فقط.`;

const TOOL = {
  name: "report",
  description: "تسجيل تقييم النظافة",
  input_schema: {
    type: "object",
    properties: {
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            i: { type: "integer", description: "رقم البند كما ورد" },
            score: { type: "integer", minimum: 1, maximum: 5 },
            clean: { type: "boolean", description: "هل يعتبر نظيف" },
            match: { type: "boolean", description: "هل الصور تخص البند" },
            note: { type: "string" },
          },
          required: ["i", "score", "clean", "match", "note"],
        },
      },
      summary: { type: "string" },
    },
    required: ["items", "summary"],
  },
};

function b64(buf: ArrayBuffer): string {
  const u = new Uint8Array(buf); let s = "";
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s);
}
async function img(v: string): Promise<{ data: string; type: string } | null> {
  if (!v) return null;
  if (v.startsWith("data:")) { const m = v.match(/^data:(image\/[a-z]+);base64,(.+)$/); return m ? { type: m[1], data: m[2] } : null; }
  if (!v.startsWith("sb:")) return null;
  const r = await fetch(`${URL_}/storage/v1/object/media/${v.slice(3).split("/").map(encodeURIComponent).join("/")}`, { headers: { Authorization: `Bearer ${SRV}`, apikey: SRV } });
  if (!r.ok) return null;
  const t = (r.headers.get("content-type") || "image/jpeg").split(";")[0];
  return { type: /image\/(jpeg|png|webp|gif)/.test(t) ? t : "image/jpeg", data: b64(await r.arrayBuffer()) };
}
async function rpc(fn: string, args: unknown, auth: string, key: string) {
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: auth, apikey: key }, body: JSON.stringify(args) });
  const t = await r.text(); let d: any = null; try { d = JSON.parse(t); } catch { d = t; }
  if (!r.ok) throw new Error((d && d.message) || t || ("rpc " + r.status));
  return d;
}
async function claude(model: string, content: unknown[]) {
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model, max_tokens: 3000, system: SYSTEM, tools: [TOOL], tool_choice: { type: "tool", name: "report" }, messages: [{ role: "user", content }] }),
  });
  if (!r.ok) throw new Error("ai " + r.status + " " + (await r.text()).slice(0, 200));
  const d = await r.json();
  const u = (d.content || []).find((c: any) => c.type === "tool_use");
  if (!u) throw new Error("ai no result");
  return u.input;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return j({ error: "method" }, 405);
  const auth = req.headers.get("Authorization") || "";
  let body: { id?: string; force?: boolean } = {};
  try { body = await req.json(); } catch { return j({ error: "bad_json" }, 400); }
  if (!body.id) return j({ error: "no_id" }, 400);
  let job: any;
  try { job = await rpc("clean_ai_job", { p_id: body.id, p_force: !!body.force }, auth, ANON); } catch (e) { return j({ error: String((e as Error).message) }, 403); }
  if (job && job.done) return j({ ok: true, done: true });
  try {
    const items: any[] = job.items || [];
    const content: unknown[] = [{ type: "text", text: `الفرع: ${job.branch} — ${job.shift}. قيّم كل بند منفّذ من صوره الثلاث.` }];
    let n = 0;
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (!it.ok) continue;
      content.push({ type: "text", text: `البند ${i}: ${it.t}` });
      const phs: string[] = Array.isArray(it.phs) ? it.phs : (it.ph ? [it.ph] : []);
      const got = await Promise.all(phs.slice(0, 3).map((p) => img(p).catch(() => null)));
      let k = 0;
      for (const g of got) if (g) { content.push({ type: "image", source: { type: "base64", media_type: g.type, data: g.data } }); k++; n++; }
      if (!k) content.push({ type: "text", text: `(البند ${i} بدون صور قابلة للفتح — قيّمه 1)` });
    }
    if (!n) { await rpc("clean_ai_save", { p_id: body.id, p_items: [], p_note: "ما فيه صور قابلة للتحليل", p_err: "" }, `Bearer ${SRV}`, SRV); return j({ ok: true, rating: 1 }); }
    let out: any;
    try { out = await claude(MODEL, content); } catch (_e) { out = await claude(FALLBACK, content); }
    const res = (out.items || []).map((x: any) => ({ i: +x.i, score: Math.max(1, Math.min(5, Math.round(+x.score || 1))), clean: !!x.clean, match: x.match !== false, note: String(x.note || "").slice(0, 200) }));
    const rating = await rpc("clean_ai_save", { p_id: body.id, p_items: res, p_note: String(out.summary || "").slice(0, 1500), p_err: "" }, `Bearer ${SRV}`, SRV);
    return j({ ok: true, rating });
  } catch (e) {
    try { await rpc("clean_ai_save", { p_id: body.id, p_items: [], p_note: "", p_err: String((e as Error).message) }, `Bearer ${SRV}`, SRV); } catch { /* */ }
    return j({ error: String((e as Error).message) }, 500);
  }
});
