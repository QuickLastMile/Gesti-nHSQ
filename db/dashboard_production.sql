-- ============================================================
--  Dashboard ejecutivo HSEQ
--  Filtros: proyecto, anio, mes y dia. Rankings de cumplimiento
--  por proyecto y por mensajero. Alertas documentales a 15 dias.
--  Los periodos sin registros NO se devuelven.
-- ============================================================
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
    select c.cedula, c.proyecto, pf.formulario_id
    from colaboradores c
    join proyectos_formularios pf on pf.proyecto=c.proyecto and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where c.activo
      and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
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
     and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy);

  -- Periodo inmediatamente anterior, con la misma cantidad de dias y las
  -- mismas reglas de calendario, festivos y justificaciones.
  prev_hasta := desde - 1;
  prev_desde := prev_hasta - greatest(ndias - 1, 0);
  select count(*) into prev_realizadas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO'
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy);
  select coalesce(sum(de.dias),0)::bigint into prev_esperadas
    from dias_exigibles(prev_desde, prev_hasta, proy) de
    join proyectos_formularios pf on pf.proyecto=de.proyecto and pf.activo
    join formularios f on f.id=pf.formulario_id and f.activo
    where form_f='' or pf.formulario_id=form_f;
  select count(*) into prev_alertas from registros r
   where r.fecha between prev_desde and prev_hasta and coalesce(r.estado,'') <> 'ANULADO'
     and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
     and coalesce(r.alertas,'')<>'' and (form_f='' or r.formulario_id=form_f)
     and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy);

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
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy))
    ),

    -- Solo dias CON registros.
    'por_dia',coalesce((select jsonb_agg(x order by x.fecha) from (
      select r.fecha, count(*) realizadas,
             count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
      from registros r
      where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by r.fecha
    ) x),'[]'::jsonb),

    -- Solo meses CON registros (del anio seleccionado).
    'por_mes',coalesce((select jsonb_agg(x order by x.mes) from (
      select to_char(r.fecha,'YYYY-MM') mes, count(*) realizadas
      from registros r
      where extract(year from r.fecha)=anio_f and coalesce(r.estado,'')<>'ANULADO'
        and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
        and (form_f='' or r.formulario_id=form_f)
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by to_char(r.fecha,'YYYY-MM')
    ) x),'[]'::jsonb),

    'por_anio',coalesce((select jsonb_agg(x order by x.anio) from (
      select extract(year from r.fecha)::int anio,count(*) realizadas
      from registros r where coalesce(r.estado,'')<>'ANULADO'
       and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
       and (form_f='' or r.formulario_id=form_f)
       and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
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
          and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
        group by coalesce(r.proyecto,'Sin proyecto')
      ) reg on reg.proyecto=p.proyecto
      left join proyectos_calendario pc on pc.proyecto=p.proyecto
    ) x),'[]'::jsonb),

    -- Ranking de mensajeros (incluye a los que no registraron nada).
    'mensajeros',coalesce((select jsonb_agg(x order by x.porcentaje desc, x.realizadas desc, x.nombre) from (
      select c.cedula, coalesce(c.nombre,'') nombre, coalesce(c.proyecto,'Sin proyecto') proyecto,
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
        and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
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
          and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
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
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
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
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by extract(hour from r.hora)
    ) x),'[]'::jsonb),

    -- Mensajeros activos que llevan mas dias sin registrar (seguimiento).
    'inactividad',coalesce((select jsonb_agg(x order by x.dias_sin desc nulls first, x.nombre) from (
      select c.cedula, coalesce(c.nombre,'') nombre, coalesce(c.proyecto,'Sin proyecto') proyecto,
             u.ultimo, case when u.ultimo is null then null else (hoy-u.ultimo) end dias_sin
      from colaboradores c
      left join (
        select regexp_replace(r.cedula,'\D','','g') ced, max(r.fecha) ultimo
        from registros r where coalesce(r.estado,'')<>'ANULADO'
          and formulario_habilitado(coalesce(r.proyecto,''),r.formulario_id)
          and (form_f='' or r.formulario_id=form_f)
        group by regexp_replace(r.cedula,'\D','','g')
      ) u on u.ced=regexp_replace(c.cedula,'\D','','g')
      where c.activo and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto,'') and pf.activo
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
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
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
        and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
        and nullif(btrim(coalesce(p.respuesta_alerta,'')),'') is not null
        and upper(btrim(coalesce(rs.valor,'')))=upper(btrim(p.respuesta_alerta))
      group by p.id,p.seccion,p.pregunta,coalesce(r.proyecto,'Sin proyecto')
      order by count(*) desc
      limit 20
    ) x),'[]'::jsonb),

    'alertas',coalesce((select jsonb_agg(x order by x.prioridad,x.dias_restantes,x.proyecto,x.nombre) from (
      select c.cedula,c.nombre,c.proyecto,c.placa_moto,d.documento,d.fecha_vencimiento,
             d.fecha_vencimiento-hoy dias_restantes,
             case when d.fecha_vencimiento is null then 'SIN FECHA'
                  when d.fecha_vencimiento<hoy then 'VENCIDO' else 'PRÓXIMO A VENCER' end estado,
             case when d.fecha_vencimiento is null or d.fecha_vencimiento<hoy then 1 else 2 end prioridad
      from colaboradores c
      cross join lateral (values ('SOAT',c.soat_vence),('TECNOMECÁNICA',c.tecnomecanica_vence),('LICENCIA',c.licencia_vence)) d(documento,fecha_vencimiento)
      where c.activo and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
        and exists (
          select 1 from proyectos_formularios pf
          join formularios f on f.id=pf.formulario_id and f.activo
          where pf.proyecto=coalesce(c.proyecto,'') and pf.activo
            and (form_f='' or pf.formulario_id=form_f)
        )
        and (d.fecha_vencimiento is null or d.fecha_vencimiento<=hoy+15)
    ) x),'[]'::jsonb),
    'actualizado',to_char(now() at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
  );
end;
$$;

revoke all on function api_dashboard(jsonb) from public, anon;
grant execute on function api_dashboard(jsonb) to authenticated;
