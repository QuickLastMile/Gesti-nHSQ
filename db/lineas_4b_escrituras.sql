-- ============================================================
--  LINEAS - Etapa 4b: nadie escribe fuera de su linea
--  ------------------------------------------------------------
--  La 4a hizo que Administracion solo MUESTRE la linea activa. Pero
--  guardar seguia sin control: con el CECO o la cedula a mano, un
--  HSEQ de Warehouse podia cambiarle el coordinador a un proyecto de
--  Last Mile, mover gente o editar una ficha ajena.
--
--  Hoy eso no es un hueco -a Administracion solo llega el usuario
--  universal- pero es exactamente lo que hay que cerrar ANTES de
--  subir a HSEQ a los usuarios de linea.
--
--  Criterio: un proyecto o una persona que YA tiene linea solo se
--  puede tocar desde esa linea. Lo que todavia no tiene gente -un
--  CECO recien cargado- se deja pasar, para no bloquear la
--  configuracion inicial de una linea nueva.
--
--  Ejecutar DESPUES de db/lineas_4a_administracion.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Los guardas
-- ------------------------------------------------------------
-- La linea de un CECO, deducida de su gente.
create or replace function linea_ceco(p_ceco text)
returns text language sql stable set search_path = public as $fn$
  select c.linea
    from colaboradores c
   where ceco_efectivo(c.proyecto_id, c.proyecto_operativo) = btrim(coalesce(p_ceco, ''))
   group by c.linea
   order by count(*) desc
   limit 1;
$fn$;

-- Cada guarda falla con un mensaje que dice QUE se intento tocar, no
-- solo "no autorizado": si alguien se equivoca de linea tiene que poder
-- entenderlo sin llamar a nadie.
create or replace function exigir_linea_proyecto(p_proyecto text, p_linea text)
returns void language plpgsql stable set search_path = public as $fn$
declare l text := linea_proyecto(p_proyecto);
begin
  if l is not null and l <> p_linea then
    raise exception 'El proyecto "%" es de la linea %, no de %. Cambia la linea en la barra.',
      p_proyecto, l, p_linea;
  end if;
end;
$fn$;

create or replace function exigir_linea_ceco(p_ceco text, p_linea text)
returns void language plpgsql stable set search_path = public as $fn$
declare l text := linea_ceco(p_ceco);
begin
  if l is not null and l <> p_linea then
    raise exception 'El CECO % es de la linea %, no de %. Cambia la linea en la barra.',
      p_ceco, l, p_linea;
  end if;
end;
$fn$;

create or replace function exigir_linea_cedula(p_cedula text, p_linea text)
returns void language plpgsql stable set search_path = public as $fn$
declare l text;
begin
  select c.linea into l from colaboradores c
   where regexp_replace(c.cedula, '\D', '', 'g') = regexp_replace(coalesce(p_cedula,''), '\D', '', 'g');
  if l is not null and l <> p_linea then
    raise exception 'Esa cedula es de la linea %, no de %. Cambia la linea en la barra.', l, p_linea;
  end if;
end;
$fn$;

-- ------------------------------------------------------------
--  2) Editar una ficha
-- ------------------------------------------------------------
create or replace function admin_guardar_colaborador(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  nueva_placa text := upper(btrim(coalesce(payload->>'placa_moto','')));
  nuevo_activo boolean := coalesce((nullif(payload->>'activo',''))::boolean, false);
begin
  if ncedula = '' then raise exception 'Cedula invalida.'; end if;
  perform exigir_linea_cedula(ncedula, linea_efectiva(coalesce(payload->>'linea','')));
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

-- ------------------------------------------------------------
--  3) Calendario y metas
-- ------------------------------------------------------------
create or replace function admin_guardar_calendario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p text := btrim(coalesce(payload->>'proyecto',''));
  d text := btrim(coalesce(payload->>'dias',''));
  f boolean := coalesce((payload->>'festivos')::boolean, false);
  m numeric := nullif(btrim(coalesce(payload->>'meta','')), '')::numeric;
