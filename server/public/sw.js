const CACHE = 'dev-dock-v7';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  // Wipe EVERY old cache — the previous versions precached '/', which is what
  // kept serving the stale (old-design) app shell after updates.
  const keys = await caches.keys();
  await Promise.all(keys.map((k) => caches.delete(k)));
  await self.clients.claim();
  // Force any already-open window to reload to the fresh HTML, so an installed
  // PWA that was showing the old version updates itself without a manual reload.
  const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  for (const w of wins) { try { await w.navigate(w.url); } catch (_) {} }
})()));
// Network-first, and refresh the cached shell on every successful load so even
// the offline fallback is the latest design (never a stale snapshot).
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  // Only ever touch same-origin requests. Cross-origin resources (and the
  // WebSocket upgrade) must pass straight through to the network untouched —
  // if we intercepted e.g. a CDN script and the fetch failed, the catch below
  // used to hand back the HTML shell, which then parsed as a broken script and
  // silently killed the terminal (xterm) and the file viewer (highlight.js).
  if (url.origin !== self.location.origin) return;
  const isNavigate = e.request.mode === 'navigate';
  e.respondWith((async () => {
    try {
      const res = await fetch(e.request);
      if (isNavigate || url.pathname === '/') {
        const c = await caches.open(CACHE); c.put('/', res.clone());
      }
      return res;
    } catch (_) {
      // Offline: serve a cached copy if we have one; only fall back to the app
      // shell for a *navigation* (never for a script/style/asset, so we never
      // return HTML where JS/CSS was expected).
      const hit = await caches.match(e.request);
      if (hit) return hit;
      if (isNavigate) { const shell = await caches.match('/'); if (shell) return shell; }
      return Response.error();
    }
  })());
});

// --- Web Push: a turn finished, or a tool needs approval -------------------
// Show an OS banner only when the app isn't already in the foreground (an
// in-app toast already covers that case). Still shows if we can't tell.
self.addEventListener('push', (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch (_) {}
  const title = data.title || 'dev-dock';
  const body = data.body || '';
  const tag = data.tag || 'dev-dock';
  const url = data.url || '/';
  e.waitUntil((async () => {
    const clientList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const focused = clientList.some((c) => c.visibilityState === 'visible' || c.focused);
    if (focused) {
      // Let the page handle it (toast/beep) instead of an OS banner.
      for (const c of clientList) c.postMessage({ type: 'push', title, body, tag });
      return;
    }
    await self.registration.showNotification(title, {
      body, tag, renotify: true, icon: '/icon-192.png', badge: '/icon-192.png',
      data: { url },
    });
  })());
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil((async () => {
    const clientList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of clientList) { if ('focus' in c) { try { await c.focus(); return; } catch (_) {} } }
    if (self.clients.openWindow) await self.clients.openWindow(url);
  })());
});
