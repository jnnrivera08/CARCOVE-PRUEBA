-- =====================================================================
-- CARCOVE · 01 · Enlaces públicos seguros para vouchers
-- Migración ADITIVA: crea objetos nuevos. No modifica ni borra tablas,
-- columnas, políticas ni datos existentes.
-- Requiere que exista public.carcove_perfiles(usuario_id, rol, activo).
-- Ejecutar en Supabase → SQL Editor (una sola vez).
-- =====================================================================

-- ---------- 1. Tabla de enlaces ----------
create table if not exists public.carcove_voucher_enlaces (
  id                     uuid primary key default gen_random_uuid(),
  creado_por             uuid not null references auth.users(id),
  servicio_numero        integer not null check (servicio_numero > 0),
  token                  text not null unique check (token ~ '^[0-9a-f]{64}$'),
  -- Copia de SOLO los campos que el cliente puede ver (sin valores económicos).
  datos_publicos         jsonb not null,
  estado                 text not null default 'activo'
                         check (estado in ('activo','completado','revocado')),
  expira_en              timestamptz not null,
  cliente_identificacion text check (char_length(cliente_identificacion) between 3 and 40),
  cliente_centro_costos  text check (char_length(cliente_centro_costos) between 2 and 80),
  firma_png              text check (firma_png is null or
                           (firma_png ~ '^data:image/png;base64,[A-Za-z0-9+/=]+$'
                            and char_length(firma_png) <= 300000)),
  confirmado_en          timestamptz,
  confirmado_huella      text,   -- md5 de la IP (no se guarda la IP en claro)
  confirmado_agente      text,   -- user-agent truncado
  huella_documento       text,   -- SHA-256 de datos + campos + firma + fecha (detección de alteración)
  creado_en              timestamptz not null default now(),
  actualizado_en         timestamptz not null default now(),
  constraint carcove_enlace_completado_ck check (
    estado <> 'completado' or (
      cliente_identificacion is not null and cliente_centro_costos is not null
      and firma_png is not null and confirmado_en is not null))
);

create index if not exists carcove_enlaces_servicio_idx
  on public.carcove_voucher_enlaces (creado_por, servicio_numero, creado_en desc);

-- Registro mínimo para limitar abusos (sin datos personales: solo hash de IP).
create table if not exists public.carcove_enlace_intentos (
  id        bigint generated always as identity primary key,
  huella    text not null,
  accion    text not null,
  creado_en timestamptz not null default now()
);
create index if not exists carcove_enlace_intentos_idx
  on public.carcove_enlace_intentos (huella, accion, creado_en);

-- ---------- 2. RLS: nadie accede a las tablas directamente salvo personal autorizado (lectura) ----------
alter table public.carcove_voucher_enlaces enable row level security;
alter table public.carcove_enlace_intentos enable row level security;

revoke all on table public.carcove_voucher_enlaces from public, anon, authenticated;
revoke all on table public.carcove_enlace_intentos from public, anon, authenticated;
grant select on table public.carcove_voucher_enlaces to authenticated;   -- filtrado por la política

-- ---------- 3. Funciones auxiliares ----------
create or replace function public.carcove_rol_activo()
returns text language sql stable security definer set search_path = ''
as $$
  select p.rol::text from public.carcove_perfiles p
  where p.usuario_id = auth.uid() and p.activo is true
  limit 1
$$;
revoke all on function public.carcove_rol_activo() from public, anon;
grant execute on function public.carcove_rol_activo() to authenticated;

create or replace function public.carcove_huella()
returns text language plpgsql stable security definer set search_path = ''
as $$
declare h json; ip text;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  ip := nullif(trim(split_part(coalesce(h->>'x-forwarded-for', h->>'cf-connecting-ip', ''), ',', 1)), '');
  return case when ip is null then null else md5(ip) end;
end
$$;
revoke all on function public.carcove_huella() from public, anon, authenticated;

create or replace function public.carcove_agente()
returns text language plpgsql stable security definer set search_path = ''
as $$
declare h json;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  return left(h->>'user-agent', 300);
end
$$;
revoke all on function public.carcove_agente() from public, anon, authenticated;

