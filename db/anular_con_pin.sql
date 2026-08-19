-- ============================================================
--  Gestión HSEQ Motos — Anular registros de verdad, con PIN
--  ------------------------------------------------------------
--  Tres correcciones:
--
--  1) Al anular, el registro se ELIMINA (con sus respuestas y
--     evidencias). Antes solo se marcaba como anulado y el
--     mensajero seguía viendo "ya registraste hoy", así que no
--     podía volver a diligenciar. Queda la auditoría completa en
--     el historial: quién, cuándo, qué contenía y por qué.
--
--  2) Anular exige un PIN de 4 dígitos que se valida en el
--     servidor. Un coordinador no puede borrar sin él.
--
--  3) Los registros anulados que ya existen dejan de bloquear.
--
--  Ejecutar DESPUÉS de: provisionales_y_traslados.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) El PIN vive en la base, no en la página.
--    Cámbialo cuando quieras con el UPDATE del final.
-- ------------------------------------------------------------
insert into config (clave, valor) values ('PIN_ANULACION', '2468')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
-- 2) Anular = eliminar, dejando la auditoría
-- ------------------------------------------------------------
create or replace function api_anular_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  rid uuid := nullif(payload->>'id_registro','')::uuid;
  motivo text := btrim(coalesce(payload->>'motivo',''));
  pin text := regexp_replace(coalesce(payload->>'pin',''), '\D', '', 'g');
  pin_ok text;
  r registros%rowtype;
  n_resp int; n_evi int;
  resumen text;
begin
  if rid is null then raise exception 'Falta el ID del registro.'; end if;
  if length(motivo) < 5 then raise exception 'Escribe un motivo de al menos 5 caracteres.'; end if;

  select valor into pin_ok from config where clave = 'PIN_ANULACION';
  if coalesce(pin_ok,'') = '' then
    raise exception 'No hay PIN configurado. Comunicate con HSEQ.';
  end if;
  if pin = '' then
    raise exception 'Digita el PIN de autorizacion para eliminar el registro.';
  end if;
  if pin <> pin_ok then
    insert into historial (tipo, cedula, detalle)
    values ('ANULACION_RECHAZADA', '', 'PIN incorrecto al intentar eliminar el registro ' || rid::text);
    raise exception 'PIN incorrecto. El registro no se elimino.';
  end if;

  select * into r from registros where id = rid for update;
  if not found then raise exception 'Registro no encontrado. Es posible que ya se haya eliminado.'; end if;

  select count(*) into n_resp from respuestas where registro_id = rid;
  select count(*) into n_evi  from evidencias where registro_id = rid;

  resumen := 'Eliminado el registro de ' || coalesce(r.nombre,'(sin nombre)') ||
             ' (CC ' || r.cedula || ') del formulario ' || r.formulario_id ||
             ' con fecha ' || to_char(r.fecha,'YYYY-MM-DD') ||
             ' ' || coalesce(to_char(r.hora,'HH24:MI'),'') ||
             ', proyecto ' || coalesce(r.proyecto,'(sin proyecto)') ||
             ', placa ' || coalesce(r.placa_moto,'(sin placa)') ||
             '. Contenia ' || n_resp || ' respuestas y ' || n_evi || ' evidencias.' ||
             ' Motivo: ' || motivo;

  insert into historial (tipo, cedula, detalle) values ('ANULACION', r.cedula, resumen);

  -- Las respuestas y evidencias se van en cascada con el registro.
  delete from registros where id = rid;

  return jsonb_build_object(
    'eliminado', true,
    'cedula', r.cedula,
    'nombre', coalesce(r.nombre,''),
    'formulario', r.formulario_id,
    'fecha', to_char(r.fecha,'YYYY-MM-DD'),
    'mensaje', coalesce(r.nombre,'El colaborador') || ' ya puede volver a diligenciar este formulario.');
end;
$fn$;

-- ------------------------------------------------------------
-- 3) Los registros anulados que quedaron de antes se eliminan,
--    para que quien los tenga pueda volver a diligenciar.
-- ------------------------------------------------------------
do $limpieza$
declare
  reg record;
  n int := 0;
