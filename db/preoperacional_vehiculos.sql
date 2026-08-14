-- ============================================================
--  Gestión HSEQ Motos — Un solo preoperacional para moto y vehículo
--  ------------------------------------------------------------
--  El formulario sigue siendo uno (PREOPERACIONAL). Cada pregunta
--  queda marcada con a quién le aplica:
--     aplica_a = null        → la responden todos
--     aplica_a = 'MOTO'      → solo QUICKER - MENSAJERO
--     aplica_a = 'VEHICULO'  → solo QUICKER - CONDUCTOR
--
--  El perfil sale del cargo del colaborador. Al digitar la cédula,
--  el sistema arma el formulario que le corresponde.
--
--  Ejecutar DESPUÉS de: schema.sql, functions.sql, functions_write.sql,
--  functions_coord2.sql, precarga_respuestas.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) A quién le aplica cada pregunta
-- ------------------------------------------------------------
alter table preguntas
  add column if not exists aplica_a text,
  add column if not exists no_precargar boolean not null default false;

comment on column preguntas.aplica_a is
  'null = todos; MOTO = solo mensajeros; VEHICULO = solo conductores.';

-- ------------------------------------------------------------
-- 2) Perfil según el cargo. Se reconoce por la palabra CONDUCTOR,
--    sin importar tildes, mayúsculas ni cómo esté separado.
-- ------------------------------------------------------------
create or replace function perfil_cargo(cargo text)
returns text language sql immutable as $$
  select case
    when sin_tildes(coalesce(cargo, '')) like '%CONDUCTOR%' then 'VEHICULO'
    else 'MOTO'
  end;
$$;

-- ------------------------------------------------------------
-- 3) Listas de opciones para el conductor
-- ------------------------------------------------------------
-- La tabla no tiene índice único, así que se evita el duplicado a mano
-- (permite volver a ejecutar el script sin repetir opciones).
insert into opciones (grupo, valor, orden, activo)
select v.grupo, v.valor, v.orden, true
  from (values
    ('cumple_no_cumple', 'Cumple',    1),
    ('cumple_no_cumple', 'No cumple', 2),
    ('categoria_licencia_veh', 'C1', 1),
    ('categoria_licencia_veh', 'C2', 2),
    ('categoria_licencia_veh', 'C3', 3)
  ) as v(grupo, valor, orden)
 where not exists (
   select 1 from opciones o where o.grupo = v.grupo and o.valor = v.valor
 );

-- ------------------------------------------------------------
-- 4) Las preguntas actuales que son propias de la moto
-- ------------------------------------------------------------
update preguntas set aplica_a = 'MOTO'
 where formulario_id = 'PREOPERACIONAL'
   and id in (
     'PRE_003',                        -- licencia A1 / A2
     'PRE_010',                        -- labrado mínimo 1 mm
     'PRE_011',                        -- nipple y rin
     'PRE_020',                        -- visor del casco
     'PRE_021', 'PRE_022',             -- espejos (dos preguntas)
     'PRE_023', 'PRE_024',             -- freno delantero y trasero
     'PRE_025', 'PRE_026', 'PRE_027',  -- niveles
     'PRE_028',                        -- fugas
     'PRE_029', 'PRE_030', 'PRE_031', 'PRE_032',   -- cadena
     'PRE_033', 'PRE_034', 'PRE_035',  -- cascos
     'PRE_036'                         -- botas
   );

-- ------------------------------------------------------------
-- 5) Textos que hablaban solo de moto, ahora sirven para ambos
-- ------------------------------------------------------------
update preguntas set pregunta = 'Kilómetros recorridos'
 where id = 'PRE_004';

update preguntas set pregunta = '¿Hay alguna falla o anomalía que impida o comprometa la operación segura del vehículo?'
 where id = 'PRE_037';

update preguntas set pregunta = 'Observaciones adicionales y descripción de fallas encontradas'
 where id = 'PRE_038';

update preguntas set pregunta = '¿Has realizado algún tipo de mantenimiento preventivo o correctivo a tu vehículo?'
 where id = 'PRE_039';

