-- ============================================================
--  LINEAS - Etapa 2: la matriz se carga por linea
--  ------------------------------------------------------------
--  PROBLEMA QUE ARREGLA (importante):
--
--  Al actualizar la matriz, el sistema inactiva a TODO el que no
--  aparezca en el texto pegado (matriz_cerrar_actualizacion). Eso
--  esta bien mientras exista una sola linea, pero con dos es una
--  bomba: pegar la matriz de Warehouse intentaria inactivar a todo
--  Last Mile. La red de seguridad del 50 % lo abortaria casi
--  siempre, pero eso es suerte, no diseno.
--
--  Desde aqui, el cargue:
--    - se hace SOBRE UNA LINEA, la que este activa en el panel;
--    - solo inactiva gente de esa linea;
--    - la red de seguridad del 50 % se mide dentro de la linea;
--    - una cedula que ya pertenece a otra linea NO se mueve: se
--      cuenta aparte y se reporta, porque un traslado entre lineas
--      es una decision, no el efecto de un pegado.
--
--  Ejecutar DESPUES de db/lineas_1_fundacion.sql.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) El cierre del cargue, ahora por linea
--  ------------------------------------------------------------
--  Se reemplaza la version de un solo argumento para que nadie
--  pueda llamar por error a la que barria toda la operacion.
-- ------------------------------------------------------------
drop function if exists matriz_cerrar_actualizacion(text[]);

create or replace function matriz_cerrar_actualizacion(presentes text[], p_linea text)
returns int language plpgsql security definer set search_path = public as $fn$
declare
  hoy text := to_char((now() at time zone 'America/Bogota')::date, 'YYYY-MM-DD');
  activos_antes int;
  van_a_caer int;
  n int;
begin
  if coalesce(array_length(presentes, 1), 0) = 0 then
    raise exception 'La matriz cargada no trajo ninguna cedula valida. No se cambio nada.';
  end if;
  if coalesce(btrim(p_linea),'') = '' then
    raise exception 'Falta la linea sobre la que se esta cargando la matriz.';
  end if;

  select count(*) into activos_antes
    from colaboradores where activo and linea = p_linea;

  select count(*) into van_a_caer
    from colaboradores
   where activo and not provisional and linea = p_linea
     and not (regexp_replace(cedula,'\D','','g') = any(presentes));

  -- Red de seguridad: nunca se inactiva a mas de la mitad de la linea
  -- de un solo golpe. Casi siempre significa que el pegado quedo incompleto.
  if activos_antes > 20 and van_a_caer > (activos_antes * 0.5) then
    raise exception
      'La matriz cargada dejaria inactivos a % de % colaboradores activos de %. Parece incompleta: revisa que hayas pegado el archivo completo con su fila de titulos. No se cambio nada.',
      van_a_caer, activos_antes, p_linea;
  end if;

  -- Quien ya venia en la nomina deja de ser provisional.
  update colaboradores set
    provisional = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Confirmado en la matriz del ' || hoy || '.', ' |'),
    actualizado_en = now()
  where provisional
    and linea = p_linea
    and regexp_replace(cedula,'\D','','g') = any(presentes);

  update colaboradores set activo = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Inactivada el ' || hoy || ': no aparece en la matriz cargada.', ' |'),
    actualizado_en = now()
  where activo
    and not provisional
    and linea = p_linea
    and not (regexp_replace(cedula,'\D','','g') = any(presentes));
  get diagnostics n = row_count;
  return n;
end;
$fn$;


