-- CARCOVE · 00 · DIAGNÓSTICO (solo lectura, no modifica nada)
-- Ejecútalo en Supabase → SQL Editor y comparte el resultado para verificar RLS de las tablas existentes.

-- 1) Tablas carcove_* y si tienen RLS activo
select c.relname as tabla, c.relrowsecurity as rls_activo, c.relforcerowsecurity as rls_forzado
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'carcove\_%' escape '\'
order by 1;

-- 2) Políticas existentes
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies where schemaname = 'public' and tablename like 'carcove\_%' escape '\'
order by tablename, policyname;

-- 3) Permisos directos de anon / authenticated sobre tablas carcove_*
select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type) as privilegios
from information_schema.role_table_grants
where table_schema = 'public' and table_name like 'carcove\_%' and grantee in ('anon','authenticated')
group by 1, 2 order by 1, 2;

-- 4) Columnas de las tablas que usa la migración (perfiles y servicios)
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name in ('carcove_perfiles','carcove_servicios')
order by table_name, ordinal_position;
