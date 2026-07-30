-- ============================================================
--  Gestión HSEQ Motos — Coordinador: Cumplimiento + Justificaciones
--  Ejecutar después de schema/functions/functions_write.
-- ============================================================

-- Justificaciones: tipo + rango de fechas (el coordinador cubre todo el rango).
alter table justificaciones add column if not exists tipo text;
alter table justificaciones add column if not exists fecha_inicio date;
alter table justificaciones add column if not exists fecha_fin date;
alter table justificaciones drop constraint if exists uq_justificacion;
update justificaciones set fecha_inicio = coalesce(fecha_inicio, fecha),
                           fecha_fin = coalesce(fecha_fin, fecha)
 where fecha_inicio is null;
create index if not exists idx_just_rango on justificaciones (cedula, fecha_inicio, fecha_fin);

-- ------------------------------------------------------------
--  Cumplimiento de un día (activos del proyecto: quién marcó,
--  quién no, quién está justificado). Justificados NO cuentan.
-- ------------------------------------------------------------
create or replace function api_cumplimiento_dia(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  dia date := coalesce(nullif(payload->>'fecha','')::date, (now() at time zone 'America/Bogota')::date);
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  forms jsonb;
  personas jsonb := '[]'::jsonb;
  total int := 0; completos int := 0; justificados int := 0;
  rec record; f record;
  estados jsonb; hechos int; nforms int;
  h text; jt text; jm text; es_just boolean; es_completo boolean;
  alertas_persona text;
begin
  forms := coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) order by orden)
                     from formularios where activo), '[]'::jsonb);
  select count(*) into nforms from formularios where activo;

  for rec in
    select c.cedula, c.nombre, c.proyecto, c.ciudad, c.placa_moto
    from colaboradores c
    where c.activo and (filtro_proy = '' or c.proyecto = filtro_proy or c.proyecto_id::text = filtro_proy)
    order by c.nombre
  loop
    estados := '{}'::jsonb; hechos := 0; alertas_persona := '';
    for f in select id, nombre from formularios where activo order by orden loop
      h := null;
      select to_char(r.hora,'HH24:MI') into h from registros r
        where regexp_replace(r.cedula,'\D','','g') = regexp_replace(rec.cedula,'\D','','g')
          and r.formulario_id = f.id and r.fecha = dia limit 1;
      if h is not null then
        estados := estados || jsonb_build_object(f.id, jsonb_build_object('hecho', true, 'hora', h));
        hechos := hechos + 1;
      else
        estados := estados || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      end if;
    end loop;

    select coalesce(string_agg(r.alertas, ' | ' order by r.hora), '') into alertas_persona
      from registros r
      where regexp_replace(r.cedula,'\D','','g') = regexp_replace(rec.cedula,'\D','','g')
        and r.fecha = dia and coalesce(r.alertas,'') <> '';

    jt := null; jm := null;
    select j.tipo, j.motivo into jt, jm from justificaciones j
      where regexp_replace(j.cedula,'\D','','g') = regexp_replace(rec.cedula,'\D','','g')
        and dia between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha)
      order by j.creado_en desc limit 1;
    es_just := found;
    es_completo := (nforms > 0 and hechos = nforms);

    total := total + 1;
    if es_completo then completos := completos + 1;
    elsif es_just then justificados := justificados + 1;
    end if;

    personas := personas || jsonb_build_array(jsonb_build_object(
      'cedula', rec.cedula, 'nombre', coalesce(rec.nombre,''), 'proyecto', coalesce(rec.proyecto,''),
      'ciudad', coalesce(rec.ciudad,''), 'placa', coalesce(rec.placa_moto,''),
      'estados', estados, 'completo', es_completo,
      'alertas_documentales', coalesce(alertas_persona,''),
      'requiere_gestion', coalesce(alertas_persona,'') <> '',
      'justificado', (es_just and not es_completo),
      'justificacion', case when es_just then jsonb_build_object('tipo', coalesce(jt,''), 'motivo', coalesce(jm,'')) else null end
    ));
  end loop;

  return jsonb_build_object(
    'fecha', to_char(dia,'YYYY-MM-DD'), 'proyecto', filtro_proy, 'formularios', forms,
    'personas', personas,
    'resumen', jsonb_build_object(
      'total', total, 'completos', completos, 'justificados', justificados,
      'pendientes', greatest(total - completos - justificados, 0),
      'esperados', greatest(total - justificados, 0),
      'porcentaje', case when (total - justificados) > 0
                         then round(completos::numeric * 1000 / (total - justificados)) / 10 else 0 end
    )
  );
end;
$$;

