-- ============================================================
--  LINEAS - Etapa 4a: Administracion solo muestra su linea
--  ------------------------------------------------------------
--  Hasta ahora, elegir Warehouse en el desplegable no cambiaba nada
--  dentro de Administracion: Proyectos, Buscar y editar, Calendario,
--  Formularios e Historial seguian mostrando Last Mile.
--
--  Desde aqui todas esas pantallas respetan la linea activa.
--
--  QUE FALTA (etapa 4b): los GUARDAS DE ESCRITURA. Guardar un
--  encargado, mover a alguien de proyecto o asignar un coordinador
--  masivo todavia no verifican que el destino sea de la linea
--  activa. Hoy eso no es un hueco de seguridad -a Administracion
--  solo llega ADMIN/HSEQ, y el unico que hay es el universal- pero
--  si hay que cerrarlo ANTES de subir a HSEQ a los usuarios de
--  linea.
--
--  Ejecutar DESPUES de db/lineas_3_lecturas.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) A que linea pertenece un proyecto
--  ------------------------------------------------------------
--  Se deduce de su gente. Funciona porque los nombres de proyecto no
--  se repiten entre lineas; si alguna vez se repitieran, esto habria
--  que llavearlo de otra forma.
-- ------------------------------------------------------------
create or replace function linea_proyecto(p_proyecto text)
returns text language sql stable set search_path = public as $fn$
  select c.linea
    from colaboradores c
   where coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto, '')
         = btrim(coalesce(p_proyecto, ''))
   group by c.linea
   order by count(*) desc
   limit 1;
$fn$;

-- Si el usuario ve todas las lineas, tambien ve los movimientos que no
-- son de nadie en particular (calendario, cargues, proyectos).
create or replace function usuario_universal()
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce((select r.todas_lineas from app_roles r
                    where r.user_id = auth.uid() and r.activo), false);
$fn$;

revoke all on function usuario_universal() from public, anon;
grant execute on function usuario_universal() to authenticated;

-- ------------------------------------------------------------
--  2) Buscar y editar colaboradores
-- ------------------------------------------------------------
create or replace function admin_buscar_colaborador(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(colab_json(c) order by c.nombre), '[]'::jsonb)
  from colaboradores c
  where c.linea = linea_efectiva(coalesce(payload->>'linea',''))
    and case when regexp_replace(coalesce(payload->>'q',''), '\D', '', 'g') <> ''
      then regexp_replace(c.cedula,'\D','','g') like regexp_replace(payload->>'q','\D','','g') || '%'
      else sin_tildes(c.nombre) like '%' || sin_tildes(coalesce(payload->>'q','')) || '%'
    end
  limit 50;
$fn$;

create or replace function admin_listar(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(colab_json(c) order by (not c.activo), c.nombre), '[]'::jsonb)
  from colaboradores c
  where c.linea = linea_efectiva(coalesce(payload->>'linea',''))
    and (coalesce(payload->>'proyecto','') = ''
         or c.proyecto_efectivo = payload->>'proyecto'
         or c.proyecto = payload->>'proyecto')
    and case coalesce(payload->>'estado','todos')
          when 'activos' then c.activo
          when 'inactivos' then not c.activo
          when 'provisionales' then c.provisional and c.activo
          when 'trasladados' then coalesce(btrim(c.proyecto_operativo),'') <> ''
          else true end
  limit 800;
$fn$;