begin
  if p = '' then raise exception 'Falta el proyecto.'; end if;
  perform exigir_linea_proyecto(p, linea_efectiva(coalesce(payload->>'linea','')));
  if d = '' then raise exception 'Selecciona al menos un dia laboral.'; end if;
  if m is not null and (m < 0 or m > 100) then raise exception 'La meta debe estar entre 0 y 100.'; end if;
  insert into proyectos_calendario (proyecto, dias_laborales, labora_festivos, meta, actualizado_en)
  values (p, string_to_array(d, ',')::smallint[], f, m, now())
  on conflict (proyecto) do update
    set dias_laborales = excluded.dias_laborales,
        labora_festivos = excluded.labora_festivos,
        meta = excluded.meta,
        actualizado_en = now();
  insert into historial (tipo, cedula, detalle)
  values ('CALENDARIO', '', p || ' -> dias ' || d || case when f then ' + festivos' else '' end
          || coalesce(' · meta ' || m || '%', ''));
  return jsonb_build_object('proyecto', p, 'dias', d, 'festivos', f, 'meta', m);
end;
$$;

-- ------------------------------------------------------------
--  4) Ingreso provisional
-- ------------------------------------------------------------
create or replace function admin_crear_provisional(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_nombre text := btrim(coalesce(payload->>'nombre',''));
  v_proy text := btrim(coalesce(payload->>'proyecto',''));
  v_cargo text := btrim(coalesce(payload->>'cargo',''));
  v_ciudad text := btrim(coalesce(payload->>'ciudad',''));
  v_ceco text;
  hoy date := (now() at time zone 'America/Bogota')::date;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ya colaboradores%rowtype;
begin
  if length(ncedula) < 5 then raise exception 'Digita una cedula valida.'; end if;
  if v_nombre = '' then raise exception 'Escribe el nombre completo.'; end if;
  if v_proy = '' then raise exception 'Selecciona el proyecto.'; end if;
  if v_cargo = '' then raise exception 'Selecciona el cargo.'; end if;
  -- Ni el proyecto ni la persona pueden ser de otra linea.
  perform exigir_linea_proyecto(v_proy, v_linea);
  perform exigir_linea_cedula(ncedula, v_linea);

  -- Sin CECO la persona quedaria sin jefe, sin lider y sin coordinador.
  v_ceco := codigo_proyecto(v_proy);
  if coalesce(v_ceco,'') = '' then
    raise exception 'El proyecto "%" no existe en la matriz o no tiene CECO. Elige uno de la lista.', v_proy;
  end if;

  select * into ya from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula;
  if found then
    update colaboradores set
      activo = true,
      nombre = coalesce(nullif(btrim(colaboradores.nombre),''), upper(v_nombre)),
      proyecto = coalesce(nullif(btrim(colaboradores.proyecto),''), v_proy),
      proyecto_id = coalesce(nullif(btrim(colaboradores.proyecto_id),''), v_ceco),
      cargo = coalesce(nullif(btrim(colaboradores.cargo),''), upper(v_cargo)),
      observacion_coordinador = null,
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;

    insert into historial (tipo, cedula, detalle)
    values ('PROVISIONAL', ncedula, 'Ya existia en la matriz; se reactivo desde configuracion.');

    return jsonb_build_object('cedula', ncedula, 'creado', false, 'reactivado', true,
      'mensaje', 'Esta persona ya estaba en la matriz. Se reactivo y ya puede registrar.');
  end if;

  insert into colaboradores (cedula, nombre, cargo, proyecto, proyecto_id, ciudad, activo,
                             tipo_vehiculo, provisional, provisional_desde, observaciones_hsq, linea)
  values (ncedula, upper(v_nombre), upper(v_cargo), v_proy, v_ceco, nullif(upper(v_ciudad),''), true,
          case when sin_tildes(v_cargo) like '%CONDUCTOR%' then 'VEHICULO' else 'MOTO' end,
          true, hoy,
          'Ingreso provisional creado el ' || hoy || ' desde configuracion, pendiente de nomina.', v_linea);

  insert into historial (tipo, cedula, detalle)
  values ('PROVISIONAL', ncedula, 'Ingreso provisional: ' || v_nombre || ' - ' || v_proy || ' - ' || v_cargo);

  return jsonb_build_object('cedula', ncedula, 'creado', true, 'reactivado', false,
    'mensaje', 'Listo. ' || v_nombre || ' ya puede registrar.');
end;
$fn$;

-- ------------------------------------------------------------
--  5) Traslado entre proyectos
-- ------------------------------------------------------------
create or replace function admin_mover_proyecto(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  destino text := btrim(coalesce(payload->>'proyecto_operativo',''));
  motivo text := btrim(coalesce(payload->>'motivo',''));
  hoy date := (now() at time zone 'America/Bogota')::date;
  c colaboradores%rowtype;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
begin
  if ncedula = '' then raise exception 'Cedula invalida.'; end if;
  -- Un traslado mueve a la persona de proyecto, no de linea.
  perform exigir_linea_cedula(ncedula, v_linea);
  if destino <> '' then perform exigir_linea_proyecto(destino, v_linea); end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula;
  if not found then raise exception 'No existe esa cedula en la matriz.'; end if;

  if destino = '' then
    update colaboradores set
      proyecto_operativo = null, proyecto_operativo_desde = null,
      proyecto_operativo_motivo = null, actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;

    insert into historial (tipo, cedula, detalle)
    values ('TRASLADO', ncedula, 'Regresa a su proyecto de nomina: ' || coalesce(c.proyecto,''));

    return jsonb_build_object('cedula', ncedula, 'proyecto_operativo', '',
      'mensaje', 'Vuelve a contar en su proyecto de nomina.');
  end if;

  if destino = coalesce(c.proyecto,'') then
    raise exception 'Ese ya es su proyecto de nomina. Para devolverlo, deja el campo vacio.';
  end if;
  if motivo = '' then raise exception 'Escribe el motivo del traslado.'; end if;

  update colaboradores set
    proyecto_operativo = destino,
    proyecto_operativo_desde = hoy,
    proyecto_operativo_motivo = motivo,
    actualizado_en = now()
  where regexp_replace(cedula,'\D','','g') = ncedula;

  insert into historial (tipo, cedula, detalle)
  values ('TRASLADO', ncedula, coalesce(c.proyecto,'(sin proyecto)') || ' -> ' || destino || ': ' || motivo);

  return jsonb_build_object('cedula', ncedula, 'proyecto_operativo', destino,
    'mensaje', 'Desde hoy se le exige y se le cuenta en ' || destino || '.');
end;
$fn$;

-- ------------------------------------------------------------
--  6) Jefe, lider y coordinador de un proyecto
-- ------------------------------------------------------------
create or replace function admin_guardar_encargado(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  pid  text := btrim(coalesce(payload->>'proyecto_id',''));
  fr   text := btrim(coalesce(payload->>'frente',''));
  n    int;
begin
  if pid = '' then raise exception 'Falta el codigo del proyecto (CECO).'; end if;
  perform exigir_linea_ceco(pid, linea_efectiva(coalesce(payload->>'linea','')));

  -- Borra TODA la configuracion del proyecto: la general y sus partes.
  if coalesce(payload->>'borrar_proyecto','') = 'true' then
    delete from responsables_proyecto where proyecto_id = pid;
    update colaboradores set frente = null, actualizado_en = now()
      where ceco_efectivo(proyecto_id, proyecto_operativo) = pid
        and coalesce(btrim(frente),'') <> '';
    perform recalcular_encargados();
    insert into historial (tipo, cedula, detalle)
    values ('ENCARGADOS', null, 'Se quito la configuracion de encargados del CECO ' || pid || '.');
    return jsonb_build_object('mensaje',
      'Listo. El proyecto queda sin jefe, sin lider y sin coordinador. Puedes volver a configurarlo cuando quieras.');
  end if;

  if coalesce(payload->>'borrar','') = 'true' then
    if fr = '' then raise exception 'Para quitar todo el proyecto usa la opcion de eliminar configuracion.'; end if;
    delete from responsables_proyecto where proyecto_id = pid and frente = fr;
    update colaboradores set frente = null
      where ceco_efectivo(proyecto_id, proyecto_operativo) = pid and btrim(coalesce(frente,'')) = fr;
    perform recalcular_encargados();
    return jsonb_build_object('mensaje', 'Parte eliminada. Su gente vuelve al coordinador del proyecto.');
  end if;

  insert into responsables_proyecto (proyecto_id, frente, cliente, jefatura, lider, coordinador, actualizado_en)
  values (pid, fr,
          nullif(btrim(coalesce(payload->>'cliente','')),''),
          nullif(upper(btrim(coalesce(payload->>'jefatura',''))),''),
          nullif(upper(btrim(coalesce(payload->>'lider',''))),''),
          nullif(upper(btrim(coalesce(payload->>'coordinador',''))),''),
          now())
  on conflict (proyecto_id, frente) do update set
    cliente     = coalesce(excluded.cliente, responsables_proyecto.cliente),
    jefatura    = excluded.jefatura,
    lider       = excluded.lider,
    coordinador = excluded.coordinador,
    actualizado_en = now();

  perform recalcular_encargados();
  select count(*) into n from colaboradores c
    where c.activo and ceco_efectivo(c.proyecto_id, c.proyecto_operativo) = pid;

  return jsonb_build_object('mensaje',
    'Guardado. Cubre ' || n || ' persona(s) de este proyecto'
    || case when fr <> '' then ' en la parte ' || fr else '' end || '.');
end;
$fn$;

-- ------------------------------------------------------------
--  7) Borrar un CECO sin gente
-- ------------------------------------------------------------
create or replace function admin_borrar_huerfano(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare pid text := btrim(coalesce(payload->>'proyecto_id',''));
begin
  if pid = '' then raise exception 'Falta el codigo del proyecto (CECO).'; end if;
  -- Un CECO sin gente no tiene linea deducible, asi que borrarlo solo lo
  -- puede hacer quien ve todas: si no, una linea borraria configuracion
  -- que la otra acaba de cargar.
  if not usuario_universal() then
    raise exception 'Solo la administracion general puede eliminar un CECO sin gente.';
  end if;
  if exists (select 1 from colaboradores where ceco_efectivo(proyecto_id, proyecto_operativo) = pid) then
    raise exception 'Ese CECO si tiene gente en la matriz. Usa la opcion del proyecto, no esta.';
  end if;
  delete from responsables_proyecto where proyecto_id = pid;
  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null, 'Se elimino el CECO cargado ' || pid || ', que no tenia gente.');
  return jsonb_build_object('mensaje', 'CECO ' || pid || ' eliminado de la tabla de encargados.');
