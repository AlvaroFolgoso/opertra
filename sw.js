/* ======================================================================
   OPERTRA · SERVICE WORKER

   Qué hace un service worker: se queda instalado en el móvil de cada
   trabajador y decide qué se pide a internet y qué se sirve de lo que ya
   tiene guardado. Es lo que permite que la app abra al instante y que
   funcione en una obra sin cobertura.

   El anterior guardaba el index.html y lo servía SIEMPRE, así que quien
   ya tenía la app abierta se quedaba con la versión vieja para siempre.
   Este pide siempre la última y usa la guardada solo si no hay red.
   ====================================================================== */

const VERSION = 'opertra-v3';
const CACHE_APP = VERSION + '-app';
const CACHE_LIB = 'opertra-librerias';

// Lo mínimo para que la app arranque sin cobertura
const ARCHIVOS = ['/', '/index.html', '/manifest.json', '/logo.svg'];

// Librerías de fuera: no cambian nunca, se guardan y no se vuelven a pedir
const DOMINIOS_LIBRERIAS = [
  'cdnjs.cloudflare.com',
  'cdn.jsdelivr.net',
  'unpkg.com',
  'fonts.googleapis.com',
  'fonts.gstatic.com',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_APP)
      .then(c => c.addAll(ARCHIVOS).catch(() => {}))
      // Sin esperar: la versión nueva entra en cuanto está lista
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const nombres = await caches.keys();
    await Promise.all(nombres
      .filter(n => n !== CACHE_APP && n !== CACHE_LIB)
      .map(n => caches.delete(n)));
    // Se toma el mando de las pestañas que ya estaban abiertas
    await self.clients.claim();
    // Y se les avisa de que hay versión nueva
    const abiertas = await self.clients.matchAll({ type: 'window' });
    abiertas.forEach(c => c.postMessage({ tipo: 'opertra-version-nueva', version: VERSION }));
  })());
});

self.addEventListener('message', (e) => {
  if (e.data && e.data.tipo === 'saltar-espera') self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (err) { return; }

  // Las comprobaciones de versión no se tocan: tienen que llegar al
  // servidor de verdad o nunca se enteraría de que hay algo nuevo.
  if (req.cache === 'no-store' || url.searchParams.has('v')) return;

  // Nada de Supabase pasa por aquí: son datos, no archivos
  if (url.hostname.endsWith('.supabase.co')) return;

  // ---- La página: primero la red, y lo guardado solo como respaldo ----
  const esPagina = req.mode === 'navigate'
    || (req.destination === 'document')
    || url.pathname === '/' || url.pathname === '/index.html';

  if (esPagina) {
    e.respondWith((async () => {
      try {
        const red = await fetch(req);
        const copia = red.clone();
        caches.open(CACHE_APP).then(c => c.put('/index.html', copia)).catch(() => {});
        return red;
      } catch (err) {
        // Sin cobertura: se sirve la última que se guardó
        const guardada = await caches.match('/index.html');
        return guardada || new Response(
          '<h1>Sin conexión</h1><p>Opertra necesita conexión la primera vez.</p>',
          { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  // ---- Librerías de fuera: lo guardado primero, que no cambian ----
  if (DOMINIOS_LIBRERIAS.some(d => url.hostname.endsWith(d))) {
    e.respondWith((async () => {
      const guardada = await caches.match(req);
      if (guardada) return guardada;
      try {
        const red = await fetch(req);
        // Se guarda aunque no se pueda leer (las de otros dominios vienen
        // "cerradas"), que para servirlas de nuevo vale igual
        caches.open(CACHE_LIB).then(c => c.put(req, red.clone())).catch(() => {});
        return red;
      } catch (err) {
        return new Response('', { status: 504 });
      }
    })());
    return;
  }

  // ---- Iconos y demás archivos nuestros ----
  if (url.origin === self.location.origin) {
    e.respondWith((async () => {
      const guardada = await caches.match(req);
      if (guardada) return guardada;
      try {
        const red = await fetch(req);
        caches.open(CACHE_APP).then(c => c.put(req, red.clone())).catch(() => {});
        return red;
      } catch (err) {
        return new Response('', { status: 504 });
      }
    })());
  }
});
