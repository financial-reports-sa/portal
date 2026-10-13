// التقرير المسائي — Supabase → Edge Functions → اسمها: daily-brief (Verify JWT: OFF)
// القاعدة ترسل له أرقام اليوم + رمز سري، وهو يكتب التقرير بالذكاء الاصطناعي ويحفظه (المفتاح ANTHROPIC_API_KEY نفسه)
const MODEL = Deno.env.get("BRIEF_MODEL") || Deno.env.get("AI_MODEL") || "claude-haiku-4-5-20251001";
const FALLBACK = "claude-haiku-4-5-20251001";

const SYSTEM = `أنت محلل أعمال لمجموعة مطاعم (مطاعم الشادن: العزيزية وشوران — وبروست الباتشينو). تكتب «التقرير المسائي» لصاحب الشغل عن يوم واحد، يوصله إشعار ويقراه من الجوال.
القواعد:
- اعتمد فقط على البيانات المرفقة. لا تخترع رقم ولا تحسب أرقام جديدة إلا الواضحة جداً؛ الأرقام والنسب جاهزة في البيانات.
- لهجة سعودية مهذبة ومختصرة ومباشرة. الأرقام بالإنجليزي مع فواصل الآلاف، والعملة ر.س.
- أول سطر: خلاصة اليوم بجملة وحدة **بالخط العريض** فيها إجمالي المبيعات والمقارنة بنفس اليوم الأسبوع الماضي.
- بعدها أقسام قصيرة، كل قسم سطر عنوان بالخط العريض ثم نقاط تبدأ بـ «- » (اذكر فقط الأقسام اللي فيها بيانات):
  **المبيعات** (كل فرع: مبيعات اليوم والتغير، ومن بداية الشهر مقابل نفس الفترة والهدف)
  **التشغيل** (من نص التقرير اليومي: أهم الملاحظات مثل أوقات الذروة، الفئات، التطبيقات، الزوار — 2 إلى 4 نقاط فقط)
  **المستودع** (النسبة لكل فرع ومقارنتها بمتوسط الشهر)
  **الورديات** (العجوزات بأسماء الكاشيرات، والتسليمات اللي تنتظر المراجعة. فرق التسليمات عن المبيعات اذكره فقط إذا كبير وقل إنه يحتاج تحقق)
  **العملاء** (التقييمات والشكاوى)
  **أسعار المشتريات** (الارتفاعات)
  **تحتاج إجراء** (قائمة مختصرة بالأشياء اللي لازم يتصرف فيها: صيانة متأخرة، شكاوى مفتوحة، عهد أو سلف تنتظر، أقساط قريبة، عجوزات)
- ركّز على الملاحظات المهمة والانحرافات؛ لا تكرر الرقم في أكثر من مكان. لا تستخدم جداول ولا عناوين #.
- لا تذكر أي معلومات شخصية ولا تتكلم عن JSON أو البيانات المرسلة.`;

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: true });
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "no_key" }, 500);
  let b: { day?: string; token?: string; sb_url?: string; apikey?: string; facts?: unknown };
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const { day, token, sb_url, apikey, facts } = b;
  if (!day || !token || !sb_url || !apikey || !/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(sb_url)) return json({ error: "bad_request" }, 400);
  const rpc = async (fn: string, args: unknown) => {
    const r = await fetch(`${sb_url}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey, "Content-Type": "application/json" }, body: JSON.stringify(args) });
    const t = await r.text(); if (!r.ok) throw new Error(`${fn} ${r.status} ${t.slice(0, 200)}`); return t ? JSON.parse(t) : null;
  };
  const work = async () => {
    console.log("brief start", day);
    if (!(await rpc("brief_auth", { p_token: token }))) { console.error("unauthorized"); return; }
    let model = MODEL, text = "";
    for (let i = 0; i < 3 && !text; i++) {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model, max_tokens: 1800, system: SYSTEM, messages: [{ role: "user", content: "بيانات يوم " + day + ":\n" + JSON.stringify(facts).slice(0, 60000) }] }),
      });
      if (r.ok) { const j = await r.json(); text = (j.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("").trim(); break; }
      const t = await r.text(); console.error("upstream", model, r.status, t.slice(0, 300));
      if ((r.status === 404 || (r.status === 400 && /model/i.test(t))) && model !== FALLBACK) model = FALLBACK;
      else if ([429, 500, 502, 503, 529].includes(r.status)) await new Promise((ok) => setTimeout(ok, 2000 * (i + 1)));
      else break;
    }
    if (!text) { console.error("no_text"); return; }
    await rpc("brief_save", { p_token: token, p_day: day, p_text: text, p_facts: facts });
    console.log("brief saved", day, text.length);
  };
  // يرد فوراً ويكمل الكتابة بالخلفية (عشان القاعدة ما تنتظر)
  const p = work().catch((e) => console.error("brief failed", String((e as Error).message || e)));
  // deno-lint-ignore no-explicit-any
  const ER = (globalThis as any).EdgeRuntime;
  if (ER && typeof ER.waitUntil === "function") { ER.waitUntil(p); return json({ ok: true, queued: true }, 202); }
  await p; return json({ ok: true });
});
