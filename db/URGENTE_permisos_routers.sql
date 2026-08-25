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
