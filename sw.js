/* ============================================================
   OPERTRA · Service Worker
   Guarda la app en el movil para que:
     - abra al instante aunque haya mala cobertura en obra
     - no se descargue entera cada vez (40.000 trabajadores abriendola
       dos veces al dia serian mas de 240 GB al mes de trafico)

   ESTRATEGIA: "servir de cache y actualizar por detras".
   El trabajador ve la app al momento; mientras, se comprueba si hay
   version nueva y se guarda para la siguiente vez. Nunca se queda con
   una version vieja para siempre.

   IMPORTANTE: los datos (fichajes, obras...) NUNCA se cachean. Solo la
   app en si. Todo lo que va a Supabase pasa siempre por la red.
   ============================================================ */

const VERSION = 'opertra-v1';
const ARCHIVOS = ['/', '/index.html', '/manifest.json'];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(VERSION)
      .then(c => c.addAll(ARCHIVOS).catch(() => {}))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then(claves => Promise.all(claves.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Nunca cachear datos ni autenticacion: siempre de la red.
  // Si esto se cacheara, un trabajador podria ver fichajes viejos o
  // quedarse con una sesion caducada.
  if (url.hostname.includes('supabase.co') ||
      url.pathname.startsWith('/auth') ||
      url.search.includes('token')) {
    return;
  }

  // La app y sus recursos: se sirve lo guardado y se actualiza por detras
  e.respondWith(
    caches.open(VERSION).then(cache =>
      cache.match(req).then(guardado => {
        const red = fetch(req).then(resp => {
          if (resp && resp.status === 200 && resp.type !== 'opaque') {
            cache.put(req, resp.clone()).catch(() => {});
          }
          return resp;
        }).catch(() => guardado);   // sin conexion: lo guardado

        return guardado || red;
      })
    )
  );
});
