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
-- CÓMO USAR ESTO
--   1. Pega y ejecuta la consulta de abajo en el SQL Editor de Supabase.
--   2. Revisa la columna "rls_activado": TIENE que decir "true" en TODAS
--      las tablas de negocio (companies, profiles, workers, projects,
--      machines, time_logs, documents, invoices, incidents, vacations,
--      clients, demo_leads). Si alguna sale en "false", esa tabla es
--      visible/editable por cualquiera con la anon key — que es pública,
--      está literalmente en el código fuente de tu página.
--   3. Revisa "num_politicas": si una tabla tiene RLS activado pero CERO
--      políticas, el efecto por defecto de Postgres es BLOQUEAR todo el
--      acceso (ni se ve ni se puede escribir) — no es un agujero de
--      seguridad, pero sí es una tabla que se quedaría "muda" en la app.
--
-- PRUEBA MANUAL COMPLEMENTARIA (la más fiable de todas)
--   Crea una empresa de prueba nueva, dale de alta un par de obras y
--   trabajadores, e inicia sesión con ella. Si ves cualquier obra,
--   trabajador o fichaje que no hayas creado tú con esa cuenta de prueba,
--   hay un fallo de RLS que hay que arreglar antes de dar la app a nadie
--   más. Es la comprobación más simple y la que de verdad demuestra que
--   funciona, más allá de leer políticas en el SQL Editor.
-- ============================================================================

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
