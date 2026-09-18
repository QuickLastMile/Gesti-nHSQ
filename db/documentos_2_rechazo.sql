-- ============================================================
--  DOCUMENTOS - Etapa 2: revisar y rechazar
--  ------------------------------------------------------------
--  Agrega a Configuracion una seccion para mirar los documentos
--  de la linea y rechazar el que este mal cargado, con motivo.
--
--  Un documento rechazado se comporta como uno que falta: en la
--  etapa 3 le va a pedir al mensajero que lo suba otra vez. Por
--  ahora solo queda marcado.
--
--  QUIEN PUEDE
--  -----------
--  Rechazar deja a una persona sin poder registrar, asi que no
--  es una accion menor. Se abre a los coordinadores de linea
--  ademas de HSEQ y administracion, como se pidio, pero SOLO
--  para estas tres acciones: el resto de Configuracion sigue
--  siendo de HSEQ y administracion.
--
--  Todo rechazo y todo levantamiento quedan en el historial con
--  el correo de quien lo hizo.
--
--  Requiere haber corrido db/documentos_1_estado.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La lista para revisar
--  ------------------------------------------------------------
--  Por defecto trae solo a quien tiene algo pendiente, que es lo
--  que se viene a mirar. Con 'todos' trae la linea completa.
-- ------------------------------------------------------------
create or replace function admin_documentos(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_linea     text := linea_efectiva(coalesce(payload->>'linea', ''));
  filtro_proy text := btrim(coalesce(payload->>'proyecto', ''));
  proy_nom    text;
  ncedula     text := regexp_replace(coalesce(payload->>'cedula', ''), '\D', '', 'g');
  solo_pend   boolean := coalesce((payload->>'soloPendientes')::boolean, true);
  tope        int := 300;
  filas       jsonb;
  n           int;
begin
  if filtro_proy <> '' then
    proy_nom := coalesce(nombre_proyecto(filtro_proy), filtro_proy);
  end if;

  select coalesce(jsonb_agg(t.fila order by t.orden, t.nombre), '[]'::jsonb), count(*)
    into filas, n
  from (
    select
      -- Primero quien bloquea, luego quien solo tiene algo pendiente.
      case when (e.est->>'bloquea')::boolean then 0
           when (e.est->>'exige')::boolean   then 1
           else 2 end as orden,
      coalesce(c.nombre, '') as nombre,
      jsonb_build_object(
        'cedula',     c.cedula,
        'nombre',     coalesce(c.nombre, ''),
        'cargo',      coalesce(c.cargo, ''),
        'proyecto',   coalesce(c.proyecto_efectivo, c.proyecto, ''),
        'ciudad',     coalesce(c.ciudad, ''),
        'placa',      coalesce(c.placa_moto, ''),
        'exige',      (e.est->>'exige')::boolean,
        'bloquea',    (e.est->>'bloquea')::boolean,
        'documentos', e.est->'documentos'
      ) as fila
    from colaboradores c
    cross join lateral (select estado_documentos(c.cedula) as est) e
    where c.activo
      and c.linea = v_linea
      and (filtro_proy = '' or coalesce(c.proyecto_efectivo, c.proyecto, '') = proy_nom)
      and (ncedula = '' or regexp_replace(c.cedula, '\D', '', 'g') = ncedula)
      and (not solo_pend or (e.est->>'exige')::boolean)
    limit tope
  ) t;

  return jsonb_build_object('filas', filas, 'total', n, 'tope', tope, 'linea', v_linea);
end;
$fn$;

-- ------------------------------------------------------------
--  2) Rechazar un documento
--  ------------------------------------------------------------
--  No se borra el archivo ni la fecha: se marca. Asi queda el
--  rastro de que se reviso y por que no sirvio, y el mensajero
--  puede ver el motivo cuando le vuelvan a pedir el documento.
-- ------------------------------------------------------------
create or replace function admin_rechazar_documento(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula', ''), '\D', '', 'g');
  doc     text := upper(btrim(coalesce(payload->>'documento', '')));
  motivo  text := btrim(coalesce(payload->>'motivo', ''));
  quien   text := coalesce((select r.email from app_roles r
                             where r.user_id = auth.uid() and r.activo), 'sin correo');
  c colaboradores%rowtype;
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  if doc not in ('SOAT', 'TECNOMECANICA', 'LICENCIA') then
    raise exception 'Documento no valido: %', doc;
  end if;
  if length(motivo) < 5 then
    raise exception 'Escribe el motivo del rechazo: el mensajero lo va a leer cuando le pidan el documento otra vez.';
  end if;

  select * into c from colaboradores
   where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;

  -- Solo sobre la linea propia: nadie rechaza documentos de otra operacion.
  if c.linea is distinct from linea_efectiva(coalesce(payload->>'linea', '')) then
    raise exception 'Esa persona no pertenece a la linea activa.';
  end if;

  if doc = 'SOAT' then
    update colaboradores
       set soat_rechazado_en = now(), soat_rechazo_motivo = motivo, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  elsif doc = 'TECNOMECANICA' then
    update colaboradores
       set tecnomecanica_rechazado_en = now(), tecnomecanica_rechazo_motivo = motivo, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  else
    update colaboradores
       set licencia_rechazado_en = now(), licencia_rechazo_motivo = motivo, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  end if;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTO_RECHAZADO', ncedula,
          doc || ' rechazado por ' || quien || '. Motivo: ' || motivo);

  return jsonb_build_object('mensaje', doc || ' quedo rechazado. Se le va a pedir de nuevo.');
end;
$fn$;

