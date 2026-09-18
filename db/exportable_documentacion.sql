-- ============================================================
--  Exportable de DOCUMENTACION de colaboradores
--  ------------------------------------------------------------
--  Hasta ahora Exportar sacaba respuestas de formularios: una
--  fila por registro diligenciado, dentro de un rango de fechas.
--
--  Esto es otra cosa. Es el estado de HOY de la matriz: una fila
--  por colaborador ACTIVO, con sus datos basicos, los del
--  vehiculo y el estado de su documentacion. Por eso NO recibe
--  fechas: no es un historico, es una foto del momento. Se acota
--  por proyecto o por cedula.
--
--  Sirve para lo que se pidio: ver de un vistazo quien tiene la
--  informacion completa y quien no.
--
--  Reservado a la CUENTA GENERAL. La guarda esta aqui, no en la
--  pantalla.
--
--  DE DONDE SALE CADA DATO
--  -----------------------
--  Hay dos origenes y conviene tenerlo claro:
--
--   - De la tabla colaboradores: nombre, cedula, cargo, proyecto,
--     ciudad, placa registrada, tipo de vehiculo, marca,
--     cilindraje, vencimientos y enlaces de los documentos.
--
--   - De las RESPUESTAS del preoperacional: propietario del
--     vehiculo (nombre y cedula) y VIN. Esas tres se preguntan al
--     registrar por primera vez, pero no se guardan como columna
--     de la matriz: viven como respuestas. Se toma la ultima
--     respuesta no vacia de cada persona, que es el valor vigente.
--
--  Ojo con esas tres: no son filas de la tabla preguntas. El bloque
--  de documentacion lo antepone la pantalla con ids fijos, y en la
--  base solo quedan las respuestas. Ver la nota del punto 2.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  0) Por si acaso: quien es la cuenta general
--  ------------------------------------------------------------
--  Va aqui tambien para que este script no dependa de haber
--  corrido antes db/seguridad_cuentas.sql.
-- ------------------------------------------------------------
create or replace function es_cuenta_general()
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce((select r.todas_lineas from app_roles r
                    where r.user_id = auth.uid() and r.activo), false);
$fn$;

revoke all on function es_cuenta_general() from public, anon;
grant execute on function es_cuenta_general() to authenticated;

-- ------------------------------------------------------------
--  1) Para que buscar la ultima respuesta no cueste un rastreo
--     completo de la tabla.
-- ------------------------------------------------------------
create index if not exists idx_resp_pregunta on respuestas (pregunta_id);

-- ------------------------------------------------------------
--  2) Que pregunta corresponde a que dato
--  ------------------------------------------------------------
--  OJO: estas preguntas NO estan en la tabla preguntas. El bloque
--  de "Documentacion del vehiculo" lo antepone la pantalla
--  (assets/api.js, constante DOCS_PREOP) con ids fijos, y lo
--  unico que queda en la base son las RESPUESTAS. Por eso aqui
--  van los ids escritos: no hay texto que buscar.
--
--  Si algun dia se cambia un id en api.js, hay que cambiarlo
--  tambien aqui o esa columna sale vacia.
-- ------------------------------------------------------------
create or replace function preguntas_del_vehiculo()
returns table (id text, campo text)
language sql immutable set search_path = public as $fn$
  select * from (values
    ('DOC_VIN',           'vin'),
    ('DOC_PROP_NOMBRE',   'propietario_nombre'),
    ('DOC_PROP_CEDULA',   'propietario_cedula'),
    ('DOC_MARCA_VEHICULO','marca_vehiculo'),
    ('DOC_CILINDRAJE',    'cilindraje')
  ) as v(id, campo);
$fn$;

-- ------------------------------------------------------------
--  3) La consulta
-- ------------------------------------------------------------
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
        'datos_vehiculo_completos',
          case when coalesce(v.datos->>'vin', '') <> ''
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
--  4) El router
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare result jsonb;
begin
  -- Lo que ve o mueve datos de toda la operación exige sesión de
  -- coordinador. El resto queda abierto: es lo que usa el mensajero
  -- desde su celular, sin login.
  if action in ('getCumplimientoDia','guardarJustificacion','getDashboard',
                'generarExportable','anularRegistro','actualizarMatriz',
                'getMatrizInfo','listaEncargados','alertasMantenimiento',
                'exportarDocumentacion')
     and not hseq_tiene_rol(array['ADMIN','HSEQ','COORDINADOR']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como coordinador autorizado.');
  end if;

  case action
    -- Abiertas: el mensajero las usa sin iniciar sesión.
    when 'getBootstrap'         then result := api_get_bootstrap(payload);
    when 'buscarActivo'         then result := api_buscar_activo(payload);
    when 'cargarFormulario'     then result := api_cargar_formulario(payload);
    when 'guardarRegistro'      then result := api_guardar_registro(payload);
    when 'registrarPlaca'       then result := api_registrar_placa(payload);
    when 'miCumplimiento'       then result := api_mi_cumplimiento(payload);
    -- Protegidas por el filtro de arriba.
    when 'getCumplimientoDia'   then result := api_cumplimiento_dia(payload);
    when 'guardarJustificacion' then result := api_guardar_justificacion(payload);
    when 'getDashboard'         then result := api_dashboard(payload);
    when 'generarExportable'    then result := api_exportable(payload);
    when 'anularRegistro'       then result := api_anular_registro(payload);
    when 'actualizarMatriz'     then result := api_actualizar_matriz(payload);
    -- Esta no depende de la linea: lee una sola fila de config.
    when 'getMatrizInfo'        then result := api_matriz_info();
    when 'alertasMantenimiento' then result := api_alertas_mantenimiento(payload);
    when 'listaEncargados'      then result := api_lista_encargados(payload);
    -- Solo cuenta general (la guarda esta dentro de la funcion).
    when 'exportarDocumentacion' then result := api_exportable_documentacion(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Cuanta gente tiene ya cada dato guardado. Si alguna fila sale
--    en cero, es que nadie ha respondido esa pregunta todavia: el
--    bloque solo aparece al responder SI a "primera vez o renovacion".
select pv.campo,
       count(distinct regexp_replace(rg.cedula, '\D', '', 'g')) as personas_con_dato
  from preguntas_del_vehiculo() pv
  left join respuestas r2 on r2.pregunta_id = pv.id
                         and coalesce(btrim(r2.valor), '') <> ''
  left join registros  rg on rg.id = r2.registro_id
                         and coalesce(rg.estado, '') <> 'ANULADO'
 group by pv.campo
 order by pv.campo;

-- b) El router ya la conoce.
select case when prosrc like '%exportarDocumentacion%' then 'ARREGLADO'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'hseq_api';

-- c) Cuantos activos hay por linea y cuantos estan completos.
select c.linea,
       count(*) as activos,
       count(*) filter (
         where coalesce(btrim(c.soat_url),'') <> ''
           and coalesce(btrim(c.tecnomecanica_url),'') <> ''
           and coalesce(btrim(c.licencia_url),'') <> ''
       ) as con_los_tres_documentos
  from colaboradores c
 where c.activo
 group by c.linea
 order by c.linea;
