// الأفكار التسويقية والترندات اليومية — Supabase → Edge Functions → اسمها: mkt-trends (Verify JWT: OFF)
// القاعدة تستدعيها كل صباح (وزر «تحديث» للإدارة) ← تبحث في الإنترنت عن ترندات اليوم ← تكتب أفكار وتحفظها في المنصة
// وكل أسبوع (أو بزر «ابحث عن مؤثرين») تبحث عن مؤثري الأكل في المدينة وجدة وتضيفهم لقائمة المؤثرين
// تستخدم نفس المفتاح ANTHROPIC_API_KEY. اختياري: Secret باسم MKT_MODEL لتغيير النموذج
const MODEL = Deno.env.get("MKT_MODEL") || "claude-sonnet-5-5";
const FALLBACK = "claude-haiku-4-5-20251001";

const SYSTEM = `أنت مسؤول تسويق ذكي لمجموعة مطاعم في المدينة المنورة:
- «مطاعم الشادن»: مطعم ومطابخ (رز ومشويات ووجبات عائلية) — فرع العزيزية (فيه قسم عائلات وتطبيق الشادن) وفرع شوران (توصيل).
- «بروست الباتشينو»: بروست ودجاج مقلي — فئة الشباب والتوصيل.
القنوات: تيك توك، سناب شات، انستقرام، إكس، واتساب، تطبيقات التوصيل (هنقرستيشن، كيتا، نينجا، فرصة)، وعروض داخل الفرع.
مهمتك كل صباح:
1) ابحث في الإنترنت عن ترندات اليوم في السعودية اللي تفيد مطعم: هاشتاقات وأصوات وتحديات تيك توك وسناب الرائجة، مناسبات اليوم والأسبوع (هجري وميلادي، مباريات، إجازات، رواتب، طقس)، وعروض وحملات المطاعم المنافسة الكبيرة في السعودية.
2) اختر أقوى 4 إلى 6 ترندات حقيقية وحديثة (من آخر أيام) مع رابط المصدر.
3) اكتب 6 أفكار تسويقية عملية تنفذ اليوم بميزانية بسيطة، تربط الترندات وأرقام المبيعات المرفقة بالمطعمين.
القواعد: لا تخترع ترند أو رابط — إذا ما لقيت مصدر لا تذكره. لهجة سعودية. لا تكرر الأفكار السابقة. استفد من الأفكار اللي عجبتهم وابتعد عن اللي ما عجبتهم.
لما تخلص البحث، احفظ النتيجة باستدعاء الأداة save_ideas مرة وحدة (6 أفكار و4-6 ترندات). لا تكتب النتيجة كنص.`;

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const parse = (t: string) => { const a = t.indexOf("{"), b = t.lastIndexOf("}"); if (a < 0 || b <= a) return null; const c = t.slice(a, b + 1); try { return JSON.parse(c); } catch { try { return JSON.parse(c.replace(/,\s*([}\]])/g, "$1").replace(/[\r\n]+/g, " ")); } catch { return null; } } };
const STR = { type: "string" };
const SAVE_TOOL = { name: "save_ideas", description: "يحفظ ترندات وأفكار اليوم في المنصة", input_schema: { type: "object", required: ["occasion", "trends", "ideas"], properties: {
  occasion: { type: "string", description: "طابع أو مناسبة اليوم بجملة" },
  trends: { type: "array", items: { type: "object", required: ["title"], properties: { title: STR, what: STR, source: { type: "string", description: "رابط المصدر" }, use: { type: "string", description: "كيف نستغله للشادن أو الباتشينو" } } } },
  ideas: { type: "array", items: { type: "object", required: ["title", "idea"], properties: { title: STR, brand: { type: "string", description: "الشادن أو الباتشينو أو الكل" }, channel: STR, idea: STR, caption: { type: "string", description: "نص منشور جاهز باللهجة السعودية مع إيموجي وهاشتاقات" }, when: STR, cost: { type: "string", description: "بدون تكلفة أو منخفضة أو متوسطة" }, why: STR } } },
} } };
const s = (v: unknown, n: number) => String(v ?? "").slice(0, n);
const SYSTEM_INF = `أنت مسؤول تسويق لمطاعم في المدينة المنورة: «مطاعم الشادن» (رز ومشويات ووجبات عائلية) و«بروست الباتشينو» (بروست ودجاج مقلي — فئة الشباب).
المطلوب الآن قائمة **مؤثرين حقيقيين** (بلوقرز / صنّاع محتوى) متخصصين في الأكل والمطاعم والفعاليات، جمهورهم في **المدينة المنورة** و**جدة**، ينفعون للتعاون والتعريف بالبراندين قبل دخول جدة.
ابحث في الإنترنت (تيك توك، سناب شات، انستقرام، إكس، يوتيوب، ومقالات «أشهر مشاهير الأكل في المدينة/جدة») واختر 8 إلى 12 مؤثر قوي: نصفهم تقريباً في المدينة ونصفهم في جدة.
القواعد الصارمة: لا تخترع أي اسم أو حساب أو رابط. كل مؤثر لازم يكون له رابط حساب حقيقي لقيته في البحث (url). عدد المتابعين اكتبه تقريبي كما ظهر في المصدر (مثل «1.2 مليون»)، وإذا ما تأكدت اتركه فارغ. لا تكرر الحسابات الموجودة عندنا.
لكل مؤثر: ليش يناسبنا بجملة، وفكرة تعاون محددة (زيارة، تحدي، تجربة منيو، إعلان سناب…). لهجة سعودية.
لما تخلص البحث احفظ القائمة باستدعاء الأداة save_influencers مرة وحدة. لا تكتب النتيجة كنص.`;
const INF_TOOL = { name: "save_influencers", description: "يحفظ قائمة المؤثرين", input_schema: { type: "object", required: ["influencers"], properties: {
  influencers: { type: "array", items: { type: "object", required: ["name", "platform", "url", "city"], properties: {
    name: STR, handle: { type: "string", description: "اسم المستخدم بدون @" }, platform: { type: "string", enum: ["tiktok", "snapchat", "instagram", "x", "youtube"] },
    url: { type: "string", description: "رابط الحساب الحقيقي" }, city: { type: "string", enum: ["madinah", "jeddah"] }, followers: { type: "string", description: "تقريبي كما في المصدر" },
    niche: { type: "string", description: "مثل: تجارب مطاعم، طبخ، فعاليات" }, why: STR, idea: { type: "string", description: "فكرة تعاون محددة" } } } } } } };