end;
$fn$;

-- ------------------------------------------------------------
--  8) Asignar parte y coordinador propio
-- ------------------------------------------------------------
create or replace function admin_asignar_frente(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ceds text[];
  fr text;
  co text;
  n int := 0;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ajenas int := 0;
begin
  select array_agg(regexp_replace(v, '\D', '', 'g'))
    into ceds
    from jsonb_array_elements_text(coalesce(payload->'cedulas','[]'::jsonb)) v;
  if ceds is null or array_length(ceds,1) is null then
    raise exception 'Selecciona al menos una persona.';
  end if;

  -- Una cedula de otra linea no se toca, y se dice cuantas fueron: es
  -- preferible avisar que hacer un cambio silencioso a medias.
  select count(*) into ajenas from colaboradores
   where regexp_replace(cedula,'\D','','g') = any(ceds) and linea <> v_linea;
  if ajenas > 0 then
    raise exception '% de las personas seleccionadas son de otra linea. Cambia la linea en la barra.', ajenas;
  end if;

  -- Una clave ausente no se toca; una clave con texto vacío sí limpia el dato.
  if payload ? 'frente' then
    fr := nullif(upper(btrim(coalesce(payload->>'frente',''))),'');
    update colaboradores set frente = fr, actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = any(ceds) and linea = v_linea;
    get diagnostics n = row_count;
  end if;

  if payload ? 'coordinador' then
    co := nullif(upper(btrim(coalesce(payload->>'coordinador',''))),'');
    update colaboradores set coordinador = co, actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = any(ceds) and linea = v_linea;
    get diagnostics n = row_count;
  end if;

  if n = 0 then raise exception 'No se encontro ninguna de esas cedulas en la matriz.'; end if;

  return jsonb_build_object('actualizados', n,
    'mensaje', n || ' persona(s) actualizada(s).');
end;
$fn$;

-- ------------------------------------------------------------
--  9) Coordinador para varios proyectos
-- ------------------------------------------------------------
create or replace function admin_coordinador_masivo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  coord text := nullif(upper(btrim(coalesce(payload->>'coordinador',''))), '');
  ids text[];
  n int := 0;
  con_partes int := 0;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ajenos int := 0;
