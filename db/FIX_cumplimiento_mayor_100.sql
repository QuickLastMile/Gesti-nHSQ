-- ============================================================
--  El cumplimiento no puede pasar del 100%
--  ------------------------------------------------------------
--  QUE PASABA
--  ----------
--  Al filtrar el domingo 20/09 el tablero mostraba 151% de
--  cumplimiento, y un coordinador salia con 2300% (46 hechos
--  contra 2 esperados).
--
--  La causa: lo ESPERADO respeta el calendario de cada proyecto
--  (dias laborales, festivos, justificaciones y frecuencia del
--  formulario), pero lo REALIZADO contaba todo registro del rango
--  sin mirar nada de eso. Un registro hecho un domingo en un
--  proyecto que no trabaja domingos sumaba al numerador y no al
--  denominador. Lo mismo con una limpieza semanal diligenciada el
--  dia que no tocaba, o con un dia justificado en el que la
--  persona registro igual.
--
--  EL ARREGLO
--  ----------
--  api_dashboard ya construye tmp_exig: una fila por persona, dia
--  y formulario REALMENTE exigible. De ahi salen las esperadas.
--  Ahora las realizadas se cuentan contra ese mismo conjunto, asi
--  que numerador y denominador miden lo mismo por construccion y
--  el porcentaje no puede pasar del 100%.
--
--  Se agrega tmp_exig_prev con la misma regla para el periodo
--  anterior (el que se compara en las tarjetas), y tmp_ok que une
--  los dos con un indice para que la consulta sea inmediata.
--
--  POR QUE NO UNA FUNCION POR FILA
--  -------------------------------
--  Se intento con una funcion que evaluara la regla registro por
--  registro: costaba 1,1 s por consulta y en api_dashboard hay 17.
--  La busqueda indexada contra tmp_ok deja el total en 694 ms
--  incluyendo construir todas las tablas.
--
--  Efecto medido en el domingo 20/09 (Last Mile):
--    antes: 151 hechos / 100 esperados = 151%
--    ahora:  83 hechos / 100 esperados =  83%
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La regla, para quien la necesite fila por fila
--  ------------------------------------------------------------
--  api_dashboard no la usa (usa tmp_ok, que es mucho mas rapido),
--  pero api_mi_cumplimiento si: ahi es una sola persona y el costo
--  no importa.
-- ------------------------------------------------------------
create or replace function registro_exigido(p_cedula text, p_proyecto text,
                                            p_formulario text, p_fecha date,
                                            p_cargo text default null)
returns boolean language sql stable set search_path = public as $fn$
  select coalesce((
    select extract(isodow from p_fecha)::smallint = any(coalesce(pc.dias_laborales, '{1,2,3,4,5,6}'::smallint[]))
       and (coalesce(pc.labora_festivos, false)
            or not exists (select 1 from festivos x where x.fecha = p_fecha))
      from (select 1) z
      left join proyectos_calendario pc
        on pc.proyecto = coalesce(nullif(btrim(coalesce(p_proyecto,'')), ''), 'Sin proyecto')
  ), false)
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

create index if not exists idx_just_cedula
  on justificaciones ((regexp_replace(cedula,'\D','','g')));

