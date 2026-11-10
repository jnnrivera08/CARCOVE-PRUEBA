-- =====================================================================
-- CARCOVE · 03 · REVERSIÓN de la migración 03 (solo si es estrictamente necesario)
-- Elimina ÚNICAMENTE los objetos creados por 03. No toca tablas anteriores.
-- Protección: se detiene si ya hay facturas registradas o documentos en el bucket.
-- Los documentos oficiales (XML/PDF) deben conservarse: descárgalos antes.
-- =====================================================================
do $$
begin
  if to_regclass('public.carcove_fe_emitidas') is not null
     and exists (select 1 from public.carcove_fe_emitidas) then
    raise exception 'Hay facturas registradas en carcove_fe_emitidas. Exporta el historial y los documentos antes de revertir. Reversión cancelada.';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'carcove-fe-documentos') then
    raise exception 'El bucket carcove-fe-documentos contiene archivos. Descárgalos y bórralos desde el panel de Storage antes de revertir. Reversión cancelada.';
  end if;
end $$;

drop policy if exists carcove_fe_docs_insert on storage.objects;
drop policy if exists carcove_fe_docs_select on storage.objects;
delete from storage.buckets where id = 'carcove-fe-documentos';

drop function if exists public.carcove_fe_diagnostico();
drop function if exists public.carcove_fe_cambiar_estado(uuid, text, text);
drop function if exists public.carcove_fe_adjuntar(uuid, text, text, text, text, jsonb);
drop function if exists public.carcove_fe_registrar(jsonb);
drop function if exists public.carcove_fe_registrar_soporte(text, text);
drop function if exists public.carcove_fe_verificar(text, boolean, text);
drop function if exists public.carcove_fe_guardar_config(jsonb);
drop function if exists public.carcove_fe_objeto_ok(text);
drop function if exists public.carcove_fe_txt(text, integer);
drop function if exists public.carcove_fe_log(uuid, text, jsonb);
drop function if exists public.carcove_fe_puede();

drop table if exists public.carcove_fe_eventos;
drop table if exists public.carcove_fe_emitida_vouchers;
drop table if exists public.carcove_fe_emitidas;
drop table if exists public.carcove_fe_config;

notify pgrst, 'reload schema';
