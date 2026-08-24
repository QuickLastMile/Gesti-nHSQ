-- ============================================================
--  Gestión HSEQ Motos — Encargados por proyecto
--  ------------------------------------------------------------
--  Quién responde por cada operación: JEFATURA, LÍDER y
--  COORDINADOR. Con esto cada quien filtra y revisa solo lo suyo.
--
--  El jefe y el líder son por proyecto (así viene la tabla de la
--  compañía, con el CECO como llave). El coordinador es distinto:
--  en un mismo proyecto puede haber varios (ej. 593 Cafam
--  Comercial: uno de Bogotá y otro de nacionales). Para eso se
--  agrega el concepto de FRENTE: una división interna del
--  proyecto, sin tocar la nómina ni crear proyectos nuevos.
--
--    proyecto sin frentes  -> un solo coordinador, todo igual
--    proyecto con frentes  -> un coordinador por frente, y cada
--                             persona pertenece a un frente
--    persona con coordinador propio -> manda sobre todo lo demás
--
--  Ejecutar DESPUÉS de: filtro_proyecto_traslado.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) Tabla de encargados
-- ------------------------------------------------------------
create table if not exists responsables_proyecto (
  id             bigserial primary key,
  proyecto_id    text not null,               -- CECO
  frente         text not null default '',    -- '' = todo el proyecto
  cliente        text,                        -- nombre del cliente en la tabla de origen
  jefatura       text,
  lider          text,
  coordinador    text,
  actualizado_en timestamptz not null default now(),
  constraint uq_responsable unique (proyecto_id, frente)
);

comment on table responsables_proyecto is
  'Jefe, lider y coordinador de cada proyecto (CECO). Una fila con frente="" cubre todo el proyecto; las filas con frente cubren solo esa parte.';
comment on column responsables_proyecto.frente is
  'Division interna del proyecto (ej. BOGOTA / NACIONALES). Vacio = todo el proyecto.';

create index if not exists idx_resp_proy on responsables_proyecto (proyecto_id);

-- ------------------------------------------------------------
-- 2) Columnas en la matriz de colaboradores
--    frente / coordinador  -> se editan
--    enc_*                 -> resultado ya resuelto, para filtrar rápido
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists frente          text,
  add column if not exists coordinador     text,
  add column if not exists enc_jefatura    text,
  add column if not exists enc_lider       text,
  add column if not exists enc_coordinador text;

comment on column colaboradores.frente is
  'Parte del proyecto a la que pertenece (ej. BOGOTA). Vacio = el proyecto completo.';
comment on column colaboradores.coordinador is
  'Coordinador asignado a esta persona en particular. Manda sobre el del frente y el del proyecto.';

create index if not exists idx_colab_enc_jefe  on colaboradores (enc_jefatura)    where activo;
create index if not exists idx_colab_enc_lider on colaboradores (enc_lider)       where activo;
create index if not exists idx_colab_enc_coord on colaboradores (enc_coordinador) where activo;
-- La cédula se compara siempre sin puntos ni guiones: que el índice lo acompañe.
create index if not exists idx_colab_ced_norm  on colaboradores ((regexp_replace(cedula,'\D','','g')));

-- ------------------------------------------------------------
-- 3) Código del proyecto a partir del nombre
--    (el inverso de nombre_proyecto, que ya existe)
-- ------------------------------------------------------------
create or replace function codigo_proyecto(nombre text)
returns text language sql stable set search_path = public as $fn$
  select proyecto_id
    from colaboradores
   where btrim(coalesce(proyecto,'')) = btrim(coalesce(nombre,''))
     and coalesce(proyecto_id,'') <> ''
   limit 1;
$fn$;

-- ------------------------------------------------------------
-- 4) Quién responde por una persona
--    Orden: lo propio de la persona > lo del frente > lo del proyecto.
--    Si está trasladada, mandan los encargados del proyecto donde labora.
-- ------------------------------------------------------------
create or replace function calc_encargados(
  p_proy_id text, p_proy_oper text, p_frente text, p_coord_manual text,
  out jefatura text, out lider text, out coordinador text)
