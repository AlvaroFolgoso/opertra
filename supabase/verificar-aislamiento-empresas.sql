-- ============================================================================
-- OPERTRA · Verificación de aislamiento entre empresas (RLS)
-- ============================================================================
--
-- POR QUÉ ESTE ARCHIVO IMPORTA MÁS QUE CUALQUIER OTRO
-- El código de index.html pide los datos así, sin filtrar por empresa:
--     sb.from('projects').select(...)
--     sb.from('workers').select(...)
--     sb.from('machines').select(...)
--     ...
-- No hay ".eq('company_id', ...)" en las lecturas. Eso es correcto y normal
-- SIEMPRE QUE cada tabla tenga activado Row Level Security (RLS) con una
-- política que solo deje ver las filas de la empresa del usuario que
-- pregunta. Si a una sola tabla le falta esa política, cualquier empresa
-- que inicie sesión vería (o podría editar/borrar) los datos de las otras
-- 99. Con 100 empresas compartiendo el mismo proyecto de Supabase, esto es
-- el único muro real entre ellas — más importante que cualquier cosa del
-- HTML, porque el HTML es solo la interfaz: quien quiera saltárselo puede
-- hablar con la API de Supabase directamente con las herramientas del
-- navegador, sin tocar tu página en absoluto.
--
-- ESTADO CONOCIDO (comprobado 2026-09-07): RLS está activado en las 18
-- tablas de public. Las únicas con 0 políticas son intentos_fallidos y
-- login_intentos, y eso es lo correcto — solo las tocan las funciones RPC
-- por dentro, nadie debe poder leerlas ni escribirlas directamente.
--
-- LO QUE FALTA COMPROBAR: que la política existe no dice qué hace. Una
-- política puede existir y aun así decir "USING (true)" (deja pasar
-- cualquier fila) por error. La consulta de abajo (PASO 2) enseña el
-- texto real de cada política para poder revisar que de verdad compara
-- contra la empresa del usuario que pregunta (normalmente algo con
-- "company_id" y "auth.uid()" o una función tipo "empresa_actual()").
--
-- CÓMO USAR ESTO
--   1. Pega y ejecuta el PASO 1 en el SQL Editor de Supabase: activado +
--      número de políticas por tabla (esto ya salió bien la primera vez).
--   2. Pega y ejecuta el PASO 2: te da el texto de cada política. Pégamelo
--      aquí y reviso que el filtro por empresa esté bien puesto.
--
-- PRUEBA MANUAL COMPLEMENTARIA (la más fiable de todas, hazla igualmente)
--   Crea una empresa de prueba nueva, dale de alta un par de obras y
--   trabajadores, e inicia sesión con ella. Si ves cualquier obra,
--   trabajador o fichaje que no hayas creado tú con esa cuenta de prueba,
--   hay un fallo de RLS que hay que arreglar antes de dar la app a nadie
--   más. Es la comprobación más simple y la que de verdad demuestra que
--   funciona, más allá de leer políticas en el SQL Editor.
-- ============================================================================

-- PASO 1 — activado + cuántas políticas por tabla
select
  t.tablename,
  t.rowsecurity as rls_activado,
  count(p.policyname) as num_politicas
from pg_tables t
left join pg_policies p
  on p.schemaname = t.schemaname and p.tablename = t.tablename
where t.schemaname = 'public'
group by t.tablename, t.rowsecurity
order by (t.rowsecurity is false) desc, t.tablename;

-- PASO 2 — qué dice cada política de verdad (esto es lo que hay que leer)
select
  tablename,
  policyname,
  cmd as operacion,           -- select / insert / update / delete
  qual as condicion_using,    -- filtro para leer/editar/borrar filas existentes
  with_check as condicion_with_check  -- filtro para lo que se inserta/actualiza
from pg_policies
where schemaname = 'public'
order by tablename, cmd;
