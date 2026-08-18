-- ============================================================
--  Gestión HSEQ Motos — Ingresos provisionales y traslados
--  ------------------------------------------------------------
--  Dos situaciones que hoy quedaban por fuera:
--
--  1) INGRESOS PROVISIONALES
--     La matriz se actualiza dos veces al mes. Quien entra a
--     mitad de periodo no puede registrar hasta que llegue la
--     nómina. Ahora HSEQ lo crea a mano y registra desde el
--     primer día; cuando llega la nómina se vuelve definitivo
--     solo, y mientras tanto la actualización de matriz NO lo
--     inactiva.
--
--  2) TRASLADOS ENTRE OPERACIONES
--     Un colaborador puede estar prestado a otro proyecto sin
--     que cambie su proyecto de nómina. Se guarda aparte dónde
--     está laborando: el cumplimiento se le exige y se le cuenta
--     en el proyecto donde realmente trabaja, y la matriz
--     conserva el suyo.
--
--  Ejecutar DESPUÉS de: functions_admin.sql y functions_coord2.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) Columnas nuevas
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists provisional boolean not null default false,
  add column if not exists provisional_desde date,
  add column if not exists proyecto_operativo text,
  add column if not exists proyecto_operativo_desde date,
  add column if not exists proyecto_operativo_motivo text;

comment on column colaboradores.provisional is
  'true = creado a mano por HSEQ; aun no viene en la nomina. No se inactiva al actualizar la matriz.';
comment on column colaboradores.proyecto_operativo is
  'Proyecto donde esta laborando realmente. Vacio = aplica el de nomina.';

-- Proyecto que manda para exigir y contar el cumplimiento.
alter table colaboradores drop column if exists proyecto_efectivo;
alter table colaboradores
  add column proyecto_efectivo text
  generated always as (coalesce(nullif(btrim(proyecto_operativo), ''), proyecto)) stored;

create index if not exists idx_colab_proy_efectivo
  on colaboradores (proyecto_efectivo) where activo;

