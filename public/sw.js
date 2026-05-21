// Minimal service worker. Caches the app shell so the PWA is installable.
// Never intercepts /api/* or /artwork/* or audio Range requests — Safari's
// audio element does its own Range handling and SW interception breaks seeking.
//
// All paths here are scope-relative: the SW's scope is derived from its own
// URL, so the same code works whether the app is mounted at "/" or "/pod".

const VERSION = 'v1';
// Resolved against the SW's URL (e.g. /sw.js or /pod/sw.js), so these become
// /app.js or /pod/app.js automatically.
const SHELL = ['./', 'app.js', 'styles.css', 'manifest.webmanifest',
               'icons/icon-192.png', 'icons/icon-512.png'];

// Pathname of the SW's scope, always ending in "/". e.g. "/" or "/pod/".
const SCOPE_PATH = new URL(self.registration.scope).pathname;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith(SCOPE_PATH + 'api/'))     return;
  if (url.pathname.startsWith(SCOPE_PATH + 'artwork/')) return;

  event.respondWith((async () => {
    const cache = await caches.open(VERSION);
    const cached = await cache.match(req);
    const network = fetch(req).then(res => {
      if (res.ok && req.method === 'GET') cache.put(req, res.clone()).catch(() => {});
      return res;
    }).catch(() => cached);
    return cached || network;
  })());
});
