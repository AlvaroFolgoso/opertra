-- ============================================================================
-- OPERTRA · ARREGLO · La purga legal automática estaba fallando cada noche
-- ============================================================================
--
-- EL PROBLEMA (comprobado en cron.job_run_details el 2026-09-08):
--   El trabajo nocturno "opertra-purga-legal-diaria" salía FAILED con:
--     "Direct deletion from storage tables is not allowed. Use the Storage API"
--   Supabase ha empezado a PROHIBIR borrar ficheros del almacén con SQL
--   (delete from storage.objects). Como toda la purga va en una sola
--   operación, al fallar ese borrado se caía la purga ENTERA y no se borraba
--   NADA: ni fichajes de +4 años, ni facturación de +6, ni leads, ni
--   documentos caducados, ni empresas dadas de baja. Incumplimiento de los
--   plazos legales de conservación de datos (RGPD).
--
-- EL ARREGLO (sin inventar nada nuevo):
--   1. Se quita el "delete from storage.objects" de las tres funciones que lo
--      usaban. Al borrar la FILA, el fichero queda huérfano y el barrido
--      nocturno que YA tienes (limpiar_archivos_auto, job 8) lo elimina por la
--      vía correcta (la Storage API). Ese barrido borra cualquier fichero sin
--      dueño de más de 2 días, así que cubre estos casos.
--   2. Se hace la purga diaria RESISTENTE: cada paso va en su propio bloque,
--      de modo que si uno falla, se apunta el error pero los demás SÍ se
--      ejecutan. Antes, un fallo tumbaba todo.
--
-- Es seguro ejecutarlo: CREATE OR REPLACE no borra datos, solo cambia cómo se
-- comportarán las funciones a partir de ahora. Los permisos que ya tenían
-- (incluido el REVOKE que acabas de aplicar) se conservan.
-- ============================================================================


-- 1) Trabajadores inactivos: se borra la fila; la foto la limpia el barrido nocturno
create or replace function public.opertra_purgar_trabajadores_inactivos()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  -- Antes había aquí un "delete from storage.objects" que Supabase ya no
  -- permite y que rompía la purga. Se retira: al borrar la fila del
  -- trabajador, su foto queda huérfana y limpiar_archivos_auto (cada noche)
  -- la elimina por la Storage API.
  delete from workers w
  where w.active = false
    and w.updated_at < now() - interval '4 years'
    and not exists (select 1 from time_logs tl where tl.worker_id = w.id);
  get diagnostics n = row_count;
  return n;
end;
$function$;


-- 2) Documentos caducados: igual, se borra la fila; el fichero lo limpia el barrido
create or replace function public.opertra_purgar_documentos_caducados()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  delete from documents
  where expiry_date is not null
    and expiry_date < (now() - interval '4 years')::date;
  get diagnostics n = row_count;
  return n;
end;
$function$;


-- 3) Empresas dadas de baja: se borran todas sus filas; sus ficheros quedan
--    huérfanos y el barrido nocturno los elimina.
create or replace function public.opertra_purgar_empresas_baja()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  empresa record;
  n integer := 0;
begin
  for empresa in
    select id from companies
    where borrar_datos_el is not null and borrar_datos_el < now()
  loop
    -- (Se retira el 'delete from storage.objects': lo hace limpiar_archivos_auto)
    delete from time_logs where worker_id in (select id from workers where company_id = empresa.id);
    delete from incidents where company_id = empresa.id;
    delete from vacations where company_id = empresa.id;
    delete from documents where company_id = empresa.id;
    delete from invoices  where company_id = empresa.id;
    delete from machines  where company_id = empresa.id;
    delete from workers   where company_id = empresa.id;
    delete from projects  where company_id = empresa.id;
    delete from clients   where company_id = empresa.id;
    delete from profiles  where company_id = empresa.id;
    delete from companies where id = empresa.id;
    n := n + 1;
  end loop;
  return n;
end;
$function$;


-- 4) La purga diaria, ahora RESISTENTE: si un paso falla, se apunta y sigue
create or replace function public.opertra_purga_legal_diaria()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  resultado jsonb := '{}'::jsonb;
  v integer;
begin
  begin v := opertra_purgar_registro_jornada();
    resultado := resultado || jsonb_build_object('registro_jornada_borrados', v);
  exception when others then
    resultado := resultado || jsonb_build_object('registro_jornada_ERROR', sqlerrm);
  end;

  begin v := opertra_purgar_trabajadores_inactivos();
    resultado := resultado || jsonb_build_object('trabajadores_inactivos_borrados', v);
  exception when others then
    resultado := resultado || jsonb_build_object('trabajadores_inactivos_ERROR', sqlerrm);
  end;

  begin v := opertra_purgar_documentos_caducados();
    resultado := resultado || jsonb_build_object('documentos_caducados_borrados', v);
  exception when others then
    resultado := resultado || jsonb_build_object('documentos_caducados_ERROR', sqlerrm);
  end;

  begin v := opertra_purgar_leads_demo();
    resultado := resultado || jsonb_build_object('leads_demo_borrados', v);
  exception when others then
    resultado := resultado || jsonb_build_object('leads_demo_ERROR', sqlerrm);
  end;

  begin v := opertra_purgar_facturacion_antigua();
    resultado := resultado || jsonb_build_object('facturacion_antigua_borrada', v);
  exception when others then
    resultado := resultado || jsonb_build_object('facturacion_antigua_ERROR', sqlerrm);
  end;

  begin v := opertra_marcar_empresas_para_borrado();
    resultado := resultado || jsonb_build_object('empresas_marcadas_para_borrado', v);
  exception when others then
    resultado := resultado || jsonb_build_object('empresas_marcadas_ERROR', sqlerrm);
  end;

  begin v := opertra_purgar_empresas_baja();
    resultado := resultado || jsonb_build_object('empresas_dadas_de_baja_borradas', v);
  exception when others then
    resultado := resultado || jsonb_build_object('empresas_baja_ERROR', sqlerrm);
  end;

  insert into opertra_purga_log (detalle) values (resultado);
end;
$function$;


-- ============================================================================
-- COMPROBAR QUE HA QUEDADO ARREGLADO
-- ============================================================================
-- Ejecuta esta línea para lanzar la purga a mano una vez (es de bajo riesgo:
-- solo borra datos con MUCHOS años, y ahora mismo la app es nueva, así que
-- lo normal es que salgan ceros o números pequeños):
--
--   select public.opertra_purga_legal_diaria();
--
-- Y mira el último resultado apuntado (debe salir con números, SIN ninguna
-- clave que acabe en "_ERROR"):
--
--   select * from public.opertra_purga_log order by ctid desc limit 1;
-- ============================================================================
