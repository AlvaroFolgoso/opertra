# Opertra — contexto para trabajar en este código

Pega esto ANTES de pasar el `index.html`.

---

## Qué es

App de gestión para constructoras: fichaje con QR, obras, maquinaria con GPS,
trabajadores, incidencias y cobros. **Un solo archivo HTML** de ~14.600 líneas
con el CSS y el JS dentro. Base de datos en Supabase, alojada en Vercel
(opertra.com). Se va a vender a ~100 empresas; la usarán obreros a diario desde
el móvil, muchas veces con mala cobertura.

Está en producción. Cualquier cambio llega a gente que está trabajando.

---

## REGLAS QUE NO SE PUEDEN ROMPER

**1. No devuelvas el archivo entero.**
Son 756 KB. Si tu contexto lo recorta y me das "el archivo completo", me borras
miles de líneas sin que ninguno de los dos se entere. Dame **solo el fragmento
que cambia**, con unas líneas alrededor para localizarlo.

**2. Nada de librerías externas (CDN).**
La política de seguridad del servidor (`vercel.json`, cabecera CSP) solo permite
scripts del propio dominio. Si metes un `<script src="https://cdn...">`,
**te funcionará en tu prueba y fallará en producción sin dar ningún error
visible**. Las librerías están descargadas en `/vendor/`: supabase, jsQR,
qrcode, leaflet, Font Awesome y las tipografías. Si necesitas otra, hay que
descargarla ahí.

**3. Si tocas algo, hay que subir el número de versión de `sw.js`.**
El navegador solo instala un service worker nuevo si ese archivo cambia. Si no
se sube, **los móviles se quedan con la versión vieja durante días** aunque el
servidor tenga otra. Está pasando de verdad y costó encontrarlo.

**4. Nunca reintentar una escritura automáticamente.**
Si la petición llegó y lo que se perdió fue la respuesta, el segundo intento
crea una fila duplicada. Solo se reintentan LECTURAS (ver `conReintentos`).

**5. Todo lo que escriba un usuario pasa por `esc()` antes de ir al HTML.**
Excepción documentada: el mensaje de acceso que se copia para WhatsApp usa el
nombre SIN escapar, porque es texto plano y se escapa después al meterlo en el
`<textarea>`. Ver punto 3 de la sección siguiente.

---

## CÓDIGO QUE PARECE UN FALLO Y NO LO ES

Todo esto son bugs ya arreglados. "Arreglarlos" otra vez los devuelve.

**1. `totalesPorObra()` y `resumenClientes()` tiran su caché en un microtask.**
Parece un despiste. No lo es: antes la caché se validaba comparando LONGITUDES
de listas, y asignar un trabajador a una obra no cambia ninguna longitud (cambia
un campo dentro de un objeto que ya estaba). Resultado: añadías a alguien a una
obra y la obra seguía saliendo vacía hasta recargar la app. La caché ahora dura
solo el repintado actual, que es para lo único que existe.

**2. Las escrituras a Supabase van envueltas (`envolverEscrituras`).**
Marcan la hora de cada escritura propia para que la suscripción en tiempo real
ignore el eco. Sin eso, cambiabas el operario de una máquina y a los pocos
segundos te salía "Datos actualizados por otra persona" y la app se recargaba
entera — por tu propio cambio, estando solo.

**3. `compartirAcceso()` usa `w.name` SIN `esc()`.**
Es texto plano camino de WhatsApp, y se escapa una vez al meterlo en el
`<textarea>`. Si además se escapa aquí, a un trabajador llamado O'Donnell le
llega "Hola O&#39;Donnell". La protección real sigue puesta: comprobado que un
nombre con etiquetas HTML no ejecuta nada.

**4. Al guardar se recoge `updated_at` con `.select('updated_at')`.**
Es obligatorio. Si no se guarda la marca nueva, el siguiente guardado cree que
lo ha tocado otra persona y suelta un aviso de conflicto falso.

**5. `volcarDatosEmpresa` se niega a vaciar la pantalla si TODO llega vacío.**
Supabase, sin sesión, devuelve 200 con lista vacía y sin error. Sin esa
comprobación, una sesión caducada hacía que el cliente viera "0 obras, 0
trabajadores" y creyera que había perdido su empresa.

**6. Los fichajes que no se pueden enviar NO se borran.**
Se apartan en una lista aparte y se avisa al trabajador con fecha y hora. Es un
registro de jornada con valor legal (art. 34.9 del Estatuto de los
Trabajadores): perder uno en silencio es un agujero legal.

**7. Los índices por id (`indicesParaFichajes`, etc.).**
Sustituyen bucles anidados que hacían cientos de miles de comparaciones en cada
carga. No los cambies por `.find()` dentro de un `.map()`.

**8. Sin `viewport-fit=cover` ni `black-translucent`, a propósito.**
Con ellos la app se dibuja bajo la barra de estado y hay que calcular los
márgenes del aparato con `env(safe-area-inset-*)`. Ese cálculo falla según
modelo, orientación y si el teclado ha salido. Se quitaron para que sea el
sistema quien recorte la zona útil. **No los vuelvas a poner** (ver "pendiente").

**9. Sin `interactive-widget=resizes-content`.**
Encogía el área de la página al salir el teclado y no la restauraba, dejando un
hueco permanente bajo la barra de abajo.

---

## YA AUDITADO — no hace falta repasarlo

- Aislamiento entre empresas (RLS) verificado en las 18 tablas.
- Retención legal automatizada: purga nocturna con `pg_cron` (4 años de
  fichajes, 6 de facturación, 24 meses de leads, borrado en cascada al darse
  de baja).
- Textos legales completos, incluido el contrato de encargado del tratamiento
  (RGPD art. 28).
- Cambio de hora (marzo/octubre): las horas se calculan sobre instantes
  absolutos; comprobado que una noche de cambio da 7 h o 9 h, no 8.
- Límite de intentos de PIN en el servidor y protección contra doble fichaje.
- Reintentos automáticos de lecturas, captura global de errores, y registro
  central de fallos.
- Anti-spam del formulario de demo (trampa en el navegador + trigger en la BD).

---

## PENDIENTE / SIN RESOLVER

**La barra de navegación inferior en iPhone.** El dueño ve un hueco grande
debajo de los botones. Se han probado seis enfoques (ajustar el relleno con
`env()`, medir en tiempo de ejecución, quitar un `::after` que pintaba una
pantalla de alto, `position: fixed; bottom: 0`, quitar
`interactive-widget=resizes-content`, y finalmente quitar `viewport-fit=cover`).
En pruebas sobre seis formatos de móvil la barra queda a 0 px del borde, pero
en su iPhone 15 Pro instalado como app sigue viéndose mal.

Sospecha viva: puede que las versiones nuevas no le estén llegando al móvil
(el service worker estuvo clavado en la misma versión muchos despliegues). Hay
un botón "Buscar actualización" en Ajustes y una pantalla de "Información
técnica" con las medidas reales del aparato, que aún no se ha podido ver.

**Otros pendientes menores:** rellenar NIF y domicilio en `DATOS_TITULAR`
(Aviso Legal), y la pasarela de pago (Stripe debe llamar a `renovar_empresa`).

---

## Cómo trabajar

1. Dime qué has cambiado y por qué, en lenguaje llano.
2. Dame solo el fragmento nuevo, nunca el archivo entero.
3. Si tocas algo, recuérdame subir la versión de `sw.js`.
4. Comenta el porqué de lo que no sea obvio, en español y sin jerga: este
   código lo lee alguien que no es programador.
