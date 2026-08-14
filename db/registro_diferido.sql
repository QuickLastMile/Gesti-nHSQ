-- ============================================================
--  Gestión HSEQ Motos — Registros hechos sin señal
--  ------------------------------------------------------------
--  Cuando el mensajero diligencia en una zona sin datos, el
--  registro queda guardado en su celular y se envía solo cuando
--  vuelve la señal. Para no falsear la trazabilidad se guardan
--  LAS DOS marcas de tiempo:
--
--    capturado_en  cuando lo diligenció en la calle (la que vale)
--    creado_en     cuando llegó al servidor
--    diferido      true si hubo diferencia entre ambas
--
--  Ejecutar DESPUÉS de: preoperacional_vehiculos.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

alter table registros
  add column if not exists capturado_en timestamptz,
  add column if not exists diferido boolean not null default false;

comment on column registros.capturado_en is
  'Momento en que se diligenció en el celular. Puede ser anterior a creado_en si se hizo sin señal.';
comment on column registros.diferido is
  'true = se diligenció sin conexión y se envió después.';

-- ------------------------------------------------------------
--  guardarRegistro acepta la marca de captura del celular.
--  Se admite solo hacia atrás y hasta 72 horas: ni fechas futuras
--  ni registros de la semana pasada.
-- ------------------------------------------------------------
create or replace function api_guardar_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  fid text := payload->>'id_formulario';
  respuestas jsonb := coalesce(payload->'respuestas', '{}'::jsonb);
  evidencias jsonb := coalesce(payload->'evidencias', '[]'::jsonb);
  c colaboradores%rowtype;
  perfil text;
  ahora_ts timestamptz := now() at time zone 'utc';
  local_ts timestamptz;
  hoy date := (now() at time zone 'America/Bogota')::date;
  ahora time := (now() at time zone 'America/Bogota')::time;
  es_diferido boolean := false;
  rid uuid;
  gate boolean;
  p record; f record; r record;
  dk text; val text;
  v_soat_v date; v_tecno_v date; v_lic_v date;
  v_soat_u text; v_tecno_u text; v_lic_u text;
  alertas_doc text := '';
  estado jsonb := '{}'::jsonb;
  regs jsonb := '[]'::jsonb;
  completo boolean := true;
