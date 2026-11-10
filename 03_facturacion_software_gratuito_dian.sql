-- =====================================================================
-- CARCOVE · 03 · Facturación electrónica con el SOFTWARE GRATUITO DIAN
-- Migración ADITIVA y reversible (ver 03_revertir_facturacion_dian.sql).
--   · Crea tablas, funciones, un bucket privado y políticas NUEVAS.
--   · No modifica ni borra tablas, columnas, políticas ni datos existentes
--     (carcove_servicios, carcove_facturas, carcove_emisor, enlaces, etc.).
-- Requiere haber ejecutado 01 (usa public.carcove_rol_activo()).
--
-- Modelo de operación: la factura se EMITE, FIRMA y VALIDA en el software
-- «Facturación Gratuita DIAN» (portal web, intervención manual). CARCOVE solo
-- prepara los datos, registra el resultado (número, CUFE) y conserva el XML y
-- el PDF oficiales. No existe conexión API con la DIAN en esta modalidad.
--
-- Nunca se almacenan certificados, claves privadas, contraseñas ni tokens.
-- Ejecutar en Supabase → SQL Editor (una sola vez; es idempotente).
-- =====================================================================

do $$ begin
  if to_regprocedure('public.carcove_rol_activo()') is null then
    raise exception 'Falta public.carcove_rol_activo(): ejecuta primero 01_enlaces_publicos_vouchers.sql';
  end if;
end $$;

-- ---------- 1. Configuración (una sola fila) ----------
create table if not exists public.carcove_fe_config (
  id                        boolean primary key default true check (id),
  -- La modalidad es fija: no se admite software propio ni proveedor tecnológico.
  modo_operacion            text not null default 'software_gratuito_dian'
                            check (modo_operacion = 'software_gratuito_dian'),
  -- Facturador: se copian tal como aparecen en el RUT (sin interpretarlos).
  razon_social              text check (char_length(razon_social) <= 200),
  nit                       text check (char_length(nit) <= 20),
  responsabilidades_rut     text check (char_length(responsabilidades_rut) <= 400),
  direccion                 text check (char_length(direccion) <= 200),
  ciudad                    text check (char_length(ciudad) <= 100),
  telefono                  text check (char_length(telefono) <= 40),
  correo                    text check (char_length(correo) <= 200),
  rnt                       text check (char_length(rnt) <= 40),
  rut_verificado_por        uuid references auth.users(id),
  rut_verificado_en         timestamptz,
  rut_soporte_path          text,
  -- Resolución de numeración de PRODUCCIÓN (formato 1876). No confundir con los
  -- rangos de prueba que el software gratuito genera durante la habilitación.
  res_numero                text check (char_length(res_numero) <= 40),
  res_fecha                 date,
  res_prefijo               text check (res_prefijo ~ '^[A-Z0-9]{1,4}$'),
  res_desde                 bigint check (res_desde > 0),
  res_hasta                 bigint,
  res_vigencia_desde        date,
  res_vigencia_hasta        date,
  res_verificado_por        uuid references auth.users(id),
  res_verificado_en         timestamptz,
  res_soporte_path          text,
  -- Tratamiento de IVA por defecto SOLO si lo define el contador (si es null, se exige por línea).
  iva_defecto               numeric(5,2) check (iva_defecto between 0 and 100),
  iva_definido_por          text check (char_length(iva_definido_por) <= 120),
  -- Certificado: solo su ESTADO informado. El archivo y su clave nunca llegan a CARCOVE.
  cert_estado               text not null default 'sin_confirmar'
                            check (cert_estado in ('sin_confirmar','solicitado','configurado')),
  cert_vigencia_hasta       date,
  cert_confirmado_por       uuid references auth.users(id),
  cert_confirmado_en        timestamptz,
  -- Habilitación (proceso independiente, confirmado paso a paso en el portal DIAN).
  hab_pasos                 jsonb not null default '{}'::jsonb,
  hab_estado                text not null default 'pendiente'
                            check (hab_estado in ('pendiente','en_proceso','habilitado')),
  hab_fecha_inicio_operacion date,
  -- Prueba real de almacenamiento (objeto verificado en storage.objects).
  almac_probado_en          timestamptz,
  almac_probado_por         uuid references auth.users(id),
  actualizado_por           uuid references auth.users(id),
  actualizado_en            timestamptz not null default now(),
  constraint carcove_fe_cfg_rango_ck    check (res_hasta is null or res_desde is null or res_hasta >= res_desde),
  constraint carcove_fe_cfg_vigencia_ck check (res_vigencia_hasta is null or res_vigencia_desde is null or res_vigencia_hasta >= res_vigencia_desde)
);
insert into public.carcove_fe_config (id) values (true) on conflict (id) do nothing;

