-- ============================================================================
-- OPERTRA · HISTORIAL DE CAMBIOS: retención de 12 meses (2026-09-18)
-- Ejecutar ENTERO, de una vez, en el SQL Editor de Supabase. Debe dar "Success".
--
-- El historial (tabla audit_log) es una ayuda para el responsable: "quién
-- cambió qué y cuándo". No es el registro legal de jornada: las
-- correcciones de fichaje quedan en la propia tabla time_logs (quién, cuándo,
-- motivo y valores originales) y se conservan los 4 años que exige la ley.
-- Por eso el historial se puede podar sin riesgo: cada noche se borran las
-- entradas de hace más de 12 meses. Así una empresa con mucho movimiento no
-- acumula decenas de miles de filas que nadie va a mirar.
-- ============================================================================

-- Índice para que la pantalla (ordenada por fecha, por empresa) vaya rápida
create index if not exists audit_log_company_created
  on public.audit_log (company_id, created_at desc);

-- Poda nocturna (03:20, hora del servidor). Si ya existía, se sustituye.
do $$
begin
  perform cron.unschedule('podar_historial_cambios');
exception when others then
  null;   -- no existía: no pasa nada
end $$;

select cron.schedule(
  'podar_historial_cambios',
  '20 3 * * *',
  $$ delete from public.audit_log where created_at < now() - interval '12 months' $$
);

-- Comprobación (opcional, en otra consulta):
-- select jobname, schedule, active from cron.job where jobname = 'podar_historial_cambios';