-- ------------------------------------------------------------
--  3) Levantar un rechazo
--  ------------------------------------------------------------
--  Rechazar bloquea a una persona. Equivocarse es cuestion de un
--  clic, asi que tiene que haber como deshacerlo sin esperar a
--  que el mensajero vuelva a subir nada.
-- ------------------------------------------------------------
create or replace function admin_levantar_rechazo(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula', ''), '\D', '', 'g');
  doc     text := upper(btrim(coalesce(payload->>'documento', '')));
  quien   text := coalesce((select r.email from app_roles r
                             where r.user_id = auth.uid() and r.activo), 'sin correo');
  c colaboradores%rowtype;
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  if doc not in ('SOAT', 'TECNOMECANICA', 'LICENCIA') then
    raise exception 'Documento no valido: %', doc;
  end if;

  select * into c from colaboradores
   where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if c.linea is distinct from linea_efectiva(coalesce(payload->>'linea', '')) then
    raise exception 'Esa persona no pertenece a la linea activa.';
  end if;

  if doc = 'SOAT' then
    update colaboradores
       set soat_rechazado_en = null, soat_rechazo_motivo = null, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  elsif doc = 'TECNOMECANICA' then
    update colaboradores
       set tecnomecanica_rechazado_en = null, tecnomecanica_rechazo_motivo = null, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  else
    update colaboradores
       set licencia_rechazado_en = null, licencia_rechazo_motivo = null, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ncedula;
  end if;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTO_RECHAZO_LEVANTADO', ncedula, doc || ' vuelve a darse por valido. Lo levanto ' || quien || '.');

  return jsonb_build_object('mensaje', 'Se levanto el rechazo de ' || doc || '.');
end;
$fn$;

-- ------------------------------------------------------------
--  4) El router de Administracion
--  ------------------------------------------------------------
--  La guarda deja de ser una sola. Revisar y rechazar documentos
--  lo pueden hacer tambien los coordinadores de linea; todo lo
--  demas de Configuracion sigue siendo de HSEQ y administracion.
-- ------------------------------------------------------------
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare result jsonb;
begin
  -- Sesion real de HSQ. La sesion anonima que usa el mensajero para
  -- subir fotos tambien cuenta como "authenticated": por eso se
  -- descarta aparte.
  if coalesce((select auth.role()), 'anon') <> 'authenticated'
     or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
  end if;

  if action in ('documentos', 'rechazarDocumento', 'levantarRechazo') then
    if not hseq_tiene_rol(array['ADMIN','HSEQ','COORDINADOR']) then
      return jsonb_build_object('ok', false, 'error', 'No tienes permiso para revisar documentos.');
    end if;
  else
    if not hseq_tiene_rol(array['ADMIN','HSEQ']) then
      return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
    end if;
  end if;

  case action
    when 'buscarColaborador'         then result := admin_buscar_colaborador(payload);
    when 'listar'                    then result := admin_listar(payload);
    when 'proyectos'                 then result := admin_proyectos(payload);
    when 'guardarColaborador'        then result := admin_guardar_colaborador(payload);
    when 'calendario'                then result := admin_calendario(payload);
    when 'guardarCalendario'         then result := admin_guardar_calendario(payload);
    when 'formulariosProyecto'       then result := admin_formularios_proyecto(payload);
    when 'guardarFormularioProyecto' then result := admin_guardar_formulario_proyecto(payload);
    when 'crearProvisional'          then result := admin_crear_provisional(payload);
    when 'moverProyecto'             then result := admin_mover_proyecto(payload);
    when 'alertasMantenimiento'      then result := api_alertas_mantenimiento(payload);
    when 'encargados'                then result := admin_encargados(payload);
    when 'guardarEncargado'          then result := admin_guardar_encargado(payload);
    when 'cargarEncargados'          then result := admin_cargar_encargados(payload);
    when 'personasProyecto'          then result := admin_personas_proyecto(payload);
    when 'asignarFrente'             then result := admin_asignar_frente(payload);
    when 'coordinadorMasivo'         then result := admin_coordinador_masivo(payload);
    when 'borrarHuerfano'            then result := admin_borrar_huerfano(payload);
    when 'historial'                 then result := admin_historial(payload);
    when 'listaEncargados'           then result := api_lista_encargados(payload);
    -- La matriz se actualiza desde Administracion, sobre la linea activa.
    when 'actualizarMatriz'          then result := api_actualizar_matriz(payload);
    when 'getMatrizInfo'             then result := api_matriz_info();
    -- Solo cuenta general (la guarda esta dentro de cada funcion).
    when 'seguridad'                 then result := admin_seguridad(payload);
    when 'guardarPin'                then result := admin_guardar_pin(payload);
    -- Documentos: tambien coordinadores de linea.
    when 'documentos'                then result := admin_documentos(payload);
    when 'rechazarDocumento'         then result := admin_rechazar_documento(payload);
    when 'levantarRechazo'           then result := admin_levantar_rechazo(payload);
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
-- a) Las tres funciones nuevas, una firma cada una.
select p.oid::regprocedure as firma
  from pg_proc p
 where p.proname in ('admin_documentos','admin_rechazar_documento','admin_levantar_rechazo')
 order by p.proname;

-- b) El router ya las conoce y abrio el permiso solo para ellas.
select case when prosrc like '%rechazarDocumento%'
             and prosrc like '%COORDINADOR%' then 'ARREGLADO'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'hseq_admin';

-- c) Cuanta gente le va a aparecer a cada linea en la pantalla nueva
--    (los que tienen algo pendiente).
select c.linea, count(*) as con_algo_pendiente
  from colaboradores c
 where c.activo and (estado_documentos(c.cedula)->>'exige')::boolean
 group by c.linea
 order by c.linea;