-- ------------------------------------------------------------
-- 2) Crear un ingreso provisional
-- ------------------------------------------------------------
create or replace function admin_crear_provisional(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_nombre text := btrim(coalesce(payload->>'nombre',''));
  v_proy text := btrim(coalesce(payload->>'proyecto',''));
  v_cargo text := btrim(coalesce(payload->>'cargo',''));
  v_ciudad text := btrim(coalesce(payload->>'ciudad',''));
  hoy date := (now() at time zone 'America/Bogota')::date;
  ya colaboradores%rowtype;
begin
  if length(ncedula) < 5 then raise exception 'Digita una cedula valida.'; end if;
  if v_nombre = '' then raise exception 'Escribe el nombre completo.'; end if;
  if v_proy = '' then raise exception 'Selecciona el proyecto.'; end if;
  if v_cargo = '' then raise exception 'Selecciona el cargo.'; end if;

  select * into ya from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula;
  if found then
    -- Ya existia: se reactiva sin pisar los datos de nomina.
    update colaboradores set
      activo = true,
      nombre = coalesce(nullif(btrim(colaboradores.nombre),''), upper(v_nombre)),
      proyecto = coalesce(nullif(btrim(colaboradores.proyecto),''), v_proy),
      cargo = coalesce(nullif(btrim(colaboradores.cargo),''), upper(v_cargo)),
      observacion_coordinador = null,
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;

    insert into historial (tipo, cedula, detalle)
    values ('PROVISIONAL', ncedula, 'Ya existia en la matriz; se reactivo desde configuracion.');

    return jsonb_build_object('cedula', ncedula, 'creado', false, 'reactivado', true,
      'mensaje', 'Esta persona ya estaba en la matriz. Se reactivo y ya puede registrar.');
  end if;

  insert into colaboradores (cedula, nombre, cargo, proyecto, ciudad, activo,
                             tipo_vehiculo, provisional, provisional_desde, observaciones_hsq)
  values (ncedula, upper(v_nombre), upper(v_cargo), v_proy, nullif(upper(v_ciudad),''), true,
          case when sin_tildes(v_cargo) like '%CONDUCTOR%' then 'VEHICULO' else 'MOTO' end,
          true, hoy,
          'Ingreso provisional creado el ' || hoy || ' desde configuracion, pendiente de nomina.');

  insert into historial (tipo, cedula, detalle)
  values ('PROVISIONAL', ncedula, 'Ingreso provisional: ' || v_nombre || ' - ' || v_proy || ' - ' || v_cargo);

  return jsonb_build_object('cedula', ncedula, 'creado', true, 'reactivado', false,
    'mensaje', 'Listo. ' || v_nombre || ' ya puede registrar.');
end;
$fn$;

-- ------------------------------------------------------------
-- 3) Trasladar a otro proyecto sin tocar la matriz.
--    Dejar el destino vacío lo devuelve a su proyecto de nómina.
-- ------------------------------------------------------------
create or replace function admin_mover_proyecto(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  destino text := btrim(coalesce(payload->>'proyecto_operativo',''));
  motivo text := btrim(coalesce(payload->>'motivo',''));
  hoy date := (now() at time zone 'America/Bogota')::date;
  c colaboradores%rowtype;
begin
  if ncedula = '' then raise exception 'Cedula invalida.'; end if;
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
-- 4) El panel muestra la situación de cada colaborador
-- ------------------------------------------------------------
create or replace function colab_json(c colaboradores)
returns jsonb language sql immutable set search_path = public as $fn$
  select jsonb_build_object(
    'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
    'proyecto', coalesce(c.proyecto,''), 'proyecto_id', coalesce(c.proyecto_id,''),
    'proyecto_operativo', coalesce(c.proyecto_operativo,''),
    'proyecto_efectivo', coalesce(c.proyecto_efectivo,''),
    'proyecto_operativo_desde', to_char(c.proyecto_operativo_desde,'YYYY-MM-DD'),
    'proyecto_operativo_motivo', coalesce(c.proyecto_operativo_motivo,''),
    'provisional', c.provisional,
    'provisional_desde', to_char(c.provisional_desde,'YYYY-MM-DD'),
    'ciudad', coalesce(c.ciudad,''), 'activo', c.activo, 'placa_moto', coalesce(c.placa_moto,''),
    'observacion_coordinador', coalesce(c.observacion_coordinador,''),
    'tipo_vehiculo', coalesce(c.tipo_vehiculo,''), 'marca_vehiculo', coalesce(c.marca_vehiculo,''),
    'cilindraje', coalesce(c.cilindraje,''),
    'soat_vence', to_char(c.soat_vence,'YYYY-MM-DD'),
    'tecnomecanica_vence', to_char(c.tecnomecanica_vence,'YYYY-MM-DD'),
    'licencia_vence', to_char(c.licencia_vence,'YYYY-MM-DD'),
    'soat_url', coalesce(c.soat_url,''), 'tecnomecanica_url', coalesce(c.tecnomecanica_url,''),
    'licencia_url', coalesce(c.licencia_url,'')
  );
$fn$;

-- Al filtrar por proyecto se busca por donde está laborando.
create or replace function admin_listar(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(colab_json(c) order by (not c.activo), c.nombre), '[]'::jsonb)
  from colaboradores c
  where (coalesce(payload->>'proyecto','') = ''
         or c.proyecto_efectivo = payload->>'proyecto'
         or c.proyecto = payload->>'proyecto')
    and case coalesce(payload->>'estado','todos')
          when 'activos' then c.activo
          when 'inactivos' then not c.activo
          when 'provisionales' then c.provisional and c.activo
          when 'trasladados' then coalesce(btrim(c.proyecto_operativo),'') <> ''
          else true end
  limit 800;
$fn$;

