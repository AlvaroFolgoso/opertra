-- ============================================================================
-- OPERTRA · Por qué falla "No se pudieron calcular las horas"
-- ============================================================================
-- CORRECCIÓN: no eran los permisos. Tu propia tabla lo demostró — las tres
-- funciones tienen puede_authenticated = SI. El "permission denied" que vi
-- en la consola era de mi navegador de pruebas, que va SIN sesión (rol
-- anon), y esas funciones correctamente no están abiertas a anon.
--
-- Así que la causa es otra. Estas consultas la buscan por descarte.
--
-- Sospecha principal: el nombre de los parámetros. La app las llama así:
--     resumen_horas_obra        ->  p_project_id
--     resumen_horas_trabajador  ->  p_worker_id
--     resumen_horas_mes         ->  p_mes
-- Si la función los declara con otro nombre (p_obra_id, p_trabajador_id...),
-- PostgREST responde "no encuentro esa función" y la app enseña el mismo
-- mensaje genérico de siempre. Es un fallo silencioso muy típico.
--
-- Ejecuta los tres pasos y mándame los resultados.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- PASO 1 · Firma exacta: qué parámetros esperan de verdad
--   Compara la columna "parametros_que_espera" con lo de arriba.
-- ----------------------------------------------------------------------------
select p.proname as funcion,
       pg_get_function_arguments(p.oid) as parametros_que_espera,
       pg_get_function_result(p.oid)    as devuelve
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('resumen_horas_obra','resumen_horas_trabajador','resumen_horas_mes')
order by p.proname;


-- ----------------------------------------------------------------------------
-- PASO 2 · Llamarlas de verdad, con datos tuyos
--   Si alguna revienta, aquí sale el error REAL en vez del mensaje genérico
--   de la app. Si devuelve filas, es que la función está bien y el problema
--   está en el navegador.
-- ----------------------------------------------------------------------------

-- Con tu obra real (coge el id de la primera obra que tengas):
select 'resumen_horas_obra' as prueba, *
from public.resumen_horas_obra((select id from public.projects order by created_at limit 1));

-- Con tu trabajador real:
select 'resumen_horas_trabajador' as prueba, *
from public.resumen_horas_trabajador((select id from public.workers where active order by created_at limit 1));

-- Con el mes en curso:
select 'resumen_horas_mes' as prueba, *
from public.resumen_horas_mes(to_char(now(), 'YYYY-MM'));


-- ----------------------------------------------------------------------------
-- PASO 3 · ¿Hay fichajes que resumir?
--   Si sale 0, las funciones estarían devolviendo vacío y no habría error
--   ninguno: simplemente no hay horas. Conviene descartarlo.
-- ----------------------------------------------------------------------------
select
  (select count(*) from public.time_logs)                            as fichajes_totales,
  (select count(*) from public.time_logs where check_out is not null) as fichajes_cerrados,
  (select count(*) from public.projects)                             as obras,
  (select count(*) from public.workers where active)                 as trabajadores_activos,
  (select min(check_in) from public.time_logs)                       as fichaje_mas_antiguo,
  (select max(check_in) from public.time_logs)                       as fichaje_mas_reciente;