-- ---------- 2. Facturas emitidas en el software gratuito DIAN ----------
create table if not exists public.carcove_fe_emitidas (
  id                    uuid primary key default gen_random_uuid(),
  ambiente              text not null check (ambiente in ('produccion','habilitacion')),
  prefijo               text not null default '' check (prefijo ~ '^[A-Z0-9]{0,4}$'),
  numero                bigint not null check (numero > 0),
  cufe                  text not null check (cufe ~ '^[0-9a-f]{96}$'),   -- SHA-384 en hexadecimal
  fecha_emision         date not null,
  cliente_nombre        text not null check (char_length(cliente_nombre) between 2 and 200),
  cliente_tipo_id       text check (char_length(cliente_tipo_id) <= 20),
  cliente_identificacion text not null check (char_length(cliente_identificacion) between 3 and 40),
  valor_total           numeric(16,2) not null check (valor_total >= 0),
  estado                text not null default 'pendiente_soportes'
                        check (estado in ('pendiente_soportes','soportada','nota_credito','registro_anulado')),
  factura_ref           text check (char_length(factura_ref) <= 40),   -- preparación interna (FI-0001…)
  xml_path              text, xml_sha256 text check (xml_sha256 ~ '^[0-9a-f]{64}$'), xml_nombre text,
  pdf_path              text, pdf_sha256 text check (pdf_sha256 ~ '^[0-9a-f]{64}$'), pdf_nombre text,
  xml_verificacion      jsonb,          -- lectura del XML oficial hecha en el navegador (informativa)
  motivo_estado         text check (char_length(motivo_estado) <= 500),
  observaciones         text check (char_length(observaciones) <= 1000),
  creado_por            uuid not null references auth.users(id),
  creado_en             timestamptz not null default now(),
  actualizado_en        timestamptz not null default now()
);
-- Sin duplicados: un número y un CUFE solo pueden estar en un registro vigente.
create unique index if not exists carcove_fe_emitidas_numero_uq
  on public.carcove_fe_emitidas (ambiente, prefijo, numero) where estado <> 'registro_anulado';
create unique index if not exists carcove_fe_emitidas_cufe_uq
  on public.carcove_fe_emitidas (cufe) where estado <> 'registro_anulado';
create index if not exists carcove_fe_emitidas_fecha_idx on public.carcove_fe_emitidas (fecha_emision desc);

-- Relación factura ↔ vouchers (los vouchers se identifican por propietario + número, como en carcove_servicios).
create table if not exists public.carcove_fe_emitida_vouchers (
  id                   bigint generated always as identity primary key,
  emitida_id           uuid not null references public.carcove_fe_emitidas(id),
  servicio_propietario uuid not null references auth.users(id),
  voucher_numero       integer not null check (voucher_numero > 0),
  activo               boolean not null default true,   -- solo producción vigente bloquea el voucher
  unique (emitida_id, servicio_propietario, voucher_numero)
);
-- Un voucher solo puede estar en UNA factura de producción vigente.
create unique index if not exists carcove_fe_voucher_activo_uq
  on public.carcove_fe_emitida_vouchers (servicio_propietario, voucher_numero) where activo;

-- Historial (solo se agregan filas).
create table if not exists public.carcove_fe_eventos (
  id          bigint generated always as identity primary key,
  emitida_id  uuid references public.carcove_fe_emitidas(id),
  accion      text not null,
  detalle     jsonb not null default '{}'::jsonb,
  usuario     uuid references auth.users(id),
  creado_en   timestamptz not null default now()
);
create index if not exists carcove_fe_eventos_idx on public.carcove_fe_eventos (emitida_id, creado_en);