language plpgsql stable set search_path = public as $fn$
declare
  pid text;
  fr  text := coalesce(nullif(btrim(p_frente), ''), '');
  rg  responsables_proyecto%rowtype;   -- fila general del proyecto
  rf  responsables_proyecto%rowtype;   -- fila del frente
begin
  -- Un traslado mueve también a quién le responde.
  if coalesce(btrim(p_proy_oper), '') <> '' then
    pid := coalesce(nullif(codigo_proyecto(p_proy_oper), ''), btrim(coalesce(p_proy_id, '')));
  else
    pid := btrim(coalesce(p_proy_id, ''));
  end if;

  if pid <> '' then
    select * into rg from responsables_proyecto r
      where r.proyecto_id = pid and r.frente = '' limit 1;
    if fr <> '' then
      select * into rf from responsables_proyecto r
        where r.proyecto_id = pid and r.frente = fr limit 1;
    end if;
  end if;

  jefatura    := coalesce(nullif(btrim(rf.jefatura), ''), nullif(btrim(rg.jefatura), ''), '');
  lider       := coalesce(nullif(btrim(rf.lider), ''),    nullif(btrim(rg.lider), ''),    '');
  coordinador := coalesce(nullif(btrim(p_coord_manual), ''),
                          nullif(btrim(rf.coordinador), ''),
                          nullif(btrim(rg.coordinador), ''), '');
end;
$fn$;

-- Cada vez que se guarda un colaborador, sus encargados quedan al día.
create or replace function trg_calc_encargados()
returns trigger language plpgsql set search_path = public as $fn$
declare e record;
begin
  select * into e from calc_encargados(new.proyecto_id, new.proyecto_operativo, new.frente, new.coordinador);
  new.enc_jefatura    := e.jefatura;
  new.enc_lider       := e.lider;
  new.enc_coordinador := e.coordinador;
  return new;
end;
$fn$;

drop trigger if exists trg_colab_encargados on colaboradores;
create trigger trg_colab_encargados
  before insert or update on colaboradores
  for each row execute function trg_calc_encargados();

-- Recalcula toda la matriz. Se llama sola al cambiar la tabla de encargados.
create or replace function recalcular_encargados()
returns int language plpgsql set search_path = public as $fn$
declare n int;
begin
  -- El trigger de arriba hace el cálculo; basta con tocar cada fila.
  update colaboradores set actualizado_en = actualizado_en;
  get diagnostics n = row_count;
  return n;
end;
$fn$;

-- ------------------------------------------------------------
-- 5) ¿Esta persona está a cargo del encargado seleccionado?
--    Se usa en cumplimiento, dashboard y exportable.
-- ------------------------------------------------------------
create or replace function en_alcance(tipo text, nombre text, ced text)
returns boolean language sql stable set search_path = public as $fn$
  select coalesce(btrim(nombre), '') = ''
      or exists (
        select 1 from colaboradores c
         where regexp_replace(c.cedula, '\D', '', 'g') = regexp_replace(coalesce(ced, ''), '\D', '', 'g')
           and sin_tildes(btrim(coalesce(
                 case upper(btrim(coalesce(tipo, '')))
                   when 'LIDER'       then c.enc_lider
                   when 'COORDINADOR' then c.enc_coordinador
                   else c.enc_jefatura
                 end, '')))
             = sin_tildes(btrim(nombre))
      );
$fn$;

