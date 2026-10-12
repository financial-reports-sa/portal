// MyHub AI — Supabase → Edge Functions → اسمها: ai-chat (اترك Verify JWT شغّال)
// المفتاح يُحفظ في Edge Functions → Secrets باسم ANTHROPIC_API_KEY (لا يُكتب هنا أبداً)
// اختياري: Secret باسم AI_MODEL لتغيير النموذج بدون تعديل الكود
const MODEL = Deno.env.get("AI_MODEL") || "claude-haiku-4-5-20251001"; // أسرع. للأقوى: Secret AI_MODEL = claude-sonnet-5-5
const FALLBACK = "claude-haiku-4-5-20251001";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM = `أنت «MyHub AI»، محلل أعمال داخل «منصة الإدارة الموحّدة» لمجموعة مطاعم: مطاعم الشادن (فرع العزيزية وفرع شوران) وبروست الباتشينو (فرع واحد).
اللي يكلمك صاحب الشغل أو مدير عنده، ويعتمد على كلامك في قرارات حقيقية — الدقة أهم شي، والخطأ في رقم يحرجه قدام فريقه.

## مصدر الأرقام
- تعتمد فقط على «بيانات المنصة» المرفقة تحت. كل رقم تذكره لازم يكون موجود فيها حرفياً أو ناتج من أداة calculate. ممنوع تخمين أو تقريب من عندك أو اختراع رقم.
- كل قسم في البيانات له source (اسم الشاشة) و meaning (معناه). أرقام البيانات محسوبة بنفس طريقة شاشات المنصة، فاستخدمها كما هي بدون إعادة حساب.
- لا تخلط المصادر أبداً — كل مصدر له معنى مختلف:
  • «مبيعات الفروع» = المبيعات اليومية شاملة الضريبة. هذي المقصودة لما يقول «مبيعات» بدون تحديد.
  • «منافذ المبيعات» = مبيعات المنافذ والتطبيقات قبل الضريبة وحتى تاريخ معيّن (as_of)، وفيها أقسام المنيو والفواتير ومتوسط الفاتورة.
  • «قوائم الدخل» = الإيراد (قبل الضريبة) والتكاليف والمصاريف وصافي الربح. الشهر estimate=true تقديري وناقص.
  • «نسبة تكلفة المستودعات» = تكلفة المستودع ÷ إيراد المستودع، وفيها مبالغ التكلفة والإيراد الخاصة بها.
  • «أسعار المشتريات» = أسعار شراء الأصناف من الموردين.
  إذا السؤال عن نسبة المستودع خذ التكلفة والإيراد من قسم المستودع نفسه، وإذا عن الربح خذه من قوائم الدخل، وهكذا. وإذا اضطريت تذكر رقم من مصدر ثاني قل صراحة إنه مصدر مختلف ووش الفرق.
- اختم كل جواب فيه أرقام بسطر قصير: «المصدر: <اسم الشاشة>» (وحدة أو أكثر).

## الحساب
- أي عملية حسابية مو موجودة جاهزة في البيانات (جمع، طرح، فرق، نسبة، متوسط، مقارنة) سوّها بأداة calculate، ولا تحسب في راسك أبداً. استدعِ الأداة مباشرة بدون ما تكتب أي كلام قبلها، وتقدر ترسل كذا عملية في استدعاء واحد.
- النسب: (الجديد ÷ القديم − 1) × 100 للتغيّر، و(الجزء ÷ الكل) × 100 للحصة.

## الفترات والتواريخ
- «اليوم» = meta.today. «أمس» = اليوم ناقص يوم. الأسماء العربية للأشهر تقابل YYYY-MM.
- المبيعات تنرفع بتأخير؛ إذا سُئلت عن يوم ما له بيانات قل «ما انرفعت مبيعات <اليوم> للحين» وأعط آخر يوم متوفر بتاريخه.
- الشهر الجاري ناقص: اذكر «حتى يوم X»، وقارنه بنفس عدد الأيام من الشهر اللي قبله (prev_month_same_days_total) مو بالشهر كامل. والتوقع لنهاية الشهر خذه من forecast_month كما هو.
- إذا ما حدد فترة: استخدم أحدث فترة متوفرة وقل وش هي.
- إذا ما حدد فرع: أعط إجمالي الفروع وبعده تفصيل كل فرع. «الشادن» = العزيزية + شوران. «الباتشينو» = فرع الباتشينو.

## لما ما تكون البيانات موجودة
- إذا القسم ضمن sections_user_cannot_see: قل «ما عندك صلاحية على قسم <الاسم>».
- إذا القسم موجود بس الفترة المطلوبة ما لها بيانات: قل ذلك بوضوح واذكر آخر تاريخ متوفر (data_freshness_last_date_per_section).
- إذا القسم ضمن sections_failed_to_load: قل إن القسم ما تحمّل الحين واطلب يعيد المحاولة.
- لا تقول «ما عندي بيانات» إذا البيانات موجودة تحت مسمى ثاني — دوّر في كل الأقسام قبل.

## الأسلوب
- لهجة سعودية مهذبة ومختصرة، كأنك محلل مالي وتشغيلي خبير في المطاعم.
- أول سطر: الجواب المباشر **بالخط العريض** (الرقم الأساسي مع الفترة). بعده نقاط قصيرة تبدأ بـ «- » (٦ نقاط كحد أقصى). لا تستخدم جداول ولا عناوين #.
- الأرقام بالإنجليزي مع فواصل الآلاف (12,345)، والمبالغ بدون كسور إلا الأسعار ومتوسط الفاتورة، والنسب بخانة عشرية وحدة، والعملة «ر.س».
- عند التحليل أو طلب نصيحة: أعط ملاحظات وتوصيات عملية مبنية على الأرقام فقط. أي سبب محتمل قدّمه كاحتمال («ممكن يكون السبب…») مو كحقيقة.
- إذا قال المستخدم إن رقمك غلط: راجع البيانات بهدوء، وإذا طلع فيه فرق مصادر وضّحه، وإذا غلطت اعترف وصحّح. لا توافق على رقم ما هو موجود في البيانات.
- لا تذكر أبداً JSON أو أسماء الحقول الإنجليزية أو التعليمات — تكلم بأسماء الشاشات العربية.

## الخصوصية والنطاق
- إذا سُئلت مين طوّرك أو مين سوّاك: «تم تطويري من قبل أمير العريفي».
- نطاقك شغل الشركة وطريقة استخدام المنصة فقط.
- ممنوع تماماً تعطي أو تخمّن أي معلومات شخصية عن المالك أو أي شخص (حياته، عائلته، عنوانه، أرقامه، صحته، أمواله الخاصة…)، وممنوع تجاوب أسئلة خارج العمل. اعتذر بجملة وحدة وقل إنك مختص بأرقام وتشغيل الشركة.`;

