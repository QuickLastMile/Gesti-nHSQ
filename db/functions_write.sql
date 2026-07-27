-- ============================================================
--  Gestión HSEQ Motos — Funciones de ESCRITURA (Milestone 2)
--  Ejecutar DESPUÉS de schema.sql y functions.sql.
--  Agrega: guardar registro, registrar/cambiar placa.
--  Al final actualiza el router hseq_api para reconocer las
--  nuevas acciones. Correr todo de una vez en SQL Editor.
-- ============================================================

-- Helper: texto en MAYÚSCULAS y sin tildes (para reconocer documentos).
create or replace function sin_tildes(s text)
returns text language sql immutable as $$
  select upper(translate(coalesce(s, ''),
    'áàäâéèëêíìïîóòöôúùüûñÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑ',
    'aaaaeeeeiiiioooouuuunAAAAEEEEIIIIOOOOUUUUN'));
$$;

-- Helper: ¿esta pregunta (tipo fecha) corresponde a un documento?
create or replace function doc_key(preg text, tipo text, doc text)
returns text language sql immutable as $$
  select case
    when coalesce(tipo, '') <> 'fecha' then null
    when sin_tildes(doc) in ('SOAT', 'TECNOMECANICA', 'LICENCIA') then sin_tildes(doc)
    when sin_tildes(preg) like '%SOAT%' then 'SOAT'
    when sin_tildes(preg) ~ 'TECNO|TECNIC|MECANIC' then 'TECNOMECANICA'
    when sin_tildes(preg) like '%LICENCIA%' then 'LICENCIA'
    else null
  end;
$$;

-- ------------------------------------------------------------
--  guardarRegistro
-- ------------------------------------------------------------
create or replace function api_guardar_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  fid text := payload->>'id_formulario';
  respuestas jsonb := coalesce(payload->'respuestas', '{}'::jsonb);
  evidencias jsonb := coalesce(payload->'evidencias', '[]'::jsonb);
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  ahora time := (now() at time zone 'America/Bogota')::time;
  rid uuid;
  gate boolean;
  p record; f record; r record; ev jsonb;
  dk text; val text;
  v_soat_v date; v_tecno_v date; v_lic_v date;
  v_soat_u text; v_tecno_u text; v_lic_u text;
  estado jsonb := '{}'::jsonb;
  regs jsonb := '[]'::jsonb;
  completo boolean := true;
begin
  if ncedula = '' or fid is null then raise exception 'Datos incompletos.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if not c.activo then raise exception 'La persona no esta activa para registro.'; end if;

  -- Regla: un registro por dia por formulario.
  if exists (select 1 from registros
             where regexp_replace(cedula,'\D','','g') = ncedula
               and formulario_id = fid and fecha = hoy) then
    raise exception 'Ya realizaste este registro hoy. Solo se permite un registro diario por tipo.';
  end if;

  gate := upper(coalesce(respuestas->>'DOC_PRIMERA_O_RENOVACION','')) = 'SI';

  -- Fechas de vencimiento de documentos.
  for p in select id, pregunta, tipo_respuesta, documento from preguntas
           where formulario_id = fid and activo loop
    dk := doc_key(p.pregunta, p.tipo_respuesta, p.documento);
    if dk is null then continue; end if;
    if gate then
      val := substring(btrim(coalesce(respuestas->>p.id, '')) from '\d{4}-\d{2}-\d{2}');
      if val is not null then
        if dk = 'SOAT' then v_soat_v := val::date;
        elsif dk = 'TECNOMECANICA' then v_tecno_v := val::date;
        else v_lic_v := val::date; end if;
      end if;
    else
      -- Dia a dia: se refleja la fecha ya guardada (pregunta bloqueada).
      val := to_char(case dk when 'SOAT' then c.soat_vence
                             when 'TECNOMECANICA' then c.tecnomecanica_vence
                             else c.licencia_vence end, 'YYYY-MM-DD');
      respuestas := jsonb_set(respuestas, array[p.id], to_jsonb(coalesce(val, '')));
    end if;
  end loop;

  -- Enlaces de documentos (solo al actualizar).
  if gate then
    for ev in select value from jsonb_array_elements(evidencias) loop
      if ev->>'id_pregunta' = 'DOC_SOAT' then v_soat_u := ev->>'url';
      elsif ev->>'id_pregunta' = 'DOC_TECNOMECANICA' then v_tecno_u := ev->>'url';
      elsif ev->>'id_pregunta' = 'DOC_LICENCIA_TRANSITO' then v_lic_u := ev->>'url';
      end if;
    end loop;
  end if;

  -- Inserta el registro (con snapshot de la persona).
  insert into registros (cedula, formulario_id, fecha, hora, estado,
    nombre, cargo, proyecto_id, proyecto, ciudad, placa_moto, tipo_vehiculo)
  values (ncedula, fid, hoy, ahora, 'OK',
    c.nombre, c.cargo, c.proyecto_id, c.proyecto, c.ciudad, c.placa_moto, c.tipo_vehiculo)
  returning id into rid;

  -- Respuestas (arrays -> unidas por coma).
  insert into respuestas (registro_id, pregunta_id, valor)
  select rid, key,
    case when jsonb_typeof(value) = 'array'
      then (select string_agg(x, ', ') from jsonb_array_elements_text(value) x)
      else value #>> '{}' end
  from jsonb_each(respuestas);

  -- Evidencias.
  insert into evidencias (registro_id, pregunta_id, nombre, storage_path, url)
  select rid, e->>'id_pregunta', e->>'nombre', e->>'path', e->>'url'
  from jsonb_array_elements(evidencias) e;

  -- Actualiza documentos en la matriz.
  if gate then
    update colaboradores set
      soat_vence = coalesce(v_soat_v, soat_vence),
      tecnomecanica_vence = coalesce(v_tecno_v, tecnomecanica_vence),
      licencia_vence = coalesce(v_lic_v, licencia_vence),
      soat_url = coalesce(v_soat_u, soat_url),
      tecnomecanica_url = coalesce(v_tecno_u, tecnomecanica_url),
      licencia_url = coalesce(v_lic_u, licencia_url),
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;
    insert into historial (tipo, cedula, detalle) values ('DOCUMENTOS', ncedula, 'Actualizados desde registro');
  end if;

  -- Estado del dia + comprobante.
  for f in select id, nombre from formularios where activo order by orden loop
    select to_char(hora,'HH24:MI') as h, id::text as rid2 into r
      from registros where regexp_replace(cedula,'\D','','g') = ncedula
        and formulario_id = f.id and fecha = hoy limit 1;
    if found then
      estado := estado || jsonb_build_object(f.id,
        jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid2));
      regs := regs || jsonb_build_array(jsonb_build_object(
        'id_formulario', f.id, 'formulario', f.nombre, 'hora', coalesce(r.h,''), 'idRegistro', r.rid2));
    else
      estado := estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      completo := false;
    end if;
  end loop;

  return jsonb_build_object(
    'idRegistro', rid, 'estado', 'OK', 'alertas', '[]'::jsonb,
    'estadoDiario', estado, 'completo', completo, 'archivoDiaUrl', '#',
    'comprobante', jsonb_build_object(
      'nombre', c.nombre, 'cedula', ncedula, 'placa_moto', coalesce(c.placa_moto,''),
      'proyecto', coalesce(c.proyecto,''), 'ciudad', coalesce(c.ciudad,''),
      'fecha', to_char(hoy,'YYYY-MM-DD'), 'completo', completo, 'registros', regs)
  );
