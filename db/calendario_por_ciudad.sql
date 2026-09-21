-- ============================================================
--  Un proyecto puede operar distinto en cada ciudad
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  El calendario (dias laborales, festivos, meta) era uno solo por
--  proyecto. Pero Cruz Verde trabaja domingo en unas ciudades y en
--  otras no, y no habia forma de decirlo: o se le exigia a todo el
--  proyecto o a ninguno.
--
--  No es un caso raro: 32 de los 124 proyectos de Last Mile tienen
--  gente en mas de una ciudad, y ahi esta el 75% del personal (446
--  de 596). Uno llega a 19 ciudades.
--
--  POR QUE CIUDAD Y NO FRENTE
--  --------------------------
--  ciudad esta lleno en los 628 activos (54 ciudades distintas);
--  frente solo en 170. La ciudad es el unico eje completo.
--
--  COMO FUNCIONA
--  -------------
--  proyectos_calendario pasa a tener llave (proyecto, ciudad):
--    - fila con ciudad vacia  -> calendario de todo el proyecto
--    - fila con ciudad        -> excepcion solo para esa ciudad
--  Si no hay ninguna, rige el defecto de config (lunes a sabado).
--
--  Nada cambia hasta que se cree la primera excepcion: al aplicar
--  este script las 310 combinaciones proyecto+ciudad siguen
--  heredando el calendario del proyecto.
--
--  Requiere db/FIX_cumplimiento_mayor_100.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La llave pasa a ser proyecto + ciudad
-- ------------------------------------------------------------
alter table proyectos_calendario
  add column if not exists ciudad text not null default '';

alter table proyectos_calendario drop constraint if exists proyectos_calendario_pkey;
alter table proyectos_calendario add primary key (proyecto, ciudad);

comment on column proyectos_calendario.ciudad is
  'Vacio = calendario de todo el proyecto. Con ciudad = excepcion solo para esa ciudad.';

-- ------------------------------------------------------------
--  2) La precedencia, en un solo sitio
--  ------------------------------------------------------------
--  Si hay fila para esa ciudad manda esa; si no, la del proyecto;
--  si tampoco, quien llama pone su defecto.
-- ------------------------------------------------------------
create or replace function calendario_de(p_proyecto text, p_ciudad text)
returns table(dias_laborales smallint[], labora_festivos boolean, meta numeric)
language sql stable set search_path = public as $fn$
  select pc.dias_laborales, pc.labora_festivos, pc.meta
    from proyectos_calendario pc
   where pc.proyecto = coalesce(nullif(btrim(coalesce(p_proyecto,'')),''), 'Sin proyecto')
     and pc.ciudad in ('', coalesce(nullif(btrim(coalesce(p_ciudad,'')),''), ''))
   order by (pc.ciudad <> '') desc
   limit 1;
$fn$;

-- ------------------------------------------------------------
--  3) Los tres calculos que leen el calendario
-- ------------------------------------------------------------
create or replace function dias_calendario_colaborador(desde date, hasta date, proy text default '')
returns table(cedula text, proyecto text, fecha date, justificado boolean)
language sql stable set search_path = public as $fn$
  with defecto as (
    select
      coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
               '{1,2,3,4,5,6}'::smallint[]) as dias_def,
      coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false) as fest_def
  ),
  activos as (
    select c.cedula, regexp_replace(c.cedula,'\D','','g') ced_n,
           coalesce(c.proyecto,'Sin proyecto') proyecto,
           coalesce(nullif(btrim(coalesce(c.ciudad,'')),''), '') ciudad
    from colaboradores c
    where c.activo
      and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
  ),
  cal as (
    -- El calendario que le aplica: el de su ciudad si existe, si no el
    -- del proyecto. Un mismo proyecto puede trabajar domingo en una
    -- ciudad y no en otra.
    select a.cedula, a.ced_n, a.proyecto,
           coalesce(k.dias_laborales, d.dias_def) dias_lab,
           coalesce(k.labora_festivos, d.fest_def) fest
    from activos a
    cross join defecto d
    left join lateral calendario_de(a.proyecto, a.ciudad) k on true
  ),
  fechas as (
    select g::date f, extract(isodow from g)::smallint dow
    from generate_series(desde, hasta, interval '1 day') g
  )
  select c.cedula, c.proyecto, f.f,
         exists (
           select 1 from justificaciones j
           where regexp_replace(j.cedula,'\D','','g') = c.ced_n
             and f.f between coalesce(j.fecha_inicio, j.fecha)
                         and coalesce(j.fecha_fin, j.fecha)
         ) as justificado
  from cal c
  join fechas f on f.dow = any(c.dias_lab)
  where c.fest
     or not exists (select 1 from festivos x where x.fecha = f.f);