-- ------------------------------------------------------------
--  2) El tablero cuenta contra lo que de verdad se exigio
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_dashboard';
  if src is null then raise exception 'No existe api_dashboard'; end if;
  if position('tmp_ok' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '  create index on tmp_exig (cedula);' || nl || '  create index on tmp_exig (fecha);',
    '  create index on tmp_exig (cedula);' || nl
 || '  create index on tmp_exig (fecha);' || nl
 || nl
 || '  -- Lo mismo para el periodo anterior, que se compara en las tarjetas.' || nl
 || '  drop table if exists tmp_exig_prev;' || nl
 || '  create temporary table tmp_exig_prev on commit drop as' || nl
 || '    select tc.cedula, tc.fecha, a.formulario_id' || nl
 || '      from dias_calendario_colaborador(desde - ndias, desde - 1, proy) tc' || nl
 || '      join tmp_asignados a on a.cedula = tc.cedula' || nl
 || '     where not tc.justificado' || nl
 || '       and (a.frecuencia <> ''SEMANAL''' || nl
 || '            or extract(isodow from tc.fecha)::smallint = a.dia_semana);' || nl
 || nl
 || '  -- Un registro solo cuenta si esta aqui: ese dia, esa persona y ese' || nl
 || '  -- formulario se le estaban exigiendo. Sin esto, lo hecho un domingo' || nl
 || '  -- en un proyecto que no trabaja domingos sumaba al numerador y no al' || nl
 || '  -- denominador, y el cumplimiento pasaba del 100%.' || nl
 || '  drop table if exists tmp_ok;' || nl
 || '  create temporary table tmp_ok on commit drop as' || nl
 || '    select regexp_replace(cedula,''\D'','''',''g'') as ced, formulario_id, fecha from tmp_exig' || nl
 || '    union all' || nl
 || '    select regexp_replace(cedula,''\D'','''',''g''), formulario_id, fecha from tmp_exig_prev;' || nl
 || '  create index on tmp_ok (ced, formulario_id, fecha);');

  nuevo := replace(nuevo,
    'and formulario_habilitado(coalesce(r.proyecto,''''),r.formulario_id)',
    'and exists (select 1 from tmp_ok x' || nl
 || '                   where x.ced = regexp_replace(r.cedula,''\D'','''',''g'')' || nl
 || '                     and x.formulario_id = r.formulario_id and x.fecha = r.fecha)');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function api_dashboard(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  3) Y el mensajero ve lo mismo en "Mi cumplimiento"
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_mi_cumplimiento';
  if position('registro_exigido' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '  select count(*) into realizados' || nl
 || '    from registros r' || nl
 || '   where regexp_replace(r.cedula,''\D'','''',''g'') = ncedula' || nl
 || '     and r.fecha between desde and hasta' || nl
 || '     and coalesce(r.estado,'''') <> ''ANULADO'';',

    '  select count(*) into realizados' || nl
 || '    from registros r' || nl
 || '   where regexp_replace(r.cedula,''\D'','''',''g'') = ncedula' || nl
 || '     and r.fecha between desde and hasta' || nl
 || '     and coalesce(r.estado,'''') <> ''ANULADO''' || nl
 || '     -- Solo lo que ese dia se le estaba exigiendo: si no, un registro' || nl
 || '     -- hecho un domingo que no se trabaja lo dejaria por encima del 100%.' || nl
 || '     and registro_exigido(r.cedula, coalesce(r.proyecto,''''), r.formulario_id, r.fecha, r.cargo);');

  if nuevo = src then raise exception 'No encontre el conteo de realizados'; end if;

  execute 'create or replace function api_mi_cumplimiento(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las tres piezas.
select (select case when prosrc like '%tmp_ok%' then 'si' else 'NO' end
          from pg_proc where proname='api_dashboard') as tablero,
       (select case when prosrc like '%tmp_exig_prev%' then 'si' else 'NO' end
          from pg_proc where proname='api_dashboard') as periodo_anterior,
       (select case when prosrc like '%registro_exigido%' then 'si' else 'NO' end
          from pg_proc where proname='api_mi_cumplimiento') as mi_cumplimiento;

-- b) Cuantos registros dejan de contar por dia no laborable. Son los que
--    inflaban el porcentaje.
select r.linea,
       count(*) as registros_del_mes,
       count(*) filter (
         where not registro_exigido(r.cedula, coalesce(r.proyecto,''), r.formulario_id, r.fecha, r.cargo)
       ) as no_le_tocaba_ese_dia
  from registros r
 where r.fecha >= date_trunc('month', (now() at time zone 'America/Bogota')::date)::date
   and coalesce(r.estado,'') <> 'ANULADO'
 group by r.linea
 order by r.linea;

-- c) Nadie deberia pasar del 100%.
with muestra as (
  select c.cedula from colaboradores c where c.activo order by random() limit 120
), x as (
  select (api_mi_cumplimiento(jsonb_build_object('cedula', cedula))->>'porcentaje')::numeric pct
    from muestra)
select count(*) as revisados,
       count(*) filter (where pct > 100) as por_encima_de_100,
       max(pct) as maximo
  from x;
