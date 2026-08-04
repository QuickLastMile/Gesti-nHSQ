-- ============================================================
--  Gestión HSEQ Motos — Coordinador: Exportable + Actualizar matriz
--  Ejecutar después de schema/functions/functions_write/functions_coord.
-- ============================================================

-- Helper: valor de una columna del texto pegado, por nombre de encabezado.
create or replace function mat_val(cols text[], idx jsonb, nombre text)
returns text language sql immutable set search_path = public as $$
  select case
    when idx ? nombre and (idx->>nombre)::int <= coalesce(array_length(cols,1),0)
    then btrim(cols[(idx->>nombre)::int]) else '' end;
$$;

-- Fecha de la última actualización de matriz.
create or replace function api_matriz_info()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('ultimaActualizacion',
    coalesce((select valor from config where clave = 'MATRIZ_ULTIMA_ACTUALIZACION'), ''));
$$;

-- ------------------------------------------------------------
--  Actualizar la matriz con el export de nómina pegado.
-- ------------------------------------------------------------
create or replace function api_actualizar_matriz(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  texto text := btrim(replace(coalesce(payload->>'data',''), E'\r', ''));
  lineas text[]; hdr text[]; cols text[];
  idx jsonb := '{}'::jsonb;
  i int; j int;
  ncedula text; retiro text; activo_new boolean;
  presentes text[] := '{}';
  c_act int := 0; c_new int := 0; c_inact int := 0;
  hoy text := to_char((now() at time zone 'America/Bogota'), 'YYYY-MM-DD HH24:MI');
begin
  if texto = '' then raise exception 'Pega los datos de la matriz.'; end if;
  lineas := string_to_array(texto, E'\n');
  if coalesce(array_length(lineas,1),0) < 2 then raise exception 'Incluye la fila de titulos y al menos un registro.'; end if;

  hdr := string_to_array(lineas[1], E'\t');
  for i in 1 .. array_length(hdr,1) loop
    idx := idx || jsonb_build_object(btrim(hdr[i]), i);
  end loop;
  if not (idx ? 'ClientId') then raise exception 'No encuentro la columna "ClientId" (cedula). Incluye la fila de titulos.'; end if;
  if not (idx ? 'ClientName') then raise exception 'No encuentro la columna "ClientName" (nombre).'; end if;

  for j in 2 .. array_length(lineas,1) loop
    if btrim(lineas[j]) = '' then continue; end if;
    cols := string_to_array(lineas[j], E'\t');
    ncedula := regexp_replace(mat_val(cols, idx, 'ClientId'), '\D', '', 'g');
    if ncedula = '' then continue; end if;
    retiro := mat_val(cols, idx, 'DateRetirement');
    activo_new := (upper(mat_val(cols, idx, 'State')) = 'A' and retiro = '');
    presentes := presentes || ncedula;

    if exists (select 1 from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula) then
      update colaboradores set
        estado_nomina = nullif(mat_val(cols,idx,'State'),''),
        nombre = coalesce(nullif(mat_val(cols,idx,'ClientName'),''), nombre),
        cargo = coalesce(nullif(mat_val(cols,idx,'PlaceName'),''), cargo),
        proyecto_id = coalesce(nullif(mat_val(cols,idx,'ProjectId'),''), proyecto_id),
        proyecto = coalesce(nullif(mat_val(cols,idx,'ProjectName'),''), proyecto),
        ciudad = coalesce(nullif(mat_val(cols,idx,'Ciudad'),''), ciudad),
        telefono = coalesce(nullif(mat_val(cols,idx,'Phone'),''), telefono),
        celular = coalesce(nullif(mat_val(cols,idx,'CelPhone'),''), celular),
        email = coalesce(nullif(mat_val(cols,idx,'Email'),''), email),
        activo = activo_new,
        actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = ncedula;
      c_act := c_act + 1;
    else
      insert into colaboradores (cedula, estado_nomina, nombre, cargo, proyecto_id, proyecto,
        ciudad, telefono, celular, email, activo, tipo_vehiculo, observaciones_hsq)
      values (ncedula, nullif(mat_val(cols,idx,'State'),''), mat_val(cols,idx,'ClientName'),
        nullif(mat_val(cols,idx,'PlaceName'),''), nullif(mat_val(cols,idx,'ProjectId'),''),
        nullif(mat_val(cols,idx,'ProjectName'),''), nullif(mat_val(cols,idx,'Ciudad'),''),
        nullif(mat_val(cols,idx,'Phone'),''), nullif(mat_val(cols,idx,'CelPhone'),''),
        nullif(mat_val(cols,idx,'Email'),''), activo_new, 'MOTO', 'Agregada el ' || hoy || ' desde actualizacion de matriz.')
      on conflict (cedula) do nothing;
      c_new := c_new + 1;
    end if;
  end loop;

  -- Inactivar a quien NO aparezca en la data cargada.
  update colaboradores set activo = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') || ' | Inactivada el ' || hoy || ': no aparece en la matriz cargada.', ' |'),
    actualizado_en = now()
  where activo and not (regexp_replace(cedula,'\D','','g') = any(presentes));
  get diagnostics c_inact = row_count;

  insert into config (clave, valor) values ('MATRIZ_ULTIMA_ACTUALIZACION', hoy)
    on conflict (clave) do update set valor = excluded.valor;
  insert into historial (tipo, cedula, detalle)
  values ('ACTUALIZACION_MATRIZ', '', 'Actualizados ' || c_act || ', nuevos ' || c_new || ', inactivados ' || c_inact);

  return jsonb_build_object('actualizados', c_act, 'nuevos', c_new, 'inactivados', c_inact,
    'totalEnData', coalesce(array_length(presentes,1),0), 'fecha', hoy);
end;
$$;

-- ------------------------------------------------------------
--  Exportable: devuelve preguntas + filas (el frontend arma el CSV).
-- ------------------------------------------------------------
create or replace function api_exportable(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fid text := payload->>'formulario';
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  preguntas jsonb;
  filas jsonb := '[]'::jsonb;
  rec record;
begin
  if fid is null or fid = '' then raise exception 'Selecciona un formulario.'; end if;
  if fi is null or ff is null or fi > ff then raise exception 'Rango de fechas invalido.'; end if;

  preguntas := coalesce((select jsonb_agg(jsonb_build_object('id', id, 'pregunta', pregunta) order by orden)
                         from preguntas where formulario_id = fid and activo), '[]'::jsonb);

  for rec in
    select r.id, r.fecha, r.hora, r.cedula, r.nombre, r.cargo, r.proyecto_id, r.proyecto,
           r.ciudad, r.placa_moto, r.tipo_vehiculo, r.estado, r.alertas,
      coalesce((select jsonb_object_agg(pregunta_id, valor)
                from (select distinct on (pregunta_id) pregunta_id, valor from respuestas
                      where registro_id = r.id order by pregunta_id) rp), '{}'::jsonb) as resp,
      coalesce((select jsonb_object_agg(pregunta_id, archivo)
                from (select distinct on (pregunta_id) pregunta_id,
                        coalesce(nullif(storage_path,''), url) as archivo
                      from evidencias where registro_id = r.id
                        and (coalesce(storage_path,'') <> '' or coalesce(url,'') <> '')
                      order by pregunta_id, subido_en desc) ev), '{}'::jsonb) as evid
    from registros r
    where r.formulario_id = fid and r.fecha between fi and ff
      and coalesce(r.estado,'') <> 'ANULADO'
      and (filtro_proy = '' or r.proyecto = filtro_proy or r.proyecto_id::text = filtro_proy)
      and (ncedula = '' or regexp_replace(r.cedula,'\D','','g') = ncedula)
    order by r.fecha, r.hora
  loop
    filas := filas || jsonb_build_array(jsonb_build_object(
      'fecha', to_char(rec.fecha,'YYYY-MM-DD'), 'hora', to_char(rec.hora,'HH24:MI:SS'),
      'id_registro', rec.id, 'cedula', rec.cedula, 'nombre', coalesce(rec.nombre,''),
      'cargo', coalesce(rec.cargo,''), 'proyecto_id', coalesce(rec.proyecto_id,''),
      'proyecto', coalesce(rec.proyecto,''), 'ciudad', coalesce(rec.ciudad,''),
      'placa_moto', coalesce(rec.placa_moto,''), 'tipo_vehiculo', coalesce(rec.tipo_vehiculo,''),
      'estado', coalesce(rec.estado,''),
      'estado_cumplimiento', case when coalesce(rec.alertas,'') <> '' then 'REQUIERE_GESTION' else 'CUMPLE' end,
      'alertas_documentales', coalesce(rec.alertas,''),
      'respuestas', rec.resp, 'evidencias', rec.evid));
  end loop;

  return jsonb_build_object('formulario', fid, 'preguntas', preguntas, 'filas', filas,
    'total', jsonb_array_length(filas));
end;
$$;

-- ------------------------------------------------------------
--  Anular registro: no borra evidencias ni respuestas; conserva auditoria.
-- ------------------------------------------------------------
create or replace function api_anular_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  rid uuid := nullif(payload->>'id_registro','')::uuid;
  motivo text := btrim(coalesce(payload->>'motivo',''));
  r registros%rowtype;
begin
  if rid is null then raise exception 'Falta el ID del registro.'; end if;
  if length(motivo) < 5 then raise exception 'Escribe un motivo de al menos 5 caracteres.'; end if;

  select * into r from registros where id = rid for update;
  if not found then raise exception 'Registro no encontrado.'; end if;
  if r.estado = 'ANULADO' then raise exception 'El registro ya estaba anulado.'; end if;

  update registros set
    estado = 'ANULADO',
    alertas = concat_ws(' | ', nullif(alertas,''), 'ANULADO: ' || motivo)
  where id = rid;

  insert into historial(tipo, cedula, detalle)
  values ('ANULACION_REGISTRO', r.cedula,
    'Registro ' || rid::text || ' (' || r.formulario_id || ', ' || to_char(r.fecha,'YYYY-MM-DD') || '): ' || motivo);

  return jsonb_build_object('idRegistro', rid, 'anulado', true, 'motivo', motivo);
end;
$$;

-- ------------------------------------------------------------
--  Router completo (todas las acciones).
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if action in ('getCumplimientoDia','guardarJustificacion','getDashboard',
                'generarExportable','anularRegistro','actualizarMatriz','getMatrizInfo')
     and not hseq_tiene_rol(array['ADMIN','HSEQ','COORDINADOR']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como coordinador autorizado.');
  end if;
  case action
    when 'getBootstrap'         then result := api_get_bootstrap();
    when 'buscarActivo'         then result := api_buscar_activo(payload);
    when 'cargarFormulario'     then result := api_cargar_formulario(payload);
    when 'guardarRegistro'      then result := api_guardar_registro(payload);
    when 'registrarPlaca'       then result := api_registrar_placa(payload);
    when 'getCumplimientoDia'   then result := api_cumplimiento_dia(payload);
    when 'guardarJustificacion' then result := api_guardar_justificacion(payload);
    when 'getDashboard'         then result := api_dashboard(payload);
    when 'generarExportable'    then result := api_exportable(payload);
    when 'anularRegistro'       then result := api_anular_registro(payload);
    when 'actualizarMatriz'     then result := api_actualizar_matriz(payload);
    when 'getMatrizInfo'        then result := api_matriz_info();
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function hseq_api(text, jsonb) to anon;