begin
  select array_agg(btrim(v))
    into ids
    from jsonb_array_elements_text(coalesce(payload->'proyectos', '[]'::jsonb)) v
   where btrim(v) <> '';
  if ids is null or array_length(ids, 1) is null then
    raise exception 'Selecciona al menos un proyecto.';
  end if;

  -- Asignar de golpe es comodo justamente porque son muchos: por eso
  -- vale la pena revisar antes que ninguno sea de otra linea.
  select count(*) into ajenos
    from unnest(ids) x(pid)
   where linea_ceco(x.pid) is not null and linea_ceco(x.pid) <> v_linea;
  if ajenos > 0 then
    raise exception '% de los proyectos seleccionados son de otra linea. Cambia la linea en la barra.', ajenos;
  end if;

  -- Solo toca el coordinador: el jefe y el lider de cada proyecto se conservan.
  insert into responsables_proyecto (proyecto_id, frente, coordinador)
  select unnest(ids), '', coord
  on conflict (proyecto_id, frente) do update
    set coordinador = excluded.coordinador, actualizado_en = now();
  get diagnostics n = row_count;

  -- Un proyecto dividido en partes ya tiene su propio coordinador por parte:
  -- ahi este pasa a ser el de respaldo, no reemplaza a los demas.
  select count(distinct proyecto_id) into con_partes
    from responsables_proyecto
   where proyecto_id = any(ids) and frente <> '';

  perform recalcular_encargados();

  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null,
          'Coordinador ' || coalesce(coord, '(sin coordinador)') || ' asignado a ' || n || ' proyecto(s).');

  return jsonb_build_object(
    'proyectos', n, 'con_partes', con_partes,
    'mensaje', case when coord is null
      then 'Se quito el coordinador de ' || n || ' proyecto(s).'
      else coord || ' queda como coordinador de ' || n || ' proyecto(s).'
        || case when con_partes > 0
             then ' En ' || con_partes || ' de ellos hay partes con su propio coordinador: ahi cubre solo a quien no este en ninguna.'
             else '' end
    end);