begin
  for reg in select * from registros where coalesce(estado,'') = 'ANULADO' loop
    insert into historial (tipo, cedula, detalle)
    values ('ANULACION', reg.cedula,
      'Limpieza: se elimino el registro anulado de ' || coalesce(reg.nombre,'') ||
      ' (' || reg.formulario_id || ', ' || to_char(reg.fecha,'YYYY-MM-DD') || '). ' ||
      coalesce(reg.alertas,''));
    delete from registros where id = reg.id;
    n := n + 1;
  end loop;
  raise notice 'Registros anulados eliminados: %', n;
end;
$limpieza$;

-- ------------------------------------------------------------
-- 4) Por si quedara alguno: los anulados no bloquean el registro
--    ni cuentan como diligenciados.
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  estado jsonb := '{}'::jsonb;
  docs jsonb := '{}'::jsonb;
  v_obs text;
  f record; r record; d record;
  dias int; est text;
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('encontrado', false, 'mensaje', 'No se encontro la cedula en la matriz.');
  end if;

  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');
  v_obs := btrim(coalesce(c.observacion_coordinador, ''));

  if c.activo then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
      order by frm.orden
    loop
      select to_char(hora,'HH24:MI') as h, id::text as rid into r
        from registros
       where regexp_replace(cedula,'\D','','g') = ncedula
         and formulario_id = f.id and fecha = hoy
         and coalesce(estado,'') <> 'ANULADO'
       limit 1;
      if found then
        estado := estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        estado := estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      end if;
    end loop;

    for d in select * from (values
        ('SOAT',          c.soat_vence,          c.soat_url),
        ('TECNOMECANICA', c.tecnomecanica_vence, c.tecnomecanica_url),
        ('LICENCIA',      c.licencia_vence,      c.licencia_url)
      ) as t(k, ven, url) loop
      if d.ven is null then
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha','', 'dias', null, 'estado','sin_dato','url', coalesce(d.url,'')));
      else
        dias := d.ven - hoy;
        est := case when dias < 0 then 'vencido' when dias <= 15 then 'por_vencer' else 'ok' end;
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha', to_char(d.ven,'YYYY-MM-DD'), 'dias', dias, 'estado', est, 'url', coalesce(d.url,'')));
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'encontrado', true,
    'activo', c.activo,
    'observacionCoordinador', v_obs,
    'mensaje', case when c.activo then 'Activo habilitado para registro.'
                    when v_obs <> '' then 'No estas habilitado para registrar. Motivo: ' || v_obs
                    else 'La persona no esta activa para registro.' end,
    'requierePlaca', (coalesce(btrim(c.placa_moto),'') = ''),
    'datos', jsonb_build_object(
      'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
      'proyecto_id', coalesce(c.proyecto_id,''), 'proyecto', proy,
      'proyecto_nomina', coalesce(c.proyecto,''),
      'trasladado', coalesce(btrim(c.proyecto_operativo),'') <> '',
      'ciudad', coalesce(c.ciudad,''), 'placa_moto', coalesce(c.placa_moto,''),
      'tipo_vehiculo', coalesce(c.tipo_vehiculo,'')
    ),
    'formulariosRequeridos', coalesce((
      select jsonb_agg(jsonb_build_object('id_formulario', frm.id, 'nombre_formulario', frm.nombre) order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy), '[]'::jsonb),
    'estadoDiario', estado,
    'documentos', docs
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 5) Router de administración COMPLETO
--    (incluye moverProyecto, que estaba faltando)
-- ------------------------------------------------------------
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare result jsonb;
begin
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
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

-- ------------------------------------------------------------
-- 6) Router del coordinador, con todas sus acciones
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
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
    when 'miCumplimiento'       then result := api_mi_cumplimiento(payload);
    when 'alertasMantenimiento' then result := api_alertas_mantenimiento(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

grant execute on function hseq_api(text, jsonb) to anon;

-- ============================================================
--  PARA CAMBIAR EL PIN (4 dígitos)
--    update config set valor = '9137' where clave = 'PIN_ANULACION';
--
--  PARA VERLO
--    select valor from config where clave = 'PIN_ANULACION';
--
--  QUIÉN INTENTÓ ELIMINAR Y CON QUÉ MOTIVO
--    select creado_en, tipo, cedula, detalle from historial
--     where tipo in ('ANULACION','ANULACION_RECHAZADA')
--     order by creado_en desc limit 30;
-- ============================================================
