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
الرد النهائي JSON فقط بدون أي كلام قبله أو بعده بهذا الشكل:
{"occasion":"طابع أو مناسبة اليوم بجملة","trends":[{"title":"اسم الترند","what":"وش هو بجملة","source":"رابط المصدر","use":"كيف نستغله للشادن أو الباتشينو بجملة"}],"ideas":[{"title":"عنوان قصير","brand":"الشادن أو الباتشينو أو الكل","channel":"القناة","idea":"وش نسوي بالضبط بجملتين أو ثلاث","caption":"نص منشور جاهز باللهجة السعودية مع إيموجي وهاشتاقات","when":"أفضل وقت","cost":"بدون تكلفة أو منخفضة أو متوسطة","why":"ليش اليوم — مبني على ترند أو رقم"}]}`;

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const parse = (t: string) => { const a = t.indexOf("{"), b = t.lastIndexOf("}"); if (a < 0 || b <= a) return null; try { return JSON.parse(t.slice(a, b + 1)); } catch { return null; } };
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
    const user = `اليوم ${day}. أرقام مبيعات أمس والشهر:\n${JSON.stringify(b.facts || {}).slice(0, 30000)}\n\nأفكار سابقة لا تكررها: ${JSON.stringify(b.prev || []).slice(0, 4000)}\nأفكار عجبتهم: ${JSON.stringify(b.liked || []).slice(0, 2000)}\nأفكار ما عجبتهم: ${JSON.stringify(b.disliked || []).slice(0, 2000)}\n\nابحث الحين واكتب الرد JSON فقط.`;
    let model = MODEL, out: Record<string, unknown> | null = null;
    for (let i = 0; i < 3 && !out; i++) {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model, max_tokens: 6000, system: SYSTEM, messages: [{ role: "user", content: user }],
          tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 6, user_location: { type: "approximate", city: "Medina", region: "Al Madinah", country: "SA", timezone: "Asia/Riyadh" } }] }),
      });
      if (r.ok) {
        const j = await r.json();
        const txt = (j.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
        out = parse(txt); if (!out) console.error("parse fail", txt.slice(0, 300)); break;
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
