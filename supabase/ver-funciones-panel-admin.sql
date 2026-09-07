-- ============================================================================
-- OPERTRA · Revisión de las funciones del Panel Opertra (super-admin)
-- ============================================================================
-- soy_opertra_admin(), panel_empresas() y renovar_empresa() son las
-- funciones más sensibles de todo el sistema: dan acceso a los datos y a la
-- facturación de las 100 empresas a la vez, no solo a una. El código del
-- navegador (index.html) comprueba "soyDuenoOpertra" antes de mostrar el
-- botón del panel, pero eso es solo para no enseñar un botón que no sirve
-- de nada — CUALQUIERA puede abrir la consola del navegador y llamar a
-- estas funciones directamente, sin pasar por ningún botón. La única
-- protección de verdad tiene que estar DENTRO de cada función, en el propio
-- Postgres: que compruebe quién la está llamando (auth.uid()) contra la
-- tabla opertra_admins antes de devolver o cambiar nada.
--
-- Pega esto en el SQL Editor de Supabase y pégame el resultado — reviso que
-- las tres se protegen a sí mismas de verdad, no solo la pantalla que las
-- envuelve.
-- ============================================================================

select p.proname, pg_get_functiondef(p.oid) as definicion
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('soy_opertra_admin', 'panel_empresas', 'renovar_empresa');
