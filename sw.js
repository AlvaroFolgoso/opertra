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

/* ATENCIÓN: ESTE NÚMERO HAY QUE SUBIRLO EN CADA DESPLIEGUE.

   No es una manía: el navegador solo se molesta en instalar un service
   worker nuevo si el ARCHIVO sw.js ha cambiado. Si no cambia, se queda con
   el que tiene, no se dispara el aviso de "hay una versión nueva" y el
   móvil puede seguir días con la app vieja aunque el servidor tenga otra.

   Pasó de verdad: estuvo clavado en v4 durante muchos despliegues y las
   correcciones no llegaban a los móviles. Con cien empresas eso significa
   arreglar algo y que el cliente siga con el fallo sin enterarse.

   Al cambiar, el 'activate' de abajo borra las cachés de la versión
   anterior, que es lo que limpia de un plumazo cualquier archivo viejo que
   se hubiera quedado guardado. */
const VERSION = 'opertra-v15';
const CACHE_APP = VERSION + '-app';
/* El almacén de librerías NO se borra en cada despliegue a propósito: las
   librerías no cambian y así no se vuelven a descargar. Pero lleva número
   propio para poder forzar una limpieza cuando hace falta — como ahora.

   Por qué se sube a -v2: la versión vieja del service worker guardaba las
   respuestas AUNQUE FUERAN UN ERROR, y luego las servía de caché sin volver
   a pedirlas nunca. A quien le fallara el CDN una sola vez se le quedaba la
   librería rota guardada de forma permanente: supabase-js sin cargar y, con
   él, "Can't find variable: supabase" al intentar entrar. Cambiar el nombre
   hace que el activate de abajo borre el almacén viejo entero y todo se
   vuelva a descargar limpio una vez. */
const CACHE_LIB = 'opertra-librerias-v2';

/* Lo mínimo para que la app arranque sin cobertura. supabase.js entra aquí
   porque sin él la app no es que se vea fea: es que no arranca — no se puede
   ni entrar ni fichar. */
const ARCHIVOS = ['/', '/index.html', '/manifest.json', '/logo.svg', '/vendor/supabase.js'];

/* Las librerías ya no vienen de fuera: se sirven desde /vendor en nuestro
   propio dominio (ver el comentario largo en el <head> de index.html). Se
   guardan en su propio almacén, aparte del de la app, para que NO se
   vuelvan a descargar en cada despliegue — son 1,4 MB que no cambian casi
   nunca. Cuando toque actualizar alguna, se sube el número de CACHE_LIB. */
function esLibreriaPropia(url) {
  return url.origin === self.location.origin && url.pathname.startsWith('/vendor/');
}

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
        /* TOPE DE 3 SEGUNDOS. Antes se esperaba a la red sin límite: en una
           obra con una raya de cobertura, esa espera puede irse a treinta
           segundos o no terminar nunca, y mientras tanto el trabajador mira
           una pantalla en blanco AUNQUE tenga la app guardada en el móvil y
           lista para abrir al instante.

           Ahora, si en tres segundos no ha llegado, se abre con la guardada y
           se sigue esperando por detrás para dejarla actualizada de cara a la
           próxima vez. Nunca se pierde una versión nueva: solo se retrasa un
           arranque. */
        const guardadaYa = await caches.match('/index.html');
        const red = guardadaYa
          ? await Promise.race([
              fetch(req),
              new Promise((_, no) => setTimeout(() => no(new Error('tarda demasiado')), 3000)),
            ])
          : await fetch(req);
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
        /* Se ha agotado el tope o no hay cobertura. Se abre con la guardada, y
           si SÍ había red (solo iba lenta) se sigue pidiendo por detrás para
           que la próxima apertura ya tenga la versión nueva. */
        fetch(req).then(r => {
          if (r && r.ok) caches.open(CACHE_APP).then(c => c.put('/index.html', r.clone())).catch(() => {});
        }).catch(() => {});

        const guardada = await caches.match('/index.html');
        return guardada || new Response(
          '<h1>Sin conexión</h1><p>Opertra necesita conexión la primera vez.</p>',
          { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  /* ---- Librerías de /vendor e iconos nuestros ----
     Los dos van igual: se sirve al instante lo guardado y, en paralelo, se
     pide la versión nueva para la próxima vez ("stale-while-revalidate").

     Antes se servía lo guardado y NO se volvía a pedir jamás. El problema:
     si la descarga fallaba justo el día que un trabajador abrió la app por
     primera vez, se guardaba la respuesta mala y ese móvil se quedaba con
     la librería rota PARA SIEMPRE — los iconos sin salir, el escáner de QR
     sin funcionar o, lo peor, supabase.js sin cargar y sin poder entrar.
     Refrescando por detrás, un fallo así se cura solo la siguiente vez que
     abra la app con cobertura. */
  if (url.origin === self.location.origin) {
    const almacen = esLibreriaPropia(url) ? CACHE_LIB : CACHE_APP;

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
