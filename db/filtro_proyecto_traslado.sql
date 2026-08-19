-- ============================================================
--  Gestión HSEQ Motos — El filtro por proyecto respeta el traslado
--  ------------------------------------------------------------
--  La pantalla convierte el nombre del proyecto a su CÓDIGO antes
--  de consultar, y el filtro comparaba ese código contra el
--  proyecto_id del colaborador. Pero al trasladar a alguien su
--  proyecto_id de nómina NO cambia: por eso un trasladado no
--  aparecía en el proyecto donde está laborando.
--
--  Ahora el código se traduce a nombre y la comparación es
--  siempre contra el proyecto efectivo.
--
--  Ejecutar DESPUÉS de: traslado_en_cumplimiento.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- Nombre del proyecto a partir de su código. Si lo que llega ya es
-- un nombre, devuelve null y el filtro usa el texto tal cual.
create or replace function nombre_proyecto(codigo text)
returns text language sql stable set search_path = public as $fn$
  select proyecto
    from colaboradores
   where coalesce(proyecto_id::text,'') = btrim(coalesce(codigo,''))
     and coalesce(proyecto,'') <> ''
   limit 1;
$fn$;


-- ---------- api_cumplimiento_dia ----------
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
  forms := coalesce((
    select jsonb_agg(jsonb_build_object('id', frm.id, 'nombre', frm.nombre) order by frm.orden)
    from formularios frm
    where frm.activo and exists (
      select 1 from proyectos_formularios pf
      join colaboradores c on c.proyecto_efectivo=pf.proyecto and c.activo
      where pf.formulario_id=frm.id and pf.activo
        and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy))
    )), '[]'::jsonb);

  for rec in
    select c.cedula, c.nombre, c.proyecto_efectivo as proyecto, c.ciudad, c.placa_moto
    from colaboradores c
    where c.activo and (filtro_proy='' or c.proyecto_efectivo = filtro_proy or c.proyecto_efectivo = nombre_proyecto(filtro_proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = filtro_proy))
      and exists (
        select 1 from proyectos_formularios pf
        join formularios frm on frm.id=pf.formulario_id and frm.activo
        where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
      )
    order by c.nombre
  loop
    estados := '{}'::jsonb; hechos := 0; nforms := 0; alertas_persona := '';
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto=coalesce(rec.proyecto,'')
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


