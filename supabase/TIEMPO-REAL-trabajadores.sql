-- ============================================================================
-- OPERTRA · TIEMPO REAL PARA EL PERSONAL DE OBRA (2026-09-18)
-- Ejecutar ENTERO, de una vez, en el SQL Editor de Supabase. Debe dar "Success".
--
-- Qué hace: cada vez que se crea, cambia o borra una obra, una máquina, un
-- trabajador o una incidencia, la base de datos emite un aviso por el canal
-- "empresa-<id de la empresa>" (Supabase Realtime, tipo "broadcast").
-- Los móviles de los trabajadores de esa empresa escuchan ese canal y, al
-- recibir el aviso, vuelven a pedir sus datos. En el aviso NO viaja ningún
-- dato: solo el nombre de la tabla y la operación.
--
-- El aviso nunca puede bloquear un guardado: si Realtime fallara, el
-- disparador se traga el error y la fila se guarda igual.
-- ============================================================================

create or replace function public.avisar_cambio_empresa()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_company uuid;
begin
  v_company := coalesce(
    case when TG_OP = 'DELETE' then null else NEW.company_id end,
    case when TG_OP = 'INSERT' then null else OLD.company_id end
  );
  if v_company is not null then
    begin
      perform realtime.send(
        jsonb_build_object('tabla', TG_TABLE_NAME, 'op', TG_OP),
        'cambio',
        'empresa-' || v_company::text,
        false
      );
    exception when others then
      null;   -- el aviso es secundario: nunca frena el guardado
    end;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_aviso_projects  on public.projects;
drop trigger if exists trg_aviso_machines  on public.machines;
drop trigger if exists trg_aviso_workers   on public.workers;
drop trigger if exists trg_aviso_incidents on public.incidents;

create trigger trg_aviso_projects  after insert or update or delete on public.projects
  for each row execute function public.avisar_cambio_empresa();
create trigger trg_aviso_machines  after insert or update or delete on public.machines
  for each row execute function public.avisar_cambio_empresa();
create trigger trg_aviso_workers   after insert or update or delete on public.workers
  for each row execute function public.avisar_cambio_empresa();
create trigger trg_aviso_incidents after insert or update or delete on public.incidents
  for each row execute function public.avisar_cambio_empresa();

-- Comprobación (opcional, en otra consulta):
-- select tgname, tgrelid::regclass from pg_trigger where tgname like 'trg_aviso_%';