-- ------------------------------------------------------------
-- 6) Listas para los desplegables de filtro
--    Solo nombres con gente activa: el filtro no se llena de
--    encargados que ya no tienen operación.
-- ------------------------------------------------------------
create or replace function api_lista_encargados()
returns jsonb language sql stable security definer set search_path = public as $fn$
  with base as (
    select c.enc_jefatura, c.enc_lider, c.enc_coordinador, c.proyecto_efectivo
    from colaboradores c
    where c.activo and cargo_aplica(c.cargo)
  )
  select jsonb_build_object(
    'jefaturas', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select enc_jefatura nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where coalesce(enc_jefatura,'') <> '' group by enc_jefatura) x), '[]'::jsonb),
    'lideres', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select enc_lider nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where coalesce(enc_lider,'') <> '' group by enc_lider) x), '[]'::jsonb),
    'coordinadores', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', x.nombre, 'personas', x.personas, 'proyectos', x.proyectos)
             order by x.nombre)
      from (select enc_coordinador nombre, count(*) personas, count(distinct proyecto_efectivo) proyectos
              from base where coalesce(enc_coordinador,'') <> '' group by enc_coordinador) x), '[]'::jsonb),
    'sin_asignar', jsonb_build_object(
      'jefatura',    (select count(*) from base where coalesce(enc_jefatura,'') = ''),
      'lider',       (select count(*) from base where coalesce(enc_lider,'') = ''),
      'coordinador', (select count(*) from base where coalesce(enc_coordinador,'') = ''))
  );
$fn$;

-- ------------------------------------------------------------
-- 7) Panel de administración — consultar
-- ------------------------------------------------------------
create or replace function admin_encargados()
returns jsonb language sql security definer set search_path = public as $fn$
  with proys as (
    select coalesce(nullif(btrim(c.proyecto_id),''),'') proyecto_id,
           max(c.proyecto) proyecto,
           count(*) filter (where c.activo and cargo_aplica(c.cargo)) activos,
           count(*) filter (where c.activo and cargo_aplica(c.cargo)
                              and coalesce(c.enc_coordinador,'') = '') sin_coordinador
    from colaboradores c
    where coalesce(c.proyecto,'') <> ''
    group by coalesce(nullif(btrim(c.proyecto_id),''),'')
  )
  select jsonb_build_object(
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'proyecto_id', p.proyecto_id,
               'proyecto',    coalesce(p.proyecto,''),
               'cliente',     coalesce(rg.cliente,''),
               'jefatura',    coalesce(rg.jefatura,''),
               'lider',       coalesce(rg.lider,''),
               'coordinador', coalesce(rg.coordinador,''),
               'activos',     p.activos,
               'sin_coordinador', p.sin_coordinador,
               'frentes', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'frente', f.frente, 'jefatura', coalesce(f.jefatura,''),
                           'lider', coalesce(f.lider,''), 'coordinador', coalesce(f.coordinador,''),
                           'personas', (select count(*) from colaboradores cc
                                         where cc.activo and cargo_aplica(cc.cargo)
                                           and coalesce(nullif(btrim(cc.proyecto_id),''),'') = p.proyecto_id
                                           and btrim(coalesce(cc.frente,'')) = f.frente))
                         order by f.frente)
                  from responsables_proyecto f
                  where f.proyecto_id = p.proyecto_id and f.frente <> ''), '[]'::jsonb))
             order by coalesce(p.proyecto,''))
      from proys p
      left join responsables_proyecto rg on rg.proyecto_id = p.proyecto_id and rg.frente = ''), '[]'::jsonb),
    -- CECOs cargados que no corresponden a ningún proyecto de la matriz.
    'huerfanos', coalesce((
      select jsonb_agg(jsonb_build_object('proyecto_id', r.proyecto_id, 'cliente', coalesce(r.cliente,''),
                                          'jefatura', coalesce(r.jefatura,''), 'lider', coalesce(r.lider,''))
             order by r.proyecto_id)
      from responsables_proyecto r
      where r.frente = ''
        and not exists (select 1 from proys p where p.proyecto_id = r.proyecto_id)), '[]'::jsonb)
  );
$fn$;

