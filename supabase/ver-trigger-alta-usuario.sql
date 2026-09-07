-- ============================================================================
-- OPERTRA · Ver el disparador que crea empresa+perfil al registrarse
-- ============================================================================
-- El código de la app (loadCurrentUserProfile, en index.html) espera que, si
-- alguien entra con Google por primera vez SIN haberse registrado antes, no
-- exista ninguna fila en "profiles" para él — y entonces le pide los datos
-- de su empresa antes de dejarle entrar. Pero quién crea (o no) esa fila de
-- perfil es un disparador dentro de la propia base de datos (handle_new_user,
-- sobre auth.users), que yo no puedo ver desde aquí.
--
-- Pega esto en el SQL Editor de Supabase y pégame el resultado — así reviso
-- si ese disparador crea la empresa sin más para cualquier cuenta nueva
-- (el fallo que estás viendo: entras con Google y ya estás dentro, sin que
-- nadie pida los datos de la empresa) o si de verdad exige los metadatos
-- "pending_company_name" que solo pone signUp() por correo.
-- ============================================================================

select pg_get_functiondef(p.oid) as definicion_handle_new_user
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.proname = 'handle_new_user';

-- Y esto enseña sobre qué evento está enganchado el disparador (para
-- confirmar que de verdad es "on auth.users after insert" y no otra cosa):
select trigger_name, event_manipulation, event_object_table, action_timing
from information_schema.triggers
where trigger_name ilike '%new_user%' or trigger_name ilike '%handle_new%';
