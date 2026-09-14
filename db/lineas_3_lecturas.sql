-- ============================================================
--  LINEAS - Etapa 3: las lecturas se filtran por linea
--  ------------------------------------------------------------
--  Hasta ahora el desplegable solo dirigia el cargue de matriz.
--  Desde aqui manda de verdad: dashboard, cumplimiento del dia,
--  exportable y lista de encargados devuelven UNICAMENTE lo de la
--  linea activa.
--
--  El filtro NO depende de que la pantalla mande bien el dato: cada
--  funcion llama a linea_efectiva(), que valida lo pedido contra las
--  lineas permitidas del usuario y falla si no le corresponde. Un
--  usuario de Warehouse que manipule la peticion sigue sin ver
--  Last Mile.
--
--  QUE FALTA DESPUES DE ESTO (etapa 4): la pantalla de
--  Administracion -Buscar y editar, Proyectos, Calendario,
--  Formularios, Historial- todavia no filtra. Mientras tanto, no le
--  entregues a otra linea un usuario con rol ADMIN o HSEQ.
--
--  Ejecutar DESPUES de db/lineas_2_matriz.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  0) Que volver a correr la etapa 1 no vuelva universal a nadie
--  ------------------------------------------------------------
--  lineas_1_fundacion.sql pone todas_lineas = true a todo ADMIN y
--  HSEQ. Eso era para no cerrarle la puerta a quien ya existia, pero
--  si se vuelve a correr convertiria en universal al usuario de
--  Warehouse. Se marca como hecho para que no se repita.
-- ------------------------------------------------------------
insert into config (clave, valor)
values ('LINEAS_BACKFILL_ROLES', to_char(now(), 'YYYY-MM-DD HH24:MI'))
on conflict (clave) do nothing;

-- ------------------------------------------------------------
--  1) La lista de encargados, solo la de la linea
--  ------------------------------------------------------------
--  Se expone directo ademas del router: asi la pantalla puede
--  mandarle la linea del desplegable sin tener que reescribir el
--  router, que es donde mas caro sale equivocarse.
-- ------------------------------------------------------------
create or replace function api_lista_encargados(payload jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = public as $fn$
  with lin as (
    select linea_efectiva(coalesce(payload->>'linea','')) as id
  ),
  base as (
    select coalesce(nullif(btrim(c.enc_jefatura), ''), '')    as jefatura,
           coalesce(nullif(btrim(c.enc_lider), ''), '')       as lider,
           coalesce(nullif(btrim(c.enc_coordinador), ''), '') as coordinador,
           c.proyecto_efectivo
      from colaboradores c, lin
     where c.activo and cargo_aplica(c.cargo)
       and c.linea = lin.id
  )
  select jsonb_build_object(
    'jefaturas', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select jefatura nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where jefatura <> '' group by jefatura) x), '[]'::jsonb),
    'lideres', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select lider nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where lider <> '' group by lider) x), '[]'::jsonb),
    'coordinadores', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select coordinador nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where coordinador <> '' group by coordinador) x), '[]'::jsonb),
    -- Quién depende de quién, según la gente activa que hay hoy.
    'combinaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'jefatura', x.jefatura, 'lider', x.lider,
               'coordinador', x.coordinador, 'personas', x.personas)
             order by x.jefatura, x.lider, x.coordinador)
      from (select jefatura, lider, coordinador, count(*) personas
              from base group by jefatura, lider, coordinador) x), '[]'::jsonb),
    'sin_asignar', jsonb_build_object(
      'jefatura',    (select count(*) from base where jefatura = ''),
      'lider',       (select count(*) from base where lider = ''),
      'coordinador', (select count(*) from base where coordinador = ''))
  );
$fn$;

revoke all on function api_lista_encargados(jsonb) from public, anon;
grant execute on function api_lista_encargados(jsonb) to authenticated;

-- ------------------------------------------------------------
--  2) Cumplimiento del dia
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
        -- Columnas del dia: un formulario semanal solo el dia que le toca.
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from dia)::smallint = pf.dia_semana)
        and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
    )), '[]'::jsonb);

  for rec in
    select c.cedula, c.nombre, c.proyecto_efectivo as proyecto, c.ciudad, c.placa_moto
    from colaboradores c
    where c.activo and c.linea = v_linea and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
      and exists (
        select 1 from proyectos_formularios pf
        join formularios frm on frm.id=pf.formulario_id and frm.activo
        where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
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
--  3) El exportable
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
  v_linea text;