-- Personas activas de un proyecto, para asignarles frente o coordinador.
create or replace function admin_personas_proyecto(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'cedula', c.cedula, 'nombre', coalesce(c.nombre,''),
           'ciudad', coalesce(c.ciudad,''), 'cargo', coalesce(c.cargo,''),
           'frente', coalesce(c.frente,''),
           'coordinador_propio', coalesce(c.coordinador,''),
           'coordinador', coalesce(c.enc_coordinador,''),
           'jefatura', coalesce(c.enc_jefatura,''), 'lider', coalesce(c.enc_lider,''))
         order by coalesce(c.ciudad,''), c.nombre), '[]'::jsonb)
  from colaboradores c
  where c.activo and cargo_aplica(c.cargo)
    and coalesce(nullif(btrim(c.proyecto_id),''),'') = btrim(coalesce(payload->>'proyecto_id',''));
$fn$;

-- ------------------------------------------------------------
-- 8) Panel de administración — guardar
-- ------------------------------------------------------------

-- Guardar (o borrar) la fila de un proyecto o de uno de sus frentes.
create or replace function admin_guardar_encargado(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  pid  text := btrim(coalesce(payload->>'proyecto_id',''));
  fr   text := btrim(coalesce(payload->>'frente',''));
  n    int;
begin
  if pid = '' then raise exception 'Falta el codigo del proyecto (CECO).'; end if;

  if coalesce(payload->>'borrar','') = 'true' then
    if fr = '' then raise exception 'Para quitar los encargados del proyecto completo, deja los campos vacios y guarda.'; end if;
    delete from responsables_proyecto where proyecto_id = pid and frente = fr;
    -- Quien estaba en ese frente vuelve al encargado general del proyecto.
    update colaboradores set frente = null
      where coalesce(nullif(btrim(proyecto_id),''),'') = pid and btrim(coalesce(frente,'')) = fr;
    perform recalcular_encargados();
    return jsonb_build_object('mensaje', 'Frente eliminado. Su gente vuelve al encargado del proyecto.');
  end if;

  insert into responsables_proyecto (proyecto_id, frente, cliente, jefatura, lider, coordinador, actualizado_en)
  values (pid, fr,
          nullif(btrim(coalesce(payload->>'cliente','')),''),
          nullif(upper(btrim(coalesce(payload->>'jefatura',''))),''),
          nullif(upper(btrim(coalesce(payload->>'lider',''))),''),
          nullif(upper(btrim(coalesce(payload->>'coordinador',''))),''),
          now())
  on conflict (proyecto_id, frente) do update set
    cliente     = coalesce(excluded.cliente, responsables_proyecto.cliente),
    jefatura    = excluded.jefatura,
    lider       = excluded.lider,
    coordinador = excluded.coordinador,
    actualizado_en = now();

  perform recalcular_encargados();
  select count(*) into n from colaboradores c
    where c.activo and coalesce(nullif(btrim(c.proyecto_id),''),'') = pid;

  return jsonb_build_object('mensaje',
    'Guardado. Cubre ' || n || ' persona(s) de este proyecto' || case when fr <> '' then ' en el frente ' || fr else '' end || '.');
end;
$fn$;

-- Carga masiva de la tabla de la compañía (CECO / cliente / jefatura / líder).
-- Un campo que llegue vacío NO borra lo que ya estaba guardado.
create or replace function admin_cargar_encargados(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fila jsonb;
  pid text; cli text; jef text; lid text;
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

    if pid = '' then ignorados := ignorados + 1; continue; end if;

    select true into ya from responsables_proyecto where proyecto_id = pid and frente = '' limit 1;
    if found then
      update responsables_proyecto set
        cliente  = coalesce(cli, cliente),
        jefatura = coalesce(jef, jefatura),
        lider    = coalesce(lid, lider),
        actualizado_en = now()
      where proyecto_id = pid and frente = '';
      actualizados := actualizados + 1;
    else
      insert into responsables_proyecto (proyecto_id, frente, cliente, jefatura, lider)
      values (pid, '', cli, jef, lid);
      creados := creados + 1;
    end if;
    ya := null;
  end loop;

  perform recalcular_encargados();

  insert into historial (tipo, cedula, detalle)
  values ('ENCARGADOS', null, 'Carga de encargados: ' || creados || ' nuevos, ' || actualizados || ' actualizados.');

  return jsonb_build_object(
    'creados', creados, 'actualizados', actualizados, 'ignorados', ignorados,
    -- Lo accionable: proyectos con gente activa que siguen sin jefe o sin líder.
    'proyectos_sin_jefe', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_jefatura,'') = ''),
    'proyectos_sin_lider', (
      select count(distinct coalesce(nullif(btrim(c.proyecto_id),''),''))
      from colaboradores c where c.activo and cargo_aplica(c.cargo) and coalesce(c.enc_lider,'') = ''),
    'mensaje', 'Listo. ' || creados || ' proyecto(s) nuevos y ' || actualizados || ' actualizados.');
