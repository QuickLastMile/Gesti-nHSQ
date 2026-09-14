-- ============================================================
--  Seguridad: el PIN de anulacion y las cuentas
--  ------------------------------------------------------------
--  Agrega a Administracion una seccion para la CUENTA GENERAL:
--
--    - ver y cambiar el PIN que autoriza eliminar registros
--    - ver que cuentas existen, con que rol, sobre que linea,
--      si estan activas y cuando entraron por ultima vez
--
--  SOBRE LAS CONTRASENAS
--  ---------------------
--  Esta seccion NO muestra contrasenas, y no es un descuido: no
--  existen guardadas en ninguna parte. Supabase guarda un hash
--  bcrypt, que es una huella de un solo sentido: sirve para
--  comprobar si la que se digita coincide, pero no se puede
--  devolver a texto. Ni Supabase, ni esta base, ni nadie puede
--  leerlas. Cambiarlas es otra cosa y va aparte.
--
--  El PIN si se puede mostrar: no es una contrasena de nadie,
--  es un codigo de autorizacion compartido que vive en la tabla
--  config en texto plano, y quien lo reparte es la administradora.
--
--  Este script tambien deja api_lineas con el campo 'universal'.
--  Si ya corriste db/lineas_universal.sql, se vuelve a aplicar
--  igual y no pasa nada.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Quien es la cuenta general
--  ------------------------------------------------------------
--  El PIN es uno solo para toda la empresa: si lo cambiara la
--  cuenta de una linea, le cambiaria el PIN a las demas sin
--  enterarse. Por eso esto queda reservado a la cuenta general.
-- ------------------------------------------------------------
create or replace function es_cuenta_general()
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce((select r.todas_lineas from app_roles r
                    where r.user_id = auth.uid() and r.activo), false);
$fn$;

revoke all on function es_cuenta_general() from public, anon;
grant execute on function es_cuenta_general() to authenticated;

-- ------------------------------------------------------------
--  2) Lo que ve la seccion
-- ------------------------------------------------------------
create or replace function admin_seguridad(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare cuentas jsonb;
begin
  if not es_cuenta_general() then
    raise exception 'Solo la cuenta general administra el PIN y las cuentas.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'email',   r.email,
           'rol',     r.rol,
           'general', r.todas_lineas,
           'lineas',  case when r.todas_lineas then 'Todas'
                           else coalesce(array_to_string(r.lineas, ', '), '') end,
           'activo',  r.activo,
           -- Sin confirmar el correo, Supabase no deja iniciar sesion.
           'confirmada', u.email_confirmed_at is not null,
           'ultimo_ingreso', coalesce(
             to_char(u.last_sign_in_at at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'),
             'Nunca')
         ) order by r.todas_lineas desc, r.email), '[]'::jsonb)
    into cuentas
    from app_roles r
    left join auth.users u on u.id = r.user_id;

  return jsonb_build_object(
    'pin', coalesce((select valor from config where clave = 'PIN_ANULACION'), ''),
    'cuentas', cuentas
  );
end;
$fn$;

-- ------------------------------------------------------------
--  3) Cambiar el PIN
-- ------------------------------------------------------------
create or replace function admin_guardar_pin(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare nuevo text := regexp_replace(coalesce(payload->>'pin', ''), '\D', '', 'g');
begin
  if not es_cuenta_general() then
    raise exception 'Solo la cuenta general puede cambiar el PIN.';
  end if;
  if nuevo !~ '^\d{4}$' then
    raise exception 'El PIN son exactamente 4 digitos.';
  end if;

  insert into config (clave, valor) values ('PIN_ANULACION', nuevo)
  on conflict (clave) do update set valor = excluded.valor;

  -- Queda la constancia de que se cambio. El PIN nuevo NO se escribe
  -- aqui: el historial lo lee mas gente de la que debe saberlo.
  insert into historial (tipo, cedula, detalle)
  values ('PIN_CAMBIADO', '', 'Se cambio el PIN de anulacion desde Administracion.');

  return jsonb_build_object('mensaje', 'PIN actualizado.');
end;
$fn$;

-- ------------------------------------------------------------
--  4) api_lineas dice si la cuenta es general
--  ------------------------------------------------------------
--  La pantalla necesita saberlo para mostrar u ocultar la seccion.
--  Ojo: eso solo ordena la vista. Quien manda es la guarda de
--  es_cuenta_general() aqui arriba, que no se puede saltar desde
--  el navegador.
-- ------------------------------------------------------------
create or replace function api_lineas()
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'nombre', l.nombre) order by l.orden, l.id)
        from lineas l
       where l.activo and l.id = any(lineas_permitidas())), '[]'::jsonb),
    'actual', coalesce((select (lineas_permitidas())[1]), ''),
    'puede_cambiar', coalesce(array_length(lineas_permitidas(),1),0) > 1,
    'rol', coalesce((select r.rol from app_roles r
                      where r.user_id = auth.uid() and r.activo), ''),
    'admin', coalesce((select r.rol in ('ADMIN','HSEQ') from app_roles r
                        where r.user_id = auth.uid() and r.activo), false),
    'universal', es_cuenta_general()
  );
$fn$;

revoke all on function api_lineas() from public, anon;
grant execute on function api_lineas() to authenticated;

-- ------------------------------------------------------------
--  5) El router
-- ------------------------------------------------------------
create or replace function hseq_admin(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare result jsonb;
begin
  -- Sesion real de HSQ. La sesion anonima que usa el mensajero para
  -- subir fotos tambien cuenta como "authenticated": por eso se
  -- descarta aparte.
  if coalesce((select auth.role()), 'anon') <> 'authenticated'
     or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
     or not hseq_tiene_rol(array['ADMIN','HSEQ']) then
    return jsonb_build_object('ok', false, 'error', 'Debes iniciar sesion como HSQ.');
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
-- a) Las funciones nuevas quedaron, una sola firma cada una.
select p.oid::regprocedure as firma
  from pg_proc p
 where p.proname in ('es_cuenta_general','admin_seguridad','admin_guardar_pin','api_lineas')
 order by p.proname;

-- b) Quien es cuenta general. Solo esas ven la seccion nueva.
select email, rol, todas_lineas as cuenta_general, lineas, activo
  from app_roles
 order by todas_lineas desc, email;

-- c) El PIN que esta puesto hoy.
select valor as pin_actual from config where clave = 'PIN_ANULACION';
