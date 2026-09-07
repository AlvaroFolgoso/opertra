-- ============================================================================
-- OPERTRA · Índices para aguantar el volumen a escala (8.000 fichajes/día)
-- ============================================================================
-- Sin índice, cada consulta de "los fichajes de mi empresa de los últimos
-- X días" obliga a Postgres a mirar fila por fila TODA la tabla time_logs
-- para encontrar las que tocan. Con 8.000 fichajes/día eso son ~2,9 millones
-- de filas nuevas cada año — al principio no se nota, pero según crece la
-- tabla la app se va quedando cada vez más lenta, hasta notarse mucho.
--
-- CREATE INDEX IF NOT EXISTS es seguro de ejecutar aunque el índice ya
-- exista (no hace nada) y no borra ni modifica ningún dato — solo añade una
-- estructura de búsqueda rápida al lado de la tabla. Pégalo entero en el SQL
-- Editor de Supabase y ejecútalo.
--
-- AVISO si algún día lo vuelves a correr con la tabla ya muy grande y en
-- producción real: un CREATE INDEX normal bloquea escrituras en esa tabla
-- mientras se construye. Con pocos datos (que es tu caso ahora mismo, antes
-- de vender) no se nota nada. Si alguna vez hace falta añadir un índice
-- nuevo con la app ya en uso real por muchas empresas, dímelo y lo hacemos
-- con CREATE INDEX CONCURRENTLY, que no bloquea pero tarda más y no puede
-- ir dentro de este mismo bloque.
-- ============================================================================

-- time_logs: la tabla que más crece de todas, con diferencia.
-- Para "los fichajes de mi empresa, del más nuevo al más viejo" (la consulta
-- que hace loadCompanyData en cada carga):
create index if not exists idx_time_logs_company_checkin
  on public.time_logs (company_id, check_in desc);

-- Para "quién tiene la jornada abierta ahora mismo" (cargarJornadasAbiertas):
-- un índice PARCIAL, que solo indexa las filas sin cerrar — son siempre
-- pocas (como mucho, una por trabajador activo), así que esta consulta sale
-- casi gratis por muchos fichajes históricos que se acumulen.
create index if not exists idx_time_logs_abiertos
  on public.time_logs (worker_id) where check_out is null;

-- Para el borrado legal a los 4 años (politica-retencion-datos.sql) y
-- cualquier filtro directo por trabajador:
create index if not exists idx_time_logs_worker
  on public.time_logs (worker_id);

-- documents: caducidades (certificados, ITV...) y la purga legal a 4 años.
create index if not exists idx_documents_expiry
  on public.documents (expiry_date) where expiry_date is not null;
create index if not exists idx_documents_company
  on public.documents (company_id);

-- incidents: las abiertas se piden siempre, en todas las empresas, cada vez
-- que se entra a Avisos.
create index if not exists idx_incidents_company_resolved
  on public.incidents (company_id, resolved, created_at desc);

-- invoices: pendientes de cobro, la pantalla de Facturación las pide enteras
-- cada vez.
create index if not exists idx_invoices_company_status
  on public.invoices (company_id, status);

-- workers/machines/projects: listados por empresa, se piden en cada carga.
create index if not exists idx_workers_company_active
  on public.workers (company_id, active);
create index if not exists idx_machines_company
  on public.machines (company_id);
create index if not exists idx_projects_company
  on public.projects (company_id);

-- audit_log: el Historial de cambios, y lo que consulta la purga de
-- empresas dadas de baja.
create index if not exists idx_audit_log_company_created
  on public.audit_log (company_id, created_at desc);

-- Para comprobar qué índices ha creado esto (o cuáles ya había):
--   SELECT tablename, indexname FROM pg_indexes
--   WHERE schemaname = 'public' ORDER BY tablename;
