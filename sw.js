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
const VERSION = 'opertra-v2';
const ARCHIVOS = ['/', '/index.html', '/manifest.json'];

/* Librerias externas de las que depende la app. Sin ellas, sin cobertura
   la app abre pero no funciona: no hay lector de QR ni conexion con la
   base de datos. Como vienen de otro dominio, el navegador devuelve una
   respuesta "opaca" (no deja ver ni su contenido ni si fue bien), asi
   que hay que guardarlas a ciegas. Son archivos con version fija en la
   direccion, no cambian nunca. */
const DOMINIOS_LIBRERIAS = ['cdnjs.cloudflare.com', 'cdn.jsdelivr.net', 'unpkg.com'];

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

/* Avisa a la pantalla de que hay version nueva guardada, para que la app
   pueda ofrecer el boton de actualizar en vez de cambiarla de golpe
   mientras alguien esta fichando. */
function avisarDeVersionNueva() {
  self.clients.matchAll().then(cs => {
    cs.forEach(c => c.postMessage({ tipo: 'opertra-version-nueva' }));
  }).catch(() => {});
}

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

  const esLibreria = DOMINIOS_LIBRERIAS.includes(url.hostname);

  e.respondWith(
    caches.open(VERSION).then(cache =>
      cache.match(req).then(guardado => {

        // Las librerias no cambian nunca: si estan guardadas, se usan y
        // no se vuelven a pedir. Ahorra trafico y funcionan sin cobertura.
        if (esLibreria && guardado) return guardado;

        const red = fetch(req).then(resp => {
          if (!resp) return resp;
          const guardable = esLibreria
            ? (resp.type === 'opaque' || resp.ok)   // opaca: se guarda a ciegas
            : (resp.status === 200 && resp.type !== 'opaque');
          if (guardable) {
            // Si la app ha cambiado, se avisa a la pantalla
            if (!esLibreria && guardado && req.mode === 'navigate') {
              const etiquetaVieja = guardado.headers && guardado.headers.get('etag');
              const etiquetaNueva = resp.headers && resp.headers.get('etag');
              if (etiquetaNueva && etiquetaVieja && etiquetaNueva !== etiquetaVieja) {
                avisarDeVersionNueva();
              }
            }
            cache.put(req, resp.clone()).catch(() => {});
          }
          return resp;
        }).catch(() => guardado);   // sin conexion: lo guardado

        return guardado || red;
      })
    )
  );
});
