-- ============================================================
--  El tope de las fechas de documentos ahora se configura
--  ------------------------------------------------------------
--  SINTOMA: "La fecha de TECNOMECANICA (2029-05-28) no parece
--  valida" a un mensajero que escribio la fecha correcta.
--
--  CAUSA: la fecha no podia estar a mas de 2 anios. Ese tope
--  sirve para atajar errores de digitacion -2092 en vez de
--  2029- pero asume que el vehiculo YA tiene certificado. Uno
--  nuevo todavia no lo tiene: lo que se registra es cuando le
--  toca la primera revision, y eso cae mas lejos.
--
--  ARREGLO: el tope de cada documento pasa a la tabla config.
--  Se puede cambiar cuando haga falta, sin tocar codigo:
--
--    update config set valor = '8'
--     where clave = 'LIMITE_ANIOS_TECNOMECANICA';
--
--  Valores que quedan puestos: SOAT 2 anios, TECNOMECANICA 6,
--  LICENCIA 20. Si ya existen, NO se pisan.
--
--  La app del celular deja de repetir esta validacion: la regla
--  queda en un solo lugar. Antes estaba en los dos y por eso
--  habia que cambiarla dos veces.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Los topes, editables
-- ------------------------------------------------------------
insert into config (clave, valor) values
  ('LIMITE_ANIOS_SOAT', '2'),
  ('LIMITE_ANIOS_TECNOMECANICA', '6'),
  ('LIMITE_ANIOS_LICENCIA', '20')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
--  2) La revision, en un solo lugar
--  ------------------------------------------------------------
--  Hacia atras siempre son 10 anios: una fecha mas vieja que eso
--  no es un documento vencido, es un error de digitacion.
-- ------------------------------------------------------------
create or replace function revisar_vencimiento(doc text, f date, hoy date)
returns void language plpgsql stable set search_path = public as $rv$
declare
  tope int := coalesce(
    (select nullif(regexp_replace(coalesce(valor,''), '\D', '', 'g'), '')::int
       from config where clave = 'LIMITE_ANIOS_' || doc), 6);
  minimo date := (hoy - interval '10 years')::date;
  maximo date := (hoy + (tope || ' years')::interval)::date;
begin
  if f is null then return; end if;
  if f < minimo or f > maximo then
    raise exception 'La fecha de % (%) esta fuera del rango permitido: entre % y %. Si la fecha del documento es esa, pidele a HSEQ que amplie el limite.',
      doc, to_char(f, 'YYYY-MM-DD'), to_char(minimo, 'YYYY-MM-DD'), to_char(maximo, 'YYYY-MM-DD');
  end if;
end;
$rv$;

revoke all on function revisar_vencimiento(text, date, date) from public, anon;

-- ------------------------------------------------------------
--  3) Guardar el registro usa esos topes
-- ------------------------------------------------------------
create or replace function api_guardar_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  fid text := payload->>'id_formulario';
  respuestas jsonb := coalesce(payload->'respuestas', '{}'::jsonb);
  evidencias jsonb := coalesce(payload->'evidencias', '[]'::jsonb);
  c colaboradores%rowtype;
  perfil text;
  proy text;
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
  alertas_resp text := '';
  exige_docs boolean := true;
  estado jsonb := '{}'::jsonb;
  regs jsonb := '[]'::jsonb;
  completo boolean := true;
begin
  if ncedula = '' or fid is null then raise exception 'Datos incompletos.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if not c.activo then raise exception 'La persona no esta activa para registro.'; end if;
  perfil := perfil_cargo(c.cargo);
  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');

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
    es_diferido := abs(extract(epoch from (now() - local_ts))) > 300;
  end if;

  if not exists (
    select 1
    from proyectos_formularios pf
    join formularios frm on frm.id=pf.formulario_id and frm.activo
    where pf.proyecto = proy and pf.formulario_id = fid and pf.activo
  ) then
    raise exception 'Este formulario no esta habilitado para tu proyecto.';
  end if;

  if exists (select 1 from registros
             where regexp_replace(cedula,'\D','','g') = ncedula
               and formulario_id = fid and fecha = hoy) then
    raise exception 'Ya realizaste este registro hoy. Solo se permite un registro diario por tipo.';
  end if;

  select coalesce(exige_documentos, true) into exige_docs
    from formularios where id = fid;

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
    -- El tope de cada documento vive en la tabla config, no aqui. Un
    -- vehiculo nuevo puede tener la primera tecnomecanica a varios anios,
    -- y ese numero lo ajusta HSEQ sin tocar codigo.
    perform revisar_vencimiento('SOAT', v_soat_v, hoy);
    perform revisar_vencimiento('TECNOMECANICA', v_tecno_v, hoy);
    perform revisar_vencimiento('LICENCIA', v_lic_v, hoy);
  end if;

  -- Quien mide la temperatura de una bodega no tiene moto: exigirle
  -- los papeles del vehiculo dejaria el formulario imposible de enviar.
  if exige_docs then
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
  end if;   -- exige_docs

  if es_diferido then
    alertas_doc := alertas_doc || 'Registro diligenciado sin conexion el ' ||
      to_char(local_ts at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI') || ' | ';
  end if;
  if coalesce(btrim(c.proyecto_operativo),'') <> '' then
    alertas_doc := alertas_doc || 'Trasladado desde ' || coalesce(c.proyecto,'(sin proyecto)') || ' | ';
  end if;
  alertas_doc := rtrim(alertas_doc, ' |');

  -- Respuestas que la configuracion pide escalar. Solo las preguntas
  -- con alerta_en_registro, no todas las que tienen respuesta_alerta:
  -- asi el preoperacional y limpieza siguen comportandose igual.
  select coalesce(string_agg(pa.pregunta || ': ' || coalesce(respuestas->>pa.id,''), ' | '), '')
    into alertas_resp
    from preguntas pa
   where pa.formulario_id = fid
     and pa.activo
     and pa.alerta_en_registro
     and nullif(btrim(coalesce(pa.respuesta_alerta,'')),'') is not null
     and upper(btrim(coalesce(respuestas->>pa.id,''))) = upper(btrim(pa.respuesta_alerta));

  if alertas_resp <> '' then
    alertas_doc := case when alertas_doc = '' then alertas_resp
                        else alertas_doc || ' | ' || alertas_resp end;
  end if;

  insert into registros (cedula, formulario_id, fecha, hora, estado, alertas,
    nombre, cargo, proyecto_id, proyecto, ciudad, placa_moto, tipo_vehiculo,
    capturado_en, diferido)
  values (ncedula, fid, hoy, ahora,
    case when alertas_doc <> '' then 'CON_ALERTA' else 'OK' end,
    nullif(alertas_doc, ''),
    c.nombre, c.cargo, c.proyecto_id, proy, c.ciudad, c.placa_moto,
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
    where frm.activo and pf.proyecto = proy
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
      'proyecto', proy, 'ciudad', coalesce(c.ciudad,''),
      'fecha', to_char(hoy,'YYYY-MM-DD'), 'completo', completo, 'registros', regs)
  );
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Los topes que quedaron. Aqui es donde se cambian.
select clave, valor as anios from config
 where clave like 'LIMITE_ANIOS_%' order by clave;

-- b) La funcion ya los consulta en vez de tenerlos escritos.
select case when prosrc like '%revisar_vencimiento%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_guardar_registro';

-- c) Prueba en seco con la fecha que fallo hoy: no debe dar error.
select revisar_vencimiento('TECNOMECANICA', date '2029-05-28', current_date);
