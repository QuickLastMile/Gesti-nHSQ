-- ============================================================
--  Gestión HSEQ Motos — Panel de administración HSQ (Milestone)
--  Funciones que SOLO puede usar un usuario con sesión iniciada
--  (el encargado de HSQ). El anon (mensajero) NO puede llamarlas.
--  Ejecutar después de schema.sql / functions.sql / functions_write.sql.
-- ============================================================

-- Buscar colaboradores por cédula o nombre (para el panel HSQ).
create or replace function admin_buscar_colaborador(payload jsonb)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(row order by nombre), '[]'::jsonb) from (
    select jsonb_build_object(
      'cedula', cedula, 'nombre', coalesce(nombre,''), 'cargo', coalesce(cargo,''),
      'proyecto', coalesce(proyecto,''), 'ciudad', coalesce(ciudad,''),
      'activo', activo, 'placa_moto', coalesce(placa_moto,''),
      'observacion_coordinador', coalesce(observacion_coordinador,''),
      'tipo_vehiculo', coalesce(tipo_vehiculo,''), 'marca_vehiculo', coalesce(marca_vehiculo,''),
      'cilindraje', coalesce(cilindraje,''),
      'soat_vence', to_char(soat_vence,'YYYY-MM-DD'),
      'tecnomecanica_vence', to_char(tecnomecanica_vence,'YYYY-MM-DD'),
      'licencia_vence', to_char(licencia_vence,'YYYY-MM-DD')
    ) as row, nombre
    from colaboradores
    where
      case when regexp_replace(coalesce(payload->>'q',''), '\D', '', 'g') <> ''
        then regexp_replace(cedula,'\D','','g') like regexp_replace(payload->>'q','\D','','g') || '%'
        else sin_tildes(nombre) like '%' || sin_tildes(coalesce(payload->>'q','')) || '%'
      end
    limit 50
  ) t;
$$;

-- Guardar cambios de un colaborador (el formulario envía todos los campos).
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

-- Router de administración: SOLO para usuarios con sesión (encargado HSQ).
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  -- Doble candado: además del permiso, se exige sesión iniciada.
  if coalesce((select auth.role()), 'anon') <> 'authenticated' then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
  end if;
  case action
    when 'buscarColaborador'  then result := admin_buscar_colaborador(payload);
    when 'guardarColaborador' then result := admin_guardar_colaborador(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

-- El anon NO puede; solo usuarios autenticados (HSQ con login).
revoke execute on function hseq_admin(text, jsonb) from anon;
grant execute on function hseq_admin(text, jsonb) to authenticated;