async function agent(key: string, system: string, user: string, tool: Record<string, unknown>, uses: number) {
  let model = MODEL;
  // deno-lint-ignore no-explicit-any
  const msgs: any[] = [{ role: "user", content: user }];
  const tools = [{ type: "web_search_20250305", name: "web_search", max_uses: uses, user_location: { type: "approximate", city: "Medina", region: "Al Madinah", country: "SA", timezone: "Asia/Riyadh" } }, tool];
  for (let i = 0; i < 5; i++) {
    const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model, max_tokens: 12000, system, messages: msgs, tools }) });
    if (r.ok) {
      const j = await r.json();
      // deno-lint-ignore no-explicit-any
      const cont: any[] = j.content || [];
      const tu = cont.find((c) => c.type === "tool_use" && c.name === tool.name);
      if (tu && tu.input && typeof tu.input === "object") return tu.input as Record<string, unknown>;
      if (j.stop_reason === "pause_turn") { msgs.push({ role: "assistant", content: cont }); continue; }
      const txt = cont.filter((c) => c.type === "text").map((c) => c.text).join("");
      const o = parse(txt); if (!o) console.error("parse fail", j.stop_reason, txt.slice(0, 300)); return o;
    }
    const t = await r.text(); console.error("upstream", model, r.status, t.slice(0, 300));
    if ((r.status === 404 || (r.status === 400 && /model/i.test(t))) && model !== FALLBACK) model = FALLBACK;
    else if ([429, 500, 502, 503, 529].includes(r.status)) await new Promise((ok) => setTimeout(ok, 3000 * (i + 1)));
    else return null;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: true });
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  const sb = Deno.env.get("SUPABASE_URL");
  if (!key || !sb) return json({ error: "no_key" }, 500);
  let b: { mode?: string; have?: unknown; day?: string; token?: string; apikey?: string; facts?: unknown; prev?: unknown; liked?: unknown; disliked?: unknown };
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const { day, token, apikey } = b;
  if (!token || !apikey || (!day && b.mode !== "inf")) return json({ error: "bad_request" }, 400);
  const rpc = async (fn: string, args: unknown) => {
    const r = await fetch(`${sb}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey, "Content-Type": "application/json" }, body: JSON.stringify(args) });
    const t = await r.text(); if (!r.ok) throw new Error(`${fn} ${r.status} ${t.slice(0, 200)}`); return t ? JSON.parse(t) : null;
  };
  const work = async () => {
    if (!(await rpc("brief_auth", { p_token: token }))) { console.error("unauthorized"); return; }
    const user = `اليوم ${day}. أرقام مبيعات أمس والشهر:\n${JSON.stringify(b.facts || {}).slice(0, 30000)}\n\nأفكار سابقة لا تكررها: ${JSON.stringify(b.prev || []).slice(0, 4000)}\nأفكار عجبتهم: ${JSON.stringify(b.liked || []).slice(0, 2000)}\nأفكار ما عجبتهم: ${JSON.stringify(b.disliked || []).slice(0, 2000)}\n\nابحث الحين، وبعدها احفظ النتيجة بالأداة save_ideas.`;
    const out = await agent(key, SYSTEM, user, SAVE_TOOL, 6);
    if (!out) return;
    const ideas = (Array.isArray(out.ideas) ? out.ideas : []).slice(0, 8).map((x: Record<string, unknown>) => ({ title: s(x.title, 120), brand: s(x.brand, 30), channel: s(x.channel, 40), idea: s(x.idea, 700), caption: s(x.caption, 900), when: s(x.when, 80), cost: s(x.cost, 40), why: s(x.why, 300) })).filter((x) => x.title && x.idea);
    const trends = (Array.isArray(out.trends) ? out.trends : []).slice(0, 8).map((x: Record<string, unknown>) => ({ title: s(x.title, 120), what: s(x.what, 300), source: /^https?:\/\//.test(s(x.source, 500)) ? s(x.source, 500) : "", use: s(x.use, 300) })).filter((x) => x.title);
    if (!ideas.length) { console.error("no ideas"); return; }
    await rpc("mkt_srv_save", { p_token: token, p_day: day, p_occasion: s(out.occasion, 200), p_items: ideas, p_trends: trends });
    console.log("mkt saved", day, ideas.length, trends.length);
  };
  const workInf = async () => {
    if (!(await rpc("brief_auth", { p_token: token }))) { console.error("unauthorized"); return; }
    const user = `الحسابات الموجودة عندنا (لا تكررها): ${JSON.stringify(b.have || []).slice(0, 4000)}\n\nابحث الحين، وبعدها احفظ القائمة بالأداة save_influencers.`;
    const out = await agent(key, SYSTEM_INF, user, INF_TOOL, 8);
    if (!out) return;
    const P = ["tiktok", "snapchat", "instagram", "x", "youtube"];
    const items = (Array.isArray(out.influencers) ? out.influencers : []).slice(0, 15).map((x: Record<string, unknown>) => ({ name: s(x.name, 80), handle: s(x.handle, 60).replace(/^@/, ""), platform: P.includes(s(x.platform, 20)) ? s(x.platform, 20) : "instagram",
      url: /^https?:\/\//.test(s(x.url, 300)) ? s(x.url, 300) : "", city: s(x.city, 10) === "jeddah" ? "jeddah" : "madinah", followers: s(x.followers, 30), niche: s(x.niche, 60), why: s(x.why, 300), idea: s(x.idea, 400) })).filter((x) => x.name && x.url);
    if (!items.length) { console.error("no influencers"); return; }
    const n = await rpc("mkt_inf_srv_add", { p_token: token, p_items: items });
    console.log("inf saved", items.length, n);
  };
  const p = (b.mode === "inf" ? workInf() : work()).catch((e) => console.error("mkt failed", String((e as Error).message || e)));
  // deno-lint-ignore no-explicit-any
  const ER = (globalThis as any).EdgeRuntime;
  if (ER && typeof ER.waitUntil === "function") { ER.waitUntil(p); return json({ ok: true, queued: true }, 202); }
  await p; return json({ ok: true });
});
