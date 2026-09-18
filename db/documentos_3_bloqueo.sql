-- ============================================================
--  DOCUMENTOS - Etapa 3: se pide solo el pendiente, y bloquea
--  ------------------------------------------------------------
--  Aqui cambia el comportamiento del preoperacional:
--
--   - Se acaba la pregunta "primera vez o renovacion". El sistema
--     ya sabe que le falta a cada quien.
--   - Se le pide UNICAMENTE el documento pendiente: el que falta,
--     el vencido o el rechazado. Los que estan al dia ni se
--     mencionan.
--   - Si el documento lleva vencido mas dias que la gracia, o
--     nunca se cargo, o esta rechazado, NO puede registrar hasta
--     resolverlo.
--   - Al volver a adjuntar un documento rechazado, el rechazo se
--     levanta solo.
--
--  Requiere db/documentos_1_estado.sql y db/documentos_2_rechazo.sql.
--
--  ANTES DE CORRERLO: mide el impacto. La ultima consulta de la
--  etapa 1 dice a cuanta gente le va a bloquear el registro.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La pantalla necesita saber que pedir
--  ------------------------------------------------------------
--  api_cargar_formulario ya recibe la cedula (la usa para
--  precargar respuestas). Se le agrega el estado de documentos
--  para que la pantalla arme el bloque con lo que falta y nada
--  mas. Lo demas de la respuesta queda igual.
-- ------------------------------------------------------------
create or replace function api_cargar_formulario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fid text := payload->>'id_formulario';
  ced text := coalesce(payload->>'cedula', '');
  frm record;
  perfil text;
  preg jsonb; opc jsonb; prev jsonb;
  ncedula text := regexp_replace(ced, '\D', '', 'g');
begin
  select * into frm from formularios where id = fid and activo;
  if not found then raise exception 'Formulario no encontrado o inactivo.'; end if;

  -- El perfil sale del cargo: el preoperacional de moto y el de
  -- vehiculo son el mismo formulario con preguntas distintas.
  perfil := null;
  if ncedula <> '' then
    select perfil_cargo(c.cargo) into perfil from colaboradores c
     where regexp_replace(c.cedula, '\D', '', 'g') = ncedula limit 1;
  end if;

  preg := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id_pregunta', id, 'seccion', seccion, 'pregunta', pregunta,
      'tipo_respuesta', tipo_respuesta, 'obligatorio', case when obligatorio then 'SI' else 'NO' end,
      'orden', orden, 'grupo_opciones', grupo_opciones,
      'ayuda', ayuda, 'imagen_url', imagen_url, 'documento', documento,
      'depende_de', depende_de, 'depende_valor', depende_valor
    ) order by orden)
    from preguntas
    where formulario_id = fid and activo
      -- Sin cédula se entregan todas (vista de configuración).
      and (perfil is null or aplica_a is null or aplica_a = perfil)
  ), '[]'::jsonb);

  opc := coalesce((
    select jsonb_object_agg(grupo, arr) from (
      select grupo, jsonb_agg(valor order by orden) arr
      from opciones where activo group by grupo
    ) t
  ), '{}'::jsonb);

  prev := api_respuestas_previas(ced, fid);

  return jsonb_build_object(
    'formulario', jsonb_build_object(
      'id_formulario', frm.id, 'nombre_formulario', frm.nombre,
      'descripcion', frm.descripcion, 'activo', case when frm.activo then 'SI' else 'NO' end),
    'perfil', coalesce(perfil, ''),
    'preguntas', preg,
    'opciones', opc,
    'previas', prev->'valores',
    'previasFecha', coalesce(prev->>'fecha', ''),
    -- Que documentos hay que pedirle, si es que hay alguno.
    'documentosEstado', case when ncedula = '' then '{}'::jsonb
                             else estado_documentos(ncedula) end
  );
end;
$fn$;