-- La lista de proyectos incluye los de nómina y los operativos.
create or replace function admin_proyectos()
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('proyecto', proyecto) order by proyecto), '[]'::jsonb)
  from (
    select distinct proyecto from colaboradores where coalesce(proyecto,'') <> ''
    union
    select distinct proyecto_operativo as proyecto from colaboradores where coalesce(proyecto_operativo,'') <> ''
    union
    select distinct proyecto from proyectos_formularios where coalesce(proyecto,'') <> ''
  ) t;
$fn$;

-- ------------------------------------------------------------
-- 5) El registro usa el proyecto donde está laborando
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  estado jsonb := '{}'::jsonb;
  docs jsonb := '{}'::jsonb;
  v_obs text;
  f record; r record; d record;
  dias int; est text;
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('encontrado', false, 'mensaje', 'No se encontro la cedula en la matriz.');
  end if;

  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');
  v_obs := btrim(coalesce(c.observacion_coordinador, ''));

  if c.activo then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
      order by frm.orden
    loop
      select to_char(hora,'HH24:MI') as h, id::text as rid into r
        from registros
       where regexp_replace(cedula,'\D','','g') = ncedula
         and formulario_id = f.id and fecha = hoy limit 1;
      if found then
        estado := estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        estado := estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      end if;
    end loop;

    for d in select * from (values
        ('SOAT',          c.soat_vence,          c.soat_url),
        ('TECNOMECANICA', c.tecnomecanica_vence, c.tecnomecanica_url),
        ('LICENCIA',      c.licencia_vence,      c.licencia_url)
      ) as t(k, ven, url) loop
      if d.ven is null then
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha','', 'dias', null, 'estado','sin_dato','url', coalesce(d.url,'')));
      else
        dias := d.ven - hoy;
        est := case when dias < 0 then 'vencido' when dias <= 15 then 'por_vencer' else 'ok' end;
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha', to_char(d.ven,'YYYY-MM-DD'), 'dias', dias, 'estado', est, 'url', coalesce(d.url,'')));
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'encontrado', true,
    'activo', c.activo,
    'observacionCoordinador', v_obs,
    'mensaje', case when c.activo then 'Activo habilitado para registro.'
                    when v_obs <> '' then 'No estas habilitado para registrar. Motivo: ' || v_obs
                    else 'La persona no esta activa para registro.' end,
    'requierePlaca', (coalesce(btrim(c.placa_moto),'') = ''),
    'datos', jsonb_build_object(
      'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
      'proyecto_id', coalesce(c.proyecto_id,''), 'proyecto', proy,
      'proyecto_nomina', coalesce(c.proyecto,''),
      'trasladado', coalesce(btrim(c.proyecto_operativo),'') <> '',
      'ciudad', coalesce(c.ciudad,''), 'placa_moto', coalesce(c.placa_moto,''),
      'tipo_vehiculo', coalesce(c.tipo_vehiculo,'')
    ),
    'formulariosRequeridos', coalesce((
      select jsonb_agg(jsonb_build_object('id_formulario', frm.id, 'nombre_formulario', frm.nombre) order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy), '[]'::jsonb),
    'estadoDiario', estado,
    'documentos', docs
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 6) Los días exigibles se calculan en el proyecto donde labora
-- ------------------------------------------------------------
create or replace function dias_exigibles(desde date, hasta date, proy text default '')
returns table(cedula text, proyecto text, dias int)
language sql stable security definer set search_path = public as $fn$
  with defecto as (
    select
      coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
               '{1,2,3,4,5,6}'::smallint[]) as dias_def,
      coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false) as fest_def
  ),
  activos as (
    select c.cedula, regexp_replace(c.cedula,'\D','','g') ced_n,
           coalesce(nullif(c.proyecto_efectivo,''),'Sin proyecto') proyecto
    from colaboradores c
    where c.activo
      and (proy='' or c.proyecto_efectivo=proy or c.proyecto_id::text=proy)
  ),
  cal as (
    select a.cedula, a.ced_n, a.proyecto,
           coalesce(pc.dias_laborales, d.dias_def) dias_lab,
           coalesce(pc.labora_festivos, d.fest_def) fest
    from activos a
    cross join defecto d
    left join proyectos_calendario pc on pc.proyecto = a.proyecto
  ),
  fechas as (
    select g::date f, extract(isodow from g)::smallint dow
    from generate_series(desde, hasta, interval '1 day') g
  )
  select c.cedula, c.proyecto, count(*)::int
  from cal c
  join fechas f on f.dow = any(c.dias_lab)
  where (c.fest or not exists (select 1 from festivos x where x.fecha = f.f))
    and not exists (
      select 1 from justificaciones j
      where regexp_replace(j.cedula,'\D','','g') = c.ced_n
        and f.f between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha)
    )
  group by c.cedula, c.proyecto;
