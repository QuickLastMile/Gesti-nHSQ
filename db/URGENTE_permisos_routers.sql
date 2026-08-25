-- ============================================================
--  URGENTE — Restaurar el control de acceso de los routers
--  ------------------------------------------------------------
--  Al reescribir hseq_api y hseq_admin para agregarles acciones
--  nuevas, se perdió la validación de rol que traían. Quedaron
--  así:
--
--  hseq_api  está concedido a anon (la llave pública que va en
--            assets/config.js, visible para cualquiera). Sin la
--            validación, cualquier persona con esa llave podía
--            llamar generarExportable, getDashboard,
--            anularRegistro o incluso actualizarMatriz.
--
--  hseq_admin está concedido a authenticated. Sin la validación,
--            cualquier sesión iniciada — un coordinador, o la
--            sesión anónima que usa el mensajero para subir
--            fotos — podía editar la matriz de colaboradores.
--
--  Este script devuelve las dos validaciones y conserva TODAS las
--  acciones que existen hoy. Correrlo cuanto antes.
--
--  Ejecutar DESPUÉS de: FIX_encargados_ceco.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) Router público: el mensajero solo puede lo suyo
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
                'getMatrizInfo','listaEncargados','alertasMantenimiento')
     and not hseq_tiene_rol(array['ADMIN','HSEQ','COORDINADOR']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como coordinador autorizado.');
  end if;

  case action
    -- Abiertas: el mensajero las usa sin iniciar sesión.
    when 'getBootstrap'         then result := api_get_bootstrap();
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
    when 'getMatrizInfo'        then result := api_matriz_info();
    when 'alertasMantenimiento' then result := api_alertas_mantenimiento(payload);
    when 'listaEncargados'      then result := api_lista_encargados();
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

grant execute on function hseq_api(text, jsonb) to anon;

-- ------------------------------------------------------------
-- 1.b) Asignar un coordinador a MUCHOS proyectos de una vez
--      Un coordinador con 20 proyectos no se puede cargar a mano.
-- ------------------------------------------------------------
create or replace function admin_coordinador_masivo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  coord text := nullif(upper(btrim(coalesce(payload->>'coordinador',''))), '');
  ids text[];
  n int := 0;
  con_partes int := 0;
begin
  select array_agg(btrim(v))
    into ids
    from jsonb_array_elements_text(coalesce(payload->'proyectos', '[]'::jsonb)) v
   where btrim(v) <> '';
  if ids is null or array_length(ids, 1) is null then
    raise exception 'Selecciona al menos un proyecto.';
  end if;

  -- Solo toca el coordinador: el jefe y el lider de cada proyecto se conservan.
  insert into responsables_proyecto (proyecto_id, frente, coordinador)
  select unnest(ids), '', coord
  on conflict (proyecto_id, frente) do update
    set coordinador = excluded.coordinador, actualizado_en = now();
  get diagnostics n = row_count;

  -- Un proyecto dividido en partes ya tiene su propio coordinador por parte:
  -- ahi este pasa a ser el de respaldo, no reemplaza a los demas.
  select count(distinct proyecto_id) into con_partes
    from responsables_proyecto
   where proyecto_id = any(ids) and frente <> '';

  perform recalcular_encargados();

  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null,
          'Coordinador ' || coalesce(coord, '(sin coordinador)') || ' asignado a ' || n || ' proyecto(s).');

  return jsonb_build_object(
    'proyectos', n, 'con_partes', con_partes,
    'mensaje', case when coord is null
      then 'Se quito el coordinador de ' || n || ' proyecto(s).'
      else coord || ' queda como coordinador de ' || n || ' proyecto(s).'
        || case when con_partes > 0
             then ' En ' || con_partes || ' de ellos hay partes con su propio coordinador: ahi cubre solo a quien no este en ninguna.'
             else '' end
    end);
end;
$fn$;

