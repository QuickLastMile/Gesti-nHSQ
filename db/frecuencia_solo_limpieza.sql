-- ============================================================
--  La frecuencia solo se ofrece en limpieza y desinfeccion
--  ------------------------------------------------------------
--  El preoperacional se hace todos los dias sin excepcion, asi que
--  no debe mostrar el selector de frecuencia. La marca vive en la
--  tabla de formularios y no en el codigo, para poder habilitarla
--  manana en otro formulario sin tocar la app.
--
--  Correr DESPUES de db/frecuencia_formulario.sql. Se puede volver
--  a correr las veces que haga falta.
-- ============================================================

-- ------------------------------------------------------------
--  Que formularios pueden ser semanales
--  ------------------------------------------------------------
--  El preoperacional se hace todos los dias sin excepcion: no tiene
--  sentido ofrecerle una frecuencia. La marca vive en la tabla de
--  formularios y no en el codigo, para poder habilitarla manana en
--  otro formulario sin tocar la app.
-- ------------------------------------------------------------
alter table formularios
  add column if not exists permite_frecuencia boolean not null default false;

update formularios
   set permite_frecuencia = true
 where id like 'LIMPIEZA%' and not permite_frecuencia;

-- Si algo quedo en semanal donde no corresponde, vuelve a diario.
update proyectos_formularios pf
   set frecuencia = 'DIARIA', dia_semana = null, actualizado_en = now()
  from formularios f
 where f.id = pf.formulario_id
   and not f.permite_frecuencia
   and pf.frecuencia <> 'DIARIA';

-- ------------------------------------------------------------
--  El panel: devuelve la marca y rechaza lo que no aplica
-- ------------------------------------------------------------
create or replace function admin_formularios_proyecto()
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'formularios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', f.id, 'nombre', f.nombre, 'descripcion', coalesce(f.descripcion,''),
        'activo_global', f.activo, 'orden', f.orden,
        -- Solo estos muestran el selector de frecuencia en el panel.
        'permite_frecuencia', coalesce(f.permite_frecuencia, false)
      ) order by f.orden, f.nombre)
      from formularios f
    ), '[]'::jsonb),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'proyecto', p.proyecto,
        'activos', p.activos,
        'habilitados', coalesce(a.habilitados,0),
        'formularios', coalesce(a.formularios,'{}'::jsonb),
        'frecuencias', coalesce(a.frecuencias,'{}'::jsonb),
        -- Dias laborales del proyecto, para avisar si el dia elegido no aplica.
        'dias_laborales', coalesce(array_to_string(pc.dias_laborales, ','),
          coalesce((select valor from config where clave='CAL_DIAS_DEFECTO'), '1,2,3,4,5,6'))
      ) order by p.proyecto)
      from (
        select c.proyecto, count(*) filter (where c.activo)::int activos
        from colaboradores c
        where coalesce(c.proyecto,'') <> ''
        group by c.proyecto
      ) p
      left join proyectos_calendario pc on pc.proyecto = p.proyecto
      left join lateral (
        select count(*) filter (where pf.activo and f.activo)::int habilitados,
               coalesce(jsonb_object_agg(pf.formulario_id, pf.activo),'{}'::jsonb) formularios,
               coalesce(jsonb_object_agg(pf.formulario_id, jsonb_build_object(
                 'frecuencia', pf.frecuencia, 'dia_semana', pf.dia_semana)),'{}'::jsonb) frecuencias
        from proyectos_formularios pf
        join formularios f on f.id=pf.formulario_id
        where pf.proyecto=p.proyecto
      ) a on true
    ), '[]'::jsonb)
  );
$fn$;

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
-- a) Solo limpieza admite frecuencia.
select id, nombre, permite_frecuencia from formularios order by orden;

-- b) Nada quedo en semanal donde no corresponde.
select f.nombre, pf.frecuencia, count(*) as proyectos
  from proyectos_formularios pf
  join formularios f on f.id = pf.formulario_id
 group by f.nombre, pf.frecuencia
 order by f.nombre, pf.frecuencia;
