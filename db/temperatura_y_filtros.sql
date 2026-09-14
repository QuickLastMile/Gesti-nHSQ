-- ============================================================
--  Temperatura por cargo, y los filtros por linea
--  ------------------------------------------------------------
--  Junta cuatro cosas que se pidieron seguidas:
--
--  1) La temperatura la mide el CONDUCTOR, no el mensajero. Un
--     formulario se habilitaba por proyecto y lo veia todo el mundo
--     de ese proyecto; ahora puede limitarse a un cargo.
--
--  2) Manana y tarde se veian como dos formularios sueltos. Con
--     'grupo' y 'etiqueta' se pintan como una fila con dos botones.
--
--  3) Los desplegables de proyecto y formulario de Cumplimiento y
--     del Dashboard no filtraban por linea: entrando como Warehouse
--     salia la lista de Last Mile. Las consultas SI filtraban -no se
--     escapo informacion- pero el desplegable mostraba nombres
--     ajenos.
--
--  4) El filtro de formulario mostraba las jornadas por separado.
--     Ahora es una sola opcion y el tablero suma las dos.
--
--  El exportable sigue jornada por jornada a proposito: el CSV saca
--  una columna por pregunta y cada jornada tiene las suyas.
--
--  Ejecutar DESPUES de db/lineas_3_lecturas.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================
-- ------------------------------------------------------------
--  1) Las columnas nuevas
-- ------------------------------------------------------------
-- MOTO / VEHICULO, o vacio para los que ve todo el proyecto.
alter table formularios add column if not exists aplica_a text;
-- Formularios que se presentan juntos, como jornadas de lo mismo.
alter table formularios add column if not exists grupo text;
-- El nombre corto del boton dentro del grupo.
alter table formularios add column if not exists etiqueta text;

update formularios
   set aplica_a = 'VEHICULO', grupo = 'TEMP_HUM', etiqueta = 'Manana'
 where id = 'TEMP_HUM_AM';

update formularios
   set aplica_a = 'VEHICULO', grupo = 'TEMP_HUM', etiqueta = 'Tarde'
 where id = 'TEMP_HUM_PM';

-- El titulo del grupo va en el nombre, sin la jornada: la jornada la
-- dice el boton.
update formularios
   set nombre = 'Temperatura y humedad'
 where id in ('TEMP_HUM_AM','TEMP_HUM_PM');

-- ------------------------------------------------------------
--  2) Cuantos formularios se le exigen a un cargo ese dia
--  ------------------------------------------------------------
--  La version de dos argumentos no sabia de cargos y contaba de mas.
--  Se reemplaza para que nadie la llame por error.
-- ------------------------------------------------------------
drop function if exists formularios_exigibles_dia(text, date);

create or replace function formularios_exigibles_dia(v_proyecto text, v_fecha date, v_perfil text)
returns int language sql stable set search_path = public as $fn$
  select count(*)::int
    from proyectos_formularios pf
    join formularios f on f.id = pf.formulario_id and f.activo
   where pf.proyecto = coalesce(v_proyecto,'')
     and pf.activo
     and (f.aplica_a is null or f.aplica_a = v_perfil)
     and (pf.frecuencia <> 'SEMANAL'
          or extract(isodow from v_fecha)::smallint = pf.dia_semana);
$fn$;
-- ------------------------------------------------------------
--  1) Que formularios cubre el filtro
--  ------------------------------------------------------------
--  Devuelve null cuando no hay filtro. Si el valor es un grupo, se
--  expande a sus jornadas; si no, es un formulario suelto.
-- ------------------------------------------------------------
create or replace function formularios_del_filtro(p_valor text)
returns text[] language sql stable set search_path = public as $fn$
  select case
    when upper(coalesce(btrim(p_valor),'')) in ('', 'TODOS') then null
    else coalesce(
      (select array_agg(f.id) from formularios f
        where f.activo and f.grupo = btrim(p_valor)),
      array[upper(btrim(p_valor))])
  end;
$fn$;

