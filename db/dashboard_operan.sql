-- ============================================================
--  Cuantos operan ese dia, no cuantos hay en nomina
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  La tabla de responsables mostraba "274 activos" contra "98
--  esperados" y "83 hechos". El 274 es la nomina entera, que no
--  tiene nada que ver con el dia filtrado: no se podia leer la
--  fila.
--
--  Peor era el caso de abajo: "71 activos, 0 esperados, 0.0%, SIN
--  DATOS". Parecia que 71 personas no habian registrado, cuando lo
--  que pasa es que ninguna trabaja los domingos.
--
--  QUE HACE
--  --------
--  Cada fila trae ademas 'operan': cuantos de esos activos tienen
--  al menos un dia exigible en el periodo filtrado. Entre semana
--  suele ser el total; un domingo pueden ser 70 de 274, y ese es el
--  numero que se compara contra lo esperado.
--
--  La pantalla muestra el grande (operan) y debajo, en pequeno, "de
--  274" — solo cuando los dos numeros difieren.
--
--  Requiere db/FIX_cumplimiento_mayor_100.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_dashboard';
  if src is null then raise exception 'No existe api_dashboard'; end if;
  if position('operan' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  -- Por proyecto
  nuevo := replace(src,
    '        select a.proyecto, count(distinct a.cedula) activos,',
    '        select a.proyecto, count(distinct a.cedula) activos,' || nl
 || '               -- De la nomina, cuantos tienen algun dia exigible en el' || nl
 || '               -- periodo. Un domingo operan 70 de 274, y comparar los 274' || nl
 || '               -- contra lo esperado de ese dia no dice nada.' || nl
 || '               count(distinct a.cedula) filter (where coalesce(t.dias,0) > 0) operan,');

  nuevo := replace(nuevo,
    '      select p.proyecto, p.activos, p.esperadas, p.justificados,',
    '      select p.proyecto, p.activos, p.operan, p.esperadas, p.justificados,');

  -- Por responsable (jefatura, lider, coordinador)
  nuevo := replace(nuevo,
    '                 count(*) activos,' || nl
 || '                 coalesce(sum(e.esperadas),0)::bigint esperadas,',
    '                 count(*) activos,' || nl
 || '                 count(*) filter (where coalesce(e.esperadas,0) > 0) operan,' || nl
 || '                 coalesce(sum(e.esperadas),0)::bigint esperadas,');

  nuevo := replace(nuevo,
    '                 ''nombre'', z.nombre, ''activos'', z.activos,',
    '                 ''nombre'', z.nombre, ''activos'', z.activos, ''operan'', z.operan,');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function api_dashboard(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya lo entrega.
select case when prosrc like '%''operan''%' then 'ARREGLADA' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_dashboard';

-- b) La diferencia real, para el domingo pasado: cuanta gente tiene cada
--    coordinador y cuanta opera de verdad ese dia.
with dia as (select date '2026-09-20' d)
select c.enc_coordinador as responsable,
       count(*) as activos,
       count(*) filter (where exists (
         select 1 from dias_calendario_colaborador((select d from dia), (select d from dia), '') k
          where k.cedula = c.cedula and not k.justificado)) as operan_ese_domingo
  from colaboradores c
 where c.activo and c.linea = 'LAST_MILE'
   and coalesce(nullif(btrim(c.enc_coordinador),''),'') <> ''
 group by c.enc_coordinador
 order by activos desc
 limit 8;
