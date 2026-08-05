-- ============================================================
--  Gestión HSEQ Motos — Panel de administración HSQ
--  Funciones que SOLO puede usar un usuario con sesión iniciada
--  (el encargado de HSQ). El anon (mensajero) NO puede llamarlas.
--  Ejecutar después de schema.sql / functions.sql / functions_write.sql.
-- ============================================================

-- JSON de un colaborador (reutilizable en buscar/listar).
create or replace function colab_json(c colaboradores)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
    'proyecto', coalesce(c.proyecto,''), 'proyecto_id', coalesce(c.proyecto_id,''),
    'ciudad', coalesce(c.ciudad,''), 'activo', c.activo, 'placa_moto', coalesce(c.placa_moto,''),
    'observacion_coordinador', coalesce(c.observacion_coordinador,''),
    'tipo_vehiculo', coalesce(c.tipo_vehiculo,''), 'marca_vehiculo', coalesce(c.marca_vehiculo,''),
    'cilindraje', coalesce(c.cilindraje,''),
    'soat_vence', to_char(c.soat_vence,'YYYY-MM-DD'),
    'tecnomecanica_vence', to_char(c.tecnomecanica_vence,'YYYY-MM-DD'),
    'licencia_vence', to_char(c.licencia_vence,'YYYY-MM-DD'),
    'soat_url', coalesce(c.soat_url,''), 'tecnomecanica_url', coalesce(c.tecnomecanica_url,''),
    'licencia_url', coalesce(c.licencia_url,'')
  );
$$;

-- Buscar por cédula o nombre.
create or replace function admin_buscar_colaborador(payload jsonb)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(colab_json(c) order by c.nombre), '[]'::jsonb)
  from colaboradores c
  where case when regexp_replace(coalesce(payload->>'q',''), '\D', '', 'g') <> ''
    then regexp_replace(c.cedula,'\D','','g') like regexp_replace(payload->>'q','\D','','g') || '%'
    else sin_tildes(c.nombre) like '%' || sin_tildes(coalesce(payload->>'q','')) || '%'
  end
  limit 50;
$$;

-- Lista de proyectos (para el desplegable).
create or replace function admin_proyectos()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('proyecto', proyecto) order by proyecto), '[]'::jsonb)
  from (select distinct proyecto from colaboradores where coalesce(proyecto,'') <> '') t;
$$;

-- Listar personal por proyecto y estado (activos/inactivos/todos).
create or replace function admin_listar(payload jsonb)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(colab_json(c) order by (not c.activo), c.nombre), '[]'::jsonb)
  from colaboradores c
  where (coalesce(payload->>'proyecto','') = '' or c.proyecto = payload->>'proyecto')
    and case coalesce(payload->>'estado','todos')
          when 'activos' then c.activo
          when 'inactivos' then not c.activo
          else true end
  limit 800;
$$;

-- Guardar cambios de un colaborador.
create or replace function admin_guardar_colaborador(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  nueva_placa text := upper(btrim(coalesce(payload->>'placa_moto','')));
  nuevo_activo boolean := coalesce((nullif(payload->>'activo',''))::boolean, false);
begin
  if ncedula = '' then raise exception 'Cedula invalida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula;
  if not found then raise exception 'No existe esa cedula en la matriz.'; end if;

  update colaboradores set
    activo = nuevo_activo,
    placa_moto = nullif(nueva_placa, ''),
    observacion_coordinador = nullif(btrim(coalesce(payload->>'observacion_coordinador','')), ''),
    tipo_vehiculo = coalesce(nullif(btrim(coalesce(payload->>'tipo_vehiculo','')), ''), 'MOTO'),
    marca_vehiculo = nullif(btrim(coalesce(payload->>'marca_vehiculo','')), ''),
    cilindraje = nullif(btrim(coalesce(payload->>'cilindraje','')), ''),
    soat_vence = substring(coalesce(payload->>'soat_vence','') from '\d{4}-\d{2}-\d{2}')::date,
    tecnomecanica_vence = substring(coalesce(payload->>'tecnomecanica_vence','') from '\d{4}-\d{2}-\d{2}')::date,
    licencia_vence = substring(coalesce(payload->>'licencia_vence','') from '\d{4}-\d{2}-\d{2}')::date,
    actualizado_en = now()
  where regexp_replace(cedula,'\D','','g') = ncedula;

  if upper(btrim(coalesce(c.placa_moto,''))) <> nueva_placa then
    insert into historial (tipo, cedula, detalle)
    values ('ADMIN_PLACA', ncedula, 'Placa ' || coalesce(c.placa_moto,'(vacía)') || ' -> ' || coalesce(nullif(nueva_placa,''),'(vacía)'));
  end if;
  if c.activo <> nuevo_activo then
    insert into historial (tipo, cedula, detalle)
    values ('ADMIN_ESTADO', ncedula, case when nuevo_activo then 'Activado' else 'Inactivado' end);
  end if;

  return jsonb_build_object('cedula', ncedula, 'activo', nuevo_activo, 'placa_moto', nueva_placa);
end;
$$;

-- Router de administración: SOLO usuarios con sesión (encargado HSQ).
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  -- Debe ser un usuario con sesion REAL (no un anonimo de subida de fotos).
  if coalesce((select auth.role()), 'anon') <> 'authenticated'
     or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
     or not hseq_tiene_rol(array['ADMIN','HSEQ']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
  end if;
  case action
    when 'buscarColaborador'  then result := admin_buscar_colaborador(payload);
    when 'listar'             then result := admin_listar(payload);
    when 'proyectos'          then result := admin_proyectos();
    when 'guardarColaborador' then result := admin_guardar_colaborador(payload);
    when 'calendario'         then result := admin_calendario();
    when 'guardarCalendario'  then result := admin_guardar_calendario(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

revoke execute on function hseq_admin(text, jsonb) from anon;
grant execute on function hseq_admin(text, jsonb) to authenticated;