end;
$$;

-- ------------------------------------------------------------
--  registrarPlaca (registrar la 1a vez o cambiar de moto)
-- ------------------------------------------------------------
create or replace function api_registrar_placa(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  nplaca text := upper(btrim(coalesce(payload->>'placa','')));
  obs text := btrim(coalesce(payload->>'observacion',''));
  c colaboradores%rowtype;
  anterior text; es_cambio boolean;
  sello text := to_char((now() at time zone 'America/Bogota'), 'YYYY-MM-DD HH24:MI');
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;
  if nplaca = '' then raise exception 'Digite una placa valida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'No se encontro la cedula.'; end if;
  anterior := upper(btrim(coalesce(c.placa_moto,'')));
  es_cambio := anterior <> '' and anterior <> nplaca;
  if es_cambio and obs = '' then
    raise exception 'Para cambiar la placa debes escribir el motivo del cambio.';
  end if;

  update colaboradores set
    placa_moto = nplaca, actualizado_en = now(),
    observaciones_hsq = case when es_cambio then
      btrim(coalesce(observaciones_hsq,'') || ' | Placa ' || anterior || ' -> ' || nplaca || ' (' || sello || '): ' || obs, ' |')
      else observaciones_hsq end
  where regexp_replace(cedula,'\D','','g') = ncedula;

  if es_cambio then
    insert into historial (tipo, cedula, detalle)
    values ('CAMBIO_PLACA', ncedula, 'Placa ' || anterior || ' -> ' || nplaca || ': ' || obs);
  end if;

  return jsonb_build_object('placa_moto', nplaca, 'cambio', es_cambio);
end;
$$;

-- ------------------------------------------------------------
--  Router actualizado: agrega las acciones de escritura.
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  case action
    when 'getBootstrap'     then result := api_get_bootstrap();
    when 'buscarActivo'     then result := api_buscar_activo(payload);
    when 'cargarFormulario' then result := api_cargar_formulario(payload);
    when 'guardarRegistro'  then result := api_guardar_registro(payload);
    when 'registrarPlaca'   then result := api_registrar_placa(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function hseq_api(text, jsonb) to anon;

-- ------------------------------------------------------------
--  Permiso para subir fotos al bucket 'evidencias' (sin login).
--  El anon SOLO puede subir; no puede listar ni leer (privado).
-- ------------------------------------------------------------
drop policy if exists "anon_sube_evidencias" on storage.objects;
create policy "anon_sube_evidencias" on storage.objects
  for insert to anon with check (bucket_id = 'evidencias');