end;
$fn$;

-- ------------------------------------------------------------
--  10) Cargue de la tabla de encargados
-- ------------------------------------------------------------
create or replace function admin_cargar_encargados(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fila jsonb;
  pid text; cli text; jef text; lid text; coo text;
  creados int := 0; actualizados int := 0; ignorados int := 0; ajenos int := 0;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ya boolean;
begin
  if jsonb_typeof(payload->'filas') <> 'array' then
    raise exception 'No llegaron filas para cargar.';
  end if;

  for fila in select * from jsonb_array_elements(payload->'filas') loop
    pid := btrim(coalesce(fila->>'proyecto_id',''));
    cli := nullif(btrim(coalesce(fila->>'cliente','')),'');
    jef := nullif(upper(btrim(coalesce(fila->>'jefatura',''))),'');
    lid := nullif(upper(btrim(coalesce(fila->>'lider',''))),'');
    coo := nullif(upper(btrim(coalesce(fila->>'coordinador',''))),'');

    if pid = '' then ignorados := ignorados + 1; continue; end if;

    -- Una tabla pegada en la linea equivocada no debe reescribir la otra:
    -- esas filas se saltan y se reportan al final.
    if linea_ceco(pid) is not null and linea_ceco(pid) <> v_linea then
      ajenos := ajenos + 1;
      continue;
    end if;

    select true into ya from responsables_proyecto where proyecto_id = pid and frente = '' limit 1;
    if found then
      -- Un campo vacio no borra lo que ya estaba guardado.
      update responsables_proyecto set
        cliente     = coalesce(cli, cliente),
        jefatura    = coalesce(jef, jefatura),
        lider       = coalesce(lid, lider),
        coordinador = coalesce(coo, coordinador),
        actualizado_en = now()
      where proyecto_id = pid and frente = '';
      actualizados := actualizados + 1;
    else
      insert into responsables_proyecto (proyecto_id, frente, cliente, jefatura, lider, coordinador)
      values (pid, '', cli, jef, lid, coo);
      creados := creados + 1;
    end if;
    ya := null;
  end loop;

  perform recalcular_encargados();

  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null, 'Carga de encargados: ' || creados || ' nuevos, ' || actualizados || ' actualizados.');

  return jsonb_build_object(
    'otraLinea', ajenos,
    'creados', creados, 'actualizados', actualizados, 'ignorados', ignorados,
    'proyectos_sin_jefe', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_jefatura,'') = ''),
    'proyectos_sin_lider', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_lider,'') = ''),
    'mensaje', 'Listo. ' || creados || ' proyecto(s) nuevos y ' || actualizados || ' actualizados.'
      || case when ajenos > 0
              then ' Se saltaron ' || ajenos || ' fila(s) de otra linea.'
              else '' end);
