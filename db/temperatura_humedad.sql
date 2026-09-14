-- ============================================================
--  REGISTRO CONTROL DE TEMPERATURA Y HUMEDAD
--  ------------------------------------------------------------
--  Se mide dos veces al dia, manana y tarde. La base tiene la regla
--  de UN registro por persona, por formulario, por dia, asi que en
--  vez de relajar esa regla -que protege a los otros formularios-
--  se crean DOS formularios: manana y tarde.
--
--  Sale mejor por todos lados: la regla del dia sigue intacta, el
--  dashboard cuenta 2 esperadas sin tocar nada, el mensajero ve
--  claramente cual de las dos le falta, y el cumplimiento muestra
--  por separado si la de la tarde se esta quedando.
--
--  Que NO se pregunta, porque la plataforma ya lo tiene de la
--  matriz: consentimiento, nombres, cedula, cargo, ciudad y placa.
--  Tampoco la fecha ni la hora: el sistema las sella solas. Y no se
--  pregunta AM/PM, que es lo mismo que el formulario elegido.
--
--  Correr DESPUES de db/FIX_exportable_lento.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Una respuesta puede marcar el registro para gestion
--  ------------------------------------------------------------
--  Hoy 'respuesta_alerta' solo alimenta el "Top de fallas" del
--  dashboard: un "No cumple" del preoperacional no deja el registro
--  marcado. Esta columna permite escalarlo, pregunta por pregunta,
--  sin cambiarle el comportamiento a los formularios que ya existen.
-- ------------------------------------------------------------
alter table preguntas
  add column if not exists alerta_en_registro boolean not null default false;

-- ------------------------------------------------------------
--  1.b) No todo formulario exige los papeles del vehiculo
--  ------------------------------------------------------------
--  Al guardar CUALQUIER registro se exige hoy tener cargados SOAT,
--  tecnomecanica y licencia, y se revisan sus vencimientos. Eso vale
--  para quien anda en moto, pero no para quien mide la temperatura
--  de una bodega: sin esta marca, el formulario nuevo seria
--  imposible de enviar ("Falta adjuntar el SOAT") y ademas saldria
--  siempre con alerta de documentos.
-- ------------------------------------------------------------
alter table formularios
  add column if not exists exige_documentos boolean not null default true;


