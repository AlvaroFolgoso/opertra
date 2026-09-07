-- ============================================================================
-- OPERTRA · Comprobación de demo_leads (trigger anti-spam + quién puede leerla)
-- ============================================================================
-- El PASO 2 es el importante y no tiene nada que ver con el spam.
--
-- Para que el formulario de la landing funcione sin iniciar sesión, la tabla
-- demo_leads tiene que permitir INSERT al rol anon (todo internet). Eso está
-- bien y es necesario. El problema sería que además permitiera SELECT: en esa
-- tabla están el nombre, la empresa, el correo y el teléfono de cada persona
-- que pide una demo — o sea, tu lista de clientes potenciales. Si anon puede
-- leerla, cualquiera con el navegador abierto puede descargarse tu embudo de
-- ventas entero: tu competencia, un spammer, quien sea. Y además sería una
-- brecha de datos personales en toda regla (RGPD art. 32).
--
-- Lo que TIENE que salir:
--   - Una política de INSERT para anon  → correcto, es el formulario.
--   - NINGUNA política de SELECT para anon → solo tú, autenticado, deberías
--     poder leer las solicitudes.
--
-- Ejecuta las cuatro consultas y pégame los resultados.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PASO 1 · ¿Quedó puesto el trigger anti-spam?
--   Esperado: una fila, trg_demo_leads_limitar_spam, tgenabled = 'O' (activo).
-- ----------------------------------------------------------------------------
-- tgenabled es del tipo interno "char" de Postgres, no text: sin el ::text
-- el operador || es ambiguo y la consulta no arranca.
select tgname as trigger_name,
       case tgenabled when 'O' then 'ACTIVO' else 'DESACTIVADO (' || tgenabled::text || ')' end as estado
from pg_trigger
where tgrelid = 'public.demo_leads'::regclass
  and not tgisinternal;

-- ----------------------------------------------------------------------------
-- PASO 2 · ¿QUIÉN PUEDE HACER QUÉ en demo_leads?   <-- EL IMPORTANTE
--   Esperado: INSERT para anon (bien). NINGUNA fila de SELECT con anon.
-- ----------------------------------------------------------------------------
select policyname as politica,
       cmd as operacion,
       roles::text as roles_permitidos,
       coalesce(qual, '(sin condicion)') as condicion_lectura,
       coalesce(with_check, '(sin condicion)') as condicion_escritura
from pg_policies
where schemaname = 'public' and tablename = 'demo_leads'
order by cmd, policyname;

-- ----------------------------------------------------------------------------
-- PASO 3 · ¿Está RLS activada? Si sale 'f', las políticas de arriba NO se
--   aplican y la tabla está abierta de par en par.
--   Esperado: rls_activada = true
-- ----------------------------------------------------------------------------
select relname as tabla, relrowsecurity as rls_activada
from pg_class
where oid = 'public.demo_leads'::regclass;

-- ----------------------------------------------------------------------------
-- PASO 4 · ¿Se crearon la columna y los índices?
--   Esperado: ip_hash presente, y 3 índices idx_demo_leads_*
-- ----------------------------------------------------------------------------
select 'columna' as tipo, column_name as nombre
from information_schema.columns
where table_schema = 'public' and table_name = 'demo_leads' and column_name = 'ip_hash'
union all
select 'indice', indexname
from pg_indexes
where schemaname = 'public' and tablename = 'demo_leads' and indexname like 'idx_demo_leads%'
order by tipo, nombre;