-- ---------- api_dashboard ----------
create or replace function api_dashboard(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  dia_f date := nullif(payload->>'dia','')::date;
  anio_f int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes_f int := nullif(payload->>'mes','')::int;
  proy text := btrim(coalesce(payload->>'proyecto',''));
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
    select c.cedula, c.proyecto_efectivo as proyecto, pf.formulario_id
    from colaboradores c
    join proyectos_formularios pf on pf.proyecto=c.proyecto_efectivo and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where c.activo
      and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy))
      and (form_f='' or pf.formulario_id=form_f);

  -- Una fila por colaborador + formulario + días realmente exigibles.
  drop table if exists tmp_requeridos;
  create temporary table tmp_requeridos on commit drop as
    select td.cedula, td.proyecto, td.dias, a.formulario_id
    from tmp_dias td
    join tmp_asignados a on a.cedula=td.cedula;

  select count(distinct cedula) into activos from tmp_asignados;
  select coalesce(sum(dias),0)::bigint into esperadas from tmp_requeridos;
  select count(*) into realizadas from registros r
   where r.fecha between desde and hasta and coalesce(r.estado,'') <> 'ANULADO'
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy));

  -- Periodo inmediatamente anterior, con la misma cantidad de dias y las
  -- mismas reglas de calendario, festivos y justificaciones.
  prev_hasta := desde - 1;
  prev_desde := prev_hasta - greatest(ndias - 1, 0);
  select count(*) into prev_realizadas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO'
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy));
  select coalesce(sum(de.dias),0)::bigint into prev_esperadas
    from dias_exigibles(prev_desde, prev_hasta, proy) de
    join proyectos_formularios pf on pf.proyecto=de.proyecto and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where form_f='' or pf.formulario_id=form_f;
  select count(*) into prev_alertas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO'
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and coalesce(r.alertas,'')<>'' and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy));

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
        and coalesce(r.alertas,'')<>'' and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy)))
    ),

    -- Solo dias CON registros.
    'por_dia',coalesce((select jsonb_agg(x order by x.fecha) from (
      select r.fecha, count(*) realizadas,
             count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
      group by r.fecha
    ) x),'[]'::jsonb),

    -- Solo meses CON registros (del anio seleccionado).
    'por_mes',coalesce((select jsonb_agg(x order by x.mes) from (
      select to_char(r.fecha,'YYYY-MM') mes, count(*) realizadas
      from registros r
      where extract(year from r.fecha)=anio_f and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
      group by to_char(r.fecha,'YYYY-MM')
    ) x),'[]'::jsonb),

    'por_anio',coalesce((select jsonb_agg(x order by x.anio) from (
      select extract(year from r.fecha)::int anio,count(*) realizadas
      from registros r where coalesce(r.estado,'')<>'ANULADO'
       and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
       and (form_f='' or r.formulario_id=form_f)
       and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
      group by extract(year from r.fecha)
    ) x),'[]'::jsonb),

    -- Cumplimiento por proyecto: realizadas vs esperadas segun activos del proyecto.
    'por_proyecto',coalesce((select jsonb_agg(x order by x.porcentaje desc, x.proyecto) from (
      select p.proyecto, p.activos, p.esperadas,
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
        select a.proyecto, count(distinct a.cedula) activos, coalesce(sum(t.dias),0)::bigint esperadas
        from tmp_asignados a
        left join tmp_requeridos t on t.cedula=a.cedula and t.formulario_id=a.formulario_id
        group by a.proyecto
      ) p
      left join (
        select coalesce(r.proyecto,'Sin proyecto') proyecto, count(*) realizadas,
               count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
        from registros r
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (form_f='' or r.formulario_id=form_f)
          and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
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
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (form_f='' or r.formulario_id=form_f)
        group by regexp_replace(r.cedula,'\D','','g')
      ) reg on reg.ced = regexp_replace(c.cedula,'\D','','g')
      left join (
        select regexp_replace(tc.cedula,'\D','','g') ced, count(*)::int dias_diligenciados
        from tmp_calendario tc
        where not tc.justificado
          and exists (select 1 from tmp_requeridos tr where tr.cedula=tc.cedula)
          and not exists (
            select 1 from tmp_requeridos tr
            where tr.cedula=tc.cedula
              and not exists (
                select 1 from registros r
                where regexp_replace(r.cedula,'\D','','g')=regexp_replace(tc.cedula,'\D','','g')
                  and r.fecha=tc.fecha and r.formulario_id=tr.formulario_id
                  and coalesce(r.estado,'')<>'ANULADO'
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
      where c.activo and req.cedula is not null
        and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy))
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
        where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
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
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
      group by extract(isodow from r.fecha), to_char(r.fecha,'TMDay')
    ) x),'[]'::jsonb),

    -- Franja horaria de los registros (puntualidad).
    'por_hora',coalesce((select jsonb_agg(x order by x.hora) from (
      select extract(hour from r.hora)::int hora, count(*) realizadas
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and r.hora is not null
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
      group by extract(hour from r.hora)
    ) x),'[]'::jsonb),

    -- Mensajeros activos que llevan mas dias sin registrar (seguimiento).
    'inactividad',coalesce((select jsonb_agg(x order by x.dias_sin desc nulls first, x.nombre) from (
      select c.cedula, coalesce(c.nombre,'') nombre, coalesce(c.proyecto_efectivo,'Sin proyecto') proyecto,
             u.ultimo, case when u.ultimo is null then null else (hoy-u.ultimo) end dias_sin
      from colaboradores c
      left join (
        select regexp_replace(r.cedula,'\D','','g') ced, max(r.fecha) ultimo
        from registros r where coalesce(r.estado,'')<>'ANULADO'
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (form_f='' or r.formulario_id=form_f)
        group by regexp_replace(r.cedula,'\D','','g')
      ) u on u.ced=regexp_replace(c.cedula,'\D','','g')
      where c.activo and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy))
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
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and coalesce(r.alertas,'')<>''
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
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
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto = coalesce(nombre_proyecto(proy), proy))
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
      where c.activo and (proy='' or c.proyecto_efectivo = proy or c.proyecto_efectivo = nombre_proyecto(proy) or (coalesce(c.proyecto_operativo,'') = '' and c.proyecto_id::text = proy))
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto_efectivo,'') and pf.activo
            and (form_f='' or pf.formulario_id=form_f)
        )
        and (d.fecha_vencimiento is null or d.fecha_vencimiento<=hoy+15)
    ) x),'[]'::jsonb),
    'actualizado',to_char(now() at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
  );
end;
$$;


-- ---------- api_exportable ----------
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
      and (filtro_proy='' or r.proyecto = coalesce(nombre_proyecto(filtro_proy), filtro_proy))
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