-- ---------- 3. RLS: lectura para administrador/facturación; escritura solo por funciones ----------
alter table public.carcove_fe_config           enable row level security;
alter table public.carcove_fe_emitidas         enable row level security;
alter table public.carcove_fe_emitida_vouchers enable row level security;
alter table public.carcove_fe_eventos          enable row level security;

revoke all on table public.carcove_fe_config, public.carcove_fe_emitidas,
                    public.carcove_fe_emitida_vouchers, public.carcove_fe_eventos
  from public, anon, authenticated;
grant select on table public.carcove_fe_config, public.carcove_fe_emitidas,
                      public.carcove_fe_emitida_vouchers, public.carcove_fe_eventos
  to authenticated;

drop policy if exists carcove_fe_config_select on public.carcove_fe_config;
create policy carcove_fe_config_select on public.carcove_fe_config for select to authenticated
  using (public.carcove_rol_activo() in ('administrador','facturacion'));
drop policy if exists carcove_fe_emitidas_select on public.carcove_fe_emitidas;
create policy carcove_fe_emitidas_select on public.carcove_fe_emitidas for select to authenticated
  using (public.carcove_rol_activo() in ('administrador','facturacion'));
drop policy if exists carcove_fe_vouchers_select on public.carcove_fe_emitida_vouchers;
create policy carcove_fe_vouchers_select on public.carcove_fe_emitida_vouchers for select to authenticated
  using (public.carcove_rol_activo() in ('administrador','facturacion'));
drop policy if exists carcove_fe_eventos_select on public.carcove_fe_eventos;
create policy carcove_fe_eventos_select on public.carcove_fe_eventos for select to authenticated
  using (public.carcove_rol_activo() in ('administrador','facturacion'));

-- ---------- 4. Almacenamiento privado (XML, PDF y soportes en PDF) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('carcove-fe-documentos', 'carcove-fe-documentos', false, 10485760,
        array['application/xml','text/xml','application/pdf'])
on conflict (id) do nothing;

-- Subir: solo administrador/facturación y solo dentro de su carpeta (<usuario>/...).
drop policy if exists carcove_fe_docs_insert on storage.objects;
create policy carcove_fe_docs_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'carcove-fe-documentos'
    and public.carcove_rol_activo() in ('administrador','facturacion')
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- Descargar: administrador/facturación.
drop policy if exists carcove_fe_docs_select on storage.objects;
create policy carcove_fe_docs_select on storage.objects for select to authenticated
  using (
    bucket_id = 'carcove-fe-documentos'
    and public.carcove_rol_activo() in ('administrador','facturacion')
  );
-- No hay políticas de update/delete: los documentos oficiales no se reemplazan ni se borran.

-- ---------- 5. Funciones auxiliares ----------
create or replace function public.carcove_fe_puede()
returns boolean language sql stable security definer set search_path = ''
as $$ select auth.uid() is not null and coalesce(public.carcove_rol_activo() in ('administrador','facturacion'), false) $$;
revoke all on function public.carcove_fe_puede() from public, anon;
grant execute on function public.carcove_fe_puede() to authenticated;

create or replace function public.carcove_fe_log(p_emitida uuid, p_accion text, p_detalle jsonb)
returns void language sql security definer set search_path = ''
as $$ insert into public.carcove_fe_eventos (emitida_id, accion, detalle, usuario)
      values (p_emitida, p_accion, coalesce(p_detalle, '{}'::jsonb), auth.uid()) $$;
revoke all on function public.carcove_fe_log(uuid, text, jsonb) from public, anon, authenticated;

