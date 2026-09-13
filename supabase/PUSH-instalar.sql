-- ============================================================================
-- OPERTRA · INSTALAR AVISOS PUSH (con la app cerrada) + candado de 2 minutos
-- Preparado el 2026-09-13. Ejecutar en el SQL Editor de Supabase,
-- UN BLOQUE CADA VEZ, en este orden. Cada bloque debe dar "Success".
-- ============================================================================


-- ----------------------------------------------------------------------------
-- BLOQUE 1 · Tablas y columna
--   push_config:        las claves VAPID (las crea la funcion la 1a vez).
--   push_subscriptions: un registro por movil suscrito a avisos.
--   time_logs.aviso_enviado_at: para no avisar dos veces de la misma jornada.
--   Ambas tablas con RLS y SIN politicas: ningun navegador las lee ni escribe;
--   solo las funciones SECURITY DEFINER y el servidor (service_role).
-- ----------------------------------------------------------------------------
create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text not null,
  vapid_private text not null,
  created_at timestamptz not null default now()
);
alter table public.push_config enable row level security;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  worker_id uuid not null,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
create index if not exists push_subscriptions_worker on public.push_subscriptions (worker_id);

alter table public.time_logs add column if not exists aviso_enviado_at timestamptz;
create index if not exists time_logs_aviso_pendiente
  on public.time_logs (expected_end)
  where check_out is null and aviso_enviado_at is null;


-- ----------------------------------------------------------------------------
-- BLOQUE 2 · Funciones que usa la app
--   push_clave_publica(): la app la lee para suscribirse. Devuelve null hasta
--   que la funcion enviar-avisos haya arrancado una vez (y creado las claves).
--   worker_guardar_push(): guarda la suscripcion del movil validando el PIN.
-- ----------------------------------------------------------------------------
create or replace function public.push_clave_publica()
returns text
language sql
security definer
set search_path to 'public'
stable
as $$
  select vapid_public from public.push_config where id = 1
$$;
grant execute on function public.push_clave_publica() to anon, authenticated;