begin
  if ncedula = '' or fid is null then raise exception 'Datos incompletos.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if not c.activo then raise exception 'La persona no esta activa para registro.'; end if;
  perfil := perfil_cargo(c.cargo);

  -- Marca de captura enviada por el celular (registro hecho sin señal)
  begin
    local_ts := nullif(payload->>'capturado_en','')::timestamptz;
  exception when others then
    local_ts := null;
  end;
  if local_ts is not null then
    if local_ts > now() + interval '10 minutes' then
      raise exception 'La hora del registro no puede estar en el futuro.';
    end if;
    if local_ts < now() - interval '72 hours' then
      raise exception 'Este registro tiene mas de 72 horas y ya no puede enviarse. Pidele a tu coordinador que lo justifique.';
    end if;
    hoy := (local_ts at time zone 'America/Bogota')::date;
    ahora := (local_ts at time zone 'America/Bogota')::time;
    es_diferido := abs(extract(epoch from (now() - local_ts))) > 300;   -- más de 5 minutos
  end if;

  if not exists (
    select 1
    from proyectos_formularios pf
    join formularios frm on frm.id=pf.formulario_id and frm.activo
    where pf.proyecto=coalesce(c.proyecto,'') and pf.formulario_id=fid and pf.activo
  ) then
    raise exception 'Este formulario no esta habilitado para tu proyecto.';
  end if;

  if exists (select 1 from registros
             where regexp_replace(cedula,'\D','','g') = ncedula
               and formulario_id = fid and fecha = hoy) then
    raise exception 'Ya realizaste este registro hoy. Solo se permite un registro diario por tipo.';
  end if;

  gate := upper(coalesce(respuestas->>'DOC_PRIMERA_O_RENOVACION','')) = 'SI';

  if (respuestas ? 'DOC_PRIMERA_O_RENOVACION') and not gate then
    declare faltan text := '';
    begin
      if coalesce(btrim(c.soat_url),'') = '' then faltan := faltan || 'SOAT, '; end if;
      if coalesce(btrim(c.tecnomecanica_url),'') = '' then faltan := faltan || 'Tecnomecanica, '; end if;
      if coalesce(btrim(c.licencia_url),'') = '' then faltan := faltan || 'Licencia, '; end if;
      if faltan <> '' then
        raise exception 'Falta adjuntar documentacion (%). Responde SI en la primera pregunta y adjunta los archivos.', btrim(faltan, ', ');
      end if;
    end;
  end if;

  for p in select id, pregunta, tipo_respuesta, documento from preguntas
           where formulario_id = fid and activo
             and (aplica_a is null or aplica_a = perfil) loop
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
      val := to_char(case dk when 'SOAT' then c.soat_vence
                             when 'TECNOMECANICA' then c.tecnomecanica_vence
                             else c.licencia_vence end, 'YYYY-MM-DD');
      respuestas := jsonb_set(respuestas, array[p.id], to_jsonb(coalesce(val, '')));
    end if;
  end loop;

  if gate then
    select e->>'url' into v_soat_u  from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_SOAT' limit 1;
    select e->>'url' into v_tecno_u from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_TECNOMECANICA' limit 1;
    select e->>'url' into v_lic_u   from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_LICENCIA_TRANSITO' limit 1;
    if coalesce(btrim(v_soat_u),'') = '' then raise exception 'Debes adjuntar el SOAT completo.'; end if;
    if coalesce(btrim(v_tecno_u),'') = '' then raise exception 'Debes adjuntar la tecnomecanica completa.'; end if;
    if coalesce(btrim(v_lic_u),'') = '' then raise exception 'Debes adjuntar la licencia de transito.'; end if;
    if v_soat_v is null or v_tecno_v is null or v_lic_v is null then
      raise exception 'Debes registrar las tres fechas de vencimiento.';
    end if;
    if v_soat_v < hoy - interval '10 years' or v_soat_v > hoy + interval '2 years' then
      raise exception 'La fecha de vencimiento del SOAT no parece valida.';
    end if;
    if v_tecno_v < hoy - interval '10 years' or v_tecno_v > hoy + interval '2 years' then
      raise exception 'La fecha de vencimiento de la tecnomecanica no parece valida.';
    end if;
    if v_lic_v < hoy - interval '10 years' or v_lic_v > hoy + interval '20 years' then
      raise exception 'La fecha de vencimiento de la licencia no parece valida.';
    end if;
  end if;

  if coalesce(btrim(coalesce(v_soat_u, c.soat_url)),'') = '' then
    raise exception 'Falta adjuntar el SOAT.';
  end if;
  if coalesce(btrim(coalesce(v_tecno_u, c.tecnomecanica_url)),'') = '' then
    raise exception 'Falta adjuntar la revision tecnomecanica.';
  end if;
  if coalesce(btrim(coalesce(v_lic_u, c.licencia_url)),'') = '' then
    raise exception 'Falta adjuntar la licencia de transito.';
  end if;

  if coalesce(v_soat_v, c.soat_vence) is null then
    alertas_doc := alertas_doc || 'SOAT sin fecha de vencimiento | ';
  elsif coalesce(v_soat_v, c.soat_vence) < hoy then
    alertas_doc := alertas_doc || 'SOAT vencido el ' || to_char(coalesce(v_soat_v, c.soat_vence),'YYYY-MM-DD') || ' | ';
  elsif coalesce(v_soat_v, c.soat_vence) <= hoy + 15 then
    alertas_doc := alertas_doc || 'SOAT proximo a vencer el ' || to_char(coalesce(v_soat_v, c.soat_vence),'YYYY-MM-DD') || ' | ';
  end if;
  if coalesce(v_tecno_v, c.tecnomecanica_vence) is null then
    alertas_doc := alertas_doc || 'Tecnomecanica sin fecha de vencimiento | ';
  elsif coalesce(v_tecno_v, c.tecnomecanica_vence) < hoy then
    alertas_doc := alertas_doc || 'Tecnomecanica vencida el ' || to_char(coalesce(v_tecno_v, c.tecnomecanica_vence),'YYYY-MM-DD') || ' | ';
  elsif coalesce(v_tecno_v, c.tecnomecanica_vence) <= hoy + 15 then
    alertas_doc := alertas_doc || 'Tecnomecanica proxima a vencer el ' || to_char(coalesce(v_tecno_v, c.tecnomecanica_vence),'YYYY-MM-DD') || ' | ';
  end if;
  if coalesce(v_lic_v, c.licencia_vence) is null then
    alertas_doc := alertas_doc || 'Licencia sin fecha de vencimiento | ';
  elsif coalesce(v_lic_v, c.licencia_vence) < hoy then
    alertas_doc := alertas_doc || 'Licencia vencida el ' || to_char(coalesce(v_lic_v, c.licencia_vence),'YYYY-MM-DD') || ' | ';
  elsif coalesce(v_lic_v, c.licencia_vence) <= hoy + 15 then
    alertas_doc := alertas_doc || 'Licencia proxima a vencer el ' || to_char(coalesce(v_lic_v, c.licencia_vence),'YYYY-MM-DD') || ' | ';
  end if;
  if es_diferido then
    alertas_doc := alertas_doc || 'Registro diligenciado sin conexion el ' ||
      to_char(local_ts at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI') || ' | ';
  end if;
  alertas_doc := rtrim(alertas_doc, ' |');

  insert into registros (cedula, formulario_id, fecha, hora, estado, alertas,
    nombre, cargo, proyecto_id, proyecto, ciudad, placa_moto, tipo_vehiculo,
    capturado_en, diferido)
  values (ncedula, fid, hoy, ahora,
    case when alertas_doc <> '' then 'CON_ALERTA' else 'OK' end,
    nullif(alertas_doc, ''),
    c.nombre, c.cargo, c.proyecto_id, c.proyecto, c.ciudad, c.placa_moto,
    coalesce(nullif(c.tipo_vehiculo,''), perfil),
    coalesce(local_ts, now()), es_diferido)
  returning id into rid;

  insert into respuestas (registro_id, pregunta_id, valor)
  select rid, key,
    case when jsonb_typeof(value) = 'array'
      then (select string_agg(x, ', ') from jsonb_array_elements_text(value) x)
      else value #>> '{}' end
  from jsonb_each(respuestas);

  insert into evidencias (registro_id, pregunta_id, nombre, storage_path, url)
  select rid, e->>'id_pregunta', e->>'nombre', e->>'path', e->>'url'
  from jsonb_array_elements(evidencias) e;

  if gate then
    update colaboradores set
      soat_vence = coalesce(v_soat_v, soat_vence),
      tecnomecanica_vence = coalesce(v_tecno_v, tecnomecanica_vence),
      licencia_vence = coalesce(v_lic_v, licencia_vence),
      soat_url = coalesce(v_soat_u, soat_url),
      tecnomecanica_url = coalesce(v_tecno_u, tecnomecanica_url),
      licencia_url = coalesce(v_lic_u, licencia_url),
      marca_vehiculo = coalesce(nullif(btrim(coalesce(respuestas->>'DOC_MARCA_VEHICULO','')), ''), marca_vehiculo),
      cilindraje = coalesce(nullif(btrim(coalesce(respuestas->>'DOC_CILINDRAJE','')), ''), cilindraje),
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;
    insert into historial (tipo, cedula, detalle) values ('DOCUMENTOS', ncedula, 'Actualizados desde registro');
  end if;

  for f in
    select frm.id, frm.nombre
    from formularios frm
    join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
    where frm.activo and pf.proyecto=coalesce(c.proyecto,'')
    order by frm.orden
  loop
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
    'idRegistro', rid,
    'estado', case when alertas_doc <> '' then 'CON_ALERTA' else 'OK' end,
    'alertas', case when alertas_doc <> '' then jsonb_build_array(alertas_doc) else '[]'::jsonb end,
    'diferido', es_diferido,
    'estadoDiario', estado, 'completo', completo, 'archivoDiaUrl', '#',
    'comprobante', jsonb_build_object(
      'nombre', c.nombre, 'cedula', ncedula, 'placa_moto', coalesce(c.placa_moto,''),
      'proyecto', coalesce(c.proyecto,''), 'ciudad', coalesce(c.ciudad,''),
      'fecha', to_char(hoy,'YYYY-MM-DD'), 'completo', completo, 'registros', regs)
  );
