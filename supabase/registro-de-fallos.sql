-- ============================================================================
-- OPERTRA · Registro central de fallos
-- ============================================================================
-- EL PROBLEMA QUE RESUELVE
--
-- Con cien empresas usando la app, si algo se rompe para treinta de ellas no
-- te enteras hasta que llama la primera — y para entonces llevan dos días
-- peleándose con ello y pensando que la app es mala. Sin esto, tu única
-- fuente de información sobre errores son las llamadas de clientes
-- enfadados.
--
-- La app ya guarda los últimos fallos en el móvil de cada persona, que sirve
-- para cuando alguien llama. Esta tabla es el otro lado: que lleguen a ti
-- solos, para poder arreglarlos ANTES de que nadie llame.
--
-- QUÉ SE GUARDA Y QUÉ NO
--   Se guarda: mensaje técnico del fallo, en qué pantalla ocurrió, hora,
--   empresa y navegador. Sirve para reproducirlo y arreglarlo.
--
--   NO se guarda ningún dato personal: ni nombres, ni PINs, ni correos, ni
--   contenido de fichas. Esto importa por dos motivos. Uno legal: menos
--   datos personales, menos obligaciones (minimización, RGPD art. 5.1.c).
--   Y otro práctico: una tabla de errores es de lo primero que se consulta
--   con prisa y sin pensar, y no debe contener nada delicado.
--
-- QUIÉN PUEDE VER QUÉ
--   Cualquiera puede APUNTAR un fallo (si no, no llegarían los de las
--   pantallas de acceso, donde todavía no hay sesión). Pero LEER solo puede
--   el dueño de Opertra. Una empresa no puede ver los fallos de otra ni los
--   suyos propios: no le aportan nada y es superficie de más.
--
-- Es seguro ejecutarlo varias veces.
-- ============================================================================

create table if not exists public.app_errors (
  id           bigserial primary key,
  created_at   timestamptz not null default now(),
  company_id   uuid,                 -- puede ser null: fallos antes de entrar
  origen       text,                 -- 'error' | 'promesa' | nombre de la funcion
  mensaje      text,
  donde        text,                 -- archivo:linea, o pista del sitio
  pantalla     text,                 -- que pestaña estaba abierta
  version      text,                 -- version legal, sirve de version de la app
  navegador    text
);

create index if not exists idx_app_errors_created on public.app_errors (created_at desc);
create index if not exists idx_app_errors_mensaje on public.app_errors (mensaje);

alter table public.app_errors enable row level security;

-- --- Apuntar: abierto, porque los fallos mas interesantes son justo los que
--- pasan antes de poder iniciar sesion.
drop policy if exists app_errors_insert on public.app_errors;
create policy app_errors_insert on public.app_errors
  for insert to anon, authenticated
  with check (true);

-- --- Leer: solo el dueño de Opertra.
drop policy if exists app_errors_select on public.app_errors;
create policy app_errors_select on public.app_errors
  for select to authenticated
  using (public.soy_opertra_admin());

-- ----------------------------------------------------------------------------
-- FRENO ANTI-INUNDACIÓN
--   Un bucle en el navegador de un cliente podría mandar miles de apuntes en
--   un minuto y llenar la base. La app ya se limita a 25 por sesión, pero eso
--   vive en el navegador y cualquiera se lo salta. El límite de verdad va
--   aquí: como mucho 500 apuntes por hora en total.
-- ----------------------------------------------------------------------------
create or replace function public.app_errors_limitar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ultima_hora int;
begin
  select count(*) into v_ultima_hora
  from public.app_errors
  where created_at > now() - interval '1 hour';

  if v_ultima_hora >= 500 then
    -- Se descarta en silencio: no tiene sentido devolver un error a la app
    -- por no haber podido apuntar un error.
    return null;
  end if;
  return new;
end $$;

drop trigger if exists trg_app_errors_limitar on public.app_errors;
create trigger trg_app_errors_limitar
  before insert on public.app_errors
  for each row execute function public.app_errors_limitar();

-- ----------------------------------------------------------------------------
-- LIMPIEZA AUTOMÁTICA
--   Un fallo de hace tres meses no sirve para nada y ocupa. 90 días sobra.
--   Se engancha a la purga nocturna que ya tienes montada.
-- ----------------------------------------------------------------------------
create or replace function public.opertra_purgar_fallos_antiguos()
returns integer language plpgsql security definer set search_path = public as $$
declare v_borrados int;
begin
  delete from public.app_errors where created_at < now() - interval '90 days';
  get diagnostics v_borrados = row_count;
  return v_borrados;
end $$;

-- ============================================================================
-- CÓMO MIRARLO (esto es lo que usarás tú)
-- ============================================================================
-- Los fallos más repetidos de la última semana, que es por donde se empieza:
--
--   select mensaje, pantalla, count(*) as veces,
--          count(distinct company_id) as empresas_afectadas,
--          max(created_at) as ultima_vez
--   from public.app_errors
--   where created_at > now() - interval '7 days'
--   group by mensaje, pantalla
--   order by empresas_afectadas desc, veces desc
--   limit 20;
--
-- Ordenado por EMPRESAS AFECTADAS y no por número de veces a propósito: un
-- fallo que le pasa 300 veces a un solo cliente suele ser un bucle raro suyo;
-- uno que le pasa 3 veces a 30 clientes distintos es un problema de verdad.
-- ============================================================================
