/* by viral — service worker
   Règle d'or : une mise à jour publiée arrive TOUTE SEULE chez tout le monde.
   - la page (index.html) vient toujours du réseau ; le cache ne sert que hors ligne ;
   - à chaque nouvelle version de ce fichier, l'ancien cache est supprimé et les
     pages ouvertes sont rechargées automatiquement (aucune action de l'utilisateur). */
const CACHE = 'byviral-v36';
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
        /* cache:'reload' : jamais la copie du cache HTTP du navigateur */
        return fetch(u, { cache: 'reload' }).then(function (r) { if (r && r.ok) return c.put(u, r); }).catch(function () {});
      }));
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      var anciens = keys.filter(function (k) { return k !== CACHE; });
      return Promise.all(anciens.map(function (k) { return caches.delete(k); })).then(function () { return anciens.length > 0; });
    }).then(function (miseAJour) {
      return self.clients.claim().then(function () {
        if (!miseAJour) return;                       /* première installation : rien à recharger */
        /* mise à jour : les pages déjà ouvertes affichent l'ancienne version → on les recharge */
        return self.clients.matchAll({ type: 'window' }).then(function (cs) {
          cs.forEach(function (c) {
            try { if (c.navigate) { c.navigate(c.url).catch(function () { c.postMessage({ type: 'viral-maj' }); }); } else c.postMessage({ type: 'viral-maj' }); }
            catch (_) { try { c.postMessage({ type: 'viral-maj' }); } catch (__) {} }
          });
        });
      });
    })
  );
});

function depuisReseau(url) {
  /* on repart de l'adresse (et non de la requête de navigation, que certains
     Safari refusent de copier) et on contourne tout cache HTTP */
  return fetch(new Request(url, { cache: 'no-store', credentials: 'same-origin' }));
}

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);
  /* Supabase (statistiques, comptes) et espace admin : toujours le réseau, jamais le cache */
  if (/\.supabase\.(co|in)$/.test(url.hostname)) return;
  if (url.origin === location.origin && url.pathname.indexOf('/admin/') !== -1) return;
  /* numéro de version : toujours le réseau, jamais mis en cache */
  if (url.origin === location.origin && /\/version\.json$/.test(url.pathname)) return;
  /* configuration : réseau d'abord, cache si hors ligne */
  if (url.origin === location.origin && /\/(supabase-config|viral-backend)\.js$/.test(url.pathname)) {
    e.respondWith(fetch(req).then(function (resp) {
      if (resp && resp.ok) { var c = resp.clone(); caches.open(CACHE).then(function (k) { k.put(req, c); }); }
      return resp;
    }).catch(function () { return caches.match(req, { ignoreSearch: true }); }));
    return;
  }
  /* la page : réseau d'abord (dernière version publiée), copie pour le hors ligne */
  if (url.origin === location.origin && (req.mode === 'navigate' || /\/(index\.html)?$/.test(url.pathname))) {
    e.respondWith(depuisReseau(url.href).then(function (resp) {
      if (resp && resp.ok) { var c = resp.clone(); caches.open(CACHE).then(function (k) { k.put('./index.html', c); }); }
      return resp;
    }).catch(function () { return caches.match('./index.html').then(function (h) { return h || caches.match(req, { ignoreSearch: true }); }); }));
    return;
  }
  /* le reste (images, modèles 3D, polices) : cache d'abord, réseau sinon */
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
