// MyHub AI — صوت طبيعي من Azure — Supabase → Edge Functions → اسمها: ai-tts (اترك Verify JWT شغّال)
// Secrets المطلوبة: AZURE_TTS_KEY و AZURE_TTS_REGION (مثل eastus) — لا تُكتب هنا أبداً
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const VOICES: Record<string, string> = {
  m: "ar-SA-HamedNeural", f: "ar-SA-ZariyahNeural",
  ml_m: "en-US-AndrewMultilingualNeural", ml_f: "en-US-AvaMultilingualNeural",
  ml_m2: "en-US-BrianMultilingualNeural", ml_f2: "en-US-EmmaMultilingualNeural",
  kw_m: "ar-KW-FahedNeural", kw_f: "ar-KW-NouraNeural",
  ae_m: "ar-AE-HamdanNeural", ae_f: "ar-AE-FatimaNeural",
};
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
const j = (o: unknown, s = 400) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return j({ error: "method" }, 405);
  const KEY = Deno.env.get("AZURE_TTS_KEY");
  const REGION = (Deno.env.get("AZURE_TTS_REGION") || "eastus").trim().toLowerCase();
  if (!KEY) return j({ error: "no_key" }, 500);
  let body: { text?: string; voice?: string; rate?: number } = {};
  try { body = await req.json(); } catch { return j({ error: "bad_json" }); }
  const text = String(body.text || "").replace(/\s+/g, " ").trim().slice(0, 2500);
  if (!text) return j({ error: "empty" });
  const voice = VOICES[String(body.voice || "m")] || VOICES.m;
  const rate = Math.max(-20, Math.min(20, Number(body.rate) || 0));
  const ssml = `<speak version="1.0" xml:lang="ar-SA" xmlns="http://www.w3.org/2001/10/synthesis"><voice name="${voice}">${voice.includes("Multilingual") ? `<lang xml:lang="ar-SA"><prosody rate="${rate}%">${esc(text)}</prosody></lang>` : `<prosody rate="${rate}%">${esc(text)}</prosody>`}</voice></speak>`;
  try {
    const r = await fetch(`https://${REGION}.tts.speech.microsoft.com/cognitiveservices/v1`, {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": KEY,
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "User-Agent": "myhub-ai-tts",
      },
      body: ssml,
    });
    if (!r.ok) return j({ error: "azure_" + r.status, detail: (await r.text()).slice(0, 200) }, 502);
    return new Response(r.body, { headers: { ...cors, "Content-Type": "audio/mpeg", "Cache-Control": "no-store" } });
  } catch (e) {
    return j({ error: "fetch", detail: String(e).slice(0, 200) }, 502);
  }
});