-- ------------------------------------------------------------
--  2) Al guardar, una respuesta marcada deja el registro en gestion
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
--  3) El exportable no saca columnas de las etiquetas informativas
-- ------------------------------------------------------------
create or replace function api_exportable(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fid text := payload->>'formulario';
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  proy_nom text;
  enc_jef text := btrim(coalesce(payload->>'jefatura',''));
  enc_lid text := btrim(coalesce(payload->>'lider',''));
  enc_coo text := btrim(coalesce(payload->>'coordinador',''));
  enc_hay boolean := (btrim(coalesce(payload->>'jefatura','')) <> ''
                   or btrim(coalesce(payload->>'lider','')) <> ''
                   or btrim(coalesce(payload->>'coordinador','')) <> '');
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  perfil text := nullif(upper(btrim(coalesce(payload->>'perfil',''))), '');
  preguntas jsonb;
  filas jsonb;
  n int;
  tope int := 30000;
begin
  if fid is null or fid = '' then raise exception 'Selecciona un formulario.'; end if;
  if fi is null or ff is null or fi > ff then raise exception 'Rango de fechas invalido.'; end if;
  if perfil is not null and perfil not in ('MOTO','VEHICULO') then
    raise exception 'Perfil no valido: %', perfil;
  end if;

  -- El nombre del proyecto se resuelve una vez, no en cada fila.
  if filtro_proy <> '' then
    proy_nom := coalesce(nombre_proyecto(filtro_proy), filtro_proy);
  end if;

  preguntas := coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'pregunta', pregunta) order by orden)
      from preguntas
     where formulario_id = fid and activo
       -- Una etiqueta informativa no se responde: no es una columna del CSV.
       and tipo_respuesta <> 'info'
       and (perfil is null or aplica_a is null or aplica_a = perfil)), '[]'::jsonb);

  -- ----------------------------------------------------------
  -- 1) Los registros del rango, filtrados una sola vez.
  -- ----------------------------------------------------------
  drop table if exists pg_temp.tmp_exp;
  create temp table tmp_exp on commit drop as
  select r.id, r.fecha, r.hora, r.cedula,
         regexp_replace(r.cedula,'\D','','g') as ced_norm,
         r.nombre, r.cargo, r.proyecto_id, r.proyecto, r.ciudad,
         r.placa_moto, r.tipo_vehiculo, r.estado, r.alertas,
         r.diferido, r.creado_en
    from registros r
   where r.formulario_id = fid
     and r.fecha between fi and ff
     and coalesce(r.estado,'') <> 'ANULADO'
     and (filtro_proy = '' or r.proyecto = proy_nom)
     and (ncedula = '' or regexp_replace(r.cedula,'\D','','g') = ncedula)
     and (perfil is null or perfil_cargo(r.cargo) = perfil);

  -- El filtro de encargado se resuelve contra la matriz de una vez,
  -- no llamando a una funcion por cada registro.
  if enc_hay then
    delete from tmp_exp t
     where not exists (
       select 1 from colaboradores c
        where regexp_replace(c.cedula,'\D','','g') = t.ced_norm
          and (enc_jef = '' or sin_tildes(btrim(coalesce(c.enc_jefatura,'')))    = sin_tildes(enc_jef))
          and (enc_lid = '' or sin_tildes(btrim(coalesce(c.enc_lider,'')))       = sin_tildes(enc_lid))
          and (enc_coo = '' or sin_tildes(btrim(coalesce(c.enc_coordinador,''))) = sin_tildes(enc_coo)));
  end if;

  create index on tmp_exp (id);
  create index on tmp_exp (ced_norm);
  analyze tmp_exp;

  select count(*) into n from tmp_exp;

  -- Un archivo mas grande que esto no lo abre Excel comodo ni lo
  -- aguanta el navegador. Mejor decirlo claro que morir en el intento.
  if n > tope then
    raise exception 'La descarga trae % registros y el limite es %. Acorta el rango de fechas o filtra por proyecto o encargado.', n, tope;
  end if;

  -- ----------------------------------------------------------
  -- 2) Todo el archivo en una sola consulta.
  -- ----------------------------------------------------------
  filas := coalesce((
    select jsonb_agg(jsonb_build_object(
        'fecha', to_char(t.fecha,'YYYY-MM-DD'),
        'hora', to_char(t.hora,'HH24:MI:SS'),
        'id_registro', t.id,
        'cedula', t.cedula,
        'nombre', coalesce(t.nombre,''),
        'cargo', coalesce(t.cargo,''),
        'tipo', perfil_cargo(t.cargo),
        'proyecto_id', coalesce(t.proyecto_id,''),
        'proyecto', coalesce(t.proyecto,''),
        'ciudad', coalesce(t.ciudad,''),
        'jefatura', coalesce(enc.enc_jefatura,''),
        'lider', coalesce(enc.enc_lider,''),
        'coordinador', coalesce(enc.enc_coordinador,''),
        'frente', coalesce(enc.frente,''),
        'placa_moto', coalesce(t.placa_moto,''),
        'tipo_vehiculo', coalesce(t.tipo_vehiculo,''),
        'estado', coalesce(t.estado,''),
        'sin_conexion', case when t.diferido then 'SI' else 'NO' end,
        'enviado_en', to_char(t.creado_en at time zone 'America/Bogota','YYYY-MM-DD HH24:MI'),
        'estado_cumplimiento', case when coalesce(t.alertas,'') <> '' then 'REQUIERE_GESTION' else 'CUMPLE' end,
        'alertas_documentales', coalesce(t.alertas,''),
        'respuestas', coalesce(rp.resp, '{}'::jsonb),
        'evidencias', coalesce(ev.evid, '{}'::jsonb))
      order by t.fecha, t.hora)
    from tmp_exp t
    left join lateral (
      select c2.enc_jefatura, c2.enc_lider, c2.enc_coordinador, c2.frente
        from colaboradores c2
       where regexp_replace(c2.cedula,'\D','','g') = t.ced_norm
       limit 1) enc on true
    -- Las respuestas de TODOS los registros, agrupadas de una vez.
    left join (
      select rr.registro_id,
             jsonb_object_agg(rr.pregunta_id, rr.valor) as resp
        from respuestas rr
        join tmp_exp t2 on t2.id = rr.registro_id
       where rr.pregunta_id is not null
       group by rr.registro_id) rp on rp.registro_id = t.id
    -- Igual las evidencias. El "order by" deja de ultima la mas
    -- reciente, que es la que queda cuando la llave se repite.
    left join (
      select ee.registro_id,
             jsonb_object_agg(ee.pregunta_id,
                              coalesce(nullif(ee.storage_path,''), ee.url)
                              order by ee.subido_en) as evid
        from evidencias ee
        join tmp_exp t3 on t3.id = ee.registro_id
       where ee.pregunta_id is not null
         and (coalesce(ee.storage_path,'') <> '' or coalesce(ee.url,'') <> '')
       group by ee.registro_id) ev on ev.registro_id = t.id
  ), '[]'::jsonb);

  return jsonb_build_object('formulario', fid, 'perfil', coalesce(perfil,''),
    'preguntas', preguntas, 'filas', filas, 'total', n);
