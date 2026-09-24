-- ============================================================
--  Personal colaborativo
--  ------------------------------------------------------------
--  Gente que NO esta vinculada en Quick ni en la matriz real de
--  nomina (no la trae ningun export de RRHH), pero que un proyecto
--  puntual necesita que diligencie los mismos formularios y cuente
--  en su indicador. Se carga aparte, el coordinador la mantiene a
--  mano (activar/inactivar/eliminar), y cargar un archivo nuevo
--  NUNCA borra ni inactiva lo que ya estaba.
--
--  DECISION DE DISENO: no es una tabla paralela. Son filas normales
--  de `colaboradores`, marcadas con `es_colaborativo = true`. Con
--  eso, el registro por celular (api_buscar_activo,
--  api_guardar_registro) funciona SIN TOCARLOS: encuentran la
--  cedula igual que a cualquier fijo. Solo hizo falta parchar tres
--  sitios para que nunca se mezclen con el fijo:
--
--   1. matriz_cerrar_actualizacion: nunca inactiva a un colaborativo
--      (antes de este parche, la SIGUIENTE carga de la matriz real
--      los hubiera apagado a todos, porque nunca aparecen en el
--      export de RRHH).
--   2. api_cumplimiento_dia: nuevo filtro 'tipoPersonal' (FIJO por
--      defecto = comportamiento identico al de antes; COLABORATIVO
--      para verlos aparte). Devuelve 'tieneColaborativos' para que
--      el frontend sepa si mostrar el interruptor.
--   3. api_dashboard: mismo filtro 'tipoPersonal', en los 6 puntos
--      donde la funcion consulta `colaboradores` directamente
--      (tmp_calendario, tmp_asignados, periodo anterior, ranking de
--      mensajeros, inactividad, alertas de documentos). Todo lo
--      demas (tmp_exig, tmp_ok, tmp_enc, por_proyecto, por_encargado,
--      series de registros...) ya hereda el filtro porque sale de
--      tmp_asignados/tmp_calendario, asi que no hizo falta tocarlo.
--
--  SEGURIDAD DEL PARCHE: como hoy nadie tiene es_colaborativo=true,
--  el filtro "and c.es_colaborativo = false" (el default de
--  tipoPersonal) es verdadero para el 100% de las filas actuales.
--  Los numeros de dashboard/cumplimiento no cambian ni un solo
--  digito hasta que alguien cargue el primer colaborativo. Se
--  verifico contra datos reales de WAREHOUSE antes y despues del
--  parche (31 activos, sin cambio).
--
--  CARGOS: el motor de exigibilidad (cargo_aplica/perfil_cargo) solo
--  reconoce dos cargos exactos, sacados de la config
--  CARGOS_EXIGIBLES: 'QUICKER - MENSAJERO' y 'QUICKER - CONDUCTOR'.
--  api_colaborativos_guardar traduce lo que el coordinador escriba
--  en "Cargo" a uno de esos dos (si menciona "conductor" o
--  "vehiculo", CONDUCTOR; si no, MENSAJERO) -sin esto, la persona
--  quedaria cargada pero invisible para el indicador, que es
--  justamente lo que se queria evitar.
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La bandera
-- ------------------------------------------------------------
alter table colaboradores add column if not exists es_colaborativo boolean not null default false;
comment on column colaboradores.es_colaborativo is
  'Personal externo (no esta en la matriz de nomina real, no esta vinculado en Quick). Lo carga el coordinador a mano o pegado desde Excel via api_colaborativos_guardar. actualizarMatriz nunca lo toca ni lo inactiva.';

-- ------------------------------------------------------------
--  2) matriz_cerrar_actualizacion: nunca toca a un colaborativo
--  ------------------------------------------------------------
--  Se parchea por ancla con regex (no se pega el cuerpo completo):
--  la funcion original no tenia parametro para esto y hay que
--  tocar tres WHERE distintos sin romper el resto.
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  pat1 text := 'select\s+count\(\*\)\s+into\s+activos_antes\s+from\s+colaboradores\s+where\s+activo\s+and\s+linea\s*=\s*p_linea;';
  pat2 text := 'select\s+count\(\*\)\s+into\s+van_a_caer\s+from\s+colaboradores\s+where\s+activo\s+and\s+not\s+provisional\s+and\s+linea\s*=\s*p_linea\s+and\s+not\s+\(';
  pat3 text := 'where\s+activo\s+and\s+not\s+provisional\s+and\s+linea\s*=\s*p_linea\s+and\s+not\s+\(';
