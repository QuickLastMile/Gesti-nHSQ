-- ============================================================
--  Temperatura: filtro por proyecto y jornada, y alerta en el top 10
--  ------------------------------------------------------------
--  Sobre lo que ya quedo en db/temperatura_dashboard_warehouse.sql,
--  el lider de WAREHOUSE pidio ademas:
--   - Filtrar por proyecto y por jornada (manana/tarde), sin perder
--     el rango de fechas ni la ciudad que ya existian.
--   - Un atajo de "Mes" en el frontend, que solo rellena Desde/Hasta
--     (no toca el backend).
--   - Que el top 10 marque con alarma a quien tuvo alguna lectura
--     fuera del rango normal (25 °C), no solo el numero pelado.
--
--  Este script YA SE APLICO en produccion (2026-09-24). create or
--  replace siempre reemplaza el cuerpo completo de api_temperatura;
--  no hace falta el parche por ancla porque no es una funcion que
--  otros procesos toquen a mano.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function api_temperatura(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  fi date := coalesce(nullif(payload->>'fechaInicio','')::date, hoy - 29);
  ff date := coalesce(nullif(payload->>'fechaFin','')::date, hoy);
  ciu text := btrim(coalesce(payload->>'ciudad',''));
  proy text := btrim(coalesce(payload->>'proyecto',''));
  jornada text := upper(btrim(coalesce(payload->>'jornada','')));
  v_forms text[];
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  v_temp_min numeric; v_temp_max numeric; v_hum_min numeric; v_hum_max numeric;
  resumen jsonb;
  serie jsonb;
  top_temp jsonb;
  ciudades jsonb;
  proyectos jsonb;
  descartadas int;
begin
  if fi > ff then raise exception 'El rango de fechas no es valido.'; end if;
  if (ff - fi) > 366 then raise exception 'El rango no puede superar un anio. Acortalo.'; end if;
  if jornada not in ('','AM','PM') then raise exception 'Jornada no valida: %', jornada; end if;
  v_forms := case jornada when 'AM' then array['TEMP_HUM_AM']
                          when 'PM' then array['TEMP_HUM_PM']
                          else array['TEMP_HUM_AM','TEMP_HUM_PM'] end;

  select min_valido, max_valido into v_temp_min, v_temp_max from preguntas where id = 'THA_002';
  select min_valido, max_valido into v_hum_min, v_hum_max from preguntas where id = 'THA_003';

  drop table if exists pg_temp.tmp_temp;
  create temp table tmp_temp on commit drop as
  select r.id, r.fecha, r.cedula, r.nombre, r.proyecto, r.ciudad,
         t_raw.temp_raw, h_raw.hum_raw,
         case when t_raw.temp_raw is null then null
              when v_temp_min is not null and t_raw.temp_raw < v_temp_min then null
              when v_temp_max is not null and t_raw.temp_raw > v_temp_max then null
              else t_raw.temp_raw end as temp,
         case when h_raw.hum_raw is null then null
              when v_hum_min is not null and h_raw.hum_raw < v_hum_min then null
              when v_hum_max is not null and h_raw.hum_raw > v_hum_max then null
              else h_raw.hum_raw end as hum,
         t_raw.temp_fuera, h_raw.hum_fuera
    from registros r
    join lateral (
      select numero_limpio(max(rp.valor)) as temp_raw,
             bool_or(valor_fuera_de_rango(rp.pregunta_id, rp.valor)) as temp_fuera
        from respuestas rp where rp.registro_id = r.id and rp.pregunta_id in ('THA_002','THP_002')
    ) t_raw on true
    join lateral (
      select numero_limpio(max(rp.valor)) as hum_raw,
             bool_or(valor_fuera_de_rango(rp.pregunta_id, rp.valor)) as hum_fuera
        from respuestas rp where rp.registro_id = r.id and rp.pregunta_id in ('THA_003','THP_003')
    ) h_raw on true
   where r.formulario_id = any(v_forms)
     and coalesce(r.estado,'') <> 'ANULADO'
     and r.linea = v_linea
     and r.fecha between fi and ff
     and (ciu = '' or r.ciudad = ciu)
     and (proy = '' or r.proyecto = proy);

  select count(*) into descartadas from tmp_temp
   where (temp_raw is not null and temp is null) or (hum_raw is not null and hum is null);

  resumen := (
    select jsonb_build_object(
      'tomas', count(*),
      'temp_prom', round(avg(temp),1), 'temp_max', max(temp), 'temp_min', min(temp),
      'hum_prom', round(avg(hum),1), 'hum_max', max(hum), 'hum_min', min(hum),
      'cumple_temp_pct', case when count(temp) > 0
        then round(100 - (count(*) filter (where temp_fuera))::numeric * 100 / count(temp), 1) end,
      'cumple_hum_pct', case when count(hum) > 0
        then round(100 - (count(*) filter (where hum_fuera))::numeric * 100 / count(hum), 1) end,
      'descartadas', descartadas)
    from tmp_temp);

  serie := coalesce((
    select jsonb_agg(jsonb_build_object(
      'fecha', to_char(s.fecha,'YYYY-MM-DD'),
      'temp_prom', s.temp_prom, 'temp_max', s.temp_max, 'temp_min', s.temp_min,
      'hum_prom', s.hum_prom, 'hum_max', s.hum_max, 'hum_min', s.hum_min,
      'tomas', s.tomas) order by s.fecha)
    from (
      select fecha, round(avg(temp),1) as temp_prom, max(temp) as temp_max, min(temp) as temp_min,
             round(avg(hum),1) as hum_prom, max(hum) as hum_max, min(hum) as hum_min,
             count(*) as tomas
        from tmp_temp
       group by fecha) s), '[]'::jsonb);

  -- 'alerta' es cierto si alguna lectura de esa persona en el periodo se
  -- salio del rango normal (25 °C) -no del rango posible, ese ya se
  -- descarto antes de llegar aqui-. El frontend lo pinta en rojo.
  top_temp := coalesce((
    select jsonb_agg(to_jsonb(t) order by t.temp_max desc, t.temp_prom desc)
    from (
      select nombre, ciudad, proyecto,
             max(temp) as temp_max, round(avg(temp),1) as temp_prom, count(*) as tomas,
             bool_or(temp_fuera) as alerta
        from tmp_temp
       where temp is not null
       group by cedula, nombre, ciudad, proyecto
       order by max(temp) desc, avg(temp) desc
       limit 10) t), '[]'::jsonb);

  ciudades := coalesce((
    select jsonb_agg(distinct r.ciudad order by r.ciudad)
      from registros r
     where r.formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM')
       and coalesce(r.estado,'') <> 'ANULADO'
       and r.linea = v_linea
       and r.ciudad is not null and r.ciudad <> ''), '[]'::jsonb);

  proyectos := coalesce((
    select jsonb_agg(distinct r.proyecto order by r.proyecto)
      from registros r
     where r.formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM')
       and coalesce(r.estado,'') <> 'ANULADO'
       and r.linea = v_linea
       and r.proyecto is not null and r.proyecto <> ''), '[]'::jsonb);

  return jsonb_build_object(
    'filtros', jsonb_build_object('desde', to_char(fi,'YYYY-MM-DD'), 'hasta', to_char(ff,'YYYY-MM-DD'), 'ciudad', ciu, 'proyecto', proy, 'jornada', jornada),
    'resumen', resumen, 'serie', serie, 'top_temperatura', top_temp, 'ciudades', ciudades, 'proyectos', proyectos);
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
select prosrc like '%jornada%' as tiene_jornada,
       prosrc like '%proyectos%' as tiene_proyectos,
       prosrc like '%bool_or(temp_fuera) as alerta%' as tiene_alerta
  from pg_proc where proname = 'api_temperatura';
