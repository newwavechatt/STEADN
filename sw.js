// ===========================================================================
// Service worker
// The app is one file with no external requests, so caching the shell is
// enough to make it work with no signal. That is the whole point of it.
// ===========================================================================
const CACHE = 'steadn-v1';
const SHELL = ['/', '/index.html', '/manifest.webmanifest', '/icon.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;          // never cache the advisor
  if (url.pathname.startsWith('/api/')) return;

  // Network first so a deploy is picked up, cache as the fallback so a dead
  // zone still opens the app.
  e.respondWith(
    fetch(e.request)
      .then(r => {
        const copy = r.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
        return r;
      })
      .catch(() => caches.match(e.request).then(m => m || caches.match('/index.html')))
  );
});