$fn$;

revoke all on function dias_exigibles(date,date,text) from public, anon;
grant execute on function dias_exigibles(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 7) La actualización de matriz respeta provisionales y traslados
-- ------------------------------------------------------------
create or replace function matriz_cerrar_actualizacion(presentes text[])
returns int language plpgsql security definer set search_path = public as $fn$
declare
  hoy text := to_char((now() at time zone 'America/Bogota')::date, 'YYYY-MM-DD');
  n int;
begin
  -- Quien ya venia en la nomina deja de ser provisional.
  update colaboradores set
    provisional = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Confirmado en la matriz del ' || hoy || '.', ' |'),
    actualizado_en = now()
  where provisional
    and regexp_replace(cedula,'\D','','g') = any(presentes);

  -- Inactivar a quien no aparezca, SIN tocar los provisionales
  -- (ellos entraron despues del corte de nomina).
  update colaboradores set activo = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Inactivada el ' || hoy || ': no aparece en la matriz cargada.', ' |'),
    actualizado_en = now()
  where activo
    and not provisional
    and not (regexp_replace(cedula,'\D','','g') = any(presentes));
  get diagnostics n = row_count;
  return n;
end;
$fn$;

-- ------------------------------------------------------------
--  Comprobación
-- ------------------------------------------------------------
-- select cedula, nombre, proyecto, proyecto_operativo, proyecto_efectivo, provisional
--   from colaboradores
--  where provisional or coalesce(proyecto_operativo,'') <> '';

