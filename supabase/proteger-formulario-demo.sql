-- ============================================================================
-- OPERTRA · Protección del formulario público de demo (demo_leads)
-- ============================================================================
-- POR QUÉ HACE FALTA ESTO
--
-- El formulario de "Solicitar demo" de la landing tiene que poder usarlo
-- cualquiera SIN haber iniciado sesión — si no, no serviría de nada. Eso
-- significa que la política RLS de demo_leads permite INSERT al rol anon, o
-- sea: a todo internet. Un bot de spam puede encontrar el endpoint y meter
-- millones de filas en una noche. Consecuencias reales:
--   - Tu bandeja de "solicitudes de demo" se vuelve inútil (basura pura).
--   - La tabla crece sin control y te come la cuota de disco de Supabase.
--   - Con la factura por uso, te cuesta dinero.
--
-- La trampa para bots que ya está en el formulario (el campo oculto
-- "demo-web") frena a los robots tontos, pero vive en el navegador: cualquiera
-- que llame a la API directamente se la salta. El límite de verdad tiene que
-- estar aquí, dentro de Postgres, donde no se puede esquivar.
--
-- QUÉ HACE ESTE ARCHIVO
--   1. Añade una columna ip_hash (huella de la IP, NO la IP).
--   2. Crea un trigger BEFORE INSERT que rechaza:
--        - el mismo correo dos veces en menos de 1 hora,
--        - más de 5 solicitudes de la misma IP en 1 hora,
--        - más de 200 solicitudes en total en 1 hora (freno de emergencia).
--   3. Índices para que esas comprobaciones sean instantáneas.
--
-- SOBRE LA IP Y EL RGPD: no se guarda la IP. Se guarda un hash SHA-256 de la
-- IP + una sal fija. Sirve para contar "¿cuántas van de este mismo sitio?"
-- pero no permite reconstruir la IP ni identificar a nadie — es minimización
-- de datos, que es justo lo que pide el RGPD. Además la fila entera se borra
-- a los 24 meses con opertra_purgar_leads_demo(), que ya tienes programada.
--
-- Es seguro ejecutarlo varias veces: no borra ni modifica ninguna solicitud
-- que ya tengas guardada.
-- ============================================================================

-- pgcrypto trae digest() para el hash. En Supabase suele venir ya activada.
create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- 1. Columna para la huella de la IP
-- ----------------------------------------------------------------------------
alter table public.demo_leads
  add column if not exists ip_hash text;

-- ----------------------------------------------------------------------------
-- 2. El trigger que aplica los límites
-- ----------------------------------------------------------------------------
create or replace function public.demo_leads_limitar_spam()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ip          text;
  v_hash        text;
  v_de_esta_ip  int;
  v_total_hora  int;
  v_mismo_email int;
begin
  -- La IP real del visitante llega en la cabecera x-forwarded-for que pone
  -- el proxy de Supabase. Si por lo que sea no viene, seguimos adelante: es
  -- preferible aceptar una solicitud buena sin poder contarla que perderla.
  v_ip := nullif(
    split_part(
      coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
      ',', 1
    ), '');

  if v_ip is not null then
    -- Hash con sal fija: cuenta repeticiones, no identifica a nadie.
    v_hash := encode(digest('opertra-demo-' || btrim(v_ip), 'sha256'), 'hex');
    new.ip_hash := v_hash;

    select count(*) into v_de_esta_ip
    from public.demo_leads
    where ip_hash = v_hash
      and created_at > now() - interval '1 hour';

    if v_de_esta_ip >= 5 then
      raise exception 'Demasiadas solicitudes seguidas. Inténtalo dentro de un rato.'
        using errcode = '53400';
    end if;
  end if;

  -- El mismo correo pidiendo demo dos veces en una hora es, o un doble clic,
  -- o un bot. En los dos casos sobra la segunda fila.
  if new.email is not null then
    select count(*) into v_mismo_email
    from public.demo_leads
    where lower(email) = lower(new.email)
      and created_at > now() - interval '1 hour';

    if v_mismo_email >= 1 then
      raise exception 'Ya hemos recibido tu solicitud. Te contactamos enseguida.'
        using errcode = '53400';
    end if;
  end if;

  -- Freno de emergencia: si alguien monta un ataque desde muchas IPs a la vez,
  -- esto corta el grifo antes de que la tabla se llene. 200 solicitudes de
  -- demo en una hora no va a pasar nunca por vías normales.
  select count(*) into v_total_hora
  from public.demo_leads
  where created_at > now() - interval '1 hour';

  if v_total_hora >= 200 then
    raise exception 'Formulario saturado temporalmente. Escríbenos por correo.'
      using errcode = '53400';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_demo_leads_limitar_spam on public.demo_leads;
create trigger trg_demo_leads_limitar_spam
  before insert on public.demo_leads
  for each row execute function public.demo_leads_limitar_spam();

-- ----------------------------------------------------------------------------
-- 3. Índices: sin esto, cada envío del formulario recorrería la tabla entera
-- ----------------------------------------------------------------------------
create index if not exists idx_demo_leads_ip_hash_created
  on public.demo_leads (ip_hash, created_at desc);

create index if not exists idx_demo_leads_email_created
  on public.demo_leads (lower(email), created_at desc);

create index if not exists idx_demo_leads_created
  on public.demo_leads (created_at desc);

-- ----------------------------------------------------------------------------
-- COMPROBACIÓN (opcional): ejecuta esto después y pégame el resultado.
-- ----------------------------------------------------------------------------
-- select tgname, tgenabled from pg_trigger
-- where tgrelid = 'public.demo_leads'::regclass and not tgisinternal;