end;
$fn$;

-- Asignar frente y/o coordinador propio a un grupo de personas.
create or replace function admin_asignar_frente(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ceds text[];
  fr text;
  co text;
  n int := 0;
begin
  select array_agg(regexp_replace(v, '\D', '', 'g'))
    into ceds
    from jsonb_array_elements_text(coalesce(payload->'cedulas','[]'::jsonb)) v;
  if ceds is null or array_length(ceds,1) is null then
    raise exception 'Selecciona al menos una persona.';
  end if;

  -- Una clave ausente no se toca; una clave con texto vacío sí limpia el dato.
  if payload ? 'frente' then
    fr := nullif(upper(btrim(coalesce(payload->>'frente',''))),'');
    update colaboradores set frente = fr, actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = any(ceds);
    get diagnostics n = row_count;
  end if;

  if payload ? 'coordinador' then
    co := nullif(upper(btrim(coalesce(payload->>'coordinador',''))),'');
    update colaboradores set coordinador = co, actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = any(ceds);
    get diagnostics n = row_count;
  end if;

  if n = 0 then raise exception 'No se encontro ninguna de esas cedulas en la matriz.'; end if;

  return jsonb_build_object('actualizados', n,
    'mensaje', n || ' persona(s) actualizada(s).');
end;
$fn$;

-- ------------------------------------------------------------
-- 9) Permisos
-- ------------------------------------------------------------
revoke all on function admin_encargados()             from public, anon;
revoke all on function admin_personas_proyecto(jsonb) from public, anon;
revoke all on function admin_guardar_encargado(jsonb) from public, anon;
revoke all on function admin_cargar_encargados(jsonb) from public, anon;
revoke all on function admin_asignar_frente(jsonb)    from public, anon;
revoke all on function recalcular_encargados()        from public, anon;
grant execute on function admin_encargados()             to authenticated;
grant execute on function admin_personas_proyecto(jsonb) to authenticated;
grant execute on function admin_guardar_encargado(jsonb) to authenticated;
grant execute on function admin_cargar_encargados(jsonb) to authenticated;
grant execute on function admin_asignar_frente(jsonb)    to authenticated;

-- ------------------------------------------------------------
-- 9.b) Routers, con las acciones nuevas
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
    when 'encargados'                then result := admin_encargados();
    when 'guardarEncargado'          then result := admin_guardar_encargado(payload);
    when 'cargarEncargados'          then result := admin_cargar_encargados(payload);
    when 'personasProyecto'          then result := admin_personas_proyecto(payload);
    when 'asignarFrente'             then result := admin_asignar_frente(payload);
    when 'listaEncargados'           then result := api_lista_encargados();
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$fn$;

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
-- 10) Primer cálculo con lo que ya está en la matriz
-- ------------------------------------------------------------
select recalcular_encargados() as colaboradores_actualizados;
