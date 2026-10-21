-- CARCOVE · 02 · Pruebas de seguridad. Ejecutar DESPUÉS de 01 en Supabase → SQL Editor.
-- Cada bloque indica el resultado esperado. No deja datos (todo se revierte).

begin;
set local role anon;

-- A) anon NO puede leer la tabla de enlaces        → esperado: ERROR "permission denied for table carcove_voucher_enlaces"
-- select * from public.carcove_voucher_enlaces;

-- B) token inválido                                 → esperado: {"ok": false, "error": "no_disponible"}
select public.carcove_voucher_publico('abc');

-- C) token con formato válido pero inexistente      → esperado: {"ok": false, "error": "no_disponible"}
select public.carcove_voucher_publico(repeat('a', 64));

-- D) anon NO puede crear enlaces                    → esperado: ERROR "permission denied for function carcove_crear_enlace"
-- select public.carcove_crear_enlace(1, '{}'::jsonb, 30);

-- E) anon NO puede leer tablas internas             → esperado: ERROR o 0 filas (según tus políticas actuales)
-- select count(*) from public.carcove_servicios;
-- select count(*) from public.carcove_facturas;
rollback;

-- F) Prueba de extremo a extremo (como administrador, desde la app publicada):
--    1. Generar enlace → 2. abrirlo en ventana privada → 3. diligenciar y firmar → 4. recargar.
--    Luego, aquí:
--    select id, servicio_numero, estado, expira_en, confirmado_en, cliente_identificacion, cliente_centro_costos,
--           char_length(firma_png) as bytes_firma, huella_documento
--    from public.carcove_voucher_enlaces order by creado_en desc limit 5;