begin
  select prosrc into src from pg_proc where proname = 'matriz_cerrar_actualizacion';
  if src is null then raise exception 'No existe matriz_cerrar_actualizacion'; end if;
  if position('es_colaborativo' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.'; return;
  end if;

  if src !~* pat1 then raise exception 'No encontre el conteo activos_antes'; end if;
  nuevo := regexp_replace(src, pat1,
    'select count(*) into activos_antes' || chr(10)
    || '    from colaboradores where activo and linea = p_linea and not es_colaborativo;', 'i');

  if nuevo !~* pat2 then raise exception 'No encontre el conteo van_a_caer'; end if;
  nuevo := regexp_replace(nuevo, pat2,
    'select count(*) into van_a_caer' || chr(10)
    || '    from colaboradores' || chr(10)
    || '   where activo and not provisional and linea = p_linea and not es_colaborativo' || chr(10)
    || '     and not (', 'i');

  -- Despues del parche de arriba, este patron ya solo aparece en el
  -- update de inactivacion (el de van_a_caer quedo distinto).
  if nuevo !~* pat3 then raise exception 'No encontre el update de inactivacion'; end if;
  nuevo := regexp_replace(nuevo, pat3,
    'where activo' || chr(10)
    || '    and not provisional' || chr(10)
    || '    and linea = p_linea' || chr(10)
    || '    and not es_colaborativo' || chr(10)
    || '    and not (', 'i');

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;
  execute 'create or replace function matriz_cerrar_actualizacion(presentes text[], p_linea text)'
       || ' returns int language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'matriz_cerrar_actualizacion parchada.';
end
$do$;

-- ------------------------------------------------------------
--  3) api_cumplimiento_dia: filtro 'tipoPersonal' y bandera
--     'tieneColaborativos' en la respuesta.
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  patDecl text := 'v_linea\s+text\s*:=\s*linea_efectiva\(coalesce\(payload->>''linea'',''''\)\);';
  patWhere text := 'from\s+colaboradores\s+c\s+where\s+c\.activo\s+and\s+c\.linea\s*=\s*v_linea\s+and\s+\(filtro_proy=';
  patForms text := 'join\s+colaboradores\s+c\s+on\s+c\.proyecto_efectivo\s*=\s*pf\.proyecto\s+and\s+c\.activo\s+and\s+c\.linea\s*=\s*v_linea';
  patReturn text := 'return\s+jsonb_build_object\(\s*''fecha'',\s*to_char\(dia,''YYYY-MM-DD''\),\s*''proyecto'',\s*filtro_proy,\s*''formularios'',\s*forms,';
begin
  select prosrc into src from pg_proc where proname = 'api_cumplimiento_dia';
  if src is null then raise exception 'No existe api_cumplimiento_dia'; end if;
  if position('tipoPersonal' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.'; return;
  end if;

  if src !~* patDecl then raise exception 'No encontre la declaracion de v_linea'; end if;
  nuevo := regexp_replace(src, patDecl,
    'v_linea text := linea_efectiva(coalesce(payload->>''linea'',''''));' || chr(10)
    || '  v_solo_colab boolean := upper(coalesce(payload->>''tipoPersonal'','''')) = ''COLABORATIVO'';', 'i');

  if nuevo !~* patWhere then raise exception 'No encontre el where de colaboradores'; end if;
  nuevo := regexp_replace(nuevo, patWhere,
    'from colaboradores c' || chr(10)
    || '    where c.activo and c.linea = v_linea and c.es_colaborativo = v_solo_colab and (filtro_proy=', 'i');

  if nuevo !~* patForms then raise exception 'No encontre el join de forms'; end if;
  nuevo := regexp_replace(nuevo, patForms,
    'join colaboradores c on c.proyecto_efectivo=pf.proyecto and c.activo and c.linea = v_linea and c.es_colaborativo = v_solo_colab', 'i');

  if nuevo !~* patReturn then raise exception 'No encontre el return final'; end if;
  nuevo := regexp_replace(nuevo, patReturn,
    'return jsonb_build_object(' || chr(10)
    || '    ''fecha'', to_char(dia,''YYYY-MM-DD''), ''proyecto'', filtro_proy, ''formularios'', forms,' || chr(10)
    || '    ''tieneColaborativos'', exists(select 1 from colaboradores hc' || chr(10)
    || '      where hc.linea = v_linea and hc.activo and hc.es_colaborativo' || chr(10)
    || '        and (filtro_proy = '''' or hc.proyecto_efectivo = filtro_proy or hc.proyecto_efectivo = nombre_proyecto(filtro_proy))),', 'i');

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;
  execute 'create or replace function api_cumplimiento_dia(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'api_cumplimiento_dia parchada con tipoPersonal.';