-- ------------------------------------------------------------
-- 8) La actualización de matriz usa el cierre que respeta
--    provisionales, y nunca pisa el proyecto operativo.
-- ------------------------------------------------------------
create or replace function api_actualizar_matriz(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
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

  -- Confirma los provisionales que ya llegaron en la nomina e inactiva
  -- a los ausentes, sin tocar a los provisionales pendientes.
  c_inact := matriz_cerrar_actualizacion(presentes);

  insert into config (clave, valor) values ('MATRIZ_ULTIMA_ACTUALIZACION', hoy)
    on conflict (clave) do update set valor = excluded.valor;
  insert into historial (tipo, cedula, detalle)
  values ('ACTUALIZACION_MATRIZ', '', 'Actualizados ' || c_act || ', nuevos ' || c_new || ', inactivados ' || c_inact);

  return jsonb_build_object('actualizados', c_act, 'nuevos', c_new, 'inactivados', c_inact,
    'provisionales', (select count(*) from colaboradores where provisional and activo),
    'totalEnData', coalesce(array_length(presentes,1),0), 'fecha', hoy);
end;
$fn$;


-- ------------------------------------------------------------
-- 9) El cumplimiento personal se mide en el proyecto donde labora
-- ------------------------------------------------------------
create or replace function api_mi_cumplimiento(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  hoy date := (now() at time zone 'America/Bogota')::date;
  anio int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes  int := coalesce(nullif(payload->>'mes','')::int, extract(month from hoy)::int);
  desde date; hasta date;
  c colaboradores%rowtype;
  proy text;
  dias_lab smallint[]; fest boolean; meta numeric;
  formularios int;
  dias int := 0;
  esperados int; realizados int;
  pct numeric;
  racha int := 0;
  d date;
  exigible boolean;
  hechos int;
  ultimo date;
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  select * into c from colaboradores
   where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');

  desde := make_date(anio, mes, 1);
  hasta := least((desde + interval '1 month - 1 day')::date, hoy);
  if hasta < desde then
    return jsonb_build_object('sin_datos', true, 'mensaje', 'Ese mes todavia no empieza.');
  end if;

  select coalesce(pc.dias_laborales,
           coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
                    '{1,2,3,4,5,6}'::smallint[])),
         coalesce(pc.labora_festivos,
           coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false)),
         coalesce(pc.meta, 90)
    into dias_lab, fest, meta
    from (select 1) z
    left join proyectos_calendario pc on pc.proyecto = proy;

  dias_lab := coalesce(dias_lab, '{1,2,3,4,5,6}'::smallint[]);
  fest := coalesce(fest, false);
  meta := coalesce(meta, 90);

  select count(*) into formularios
    from proyectos_formularios pf
    join formularios f on f.id = pf.formulario_id and f.activo
   where pf.proyecto = proy and pf.activo;

  if formularios = 0 then
    return jsonb_build_object('sin_datos', true,
      'mensaje', 'Tu proyecto no tiene formularios asignados, asi que no se te exige registro.');
  end if;

  select count(*) into dias
    from generate_series(desde, hasta, interval '1 day') g
   where extract(isodow from g)::smallint = any(dias_lab)
     and (fest or not exists (select 1 from festivos x where x.fecha = g::date))
     and not exists (
       select 1 from justificaciones j
        where regexp_replace(j.cedula,'\D','','g') = ncedula
          and g::date between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha));

  esperados := dias * formularios;

  select count(*) into realizados
    from registros r
   where regexp_replace(r.cedula,'\D','','g') = ncedula
     and r.fecha between desde and hasta
     and coalesce(r.estado,'') <> 'ANULADO';

  pct := case when esperados > 0 then round(realizados * 100.0 / esperados, 1) else 0 end;

  select max(fecha) into ultimo from registros
   where regexp_replace(cedula,'\D','','g') = ncedula and coalesce(estado,'') <> 'ANULADO';

  d := hoy;
  loop
    exit when d < hoy - 120;
    exigible := extract(isodow from d)::smallint = any(dias_lab)
      and (fest or not exists (select 1 from festivos x where x.fecha = d))
      and not exists (select 1 from justificaciones j
                       where regexp_replace(j.cedula,'\D','','g') = ncedula
                         and d between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha));
    if exigible then
      select count(*) into hechos from registros
       where regexp_replace(cedula,'\D','','g') = ncedula
         and fecha = d and coalesce(estado,'') <> 'ANULADO';
      if hechos >= formularios then racha := racha + 1;
      elsif d = hoy then null;
      else exit;
      end if;
    end if;
    d := d - 1;
  end loop;

  return jsonb_build_object(
    'nombre', coalesce(c.nombre,''),
    'proyecto', proy,
    'anio', anio, 'mes', mes,
    'dias_exigibles', dias,
    'formularios', formularios,
    'esperados', esperados,
    'realizados', realizados,
    'porcentaje', pct,
    'meta', meta,
    'en_meta', pct >= meta,
    'racha', racha,
    'ultimo_registro', to_char(ultimo, 'YYYY-MM-DD')
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 10) El registro diario se exige y se guarda en el proyecto
--     donde el colaborador está laborando.
--     Incluye el soporte de registro sin señal, para que este
--     script sirva tanto si ya se ejecutó registro_diferido.sql
--     como si no.
-- ------------------------------------------------------------
alter table registros
  add column if not exists capturado_en timestamptz,
  add column if not exists diferido boolean not null default false;

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
  if coalesce(btrim(c.proyecto_operativo),'') <> '' then
    alertas_doc := alertas_doc || 'Trasladado desde ' || coalesce(c.proyecto,'(sin proyecto)') || ' | ';
  end if;
  alertas_doc := rtrim(alertas_doc, ' |');

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
