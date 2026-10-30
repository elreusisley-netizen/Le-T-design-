/* =====================================================================
   VIRAL Design — accès à Supabase (sans bibliothèque externe)
   - Statistiques anonymes : identifiant aléatoire par appareil, aucune
     donnée personnelle, file d'attente hors ligne, désactivables.
   - Comptes facultatifs : connexion par code reçu par e-mail.
   - Utilisé par l'appli (index.html) et par l'espace admin (admin/).
   ===================================================================== */
(function(){
  var cfg = window.VIRAL_SUPABASE || {};
  var URL_ = (cfg.url || '').replace(/\/+$/, '');
  var KEY = cfg.anonKey || '';

  /* refuse toute clé secrète placée par erreur dans le site public */
  function cleSecrete(k){
    if(/^sb_secret_/.test(k)) return true;
    try{ var p = JSON.parse(atob(k.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))); return p && p.role === 'service_role'; }catch(_){ return false; }
  }
  var enabled = !!(URL_ && KEY);
  if(enabled && cleSecrete(KEY)){ enabled = false; console.error('VIRAL : clé secrète détectée dans supabase-config.js — connexion désactivée. Utilise la clé publique.'); }

  function lire(k, d){ try{ var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); }catch(_){ return d; } }
  function ecrire(k, v){ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(_){ } }
  function uuid(){
    if(window.crypto && crypto.randomUUID) return crypto.randomUUID();
    var b = new Uint8Array(16); (window.crypto||{getRandomValues:function(a){ for(var i=0;i<a.length;i++) a[i]=Math.random()*256|0; return a; }}).getRandomValues(b);
    b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
    var h = Array.prototype.map.call(b, function(x){ return (x+256).toString(16).slice(1); }).join('');
    return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
  }

  /* ---------- identifiant d'appareil (renouvelé tous les 13 mois, CNIL) ---------- */
  function anonId(){
    var a = lire('viral-anon', null), now = Date.now();
    if(!a || !a.id || now - (a.t || 0) > 395 * 864e5){ a = { id: uuid(), t: now }; ecrire('viral-anon', a); }
    return a.id;
  }

  function standalone(){
    try{ return !!((window.matchMedia && matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true); }catch(_){ return false; }
  }
  function platform(){
    var ua = navigator.userAgent || '';
    if(/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'ios';
    if(/Android/.test(ua)) return 'android';
    if(/Windows|Macintosh|Linux|CrOS/.test(ua)) return 'desktop';
    return 'other';
  }

  /* ---------- session ---------- */
  var session = lire('viral-auth', null);
  function setSession(s){ session = s; if(s) ecrire('viral-auth', s); else { try{ localStorage.removeItem('viral-auth'); }catch(_){ } } emit(); }
  var abonnes = [];
  function emit(){ abonnes.forEach(function(f){ try{ f(session); }catch(_){ } }); }
  function fromAuthResponse(r){
    return { access_token: r.access_token, refresh_token: r.refresh_token,
             expires_at: r.expires_at || (Math.floor(Date.now()/1000) + (r.expires_in || 3600)),
             user: r.user ? { id: r.user.id, email: r.user.email, created_at: r.user.created_at } : (session && session.user) };
  }

  function http(method, path, body, opts){
    opts = opts || {};
    var h = { 'apikey': KEY, 'Content-Type': 'application/json' };
    if(opts.token) h['Authorization'] = 'Bearer ' + opts.token;
    if(opts.prefer) h['Prefer'] = opts.prefer;
    return fetch(URL_ + path, { method: method, headers: h, body: body == null ? undefined : JSON.stringify(body), keepalive: !!opts.keepalive, cache: 'no-store' })
      .then(function(r){
        return r.text().then(function(t){
          var j = null; try{ j = t ? JSON.parse(t) : null; }catch(_){ j = t; }
          if(!r.ok){
            var msg = (j && (j.msg || j.message || j.error_description || j.error)) || ('Erreur ' + r.status);
            var e = new Error(msg); e.status = r.status; e.code = j && j.code; throw e;
          }
          return j;
        });
      });
  }

  var _refresh = null;
  function token(){
    if(!session) return Promise.resolve(null);
    if(session.expires_at - 60 > Date.now()/1000) return Promise.resolve(session.access_token);
    if(!_refresh){
      _refresh = http('POST', '/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token })
        .then(function(r){ setSession(fromAuthResponse(r)); return session.access_token; })
        .catch(function(e){ if(e.status === 400 || e.status === 401) setSession(null); return null; })
        .then(function(t){ _refresh = null; return t; });
    }
    return _refresh;
  }

  /* ---------- statistiques ---------- */
  var FILE = 'viral-events-queue';
  function statsOn(){ return enabled && lire('viral-stats-off', false) !== true; }
  function track(name, extra){
    if(!statsOn()) return;
    extra = extra || {};
    var q = lire(FILE, []);
    q.push({ anon_id: anonId(), user_id: session && session.user ? session.user.id : null, name: name,
             garment: extra.garment || null, standalone: standalone(), platform: platform() });
    if(q.length > 200) q = q.slice(-200);
    ecrire(FILE, q);
    planifierEnvoi();
  }
  var _tEnvoi = null, _envoi = false;
  function planifierEnvoi(){ clearTimeout(_tEnvoi); _tEnvoi = setTimeout(envoyer, 1200); }
  function envoyer(keepalive){
    if(!statsOn() || _envoi || (navigator.onLine === false)) return;
    var q = lire(FILE, []); if(!q.length) return;
    var lot = q.slice(0, 50);
    _envoi = true;
    /* les événements d'un compte partent avec son jeton (le serveur vérifie user_id) */
    token().then(function(t){
      if(!t) lot.forEach(function(e){ e.user_id = null; });
      return http('POST', '/rest/v1/events', lot, { token: t, prefer: 'return=minimal', keepalive: keepalive });
    }).then(function(){
      var reste = lire(FILE, []).slice(lot.length); ecrire(FILE, reste);
      _envoi = false; if(reste.length) planifierEnvoi();
    }).catch(function(e){
      _envoi = false;
      if(e && e.status >= 400 && e.status < 500 && e.status !== 429){ ecrire(FILE, lire(FILE, []).slice(lot.length)); } /* lot refusé : on ne réessaie pas */
    });
  }
  if(enabled){
    window.addEventListener('online', function(){ envoyer(); });
    document.addEventListener('visibilitychange', function(){ if(document.visibilityState === 'hidden') envoyer(true); });
  }

  /* ---------- comptes ---------- */
  function sendCode(email){
    /* l'e-mail contient un code (si le modèle Supabase affiche {{ .Token }}) et/ou un lien
       qui ramène sur cette page : les deux méthodes fonctionnent */
    var retour = encodeURIComponent(location.origin + location.pathname);
    return http('POST', '/auth/v1/otp?redirect_to=' + retour, { email: email, create_user: true });
  }
  /* retour depuis le lien reçu par e-mail : #access_token=…&refresh_token=… */
  var pret = Promise.resolve();
  if(enabled && /access_token=/.test(location.hash)){
    var hp = {}; location.hash.slice(1).split('&').forEach(function(kv){ var i = kv.indexOf('='); hp[decodeURIComponent(kv.slice(0,i))] = decodeURIComponent(kv.slice(i+1)); });
    try{ window.history.replaceState(null, '', location.pathname + location.search); }catch(_){ }
    if(hp.access_token && hp.refresh_token){
      pret = http('GET', '/auth/v1/user', null, { token: hp.access_token }).then(function(u){
        setSession(fromAuthResponse({ access_token: hp.access_token, refresh_token: hp.refresh_token,
          expires_at: +hp.expires_at || 0, expires_in: +hp.expires_in || 3600, user: u }));
        var cree = u && u.created_at ? Date.parse(u.created_at) : 0;
        track(cree && Date.now() - cree < 10 * 60 * 1000 ? 'signup' : 'login');
      }).catch(function(){ });
    }
  }
  function verifyCode(email, code){
    return http('POST', '/auth/v1/verify', { type: 'email', email: email, token: String(code).replace(/\s+/g,'') })
      .then(function(r){
        setSession(fromAuthResponse(r));
        var cree = r.user && r.user.created_at ? Date.parse(r.user.created_at) : 0;
        track(cree && Date.now() - cree < 10 * 60 * 1000 ? 'signup' : 'login');
        return session;
      });
  }
  function signOut(){
    var s = session;
    setSession(null);
    if(s) return http('POST', '/auth/v1/logout', {}, { token: s.access_token }).catch(function(){});
    return Promise.resolve();
  }
  function rpc(fn, args){
    return token().then(function(t){
      if(!t) { var e = new Error('Connexion requise'); e.status = 401; throw e; }
      return http('POST', '/rest/v1/rpc/' + fn, args || {}, { token: t });
    });
  }
  function rest(method, path, body, prefer){
    return token().then(function(t){
      if(!t) { var e = new Error('Connexion requise'); e.status = 401; throw e; }
      return http(method, '/rest/v1/' + path, body, { token: t, prefer: prefer });
    });
  }
  function emailMasque(){
    var e = session && session.user && session.user.email; if(!e) return '';
    var p = e.split('@'); return p[0].slice(0,2) + '•••@' + (p[1] || '');
  }

  window.VB = {
    enabled: enabled,
    anonId: anonId, standalone: standalone, platform: platform,
    track: track, flush: envoyer,
    statsOn: statsOn,
    setStats: function(on){ ecrire('viral-stats-off', !on); if(!on){ try{ localStorage.removeItem(FILE); }catch(_){ } } },
    session: function(){ return session; },
    onSession: function(f){ abonnes.push(f); },
    sendCode: sendCode, verifyCode: verifyCode, signOut: signOut,
    rpc: rpc, rest: rest, token: token, emailMasque: emailMasque,
    pret: function(){ return pret; }
  };
  if(enabled) setTimeout(envoyer, 2500);
})();