begin
  v_linea := linea_efectiva(coalesce(payload->>'linea',''));
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
     and r.linea = v_linea
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
--  4) El dashboard
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
    where c.activo and c.linea = v_linea
      and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
      and (form_f='' or pf.formulario_id=form_f);

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
      and (form_f='' or r.formulario_id=form_f)
    group by 1;

  select count(distinct cedula) into activos from tmp_asignados;
  select coalesce(sum(dias),0)::bigint into esperadas from tmp_requeridos;
  select count(*) into realizadas from registros r
   where r.fecha between desde and hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula));

  -- Periodo inmediatamente anterior, con la misma cantidad de dias y las
  -- mismas reglas de calendario, festivos y justificaciones.
  prev_hasta := desde - 1;
  prev_desde := prev_hasta - greatest(ndias - 1, 0);
  select count(*) into prev_realizadas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula));
  -- El periodo anterior se mide con la misma regla de frecuencia, si no la
  -- comparacion contra el periodo previo quedaria inflada.
  select count(*)::bigint into prev_esperadas
    from dias_calendario_colaborador(prev_desde, prev_hasta, proy) dc
    join colaboradores c2 on c2.cedula = dc.cedula and c2.linea = v_linea
    join proyectos_formularios pf on pf.proyecto=dc.proyecto and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where not dc.justificado
      and (form_f='' or pf.formulario_id=form_f)
      and (pf.frecuencia <> 'SEMANAL'
           or extract(isodow from dc.fecha)::smallint = pf.dia_semana)
      and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, dc.cedula));
  select count(*) into prev_alertas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO' and r.linea = v_linea
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and coalesce(r.alertas,'')<>'' and (form_f='' or r.formulario_id=form_f)
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
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula)))
    ),

    -- Solo dias CON registros.
    'por_dia',coalesce((select jsonb_agg(x order by x.fecha) from (
      select r.fecha, count(*) realizadas,
             count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
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
          and (form_f='' or r.formulario_id=form_f)
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
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by to_char(r.fecha,'YYYY-MM')
    ) x),'[]'::jsonb),

    'por_anio',coalesce((select jsonb_agg(x order by x.anio) from (
      select extract(year from r.fecha)::int anio,count(*) realizadas
      from registros r where coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
       and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
       and (form_f='' or r.formulario_id=form_f)
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
          and (form_f='' or r.formulario_id=form_f)
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
          and (form_f='' or r.formulario_id=form_f)
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
      where f.activo and (form_f='' or f.id=form_f)
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
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, r.cedula))
      group by extract(isodow from r.fecha), to_char(r.fecha,'TMDay')
    ) x),'[]'::jsonb),

    -- Franja horaria de los registros (puntualidad).
    'por_hora',coalesce((select jsonb_agg(x order by x.hora) from (
      select extract(hour from r.hora)::int hora, count(*) realizadas
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO' and r.linea = v_linea
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
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
          and (form_f='' or r.formulario_id=form_f)
        group by regexp_replace(r.cedula,'\D','','g')
      ) u on u.ced=regexp_replace(c.cedula,'\D','','g')
      where c.activo and c.linea = v_linea and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy)) and (not enc_hay or en_alcance_enc(enc_jef, enc_lid, enc_coo, c.cedula))
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
            and (form_f='' or pf.formulario_id=form_f)
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
        and (form_f='' or r.formulario_id=form_f)
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
        and (form_f='' or r.formulario_id=form_f)
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
            and (form_f='' or pf.formulario_id=form_f)
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
--  Verificacion
-- ------------------------------------------------------------
-- a) Las cuatro funciones ya resuelven la linea.
select proname,
       case when prosrc like '%linea_efectiva%' then 'FILTRA POR LINEA'
            else 'SIN FILTRO' end as estado
  from pg_proc
 where proname in ('api_dashboard','api_cumplimiento_dia','api_exportable','api_lista_encargados')
 order by proname;

-- b) Quien ve que. Revisa que el usuario nuevo tenga SU linea y
--    todas_lineas en false.
select email, rol, todas_lineas, lineas, activo from app_roles order by rol, email;

-- c) Cuantos registros hay por linea (Warehouse aparecera en 0 hasta
--    que cargues su matriz y empiecen a registrar).
select linea, count(*) as registros from registros group by linea order by linea;
