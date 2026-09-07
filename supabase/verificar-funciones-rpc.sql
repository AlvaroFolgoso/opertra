-- ============================================================================
-- OPERTRA · Verificación de que todas las funciones RPC existen de verdad
-- ============================================================================
-- La app llama a estas 26 funciones desde el navegador (getSupabase().rpc(...)).
-- Muchas de esas llamadas van dentro de un try/catch silencioso — si una
-- función no existiera de verdad en tu base de datos, la app no avisaría a
-- nadie, simplemente esa parte dejaría de funcionar sin más (es justo lo que
-- pasaba con el GPS: parecía que funcionaba, pero eran datos falsos). Esto
-- comprueba de una vez que las 26 existen.
--
-- Pega esto en el SQL Editor de Supabase y pégame el resultado. Cualquier
-- fila con "existe = false" es una función que la app necesita y no tiene.
-- ============================================================================

with esperadas (nombre) as (
  values
    ('worker_datos'), ('resumen_horas_obra'), ('worker_estado'),
    ('worker_fichar_pendiente'), ('ultima_lectura_maquina'), ('worker_lecturas'),
    ('worker_fichar'), ('cerrar_jornadas_olvidadas'), ('siguiente_codigo'),
    ('pin_libre'), ('resumen_horas_trabajador'), ('worker_reportar_incidencia'),
    ('limpiar_incidencias_antiguas'), ('archivos_huerfanos'), ('worker_incidencias'),
    ('resumen_horas_mes'), ('registrar_aceptacion_legal'), ('puedo_intentar'),
    ('worker_login'), ('fallo_de_acceso'), ('acceso_correcto'),
    ('crear_mi_empresa'), ('soy_opertra_admin'), ('panel_empresas'),
    ('renovar_empresa'), ('uso_almacenamiento')
)
select
  e.nombre,
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = e.nombre
  ) as existe
from esperadas e
order by existe asc, e.nombre;