end;
$fn$;


-- ------------------------------------------------------------
--  4) Los dos formularios
-- ------------------------------------------------------------

insert into formularios (id, nombre, descripcion, activo, orden, exige_documentos) values
  ('TEMP_HUM_AM', 'Temperatura y humedad · Mañana', 'Control de temperatura y humedad en bodega.', true, 3, false)
on conflict (id) do update
  set nombre = excluded.nombre,
      descripcion = excluded.descripcion,
      activo = true,
      orden = excluded.orden,
      -- No pide SOAT ni tecnomecanica: no se mide sobre un vehiculo.
      exige_documentos = false;

insert into formularios (id, nombre, descripcion, activo, orden, exige_documentos) values
  ('TEMP_HUM_PM', 'Temperatura y humedad · Tarde', 'Control de temperatura y humedad en bodega.', true, 4, false)
on conflict (id) do update
  set nombre = excluded.nombre,
      descripcion = excluded.descripcion,
      activo = true,
      orden = excluded.orden,
      -- No pide SOAT ni tecnomecanica: no se mide sobre un vehiculo.
      exige_documentos = false;

-- ------------------------------------------------------------
--  5) Las preguntas de cada jornada
--  ------------------------------------------------------------
--  Se puede volver a correr: actualiza en vez de duplicar.
-- ------------------------------------------------------------

insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, ayuda, depende_de, depende_valor,
                       respuesta_alerta, alerta_en_registro, activo)
select v.id, v.formulario_id, v.seccion, v.pregunta, v.tipo, v.obligatorio, v.orden,
       v.ayuda, v.depende_de, v.depende_valor, v.respuesta_alerta, v.alerta, true