end;
$$;

-- ------------------------------------------------------------
--  El exportable muestra si el registro se hizo sin conexión
-- ------------------------------------------------------------
create or replace function api_exportable(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fid text := payload->>'formulario';
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  perfil text := nullif(upper(btrim(coalesce(payload->>'perfil',''))), '');
  preguntas jsonb;
  filas jsonb := '[]'::jsonb;
  rec record;
begin
  if fid is null or fid = '' then raise exception 'Selecciona un formulario.'; end if;
  if fi is null or ff is null or fi > ff then raise exception 'Rango de fechas invalido.'; end if;
  if perfil is not null and perfil not in ('MOTO','VEHICULO') then
    raise exception 'Perfil no valido: %', perfil;
  end if;

  preguntas := coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'pregunta', pregunta) order by orden)
      from preguntas
     where formulario_id = fid and activo
       and (perfil is null or aplica_a is null or aplica_a = perfil)), '[]'::jsonb);

  for rec in
    select r.id, r.fecha, r.hora, r.cedula, r.nombre, r.cargo, r.proyecto_id, r.proyecto,
           r.ciudad, r.placa_moto, r.tipo_vehiculo, r.estado, r.alertas,
           r.diferido, r.creado_en,
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
      and (perfil is null or perfil_cargo(r.cargo) = perfil)
    order by r.fecha, r.hora
  loop
    filas := filas || jsonb_build_array(jsonb_build_object(
      'fecha', to_char(rec.fecha,'YYYY-MM-DD'), 'hora', to_char(rec.hora,'HH24:MI:SS'),
      'id_registro', rec.id, 'cedula', rec.cedula, 'nombre', coalesce(rec.nombre,''),
      'cargo', coalesce(rec.cargo,''), 'tipo', perfil_cargo(rec.cargo),
      'proyecto_id', coalesce(rec.proyecto_id,''),
      'proyecto', coalesce(rec.proyecto,''), 'ciudad', coalesce(rec.ciudad,''),
      'placa_moto', coalesce(rec.placa_moto,''), 'tipo_vehiculo', coalesce(rec.tipo_vehiculo,''),
      'estado', coalesce(rec.estado,''),
      'sin_conexion', case when rec.diferido then 'SI' else 'NO' end,
      'enviado_en', to_char(rec.creado_en at time zone 'America/Bogota','YYYY-MM-DD HH24:MI'),
      'estado_cumplimiento', case when coalesce(rec.alertas,'') <> '' then 'REQUIERE_GESTION' else 'CUMPLE' end,
      'alertas_documentales', coalesce(rec.alertas,''),
      'respuestas', rec.resp, 'evidencias', rec.evid));
  end loop;

  return jsonb_build_object('formulario', fid, 'perfil', coalesce(perfil,''),
    'preguntas', preguntas, 'filas', filas, 'total', jsonb_array_length(filas));
end;
$$;

-- ------------------------------------------------------------
--  Comprobación
-- ------------------------------------------------------------
-- select count(*) filter (where diferido) as sin_conexion, count(*) as total
--   from registros where fecha >= current_date - 30;
