-- ============================================================================
-- OPERTRA · AUDITORÍA · BLOQUE 1 (que nadie vea lo que no es suyo)
-- Comprobaciones que SOLO se pueden hacer dentro de la base de datos.
--
-- Cómo usarlo: abre el SQL Editor de Supabase, pega cada PASO por separado,
-- ejecútalo y pégame el resultado. Cada consulta lleva escrito qué mira y
-- qué resultado esperas ver si todo está bien. Ninguna de estas consultas
-- cambia nada: solo leen. Son seguras de ejecutar en producción.
-- ============================================================================


-- ############################################################################
-- PASO A · EL BUCKET DE FOTOS Y DOCUMENTOS (lo más grave del bloque)
-- ############################################################################
-- Por qué: las tablas están protegidas, pero las FOTOS (incluidos DNI) y los
-- DOCUMENTOS viven en Storage, que se protege APARTE, en la tabla
-- storage.objects. En el código, el personal de obra pide los enlaces de sus
-- fotos SIN tener sesión (entra con PIN, para Storage es "anónimo"). Para que
-- eso funcione, storage.objects tiene que dejar leer al rol anónimo. El
-- peligro: si ese permiso NO está limitado a la carpeta de su propia empresa,
-- cualquiera puede pedir el enlace de las fotos de CUALQUIER empresa.

-- A.1 · ¿El bucket es privado? (public = false es lo correcto)
select id, name, public
from storage.buckets
where id = 'opertra';
-- ESPERADO: una fila, public = false. Si sale public = true, cualquiera con
-- la URL ve el archivo sin enlace firmado: hay que ponerlo en privado.

-- A.2 · ¿Qué políticas tiene storage.objects y qué dicen exactamente?
select policyname,
       roles,                 -- a qué rol se aplica (ojo si aparece 'anon')
       cmd as operacion,      -- select = leer/firmar, insert = subir, etc.
       qual as condicion_leer,
       with_check as condicion_escribir
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
order by cmd, policyname;
-- QUÉ BUSCAR (esto lo reviso yo con tu resultado, pero para que lo veas):
--   * NO debe haber ninguna política de SELECT para 'anon' cuya condición sea
--     solo "bucket_id = 'opertra'". Eso dejaría a cualquier anónimo firmar el
--     enlace de todas las carpetas.
--   * Lo correcto es que el enlace de una foto solo lo pueda pedir alguien de
--     esa misma empresa. Como el trabajador anónimo no tiene empresa asociada,
--     lo sano es que el trabajador NO firme directamente, sino a través de una
--     función que valida su PIN. Si ves permiso de SELECT abierto a 'anon',
--     es el agujero clásico y hay que cerrarlo.


-- ############################################################################
-- PASO B · AISLAMIENTO ENTRE EMPRESAS EN LAS TABLAS (RLS)
-- ############################################################################
-- Por qué: el navegador lee sin filtrar por empresa (no hay .eq('company_id')).
-- El único muro es que cada tabla tenga RLS con una política que compare
-- contra la empresa del que pregunta. Que la política EXISTA no basta: hay
-- que leer qué dice.

-- B.1 · RLS activado y nº de políticas por tabla
select t.tablename,
       t.rowsecurity as rls_activado,
       count(p.policyname) as num_politicas
from pg_tables t
left join pg_policies p on p.schemaname = t.schemaname and p.tablename = t.tablename
where t.schemaname = 'public'
group by t.tablename, t.rowsecurity
order by (t.rowsecurity is false) desc, t.tablename;
-- ESPERADO: rls_activado = true en TODAS. Las únicas que pueden tener 0
-- políticas son las que solo tocan las funciones por dentro (intentos de
-- login). Cualquier tabla con datos de empresa y 0 políticas es un agujero.

-- B.2 · El texto REAL de cada política (esto es lo que de verdad importa)
select tablename,
       policyname,
       cmd as operacion,
       qual as condicion_using,          -- filtro para leer/editar/borrar
       with_check as condicion_with_check -- filtro para lo que se inserta
from pg_policies
where schemaname = 'public'
order by tablename, cmd;
-- QUÉ BUSCAR:
--   * PELIGRO si ves "true" a secas en condicion_using de un SELECT: deja ver
--     todas las filas de todas las empresas.
--   * En los INSERT, la condicion_with_check TIENE que forzar que company_id
--     sea el de la empresa del usuario (algo como
--     "company_id = (select company_id from profiles where id = auth.uid())"
--     o una función tipo empresa_actual()). Si el INSERT no comprueba
--     company_id, un administrador puede meter filas en OTRA empresa cambiando
--     un dato en la consola del navegador (el código manda company_id desde
--     el navegador: insert({ company_id: currentUser.companyId, ... })).


