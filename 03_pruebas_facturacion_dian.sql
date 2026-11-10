-- =====================================================================
-- CARCOVE · 03 · Pruebas de la migración de facturación (Software Gratuito DIAN)
-- Ejecutar DESPUÉS de 03 en Supabase → SQL Editor. Todo ocurre dentro de una
-- transacción que se revierte al final: NO deja datos.
-- Reemplaza el UUID de :admin por el de un usuario real con rol 'administrador'
-- (select usuario_id from carcove_perfiles where rol = 'administrador' and activo).
-- Cada bloque indica el resultado esperado.
-- =====================================================================

-- A) Revisión del esquema existente de facturación (solo lectura, informativo):
select table_name, column_name, data_type from information_schema.columns
 where table_schema = 'public' and table_name in ('carcove_emisor','carcove_facturas')
 order by table_name, ordinal_position;
select conrelid::regclass as tabla, conname, pg_get_constraintdef(oid) as definicion
  from pg_constraint where conrelid in (to_regclass('public.carcove_emisor'), to_regclass('public.carcove_facturas'))
   and contype = 'c';

begin;
-- B) anon no ve nada                                        → esperado: ERROR permission denied (descomentar para ver)
-- set local role anon; select * from public.carcove_fe_emitidas; reset role;

-- Simular sesión del administrador (sustituye el UUID):
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);  -- ← UUID del administrador
set local role authenticated;

-- C) Diagnóstico                                             → esperado: {"ok": true, "bucket": true, "politicas_storage": 2, ...}
select public.carcove_fe_diagnostico();

-- D) Producción bloqueada mientras no haya habilitación      → esperado: {"ok": false, "error": "habilitacion_no_confirmada"}
select public.carcove_fe_registrar(jsonb_build_object('ambiente','produccion','prefijo','FE','numero',1,
  'cufe', repeat('a',96), 'fecha_emision', current_date, 'cliente_nombre','Prueba','cliente_identificacion','123',
  'valor_total', 1000, 'vouchers', jsonb_build_array(1)));

-- E) CUFE inválido                                           → esperado: {"ok": false, "error": "datos_invalidos", "campo": "cufe"}
select public.carcove_fe_registrar(jsonb_build_object('ambiente','habilitacion','numero',1,'cufe','abc',
  'fecha_emision', current_date, 'cliente_nombre','Prueba','cliente_identificacion','123','valor_total',1));

-- F) Registro de habilitación válido y luego duplicado       → esperado: ok true, luego "duplicada"
select public.carcove_fe_registrar(jsonb_build_object('ambiente','habilitacion','prefijo','SETP','numero',990000001,
  'cufe', repeat('b',96), 'fecha_emision', current_date, 'cliente_nombre','Cliente de prueba','cliente_identificacion','222222222222',
  'valor_total', 1000));
select public.carcove_fe_registrar(jsonb_build_object('ambiente','habilitacion','prefijo','SETP','numero',990000001,
  'cufe', repeat('c',96), 'fecha_emision', current_date, 'cliente_nombre','Cliente de prueba','cliente_identificacion','222222222222',
  'valor_total', 1000));

-- G) No se puede escribir directamente en las tablas         → esperado: ERROR permission denied
-- insert into public.carcove_fe_emitidas (ambiente, numero, cufe, fecha_emision, cliente_nombre, cliente_identificacion, valor_total, creado_por)
-- values ('produccion', 1, repeat('d',96), current_date, 'x', '123', 1, auth.uid());
rollback;