$fn$;

create or replace function dias_exigibles(desde date, hasta date, proy text default '')
returns table(cedula text, proyecto text, dias integer)
language sql stable set search_path = public as $fn$
  with defecto as (
    select
      coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
               '{1,2,3,4,5,6}'::smallint[]) as dias_def,
      coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false) as fest_def
  ),
  activos as (
    select c.cedula, regexp_replace(c.cedula,'\D','','g') ced_n,
           coalesce(nullif(c.proyecto_efectivo,''),'Sin proyecto') proyecto,
           coalesce(nullif(btrim(coalesce(c.ciudad,'')),''), '') ciudad
    from colaboradores c
    where c.activo
      and (proy='' or c.proyecto_efectivo=proy or c.proyecto_id::text=proy)
  ),
  cal as (
    select a.cedula, a.ced_n, a.proyecto,
           coalesce(k.dias_laborales, d.dias_def) dias_lab,
           coalesce(k.labora_festivos, d.fest_def) fest
    from activos a
    cross join defecto d
    left join lateral calendario_de(a.proyecto, a.ciudad) k on true
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

create or replace function registro_exigido(p_cedula text, p_proyecto text,
                                            p_formulario text, p_fecha date,
                                            p_cargo text default null,
                                            p_ciudad text default null)
returns boolean language sql stable set search_path = public as $fn$
  select coalesce((
    select extract(isodow from p_fecha)::smallint
             = any(coalesce(k.dias_laborales, '{1,2,3,4,5,6}'::smallint[]))
       and (coalesce(k.labora_festivos, false)
            or not exists (select 1 from festivos x where x.fecha = p_fecha))
      from calendario_de(p_proyecto, p_ciudad) k
  ), (
    -- Sin calendario configurado: el defecto de lunes a sabado.
    select extract(isodow from p_fecha)::smallint = any('{1,2,3,4,5,6}'::smallint[])
       and not exists (select 1 from festivos x where x.fecha = p_fecha)
  ))
  and not exists (
        select 1 from justificaciones j
         where regexp_replace(j.cedula,'\D','','g') = regexp_replace(coalesce(p_cedula,''),'\D','','g')
           and p_fecha between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha))
  and exists (
        select 1
          from proyectos_formularios pf
          join formularios f on f.id = pf.formulario_id and f.activo
         where pf.proyecto = coalesce(p_proyecto,'') and pf.activo
           and pf.formulario_id = p_formulario
           and (pf.frecuencia <> 'SEMANAL'
                or extract(isodow from p_fecha)::smallint = pf.dia_semana)
           and (f.aplica_a is null or f.aplica_a = perfil_cargo(p_cargo)));
$fn$;

-- Mi cumplimiento pasa la ciudad del registro.
do $do$
declare src text; nuevo text;
begin
  select prosrc into src from pg_proc where proname = 'api_mi_cumplimiento';
  if position('r.ciudad' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.'; return;
  end if;
  nuevo := replace(src,
    'registro_exigido(r.cedula, coalesce(r.proyecto,''''), r.formulario_id, r.fecha, r.cargo)',
    'registro_exigido(r.cedula, coalesce(r.proyecto,''''), r.formulario_id, r.fecha, r.cargo, r.ciudad)');
  if nuevo = src then raise exception 'No encontre la llamada'; end if;
  execute 'create or replace function api_mi_cumplimiento(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  4) Configuracion: ver y guardar el calendario por ciudad
-- ------------------------------------------------------------
create or replace function admin_calendario(payload jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = public as $fn$
  with v_linea as (select linea_efectiva(coalesce(payload->>'linea','')) l),
  gente as (
    select coalesce(c.proyecto,'Sin proyecto') proyecto,
           coalesce(nullif(btrim(coalesce(c.ciudad,'')),''), 'Sin ciudad') ciudad,
           count(*) activos
      from colaboradores c, v_linea
     where c.activo and c.linea = v_linea.l
     group by 1,2
  ),
  proyectos as (
    select proyecto, sum(activos)::int activos, count(*)::int ciudades
      from gente group by proyecto
  )
  select jsonb_build_object(
    'defecto', jsonb_build_object(
      'dias', coalesce((select valor from config where clave='CAL_DIAS_DEFECTO'), '1,2,3,4,5,6'),
      'festivos', coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false),
      'meta', coalesce((select valor::numeric from config where clave='META_DEFECTO'), 90)),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'proyecto', p.proyecto,
        'activos', p.activos,
        'dias', coalesce(array_to_string(pc.dias_laborales, ','), ''),
        'festivos', coalesce(pc.labora_festivos, false),
        'meta', pc.meta,
        'configurado', pc.proyecto is not null,
        -- Las ciudades del proyecto, con su excepcion si la tienen.
        'ciudades', coalesce((
          select jsonb_agg(jsonb_build_object(
            'ciudad', g.ciudad,
            'activos', g.activos,
            'dias', coalesce(array_to_string(pcc.dias_laborales, ','), ''),
            'festivos', coalesce(pcc.labora_festivos, false),
            'meta', pcc.meta,
            'propio', pcc.proyecto is not null) order by g.activos desc, g.ciudad)
            from gente g
            left join proyectos_calendario pcc
                   on pcc.proyecto = g.proyecto and pcc.ciudad = g.ciudad
           where g.proyecto = p.proyecto), '[]'::jsonb)
      ) order by p.proyecto)
      from proyectos p
      left join proyectos_calendario pc on pc.proyecto = p.proyecto and pc.ciudad = ''
    ), '[]'::jsonb)
  );
