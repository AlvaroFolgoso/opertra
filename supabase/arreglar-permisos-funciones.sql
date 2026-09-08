-- ============================================================================
-- OPERTRA · Permisos de ejecución de las funciones
-- ============================================================================
--
-- >>> NO HACE FALTA EJECUTARLO. Comprobado el 2026-09-08 con el PASO 1: las
-- >>> 23 funciones ya tenían puede_authenticated = SI, así que los permisos
-- >>> NO eran la causa de "no se pudieron calcular las horas". La causa se
-- >>> busca en supabase/diagnostico-resumenes-horas.sql.
-- >>>
-- >>> Se deja el archivo porque el PASO 1 es una comprobación útil para
-- >>> repetir en el futuro, y porque el PASO 2 es idempotente y sirve de
-- >>> red si algún día se crea una función nueva sin sus permisos.
--
-- ============================================================================
-- EL SÍNTOMA
--   Entras en una obra o en un trabajador, sale "Calculando horas..." dando
--   vueltas tres o cuatro segundos, y acaba en "No se pudieron calcular las
--   horas". En la consola del navegador aparece el motivo real:
--
--       permission denied for function resumen_horas_mes   (código 42501)
--
-- POR QUÉ PASA
--   En Postgres, crear una función no basta para que se pueda llamar: hay
--   que dar permiso de EXECUTE al rol que la va a usar. En Supabase esos
--   roles son 'authenticated' (quien ha iniciado sesión con correo) y 'anon'
--   (el navegador sin sesión, que es como entra el personal de obra con PIN).
--
--   Si una función se creó sin ese permiso, la app la llama, Postgres la
--   rechaza, y lo único que se ve es el mensaje genérico de error.
--
-- QUÉ HACE ESTE ARCHIVO
--   1. PRIMERO te enseña cómo están los permisos ahora mismo (PASO 1), para
--      que veamos exactamente cuáles fallan.
--   2. Da los permisos que faltan, uno por uno y con el rol que corresponde
--      a cada función.
--
-- IMPORTANTE SOBRE LA SEGURIDAD
--   Dar EXECUTE no abre ningún agujero: estas funciones son SECURITY DEFINER
--   y comprueban por dentro quién llama y a qué empresa pertenece. El
--   permiso solo dice "puedes intentar llamarla"; lo que devuelve lo sigue
--   decidiendo la propia función. Las de administración (panel_empresas,
--   renovar_empresa, soy_opertra_admin) NO se tocan aquí: esas solo las usa
--   el dueño y ya comprueban contra la tabla opertra_admins.
--
-- Pega el PASO 1, mándame el resultado, y ejecuta el PASO 2.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- PASO 1 · ¿Cómo están los permisos ahora?
--   Mándame esta tabla. Las que salgan con "authenticated=NO" son las que
--   están rotas.
-- ----------------------------------------------------------------------------
select p.proname as funcion,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'SI' else 'NO' end as puede_authenticated,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'SI' else 'NO' end as puede_anon,
       case when p.prosecdef then 'SECURITY DEFINER' else 'normal' end as tipo
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'resumen_horas_mes','resumen_horas_obra','resumen_horas_trabajador',
    'worker_login','worker_datos','worker_estado','worker_fichar',
    'worker_fichar_pendiente','worker_incidencias','worker_lecturas',
    'worker_reportar_incidencia',
    'puedo_intentar','fallo_de_acceso','acceso_correcto',
    'pin_libre','siguiente_codigo','ultima_lectura_maquina',
    'crear_mi_empresa','registrar_aceptacion_legal',
    'cerrar_jornadas_olvidadas','limpiar_incidencias_antiguas',
    'archivos_huerfanos','uso_almacenamiento'
  )
order by puede_authenticated, p.proname;


-- ----------------------------------------------------------------------------
-- PASO 2 · Dar los permisos que faltan
--   Es seguro ejecutarlo aunque ya los tuvieran: GRANT sobre un permiso que
--   ya existe no hace nada. No modifica ni borra ningún dato.
-- ----------------------------------------------------------------------------

-- --- Resúmenes de horas: los pide el administrador desde la app ---
-- Son las tres de "No se pudieron calcular las horas".
grant execute on function public.resumen_horas_mes(text)              to authenticated;
grant execute on function public.resumen_horas_obra(uuid)             to authenticated;
grant execute on function public.resumen_horas_trabajador(uuid)       to authenticated;

-- --- Utilidades del administrador ---
grant execute on function public.pin_libre()                          to authenticated;
grant execute on function public.siguiente_codigo(text)               to authenticated;
grant execute on function public.ultima_lectura_maquina(uuid)         to authenticated;
grant execute on function public.crear_mi_empresa(text, text, text, text, text, text) to authenticated;
grant execute on function public.registrar_aceptacion_legal(text)     to authenticated;
grant execute on function public.cerrar_jornadas_olvidadas()          to authenticated;
grant execute on function public.limpiar_incidencias_antiguas()       to authenticated;
grant execute on function public.archivos_huerfanos()                 to authenticated;
grant execute on function public.uso_almacenamiento()                 to authenticated;

-- --- Personal de obra: entra con PIN, SIN sesión, o sea como rol 'anon' ---
-- Estas TIENEN que estar abiertas a anon o nadie podría fichar. La seguridad
-- la pone la propia función, que exige el PIN correcto en cada llamada.
grant execute on function public.worker_login(text, text)             to anon, authenticated;
grant execute on function public.puedo_intentar(text)                 to anon, authenticated;
grant execute on function public.fallo_de_acceso(text)                to anon, authenticated;
grant execute on function public.acceso_correcto(text)                to anon, authenticated;

-- El resto de funciones del trabajador llevan su worker_id y su PIN, y los
-- validan por dentro antes de devolver o escribir nada.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('worker_datos','worker_estado','worker_fichar',
                        'worker_fichar_pendiente','worker_incidencias',
                        'worker_lecturas','worker_reportar_incidencia')
  loop
    execute format('grant execute on function %s to anon, authenticated', f.firma);
  end loop;
end $$;

-- Y por si alguna de las de arriba tiene la firma con otros tipos de los que
-- he supuesto, esta pasada da el permiso por nombre, sin depender de ellos.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('resumen_horas_mes','resumen_horas_obra',
                        'resumen_horas_trabajador','pin_libre','siguiente_codigo',
                        'ultima_lectura_maquina','crear_mi_empresa',
                        'registrar_aceptacion_legal','cerrar_jornadas_olvidadas',
                        'limpiar_incidencias_antiguas','archivos_huerfanos',
                        'uso_almacenamiento')
  loop
    execute format('grant execute on function %s to authenticated', f.firma);
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- PASO 3 · Volver a mirar cómo han quedado
--   Aquí ya deberían salir todas con "SI" en la columna que les toca.
-- ----------------------------------------------------------------------------
select p.proname as funcion,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'SI' else 'NO' end as puede_authenticated,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'SI' else 'NO' end as puede_anon
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'resumen_horas_mes','resumen_horas_obra','resumen_horas_trabajador',
    'worker_login','worker_datos','worker_estado','worker_fichar',
    'worker_fichar_pendiente','worker_incidencias','worker_lecturas',
    'worker_reportar_incidencia',
    'puedo_intentar','fallo_de_acceso','acceso_correcto',
    'pin_libre','siguiente_codigo','ultima_lectura_maquina',
    'crear_mi_empresa','registrar_aceptacion_legal',
    'cerrar_jornadas_olvidadas','limpiar_incidencias_antiguas',
    'archivos_huerfanos','uso_almacenamiento'
  )
order by puede_authenticated, p.proname;
