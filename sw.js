// خدمة الخلفية لمنصة الإدارة الموحّدة — إشعارات الجوال + تسريع التحميل
// الصفحة: من الشبكة أولاً (نسخة محفوظة لو النت بطيء/مقطوع) · المكتبات والخطوط والملفات المرقّمة: من الذاكرة أولاً
const CACHE = 'myhub-v3';
const CDN = ['cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'fonts.googleapis.com', 'fonts.gstatic.com', 'unpkg.com'];

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  const keys = await caches.keys();
  await Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)));
  await self.clients.claim();
})()));

const put = async (req, res) => { try { if (res && (res.ok || res.type === 'opaque')) { const c = await caches.open(CACHE); await c.put(req, res); } } catch (_) {} };

async function cacheFirst(req) {
  const hit = await caches.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  put(req, res.clone());
  return res;
}

async function networkFirst(req, ms) {
  const c = await caches.open(CACHE);
  const net = fetch(req).then((res) => { if (res.ok) c.put(req, res.clone()).catch(() => {}); return res; });
  const timer = new Promise((r) => setTimeout(r, ms));
  try {
    const first = await Promise.race([net, timer.then(() => null)]);
    if (first) return first;
    const hit = await c.match(req, { ignoreSearch: true });
    return hit || await net;
  } catch (e) {
    const hit = await c.match(req, { ignoreSearch: true });
    if (hit) return hit;
    throw e;
  }
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (CDN.includes(u.hostname)) { e.respondWith(cacheFirst(req)); return; }
  if (u.origin !== self.location.origin) return;               // Supabase وغيره: مباشر بدون تخزين
  if (req.mode === 'navigate') { e.respondWith(networkFirst(req, 4000)); return; }
  if (u.searchParams.has('v')) { e.respondWith(cacheFirst(req)); return; }   // ملفات مرقّمة بالإصدار
  if (/\.(png|svg|css|js|json)$/.test(u.pathname)) e.respondWith(networkFirst(req, 3000));
});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'منصة الإدارة الموحّدة', {
    body: d.body || '',
    icon: 'icon-192.png?v=4',
    badge: 'badge.png?v=1',
    dir: 'rtl',
    lang: 'ar',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((cs) => {
    for (const c of cs) {
      if (c.url.startsWith(self.registration.scope) && 'focus' in c) {
        c.postMessage({ type: 'nav', url });
        return c.focus().catch(() => {});
      }
    }
    return self.clients.openWindow(url);
  }));
});