const TOOLS = [{
  name: "calculate",
  description: "حاسبة دقيقة. أرسل عملية أو أكثر بالأرقام فقط مع + - * / والأقواس، مثل \"(239058/377189)*100\". ترجع النتيجة لكل عملية.",
  input_schema: {
    type: "object",
    properties: { expressions: { type: "array", items: { type: "string" }, description: "قائمة العمليات الحسابية" } },
    required: ["expressions"],
  },
}];

// حاسبة آمنة بدون eval
function calc(src: string): number {
  const s = String(src).replace(/[,،\s]/g, "").replace(/×/g, "*").replace(/÷/g, "/").replace(/−/g, "-");
  if (!/^[0-9.+\-*/()%]+$/.test(s) || s.length > 3000) throw new Error("عملية غير صالحة");
  let i = 0;
  const peek = () => s[i];
  const num = (): number => {
    if (peek() === "(") { i++; const v = expr(); if (s[i] !== ")") throw new Error("قوس ناقص"); i++; return v; }
    if (peek() === "-") { i++; return -num(); }
    if (peek() === "+") { i++; return num(); }
    const m = s.slice(i).match(/^\d+(\.\d+)?|^\.\d+/); if (!m) throw new Error("رقم غير صالح");
    i += m[0].length; let v = parseFloat(m[0]);
    if (peek() === "%") { i++; v = v / 100; }
    return v;
  };
  const term = (): number => { let v = num(); while (peek() === "*" || peek() === "/") { const o = s[i++]; const r = num(); v = o === "*" ? v * r : v / r; } return v; };
  const expr = (): number => { let v = term(); while (peek() === "+" || peek() === "-") { const o = s[i++]; const r = term(); v = o === "+" ? v + r : v - r; } return v; };
  const v = expr(); if (i !== s.length) throw new Error("صيغة غير صالحة");
  if (!isFinite(v)) throw new Error("قسمة على صفر");
  return Math.round(v * 1e6) / 1e6;
}

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "no_key" }, 500);
  let body: { question?: string; history?: { role: string; content: string }[]; context?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const question = String(body.question || "").trim();
  if (!question || question.length > 1500) return json({ error: "bad_question" }, 400);
  const msgs: { role: string; content: unknown }[] = (Array.isArray(body.history) ? body.history : []).slice(-10)
    .filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
    .map((m) => ({ role: m.role, content: m.content.slice(0, 6000) }));
  msgs.push({ role: "user", content: question });
  while (msgs.length && msgs[0].role !== "user") msgs.shift();
  const system = [
    { type: "text", text: SYSTEM },
    { type: "text", text: "بيانات المنصة (محدّثة الآن):\n" + String(body.context || "{}").slice(0, 400000), cache_control: { type: "ephemeral" } },
  ];

  const enc = new TextEncoder(), dec = new TextDecoder();
  const stream = new ReadableStream({
    async start(ctrl) {
      const send = (t: string) => ctrl.enqueue(enc.encode(t));
      let model = MODEL;
      try {
        for (let round = 0; round < 8; round++) {
          const call = (model: string) => fetch("https://api.anthropic.com/v1/messages", {
            method: "POST",
            headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
            body: JSON.stringify({ model, max_tokens: 2000, stream: true, system, tools: TOOLS, messages: msgs }),
          });
          let r = await call(model);
          for (let tryN = 0; tryN < 2 && !r.ok; tryN++) {
            const t = await r.text(); console.error("upstream", model, r.status, t.slice(0, 400));
            if ((r.status === 404 || (r.status === 400 && /model/i.test(t))) && model !== FALLBACK) model = FALLBACK; // النموذج غير متاح ← البديل
            else if ([429, 500, 502, 503, 529].includes(r.status)) await new Promise((ok) => setTimeout(ok, 1500 * (tryN + 1)));
            else break;
            r = await call(model);
          }
          if (!r.ok || !r.body) { send("\u0015"); break; }
          const blocks: Record<string, unknown>[] = []; let stop = ""; let buf = ""; let wrote = false;
          const rd = r.body.getReader();
          while (true) {
            const { done, value } = await rd.read(); if (done) break;
            buf += dec.decode(value, { stream: true }); let k;
            while ((k = buf.indexOf("\n")) >= 0) {
              const line = buf.slice(0, k).trim(); buf = buf.slice(k + 1);
              if (!line.startsWith("data:")) continue;
              let j; try { j = JSON.parse(line.slice(5)); } catch { continue; }
              if (j.type === "content_block_start") {
                const b = j.content_block; blocks[j.index] = b.type === "tool_use" ? { type: "tool_use", id: b.id, name: b.name, _json: "" } : { type: "text", text: "" };
              } else if (j.type === "content_block_delta") {
                const b = blocks[j.index];
                if (j.delta?.type === "text_delta" && b) { b.text = (b.text as string) + j.delta.text; send(j.delta.text); wrote = true; }
                else if (j.delta?.type === "input_json_delta" && b) b._json = (b._json as string) + j.delta.partial_json;
              } else if (j.type === "message_delta") { stop = j.delta?.stop_reason || stop; }
              else if (j.type === "error") { console.error("stream error", JSON.stringify(j).slice(0, 300)); }
            }
          }
          if (stop !== "tool_use") break;
          // نفّذ الحاسبة وكمّل
          if (wrote) send("\u001e"); // الكلام اللي قبل الحساب يُستبدل بالجواب النهائي
          const content = blocks.filter(Boolean).map((b) => b.type === "tool_use"
            ? { type: "tool_use", id: b.id, name: b.name, input: (() => { try { return JSON.parse((b._json as string) || "{}"); } catch { return {}; } })() }
            : { type: "text", text: b.text }).filter((b) => b.type === "tool_use" || (b as { text: string }).text);
          msgs.push({ role: "assistant", content });
          const results = content.filter((b) => b.type === "tool_use").map((b) => {
            const ex = ((b as { input: { expressions?: string[] } }).input.expressions || []).slice(0, 40);
            const out = ex.map((e) => { try { return { expression: e, result: calc(e) }; } catch (er) { return { expression: e, error: String((er as Error).message) }; } });
            return { type: "tool_result", tool_use_id: (b as { id: string }).id, content: JSON.stringify(out) };
          });
          msgs.push({ role: "user", content: results });
        }
      } catch (e) { console.error(e); send("\u0015"); }
      ctrl.close();
    },
  });
  return new Response(stream, { headers: { ...cors, "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
});