-- ------------------------------------------------------------
--  2) Los desplegables de proyecto y formulario
--  ------------------------------------------------------------
--  Solo lo llaman Cumplimiento y el Dashboard, que siempre tienen
--  sesion; el mensajero no pasa por aqui.
-- ------------------------------------------------------------
-- Ojo: esta funcion antes no recibia parametros. 'create or replace' no
-- reemplaza una firma por otra, crea una segunda; las dos se podrian
-- llamar sin argumentos y Postgres responderia "is not unique".
drop function if exists api_get_bootstrap();
create or replace function api_get_bootstrap(payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  with lin as (select linea_efectiva(coalesce(payload->>'linea','')) as id)
  select jsonb_build_object(
    -- Las jornadas de un mismo grupo son UNA opcion: al elegirla, el
    -- tablero suma las dos. El valor es el grupo, no el formulario.
    'formularios', coalesce((
      select jsonb_agg(x.opcion order by x.orden)
      from (
        select min(f.orden) as orden,
               jsonb_build_object(
                 'id_formulario', coalesce(nullif(f.grupo,''), f.id),
                 'nombre_formulario', f.nombre) as opcion
          from formularios f, lin
         where f.activo and exists (
                 select 1 from proyectos_formularios pf
                 join colaboradores c on c.proyecto = pf.proyecto and c.activo
                                      and c.linea = lin.id
                 where pf.formulario_id = f.id and pf.activo)
         group by coalesce(nullif(f.grupo,''), f.id), f.nombre
      ) x), '[]'::jsonb),
    -- Suelta, jornada por jornada: la usa el exportable, que saca un
    -- archivo por formulario.
    'formularios_detalle', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id_formulario', f.id,
               'nombre_formulario', f.nombre
                 || case when coalesce(f.etiqueta,'') <> '' then ' - ' || f.etiqueta else '' end)
             order by f.orden)
      from formularios f, lin
      where f.activo and exists (
              select 1 from proyectos_formularios pf
              join colaboradores c on c.proyecto = pf.proyecto and c.activo
                                   and c.linea = lin.id
              where pf.formulario_id = f.id and pf.activo)), '[]'::jsonb),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object('proyecto_id', p.proyecto_id, 'proyecto', p.proyecto))
      from (select distinct c.proyecto_id, c.proyecto
            from colaboradores c, lin
            where c.activo and coalesce(c.proyecto,'') <> ''
              and c.linea = lin.id
              and exists (
                select 1 from proyectos_formularios pf
                join formularios f on f.id=pf.formulario_id and f.activo
                where pf.proyecto=c.proyecto and pf.activo
              )
            order by c.proyecto) p), '[]'::jsonb)
  );
$fn$;

-- ------------------------------------------------------------
--  Lo que se le pide al mensajero
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  puede boolean;
  v_perfil text;
  v_estado jsonb := '{}'::jsonb;
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
  puede := c.activo and cargo_aplica(c.cargo);
  v_perfil := perfil_cargo(c.cargo);

  if puede then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
        -- Hay formularios de un solo cargo: la temperatura la mide el
        -- conductor, no el mensajero.
        and (frm.aplica_a is null or frm.aplica_a = v_perfil)
        -- Un formulario semanal solo aparece el dia que le toca.
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from hoy)::smallint = pf.dia_semana)
      order by frm.orden
    loop
      select to_char(reg.hora,'HH24:MI') as h, reg.id::text as rid into r
        from registros reg
       where regexp_replace(reg.cedula,'\D','','g') = ncedula
         and reg.formulario_id = f.id
         and reg.fecha = hoy
         and coalesce(reg.estado,'') <> 'ANULADO'
       limit 1;
      if found then
        v_estado := v_estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        v_estado := v_estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
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
    'activo', puede,
    'observacionCoordinador', v_obs,
    'mensaje', case
      when puede then 'Activo habilitado para registro.'
      when not cargo_aplica(c.cargo) then
        'Tu cargo (' || coalesce(c.cargo,'sin cargo') || ') no requiere diligenciar estos formularios.'
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
      select jsonb_agg(jsonb_build_object(
               'id_formulario', frm.id, 'nombre_formulario', frm.nombre,
               -- Los del mismo grupo se pintan como una sola fila con un
               -- boton por jornada.
               'grupo', coalesce(frm.grupo,''), 'etiqueta', coalesce(frm.etiqueta,''))
             order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy and puede
        and (frm.aplica_a is null or frm.aplica_a = v_perfil)
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from hoy)::smallint = pf.dia_semana)), '[]'::jsonb),
    'estadoDiario', v_estado,
    'documentos', docs
  );
end;
$fn$;

