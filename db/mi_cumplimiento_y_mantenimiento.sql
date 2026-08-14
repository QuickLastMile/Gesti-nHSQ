-- ============================================================
--  Gestión HSEQ Motos — Dos funciones nuevas
--  ------------------------------------------------------------
--  1) miCumplimiento     el mensajero consulta cómo va en el mes
--  2) alertasMantenimiento  fallas repetidas en el mismo punto,
--                        para intervenir antes de que sea un daño
--
--  Ejecutar DESPUÉS de: calendario_laboral.sql y functions_coord2.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================


-- ============================================================
--  1) CÓMO VOY ESTE MES
--     Usa el mismo cálculo del tablero: respeta los días que
--     labora el proyecto y descuenta las ausencias justificadas.
-- ============================================================
create or replace function api_mi_cumplimiento(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  hoy date := (now() at time zone 'America/Bogota')::date;
  anio int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes  int := coalesce(nullif(payload->>'mes','')::int, extract(month from hoy)::int);
  desde date; hasta date;
  c colaboradores%rowtype;
  dias_lab smallint[]; fest boolean; meta numeric;
  formularios int;
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

  desde := make_date(anio, mes, 1);
  hasta := least((desde + interval '1 month - 1 day')::date, hoy);
  if hasta < desde then
    return jsonb_build_object('sin_datos', true, 'mensaje', 'Ese mes todavia no empieza.');
  end if;

  -- Calendario del proyecto (o el de por defecto)
  select coalesce(pc.dias_laborales,
           coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
                    '{1,2,3,4,5,6}'::smallint[])),
         coalesce(pc.labora_festivos,
           coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false)),
         coalesce(pc.meta, 90)
    into dias_lab, fest, meta
    from (select 1) z
    left join proyectos_calendario pc on pc.proyecto = coalesce(c.proyecto,'');

  dias_lab := coalesce(dias_lab, '{1,2,3,4,5,6}'::smallint[]);
  fest := coalesce(fest, false);
  meta := coalesce(meta, 90);

  select count(*) into formularios
    from proyectos_formularios pf
    join formularios f on f.id = pf.formulario_id and f.activo
   where pf.proyecto = coalesce(c.proyecto,'') and pf.activo;

  if formularios = 0 then
    return jsonb_build_object('sin_datos', true,
      'mensaje', 'Tu proyecto no tiene formularios asignados, asi que no se te exige registro.');
  end if;

  -- Días exigibles del mes para esta persona
  select count(*) into dias
    from generate_series(desde, hasta, interval '1 day') g
   where extract(isodow from g)::smallint = any(dias_lab)
     and (fest or not exists (select 1 from festivos x where x.fecha = g::date))
     and not exists (
       select 1 from justificaciones j
        where regexp_replace(j.cedula,'\D','','g') = ncedula
          and g::date between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha));

  esperados := dias * formularios;

  select count(*) into realizados
    from registros r
   where regexp_replace(r.cedula,'\D','','g') = ncedula
     and r.fecha between desde and hasta
     and coalesce(r.estado,'') <> 'ANULADO';

  pct := case when esperados > 0 then round(realizados * 100.0 / esperados, 1) else 0 end;

  select max(fecha) into ultimo from registros
   where regexp_replace(cedula,'\D','','g') = ncedula and coalesce(estado,'') <> 'ANULADO';

  -- Racha: días exigibles seguidos, hacia atrás, con todos los formularios hechos
  d := hoy;
  loop
    exit when d < hoy - 120;                      -- tope de búsqueda
    exigible := extract(isodow from d)::smallint = any(dias_lab)
      and (fest or not exists (select 1 from festivos x where x.fecha = d))
      and not exists (select 1 from justificaciones j
                       where regexp_replace(j.cedula,'\D','','g') = ncedula
                         and d between coalesce(j.fecha_inicio, j.fecha) and coalesce(j.fecha_fin, j.fecha));
    if exigible then
      select count(*) into hechos from registros
       where regexp_replace(cedula,'\D','','g') = ncedula
         and fecha = d and coalesce(estado,'') <> 'ANULADO';
      -- El día de hoy todavía puede completarse: no corta la racha.
      if hechos >= formularios then racha := racha + 1;
      elsif d = hoy then null;
      else exit;
      end if;
    end if;
    d := d - 1;
  end loop;

  return jsonb_build_object(
    'nombre', coalesce(c.nombre,''),
    'proyecto', coalesce(c.proyecto,''),
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
$$;


-- ============================================================
--  2) ALERTAS DE MANTENIMIENTO
--     Un "No cumple" puede ser un mal día. El mismo punto en mal
--     estado varias veces seguidas es un daño sin atender.
--     Parámetros: dias (ventana, 30 por defecto), minimo (3),
--     proyecto (opcional).
-- ============================================================
create or replace function api_alertas_mantenimiento(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  ventana int := greatest(7, least(180, coalesce(nullif(payload->>'dias','')::int, 30)));
  minimo int := greatest(2, least(10, coalesce(nullif(payload->>'minimo','')::int, 3)));
  proy text := btrim(coalesce(payload->>'proyecto',''));
  filas jsonb;
begin
  select coalesce(jsonb_agg(t order by t.veces desc, t.ultima desc), '[]'::jsonb)
    into filas
  from (
    select r.cedula,
           max(r.nombre) as nombre,
           max(r.placa_moto) as placa,
           max(r.proyecto) as proyecto,
           max(p.pregunta) as punto,
           res.pregunta_id,
           count(*)::int as veces,
           min(r.fecha) as primera,
           max(r.fecha) as ultima
      from respuestas res
      join registros r on r.id = res.registro_id
      join preguntas p on p.id = res.pregunta_id
     where r.fecha >= hoy - ventana
       and coalesce(r.estado,'') <> 'ANULADO'
       and sin_tildes(res.valor) = 'NO CUMPLE'
       and (proy = '' or r.proyecto = proy)
     group by r.cedula, res.pregunta_id
    having count(*) >= minimo
  ) t;

  return jsonb_build_object(
    'desde', to_char(hoy - ventana, 'YYYY-MM-DD'),
    'hasta', to_char(hoy, 'YYYY-MM-DD'),
    'minimo', minimo,
    'alertas', filas,
    'total', jsonb_array_length(filas)
  );
end;
$$;


-- ============================================================
--  3) Router: se agregan las dos acciones nuevas conservando
--     TODAS las que ya existían (coordinador, dashboard, matriz).
-- ============================================================
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  case action
    when 'getBootstrap'         then result := api_get_bootstrap();
    when 'buscarActivo'         then result := api_buscar_activo(payload);
    when 'cargarFormulario'     then result := api_cargar_formulario(payload);
    when 'guardarRegistro'      then result := api_guardar_registro(payload);
    when 'registrarPlaca'       then result := api_registrar_placa(payload);
    when 'getCumplimientoDia'   then result := api_cumplimiento_dia(payload);
    when 'guardarJustificacion' then result := api_guardar_justificacion(payload);
    when 'getDashboard'         then result := api_dashboard(payload);
    when 'generarExportable'    then result := api_exportable(payload);
    when 'anularRegistro'       then result := api_anular_registro(payload);
    when 'actualizarMatriz'     then result := api_actualizar_matriz(payload);
    when 'getMatrizInfo'        then result := api_matriz_info();
    -- nuevas
    when 'miCumplimiento'       then result := api_mi_cumplimiento(payload);
    when 'alertasMantenimiento' then result := api_alertas_mantenimiento(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function hseq_api(text, jsonb) to anon;

-- ------------------------------------------------------------
--  Comprobación
-- ------------------------------------------------------------
-- select hseq_api('miCumplimiento', '{"cedula":"1003706159"}'::jsonb);
-- select api_alertas_mantenimiento('{"dias":60,"minimo":2}'::jsonb);
