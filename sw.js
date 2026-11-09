/* by viral — service worker (offline, tolerant) */
const CACHE = 'byviral-v13';
const CORE = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
  './supabase-config.js',
  './viral-backend.js'
];

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(CACHE).then(function (c) {
      return Promise.all(CORE.map(function (u) {
        return fetch(u).then(function (r) { if (r && r.ok) return c.put(u, r); }).catch(function () {});
      }));
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) { return k !== CACHE; })
        .map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);
  /* Supabase (statistiques, comptes) et espace admin : toujours le réseau, jamais le cache */
  if (/\.supabase\.(co|in)$/.test(url.hostname)) return;
  if (url.origin === location.origin && url.pathname.indexOf('/admin/') !== -1) return;
  /* configuration : réseau d'abord (pour prendre les modifications), cache si hors ligne */
  if (url.origin === location.origin && /\/(supabase-config|viral-backend)\.js$/.test(url.pathname)) {
    e.respondWith(fetch(req).then(function (resp) {
      if (resp && resp.ok) { var c = resp.clone(); caches.open(CACHE).then(function (k) { k.put(req, c); }); }
      return resp;
    }).catch(function () { return caches.match(req, { ignoreSearch: true }); }));
    return;
  }
  e.respondWith(
    caches.match(req).then(function (hit) {
      if (hit) return hit;
      return fetch(req).then(function (resp) {
        try { var clone = resp.clone(); caches.open(CACHE).then(function (c) { c.put(req, clone); }); } catch (_) {}
        return resp;
      }).catch(function () { if (req.mode === 'navigate') return caches.match('./index.html'); });
    })
  );
});