-- Texto limpio (sin caracteres de control) o null.
create or replace function public.carcove_fe_txt(p text, p_max integer)
returns text language sql immutable set search_path = ''
as $$ select nullif(left(trim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g')), p_max), '') $$;
revoke all on function public.carcove_fe_txt(text, integer) from public, anon, authenticated;

-- El objeto existe en el bucket y lo subió este usuario.
create or replace function public.carcove_fe_objeto_ok(p_path text)
returns boolean language sql stable security definer set search_path = ''
as $$ select p_path is not null
         and split_part(p_path, '/', 1) = auth.uid()::text
         and exists (select 1 from storage.objects o
                     where o.bucket_id = 'carcove-fe-documentos' and o.name = p_path) $$;
revoke all on function public.carcove_fe_objeto_ok(text) from public, anon, authenticated;

-- ---------- 6. Guardar configuración ----------
-- Cualquier cambio en los datos del RUT o de la resolución anula su verificación previa.
create or replace function public.carcove_fe_guardar_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.carcove_fe_config; n public.carcove_fe_config; v_pref text;
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  select * into c from public.carcove_fe_config where id for update;
  n := c;
  if p ? 'razon_social'          then n.razon_social          := public.carcove_fe_txt(p->>'razon_social', 200); end if;
  if p ? 'nit'                   then n.nit                   := public.carcove_fe_txt(p->>'nit', 20); end if;
  if p ? 'responsabilidades_rut' then n.responsabilidades_rut := public.carcove_fe_txt(p->>'responsabilidades_rut', 400); end if;
  if p ? 'direccion'             then n.direccion             := public.carcove_fe_txt(p->>'direccion', 200); end if;
  if p ? 'ciudad'                then n.ciudad                := public.carcove_fe_txt(p->>'ciudad', 100); end if;
  if p ? 'telefono'              then n.telefono              := public.carcove_fe_txt(p->>'telefono', 40); end if;
  if p ? 'correo'                then n.correo                := public.carcove_fe_txt(p->>'correo', 200); end if;
  if p ? 'rnt'                   then n.rnt                   := public.carcove_fe_txt(p->>'rnt', 40); end if;
  if p ? 'res_numero'            then n.res_numero            := public.carcove_fe_txt(p->>'res_numero', 40); end if;
  if p ? 'res_prefijo' then
    v_pref := upper(public.carcove_fe_txt(p->>'res_prefijo', 10));
    if v_pref is not null and v_pref !~ '^[A-Z0-9]{1,4}$' then
      return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'res_prefijo');
    end if;
    n.res_prefijo := v_pref;
  end if;
  begin
    if p ? 'res_fecha'          then n.res_fecha          := nullif(p->>'res_fecha', '')::date; end if;
    if p ? 'res_desde'          then n.res_desde          := nullif(p->>'res_desde', '')::bigint; end if;
    if p ? 'res_hasta'          then n.res_hasta          := nullif(p->>'res_hasta', '')::bigint; end if;
    if p ? 'res_vigencia_desde' then n.res_vigencia_desde := nullif(p->>'res_vigencia_desde', '')::date; end if;
    if p ? 'res_vigencia_hasta' then n.res_vigencia_hasta := nullif(p->>'res_vigencia_hasta', '')::date; end if;
    if p ? 'iva_defecto'        then n.iva_defecto        := nullif(p->>'iva_defecto', '')::numeric; end if;
    if p ? 'cert_vigencia_hasta' then n.cert_vigencia_hasta := nullif(p->>'cert_vigencia_hasta', '')::date; end if;
    if p ? 'hab_fecha_inicio_operacion' then n.hab_fecha_inicio_operacion := nullif(p->>'hab_fecha_inicio_operacion', '')::date; end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'fecha_o_numero');
  end;
  if p ? 'iva_definido_por' then n.iva_definido_por := public.carcove_fe_txt(p->>'iva_definido_por', 120); end if;
  if n.iva_defecto is not null and n.iva_definido_por is null then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'iva_definido_por');
  end if;
  if p ? 'cert_estado' then
    if p->>'cert_estado' not in ('sin_confirmar','solicitado','configurado') then
      return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'cert_estado');
    end if;
    if p->>'cert_estado' is distinct from c.cert_estado then
      n.cert_estado := p->>'cert_estado'; n.cert_confirmado_por := auth.uid(); n.cert_confirmado_en := now();
    end if;
  end if;
  if (n.razon_social, n.nit, n.responsabilidades_rut, n.direccion) is distinct from
     (c.razon_social, c.nit, c.responsabilidades_rut, c.direccion) then
    n.rut_verificado_por := null; n.rut_verificado_en := null;
  end if;
  if (n.res_numero, n.res_fecha, n.res_prefijo, n.res_desde, n.res_hasta, n.res_vigencia_desde, n.res_vigencia_hasta) is distinct from
     (c.res_numero, c.res_fecha, c.res_prefijo, c.res_desde, c.res_hasta, c.res_vigencia_desde, c.res_vigencia_hasta) then
    n.res_verificado_por := null; n.res_verificado_en := null;
  end if;
  begin
    update public.carcove_fe_config set
      razon_social = n.razon_social, nit = n.nit, responsabilidades_rut = n.responsabilidades_rut,
      direccion = n.direccion, ciudad = n.ciudad, telefono = n.telefono, correo = n.correo, rnt = n.rnt,
      rut_verificado_por = n.rut_verificado_por, rut_verificado_en = n.rut_verificado_en,
      res_numero = n.res_numero, res_fecha = n.res_fecha, res_prefijo = n.res_prefijo,
      res_desde = n.res_desde, res_hasta = n.res_hasta,
      res_vigencia_desde = n.res_vigencia_desde, res_vigencia_hasta = n.res_vigencia_hasta,
      res_verificado_por = n.res_verificado_por, res_verificado_en = n.res_verificado_en,
      iva_defecto = n.iva_defecto, iva_definido_por = n.iva_definido_por,
      cert_estado = n.cert_estado, cert_vigencia_hasta = n.cert_vigencia_hasta,
      cert_confirmado_por = n.cert_confirmado_por, cert_confirmado_en = n.cert_confirmado_en,
      hab_fecha_inicio_operacion = n.hab_fecha_inicio_operacion,
      actualizado_por = auth.uid(), actualizado_en = now()
    where id;
  exception when check_violation then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'rango_o_vigencia');
  end;
  perform public.carcove_fe_log(null, 'config_guardada', jsonb_build_object(
    'rut_verificacion_reiniciada', c.rut_verificado_en is not null and n.rut_verificado_en is null,
    'resolucion_verificacion_reiniciada', c.res_verificado_en is not null and n.res_verificado_en is null));
  return jsonb_build_object('ok', true);
