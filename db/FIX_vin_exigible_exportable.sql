-- ============================================================
--  El exportable de documentacion exige el VIN completo
--  ------------------------------------------------------------
--  Hasta ahora 'datos_vehiculo_completos' decia SI con cualquier
--  VIN escrito, aunque fueran 6 digitos. Tener el dato escrito
--  no es tenerlo: un VIN incompleto no identifica ningun
--  vehiculo.
--
--  Ahora exige los 17 caracteres, y ademas se agrega una columna
--  'vin_valido' para poder ver de un vistazo a quien hay que
--  perseguir.
--
--  Requiere db/exportable_documentacion.sql ya corrido.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- Va como VOLATILE (sin 'stable') a proposito: adentro crea una tabla
-- temporal, y eso es escribir. Declararla estable seria prometerle al
-- motor algo que no cumple.
create or replace function api_exportable_documentacion(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_linea     text := linea_efectiva(coalesce(payload->>'linea', ''));
  filtro_proy text := btrim(coalesce(payload->>'proyecto', ''));
  proy_nom    text;
  ncedula     text := regexp_replace(coalesce(payload->>'cedula', ''), '\D', '', 'g');
  hoy         date := (now() at time zone 'America/Bogota')::date;
  filas       jsonb;
  n           int;
begin
  if not es_cuenta_general() then
    raise exception 'Solo la cuenta general puede descargar la documentacion.';
  end if;

  -- El filtro puede venir como nombre o como codigo de proyecto.
  if filtro_proy <> '' then
    proy_nom := coalesce(nombre_proyecto(filtro_proy), filtro_proy);
  end if;

  -- La ultima respuesta no vacia de cada persona para cada dato del
  -- vehiculo. Se arma UNA vez para todos, no una consulta por persona.
  drop table if exists pg_temp.tmp_veh;
  create temp table tmp_veh on commit drop as
  select z.ced_norm, jsonb_object_agg(z.campo, z.valor) as datos
    from (
      select distinct on (y.ced_norm, y.campo) y.ced_norm, y.campo, y.valor
        from (
          select regexp_replace(rg.cedula, '\D', '', 'g') as ced_norm,
                 pv.campo, r2.valor, rg.fecha, rg.hora
            from preguntas_del_vehiculo() pv
            join respuestas r2 on r2.pregunta_id = pv.id
            join registros  rg on rg.id = r2.registro_id
           where pv.campo is not null
             and coalesce(btrim(r2.valor), '') <> ''
             and coalesce(rg.estado, '') <> 'ANULADO'
        ) y
       order by y.ced_norm, y.campo, y.fecha desc, y.hora desc
    ) z
   group by z.ced_norm;

  create index on tmp_veh (ced_norm);

  select coalesce(jsonb_agg(t.fila order by t.proyecto, t.nombre), '[]'::jsonb),
         count(*)
    into filas, n
  from (
    select
      coalesce(c.proyecto_efectivo, c.proyecto, '') as proyecto,
      coalesce(c.nombre, '')                        as nombre,
      jsonb_build_object(
        'cedula',      c.cedula,
        'nombre',      coalesce(c.nombre, ''),
        'cargo',       coalesce(c.cargo, ''),
        'tipo',        perfil_cargo(c.cargo),
        'proyecto_id', coalesce(c.proyecto_id, ''),
        'proyecto',    coalesce(c.proyecto_efectivo, c.proyecto, ''),
        'ciudad',      coalesce(c.ciudad, ''),
        'linea',       coalesce(c.linea, ''),
        'jefatura',    coalesce(c.enc_jefatura, ''),
        'lider',       coalesce(c.enc_lider, ''),
        'coordinador', coalesce(c.enc_coordinador, ''),

        -- Vehiculo. La marca y el cilindraje se guardan en la matriz;
        -- si ahi faltan, se cae a la respuesta del formulario.
        'placa_registrada', coalesce(c.placa_moto, ''),
        'tipo_vehiculo',    coalesce(c.tipo_vehiculo, ''),
        'marca_vehiculo',   coalesce(nullif(btrim(coalesce(c.marca_vehiculo, '')), ''),
                                     v.datos->>'marca_vehiculo', ''),
        'cilindraje',       coalesce(nullif(btrim(coalesce(c.cilindraje, '')), ''),
                                     v.datos->>'cilindraje', ''),
        -- Estas tres solo existen como respuesta del preoperacional.
        'propietario_nombre', coalesce(v.datos->>'propietario_nombre', ''),
        'propietario_cedula', coalesce(v.datos->>'propietario_cedula', ''),
        'vin',                coalesce(v.datos->>'vin', ''),

        -- Vencimientos
        'soat_vence',          coalesce(to_char(c.soat_vence, 'YYYY-MM-DD'), ''),
        'tecnomecanica_vence', coalesce(to_char(c.tecnomecanica_vence, 'YYYY-MM-DD'), ''),
        'licencia_vence',      coalesce(to_char(c.licencia_vence, 'YYYY-MM-DD'), ''),

        -- Que hay adjunto y que falta: esta es la pregunta de fondo.
        'soat_adjunto',          case when coalesce(btrim(c.soat_url), '') <> ''          then 'SI' else 'NO' end,
        'tecnomecanica_adjunta', case when coalesce(btrim(c.tecnomecanica_url), '') <> '' then 'SI' else 'NO' end,
        'licencia_adjunta',      case when coalesce(btrim(c.licencia_url), '') <> ''      then 'SI' else 'NO' end,
        'documentacion_completa',
          case when coalesce(btrim(c.soat_url), '') <> ''
                and coalesce(btrim(c.tecnomecanica_url), '') <> ''
                and coalesce(btrim(c.licencia_url), '') <> ''
               then 'SI' else 'NO' end,
        -- Un VIN de 6 digitos no identifica ningun vehiculo: tenerlo
        -- escrito no es tenerlo. Aqui se exige que sean los 17.
        'vin_valido',
          case when upper(regexp_replace(coalesce(v.datos->>'vin', ''), '[[:space:]-]', '', 'g')) ~ '^[A-Z0-9]{17}$'
               then 'SI' else 'NO' end,
        'datos_vehiculo_completos',
          case when upper(regexp_replace(coalesce(v.datos->>'vin', ''), '[[:space:]-]', '', 'g')) ~ '^[A-Z0-9]{17}$'
                and coalesce(v.datos->>'propietario_nombre', '') <> ''
                and coalesce(v.datos->>'propietario_cedula', '') <> ''
               then 'SI' else 'NO' end,
        'estado_documental',
          case
            when coalesce(btrim(c.soat_url), '') = ''
              or coalesce(btrim(c.tecnomecanica_url), '') = ''
              or coalesce(btrim(c.licencia_url), '') = ''      then 'SIN DOCUMENTACION'
            when c.soat_vence is null or c.tecnomecanica_vence is null
              or c.licencia_vence is null                      then 'SIN FECHAS'
            when least(c.soat_vence, c.tecnomecanica_vence, c.licencia_vence) < hoy
                                                               then 'VENCIDA'
            when least(c.soat_vence, c.tecnomecanica_vence, c.licencia_vence) <= hoy + 15
                                                               then 'POR VENCER'
            else 'AL DIA'
          end,

        -- Cuando cargo la documentacion por primera vez. Queda en el
        -- historial cada vez que responde SI a "primera vez o renovacion".
        'documentos_cargados_el', coalesce(to_char(d.primera at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'), ''),
        'ultima_actualizacion',   coalesce(to_char(d.ultima  at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'), ''),

        -- Los enlaces van como "evidencias" a proposito: asi la pantalla
        -- los firma con el mismo camino que usa el exportable normal.
        'evidencias', (
          select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb)
            from (values ('SOAT', c.soat_url),
                         ('TECNOMECANICA', c.tecnomecanica_url),
                         ('LICENCIA', c.licencia_url)) as e(k, v)
           where coalesce(btrim(e.v), '') <> '')
      ) as fila
    from colaboradores c
    left join tmp_veh v on v.ced_norm = regexp_replace(c.cedula, '\D', '', 'g')
    left join lateral (
      select min(h.creado_en) as primera, max(h.creado_en) as ultima
        from historial h
       where h.tipo = 'DOCUMENTOS'
         and regexp_replace(coalesce(h.cedula, ''), '\D', '', 'g')
           = regexp_replace(c.cedula, '\D', '', 'g')
    ) d on true
    where c.activo
      and c.linea = v_linea
      and (filtro_proy = '' or coalesce(c.proyecto_efectivo, c.proyecto, '') = proy_nom)
      and (ncedula = '' or regexp_replace(c.cedula, '\D', '', 'g') = ncedula)
  ) t;

  return jsonb_build_object('filas', filas, 'total', n, 'linea', v_linea);
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya exige los 17.
select case when prosrc like '%[A-Z0-9]{17}%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_exportable_documentacion';

-- b) Cuantos VIN guardados no cumplen, por linea. Estos son los que
--    van a cambiar de SI a NO en el exportable.
select c.linea,
       count(*) as con_vin,
       count(*) filter (
         where upper(regexp_replace(x.valor, '[[:space:]-]', '', 'g')) !~ '^[A-Z0-9]{17}$'
       ) as vin_incompleto
  from colaboradores c
  join lateral (
    select r.valor
      from respuestas r
      join registros rg on rg.id = r.registro_id
     where r.pregunta_id = 'DOC_VIN'
       and coalesce(btrim(coalesce(r.valor,'')), '') <> ''
       and coalesce(rg.estado,'') <> 'ANULADO'
       and regexp_replace(rg.cedula, '\D', '', 'g') = regexp_replace(c.cedula, '\D', '', 'g')
     order by rg.fecha desc, rg.hora desc
     limit 1) x on true
 where c.activo
 group by c.linea
 order by c.linea;
