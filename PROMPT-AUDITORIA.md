# Auditoría de Opertra para ponerla a la venta

Eres un ingeniero senior auditando una app que va a venderse a empresas reales.
Trabaja como si tu firma fuera en el resultado: **prefiero un "esto está mal y
así se arregla" a un "todo correcto" que no sea verdad.**

---

## QUÉ ES Y A QUÉ TIENE QUE AGUANTAR

App de gestión para constructoras: fichaje con QR, obras, maquinaria con GPS,
trabajadores, incidencias y cobros. **Un solo archivo HTML** de ~14.800 líneas
con el CSS y el JS dentro. Base de datos en **Supabase** (PostgreSQL con RLS),
alojada en **Vercel** (opertra.com). PWA instalable.

Objetivo real: **100 empresas, 10.000 trabajadores fichando el mismo día**,
muchos desde el móvil en obra con una raya de cobertura. Ya está en producción.

Lo que no me puedo permitir, por orden:

1. Que una empresa vea datos de otra. Sería una brecha de datos personales con
   sanción de la AEPD y demanda de mis clientes.
2. Que algo que el usuario cree guardado no se haya guardado.
3. Que se degrade con el tiempo o se caiga en hora punta.
4. Que vaya lento o a tirones.

---

## CINCO REGLAS QUE NO PUEDES ROMPER

**1. Nunca me devuelvas el archivo entero.** Son 780 KB. Si tu contexto lo
recorta y me das "el archivo completo", me borras miles de líneas sin que
ninguno de los dos se entere. Dame **solo el fragmento que cambia**, con 3-4
líneas alrededor para localizarlo, y dime en qué función va.

**2. Prohibido cargar nada de un CDN.** La cabecera CSP (`vercel.json`) solo
permite scripts y estilos del propio dominio. Si metes un
`<script src="https://cdn...">`, **te funcionará a ti en tu prueba y fallará en
producción sin dar ningún error visible**. Las librerías están descargadas en
`/vendor/`. Si hace falta otra, se descarga ahí.

**3. Si tocas algo, sube `VERSION` en `sw.js`.** El navegador solo instala un
service worker nuevo si ese archivo cambia. Sin subirlo, los móviles se quedan
días con la versión vieja aunque el servidor tenga otra. Ya pasó.

**4. Nunca reintentes una escritura automáticamente.** Si la petición llegó y lo
que se perdió fue la respuesta, el segundo intento duplica la fila. Solo se
reintentan LECTURAS (ver `conReintentos`).

**5. Todo lo que escriba un usuario pasa por `esc()` antes de ir al HTML.**

---

## CÓDIGO QUE PARECE UN FALLO Y NO LO ES

Son bugs ya arreglados. "Arreglarlos" otra vez los devuelve. Si crees que alguno
está mal, dímelo y lo hablamos, pero no lo cambies sin avisar.

1. **`totalesPorObra()` tira su caché en un microtask.** La caché anterior se
   validaba comparando longitudes de listas, y asignar un trabajador a una obra
   no cambia ninguna longitud. Resultado: añadías a alguien y la obra seguía
   saliendo vacía hasta recargar.
2. **Las escrituras van envueltas (`envolverEscrituras`)** para que la
   suscripción en tiempo real ignore el eco de tus propios cambios. Sin eso
   salía "actualizado por otra persona" estando solo.
3. **`compartirAcceso()` usa `w.name` SIN `esc()`** a propósito: es texto plano
   camino de WhatsApp y se escapa después al meterlo en el `<textarea>`. Con
   doble escape, a un trabajador llamado O'Donnell le llega "O&#39;Donnell".
4. **Al guardar se recoge `updated_at` con `.select('updated_at')`.** Sin eso,
   el siguiente guardado cree que lo ha tocado otra persona y da un conflicto
   falso.
5. **`volcarDatosEmpresa` se niega a vaciar la pantalla si TODO llega vacío.**
   Supabase sin sesión devuelve 200 con listas vacías y sin error: sin esa
   comprobación, el cliente ve "0 obras, 0 trabajadores" y cree que ha perdido
   su empresa.
6. **Los fichajes que no se pueden enviar NO se borran**, se apartan en una
   lista y se avisa con fecha y hora. Es un registro con valor legal (art. 34.9
   del Estatuto de los Trabajadores).
7. **Sin `viewport-fit=cover` ni `interactive-widget=resizes-content`**, a
   propósito: obligaban a calcular a mano los márgenes del aparato y fallaban
   según modelo, orientación y si había salido el teclado.
8. **`contain: layout paint style` en la barra, sin `will-change` ni
   `translateZ`**: esos dos crean una capa que se compone un fotograma después
   del fondo, y era lo que hacía saltar los iconos.

---

## YA HECHO — no lo repitas

