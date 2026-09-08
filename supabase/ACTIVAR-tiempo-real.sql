-- ============================================================================
-- OPERTRA · Activar el tiempo real en las tablas
-- ============================================================================
--
-- POR QUÉ
--   La app se suscribe a los cambios de estas tablas para actualizarse sola
--   (añadir un trabajador, cambiar una máquina, y ahora también los fichajes).
--   Pero en Supabase el tiempo real SOLO funciona en las tablas que están
--   "publicadas" para ello. Si una tabla no está publicada, la app escucha y
--   no llega nada: por eso no se actualizaba en vivo.
--
--   Ninguna de estas consultas borra ni cambia datos. Solo activan avisos.
-- ============================================================================

-- PASO 1 · ¿Qué tablas tienen ya el tiempo real activado? (para ver qué falta)
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public'
order by tablename;
-- Esperado tras el PASO 2: deben aparecer time_logs, projects, machines,
-- workers, incidents, invoices y clients.


-- PASO 2 · Activar el tiempo real en las que falten (es idempotente: si una ya
--          estaba, no hace nada; no da error).
do $$
declare t text;
begin
  foreach t in array array['time_logs','projects','machines','workers',
                           'incidents','invoices','clients']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- PASO 3 · Para que los avisos de MODIFICAR y BORRAR un fichaje lleguen bien
--          filtrados por empresa, time_logs debe llevar "identidad completa".
--          (Coste despreciable: se ficha miles de veces al día, no millones.)
alter table public.time_logs replica identity full;


-- PASO 4 · Volver a mirar cómo ha quedado (debe salir la lista completa)
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public'
order by tablename;