-- ------------------------------------------------------------
--  Cumplimiento del dia
-- ------------------------------------------------------------
create or replace function api_cumplimiento_dia(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  dia date := coalesce(nullif(payload->>'fecha','')::date, (now() at time zone 'America/Bogota')::date);
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  enc_jef text := btrim(coalesce(payload->>'jefatura',''));
  enc_lid text := btrim(coalesce(payload->>'lider',''));
  enc_coo text := btrim(coalesce(payload->>'coordinador',''));
  enc_hay boolean := (btrim(coalesce(payload->>'jefatura','')) <> ''
                   or btrim(coalesce(payload->>'lider','')) <> ''
                   or btrim(coalesce(payload->>'coordinador','')) <> '');
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  forms jsonb;
  personas jsonb := '[]'::jsonb;
  total int := 0; completos int := 0; justificados int := 0;
  rec record; f record;
  estados jsonb; hechos int; nforms int;
  h text; jt text; jm text; es_just boolean; es_completo boolean;
  alertas_persona text;
begin
  forms := coalesce((
    select jsonb_agg(jsonb_build_object('id', frm.id, 'nombre', frm.nombre) order by frm.orden)
    from formularios frm
    where frm.activo and exists (
      select 1 from proyectos_formularios pf
      join colaboradores c on c.proyecto_efectivo=pf.proyecto and c.activo and c.linea = v_linea
      where pf.formulario_id=frm.id and pf.activo
        and (frm.aplica_a is null or frm.aplica_a = perfil_cargo(c.cargo))
        -- Columnas del dia: un formulario semanal solo el dia que le toca.
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from dia)::smallint = pf.dia_semana)
        and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
    )), '[]'::jsonb);

  for rec in
    select c.cedula, c.nombre, c.proyecto_efectivo as proyecto, c.ciudad, c.placa_moto,
           perfil_cargo(c.cargo) as perfil
    from colaboradores c
    where c.activo and c.linea = v_linea and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
      and exists (
        select 1 from proyectos_formularios pf
        join formularios frm on frm.id=pf.formulario_id and frm.activo
        where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
          and (frm.aplica_a is null or frm.aplica_a = perfil_cargo(c.cargo))
          -- Si hoy no se le exige ningun formulario, no es un pendiente.
          and (pf.frecuencia <> 'SEMANAL'
               or extract(isodow from dia)::smallint = pf.dia_semana)
      )
    order by c.nombre
  loop
    estados := '{}'::jsonb; hechos := 0; nforms := 0; alertas_persona := '';
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto=coalesce(rec.proyecto,'')
        and (frm.aplica_a is null or frm.aplica_a = rec.perfil)
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from dia)::smallint = pf.dia_semana)
      order by frm.orden
    loop
      nforms := nforms + 1;
      h := null;
      select to_char(r.hora,'HH24:MI') into h from registros r
        where regexp_replace(r.cedula,'\D','','g') = regexp_replace(rec.cedula,'\D','','g')
          and r.formulario_id = f.id and r.fecha = dia
          and coalesce(r.estado,'') <> 'ANULADO' limit 1;
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
        and r.fecha = dia and coalesce(r.alertas,'') <> ''
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id);

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
--  El dashboard: por cargo, y sumando las jornadas del grupo
-- ------------------------------------------------------------
create or replace function api_dashboard(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  dia_f date := nullif(payload->>'dia','')::date;
  anio_f int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes_f int := nullif(payload->>'mes','')::int;
  proy text := btrim(coalesce(payload->>'proyecto',''));
  enc_jef text := btrim(coalesce(payload->>'jefatura',''));
  enc_lid text := btrim(coalesce(payload->>'lider',''));
  enc_coo text := btrim(coalesce(payload->>'coordinador',''));
  enc_hay boolean := (btrim(coalesce(payload->>'jefatura','')) <> ''
                   or btrim(coalesce(payload->>'lider','')) <> ''
                   or btrim(coalesce(payload->>'coordinador','')) <> '');
  form_f text := upper(btrim(coalesce(payload->>'formulario','PREOPERACIONAL')));
  desde date;
  hasta date;
  ndias int;
  activos int;
  realizadas bigint;
  esperadas bigint;
  prev_desde date;
  prev_hasta date;
  prev_realizadas bigint;
  prev_esperadas bigint;
  prev_alertas bigint;
  meta_def numeric;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  -- El filtro puede traer un formulario o un grupo de jornadas.
  v_forms text[];
begin
  select coalesce((select valor::numeric from config where clave='META_DEFECTO'), 90) into meta_def;
  if dia_f is not null then
    desde := dia_f; hasta := dia_f;
    anio_f := extract(year from dia_f)::int;
    mes_f := extract(month from dia_f)::int;
  else
    desde := case when mes_f is null then make_date(anio_f,1,1) else make_date(anio_f,mes_f,1) end;
    hasta := case when mes_f is null then make_date(anio_f,12,31) else (desde + interval '1 month - 1 day')::date end;
    hasta := least(hasta,hoy);
    if hasta < desde then hasta := desde; end if;
  end if;
  ndias := greatest((hasta-desde)+1,0);

  if form_f = '' or form_f = 'TODOS' then form_f := ''; end if;
  v_forms := formularios_del_filtro(form_f);

  -- Dias realmente exigibles: respeta el calendario de cada proyecto
  -- (dias laborales y festivos) y descuenta las justificaciones.
  drop table if exists tmp_calendario;
  create temporary table tmp_calendario on commit drop as
    select * from dias_calendario_colaborador(desde, hasta, proy);

  -- Recortar aqui alcanza para todo lo que sale del calendario:
  -- tmp_dias, tmp_exig, tmp_requeridos y tmp_just cuelgan de esta tabla.
  delete from tmp_calendario tc
   where not exists (select 1 from colaboradores c
                      where c.cedula = tc.cedula and c.linea = v_linea);

  drop table if exists tmp_dias;
  create temporary table tmp_dias on commit drop as
    select cedula, proyecto, count(*)::int dias
    from tmp_calendario
    where not justificado
    group by cedula, proyecto;

  -- Asignaciones vigentes de cada colaborador. Excluye por completo los
  -- proyectos sin formularios, incluso si todavía tienen personal activo.
  drop table if exists tmp_asignados;
  create temporary table tmp_asignados on commit drop as
    select c.cedula, c.proyecto_efectivo as proyecto, pf.formulario_id,
           pf.frecuencia, pf.dia_semana
    from colaboradores c
    join proyectos_formularios pf on pf.proyecto=c.proyecto_efectivo and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
     and (f.aplica_a is null or f.aplica_a = perfil_cargo(c.cargo))
    where c.activo and c.linea = v_linea
      and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
      and (v_forms is null or pf.formulario_id = any(v_forms));

  -- Una fila por persona, DIA y formulario realmente exigible. De aqui
  -- salen todas las esperadas. Un formulario semanal solo aporta los dias
  -- de la semana que le tocan, no todo el calendario.
  drop table if exists tmp_exig;
  create temporary table tmp_exig on commit drop as
    select tc.cedula, tc.proyecto, tc.fecha, a.formulario_id
    from tmp_calendario tc
    join tmp_asignados a on a.cedula = tc.cedula
    where not tc.justificado
      and (a.frecuencia <> 'SEMANAL'
           or extract(isodow from tc.fecha)::smallint = a.dia_semana);
  create index on tmp_exig (cedula);
  create index on tmp_exig (fecha);

  -- Una fila por colaborador + formulario + días realmente exigibles.
  drop table if exists tmp_requeridos;
  create temporary table tmp_requeridos on commit drop as
    select cedula, proyecto, formulario_id, count(*)::int as dias
    from tmp_exig
    group by cedula, proyecto, formulario_id;

  -- Dias que NO se exigieron por estar justificados. Se cuentan aparte
  -- porque ya vienen descontados de las esperadas: sin este dato no se
  -- sabe si un proyecto tiene poco esperado por calendario o por permisos.
  drop table if exists tmp_just;
  create temporary table tmp_just on commit drop as
    select tc.cedula, count(*) filter (where tc.justificado)::bigint dias_just
    from tmp_calendario tc
    group by tc.cedula;

  -- Encargados y dias exigibles de cada persona, para agrupar por nivel.
  drop table if exists tmp_enc;
  create temporary table tmp_enc on commit drop as
    select a.cedula,
           coalesce(nullif(btrim(c.enc_jefatura),''),'Sin asignar')    as jefatura,
           coalesce(nullif(btrim(c.enc_lider),''),'Sin asignar')       as lider,
           coalesce(nullif(btrim(c.enc_coordinador),''),'Sin asignar') as coordinador,
           coalesce(sum(t.dias),0)::bigint as esperadas,
           coalesce(max(j.dias_just),0)::bigint as justificados
    from tmp_asignados a
    join colaboradores c on c.cedula = a.cedula
    left join tmp_requeridos t on t.cedula = a.cedula and t.formulario_id = a.formulario_id
    left join tmp_just j on j.cedula = a.cedula
    group by a.cedula, c.enc_jefatura, c.enc_lider, c.enc_coordinador;

  -- Registros del periodo, contados por persona.
  drop table if exists tmp_reg_ced;
  create temporary table tmp_reg_ced on commit drop as
    select regexp_replace(r.cedula,'\D','','g') as ced,
           count(*) as realizadas,
           count(*) filter (where coalesce(r.alertas,'')<>'') as con_alerta
    from registros r
    where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
      and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
      and (v_forms is null or r.formulario_id = any(v_forms))
    group by 1;

  select count(distinct cedula) into activos from tmp_asignados;
  select coalesce(sum(dias),0)::bigint into esperadas from tmp_requeridos;
  select count(*) into realizadas from registros r
   where r.fecha between desde and hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (v_forms is null or r.formulario_id = any(v_forms))
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula));

  -- Periodo inmediatamente anterior, con la misma cantidad de dias y las
  -- mismas reglas de calendario, festivos y justificaciones.
  prev_hasta := desde - 1;
  prev_desde := prev_hasta - greatest(ndias - 1, 0);
  select count(*) into prev_realizadas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (v_forms is null or r.formulario_id = any(v_forms))
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula));
  -- El periodo anterior se mide con la misma regla de frecuencia, si no la
  -- comparacion contra el periodo previo quedaria inflada.
  select count(*)::bigint into prev_esperadas
    from dias_calendario_colaborador(prev_desde, prev_hasta, proy) dc
    join colaboradores c2 on c2.cedula = dc.cedula and c2.linea = v_linea
    join proyectos_formularios pf on pf.proyecto=dc.proyecto and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where not dc.justificado
      and (v_forms is null or pf.formulario_id = any(v_forms))
      and (pf.frecuencia <> 'SEMANAL'
           or extract(isodow from dc.fecha)::smallint = pf.dia_semana)
      and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, dc.cedula));
  select count(*) into prev_alertas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and coalesce(r.alertas,'')<>'' and (v_forms is null or r.formulario_id = any(v_forms))
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula));

  return jsonb_build_object(
    'filtros',jsonb_build_object('anio',anio_f,'mes',mes_f,'dia',dia_f,'proyecto',proy,'formulario',form_f,
      'desde',desde,'hasta',hasta,'dias',ndias),
    'resumen',jsonb_build_object(
      'activos',activos,'realizadas',realizadas,'esperadas',esperadas,
      -- Trazabilidad del calculo: dias-persona exigibles y cuantos se justificaron.
      'dias_persona',(select coalesce(sum(dias),0) from (
        select cedula,max(dias) dias from tmp_requeridos group by cedula
      ) dp),
      'meta',meta_def,
      'justificados',(select count(*) from justificaciones j
         where j.fecha_inicio <= hasta and coalesce(j.fecha_fin,j.fecha_inicio) >= desde
           and exists (select 1 from tmp_asignados a
             where regexp_replace(a.cedula,'\D','','g')=regexp_replace(j.cedula,'\D','','g'))),
      'anterior',jsonb_build_object(
        'desde',prev_desde,'hasta',prev_hasta,'activos',activos,
        'realizadas',prev_realizadas,'esperadas',prev_esperadas,
        'no_realizadas',greatest(prev_esperadas-prev_realizadas,0),
        'porcentaje',case when prev_esperadas>0 then round(prev_realizadas::numeric*1000/prev_esperadas)/10 else 0 end,
        'con_alerta',prev_alertas),
      'no_realizadas',greatest(esperadas-realizadas,0),
      'porcentaje',case when esperadas>0 then round(realizadas::numeric*1000/esperadas)/10 else 0 end,
      'con_alerta',(select count(*) from registros r where r.fecha between desde and hasta
        and coalesce(r.alertas,'')<>'' and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula)))
    ),

    -- Solo dias CON registros.
    'por_dia',coalesce((select jsonb_agg(x order by x.fecha) from (
      select r.fecha, count(*) realizadas,
             count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by r.fecha
    ) x),'[]'::jsonb),

    -- Serie diaria de CUMPLIMIENTO: incluye los dias exigibles en los que
    -- nadie registro, que son justamente los que hay que ver. No reemplaza a
    -- 'por_dia', que sigue mostrando solo los dias con actividad.
    'por_dia_cumplimiento',coalesce((select jsonb_agg(x order by x.fecha) from (
      select d.fecha,
             d.esperadas,
             coalesce(reg.realizadas,0) realizadas,
             coalesce(reg.con_alerta,0) con_alerta
      from (
        select te.fecha, count(*)::bigint esperadas
        from tmp_exig te
        group by te.fecha
      ) d
      left join (
        select r.fecha, count(*) realizadas,
               count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
        from registros r
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (v_forms is null or r.formulario_id = any(v_forms))
          and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
          and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
        group by r.fecha
      ) reg on reg.fecha = d.fecha
    ) x),'[]'::jsonb),

    -- Solo meses CON registros (del anio seleccionado).
    'por_mes',coalesce((select jsonb_agg(x order by x.mes) from (
      select to_char(r.fecha,'YYYY-MM') mes, count(*) realizadas
      from registros r
      where extract(year from r.fecha)=anio_f and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by to_char(r.fecha,'YYYY-MM')
    ) x),'[]'::jsonb),

    'por_anio',coalesce((select jsonb_agg(x order by x.anio) from (
      select extract(year from r.fecha)::int anio,count(*) realizadas
      from registros r where coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
       and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
       and (v_forms is null or r.formulario_id = any(v_forms))
       and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by extract(year from r.fecha)
    ) x),'[]'::jsonb),

    -- Cumplimiento por proyecto: realizadas vs esperadas segun activos del proyecto.
    'por_proyecto',coalesce((select jsonb_agg(x order by x.porcentaje desc, x.proyecto) from (
      select p.proyecto, p.activos, p.esperadas, p.justificados,
             coalesce(reg.realizadas,0) realizadas,
             coalesce(reg.con_alerta,0) con_alerta,
             greatest(p.esperadas-coalesce(reg.realizadas,0),0) no_realizadas,
             coalesce(pc.meta, meta_def) meta,
             case when p.esperadas>0
                  then round(coalesce(reg.realizadas,0)::numeric*1000/p.esperadas)/10 else 0 end porcentaje,
             -- Semaforo: cumple la meta, esta cerca (>=80% de la meta) o no cumple.
             case when p.esperadas=0 then 'sin_datos'
                  when round(coalesce(reg.realizadas,0)::numeric*1000/p.esperadas)/10 >= coalesce(pc.meta, meta_def) then 'cumple'
                  when round(coalesce(reg.realizadas,0)::numeric*1000/p.esperadas)/10 >= coalesce(pc.meta, meta_def)*0.8 then 'cerca'
                  else 'no_cumple' end estado
      from (
        -- Esperadas segun el calendario del proyecto y sin dias justificados.
        select a.proyecto, count(distinct a.cedula) activos,
               coalesce(sum(t.dias),0)::bigint esperadas,
               -- Una sola vez por persona, aunque tenga varios formularios.
               coalesce((select sum(j.dias_just)
                           from tmp_just j
                          where j.cedula in (select distinct a2.cedula from tmp_asignados a2
                                              where a2.proyecto = a.proyecto)),0)::bigint justificados
        from tmp_asignados a
        left join tmp_requeridos t on t.cedula=a.cedula and t.formulario_id=a.formulario_id
        group by a.proyecto
      ) p
      left join (
        select coalesce(r.proyecto,'Sin proyecto') proyecto, count(*) realizadas,
               count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
        from registros r
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (v_forms is null or r.formulario_id = any(v_forms))
          and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
        group by coalesce(r.proyecto,'Sin proyecto')
      ) reg on reg.proyecto=p.proyecto
      left join proyectos_calendario pc on pc.proyecto=p.proyecto
    ) x),'[]'::jsonb),

    -- Ranking de mensajeros (incluye a los que no registraron nada).
    'mensajeros',coalesce((select jsonb_agg(x order by x.porcentaje desc, x.realizadas desc, x.nombre) from (
      select c.cedula, coalesce(c.nombre,'') nombre, coalesce(c.proyecto_efectivo,'Sin proyecto') proyecto,
             coalesce(c.placa_moto,'') placa,
             coalesce(reg.realizadas,0) realizadas,
             coalesce(req.esperadas,0)::bigint esperadas,
             coalesce(reg_dias.dias_diligenciados,0)::int dias_diligenciados,
             coalesce(td.dias,0)::int dias_exigibles,
             coalesce(jus.dias_justificados,0)::int dias_justificados,
             case when coalesce(td.dias,0)>0
                  then least(round(coalesce(reg_dias.dias_diligenciados,0)::numeric*1000/td.dias)/10,100)
                  else null end porcentaje_dias,
             coalesce(reg.con_alerta,0) con_alerta,
             coalesce(reg.ultimo,null) ultimo_registro,
             case when coalesce(req.esperadas,0)>0
                  then round(coalesce(reg.realizadas,0)::numeric*1000/req.esperadas)/10 else 0 end porcentaje
      from colaboradores c
      left join tmp_dias td on td.cedula = c.cedula
      left join (
        select a.cedula, coalesce(sum(t.dias),0)::bigint esperadas
        from tmp_asignados a
        left join tmp_requeridos t on t.cedula=a.cedula and t.formulario_id=a.formulario_id
        group by a.cedula
      ) req on req.cedula=c.cedula
      left join (
        select regexp_replace(r.cedula,'\D','','g') ced, count(*) realizadas,
               count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta,
               max(r.fecha) ultimo
        from registros r
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (v_forms is null or r.formulario_id = any(v_forms))
        group by regexp_replace(r.cedula,'\D','','g')
      ) reg on reg.ced = regexp_replace(c.cedula,'\D','','g')
      left join (
        select regexp_replace(tc.cedula,'\D','','g') ced, count(*)::int dias_diligenciados
        from tmp_calendario tc
        where not tc.justificado
          -- Un dia cuenta como diligenciado si se hizo TODO lo que ese dia
          -- se pedia; un formulario que no tocaba no lo deja incompleto.
          and exists (select 1 from tmp_exig tr
                       where tr.cedula=tc.cedula and tr.fecha=tc.fecha)
          and not exists (
            select 1 from tmp_exig tr
            where tr.cedula=tc.cedula and tr.fecha=tc.fecha
              and not exists (
                select 1 from registros r
                where regexp_replace(r.cedula,'\D','','g')=regexp_replace(tc.cedula,'\D','','g')
                  and r.fecha=tc.fecha and r.formulario_id=tr.formulario_id
                  and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
              )
          )
        group by regexp_replace(tc.cedula,'\D','','g')
      ) reg_dias on reg_dias.ced = regexp_replace(c.cedula,'\D','','g')
      left join (
        select regexp_replace(tc.cedula,'\D','','g') ced,
               count(*) filter (where tc.justificado)::int dias_justificados
        from tmp_calendario tc
        group by regexp_replace(tc.cedula,'\D','','g')
      ) jus on jus.ced = regexp_replace(c.cedula,'\D','','g')
      where c.activo and c.linea = v_linea and req.cedula is not null
        and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
    ) x),'[]'::jsonb),

    -- Cumplimiento por tipo de formulario (preoperacional vs limpieza).
    'por_formulario',coalesce((select jsonb_agg(x order by x.nombre) from (
      select f.id, f.nombre,
             coalesce(reg.realizadas,0) realizadas,
             req.esperadas,
             case when req.esperadas>0
                  then round(coalesce(reg.realizadas,0)::numeric*1000/req.esperadas)/10
                  else 0 end porcentaje
      from (
        select formulario_id, sum(dias)::bigint esperadas
        from tmp_requeridos group by formulario_id
      ) req
      join formularios f on f.id=req.formulario_id
      left join (
        select r.formulario_id, count(*) realizadas
        from registros r
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
        group by r.formulario_id
      ) reg on reg.formulario_id=f.id
      where f.activo and (v_forms is null or f.id = any(v_forms))
    ) x),'[]'::jsonb),

    -- Patron semanal: en que dias se registra mas.
    'por_dia_semana',coalesce((select jsonb_agg(x order by x.dow) from (
      select extract(isodow from r.fecha)::int dow,
             to_char(r.fecha,'TMDay') dia,
             count(*) realizadas,
             count(distinct r.fecha) dias
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by extract(isodow from r.fecha), to_char(r.fecha,'TMDay')
    ) x),'[]'::jsonb),

    -- Franja horaria de los registros (puntualidad).
    'por_hora',coalesce((select jsonb_agg(x order by x.hora) from (
      select extract(hour from r.hora)::int hora, count(*) realizadas
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and r.hora is not null
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by extract(hour from r.hora)
    ) x),'[]'::jsonb),

    -- Mensajeros activos que llevan mas dias sin registrar (seguimiento).
    'inactividad',coalesce((select jsonb_agg(x order by x.dias_sin desc nulls first, x.nombre) from (
      select c.cedula, coalesce(c.nombre,'') nombre, coalesce(c.proyecto_efectivo,'Sin proyecto') proyecto,
             u.ultimo, case when u.ultimo is null then null else (hoy-u.ultimo) end dias_sin
      from colaboradores c
      left join (
        select regexp_replace(r.cedula,'\D','','g') ced, max(r.fecha) ultimo
        from registros r where coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (v_forms is null or r.formulario_id = any(v_forms))
        group by regexp_replace(r.cedula,'\D','','g')
      ) u on u.ced=regexp_replace(c.cedula,'\D','','g')
      where c.activo and c.linea = v_linea and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
            and (v_forms is null or pf.formulario_id = any(v_forms))
        )
        and (u.ultimo is null or hoy-u.ultimo >= 3)
      limit 60
    ) x),'[]'::jsonb),

    -- Registros del periodo que quedaron con alerta (fallas / documentos).
    'alertas_operativas',coalesce((select jsonb_agg(x order by x.fecha desc, x.nombre) from (
      select r.fecha, r.nombre, r.cedula, coalesce(r.proyecto,'Sin proyecto') proyecto,
             coalesce(r.placa_moto,'') placa, r.alertas
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and coalesce(r.alertas,'')<>''
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      limit 300
    ) x),'[]'::jsonb),

    -- Fallas marcadas según la respuesta de alerta configurada en cada pregunta.
    -- Se agrupan por componente y proyecto para orientar acciones preventivas.
    'top_fallas',coalesce((select jsonb_agg(x order by x.cantidad desc, x.pregunta, x.proyecto) from (
      select p.id pregunta_id, coalesce(p.seccion,'Sin sección') seccion, p.pregunta,
             coalesce(r.proyecto,'Sin proyecto') proyecto, count(*) cantidad,
             count(distinct regexp_replace(r.cedula,'\D','','g')) mensajeros,
             max(r.fecha) ultima_fecha,
             case when realizadas>0 then round(count(*)::numeric*1000/realizadas)/10 else 0 end porcentaje
      from respuestas rs
      join registros r on r.id=rs.registro_id
      join preguntas p on p.id=rs.pregunta_id
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (v_forms is null or r.formulario_id = any(v_forms))
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
        and nullif(btrim(coalesce(p.respuesta_alerta,'')),'') is not null
        and upper(btrim(coalesce(rs.valor,'')))=upper(btrim(p.respuesta_alerta))
      group by p.id,p.seccion,p.pregunta,coalesce(r.proyecto,'Sin proyecto')
      order by count(*) desc
      limit 20
    ) x),'[]'::jsonb),

    'alertas',coalesce((select jsonb_agg(x order by x.prioridad,x.dias_restantes,x.proyecto,x.nombre) from (
      select c.cedula,c.nombre,c.proyecto_efectivo as proyecto,c.placa_moto,d.documento,d.fecha_vencimiento,
             d.fecha_vencimiento-hoy dias_restantes,
             case when d.fecha_vencimiento is null then 'SIN FECHA'
                  when d.fecha_vencimiento<hoy then 'VENCIDO' else 'PRÓXIMO A VENCER' end estado,
             case when d.fecha_vencimiento is null or d.fecha_vencimiento<hoy then 1 else 2 end prioridad
      from colaboradores c
      cross join lateral (values ('SOAT',c.soat_vence),('TECNOMECÁNICA',c.tecnomecanica_vence),('LICENCIA',c.licencia_vence)) d(documento,fecha_vencimiento)
      where c.activo and c.linea = v_linea and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
            and (v_forms is null or pf.formulario_id = any(v_forms))
        )
        and (d.fecha_vencimiento is null or d.fecha_vencimiento<=hoy+15)
    ) x),'[]'::jsonb),
    -- Cumplimiento agrupado por jefatura, por lider y por coordinador.
    -- Cada persona aporta a los tres niveles a la vez.
    'por_encargado',coalesce((
      select jsonb_object_agg(g.nivel, g.filas)
      from (
        select z.nivel,
               jsonb_agg(jsonb_build_object(
                 'nombre', z.nombre, 'activos', z.activos,
                 'esperadas', z.esperadas, 'realizadas', z.realizadas,
                 'justificados', z.justificados,
                 'no_realizadas', greatest(z.esperadas - z.realizadas, 0),
                 'con_alerta', z.con_alerta, 'meta', meta_def,
                 'porcentaje', case when z.esperadas>0
                                    then round(z.realizadas::numeric*1000/z.esperadas)/10 else 0 end,
                 'estado', case when z.esperadas=0 then 'sin_datos'
                                when round(z.realizadas::numeric*1000/z.esperadas)/10 >= meta_def then 'cumple'
                                when round(z.realizadas::numeric*1000/z.esperadas)/10 >= meta_def*0.8 then 'cerca'
                                else 'no_cumple' end)
                 order by case when z.esperadas>0
                               then round(z.realizadas::numeric*1000/z.esperadas)/10 else 0 end desc, z.nombre) filas
        from (
          select v.nivel, v.nombre,
                 count(*) activos,
                 coalesce(sum(e.esperadas),0)::bigint esperadas,
                 coalesce(sum(e.justificados),0)::bigint justificados,
                 coalesce(sum(rc.realizadas),0)::bigint realizadas,
                 coalesce(sum(rc.con_alerta),0)::bigint con_alerta
          from tmp_enc e
          cross join lateral (values ('jefatura', e.jefatura),
                                     ('lider', e.lider),
                                     ('coordinador', e.coordinador)) v(nivel, nombre)
          left join tmp_reg_ced rc on rc.ced = regexp_replace(e.cedula,'\D','','g')
          group by v.nivel, v.nombre
        ) z
        group by z.nivel
      ) g), '{}'::jsonb),
    'actualizado',to_char(now() at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
  );