revoke all on function admin_coordinador_masivo(jsonb) from public, anon;
grant execute on function admin_coordinador_masivo(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 1.c) La carga masiva acepta una quinta columna: COORDINADOR
--      Asi la tabla de Excel puede traerlo todo de una vez.
-- ------------------------------------------------------------
create or replace function admin_cargar_encargados(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fila jsonb;
  pid text; cli text; jef text; lid text; coo text;
  creados int := 0; actualizados int := 0; ignorados int := 0;
  ya boolean;
begin
  if jsonb_typeof(payload->'filas') <> 'array' then
    raise exception 'No llegaron filas para cargar.';
  end if;

  for fila in select * from jsonb_array_elements(payload->'filas') loop
    pid := btrim(coalesce(fila->>'proyecto_id',''));
    cli := nullif(btrim(coalesce(fila->>'cliente','')),'');
    jef := nullif(upper(btrim(coalesce(fila->>'jefatura',''))),'');
    lid := nullif(upper(btrim(coalesce(fila->>'lider',''))),'');
    coo := nullif(upper(btrim(coalesce(fila->>'coordinador',''))),'');

    if pid = '' then ignorados := ignorados + 1; continue; end if;

    select true into ya from responsables_proyecto where proyecto_id = pid and frente = '' limit 1;
    if found then
      -- Un campo vacio no borra lo que ya estaba guardado.
      update responsables_proyecto set
        cliente     = coalesce(cli, cliente),
        jefatura    = coalesce(jef, jefatura),
        lider       = coalesce(lid, lider),
        coordinador = coalesce(coo, coordinador),
        actualizado_en = now()
      where proyecto_id = pid and frente = '';
      actualizados := actualizados + 1;
    else
      insert into responsables_proyecto (proyecto_id, frente, cliente, jefatura, lider, coordinador)
      values (pid, '', cli, jef, lid, coo);
      creados := creados + 1;
    end if;
    ya := null;
  end loop;

  perform recalcular_encargados();

  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null, 'Carga de encargados: ' || creados || ' nuevos, ' || actualizados || ' actualizados.');

  return jsonb_build_object(
    'creados', creados, 'actualizados', actualizados, 'ignorados', ignorados,
    'proyectos_sin_jefe', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_jefatura,'') = ''),
    'proyectos_sin_lider', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_lider,'') = ''),
    'mensaje', 'Listo. ' || creados || ' proyecto(s) nuevos y ' || actualizados || ' actualizados.');
end;
$fn$;

-- ------------------------------------------------------------
-- 2) Router de administración: solo HSQ
--    Incluye la actualización de matriz, que se muda aquí desde
--    la pantalla de coordinadores.
-- ------------------------------------------------------------
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare result jsonb;
begin
  -- Sesión real de HSQ. La sesión anónima que usa el mensajero para
  -- subir fotos también cuenta como "authenticated": por eso se
  -- descarta aparte.
  if coalesce((select auth.role()), 'anon') <> 'authenticated'
     or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
     or not hseq_tiene_rol(array['ADMIN','HSEQ']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
  end if;

  case action
    when 'buscarColaborador'         then result := admin_buscar_colaborador(payload);
    when 'listar'                    then result := admin_listar(payload);
    when 'proyectos'                 then result := admin_proyectos();
    when 'guardarColaborador'        then result := admin_guardar_colaborador(payload);
    when 'calendario'                then result := admin_calendario();
    when 'guardarCalendario'         then result := admin_guardar_calendario(payload);
    when 'formulariosProyecto'       then result := admin_formularios_proyecto();
    when 'guardarFormularioProyecto' then result := admin_guardar_formulario_proyecto(payload);
    when 'crearProvisional'          then result := admin_crear_provisional(payload);
    when 'moverProyecto'             then result := admin_mover_proyecto(payload);
    when 'alertasMantenimiento'      then result := api_alertas_mantenimiento(payload);
    when 'encargados'                then result := admin_encargados();
    when 'guardarEncargado'          then result := admin_guardar_encargado(payload);
    when 'cargarEncargados'          then result := admin_cargar_encargados(payload);
    when 'personasProyecto'          then result := admin_personas_proyecto(payload);
    when 'asignarFrente'             then result := admin_asignar_frente(payload);
    when 'coordinadorMasivo'         then result := admin_coordinador_masivo(payload);
    when 'listaEncargados'           then result := api_lista_encargados();
    -- Nuevas: la matriz se actualiza desde Administración.
    when 'actualizarMatriz'          then result := api_actualizar_matriz(payload);
    when 'getMatrizInfo'             then result := api_matriz_info();
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

revoke execute on function hseq_admin(text, jsonb) from anon;
grant execute on function hseq_admin(text, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3) Comprobación
--    Debe decir "protegido" en las dos filas.
-- ------------------------------------------------------------
select 'hseq_api' as router,
       case when pg_get_functiondef(p.oid) like '%hseq_tiene_rol%'
            then 'protegido' else 'SIN PROTECCION' end as estado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'hseq_api'
union all
select 'hseq_admin',
       case when pg_get_functiondef(p.oid) like '%hseq_tiene_rol%'
            then 'protegido' else 'SIN PROTECCION' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'hseq_admin';