end
$$;
revoke all on function public.carcove_fe_guardar_config(jsonb) from public, anon;
grant execute on function public.carcove_fe_guardar_config(jsonb) to authenticated;

-- ---------- 7. Verificaciones manuales (quién y cuándo) ----------
-- p_item: 'rut' | 'resolucion' | 'paso:<clave>' (pasos de habilitación).
create or replace function public.carcove_fe_verificar(p_item text, p_ok boolean, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.carcove_fe_config; v_paso text; v_pasos jsonb;
  v_validos text[] := array['registro','modo','set_pruebas','estado_habilitado','fecha_inicio',
                            'rut_facturador','numeracion_fe','numeracion_contingencia','prefijos'];
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  select * into c from public.carcove_fe_config where id for update;
  if p_item = 'rut' then
    if p_ok and (c.razon_social is null or c.nit is null or c.responsabilidades_rut is null or c.direccion is null) then
      return jsonb_build_object('ok', false, 'error', 'faltan_datos_rut');
    end if;
    update public.carcove_fe_config set
      rut_verificado_por = case when p_ok then auth.uid() end,
      rut_verificado_en  = case when p_ok then now() end, actualizado_en = now() where id;
  elsif p_item = 'resolucion' then
    if p_ok and (c.res_numero is null or c.res_fecha is null or c.res_prefijo is null or c.res_desde is null
                 or c.res_hasta is null or c.res_vigencia_desde is null or c.res_vigencia_hasta is null) then
      return jsonb_build_object('ok', false, 'error', 'faltan_datos_resolucion');
    end if;
    update public.carcove_fe_config set
      res_verificado_por = case when p_ok then auth.uid() end,
      res_verificado_en  = case when p_ok then now() end, actualizado_en = now() where id;
  elsif p_item like 'paso:%' then
    v_paso := substr(p_item, 6);
    if not (v_paso = any (v_validos)) then return jsonb_build_object('ok', false, 'error', 'paso_invalido'); end if;
    if v_paso = 'estado_habilitado' and p_ok and not coalesce((c.hab_pasos->'set_pruebas'->>'ok')::boolean, false) then
      return jsonb_build_object('ok', false, 'error', 'falta_set_pruebas');
    end if;
    if p_ok then
      v_pasos := c.hab_pasos || jsonb_build_object(v_paso, jsonb_build_object(
                   'ok', true, 'por', auth.uid(), 'en', now(), 'nota', public.carcove_fe_txt(p_nota, 300)));
    else
      v_pasos := c.hab_pasos - v_paso;
      if v_paso = 'set_pruebas' then v_pasos := v_pasos - 'estado_habilitado'; end if;
    end if;
    update public.carcove_fe_config set hab_pasos = v_pasos,
      hab_estado = case when coalesce((v_pasos->'estado_habilitado'->>'ok')::boolean, false) then 'habilitado'
                        when v_pasos <> '{}'::jsonb then 'en_proceso' else 'pendiente' end,
      actualizado_por = auth.uid(), actualizado_en = now()
    where id;
  else
    return jsonb_build_object('ok', false, 'error', 'item_invalido');
  end if;
  perform public.carcove_fe_log(null, 'verificacion', jsonb_build_object('item', p_item, 'ok', p_ok,
          'nota', public.carcove_fe_txt(p_nota, 300)));
  return jsonb_build_object('ok', true);
end
$$;
revoke all on function public.carcove_fe_verificar(text, boolean, text) from public, anon;
grant execute on function public.carcove_fe_verificar(text, boolean, text) to authenticated;

-- ---------- 8. Soportes (RUT / resolución) y prueba real del almacenamiento ----------
create or replace function public.carcove_fe_registrar_soporte(p_tipo text, p_path text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  if p_tipo not in ('rut','resolucion','prueba') then return jsonb_build_object('ok', false, 'error', 'tipo_invalido'); end if;
  if not public.carcove_fe_objeto_ok(p_path) then return jsonb_build_object('ok', false, 'error', 'archivo_no_encontrado'); end if;
  if p_tipo = 'rut' then
    update public.carcove_fe_config set rut_soporte_path = p_path, actualizado_en = now() where id;
  elsif p_tipo = 'resolucion' then
    update public.carcove_fe_config set res_soporte_path = p_path, actualizado_en = now() where id;
  else
    update public.carcove_fe_config set almac_probado_en = now(), almac_probado_por = auth.uid(), actualizado_en = now() where id;
  end if;
  perform public.carcove_fe_log(null, 'soporte_' || p_tipo, jsonb_build_object('path', p_path));
  return jsonb_build_object('ok', true);
end
$$;
revoke all on function public.carcove_fe_registrar_soporte(text, text) from public, anon;
grant execute on function public.carcove_fe_registrar_soporte(text, text) to authenticated;

-- ---------- 9. Registrar una factura emitida en el software gratuito ----------
create or replace function public.carcove_fe_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  c public.carcove_fe_config;
  v_amb text := p->>'ambiente';
  v_pref text := upper(coalesce(public.carcove_fe_txt(p->>'prefijo', 10), ''));
  v_num bigint; v_fecha date; v_total numeric;
  v_cufe text := lower(coalesce(public.carcove_fe_txt(p->>'cufe', 200), ''));
  v_cli text := public.carcove_fe_txt(p->>'cliente_nombre', 200);
  v_cid text := public.carcove_fe_txt(p->>'cliente_identificacion', 40);
  v_vouchers integer[]; v_id uuid; v_v integer; v_otro text;
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  if v_amb is null or v_amb not in ('produccion','habilitacion') then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'ambiente');
  end if;
  begin
    v_num := (p->>'numero')::bigint; v_fecha := (p->>'fecha_emision')::date; v_total := (p->>'valor_total')::numeric;
    select coalesce(array_agg(distinct x::integer), '{}') into v_vouchers
      from jsonb_array_elements_text(coalesce(p->'vouchers', '[]'::jsonb)) x;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'numero_fecha_total_o_vouchers');
  end;
  if v_num is null or v_num <= 0 then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'numero'); end if;
  if v_pref !~ '^[A-Z0-9]{0,4}$' then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'prefijo'); end if;
  if v_cufe !~ '^[0-9a-f]{96}$' then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'cufe'); end if;
  if v_fecha is null or v_fecha > (now() at time zone 'America/Bogota')::date then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'fecha_emision');
  end if;
  if v_total is null or v_total < 0 then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'valor_total'); end if;
  if v_cli is null or char_length(v_cli) < 2 then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'cliente_nombre'); end if;
  if v_cid is null or char_length(v_cid) < 3 then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'cliente_identificacion'); end if;
  if exists (select 1 from unnest(v_vouchers) u where u <= 0) then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'vouchers');
  end if;

  select * into c from public.carcove_fe_config where id;
  if v_amb = 'produccion' then
    -- Producción exige habilitación confirmada y resolución verificada; el número debe estar en el rango y la fecha en la vigencia.
    if c.hab_estado <> 'habilitado' then return jsonb_build_object('ok', false, 'error', 'habilitacion_no_confirmada'); end if;
    if c.res_verificado_en is null then return jsonb_build_object('ok', false, 'error', 'resolucion_no_verificada'); end if;
    if v_pref <> c.res_prefijo then
      return jsonb_build_object('ok', false, 'error', 'prefijo_no_autorizado', 'esperado', c.res_prefijo);
    end if;
    if v_num < c.res_desde or v_num > c.res_hasta then
      return jsonb_build_object('ok', false, 'error', 'fuera_de_rango', 'desde', c.res_desde, 'hasta', c.res_hasta);
    end if;
    if v_fecha < c.res_vigencia_desde or v_fecha > c.res_vigencia_hasta then
      return jsonb_build_object('ok', false, 'error', 'fuera_de_vigencia', 'desde', c.res_vigencia_desde, 'hasta', c.res_vigencia_hasta);
    end if;
    if cardinality(v_vouchers) = 0 then return jsonb_build_object('ok', false, 'error', 'sin_vouchers'); end if;
  end if;

  if exists (select 1 from public.carcove_fe_emitidas e where e.estado <> 'registro_anulado'
             and ((e.ambiente = v_amb and e.prefijo = v_pref and e.numero = v_num) or e.cufe = v_cufe)) then
    return jsonb_build_object('ok', false, 'error', 'duplicada');
  end if;
  if v_amb = 'produccion' then
    select string_agg(distinct coalesce(nullif(e.prefijo, '') || '-', '') || e.numero::text, ', ') into v_otro
      from public.carcove_fe_emitida_vouchers ev join public.carcove_fe_emitidas e on e.id = ev.emitida_id
     where ev.activo and ev.servicio_propietario = auth.uid() and ev.voucher_numero = any (v_vouchers);
    if v_otro is not null then return jsonb_build_object('ok', false, 'error', 'voucher_ya_facturado', 'facturas', v_otro); end if;
  end if;

  insert into public.carcove_fe_emitidas (ambiente, prefijo, numero, cufe, fecha_emision, cliente_nombre, cliente_tipo_id,
      cliente_identificacion, valor_total, factura_ref, observaciones, creado_por)
  values (v_amb, v_pref, v_num, v_cufe, v_fecha, v_cli, public.carcove_fe_txt(p->>'cliente_tipo_id', 20),
      v_cid, v_total, public.carcove_fe_txt(p->>'factura_ref', 40), public.carcove_fe_txt(p->>'observaciones', 1000), auth.uid())
  returning id into v_id;

  foreach v_v in array v_vouchers loop
    insert into public.carcove_fe_emitida_vouchers (emitida_id, servicio_propietario, voucher_numero, activo)
    values (v_id, auth.uid(), v_v, v_amb = 'produccion');
  end loop;

  perform public.carcove_fe_log(v_id, 'registrada', jsonb_build_object('ambiente', v_amb, 'prefijo', v_pref,
          'numero', v_num, 'vouchers', to_jsonb(v_vouchers), 'valor_total', v_total));
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'duplicada');
end
$$;
revoke all on function public.carcove_fe_registrar(jsonb) from public, anon;
grant execute on function public.carcove_fe_registrar(jsonb) to authenticated;

