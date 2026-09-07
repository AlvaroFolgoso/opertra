-- ============================================================================
-- OPERTRA · De dónde sale el valor inicial de borrar_datos_el
-- ============================================================================
-- Ya sabemos que renovar_empresa() lo pone a NULL cuando confirmas que una
-- empresa ha pagado. Falta ver quién le pone el valor la primera vez (al
-- crear la empresa, imagino) para confirmar que el sistema manual de antes
-- de Stripe ya es coherente de punta a punta, y de paso ver el estado real
-- de tu propia empresa ahora mismo.
--
-- Pega esto y pégame el resultado de las dos consultas.
-- ============================================================================

-- 1. La función que crea la empresa nueva (donde debería fijarse el valor
--    inicial de trial_ends_at / borrar_datos_el):
select pg_get_functiondef(p.oid) as definicion_crear_mi_empresa
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'crear_mi_empresa';

-- 2. Estado real de todas las empresas que tengas ahora mismo (debería ser
--    solo la tuya de pruebas, o pocas más):
select name, created_at, trial_ends_at, borrar_datos_el,
       (borrar_datos_el is not null and borrar_datos_el < now()) as se_borraria_ya
from public.companies
order by created_at;