-- ############################################################################
-- PASO C · LAS FUNCIONES QUE SE SALTAN RLS (SECURITY DEFINER)
-- ############################################################################
-- Por qué: estas funciones se ejecutan con permisos totales; la seguridad la
-- tienen que poner ELLAS por dentro. Hay que leer su código.

-- C.1 · Ver el código de las funciones más sensibles (panel del dueño +
--       la que recibe company_id desde el navegador)
select p.proname as funcion, pg_get_functiondef(p.oid) as codigo
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('soy_opertra_admin','panel_empresas','renovar_empresa',
                    'uso_almacenamiento');
-- QUÉ BUSCAR:
--   * panel_empresas / renovar_empresa / soy_opertra_admin: al principio deben
--     comprobar que quien llama está en la tabla opertra_admins (algo como
--     "if not exists (select 1 from opertra_admins where user_id = auth.uid())
--      then raise exception ...")  ANTES de tocar nada.
--   * uso_almacenamiento(p_company_id): recibe la empresa DESDE EL NAVEGADOR.
--     Tiene que ignorar ese parámetro o comprobar que coincide con la empresa
--     del que llama. Si se fía del parámetro, un administrador puede consultar
--     el consumo de otra empresa pasándole otro id.

-- C.2 · Ver el código de las funciones del trabajador (abiertas a 'anon')
select p.proname as funcion, pg_get_functiondef(p.oid) as codigo
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('worker_login','worker_datos','worker_estado','worker_fichar',
                    'worker_fichar_pendiente','worker_lecturas',
                    'worker_reportar_incidencia','worker_incidencias');
-- QUÉ BUSCAR:
--   * TODAS deben validar el PIN contra el worker_id ANTES de devolver o
--     escribir nada, y devolver solo datos de la empresa de ese trabajador.
--   * worker_fichar / worker_reportar_incidencia reciben p_project_id y
--     p_machine_id desde el navegador. Deben comprobar que esa obra/máquina
--     pertenece a la empresa del trabajador; si no, un trabajador podría
--     fichar en (o colgar una incidencia a) una obra de otra empresa
--     adivinando su id.
--   * worker_login: MUY IMPORTANTE, ver PASO D.


-- ############################################################################
-- PASO D · FRENO DE FUERZA BRUTA DEL PIN (posible fallo grave)
-- ############################################################################
-- Por qué: en el navegador, cuando un login falla, se llama a otra función
-- aparte, fallo_de_acceso(), para apuntar el intento. Un atacante que pruebe
-- PINs llamando a worker_login() directamente (sin pasar por la web) NUNCA
-- llamará a fallo_de_acceso(), así que el freno no salta y puede probar los
-- 10.000 PINs de 4 dígitos de una empresa conocida.
--
-- Ya has leído C.2 con el código de worker_login. Comprueba en ese código:
--   ¿worker_login apunta el intento fallido POR DENTRO (escribe en
--   intentos_fallidos / login_intentos cuando el PIN es incorrecto)?
--     - SÍ  -> el freno es de verdad. Bien.
--     - NO  -> el freno solo funciona desde la web y se salta con un script.
--              Hay que mover el conteo de fallos DENTRO de worker_login.

-- D.1 · Ver también el código del freno para entender cómo cuenta
select p.proname as funcion, pg_get_functiondef(p.oid) as codigo
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('puedo_intentar','fallo_de_acceso','acceso_correcto');


-- ############################################################################
-- PASO E · FORMULARIO DE DEMO (tabla demo_leads, abierta a 'anon' para escribir)
-- ############################################################################
-- Por qué: el formulario público inserta en demo_leads sin sesión. Está bien
-- que 'anon' pueda INSERTAR, pero NO debe poder LEER: si no, cualquiera se
-- descarga la lista de contactos comerciales (nombres, correos, teléfonos).

select policyname, roles, cmd as operacion, qual as condicion, with_check
from pg_policies
where schemaname = 'public' and tablename = 'demo_leads'
order by cmd;
-- ESPERADO: una política de INSERT para anon (con with_check), y NINGUNA de
-- SELECT para anon. Si hay SELECT para anon, la lista de leads está expuesta.


-- ############################################################################
-- PASO F · PRUEBA REAL (la más fiable de todas)
-- ############################################################################
-- Crea una empresa de prueba nueva, con un par de obras y trabajadores, e
-- inicia sesión con ella. Si ves UNA sola obra, trabajador, máquina, fichaje
-- o foto que no hayas creado con esa cuenta, hay un fallo de aislamiento.
-- Prueba también, con la consola del navegador abierta en esa cuenta de
-- prueba, a pedir el enlace de una foto de otra empresa:
--   await supabase.storage.from('opertra').createSignedUrls(['<ID_OTRA_EMPRESA>/workers/loquesea'], 3600)
-- Si devuelve un enlace que abre la foto, el bucket está mal protegido.