-- ------------------------------------------------------------
--  2) Guardar: se exige documento por documento
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
  -- Estado por documento, que es quien manda ahora.
  est_docs jsonb;
  d record;
  faltan text := '';
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

  -- ----------------------------------------------------------
  --  Documentos, uno por uno
  --  --------------------------------------------------------
  --  Ya no hay una pregunta que abra el bloque entero. Para cada
  --  documento se mira si viene en este registro; si no viene y
  --  ademas bloquea, no se guarda nada.
  -- ----------------------------------------------------------
  if exige_docs then
    est_docs := estado_documentos(ncedula);

    -- Lo que llego adjunto en este registro.
    select e->>'url' into v_soat_u  from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_SOAT' limit 1;
    select e->>'url' into v_tecno_u from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_TECNOMECANICA' limit 1;
    select e->>'url' into v_lic_u   from jsonb_array_elements(evidencias) e where e->>'id_pregunta' = 'DOC_LICENCIA_TRANSITO' limit 1;

    for d in select * from (values
        ('SOAT',          'DOC_SOAT',              v_soat_u),
        ('TECNOMECANICA', 'DOC_TECNOMECANICA',     v_tecno_u),
        ('LICENCIA',      'DOC_LICENCIA_TRANSITO', v_lic_u)
      ) as t(k, preg_id, url_nuevo) loop

      if coalesce(btrim(coalesce(d.url_nuevo,'')), '') <> '' then
        -- Viene adjunto: se exige tambien su fecha, y se valida.
        val := substring(btrim(coalesce(respuestas->>('DOC_FECHA_' || d.k), '')) from '\d{4}-\d{2}-\d{2}');
        if val is null then
          -- La pantalla manda la fecha con el id de la pregunta de la
          -- hoja; se busca tambien por ahi.
          select substring(btrim(coalesce(respuestas->>pq.id, '')) from '\d{4}-\d{2}-\d{2}')
            into val
            from preguntas pq
           where pq.formulario_id = fid and pq.activo
             and pq.tipo_respuesta = 'fecha'
             and doc_key(pq.pregunta, pq.tipo_respuesta, pq.documento) = d.k
           limit 1;
        end if;
        if val is null then
          raise exception 'Adjuntaste % pero falta su fecha de vencimiento.', d.k;
        end if;
        perform revisar_vencimiento(d.k, val::date, hoy);
        if d.k = 'SOAT' then v_soat_v := val::date;
        elsif d.k = 'TECNOMECANICA' then v_tecno_v := val::date;
        else v_lic_v := val::date; end if;

      elsif coalesce((est_docs->'documentos'->d.k->>'bloquea')::boolean, false) then
        -- No vino, y sin el no puede registrar. Se dice por que.
        faltan := faltan || d.k || ' ('
          || case est_docs->'documentos'->d.k->>'motivo_exige'
               when 'rechazado' then 'rechazado: '
                 || coalesce(nullif(est_docs->'documentos'->d.k->>'motivo',''), 'revisalo con HSEQ')
               when 'vencido'   then 'vencido el '
                 || coalesce(est_docs->'documentos'->d.k->>'fecha','')
               else 'sin cargar' end
          || '), ';
      else
        -- No vino y no bloquea: se conserva lo que ya estaba y, si
        -- esta vencido dentro de la gracia, queda el aviso.
        if d.k = 'SOAT' then v_soat_v := c.soat_vence;
        elsif d.k = 'TECNOMECANICA' then v_tecno_v := c.tecnomecanica_vence;
        else v_lic_v := c.licencia_vence; end if;
      end if;
    end loop;

    if faltan <> '' then
      raise exception 'No puedes registrar hasta actualizar: %. Adjuntalo en este mismo formulario.',
        btrim(faltan, ', ');
    end if;
  end if;

  -- Las fechas bloqueadas que la pantalla manda de vuelta se reflejan
  -- tal cual estan guardadas, para que el registro quede completo.
  for p in select id, pregunta, tipo_respuesta, documento from preguntas
           where formulario_id = fid and activo
             and (aplica_a is null or aplica_a = perfil) loop
    dk := doc_key(p.pregunta, p.tipo_respuesta, p.documento);
    if dk is null then continue; end if;
    val := to_char(case dk when 'SOAT' then coalesce(v_soat_v, c.soat_vence)
                           when 'TECNOMECANICA' then coalesce(v_tecno_v, c.tecnomecanica_vence)
                           else coalesce(v_lic_v, c.licencia_vence) end, 'YYYY-MM-DD');
    respuestas := jsonb_set(respuestas, array[p.id], to_jsonb(coalesce(val, '')));
  end loop;

  if exige_docs then
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
  end if;

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

  -- Se guarda solo lo que llego en ESTE registro. Adjuntar un documento
  -- levanta su rechazo: ya hay algo nuevo que revisar.
  update colaboradores set
    soat_vence = coalesce(v_soat_v, soat_vence),
    tecnomecanica_vence = coalesce(v_tecno_v, tecnomecanica_vence),
    licencia_vence = coalesce(v_lic_v, licencia_vence),
    soat_url = coalesce(nullif(btrim(coalesce(v_soat_u,'')),''), soat_url),
    tecnomecanica_url = coalesce(nullif(btrim(coalesce(v_tecno_u,'')),''), tecnomecanica_url),
    licencia_url = coalesce(nullif(btrim(coalesce(v_lic_u,'')),''), licencia_url),
    soat_rechazado_en = case when coalesce(btrim(coalesce(v_soat_u,'')),'') <> '' then null else soat_rechazado_en end,
    soat_rechazo_motivo = case when coalesce(btrim(coalesce(v_soat_u,'')),'') <> '' then null else soat_rechazo_motivo end,
    tecnomecanica_rechazado_en = case when coalesce(btrim(coalesce(v_tecno_u,'')),'') <> '' then null else tecnomecanica_rechazado_en end,
    tecnomecanica_rechazo_motivo = case when coalesce(btrim(coalesce(v_tecno_u,'')),'') <> '' then null else tecnomecanica_rechazo_motivo end,
    licencia_rechazado_en = case when coalesce(btrim(coalesce(v_lic_u,'')),'') <> '' then null else licencia_rechazado_en end,
    licencia_rechazo_motivo = case when coalesce(btrim(coalesce(v_lic_u,'')),'') <> '' then null else licencia_rechazo_motivo end,
    marca_vehiculo = coalesce(nullif(btrim(coalesce(respuestas->>'DOC_MARCA_VEHICULO','')), ''), marca_vehiculo),
    cilindraje = coalesce(nullif(btrim(coalesce(respuestas->>'DOC_CILINDRAJE','')), ''), cilindraje),
    actualizado_en = now()
  where regexp_replace(cedula,'\D','','g') = ncedula;

  if coalesce(btrim(coalesce(v_soat_u,'')),'') <> ''
     or coalesce(btrim(coalesce(v_tecno_u,'')),'') <> ''
     or coalesce(btrim(coalesce(v_lic_u,'')),'') <> '' then
    insert into historial (tipo, cedula, detalle)
    values ('DOCUMENTOS', ncedula, 'Actualizados desde registro');
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
-- a) Guardar ya consulta el estado por documento.
select case when prosrc like '%estado_documentos%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_guardar_registro';

-- b) Cargar el formulario ya dice que documentos pedir.
select case when prosrc like '%documentosEstado%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_cargar_formulario';

-- c) A quien le va a bloquear el registro desde ahora.
select c.linea, count(*) as bloqueados
  from colaboradores c
 where c.activo and (estado_documentos(c.cedula)->>'bloquea')::boolean
 group by c.linea
 order by c.linea;