from (values
  ('THA_001', 'TEMP_HUM_AM', 'Criterio de aceptación', 'Antes de medir, tenga presente', 'info', false, 1, 'La temperatura debe mantenerse en 25 °C o menos, y la humedad relativa en 65 % o menos.
Si la medición se sostiene por fuera de ese rango durante 24 horas continuas, hay que reportar la desviación en este mismo formulario.', null, null, null, false),
  ('THA_002', 'TEMP_HUM_AM', 'Medición', 'Temperatura', 'numero', true, 2, 'Recuerde que son grados centígrados (°C).', null, null, null, false),
  ('THA_003', 'TEMP_HUM_AM', 'Medición', 'Humedad', 'numero', true, 3, 'Recuerde que el valor es porcentual (%).', null, null, null, false),
  ('THA_004', 'TEMP_HUM_AM', 'Medición', 'De acuerdo con el último registro de temperatura y humedad que usted realizó, ¿se evidencia una condición sostenida durante 24 horas continuas con temperatura superior a 25 °C y/o humedad relativa mayor al 65 %?', 'si_no', true, 4, null, null, null, 'SI', true),
  ('THA_005', 'TEMP_HUM_AM', 'Reporte de desviaciones', 'Qué debe hacer ahora', 'info', false, 5, 'Notifique al Coordinador HSEQ y envíe la notificación al número +57 310 719 6685.
En la siguiente pregunta adjunte el soporte fotográfico correspondiente.', 'THA_004', 'SI', null, false),
  ('THA_006', 'TEMP_HUM_AM', 'Reporte de desviaciones', 'Soporte fotográfico de la desviación', 'archivo', true, 6, 'Foto de la medición o del registro del equipo.', 'THA_004', 'SI', null, false),
  ('THA_007', 'TEMP_HUM_AM', 'Tratamiento de datos', 'Tratamiento de datos personales', 'info', false, 7, 'De acuerdo con la Ley 1581 de 2012 y sus decretos reglamentarios, al registrar autoriza de manera libre, expresa e informada a Quick Help el tratamiento de sus datos personales con fines de gestión de capacitación, verificación del aprendizaje y cumplimiento del Sistema de Gestión de Seguridad y Salud en el Trabajo (SG-SST).', null, null, null, false)
) as v(id, formulario_id, seccion, pregunta, tipo, obligatorio, orden, ayuda,
       depende_de, depende_valor, respuesta_alerta, alerta)
on conflict (id) do update
  set formulario_id = excluded.formulario_id,
      seccion = excluded.seccion,
      pregunta = excluded.pregunta,
      tipo_respuesta = excluded.tipo_respuesta,
      obligatorio = excluded.obligatorio,
      orden = excluded.orden,
      ayuda = excluded.ayuda,
      depende_de = excluded.depende_de,
      depende_valor = excluded.depende_valor,
      respuesta_alerta = excluded.respuesta_alerta,
      alerta_en_registro = excluded.alerta_en_registro,
      activo = true;

insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, ayuda, depende_de, depende_valor,
                       respuesta_alerta, alerta_en_registro, activo)
select v.id, v.formulario_id, v.seccion, v.pregunta, v.tipo, v.obligatorio, v.orden,
       v.ayuda, v.depende_de, v.depende_valor, v.respuesta_alerta, v.alerta, true
from (values
  ('THP_001', 'TEMP_HUM_PM', 'Criterio de aceptación', 'Antes de medir, tenga presente', 'info', false, 1, 'La temperatura debe mantenerse en 25 °C o menos, y la humedad relativa en 65 % o menos.
Si la medición se sostiene por fuera de ese rango durante 24 horas continuas, hay que reportar la desviación en este mismo formulario.', null, null, null, false),
  ('THP_002', 'TEMP_HUM_PM', 'Medición', 'Temperatura', 'numero', true, 2, 'Recuerde que son grados centígrados (°C).', null, null, null, false),
  ('THP_003', 'TEMP_HUM_PM', 'Medición', 'Humedad', 'numero', true, 3, 'Recuerde que el valor es porcentual (%).', null, null, null, false),
  ('THP_004', 'TEMP_HUM_PM', 'Medición', 'De acuerdo con el último registro de temperatura y humedad que usted realizó, ¿se evidencia una condición sostenida durante 24 horas continuas con temperatura superior a 25 °C y/o humedad relativa mayor al 65 %?', 'si_no', true, 4, null, null, null, 'SI', true),
  ('THP_005', 'TEMP_HUM_PM', 'Reporte de desviaciones', 'Qué debe hacer ahora', 'info', false, 5, 'Notifique al Coordinador HSEQ y envíe la notificación al número +57 310 719 6685.
En la siguiente pregunta adjunte el soporte fotográfico correspondiente.', 'THP_004', 'SI', null, false),
  ('THP_006', 'TEMP_HUM_PM', 'Reporte de desviaciones', 'Soporte fotográfico de la desviación', 'archivo', true, 6, 'Foto de la medición o del registro del equipo.', 'THP_004', 'SI', null, false),
  ('THP_007', 'TEMP_HUM_PM', 'Tratamiento de datos', 'Tratamiento de datos personales', 'info', false, 7, 'De acuerdo con la Ley 1581 de 2012 y sus decretos reglamentarios, al registrar autoriza de manera libre, expresa e informada a Quick Help el tratamiento de sus datos personales con fines de gestión de capacitación, verificación del aprendizaje y cumplimiento del Sistema de Gestión de Seguridad y Salud en el Trabajo (SG-SST).', null, null, null, false)
) as v(id, formulario_id, seccion, pregunta, tipo, obligatorio, orden, ayuda,
       depende_de, depende_valor, respuesta_alerta, alerta)
on conflict (id) do update
  set formulario_id = excluded.formulario_id,
      seccion = excluded.seccion,
      pregunta = excluded.pregunta,
      tipo_respuesta = excluded.tipo_respuesta,
      obligatorio = excluded.obligatorio,
      orden = excluded.orden,
      ayuda = excluded.ayuda,
      depende_de = excluded.depende_de,
      depende_valor = excluded.depende_valor,
      respuesta_alerta = excluded.respuesta_alerta,
      alerta_en_registro = excluded.alerta_en_registro,
      activo = true;

-- ------------------------------------------------------------
--  6) Habilitarlo donde corresponda
--  ------------------------------------------------------------
--  No se habilita solo en ningun proyecto: eso se hace desde
--  Administracion -> Formularios por proyecto, marcando las dos
--  jornadas en las bodegas que lo deban diligenciar.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Los dos formularios quedaron.
select id, nombre, orden, activo from formularios order by orden;

-- b) Las preguntas de cada jornada, en orden.
select formulario_id, orden, id, tipo_respuesta, obligatorio,
       case when alerta_en_registro then 'ESCALA' else '' end as marca,
       left(pregunta, 60) as pregunta
  from preguntas
 where formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM')
 order by formulario_id, orden;

-- c) El exportable ya no saca columnas de las etiquetas informativas.
select 'api_exportable' as funcion,
       case when prosrc like '%tipo_respuesta <> ''info''%'
            then 'ACTUALIZADA' else 'SIN ACTUALIZAR' end as estado
  from pg_proc where proname = 'api_exportable';