end
$do$;

-- ------------------------------------------------------------
--  4) api_dashboard: mismo filtro, en los 6 puntos que consultan
--     `colaboradores` directamente (no via tmp_asignados/tmp_calendario).
--  ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  patDecl text := 'v_linea\s+text\s*:=\s*linea_efectiva\(coalesce\(payload->>''linea'',''''\)\);';
  patCal  text := 'delete\s+from\s+tmp_calendario\s+tc\s+where\s+not\s+exists\s*\(select\s+1\s+from\s+colaboradores\s+c\s+where\s+c\.cedula\s*=\s*tc\.cedula\s+and\s+c\.linea\s*=\s*v_linea\)\s*;';
  patProy text := 'c\.activo\s+and\s+c\.linea\s*=\s*v_linea\s+and\s+\(proy=';
  patPrev text := 'join\s+colaboradores\s+c2\s+on\s+c2\.cedula\s*=\s*dc\.cedula\s+and\s+c2\.linea\s*=\s*v_linea';
  patMsj  text := 'c\.activo\s+and\s+c\.linea\s*=\s*v_linea\s+and\s+req\.cedula\s+is\s+not\s+null';
  patRet  text := '''actualizado'',to_char\(now\(\)\s+at\s+time\s+zone\s+''America/Bogota'',''YYYY-MM-DD HH24:MI''\)';
  n_proy int := 0;