-- ---------- 4. Política de lectura para personal autorizado ----------
drop policy if exists carcove_enlaces_select on public.carcove_voucher_enlaces;
create policy carcove_enlaces_select on public.carcove_voucher_enlaces
  for select to authenticated
  using (
    public.carcove_rol_activo() is not null
    and (creado_por = auth.uid() or public.carcove_rol_activo() = 'administrador')
  );
-- No existen políticas de insert/update/delete: solo se escribe mediante las funciones de abajo.

-- ---------- 5. Funciones del personal (requieren sesión) ----------
create or replace function public.carcove_crear_enlace(p_numero integer, p_datos jsonb, p_dias integer default 30)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_rol text := public.carcove_rol_activo();
  v_token text;
  v_id uuid;
  v_exp timestamptz;
  v_datos jsonb;
begin
  if auth.uid() is null or v_rol is null or v_rol not in ('administrador','facturacion','operador') then
    return jsonb_build_object('ok', false, 'error', 'sin_permiso');
  end if;
  if p_numero is null or p_numero <= 0 then
    return jsonb_build_object('ok', false, 'error', 'numero_invalido');
  end if;
  if p_dias is null or p_dias < 1 or p_dias > 90 then p_dias := 30; end if;

  -- Lista blanca de campos visibles para el cliente (nunca valores económicos).
  v_datos := jsonb_build_object(
    'n',  p_numero,
    'f',  left(coalesce(p_datos->>'f',  ''), 200),
    'e',  left(coalesce(p_datos->>'e',  ''), 200),
    'p',  left(coalesce(p_datos->>'p',  ''), 200),
    'r',  left(coalesce(p_datos->>'r',  ''), 200),
    't',  left(coalesce(p_datos->>'t',  ''), 200),
    'k',  left(coalesce(p_datos->>'k',  ''), 200),
    'pl', left(coalesce(p_datos->>'pl', ''), 200)
  );

  -- Un solo enlace activo por voucher: los anteriores activos quedan revocados.
  update public.carcove_voucher_enlaces
     set estado = 'revocado', actualizado_en = now()
   where creado_por = auth.uid() and servicio_numero = p_numero and estado = 'activo';

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');  -- 64 hex, CSPRNG
  v_exp := now() + make_interval(days => p_dias);

  insert into public.carcove_voucher_enlaces (creado_por, servicio_numero, token, datos_publicos, expira_en)
  values (auth.uid(), p_numero, v_token, v_datos, v_exp)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'token', v_token, 'expira_en', v_exp);
end
$$;
revoke all on function public.carcove_crear_enlace(integer, jsonb, integer) from public, anon;
grant execute on function public.carcove_crear_enlace(integer, jsonb, integer) to authenticated;

create or replace function public.carcove_enlace_revocar(p_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rol text := public.carcove_rol_activo(); v_n integer;
begin
  if auth.uid() is null or v_rol is null or v_rol not in ('administrador','facturacion','operador') then
    return jsonb_build_object('ok', false, 'error', 'sin_permiso');
  end if;
  update public.carcove_voucher_enlaces
     set estado = 'revocado', actualizado_en = now()
   where id = p_id and estado = 'activo'
     and (creado_por = auth.uid() or v_rol = 'administrador');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'error', case when v_n = 0 then 'no_encontrado_o_no_activo' end);
end
$$;
revoke all on function public.carcove_enlace_revocar(uuid) from public, anon;
grant execute on function public.carcove_enlace_revocar(uuid) to authenticated;

-- ---------- 6. Funciones públicas (el cliente, sin sesión; solo con el token) ----------
-- Los errores se devuelven como JSON (no como excepción) para que el registro de intentos no se revierta.

