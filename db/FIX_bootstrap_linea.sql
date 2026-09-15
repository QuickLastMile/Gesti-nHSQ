-- ============================================================
--  FIX - La cuenta general siempre veia los formularios de la
--        primera linea, sin importar cual escogiera
--  ------------------------------------------------------------
--  SINTOMA: con el usuario global, al cambiar el desplegable a
--  Warehouse, el filtro de formularios seguia mostrando los de
--  Last Mile -sin temperatura y humedad-. Con el usuario de
--  Warehouse si aparecian.
--
--  CAUSA: el router hseq_api llamaba 'api_get_bootstrap()' sin
--  pasarle el payload. Cuando a esa funcion se le agrego el
--  parametro 'linea', el llamado del router nunca se actualizo.
--  Sin linea, linea_efectiva('') devuelve la PRIMERA linea
--  permitida:
--
--    - cuenta de Warehouse -> solo tiene una, acierta por azar.
--    - cuenta general      -> tiene las dos, y la primera por
--                             orden es Last Mile. Siempre.
--
--  Por eso el error solo se veia desde la cuenta general: era el
--  unico usuario con mas de una linea donde escoger.
--
--  Lo mismo le pasaba a 'api_lista_encargados()'. La pantalla lo
--  esquivaba llamando a la funcion por fuera del router, asi que
--  no se noto; igual se corrige aqui, que es donde debe estar.
--
--  Nada mas cambia: el resto del router queda igual.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

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
    -- getBootstrap SI lleva payload: la linea viene ahi. Solo la
    -- llaman pantallas con sesion (Cumplimiento y Dashboard).
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
-- a) El router ya le pasa la linea a las dos que la necesitaban.
select case when prosrc like '%api_get_bootstrap(payload)%'
             and prosrc like '%api_lista_encargados(payload)%'
            then 'ARREGLADO' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'hseq_api';

-- b) Una sola firma por funcion, sin duplicados que confundan.
select p.oid::regprocedure as firma
  from pg_proc p
 where p.proname in ('hseq_api','api_get_bootstrap','api_lista_encargados')
 order by p.proname;

-- c) Que formularios deberia ver cada linea. Aqui es donde debe
--    aparecer temperatura para WAREHOUSE.
select l.id as linea, f.id as formulario, f.nombre
  from lineas l
  join formularios f on f.activo
 where exists (
   select 1 from proyectos_formularios pf
   join colaboradores c on c.proyecto = pf.proyecto and c.activo and c.linea = l.id
   where pf.formulario_id = f.id and pf.activo)
 order by l.orden, f.orden;
