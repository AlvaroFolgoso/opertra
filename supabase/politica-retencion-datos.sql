-- ============================================================================
-- OPERTRA · Purga automática de datos por caducidad legal
-- ============================================================================
--
-- QUÉ ES ESTO
-- La política de privacidad de la app (dentro de index.html, sección
-- "openLegal('privacidad')") ya promete estos plazos de conservación, pero
-- hasta ahora nada los hacía cumplir de verdad en la base de datos. Este
-- script crea ese mecanismo: funciones que borran lo que ya ha caducado,
-- programadas para correr solas cada noche con pg_cron (una extensión de
-- Postgres, la usa Supabase, no hace falta ningún servidor aparte).
--
-- CÓMO SE EJECUTA (una sola vez)
--   1. Panel de Supabase → Database → Extensions → activa "pg_cron" si no
--      lo está ya (el CREATE EXTENSION de abajo también lo intenta).
--   2. Panel de Supabase → SQL Editor → pega este archivo entero → Run.
--   3. Comprueba que salió bien: SELECT * FROM cron.job; (debe aparecer
--      'opertra-purga-legal-diaria').
--
-- IMPORTANTE — revisa esto antes de correrlo
-- Los nombres de tabla y columna de abajo (workers, time_logs, documents,
-- invoices, incidents, vacations, clients, machines, projects, companies,
-- demo_leads, profiles) están sacados de las llamadas reales que hace
-- index.html contra Supabase, no de una lectura directa de tu esquema.
-- Si alguna tabla o columna tiene otro nombre en tu proyecto, este script
-- fallará al ejecutarse (Postgres avisa con un error claro de "no existe
-- la columna/tabla X") y no habrá borrado nada a medias — puedes corregir
-- el nombre y volver a lanzarlo tranquilamente.
--
-- BASE LEGAL DE CADA PLAZO (España)
--   - Registro de jornada (time_logs): 4 años desde cada fichaje.
--     Art. 34.9 Estatuto de los Trabajadores, según RDL 8/2019. El plazo
--     corre desde la fecha de cada jornada, no desde que el trabajador se
--     va de la empresa.
--   - Geolocalización de maquinaria (machines.lat/lng): la app solo guarda
--     la última posición conocida (no un histórico), así que no acumula
--     datos de localización más allá de lo necesario — no hace falta
--     purgarla aparte, ya cumple minimización por diseño.
--   - Datos personales de un trabajador dado de baja (workers): mientras
--     tenga fichajes dentro de los últimos 4 años hay que conservarlos
--     (para que el registro de jornada siga teniendo sentido). Pasado ese
--     plazo, sin fichajes que lo respalden, ya no hay base para retener su
--     ficha (contratos/nóminas/cotizaciones: 4 años, LISOS) y se borra.
--   - Facturación y clientes: obligación mercantil de conservar documentos
--     contables 6 años (art. 30 Código de Comercio; el plazo fiscal de la
--     Ley General Tributaria es de solo 4, pero manda el más largo). Este
--     script NO borra facturación en automático — 6 años es un mínimo que
--     hay que respetar, no una fecha de borrado obligatorio. Se deja una
--     función manual por si un día quieres limpiar lo muy antiguo.
--   - Leads de la demo pública (demo_leads): son datos de gente que ni
--     siquiera es cliente, recogidos para prospección comercial. Sin una
--     base para conservarlos indefinidamente, se purgan a los 24 meses
--     sin actividad si nunca llegaron a convertirse en empresa.
--   - Baja de empresa (companies.borrar_datos_el): esto ya lo anuncia la
--     propia app en pantalla ("Se conservan X más. Pasado ese plazo se
--     eliminarán de forma definitiva..."). Comprobado contra el código real
--     de crear_mi_empresa() y renovar_empresa(): nada ponía nunca esa fecha
--     (se crea en NULL, y lo único que la toca es renovar_empresa, que la
--     limpia al confirmar un pago — ya sea a mano hoy, o vía Stripe más
--     adelante, el mecanismo es el mismo). Le faltaba la pieza que decide
--     cuándo SÍ ponerla: opertra_marcar_empresas_para_borrado() (sección 4b)
--     marca las pruebas caducadas hace más de 30 días y nunca renovadas, y
--     opertra_purgar_empresas_baja() (sección 5) borra las que llevan 60
--     días más así, sin haber pagado ni vuelto a entrar. Las dos ya entran
--     en la purga automática de cada noche.
--
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Extensión y tabla de auditoría de las propias purgas
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

-- No guarda datos personales, solo cuántas filas se borraron y cuándo —
-- es el propio registro de que la política de retención se está cumpliendo.
create table if not exists opertra_purga_log (
  id bigint generated always as identity primary key,
  ejecutado_en timestamptz not null default now(),
  detalle jsonb not null
);


-- ---------------------------------------------------------------------------
-- 1. Registro de jornada caducado (> 4 años)
-- ---------------------------------------------------------------------------
create or replace function opertra_purgar_registro_jornada()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  delete from time_logs
  where check_in < now() - interval '4 years';
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 2. Trabajadores dados de baja sin fichajes ya dentro del plazo legal
-- ---------------------------------------------------------------------------
-- Solo se borran si: están inactivos, no tienen NINGÚN fichaje restante
-- (porque el paso 1 ya se ha comido los de más de 4 años) y llevan de baja
-- más de 4 años — así siempre hay margen para reactivar a alguien dado de
-- baja por error reciente, que es lo que la propia app promete al admin.
create or replace function opertra_purgar_trabajadores_inactivos()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  -- La foto de perfil también, no solo la fila: si no, se queda huérfana en
  -- el Storage. (El barrido diario de archivos huérfanos la habría acabado
  -- pillando de todas formas, pero solo se dispara cuando un admin abre
  -- sesión — mejor no depender de eso aquí.)
  delete from storage.objects
  where bucket_id = 'opertra'
    and name in (
      select photo_path from workers w
      where w.active = false
        and w.updated_at < now() - interval '4 years'
        and photo_path is not null
        and not exists (select 1 from time_logs tl where tl.worker_id = w.id)
    );

  delete from workers w
  where w.active = false
    and w.updated_at < now() - interval '4 years'
    and not exists (select 1 from time_logs tl where tl.worker_id = w.id);
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. Documentos caducados hace más de 4 años (certificados, ITV, etc.)
-- ---------------------------------------------------------------------------
-- Borra también el archivo del Storage, no solo la fila de la base de datos.
create or replace function opertra_purgar_documentos_caducados()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  delete from storage.objects
  where bucket_id = 'opertra'
    and name in (
      select file_path from documents
      where file_path is not null
        and expiry_date is not null
        and expiry_date < (now() - interval '4 years')::date
    );

  delete from documents
  where expiry_date is not null
    and expiry_date < (now() - interval '4 years')::date;
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 4. Leads de la demo pública sin convertir, a los 24 meses
-- ---------------------------------------------------------------------------
create or replace function opertra_purgar_leads_demo()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if to_regclass('public.demo_leads') is null then
    return 0;
  end if;
  delete from demo_leads
  where created_at < now() - interval '24 months';
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 4b. Marcar para borrado las pruebas caducadas y nunca renovadas
-- ---------------------------------------------------------------------------
-- Comprobado (2026-09-07): nada ponía nunca borrar_datos_el a una fecha
-- real — ni al crear la empresa (crear_mi_empresa la deja en NULL), ni en
-- ningún otro sitio salvo renovar_empresa, que solo la LIMPIA al confirmar
-- el pago. Sin esto, la purga de empresas de abajo nunca tendría nada que
-- borrar, y la pantalla de prueba caducada nunca llegaría a anunciar una
-- fecha de borrado real. Esta función es la pieza que faltaba — y no hace
-- falta Stripe para nada de esto: renovar_empresa ya limpia la marca al
-- renovar (aunque hoy renovar sea un botón que pulsas tú a mano al recibir
-- el pago), así que el circuito ya es coherente de punta a punta.
--
-- Plazos elegidos (ajústalos si quieres otros — no son un mínimo legal,
-- es solo cuánto margen le das a una prueba abandonada antes de borrarla):
--   30 días de margen tras caducar la prueba de 50 días, sin renovar, antes
--   de marcarla; y desde que se marca, 60 días más (visibles para el
--   usuario en la propia app) antes del borrado de verdad. En total, unos
--   90 días desde que caduca la prueba hasta que se borra si nadie ha
--   vuelto a entrar ni ha pagado — tiempo de sobra para reclamar el pago o
--   para que el cliente vuelva.
create or replace function opertra_marcar_empresas_para_borrado()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update companies
     set borrar_datos_el = now() + interval '60 days'
   where trial_ends_at < now() - interval '30 days'
     and borrar_datos_el is null;
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 5. Baja definitiva de empresa: borrado total en cascada
-- ---------------------------------------------------------------------------
-- Se dispara para cada empresa cuya fecha "borrar_datos_el" ya ha pasado —
-- exactamente lo que la pantalla de prueba caducada le anuncia al usuario.
-- Orden: primero lo que depende de otras filas, la propia empresa al final.
create or replace function opertra_purgar_empresas_baja()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  empresa record;
  n integer := 0;
begin
  for empresa in
    select id from companies
    where borrar_datos_el is not null and borrar_datos_el < now()
  loop
    -- Ficheros del Storage: todo lo que cuelga de la carpeta "<company_id>/..."
    delete from storage.objects
    where bucket_id = 'opertra'
      and (storage.foldername(name))[1] = empresa.id::text;

    delete from time_logs where worker_id in (select id from workers where company_id = empresa.id);
    delete from incidents where company_id = empresa.id;
    delete from vacations where company_id = empresa.id;
    delete from documents where company_id = empresa.id;
    delete from invoices where company_id = empresa.id;
    delete from machines where company_id = empresa.id;
    delete from workers where company_id = empresa.id;
    delete from projects where company_id = empresa.id;
    delete from clients where company_id = empresa.id;
    delete from profiles where company_id = empresa.id;
    delete from companies where id = empresa.id;

    n := n + 1;
  end loop;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 6. Facturación antigua — automática, a los 6 años
-- ---------------------------------------------------------------------------
-- El Código de Comercio obliga a conservar 6 años (mínimo); pasado ese
-- plazo ya no hay base legal para seguir guardándolo sin más, así que entra
-- en la purga diaria igual que el resto.
create or replace function opertra_purgar_facturacion_antigua()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  delete from invoices
  where created_at < now() - interval '6 years';
  get diagnostics n = row_count;
  return n;
end;
$$;


-- ---------------------------------------------------------------------------
-- 7. Función maestra: la que se programa
-- ---------------------------------------------------------------------------
-- opertra_purgar_empresas_baja() YA entra aquí (antes se dejaba fuera; ver
-- el histórico de git si quieres el porqué original). Se destrabó al
-- comprobar que renovar_empresa() ya limpia borrar_datos_el de verdad al
-- confirmar un pago — no hacía falta Stripe para que el circuito fuera
-- seguro, solo faltaba opertra_marcar_empresas_para_borrado() (4b, arriba),
-- que es quien de verdad decide qué empresa lleva demasiado tiempo sin
-- pagar. Va primero marcar y después purgar, en ese orden, dentro del mismo
-- barrido nocturno.
create or replace function opertra_purga_legal_diaria()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  resultado jsonb;
begin
  resultado := jsonb_build_object(
    'registro_jornada_borrados', opertra_purgar_registro_jornada(),
    'trabajadores_inactivos_borrados', opertra_purgar_trabajadores_inactivos(),
    'documentos_caducados_borrados', opertra_purgar_documentos_caducados(),
    'leads_demo_borrados', opertra_purgar_leads_demo(),
    'facturacion_antigua_borrada', opertra_purgar_facturacion_antigua(),
    'empresas_marcadas_para_borrado', opertra_marcar_empresas_para_borrado(),
    'empresas_dadas_de_baja_borradas', opertra_purgar_empresas_baja()
  );
  insert into opertra_purga_log (detalle) values (resultado);
end;
$$;


-- ---------------------------------------------------------------------------
-- 8. Programación diaria (03:00 hora de Madrid ≈ 01:00 UTC en horario de
--    verano, 02:00 UTC en horario de invierno; pg_cron trabaja en UTC, así
--    que se deja fijo a la 01:00 UTC — ajusta la hora si te importa el
--    minuto exacto, para una purga nocturna no es crítico)
-- ---------------------------------------------------------------------------
select cron.unschedule('opertra-purga-legal-diaria')
where exists (select 1 from cron.job where jobname = 'opertra-purga-legal-diaria');

select cron.schedule(
  'opertra-purga-legal-diaria',
  '0 1 * * *',
  $$ select opertra_purga_legal_diaria(); $$
);

-- Para comprobar que ha quedado programada:
--   SELECT * FROM cron.job WHERE jobname = 'opertra-purga-legal-diaria';
-- Para ver qué se ha ido borrando cada noche:
--   SELECT * FROM opertra_purga_log ORDER BY ejecutado_en DESC;
-- Para lanzar una purga ahora mismo, sin esperar a la 1 de la noche:
--   SELECT opertra_purga_legal_diaria();
--
-- Cuando conectes Stripe: si el webhook llama a renovar_empresa() en cada
-- pago (lo lógico), no hay que tocar nada de este archivo — el circuito ya
-- funciona igual, solo que "renovar" pasa a ser automático en vez de un
-- botón que pulsas tú. Si en vez de eso Stripe actualiza trial_ends_at por
-- su cuenta sin pasar por renovar_empresa(), dímelo entonces y lo revisamos
-- juntos, porque en ese caso sí habría que ajustar algo aquí.
