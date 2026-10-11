// خدمة الخلفية لمنصة الإدارة الموحّدة — تستقبل إشعارات الجوال وتعرضها (بدون تخزين مؤقت للصفحات)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'MyHub', {
    body: d.body || '',
    icon: 'icon-192.png?v=4',
    badge: 'icon-192.png?v=4',
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
        return c.navigate(url).then((w) => (w || c).focus()).catch(() => c.focus());
      }
    }
    return self.clients.openWindow(url);
  }));
});