create or replace function public.worker_guardar_push(
  p_worker_id uuid, p_pin text, p_endpoint text, p_p256dh text, p_auth text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_company uuid;
begin
  select w.company_id into v_company
    from public.workers w
   where w.id = p_worker_id and w.pin = p_pin and w.active = true;
  if v_company is null then
    perform pg_sleep(0.25);
    raise exception 'PIN incorrecto';
  end if;
  if p_endpoint is null or length(p_endpoint) < 20 or p_p256dh is null or p_auth is null then
    raise exception 'Suscripcion no valida';
  end if;
  insert into public.push_subscriptions (company_id, worker_id, endpoint, p256dh, auth)
  values (v_company, p_worker_id, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
     set worker_id = excluded.worker_id, company_id = excluded.company_id,
         p256dh = excluded.p256dh, auth = excluded.auth, last_used_at = now();
end;
$$;
grant execute on function public.worker_guardar_push(uuid, text, text, text, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- BLOQUE 3 · El reloj: cada minuto llama a la funcion enviar-avisos
--   Requiere la extension pg_net (peticiones HTTP desde la base).
--   El "Bearer" es el secreto AVISOS_SECRET, que tambien hay que guardar en
--   Edge Functions -> Secrets con ese mismo nombre y valor.
--   EJECUTAR UNA SOLA VEZ (si se repite, dara error de nombre duplicado).
-- ----------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'enviar_avisos_fin_jornada',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://uqfnijlmnybqznnnlkqj.supabase.co/functions/v1/enviar-avisos',
    headers := '{"Content-Type":"application/json","Authorization":"Bearer 1467c9d122003619637ab2d35a3a6774100a97a4f27f59d4"}'::jsonb,
    body    := '{}'::jsonb
  );
  $$
);

-- Comprobar que quedo programado (1 fila, active = true):
-- select jobname, schedule, active from cron.job where jobname = 'enviar_avisos_fin_jornada';


-- ----------------------------------------------------------------------------
-- BLOQUE 4 · Candado de 2 minutos en el servidor (worker_fichar_v2)
--   Nada mas fichar la entrada, el boton pasa a "Fichar salida": un toque de
--   mas cerraba la jornada con 0 minutos. La app ya lo frena; esto lo frena
--   tambien en el servidor. Solo en fichaje EN VIVO (p_momento is null): un
--   fichaje guardado sin cobertura trae su hora real y no se toca.
--   Devuelve accion = 'recien_entrado' (la app ya sabe ensenarlo).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.worker_fichar_v2(
  p_worker_id uuid, p_pin text, p_project_id uuid, p_machine_id uuid,
  p_horas_previstas numeric DEFAULT NULL, p_verificado boolean DEFAULT true,
  p_op_id uuid DEFAULT NULL, p_accion text DEFAULT NULL, p_momento timestamptz DEFAULT NULL
)
RETURNS TABLE(log_id uuid, accion text, hora timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_company uuid; v_abierto uuid; v_desde timestamptz; v_momento timestamptz;
  v_accion text; v_l uuid; v_a text; v_h timestamptz; v_check_out timestamptz;
begin
  select w.company_id into v_company from public.workers w
   where w.id = p_worker_id and w.pin = p_pin and w.active = true;
  if v_company is null then raise exception 'PIN incorrecto'; end if;

  if p_op_id is not null then
    select o.log_id, o.accion, o.hora into v_l, v_a, v_h
      from public.fichaje_ops o where o.op_id = p_op_id;
    if found then return query select v_l, v_a, v_h; return; end if;
  end if;

  if p_project_id is not null and not exists (select 1 from public.projects where id = p_project_id and company_id = v_company) then
    p_project_id := null;
  end if;
  if p_machine_id is not null and not exists (select 1 from public.machines where id = p_machine_id and company_id = v_company) then
    p_machine_id := null;
  end if;

  v_momento := p_momento;
  if v_momento is null or v_momento > now() + interval '1 minute' or v_momento < now() - interval '3 days' then
    v_momento := now();
  end if;

  select t.id, t.check_in into v_abierto, v_desde from public.time_logs t
   where t.worker_id = p_worker_id and t.check_out is null limit 1;

  v_accion := case when p_accion = 'entrada' then 'entrada'
                   when p_accion = 'salida'  then 'salida'
                   else (case when v_abierto is not null then 'salida' else 'entrada' end) end;

  if v_accion = 'entrada' then
    if v_abierto is not null then
      v_l := v_abierto; v_a := 'ya_fichado'; v_h := v_desde;
    elsif p_momento is null and p_machine_id is not null and exists (
            select 1 from public.time_logs t
             where t.machine_id = p_machine_id
               and t.check_out is null
               and t.worker_id <> p_worker_id
               and t.company_id = v_company
               and t.check_in > now() - interval '16 hours') then
      v_l := null; v_a := 'maquina_ocupada'; v_h := null;
    else
      insert into public.time_logs (company_id, worker_id, project_id, machine_id,
                                    check_in, method, expected_end, verified)
      values (v_company, p_worker_id, p_project_id, p_machine_id, v_momento, 'app',
              case when p_horas_previstas is null then null
                   else v_momento + (p_horas_previstas || ' hours')::interval end,
              coalesce(p_verificado, true))
      returning id into v_l;
      v_a := 'entrada'; v_h := v_momento;
    end if;
  else
    if v_abierto is null then
      v_l := null; v_a := 'nada_que_cerrar'; v_h := null;
    elsif p_momento is null and v_desde > now() - interval '2 minutes' then
      v_l := v_abierto; v_a := 'recien_entrado'; v_h := v_desde;
    else
      v_check_out := greatest(v_momento, v_desde);
      update public.time_logs set check_out = v_check_out where id = v_abierto;
      v_l := v_abierto; v_a := 'salida'; v_h := v_check_out;
    end if;
  end if;

  if p_op_id is not null and v_a in ('entrada', 'salida') then
    insert into public.fichaje_ops (op_id, company_id, worker_id, log_id, accion, hora)
    values (p_op_id, v_company, p_worker_id, v_l, v_a, v_h)
    on conflict (op_id) do nothing;
  end if;

  return query select v_l, v_a, v_h;

exception when others then
  perform pg_sleep(0.25);
  raise;
end;
$function$;