-- ------------------------------------------------------------
--  2) El cargue de matriz, amarrado a la linea activa
-- ------------------------------------------------------------
create or replace function api_actualizar_matriz(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  texto text := btrim(replace(coalesce(payload->>'data',''), E'\r', ''));
  filas text[]; hdr text[]; cols text[];
  idx jsonb := '{}'::jsonb;
  i int; j int;
  ncedula text; retiro text; activo_new boolean; cargo_new text;
  presentes text[] := '{}';
  c_act int := 0; c_new int := 0; c_inact int := 0; c_nocargo int := 0;
  c_otra int := 0;
  v_linea text;
  v_otra text;
  hoy text := to_char((now() at time zone 'America/Bogota'), 'YYYY-MM-DD HH24:MI');
begin
  -- El panel propone la linea; linea_efectiva la valida contra las que
  -- el usuario tiene permitidas y falla si no le corresponde.
  v_linea := linea_efectiva(coalesce(payload->>'linea',''));

  if texto = '' then raise exception 'Pega los datos de la matriz.'; end if;
  filas := string_to_array(texto, E'\n');
  if coalesce(array_length(filas,1),0) < 2 then raise exception 'Incluye la fila de titulos y al menos un registro.'; end if;

  hdr := string_to_array(filas[1], E'\t');
  for i in 1 .. array_length(hdr,1) loop
    idx := idx || jsonb_build_object(btrim(hdr[i]), i);
  end loop;
  if not (idx ? 'ClientId') then raise exception 'No encuentro la columna "ClientId" (cedula). Incluye la fila de titulos.'; end if;
  if not (idx ? 'ClientName') then raise exception 'No encuentro la columna "ClientName" (nombre).'; end if;

  for j in 2 .. array_length(filas,1) loop
    if btrim(filas[j]) = '' then continue; end if;
    cols := string_to_array(filas[j], E'\t');
    ncedula := regexp_replace(mat_val(cols, idx, 'ClientId'), '\D', '', 'g');
    if ncedula = '' then continue; end if;

    -- Una cedula que ya pertenece a otra linea NO se mueve por un pegado:
    -- un traslado entre lineas es una decision, no un efecto secundario.
    select c0.linea into v_otra from colaboradores c0
     where regexp_replace(c0.cedula,'\D','','g') = ncedula;
    if found and v_otra is distinct from v_linea then
      c_otra := c_otra + 1;
      continue;
    end if;
    retiro := mat_val(cols, idx, 'DateRetirement');
    cargo_new := nullif(mat_val(cols, idx, 'PlaceName'), '');
    -- Activo solo si la nomina lo trae activo Y su cargo requiere registro.
    activo_new := (upper(mat_val(cols, idx, 'State')) = 'A' and retiro = ''
                   and cargo_aplica(cargo_new));
    if not cargo_aplica(cargo_new) then c_nocargo := c_nocargo + 1; end if;
    presentes := presentes || ncedula;

    if exists (select 1 from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula) then
      update colaboradores set
        estado_nomina = nullif(mat_val(cols,idx,'State'),''),
        nombre = coalesce(nullif(mat_val(cols,idx,'ClientName'),''), nombre),
        cargo = coalesce(cargo_new, cargo),
        proyecto_id = coalesce(nullif(mat_val(cols,idx,'ProjectId'),''), proyecto_id),
        proyecto = coalesce(nullif(mat_val(cols,idx,'ProjectName'),''), proyecto),
        ciudad = coalesce(nullif(mat_val(cols,idx,'Ciudad'),''), ciudad),
        telefono = coalesce(nullif(mat_val(cols,idx,'Phone'),''), telefono),
        celular = coalesce(nullif(mat_val(cols,idx,'CelPhone'),''), celular),
        email = coalesce(nullif(mat_val(cols,idx,'Email'),''), email),
        activo = activo_new,
        observacion_coordinador = case
          when not cargo_aplica(coalesce(cargo_new, cargo))
            then 'Su cargo no requiere diligenciar los formularios HSEQ.'
          else observacion_coordinador end,
        actualizado_en = now()
      where regexp_replace(cedula,'\D','','g') = ncedula;
      c_act := c_act + 1;
    else
      insert into colaboradores (cedula, estado_nomina, nombre, cargo, proyecto_id, proyecto,
        ciudad, telefono, celular, email, activo, tipo_vehiculo, observaciones_hsq, linea)
      values (ncedula, nullif(mat_val(cols,idx,'State'),''), mat_val(cols,idx,'ClientName'),
        cargo_new, nullif(mat_val(cols,idx,'ProjectId'),''),
        nullif(mat_val(cols,idx,'ProjectName'),''), nullif(mat_val(cols,idx,'Ciudad'),''),
        nullif(mat_val(cols,idx,'Phone'),''), nullif(mat_val(cols,idx,'CelPhone'),''),
        nullif(mat_val(cols,idx,'Email'),''), activo_new,
        case when perfil_cargo(cargo_new) = 'VEHICULO' then 'VEHICULO' else 'MOTO' end,
        'Agregada el ' || hoy || ' desde actualizacion de matriz.', v_linea)
      on conflict (cedula) do nothing;
      c_new := c_new + 1;
    end if;
  end loop;

  c_inact := matriz_cerrar_actualizacion(presentes, v_linea);

  insert into config (clave, valor) values ('MATRIZ_ULTIMA_ACTUALIZACION', hoy)
    on conflict (clave) do update set valor = excluded.valor;
  insert into historial (tipo, cedula, detalle)
  values ('ACTUALIZACION_MATRIZ', '', v_linea || ': actualizados ' || c_act || ', nuevos ' || c_new ||
          ', inactivados ' || c_inact || ', con cargo no exigible ' || c_nocargo ||
          case when c_otra > 0 then ', de otra linea (ignorados) ' || c_otra else '' end);

  return jsonb_build_object('actualizados', c_act, 'nuevos', c_new, 'inactivados', c_inact,
    'cargoNoExigible', c_nocargo, 'linea', v_linea, 'otraLinea', c_otra,
    'provisionales', (select count(*) from colaboradores
                       where provisional and activo and linea = v_linea),
    'totalEnData', coalesce(array_length(presentes,1),0), 'fecha', hoy);
end;
$fn$;


-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Ya no existe la version peligrosa de un solo argumento.
select p.oid::regprocedure as firma
  from pg_proc p
 where p.proname = 'matriz_cerrar_actualizacion';

-- b) El cargue pide linea.
select 'api_actualizar_matriz' as funcion,
       case when prosrc like '%linea_efectiva%' then 'ACTUALIZADA'
            else 'SIN ACTUALIZAR' end as estado
  from pg_proc where proname = 'api_actualizar_matriz';

-- c) Cuanta gente activa hay por linea (esto es lo que protege el 50 %).
select linea, count(*) filter (where activo) as activos, count(*) as total
  from colaboradores group by linea order by linea;