-- ---------- 10. Adjuntar XML / PDF oficiales (ya subidos al bucket) ----------
create or replace function public.carcove_fe_adjuntar(p_id uuid, p_tipo text, p_path text, p_sha256 text,
                                                      p_nombre text, p_verificacion jsonb default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare e public.carcove_fe_emitidas;
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  if p_tipo not in ('xml','pdf') then return jsonb_build_object('ok', false, 'error', 'tipo_invalido'); end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'sha256'); end if;
  select * into e from public.carcove_fe_emitidas where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_encontrada'); end if;
  if e.estado = 'registro_anulado' then return jsonb_build_object('ok', false, 'error', 'registro_anulado'); end if;
  if split_part(p_path, '/', 2) <> p_id::text or not public.carcove_fe_objeto_ok(p_path) then
    return jsonb_build_object('ok', false, 'error', 'archivo_no_encontrado');
  end if;
  if p_tipo = 'xml' then
    update public.carcove_fe_emitidas set xml_path = p_path, xml_sha256 = p_sha256,
      xml_nombre = public.carcove_fe_txt(p_nombre, 200), xml_verificacion = p_verificacion, actualizado_en = now()
    where id = p_id;
  else
    update public.carcove_fe_emitidas set pdf_path = p_path, pdf_sha256 = p_sha256,
      pdf_nombre = public.carcove_fe_txt(p_nombre, 200), actualizado_en = now()
    where id = p_id;
  end if;
  update public.carcove_fe_emitidas set estado = 'soportada', actualizado_en = now()
   where id = p_id and estado = 'pendiente_soportes' and xml_path is not null and pdf_path is not null;
  perform public.carcove_fe_log(p_id, 'adjunto_' || p_tipo, jsonb_build_object('path', p_path, 'sha256', p_sha256,
          'reemplaza', case when p_tipo = 'xml' then e.xml_path else e.pdf_path end));
  return jsonb_build_object('ok', true);