$fn$;

create or replace function admin_guardar_calendario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  p text := btrim(coalesce(payload->>'proyecto',''));
  ciu text := btrim(coalesce(payload->>'ciudad',''));
  d text := btrim(coalesce(payload->>'dias',''));
  f boolean := coalesce((payload->>'festivos')::boolean, false);
  m numeric := nullif(btrim(coalesce(payload->>'meta','')), '')::numeric;
  quitar boolean := coalesce((payload->>'quitar')::boolean, false);
begin
  if p = '' then raise exception 'Falta el proyecto.'; end if;
  perform exigir_linea_proyecto(p, linea_efectiva(coalesce(payload->>'linea','')));

  -- Quitar la excepcion de una ciudad: vuelve a regirse por el proyecto.
  if quitar then
    if ciu = '' then raise exception 'El calendario del proyecto no se puede quitar.'; end if;
    delete from proyectos_calendario where proyecto = p and ciudad = ciu;
    insert into historial (tipo, cedula, detalle)
    values ('CALENDARIO', '', p || ' · ' || ciu || ' -> vuelve al calendario del proyecto');
    return jsonb_build_object('proyecto', p, 'ciudad', ciu, 'quitado', true);
  end if;

  if d = '' then raise exception 'Selecciona al menos un dia laboral.'; end if;
  if m is not null and (m < 0 or m > 100) then raise exception 'La meta debe estar entre 0 y 100.'; end if;

  insert into proyectos_calendario (proyecto, ciudad, dias_laborales, labora_festivos, meta, actualizado_en)
  values (p, ciu, string_to_array(d, ',')::smallint[], f, m, now())
  on conflict (proyecto, ciudad) do update
    set dias_laborales = excluded.dias_laborales,
        labora_festivos = excluded.labora_festivos,
        meta = excluded.meta,
        actualizado_en = now();

  insert into historial (tipo, cedula, detalle)
  values ('CALENDARIO', '',
    p || case when ciu <> '' then ' · ' || ciu else '' end
      || ' -> dias ' || d || case when f then ' + festivos' else '' end
      || coalesce(' · meta ' || m || '%', ''));

  return jsonb_build_object('proyecto', p, 'ciudad', ciu, 'dias', d, 'festivos', f, 'meta', m);
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La llave nueva.
select a.attname as columna
  from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
 where i.indrelid = 'proyectos_calendario'::regclass and i.indisprimary
 order by a.attname;

-- b) Proyectos repartidos en varias ciudades: son los que ganan con esto.
select count(*) filter (where ciudades > 1) as proyectos_multiciudad,
       sum(personas) filter (where ciudades > 1) as personas,
       max(ciudades) as mas_ciudades
  from (select c.proyecto_efectivo,
               count(distinct nullif(btrim(coalesce(c.ciudad,'')),'')) ciudades,
               count(*) personas
          from colaboradores c where c.activo and c.linea='LAST_MILE'
         group by 1) x;

-- c) Excepciones creadas hasta ahora (al aplicar el script deben ser 0:
--    todo sigue heredando el calendario del proyecto).
select proyecto, ciudad, array_to_string(dias_laborales, ',') as dias, labora_festivos, meta
  from proyectos_calendario
 where ciudad <> ''
 order by proyecto, ciudad;
