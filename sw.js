// Rota Certa — guarda o aplicativo no aparelho para abrir sem internet.
// Os dados (Supabase) nunca passam por aqui.
const VERSAO = 'rc-v1';
const LIB = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.39.8/dist/umd/supabase.js';
const BASE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', LIB];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSAO).then(c => Promise.all(BASE.map(u => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSAO).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if(r.method !== 'GET') return;
  if(u.origin !== location.origin && r.url !== LIB) return;      // Supabase e o resto vão direto para a internet
  e.respondWith(
    fetch(r).then(res => { if(res.ok){ const c = res.clone(); caches.open(VERSAO).then(ca => ca.put(r, c)); } return res; })
      .catch(() => caches.match(r, { ignoreSearch: true }).then(m => m || (r.mode === 'navigate' ? caches.match('./index.html') : Response.error())))
  );
});