create or replace function public.carcove_voucher_publico(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare e public.carcove_voucher_enlaces; h text := public.carcove_huella();
begin
  if random() < 0.02 then
    delete from public.carcove_enlace_intentos where creado_en < now() - interval '1 day';
  end if;
  if h is not null and (select count(*) from public.carcove_enlace_intentos
        where huella = h and accion = 'fallo' and creado_en > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'error', 'demasiados_intentos');
  end if;

  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    if h is not null then insert into public.carcove_enlace_intentos(huella, accion) values (h, 'fallo'); end if;
    return jsonb_build_object('ok', false, 'error', 'no_disponible');
  end if;

  select * into e from public.carcove_voucher_enlaces where token = p_token;
  if not found or e.estado = 'revocado' or e.expira_en < now() then
    if h is not null then insert into public.carcove_enlace_intentos(huella, accion) values (h, 'fallo'); end if;
    return jsonb_build_object('ok', false, 'error', 'no_disponible');
  end if;

  return jsonb_build_object(
    'ok', true,
    'datos', e.datos_publicos,
    'estado', e.estado,
    'identificacion', e.cliente_identificacion,
    'centro_costos', e.cliente_centro_costos,
    'firma', e.firma_png,
    'confirmado_en', e.confirmado_en,
    'expira_en', e.expira_en
  );
end
$$;
revoke all on function public.carcove_voucher_publico(text) from public;
grant execute on function public.carcove_voucher_publico(text) to anon, authenticated;

create or replace function public.carcove_voucher_diligenciar(
  p_token text, p_identificacion text, p_centro text, p_firma text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  e public.carcove_voucher_enlaces;
  h text := public.carcove_huella();
  v_id text; v_cc text; v_ahora timestamptz := now();
begin
  if h is not null then
    if (select count(*) from public.carcove_enlace_intentos
          where huella = h and accion in ('fallo','escritura') and creado_en > now() - interval '10 minutes') >= 30 then
      return jsonb_build_object('ok', false, 'error', 'demasiados_intentos');
    end if;
    insert into public.carcove_enlace_intentos(huella, accion) values (h, 'escritura');
  end if;

  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    if h is not null then insert into public.carcove_enlace_intentos(huella, accion) values (h, 'fallo'); end if;
    return jsonb_build_object('ok', false, 'error', 'no_disponible');
  end if;

  select * into e from public.carcove_voucher_enlaces where token = p_token for update;
  if not found or e.estado = 'revocado' or e.expira_en < v_ahora then
    if h is not null then insert into public.carcove_enlace_intentos(huella, accion) values (h, 'fallo'); end if;
    return jsonb_build_object('ok', false, 'error', 'no_disponible');
  end if;
  if e.estado = 'completado' then
    return jsonb_build_object('ok', false, 'error', 'ya_confirmado');
  end if;

  -- Limpieza y validación en el servidor (no se confía en el navegador).
  v_id := trim(regexp_replace(coalesce(p_identificacion, ''), '[[:cntrl:]]', '', 'g'));
  v_cc := trim(regexp_replace(coalesce(p_centro, ''), '[[:cntrl:]]', '', 'g'));
  if char_length(v_id) < 3 or char_length(v_id) > 40 then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'identificacion');
  end if;
  if char_length(v_cc) < 2 or char_length(v_cc) > 80 then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'centro_costos');
  end if;
  if p_firma is null or p_firma !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$'
     or char_length(p_firma) > 300000 or char_length(p_firma) < 400 then
    return jsonb_build_object('ok', false, 'error', 'datos_invalidos', 'campo', 'firma');
  end if;

  update public.carcove_voucher_enlaces set
    estado = 'completado',
    cliente_identificacion = v_id,
    cliente_centro_costos = v_cc,
    firma_png = p_firma,
    confirmado_en = v_ahora,
    confirmado_huella = h,
    confirmado_agente = public.carcove_agente(),
    huella_documento = encode(sha256(convert_to(
        e.datos_publicos::text || '|' || v_id || '|' || v_cc || '|' || p_firma || '|' || v_ahora::text, 'UTF8')), 'hex'),
    actualizado_en = v_ahora
  where id = e.id;

  return jsonb_build_object('ok', true, 'confirmado_en', v_ahora);
end
$$;
revoke all on function public.carcove_voucher_diligenciar(text, text, text, text) from public;
grant execute on function public.carcove_voucher_diligenciar(text, text, text, text) to anon, authenticated;

-- Refrescar el caché de PostgREST para que las funciones nuevas queden disponibles.
notify pgrst, 'reload schema';