-- ------------------------------------------------------------
--  3) La lista de proyectos que alimenta los desplegables
-- ------------------------------------------------------------
-- Ojo: esta funcion antes no recibia parametros. 'create or replace' no
-- reemplaza una firma por otra, crea una segunda; las dos se podrian
-- llamar sin argumentos y Postgres responderia "is not unique".
drop function if exists admin_proyectos();
create or replace function admin_proyectos(payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  with lin as (select linea_efectiva(coalesce(payload->>'linea','')) as id)
  select coalesce(jsonb_agg(jsonb_build_object('proyecto', proyecto) order by proyecto), '[]'::jsonb)
  from (
    select distinct c.proyecto from colaboradores c, lin
     where coalesce(c.proyecto,'') <> '' and c.linea = lin.id
    union
    select distinct c.proyecto_operativo from colaboradores c, lin
     where coalesce(c.proyecto_operativo,'') <> '' and c.linea = lin.id
    union
    -- Un proyecto configurado que todavia no tiene gente: se muestra solo
    -- si se puede deducir que es de esta linea.
    select distinct pf.proyecto from proyectos_formularios pf, lin
     where coalesce(pf.proyecto,'') <> '' and linea_proyecto(pf.proyecto) = lin.id
  ) t(proyecto);
$fn$;

-- ------------------------------------------------------------
--  4) Calendario y metas
-- ------------------------------------------------------------
-- Ojo: esta funcion antes no recibia parametros. 'create or replace' no
-- reemplaza una firma por otra, crea una segunda; las dos se podrian
-- llamar sin argumentos y Postgres responderia "is not unique".
drop function if exists admin_calendario();
create or replace function admin_calendario(payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'defecto', jsonb_build_object(
      'dias', coalesce((select valor from config where clave='CAL_DIAS_DEFECTO'), '1,2,3,4,5,6'),
      'festivos', coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false),
      'meta', coalesce((select valor::numeric from config where clave='META_DEFECTO'), 90)),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'proyecto', p.proyecto,
        'activos', p.activos,
        'dias', coalesce(array_to_string(pc.dias_laborales, ','), ''),
        'festivos', coalesce(pc.labora_festivos, false),
        'meta', pc.meta,
        'configurado', pc.proyecto is not null
      ) order by p.proyecto)
      from (
        select coalesce(proyecto,'Sin proyecto') proyecto, count(*) activos
        from colaboradores
        where activo and linea = linea_efectiva(coalesce(payload->>'linea',''))
        group by coalesce(proyecto,'Sin proyecto')
      ) p
      left join proyectos_calendario pc on pc.proyecto = p.proyecto
    ), '[]'::jsonb)
  );
$fn$;

-- ------------------------------------------------------------
--  5) Proyectos y encargados
-- ------------------------------------------------------------
-- Ojo: esta funcion antes no recibia parametros. 'create or replace' no
-- reemplaza una firma por otra, crea una segunda; las dos se podrian
-- llamar sin argumentos y Postgres responderia "is not unique".
drop function if exists admin_encargados();
create or replace function admin_encargados(payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  with lin as (
    select linea_efectiva(coalesce(payload->>'linea','')) as id
  ),
  base as (
    select c.activo, c.cargo, c.enc_coordinador,
           btrim(coalesce(c.frente, '')) frente,
           ceco_efectivo(c.proyecto_id, c.proyecto_operativo) ceco,
           coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto) proy_nombre
    from colaboradores c, lin
    where coalesce(c.proyecto, '') <> ''
      and c.linea = lin.id
  ),
  proys as (
    -- Sin CECO, dos proyectos distintos no pueden caer en la misma fila.
    select b.ceco,
           case when b.ceco = '' then b.proy_nombre else '' end agrupa_nombre,
           max(b.proy_nombre) nombre_visto,
           count(*) filter (where b.activo and cargo_aplica(b.cargo)) activos,
           count(*) filter (where b.activo and cargo_aplica(b.cargo)
                              and coalesce(b.enc_coordinador, '') = '') sin_coordinador,
           count(*) filter (where b.activo and cargo_aplica(b.cargo) and b.frente = '') sin_frente
    from base b
    group by b.ceco, case when b.ceco = '' then b.proy_nombre else '' end
  )
  select jsonb_build_object(
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'proyecto_id', p.ceco,
               'sin_ceco',    (p.ceco = ''),
               'proyecto',    case when p.ceco = '' then p.nombre_visto
                                   else coalesce(nullif(nombre_proyecto(p.ceco), ''), p.nombre_visto) end,
               'cliente',     coalesce(rg.cliente, ''),
               'jefatura',    coalesce(rg.jefatura, ''),
               'lider',       coalesce(rg.lider, ''),
               'coordinador', coalesce(rg.coordinador, ''),
               'activos',     p.activos,
               'sin_coordinador', p.sin_coordinador,
               'sin_frente',  p.sin_frente,
               'frentes', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'frente', f.frente, 'jefatura', coalesce(f.jefatura, ''),
                           'lider', coalesce(f.lider, ''), 'coordinador', coalesce(f.coordinador, ''),
                           'personas', (select count(*) from colaboradores cc
                                         where cc.activo and cargo_aplica(cc.cargo)
                                           and ceco_efectivo(cc.proyecto_id, cc.proyecto_operativo) = p.ceco
                                           and btrim(coalesce(cc.frente, '')) = f.frente))
                         order by f.frente)
                  from responsables_proyecto f
                  where p.ceco <> '' and f.proyecto_id = p.ceco and f.frente <> ''), '[]'::jsonb))
             order by (p.ceco = '') desc, case when p.ceco = '' then p.nombre_visto
                                               else coalesce(nullif(nombre_proyecto(p.ceco), ''), p.nombre_visto) end)
      from proys p
      left join responsables_proyecto rg on p.ceco <> '' and rg.proyecto_id = p.ceco and rg.frente = ''), '[]'::jsonb),
    -- CECOs cargados que hoy no tienen a nadie en la matriz.
    'huerfanos', coalesce((
      select jsonb_agg(jsonb_build_object('proyecto_id', r.proyecto_id, 'cliente', coalesce(r.cliente, ''),
                                          'jefatura', coalesce(r.jefatura, ''), 'lider', coalesce(r.lider, ''))
             order by r.proyecto_id)
      from responsables_proyecto r
      where r.frente = ''
        -- Un CECO sin gente no tiene linea deducible: solo lo ve quien
        -- ve todas las lineas, para no mostrarselo a la linea equivocada.
        and usuario_universal()
        and not exists (select 1 from proys p where p.ceco = r.proyecto_id)), '[]'::jsonb)
  );
