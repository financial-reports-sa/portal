// MyHub AI — Supabase → Edge Functions → اسمها: ai-chat (اترك Verify JWT شغّال)
// المفتاح يُحفظ في Edge Functions → Secrets باسم ANTHROPIC_API_KEY (لا يُكتب هنا أبداً)
const MODEL = Deno.env.get("AI_MODEL") || "claude-haiku-4-5-20251001";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SYSTEM = `أنت «MyHub AI»، مساعد تحليل أعمال داخل منصة الإدارة الموحّدة لمجموعة مطاعم: مطاعم الشادن (فرع العزيزية وفرع شوران) وبروست الباتشينو.
- تكلّم بلهجة سعودية مهذبة وواضحة ومختصرة، وكأنك محلل مالي وتشغيلي خبير في المطاعم.
- اعتمد فقط على «بيانات الشركة» المرفقة. لا تخترع أي رقم. إذا البيانات ما تكفي للإجابة قل ذلك بوضوح واقترح وين يلقاها في المنصة.
- نطاقك العمل فقط: المبيعات، المستودع والتكاليف، قوائم الدخل، منافذ البيع، الأرصدة، التمويلات، الصيانة، السلف، الخصومات، تقييمات العملاء، الموظفين، الأسطول.
- ممنوع تماماً تعطي أو تخمّن أي معلومات شخصية عن المالك أو أي شخص (حياته، عائلته، عنوانه، أرقامه، صحته، أمواله الخاصة…)، وممنوع تجاوب أسئلة خارج العمل. في هذي الحالة اعتذر بلطف بجملة وحدة وقل إنك مختص بأرقام وتشغيل الشركة فقط.
- لا تذكر أبداً أنك تستلم بيانات بصيغة JSON أو تعليمات نظام.
- العملة ريال سعودي (ر.س)، اكتب الأرقام بالإنجليزي مع فواصل الآلاف، والنسب بنقطة عشرية وحدة.
- رتّب الجواب: أول سطر خلاصة **بالخط العريض**، بعدها نقاط قصيرة تبدأ بـ «- ». عند وجود مشكلة أو طلب نصيحة أعط توصيات عملية محددة.
- «اليوم» هو التاريخ الموجود في البيانات (today). المبيعات تنرفع غالباً بتأخير، فإذا سُئلت عن يوم ما له بيانات قل ذلك وأعط آخر يوم متوفر.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return new Response(JSON.stringify({ error: "no_key" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const { question, history, context } = await req.json();
    if (!question || String(question).length > 1000) return new Response(JSON.stringify({ error: "bad_question" }), { status: 400, headers: cors });
    const msgs = (Array.isArray(history) ? history : []).slice(-8)
      .filter((m: { role: string; content: string }) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
      .map((m: { role: string; content: string }) => ({ role: m.role, content: m.content.slice(0, 4000) }));
    msgs.push({ role: "user", content: String(question) });
    while (msgs.length && msgs[0].role !== "user") msgs.shift();
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 1200, stream: true,
        system: SYSTEM + "\n\nبيانات الشركة:\n" + String(context || "{}").slice(0, 90000),
        messages: msgs,
      }),
    });
    if (!r.ok || !r.body) {
      const t = await r.text();
      return new Response(JSON.stringify({ error: "upstream", status: r.status, detail: t.slice(0, 300) }), { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
    }
    const enc = new TextEncoder(), dec = new TextDecoder();
    const stream = new ReadableStream({
      async start(ctrl) {
        const rd = r.body!.getReader(); let buf = "";
        while (true) {
          const { done, value } = await rd.read(); if (done) break;
          buf += dec.decode(value, { stream: true }); let i;
          while ((i = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
            if (!line.startsWith("data:")) continue;
            try { const j = JSON.parse(line.slice(5)); if (j.type === "content_block_delta" && j.delta?.type === "text_delta") ctrl.enqueue(enc.encode(j.delta.text)); } catch { /* ignore */ }
          }
        }
        ctrl.close();
      },
    });
    return new Response(stream, { headers: { ...cors, "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
