-- ============================================================================
-- OPERTRA · PENDIENTE DE EJECUTAR (preparado el 2026-09-13)
-- Ejecutar en el SQL Editor de Supabase, UN BLOQUE CADA VEZ (el editor solo
-- enseña el resultado de la ultima sentencia).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) ¿A service_role le falta permiso de lectura en alguna tabla?
--    En la auditoria se le quito por error en `workers` (ya restaurado el
--    2026-09-13). Aqui se comprueba si paso en mas tablas. IDEAL: sale VACIO.
-- ----------------------------------------------------------------------------
select t.table_name
from information_schema.tables t
where t.table_schema = 'public' and t.table_type = 'BASE TABLE'
  and not exists (
    select 1 from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.table_name = t.table_name
      and g.grantee = 'service_role' and g.privilege_type = 'SELECT'
  )
order by t.table_name;

-- Si sale alguna tabla, ejecutar por cada una (cambiando <tabla>):
--   grant select, insert, update, delete on public.<tabla> to service_role;


-- ----------------------------------------------------------------------------
-- 2) Purga nocturna de la "libreta" de fichajes (fichaje_ops).
--    Esa tabla solo sirve para que un fichaje reintentado no se duplique, y
--    los reintentos duran pocos dias (la cola del movil caduca a los 3).
--    Sin purga crece sin limite: 10.000 fichajes/dia = 3,6 millones de
--    filas al anio. Se borra lo de mas de 7 dias, cada noche a las 04:15.
--    EJECUTAR UNA SOLA VEZ (si se repite, dara error de nombre duplicado).
-- ----------------------------------------------------------------------------
select cron.schedule(
  'purgar_fichaje_ops',
  '15 4 * * *',
  $$delete from public.fichaje_ops where created_at < now() - interval '7 days'$$
);

-- Comprobar que quedo programada (debe salir 1 fila):
-- select jobname, schedule, active from cron.job where jobname = 'purgar_fichaje_ops';


-- ----------------------------------------------------------------------------
-- 3) ¿Existe el trigger que pone al dia la obra/maquina ACTUAL del trabajador
--    cada vez que ficha? (se le paso a Alvaro para ejecutar; sin confirmar)
--    Si sale 1 fila con tgenabled = 'O', esta activo. Si no sale nada, no se
--    aplico y hay que volver a pedir ese SQL.
-- ----------------------------------------------------------------------------
select tgname, tgrelid::regclass as tabla, tgenabled
from pg_trigger
where tgname = 'trg_worker_actual';


-- ----------------------------------------------------------------------------
-- 4) (Opcional, pulcritud) Redesplegar la Edge Function `swift-worker` con la
--    version limpia del repositorio: supabase/functions/swift-worker/index.ts
--    La desplegada ahora funciona igual, pero lleva un "chivato" que, en caso
--    de error, devuelve detalles internos. Panel Supabase → Edge Functions →
--    subir-archivo-trabajador → Code → Ctrl+A → pegar → Deploy.
-- ----------------------------------------------------------------------------