end;
$$;

-- ------------------------------------------------------------
--  La pantalla "mi cumplimiento" del mensajero
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
  nform int;
  v_perfil text;
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
  v_perfil := perfil_cargo(c.cargo);

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
   where pf.proyecto = proy and pf.activo
     and (f.aplica_a is null or f.aplica_a = v_perfil);

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

  -- Cada dia exigible pesa segun cuantos formularios se pedian ESE dia:
  -- uno semanal no suma los cinco dias que no tocaba.
  select coalesce(sum(formularios_exigibles_dia(proy, g::date, v_perfil)),0)::int into esperados
    from generate_series(desde, hasta, interval '1 day') g
   where extract(isodow from g)::smallint = any(dias_lab)
     and (fest or not exists (select 1 from festivos x where x.fecha = g::date))
     and not exists (
       select 1 from justificaciones j
        where regexp_replace(j.cedula,'\D','','g') = ncedula
          and g::date between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha));

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
      -- Un dia en el que no se pedia nada no rompe la racha ni la suma.
      nform := formularios_exigibles_dia(proy, d, v_perfil);
      if nform > 0 then
        select count(*) into hechos from registros
         where regexp_replace(cedula,'\D','','g') = ncedula
           and fecha = d and coalesce(estado,'') <> 'ANULADO';
        if hechos >= nform then racha := racha + 1;
        elsif d = hoy then null;
        else exit;
        end if;
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
--  Verificacion
-- ------------------------------------------------------------
-- a) Solo la temperatura esta limitada a un cargo, y agrupada.
select id, nombre, coalesce(aplica_a,'(todos)') as le_aplica_a,
       coalesce(grupo,'') as grupo, coalesce(etiqueta,'') as boton, activo
  from formularios order by orden;

-- b) El filtro resuelve el grupo a sus dos jornadas.
select formularios_del_filtro('TEMP_HUM')       as grupo_temperatura,
       formularios_del_filtro('PREOPERACIONAL') as un_formulario,
       formularios_del_filtro('TODOS')          as sin_filtro;

-- c) Las cinco funciones quedaron al dia.
select proname,
       case when prosrc like '%aplica_a%' or prosrc like '%v_forms%'
                 or prosrc like '%linea_efectiva%'
            then 'ACTUALIZADA' else 'SIN ACTUALIZAR' end as estado
  from pg_proc
 where proname in ('api_get_bootstrap','api_buscar_activo','api_cumplimiento_dia',
                   'api_dashboard','api_mi_cumplimiento')
 order by proname;
