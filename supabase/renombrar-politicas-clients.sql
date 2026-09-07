-- ============================================================================
-- OPERTRA · Renombrar las políticas RLS de "clients"
-- ============================================================================
-- Las 4 políticas de la tabla clients se crearon copiando las de projects y
-- se quedaron con ese nombre (projects_select, projects_insert, etc.) sobre
-- la tabla equivocada en el nombre. La condición de cada una SÍ es correcta
-- (compara clients.company_id con auth_company_id()) — esto es solo para que
-- el nombre no despiste a quien mire el panel de Supabase más adelante.
--
-- Pégalo y ejecútalo una vez en el SQL Editor de Supabase.
-- ============================================================================

alter policy "projects_select" on public.clients rename to "clients_select";
alter policy "projects_insert" on public.clients rename to "clients_insert";
alter policy "projects_update" on public.clients rename to "clients_update";
alter policy "projects_delete" on public.clients rename to "clients_delete";

-- Comprobación: debe salir "clients" y los 4 nombres nuevos.
select tablename, policyname from pg_policies where tablename = 'clients' order by policyname;