RLS verificado en 18 tablas · purga legal automática con `pg_cron` (4 años de
fichajes, 6 de facturación, 24 meses de leads, borrado en cascada al darse de
baja) · textos legales incluido el contrato de encargado del tratamiento
(RGPD art. 28) · cambio de hora verificado · límite de intentos de PIN en el
servidor · protección de doble fichaje · reintentos automáticos de lecturas ·
captura global de errores · registro central de fallos · anti-spam del
formulario de demo · librerías autoalojadas · enlaces de fotos en lote con
caché · índices de escala.

---

## LO QUE TIENES QUE AUDITAR, POR ORDEN

### BLOQUE 1 — Que nadie vea lo que no es suyo

Lo más importante de todo. Empieza aquí.

- **Storage.** Las tablas tienen RLS, ¿y el bucket de fotos y documentos?
  Comprueba las políticas de `storage.objects`. Es el agujero clásico: la base
  de datos perfectamente protegida y las fotos de los DNI accesibles con solo
  tener la URL. Verifica que los enlaces caduquen y que no se pueda listar el
  bucket ni adivinar rutas.
- **Cada RPC, una por una.** Hay ~26 funciones `SECURITY DEFINER`, que por
  definición se saltan RLS. Revisa que **cada una** filtre por empresa por
  dentro y que no se fíe de un parámetro que manda el navegador. Atención
  especial a las `worker_*`, que están abiertas al rol `anon`.
- **El flujo del PIN.** ¿Se puede averiguar si un código de empresa existe
  probando códigos? ¿Se puede sacar la lista de trabajadores de otra empresa
  sabiendo su código? ¿El PIN se compara en el servidor o viaja al navegador?
- **Fugas por el navegador.** ¿Queda algo de la empresa anterior en
  `localStorage` o en memoria al cerrar sesión? ¿Y al cambiar de usuario en el
  mismo móvil?
- **Panel de Opertra.** `soy_opertra_admin()`, `panel_empresas()` y
  `renovar_empresa()` dan acceso a las 100 empresas a la vez. Verifica que se
  protejan DENTRO de la función, no solo escondiendo el botón: cualquiera puede
  llamarlas desde la consola del navegador.

### BLOQUE 2 — Que todo lo que se toca se guarde de verdad

Recorre **cada formulario y cada botón que escriba**: alta y edición de obra,
máquina, trabajador, cliente, incidencia, cobro, documento, vacaciones, fichaje
manual, edición de fichaje y ajustes.

Para cada uno responde:

- ¿Escribe en la base de datos o solo en memoria?
- ¿Qué pasa si falla a mitad?
- ¿Se pinta como guardado antes de que el servidor lo confirme?
- ¿Se puede pulsar dos veces y crear dos filas?
- ¿Queda registro en el histórico de cambios cuando la ley lo exige?

**Dime los que fallen, con el nombre de la función.**

### BLOQUE 3 — Que aguante 10.000 fichajes al día

- Consultas sin `limit` o sin filtro por fecha, que crecerán sin freno.
- Bucles anidados sobre listas (un `.find()` dentro de un `.map()`) que con 500
  trabajadores hacen cientos de miles de comparaciones en cada carga.
- Cuántas conexiones de tiempo real se abren y si se cierran al salir.
- Qué se acumula sin borrarse nunca: `localStorage`, listeners, temporizadores,
  observers, mapas de Leaflet.
- Cuántos datos se descargan en cada carga y qué podría pedirse solo al abrir su
  pestaña.

### BLOQUE 4 — Que vaya fino

- La barra inferior tiene que ir **a 60 fps en un móvil de gama baja**. Mide qué
  provoca repintados al desplazar.
- Cuánto tarda desde abrir la app hasta poder fichar, y qué se puede sacar del
  camino crítico.
- Que no haya saltos de contenido al cargar (imágenes o listas sin su sitio
  reservado).
- Que la app siga respondiendo mientras carga cosas por detrás.

---

## CÓMO QUIERO QUE ME LO CUENTES

**No me digas "está bien": demuéstramelo.** Para cada hallazgo:

1. Qué está mal, en lenguaje llano.
2. **Qué pasa en la práctica.** Ejemplo: "si dos encargados guardan la misma
   obra a la vez, el segundo pisa al primero sin que ninguno se entere".
3. Cómo de grave y cómo de probable.
4. El arreglo, como fragmento suelto.
5. **Cómo has comprobado que funciona.**

Si algo no puedes verificar sin acceso a la base de datos, dímelo claramente y
dame el SQL para ejecutarlo yo, con comentarios en español explicando qué mira
cada consulta y qué resultado esperas ver.

Empieza por el **Bloque 1**. No pases al siguiente hasta terminarlo.

**Escribe todo en español, sin jerga, y comenta el porqué de lo que no sea
obvio: este código lo lee alguien que no es programador.**