-- ------------------------------------------------------------
--  Guardar justificación (con tipo y rango). Renuncia = inactivar.
-- ------------------------------------------------------------
create or replace function api_guardar_justificacion(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  tipo text := upper(btrim(coalesce(payload->>'tipo','')));
  motivo text := btrim(coalesce(payload->>'motivo',''));
  fi date := nullif(payload->>'fecha_inicio','')::date;
  ff date := nullif(payload->>'fecha_fin','')::date;
  hoy date := (now() at time zone 'America/Bogota')::date;
  nombre text := btrim(coalesce(payload->>'nombre',''));
  proyecto text := btrim(coalesce(payload->>'proyecto',''));
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  if tipo = '' then raise exception 'Elige el tipo de justificacion.'; end if;

  if tipo = 'RENUNCIA' then
    update colaboradores set activo = false,
      observacion_coordinador = 'Renuncia (' || to_char(coalesce(fi, hoy),'YYYY-MM-DD') || ')'
        || case when motivo <> '' then ': ' || motivo else '' end,
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;
    insert into historial (tipo, cedula, detalle) values ('RENUNCIA', ncedula, coalesce(nullif(motivo,''), 'Renuncia'));
    return jsonb_build_object('tipo', 'RENUNCIA', 'inactivado', true);
  end if;

  fi := coalesce(fi, hoy);
  ff := coalesce(ff, fi);
  if ff < fi then raise exception 'La fecha fin no puede ser anterior a la fecha inicio.'; end if;

  insert into justificaciones (fecha, cedula, nombre, proyecto, motivo, tipo, fecha_inicio, fecha_fin, creado_en)
  values (fi, ncedula, nombre, proyecto, coalesce(nullif(motivo,''), initcap(lower(tipo))), tipo, fi, ff, now());
  insert into historial (tipo, cedula, detalle)
  values ('JUSTIFICACION', ncedula, tipo || ' ' || to_char(fi,'YYYY-MM-DD') || ' a ' || to_char(ff,'YYYY-MM-DD'));

  return jsonb_build_object('tipo', tipo, 'dias', (ff - fi) + 1);
end;
$$;

-- ------------------------------------------------------------
--  Dashboard: marcaciones realizadas vs esperadas, por mes y por
--  proyecto. Filtros: anio, mes (opcional), proyecto (opcional).
-- ------------------------------------------------------------
create or replace function api_dashboard(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  anio int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes int := nullif(payload->>'mes','')::int;
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  desde date; hasta date;
  nforms int; activos int; dias_total int;
  real_total bigint; esp_total bigint;
  por_mes jsonb := '[]'::jsonb; por_proy jsonb := '[]'::jsonb;
  m int; md date; mh date; dd int; real_m bigint; esp_m bigint;
  rec record; rp bigint; ep bigint;
begin
  select count(*) into nforms from formularios where activo;
  select count(*) into activos from colaboradores where activo and (filtro_proy = '' or proyecto = filtro_proy or proyecto_id::text = filtro_proy);

  if mes is not null then
    desde := make_date(anio, mes, 1);
    hasta := least((desde + interval '1 month - 1 day')::date, hoy);
  else
    desde := make_date(anio, 1, 1);
    hasta := least(make_date(anio, 12, 31), hoy);
  end if;
  if hasta < desde then hasta := desde; end if;
  dias_total := (hasta - desde) + 1;

  select count(*) into real_total from registros r
    where r.fecha between desde and hasta and (filtro_proy = '' or r.proyecto = filtro_proy or r.proyecto_id::text = filtro_proy);
  esp_total := activos::bigint * dias_total * nforms;

  for m in extract(month from desde)::int .. extract(month from hasta)::int loop
    md := greatest(desde, make_date(anio, m, 1));
    mh := least(hasta, (make_date(anio, m, 1) + interval '1 month - 1 day')::date);
    dd := (mh - md) + 1;
    select count(*) into real_m from registros r
      where r.fecha between md and mh and (filtro_proy = '' or r.proyecto = filtro_proy or r.proyecto_id::text = filtro_proy);
    esp_m := activos::bigint * dd * nforms;
    por_mes := por_mes || jsonb_build_array(jsonb_build_object(
      'etiqueta', to_char(md,'YYYY-MM'), 'realizadas', real_m, 'esperadas', esp_m,
      'no_realizadas', greatest(esp_m - real_m, 0),
      'porcentaje', case when esp_m > 0 then round(real_m::numeric * 1000 / esp_m) / 10 else 0 end));
  end loop;

  if filtro_proy = '' then
    for rec in
      select proyecto as proy, count(*) as act
      from colaboradores where activo and coalesce(proyecto,'') <> ''
      group by proyecto order by proyecto
    loop
      select count(*) into rp from registros r where r.fecha between desde and hasta and r.proyecto = rec.proy;
      ep := rec.act::bigint * dias_total * nforms;
      por_proy := por_proy || jsonb_build_array(jsonb_build_object(
        'proyecto', rec.proy, 'realizadas', rp, 'esperadas', ep,
        'no_realizadas', greatest(ep - rp, 0),
        'porcentaje', case when ep > 0 then round(rp::numeric * 1000 / ep) / 10 else 0 end));
    end loop;
  end if;

  return jsonb_build_object(
    'anio', anio, 'mes', mes, 'proyecto', filtro_proy,
    'resumen', jsonb_build_object('activos', activos, 'realizadas', real_total, 'esperadas', esp_total,
      'no_realizadas', greatest(esp_total - real_total, 0),
      'porcentaje', case when esp_total > 0 then round(real_total::numeric * 1000 / esp_total) / 10 else 0 end),
    'por_mes', por_mes, 'por_proyecto', por_proy
  );
end;
$$;

-- ------------------------------------------------------------
--  Router actualizado con las acciones del coordinador.
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  case action
    when 'getBootstrap'        then result := api_get_bootstrap();
    when 'buscarActivo'        then result := api_buscar_activo(payload);
    when 'cargarFormulario'    then result := api_cargar_formulario(payload);
    when 'guardarRegistro'     then result := api_guardar_registro(payload);
    when 'registrarPlaca'      then result := api_registrar_placa(payload);
    when 'getCumplimientoDia'  then result := api_cumplimiento_dia(payload);
    when 'guardarJustificacion' then result := api_guardar_justificacion(payload);
    when 'getDashboard'        then result := api_dashboard(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function hseq_api(text, jsonb) to anon;