-- ------------------------------------------------------------
-- 6) Las preguntas propias del vehículo
--    El orden se intercala con las de moto para que cada quien
--    vea su formulario en una secuencia lógica.
-- ------------------------------------------------------------
insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, grupo_opciones, aplica_a, activo) values
  ('VEH_001', 'PREOPERACIONAL', 'Seguridad', 'Categoría de la licencia de conducción',
   'desplegable', true, 3.1, 'categoria_licencia_veh', 'VEHICULO', true),
  ('VEH_002', 'PREOPERACIONAL', 'Seguridad', 'Modelo del vehículo',
   'texto', true, 3.2, null, 'VEHICULO', true),
  ('VEH_003', 'PREOPERACIONAL', 'Seguridad', 'Tipo de combustible',
   'texto', true, 3.3, null, 'VEHICULO', true),
  ('VEH_004', 'PREOPERACIONAL', 'Seguridad', 'Profundidad del labrado adecuada Min 1.6 mm',
   'desplegable', true, 10.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_005', 'PREOPERACIONAL', 'Seguridad', 'Tuercas y Rin',
   'desplegable', true, 11.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_006', 'PREOPERACIONAL', 'Seguridad', 'Luces Traseras',
   'desplegable', true, 18.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_007', 'PREOPERACIONAL', 'Seguridad', 'Parabrisas en buen estado',
   'desplegable', true, 19.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_008', 'PREOPERACIONAL', 'Seguridad', 'Limpia parabrisas operativos',
   'desplegable', true, 19.2, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_009', 'PREOPERACIONAL', 'Seguridad', 'Espejos retrovisores completos y ajustados',
   'desplegable', true, 22.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_010', 'PREOPERACIONAL', 'Seguridad', 'Freno de servicio operativo',
   'desplegable', true, 24.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_011', 'PREOPERACIONAL', 'Seguridad', 'Freno de emergencia / Freno de mano operativo',
   'desplegable', true, 24.2, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_012', 'PREOPERACIONAL', 'Seguridad', 'Pedal de freno en buen estado',
   'desplegable', true, 24.3, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_013', 'PREOPERACIONAL', 'Seguridad', 'Ausencia de ruidos anormales al frenar',
   'desplegable', true, 24.4, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_014', 'PREOPERACIONAL', 'Seguridad', 'Cinturón de seguridad en buen estado y ajustado correctamente',
   'desplegable', true, 33.1, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_015', 'PREOPERACIONAL', 'Seguridad', 'Apoya cabezas en buen estado',
   'desplegable', true, 33.2, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_016', 'PREOPERACIONAL', 'Seguridad', 'Air Bag',
   'desplegable', true, 33.3, 'cumple_no_cumple', 'VEHICULO', true),
  ('VEH_017', 'PREOPERACIONAL', 'Seguridad', 'Puertas con cierre y apertura adecuados',
   'desplegable', true, 33.4, 'cumple_no_cumple', 'VEHICULO', true)
on conflict (id) do update set
  pregunta = excluded.pregunta, tipo_respuesta = excluded.tipo_respuesta,
  obligatorio = excluded.obligatorio, orden = excluded.orden,
  grupo_opciones = excluded.grupo_opciones, aplica_a = excluded.aplica_a,
  seccion = excluded.seccion, activo = true;

-- El modelo y el combustible se responden a diario, pero llegan
-- precargados del último registro para no repetirlos cada mañana.
update preguntas set no_precargar = false where id in ('VEH_002', 'VEH_003');

-- ------------------------------------------------------------
-- 7) cargarFormulario entrega solo las preguntas del perfil
-- ------------------------------------------------------------
create or replace function api_cargar_formulario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fid text := payload->>'id_formulario';
  ced text := coalesce(payload->>'cedula', '');
  ncedula text := regexp_replace(ced, '\D', '', 'g');
  perfil text := null;
  frm record;
  preg jsonb;
  opc  jsonb;
  prev jsonb;
begin
  select * into frm from formularios where id = fid and activo;
  if not found then raise exception 'Formulario no encontrado o inactivo.'; end if;

  if ncedula <> '' then
    select perfil_cargo(cargo) into perfil
      from colaboradores
     where regexp_replace(cedula, '\D', '', 'g') = ncedula
     limit 1;
  end if;

  preg := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id_pregunta', id, 'pregunta', pregunta, 'tipo_respuesta', tipo_respuesta,
      'obligatorio', case when obligatorio then 'SI' else 'NO' end,
      'orden', orden, 'seccion', seccion, 'grupo_opciones', grupo_opciones,
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
    'previasFecha', coalesce(prev->>'fecha', '')
  );
end;
$$;

-- ------------------------------------------------------------
-- 8) Las respuestas previas también se limitan al perfil
-- ------------------------------------------------------------
create or replace function api_respuestas_previas(ced text, fid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(ced, ''), '\D', '', 'g');
  perfil text;
  ult record;
  mapa jsonb;