$fn$;

create or replace function admin_personas_proyecto(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'cedula', c.cedula, 'nombre', coalesce(c.nombre, ''),
           'ciudad', coalesce(c.ciudad, ''), 'cargo', coalesce(c.cargo, ''),
           'frente', coalesce(c.frente, ''),
           'coordinador_propio', coalesce(c.coordinador, ''),
           'coordinador', coalesce(c.enc_coordinador, ''),
           'jefatura', coalesce(c.enc_jefatura, ''), 'lider', coalesce(c.enc_lider, ''),
           'trasladado', coalesce(nullif(btrim(c.proyecto_operativo), ''), '') <> '',
           'proyecto_nomina', coalesce(c.proyecto, ''))
         order by coalesce(c.ciudad, ''), c.nombre), '[]'::jsonb)
  from colaboradores c
  where c.activo and cargo_aplica(c.cargo)
    and c.linea = linea_efectiva(coalesce(payload->>'linea',''))
    and ceco_efectivo(c.proyecto_id, c.proyecto_operativo) = btrim(coalesce(payload->>'proyecto_id', ''))
    -- Los proyectos sin CECO se distinguen por el nombre.
    and (btrim(coalesce(payload->>'proyecto_id', '')) <> ''
         or coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto) = btrim(coalesce(payload->>'proyecto', '')));
$fn$;

-- ------------------------------------------------------------
--  6) Formularios por proyecto
-- ------------------------------------------------------------
-- Ojo: esta funcion antes no recibia parametros. 'create or replace' no
-- reemplaza una firma por otra, crea una segunda; las dos se podrian
-- llamar sin argumentos y Postgres responderia "is not unique".
drop function if exists admin_formularios_proyecto();
create or replace function admin_formularios_proyecto(payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'formularios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', f.id, 'nombre', f.nombre, 'descripcion', coalesce(f.descripcion,''),
        'activo_global', f.activo, 'orden', f.orden,
        -- Solo estos muestran el selector de frecuencia en el panel.
        'permite_frecuencia', coalesce(f.permite_frecuencia, false)
      ) order by f.orden, f.nombre)
      from formularios f
    ), '[]'::jsonb),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'proyecto', p.proyecto,
        'activos', p.activos,
        'habilitados', coalesce(a.habilitados,0),
        'formularios', coalesce(a.formularios,'{}'::jsonb),
        'frecuencias', coalesce(a.frecuencias,'{}'::jsonb),
        -- Dias laborales del proyecto, para avisar si el dia elegido no aplica.
        'dias_laborales', coalesce(array_to_string(pc.dias_laborales, ','),
          coalesce((select valor from config where clave='CAL_DIAS_DEFECTO'), '1,2,3,4,5,6'))
      ) order by p.proyecto)
      from (
        select c.proyecto, count(*) filter (where c.activo)::int activos
        from colaboradores c
        where coalesce(c.proyecto,'') <> ''
          and c.linea = linea_efectiva(coalesce(payload->>'linea',''))
        group by c.proyecto
      ) p
      left join proyectos_calendario pc on pc.proyecto = p.proyecto
      left join lateral (
        select count(*) filter (where pf.activo and f.activo)::int habilitados,
               coalesce(jsonb_object_agg(pf.formulario_id, pf.activo),'{}'::jsonb) formularios,
               coalesce(jsonb_object_agg(pf.formulario_id, jsonb_build_object(
                 'frecuencia', pf.frecuencia, 'dia_semana', pf.dia_semana)),'{}'::jsonb) frecuencias
        from proyectos_formularios pf
        join formularios f on f.id=pf.formulario_id
        where pf.proyecto=p.proyecto
      ) a on true
    ), '[]'::jsonb)
  );
$fn$;