end;
$fn$;

-- ------------------------------------------------------------
--  11) Habilitar un formulario en un proyecto
-- ------------------------------------------------------------
create or replace function admin_guardar_formulario_proyecto(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_proyecto text := btrim(coalesce(payload->>'proyecto',''));
  v_formulario text := upper(btrim(coalesce(payload->>'formulario_id','')));
  v_activo boolean := coalesce((nullif(payload->>'activo',''))::boolean, false);
  v_frec text := upper(btrim(coalesce(payload->>'frecuencia','DIARIA')));
  v_dia smallint := nullif(btrim(coalesce(payload->>'dia_semana','')), '')::smallint;
  v_nombre text;
  v_dias smallint[];
  v_aviso text := '';
begin
  if v_proyecto='' then raise exception 'Proyecto invalido.'; end if;
  if not exists (select 1 from colaboradores where proyecto=v_proyecto) then
    raise exception 'El proyecto no existe en la matriz.';
  end if;
  perform exigir_linea_proyecto(v_proyecto, linea_efectiva(coalesce(payload->>'linea','')));
  select nombre into v_nombre from formularios where id=v_formulario;
  if not found then raise exception 'El formulario no existe.'; end if;
  if v_activo and not exists (select 1 from formularios where id=v_formulario and activo) then
    raise exception 'El formulario esta inactivo globalmente.';
  end if;

  if v_frec not in ('DIARIA','SEMANAL') then
    raise exception 'Frecuencia no valida: %', v_frec;
  end if;
  -- El preoperacional (y cualquier formulario sin la marca) es siempre diario.
  if v_frec = 'SEMANAL'
     and not coalesce((select permite_frecuencia from formularios where id=v_formulario), false) then
    raise exception '% se diligencia todos los dias: no admite frecuencia semanal.', v_nombre;
  end if;
  if v_frec = 'SEMANAL' then
    if v_dia is null or v_dia < 1 or v_dia > 7 then
      raise exception 'Elige el dia de la semana (1=lunes ... 7=domingo).';
    end if;
  else
    v_dia := null;   -- diaria no guarda dia
  end if;

  insert into proyectos_formularios
    (proyecto, formulario_id, activo, frecuencia, dia_semana, actualizado_en, actualizado_por)
  values (v_proyecto, v_formulario, v_activo, v_frec, v_dia, now(), auth.uid())
  on conflict (proyecto, formulario_id) do update set
    activo=excluded.activo,
    frecuencia=excluded.frecuencia,
    dia_semana=excluded.dia_semana,
    actualizado_en=excluded.actualizado_en,
    actualizado_por=excluded.actualizado_por;

  -- Un dia que el proyecto no labora nunca llega: mejor decirlo al guardar.
  if v_activo and v_frec = 'SEMANAL' then
    select coalesce(pc.dias_laborales,
             coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
                      '{1,2,3,4,5,6}'::smallint[]))
      into v_dias
      from (select 1) z
      left join proyectos_calendario pc on pc.proyecto = v_proyecto;
    if not (v_dia = any(coalesce(v_dias, '{1,2,3,4,5,6}'::smallint[]))) then
      v_aviso := 'Ojo: ese dia no es laboral para ' || v_proyecto
              || ', asi que el formulario no se va a exigir nunca. Ajusta el calendario del proyecto.';
    end if;
  end if;

  insert into historial(tipo, detalle)
  values ('FORMULARIO_PROYECTO',
    v_proyecto || ' - ' || v_nombre || ': ' || case when v_activo then 'ACTIVADO' else 'INACTIVADO' end
    || case when v_activo and v_frec='SEMANAL'
            then ' (solo ' || (array['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])[v_dia] || ')'
            when v_activo then ' (todos los dias del calendario)'
            else '' end);

  return jsonb_build_object(
    'proyecto',v_proyecto,'formulario_id',v_formulario,'activo',v_activo,
    'frecuencia',v_frec,'dia_semana',v_dia,'aviso',v_aviso,
    'habilitados',(select count(*) from proyectos_formularios pf
      join formularios f on f.id=pf.formulario_id and f.activo
      where pf.proyecto=v_proyecto and pf.activo));
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las escrituras ya validan la linea.
select proname,
       case when prosrc like '%exigir_linea%' or prosrc like '%linea_ceco%'
                 or prosrc like '%usuario_universal%'
            then 'CON GUARDA' else 'SIN GUARDA' end as estado
  from pg_proc
 where proname in ('admin_guardar_colaborador','admin_guardar_calendario',
                   'admin_crear_provisional','admin_mover_proyecto',
                   'admin_guardar_encargado','admin_borrar_huerfano',
                   'admin_asignar_frente','admin_coordinador_masivo',
                   'admin_cargar_encargados','admin_guardar_formulario_proyecto')
 order by proname;

-- b) Ya se pueden subir a HSEQ los usuarios de linea. Descomenta para
--    hacerlo; cada uno seguira viendo solo SU linea.
-- update app_roles set rol = 'HSEQ'
--  where email in ('gestionadmin.lastmile@gmail.com',
--                  'gestionadmin.werehouse@gmail.com');

-- c) Quien puede que.
select email, rol,
       case when rol in ('ADMIN','HSEQ') then 'Administracion + Cumplimiento + Dashboard'
            else 'Cumplimiento + Dashboard' end as pantallas,
       case when todas_lineas then 'TODAS' else array_to_string(lineas, ', ') end as ve_lineas
  from app_roles where activo order by rol, email;
