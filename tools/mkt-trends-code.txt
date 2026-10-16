// الأفكار التسويقية والترندات اليومية — Supabase → Edge Functions → اسمها: mkt-trends (Verify JWT: OFF)
// القاعدة تستدعيها كل صباح (وزر «تحديث» للإدارة) ← تبحث في الإنترنت عن ترندات اليوم ← تكتب أفكار وتحفظها في المنصة
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

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: true });
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  const sb = Deno.env.get("SUPABASE_URL");
  if (!key || !sb) return json({ error: "no_key" }, 500);
  let b: { day?: string; token?: string; apikey?: string; facts?: unknown; prev?: unknown; liked?: unknown; disliked?: unknown };
  try { b = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const { day, token, apikey } = b;
  if (!day || !token || !apikey) return json({ error: "bad_request" }, 400);
  const rpc = async (fn: string, args: unknown) => {
    const r = await fetch(`${sb}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey, "Content-Type": "application/json" }, body: JSON.stringify(args) });
    const t = await r.text(); if (!r.ok) throw new Error(`${fn} ${r.status} ${t.slice(0, 200)}`); return t ? JSON.parse(t) : null;
  };
  const work = async () => {
    if (!(await rpc("brief_auth", { p_token: token }))) { console.error("unauthorized"); return; }
    const user = `اليوم ${day}. أرقام مبيعات أمس والشهر:\n${JSON.stringify(b.facts || {}).slice(0, 30000)}\n\nأفكار سابقة لا تكررها: ${JSON.stringify(b.prev || []).slice(0, 4000)}\nأفكار عجبتهم: ${JSON.stringify(b.liked || []).slice(0, 2000)}\nأفكار ما عجبتهم: ${JSON.stringify(b.disliked || []).slice(0, 2000)}\n\nابحث الحين، وبعدها احفظ النتيجة بالأداة save_ideas.`;
    let model = MODEL, out: Record<string, unknown> | null = null;
    // deno-lint-ignore no-explicit-any
    const msgs: any[] = [{ role: "user", content: user }];
    const tools = [{ type: "web_search_20250305", name: "web_search", max_uses: 6, user_location: { type: "approximate", city: "Medina", region: "Al Madinah", country: "SA", timezone: "Asia/Riyadh" } }, SAVE_TOOL];
    for (let i = 0; i < 5 && !out; i++) {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model, max_tokens: 12000, system: SYSTEM, messages: msgs, tools }),
      });
      if (r.ok) {
        const j = await r.json();
        // deno-lint-ignore no-explicit-any
        const cont: any[] = j.content || [];
        const tu = cont.find((c) => c.type === "tool_use" && c.name === "save_ideas");
        if (tu && tu.input && typeof tu.input === "object") { out = tu.input; break; }
        if (j.stop_reason === "pause_turn") { msgs.push({ role: "assistant", content: cont }); continue; }
        const txt = cont.filter((c) => c.type === "text").map((c) => c.text).join("");
        out = parse(txt); if (!out) console.error("parse fail", j.stop_reason, txt.slice(0, 300), "…", txt.slice(-200)); break;
      }
      const t = await r.text(); console.error("upstream", model, r.status, t.slice(0, 300));
      if ((r.status === 404 || (r.status === 400 && /model/i.test(t))) && model !== FALLBACK) model = FALLBACK;
      else if ([429, 500, 502, 503, 529].includes(r.status)) await new Promise((ok) => setTimeout(ok, 3000 * (i + 1)));
      else break;
    }
    if (!out) return;
    const ideas = (Array.isArray(out.ideas) ? out.ideas : []).slice(0, 8).map((x: Record<string, unknown>) => ({ title: s(x.title, 120), brand: s(x.brand, 30), channel: s(x.channel, 40), idea: s(x.idea, 700), caption: s(x.caption, 900), when: s(x.when, 80), cost: s(x.cost, 40), why: s(x.why, 300) })).filter((x) => x.title && x.idea);
    const trends = (Array.isArray(out.trends) ? out.trends : []).slice(0, 8).map((x: Record<string, unknown>) => ({ title: s(x.title, 120), what: s(x.what, 300), source: /^https?:\/\//.test(s(x.source, 500)) ? s(x.source, 500) : "", use: s(x.use, 300) })).filter((x) => x.title);
    if (!ideas.length) { console.error("no ideas"); return; }
    await rpc("mkt_srv_save", { p_token: token, p_day: day, p_occasion: s(out.occasion, 200), p_items: ideas, p_trends: trends });
    console.log("mkt saved", day, ideas.length, trends.length);
  };
  const p = work().catch((e) => console.error("mkt failed", String((e as Error).message || e)));
  // deno-lint-ignore no-explicit-any
  const ER = (globalThis as any).EdgeRuntime;
  if (ER && typeof ER.waitUntil === "function") { ER.waitUntil(p); return json({ ok: true, queued: true }, 202); }
  await p; return json({ ok: true });
});