begin
  if ncedula = '' or coalesce(fid, '') = '' then
    return jsonb_build_object('valores', '{}'::jsonb);
  end if;

  select perfil_cargo(cargo) into perfil
    from colaboradores where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;

  select id, fecha into ult
  from registros
  where regexp_replace(cedula, '\D', '', 'g') = ncedula
    and formulario_id = fid
  order by fecha desc, creado_en desc
  limit 1;

  if not found then
    return jsonb_build_object('valores', '{}'::jsonb);
  end if;

  select coalesce(jsonb_object_agg(r.pregunta_id, r.valor), '{}'::jsonb)
    into mapa
  from respuestas r
  join preguntas p on p.id = r.pregunta_id
  where r.registro_id = ult.id
    and p.formulario_id = fid
    and p.activo
    and not p.no_precargar
    and (perfil is null or p.aplica_a is null or p.aplica_a = perfil)
    and p.tipo_respuesta <> 'archivo'
    and p.tipo_respuesta <> 'hora'
    and doc_key(p.pregunta, p.tipo_respuesta, p.documento) is null
    and not (p.tipo_respuesta = 'fecha' and (
          sin_tildes(p.seccion) like '%DATOS DEL REGISTRO%'
          or sin_tildes(p.pregunta) ~ 'FECHA DE (LA )?(INSPECCION|LIMPIEZA|REGISTRO)'))
    and p.id <> 'DOC_PRIMERA_O_RENOVACION'
    and coalesce(btrim(r.valor), '') <> '';

  return jsonb_build_object(
    'valores', coalesce(mapa, '{}'::jsonb),
    'fecha', to_char(ult.fecha, 'YYYY-MM-DD')
  );
end;
$$;

-- ------------------------------------------------------------
-- 9) Al guardar, las vigencias solo se leen de las preguntas
--    que le aplican a esa persona.
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
  hoy date := (now() at time zone 'America/Bogota')::date;
  ahora time := (now() at time zone 'America/Bogota')::time;
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
  alertas_doc := rtrim(alertas_doc, ' |');

  insert into registros (cedula, formulario_id, fecha, hora, estado, alertas,
    nombre, cargo, proyecto_id, proyecto, ciudad, placa_moto, tipo_vehiculo)
  values (ncedula, fid, hoy, ahora,
    case when alertas_doc <> '' then 'CON_ALERTA' else 'OK' end,
    nullif(alertas_doc, ''),
    c.nombre, c.cargo, c.proyecto_id, c.proyecto, c.ciudad, c.placa_moto,
    coalesce(nullif(c.tipo_vehiculo,''), perfil))
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
    'estadoDiario', estado, 'completo', completo, 'archivoDiaUrl', '#',
    'comprobante', jsonb_build_object(
      'nombre', c.nombre, 'cedula', ncedula, 'placa_moto', coalesce(c.placa_moto,''),
      'proyecto', coalesce(c.proyecto,''), 'ciudad', coalesce(c.ciudad,''),
      'fecha', to_char(hoy,'YYYY-MM-DD'), 'completo', completo, 'registros', regs)
  );
end;
$$;

-- ------------------------------------------------------------
-- 10) Exportable con diferenciador de moto / vehículo
--     payload.perfil = 'MOTO' | 'VEHICULO' | '' (todos)
--     Al elegir uno, el archivo trae solo esas personas y solo
--     las columnas de preguntas que les aplican.
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
      'estado_cumplimiento', case when coalesce(rec.alertas,'') <> '' then 'REQUIERE_GESTION' else 'CUMPLE' end,
      'alertas_documentales', coalesce(rec.alertas,''),
      'respuestas', rec.resp, 'evidencias', rec.evid));
  end loop;

  return jsonb_build_object('formulario', fid, 'perfil', coalesce(perfil,''),
    'preguntas', preguntas, 'filas', filas, 'total', jsonb_array_length(filas));
end;
$$;

-- ------------------------------------------------------------
-- 11) Comprobación
-- ------------------------------------------------------------
-- select coalesce(aplica_a,'AMBOS') as aplica_a, count(*)
--   from preguntas where formulario_id='PREOPERACIONAL' and activo
--  group by 1 order by 2 desc;

-- select perfil_cargo(cargo) as perfil, count(*) filter (where activo) as activos
--   from colaboradores group by 1;