end
$$;
revoke all on function public.carcove_fe_adjuntar(uuid, text, text, text, text, jsonb) from public, anon;
grant execute on function public.carcove_fe_adjuntar(uuid, text, text, text, text, jsonb) to authenticated;

-- ---------- 11. Cambiar estado (nunca se borra) ----------
-- 'nota_credito'    : en la DIAN se emitió una nota crédito que anula la factura (el voucher queda libre).
-- 'registro_anulado': el registro en CARCOVE fue un error de digitación (no afecta nada en la DIAN).
create or replace function public.carcove_fe_cambiar_estado(p_id uuid, p_estado text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare e public.carcove_fe_emitidas; v_m text := public.carcove_fe_txt(p_motivo, 500);
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  if p_estado not in ('nota_credito','registro_anulado') then return jsonb_build_object('ok', false, 'error', 'estado_invalido'); end if;
  if v_m is null or char_length(v_m) < 5 then return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'motivo'); end if;
  select * into e from public.carcove_fe_emitidas where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_encontrada'); end if;
  if e.estado in ('nota_credito','registro_anulado') then return jsonb_build_object('ok', false, 'error', 'estado_final'); end if;
  update public.carcove_fe_emitidas set estado = p_estado, motivo_estado = v_m, actualizado_en = now() where id = p_id;
  update public.carcove_fe_emitida_vouchers set activo = false where emitida_id = p_id;
  perform public.carcove_fe_log(p_id, 'estado_' || p_estado, jsonb_build_object('motivo', v_m, 'anterior', e.estado));
  return jsonb_build_object('ok', true);
end
$$;
revoke all on function public.carcove_fe_cambiar_estado(uuid, text, text) from public, anon;
grant execute on function public.carcove_fe_cambiar_estado(uuid, text, text) to authenticated;

-- ---------- 12. Diagnóstico de instalación (lo usa la app para mostrar estados reales) ----------
create or replace function public.carcove_fe_diagnostico()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.carcove_fe_puede() then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  return jsonb_build_object('ok', true, 'version', 3,
    'bucket', exists (select 1 from storage.buckets where id = 'carcove-fe-documentos' and public = false),
    'politicas_storage', (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                          and policyname in ('carcove_fe_docs_insert','carcove_fe_docs_select')),
    'emitidas_produccion', (select count(*) from public.carcove_fe_emitidas where ambiente = 'produccion' and estado <> 'registro_anulado'),
    'emitidas_habilitacion', (select count(*) from public.carcove_fe_emitidas where ambiente = 'habilitacion' and estado <> 'registro_anulado'));
end
$$;
revoke all on function public.carcove_fe_diagnostico() from public, anon;
grant execute on function public.carcove_fe_diagnostico() to authenticated;

notify pgrst, 'reload schema';
