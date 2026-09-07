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

/* Subir este número en cada despliegue que cambie sw.js. Al cambiar, el
   'activate' de abajo borra las cachés de la versión anterior — que es lo
   que limpia de un plumazo cualquier index.html malo que se hubiera
   guardado con la versión antigua del service worker. */
const VERSION = 'opertra-v4';
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
        // OJO: fetch() solo falla si NO HAY RED. Un 500, un 502 o un 404 del
        // servidor llegan aquí como respuesta buena. Sin este if, un error
        // pasajero de Vercel (un despliegue a medias, por ejemplo) se
        // guardaba como si fuera la app: a partir de ahí, ese trabajador
        // abría una página de error cada vez que se quedaba sin cobertura,
        // y no se arreglaba solo nunca.
        if (red.ok) {
          const copia = red.clone();
          caches.open(CACHE_APP).then(c => c.put('/index.html', copia)).catch(() => {});
        }
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

  /* ---- Librerías de fuera e iconos nuestros ----
     Los dos van igual: se sirve al instante lo guardado y, en paralelo, se
     pide la versión nueva para la próxima vez ("stale-while-revalidate").

     Antes se servía lo guardado y NO se volvía a pedir jamás. El problema:
     si el CDN fallaba justo el día que un trabajador abrió la app por
     primera vez, se guardaba la respuesta mala y ese móvil se quedaba con
     la librería rota PARA SIEMPRE — los iconos sin salir o el escáner de
     QR sin funcionar, sin manera de arreglarlo salvo desinstalar la app.
     Refrescando por detrás, un fallo así se cura solo la siguiente vez que
     abra la app con cobertura. */
  const esLibreria = DOMINIOS_LIBRERIAS.some(d => url.hostname.endsWith(d));
  if (esLibreria || url.origin === self.location.origin) {
    const almacen = esLibreria ? CACHE_LIB : CACHE_APP;

    e.respondWith((async () => {
      const guardada = await caches.match(req);

      const pedirYGuardar = fetch(req).then(red => {
        /* Solo se guarda si la respuesta es buena. 'opaque' es el caso de
           las librerías de otros dominios: vienen cerradas y no se puede
           mirar dentro ni saber el código de estado, así que se aceptan por
           necesidad — pero como ahora se refrescan cada vez, si una salió
           mal se sustituye sola en la siguiente visita. */
        if (red && (red.ok || red.type === 'opaque')) {
          const copia = red.clone();
          caches.open(almacen).then(c => c.put(req, copia)).catch(() => {});
        }
        return red;
      }).catch(() => null);

      /* waitUntil mantiene vivo el service worker hasta que termine el
         refresco. Sin esto el navegador lo apaga en cuanto respondemos con
         lo guardado, la petición de fondo se corta a medias y la caché no
         se actualizaría nunca. */
      try { e.waitUntil(pedirYGuardar); } catch (err) {}

      // Con algo guardado: se responde ya y el refresco sigue por detrás.
      if (guardada) return guardada;

      const red = await pedirYGuardar;
      return red || new Response('', { status: 504 });
    })());
  }
});