-- ------------------------------------------------------------
--  7) Historial
-- ------------------------------------------------------------
create or replace function admin_historial(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  q      text := btrim(coalesce(payload->>'q', ''));
  v_tipo text := btrim(coalesce(payload->>'tipo', ''));
  desde  date := nullif(payload->>'desde', '')::date;
  hasta  date := nullif(payload->>'hasta', '')::date;
  lim    int  := least(greatest(coalesce(nullif(payload->>'limite', '')::int, 300), 1), 1000);
  filas  jsonb;
  cuantos bigint;
  -- Lo que hace el mensajero desde su celular no es un cambio
  -- administrativo: sube sus documentos al diligenciar (DOCUMENTOS) y
  -- registra su placa la primera vez (CAMBIO_PLACA). Eso no va aqui.
  -- Ojo: ADMIN_PLACA y ADMIN_ESTADO si son de HSQ y si se muestran.
  del_mensajero text[] := array['DOCUMENTOS', 'CAMBIO_PLACA'];
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  v_todo  boolean := usuario_universal();
begin
  drop table if exists tmp_hist_sel;
  create temporary table tmp_hist_sel on commit drop as
    select h.id, h.creado_en, coalesce(h.tipo, '') tipo,
           coalesce(h.cedula, '') cedula,
           coalesce(c.nombre, '') nombre,
           coalesce(h.detalle, '') detalle,
           coalesce(c.proyecto_efectivo, c.proyecto, '') proyecto
      from historial h
      left join colaboradores c
        on regexp_replace(c.cedula, '\D', '', 'g') = regexp_replace(coalesce(h.cedula, ''), '\D', '', 'g')
       and coalesce(h.cedula, '') <> ''
     where coalesce(h.tipo, '') <> all (del_mensajero)
       -- Un movimiento de persona se ve en la linea de esa persona. Los
       -- que no tienen cedula (calendario, cargues, proyectos) no tienen
       -- linea deducible: solo los ve quien ve todas.
       and (case when coalesce(h.cedula, '') = '' then v_todo
                 else c.linea = v_linea end)
       and (v_tipo = '' or h.tipo = v_tipo)
       and (desde is null or (h.creado_en at time zone 'America/Bogota')::date >= desde)
       and (hasta is null or (h.creado_en at time zone 'America/Bogota')::date <= hasta)
       and (q = ''
            or coalesce(h.cedula, '') ilike '%' || q || '%'
            or coalesce(h.detalle, '') ilike '%' || q || '%'
            or coalesce(h.tipo, '') ilike '%' || q || '%'
            or coalesce(c.nombre, '') ilike '%' || q || '%');

  select count(*) into cuantos from tmp_hist_sel;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'fecha', to_char(t.creado_en at time zone 'America/Bogota', 'YYYY-MM-DD'),
           'hora',  to_char(t.creado_en at time zone 'America/Bogota', 'HH24:MI'),
           'tipo', t.tipo, 'cedula', t.cedula, 'nombre', t.nombre,
           'proyecto', t.proyecto, 'detalle', t.detalle) order by t.creado_en desc), '[]'::jsonb)
    into filas
    from (select * from tmp_hist_sel order by creado_en desc limit lim) t;

  return jsonb_build_object(
    'filas', filas,
    'total', cuantos,
    'mostrados', jsonb_array_length(filas),
    -- Los tipos que existen, para el desplegable de la pantalla.
    'tipos', coalesce((select jsonb_agg(x.tipo order by x.tipo)
                         from (select distinct coalesce(tipo, '') tipo from historial
                                where coalesce(tipo, '') <> ''
                                  and coalesce(tipo, '') <> all (del_mensajero)) x), '[]'::jsonb));
end;
$fn$;

-- ------------------------------------------------------------
--  8) El router le pasa la linea a las que antes no la recibian
--  ------------------------------------------------------------
--  Se conserva la guarda de rol tal cual: sesion real de HSQ, no la
--  anonima que usa el mensajero para subir fotos.
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
-- a) Las pantallas de Administracion ya resuelven la linea.
select proname,
       case when prosrc like '%linea_efectiva%' then 'FILTRA POR LINEA'
            else 'SIN FILTRO' end as estado
  from pg_proc
 where proname in ('admin_buscar_colaborador','admin_listar','admin_proyectos',
                   'admin_calendario','admin_encargados','admin_personas_proyecto',
                   'admin_formularios_proyecto','admin_historial')
 order by proname;

-- b) El router conserva la guarda de rol.
select 'hseq_admin' as router,
       case when prosrc like '%hseq_tiene_rol%' then 'CON GUARDA' else 'SIN GUARDA' end as estado
  from pg_proc where proname = 'hseq_admin';

-- c) Cuanta gente hay por linea.
select linea, count(*) filter (where activo) as activos, count(*) as total
  from colaboradores group by linea order by linea;