begin
  select prosrc into src from pg_proc where proname = 'api_dashboard';
  if src is null then raise exception 'No existe api_dashboard'; end if;
  if position('v_solo_colab' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.'; return;
  end if;

  if src !~* patDecl then raise exception 'No encontre la declaracion de v_linea'; end if;
  nuevo := regexp_replace(src, patDecl,
    'v_linea text := linea_efectiva(coalesce(payload->>''linea'',''''));' || chr(10)
    || '  v_solo_colab boolean := upper(coalesce(payload->>''tipoPersonal'','''')) = ''COLABORATIVO'';', 'i');

  if nuevo !~* patCal then raise exception 'No encontre el delete de tmp_calendario'; end if;
  nuevo := regexp_replace(nuevo, patCal,
    'delete from tmp_calendario tc' || chr(10)
    || '   where not exists (select 1 from colaboradores c' || chr(10)
    || '                      where c.cedula = tc.cedula and c.linea = v_linea and c.es_colaborativo = v_solo_colab);', 'i');

  -- Tres apariciones identicas (tmp_asignados, inactividad, alertas
  -- documentales). Sin 'g', cada llamada toma la primera que quede sin
  -- tocar: se aplica 3 veces seguidas.
  for n_proy in 1..3 loop
    if nuevo !~* patProy then
      raise exception 'Solo encontre % de las 3 apariciones esperadas de (proy=', n_proy - 1;
    end if;
    nuevo := regexp_replace(nuevo, patProy,
      'c.activo and c.linea = v_linea and c.es_colaborativo = v_solo_colab and (proy=', 'i');
  end loop;

  if nuevo !~* patPrev then raise exception 'No encontre el join de prev_esperadas'; end if;
  nuevo := regexp_replace(nuevo, patPrev,
    'join colaboradores c2 on c2.cedula = dc.cedula and c2.linea = v_linea and c2.es_colaborativo = v_solo_colab', 'i');

  if nuevo !~* patMsj then raise exception 'No encontre el where de mensajeros'; end if;
  nuevo := regexp_replace(nuevo, patMsj,
    'c.activo and c.linea = v_linea and c.es_colaborativo = v_solo_colab and req.cedula is not null', 'i');

  if nuevo !~* patRet then raise exception 'No encontre el campo actualizado del return final'; end if;
  nuevo := regexp_replace(nuevo, patRet,
    '''tieneColaborativos'', exists(select 1 from colaboradores hc' || chr(10)
    || '      where hc.linea = v_linea and hc.activo and hc.es_colaborativo' || chr(10)
    || '        and (proy = '''' or hc.proyecto_efectivo = proy or hc.proyecto_efectivo = nombre_proyecto(proy))),' || chr(10)
    || '    ''actualizado'',to_char(now() at time zone ''America/Bogota'',''YYYY-MM-DD HH24:MI'')', 'i');

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;
  execute 'create or replace function api_dashboard(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'api_dashboard parchado con tipoPersonal.';
end
$do$;

-- ------------------------------------------------------------
--  5) Las cuatro funciones de gestion
-- ------------------------------------------------------------
create or replace function api_colaborativos_lista(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  proy text := btrim(coalesce(payload->>'proyecto',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  filas jsonb;
begin
  filas := coalesce((
    select jsonb_agg(jsonb_build_object(
        'cedula', c.cedula, 'nombre', c.nombre, 'cargo', c.cargo,
        'tipo', perfil_cargo(c.cargo), 'proyecto', c.proyecto, 'ciudad', c.ciudad,
        'placa_moto', c.placa_moto, 'tipo_vehiculo', c.tipo_vehiculo,
        'activo', c.activo, 'creado_en', to_char(c.actualizado_en,'YYYY-MM-DD HH24:MI'))
      order by c.activo desc, c.nombre)
    from colaboradores c
   where c.es_colaborativo and c.linea = v_linea
     and (proy = '' or c.proyecto = proy)), '[]'::jsonb);
  return jsonb_build_object('filas', filas);
end;
$fn$;

create or replace function api_colaborativos_guardar(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  texto text := btrim(replace(coalesce(payload->>'data',''), chr(13), ''));
  proy text := btrim(coalesce(payload->>'proyecto',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  filas text[]; hdr text[]; cols text[];
  idx jsonb := '{}'::jsonb;
  i int; j int;
  ncedula text; nombre_v text; cargo_txt text; cargo_v text;
  c_nuevos int := 0; c_act int := 0; c_saltados int := 0;
begin
  if proy = '' then raise exception 'Falta el proyecto: el personal colaborativo siempre queda asociado a uno.'; end if;
  if texto = '' then raise exception 'Pega los datos (con la fila de titulos) o llena el formulario de alta manual.'; end if;

  filas := string_to_array(texto, chr(10));
  if coalesce(array_length(filas,1),0) < 2 then
    raise exception 'Incluye la fila de titulos y al menos un registro.';
  end if;

  hdr := string_to_array(filas[1], chr(9));
  for i in 1 .. array_length(hdr,1) loop
    idx := idx || jsonb_build_object(btrim(hdr[i]), i);
  end loop;
  if not (idx ? 'Cedula') then raise exception 'No encuentro la columna "Cedula".'; end if;
  if not (idx ? 'Nombre') then raise exception 'No encuentro la columna "Nombre".'; end if;

  for j in 2 .. array_length(filas,1) loop
    if btrim(filas[j]) = '' then continue; end if;
    cols := string_to_array(filas[j], chr(9));
    ncedula := regexp_replace(mat_val(cols, idx, 'Cedula'), '\D', '', 'g');
    nombre_v := mat_val(cols, idx, 'Nombre');
    if ncedula = '' or nombre_v = '' then c_saltados := c_saltados + 1; continue; end if;

    -- Una cedula que ya es colaborador FIJO no se toca por aqui: seria
    -- pisar a alguien de la matriz real con datos sueltos de un pegado.
    if exists (select 1 from colaboradores where cedula = ncedula and not es_colaborativo) then
      c_saltados := c_saltados + 1; continue;
    end if;

    -- El motor de exigibilidad solo reconoce 'QUICKER - MENSAJERO' y
    -- 'QUICKER - CONDUCTOR' (config CARGOS_EXIGIBLES). Se traduce lo
    -- que escriba el coordinador; sin esto la persona quedaria cargada
    -- pero invisible para el indicador.
    cargo_txt := coalesce(mat_val(cols, idx, 'Cargo'), '');
    cargo_v := case when cargo_txt ~* 'conductor|vehiculo|veh[ií]culo'
                     then 'QUICKER - CONDUCTOR' else 'QUICKER - MENSAJERO' end;

    if exists (select 1 from colaboradores where cedula = ncedula and es_colaborativo) then
      update colaboradores set
        nombre = nombre_v, cargo = cargo_v, proyecto = proy,
        ciudad = coalesce(nullif(mat_val(cols,idx,'Ciudad'),''), ciudad),
        placa_moto = coalesce(nullif(mat_val(cols,idx,'Placa'),''), placa_moto),
        tipo_vehiculo = case when cargo_v = 'QUICKER - CONDUCTOR' then 'VEHICULO' else 'MOTO' end,
        activo = true, actualizado_en = now()
      where cedula = ncedula;
      c_act := c_act + 1;
    else
      insert into colaboradores (cedula, nombre, cargo, proyecto, proyecto_id, ciudad, placa_moto,
        tipo_vehiculo, activo, linea, es_colaborativo, observaciones_hsq)
      values (ncedula, nombre_v, cargo_v, proy, proy, nullif(mat_val(cols,idx,'Ciudad'),''),
        nullif(mat_val(cols,idx,'Placa'),''),
        case when cargo_v = 'QUICKER - CONDUCTOR' then 'VEHICULO' else 'MOTO' end,
        true, v_linea, true,
        'Personal colaborativo, cargado el ' || to_char(now() at time zone 'America/Bogota','YYYY-MM-DD') || '.')
      on conflict (cedula) do update set
        nombre = excluded.nombre, cargo = excluded.cargo,
        proyecto = excluded.proyecto, activo = true, es_colaborativo = true,
        actualizado_en = now();
      c_nuevos := c_nuevos + 1;
    end if;
  end loop;

  return jsonb_build_object('nuevos', c_nuevos, 'actualizados', c_act, 'saltados', c_saltados);
end;
$fn$;

create or replace function api_colaborativos_estado(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  activo_new boolean := coalesce((payload->>'activo')::boolean, true);
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  update colaboradores set activo = activo_new, actualizado_en = now()
   where cedula = ncedula and es_colaborativo and linea = v_linea;
  if not found then raise exception 'No encontre a esa persona en el personal colaborativo de tu linea.'; end if;
  return jsonb_build_object('ok', true, 'activo', activo_new);
end;
$fn$;

create or replace function api_colaborativos_eliminar(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  delete from colaboradores where cedula = ncedula and es_colaborativo and linea = v_linea;
  if not found then raise exception 'No encontre a esa persona en el personal colaborativo de tu linea.'; end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

-- ------------------------------------------------------------
--  6) Router: cuatro acciones nuevas, protegidas igual que el resto
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  anchor_lista text := $tag$'reportesLista','reportesPersona','reportesRegistro','reportesFormularios',$tag$;
  anchor_case  text := $tag$when 'reportesFormularios' then result := api_reportes_formularios(payload);$tag$;
begin
  select prosrc into src from pg_proc where proname = 'hseq_api';
  if src is null then raise exception 'No existe hseq_api'; end if;
  if position('colaborativosLista' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.'; return;
  end if;

  if position(anchor_lista in src) = 0 then raise exception 'No encontre la lista de acciones de reportes'; end if;
  nuevo := replace(src, anchor_lista, anchor_lista || $tag$'colaborativosLista','colaborativosGuardar','colaborativosEstado','colaborativosEliminar',$tag$);

  if position(anchor_case in nuevo) = 0 then raise exception 'No encontre el case de reportesFormularios'; end if;
  nuevo := replace(nuevo, anchor_case,
    anchor_case || chr(13) || chr(10)
    || $tag$    when 'colaborativosLista'    then result := api_colaborativos_lista(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosGuardar'  then result := api_colaborativos_guardar(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosEstado'   then result := api_colaborativos_estado(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosEliminar' then result := api_colaborativos_eliminar(payload);$tag$);

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;
  execute 'create or replace function hseq_api(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'hseq_api parchado con las 4 acciones de colaborativos.';
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
select prosrc like '%colaborativosLista%' as router_ok from pg_proc where proname = 'hseq_api';
select (select count(*) from regexp_matches(prosrc, 'es_colaborativo = v_solo_colab', 'g')) as parches_dashboard
  from pg_proc where proname='api_dashboard';  -- deberia dar 6
select prosrc like '%tipoPersonal%' as cumplimiento_ok from pg_proc where proname='api_cumplimiento_dia';
