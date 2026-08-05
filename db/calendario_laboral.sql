-- ============================================================
--  Calendario laboral por proyecto + festivos de Colombia
--  Hace que el "esperado" del cumplimiento cuente SOLO los dias
--  que cada proyecto realmente labora, y descuente los dias con
--  justificacion (descanso, permiso, vacaciones, suspension).
--  Ejecutar en Supabase -> SQL Editor.
-- ============================================================

-- ------------------------------------------------------------
--  1) Festivos (Colombia). Editable desde el panel si hace falta.
-- ------------------------------------------------------------
create table if not exists festivos (
  fecha  date primary key,
  nombre text
);
alter table festivos enable row level security;

insert into festivos (fecha, nombre) values
  ('2026-01-01','Año Nuevo'),('2026-01-12','Reyes Magos'),('2026-03-23','San José'),
  ('2026-04-02','Jueves Santo'),('2026-04-03','Viernes Santo'),('2026-05-01','Día del Trabajo'),
  ('2026-05-18','Ascensión'),('2026-06-08','Corpus Christi'),('2026-06-15','Sagrado Corazón'),
  ('2026-06-29','San Pedro y San Pablo'),('2026-07-20','Independencia'),('2026-08-07','Batalla de Boyacá'),
  ('2026-08-17','Asunción'),('2026-10-12','Día de la Raza'),('2026-11-02','Todos los Santos'),
  ('2026-11-16','Independencia de Cartagena'),('2026-12-08','Inmaculada Concepción'),('2026-12-25','Navidad'),
  ('2027-01-01','Año Nuevo'),('2027-01-11','Reyes Magos'),('2027-03-22','San José'),
  ('2027-03-25','Jueves Santo'),('2027-03-26','Viernes Santo'),('2027-05-01','Día del Trabajo'),
  ('2027-05-10','Ascensión'),('2027-05-31','Corpus Christi'),('2027-06-07','Sagrado Corazón'),
  ('2027-07-05','San Pedro y San Pablo'),('2027-07-20','Independencia'),('2027-08-07','Batalla de Boyacá'),
  ('2027-08-16','Asunción'),('2027-10-18','Día de la Raza'),('2027-11-01','Todos los Santos'),
  ('2027-11-15','Independencia de Cartagena'),('2027-12-08','Inmaculada Concepción'),('2027-12-25','Navidad')
on conflict (fecha) do nothing;

-- ------------------------------------------------------------
--  2) Calendario por proyecto
--     dias_laborales: 1=lunes ... 7=domingo
--     labora_festivos: true si el proyecto opera tambien en festivo
-- ------------------------------------------------------------
create table if not exists proyectos_calendario (
  proyecto        text primary key,
  dias_laborales  smallint[] not null default '{1,2,3,4,5,6}',
  labora_festivos boolean not null default false,
  actualizado_en  timestamptz not null default now()
);
alter table proyectos_calendario enable row level security;

-- Meta de cumplimiento por proyecto (para el semaforo del dashboard).
alter table proyectos_calendario add column if not exists meta numeric(5,1);

-- Valores por defecto para los proyectos que aun no se han configurado.
insert into config (clave, valor) values
  ('CAL_DIAS_DEFECTO', '1,2,3,4,5,6'),
  ('CAL_FESTIVOS_DEFECTO', 'false'),
  ('META_DEFECTO', '90')
on conflict (clave) do nothing;

-- Deja creado el registro de cada proyecto activo (con el valor por defecto).
insert into proyectos_calendario (proyecto)
select distinct coalesce(proyecto,'Sin proyecto')
from colaboradores where activo and coalesce(proyecto,'') <> ''
on conflict (proyecto) do nothing;

-- ------------------------------------------------------------
--  3) Dias que SI se le deben exigir a cada persona en un rango.
--     Descuenta: dias no laborales del proyecto, festivos (si no
--     los labora) y los dias con justificacion vigente.
-- ------------------------------------------------------------
create or replace function dias_exigibles(desde date, hasta date, proy text default '')
returns table(cedula text, proyecto text, dias int)
language sql stable security definer set search_path = public as $$
  with defecto as (
    select
      coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
               '{1,2,3,4,5,6}'::smallint[]) as dias_def,
      coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false) as fest_def
  ),
  activos as (
    select c.cedula, regexp_replace(c.cedula,'\D','','g') ced_n,
           coalesce(c.proyecto,'Sin proyecto') proyecto
    from colaboradores c
    where c.activo
      and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
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
$$;

-- ------------------------------------------------------------
--  4) Lectura y edicion del calendario (solo HSQ autenticado)
-- ------------------------------------------------------------
create or replace function admin_calendario()
returns jsonb language sql security definer set search_path = public as $$
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
        'configurado', pc.proyecto is not null
      ) order by p.proyecto)
      from (
        select coalesce(proyecto,'Sin proyecto') proyecto, count(*) activos
        from colaboradores where activo group by coalesce(proyecto,'Sin proyecto')
      ) p
      left join proyectos_calendario pc on pc.proyecto = p.proyecto
    ), '[]'::jsonb)
  );
$$;

create or replace function admin_guardar_calendario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p text := btrim(coalesce(payload->>'proyecto',''));
  d text := btrim(coalesce(payload->>'dias',''));
  f boolean := coalesce((payload->>'festivos')::boolean, false);
  m numeric := nullif(btrim(coalesce(payload->>'meta','')), '')::numeric;
begin
  if p = '' then raise exception 'Falta el proyecto.'; end if;
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

revoke all on function dias_exigibles(date,date,text) from public, anon;
grant execute on function dias_exigibles(date,date,text) to authenticated;
revoke all on function admin_calendario() from public, anon;
revoke all on function admin_guardar_calendario(jsonb) from public, anon;
