-- ============================================================
--  Gestión HSEQ Motos — Solo dos cargos deben registrar
--  ------------------------------------------------------------
--  Estaban contando como activos cargos que no deben diligenciar
--  (CONDUCTOR ASISTENCIAL INTRAHOSPITALARIO, QUICKER - MENSAJERO
--  BICICLETA…), lo que inflaba los "esperados" y bajaba el
--  cumplimiento de sus proyectos.
--
--  Desde ahora solo se exige registro a:
--      QUICKER - MENSAJERO   (moto)
--      QUICKER - CONDUCTOR   (vehículo)
--
--  La comparación es EXACTA: "QUICKER - MENSAJERO BICICLETA"
--  contiene el texto del primero, pero no es el mismo cargo.
--
--  La lista vive en config, así que se puede ampliar sin tocar
--  el código (ver el final del archivo).
--
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) La lista de cargos que sí deben registrar
-- ------------------------------------------------------------
insert into config (clave, valor)
values ('CARGOS_EXIGIBLES', 'QUICKER - MENSAJERO|QUICKER - CONDUCTOR')
on conflict (clave) do update set valor = excluded.valor;

-- ------------------------------------------------------------
-- 2) Normalizar el cargo: sin tildes, en mayúsculas, con los
--    espacios y el guion parejos. Así "QUICKER-MENSAJERO" y
--    "Quicker - Mensajero" se reconocen igual.
-- ------------------------------------------------------------
create or replace function cargo_norm(cargo text)
returns text language sql immutable set search_path = public as $fn$
  select btrim(regexp_replace(
           regexp_replace(sin_tildes(coalesce(cargo, '')), '\s*-\s*', ' - ', 'g'),
           '\s+', ' ', 'g'));
$fn$;

-- ¿Este cargo debe diligenciar los formularios?
create or replace function cargo_aplica(cargo text)
returns boolean language sql stable set search_path = public as $fn$
  select cargo_norm(cargo) = any(
    string_to_array(
      coalesce((select valor from config where clave = 'CARGOS_EXIGIBLES'),
               'QUICKER - MENSAJERO|QUICKER - CONDUCTOR'),
      '|'));
$fn$;

-- ------------------------------------------------------------
-- 3) El perfil ahora se decide por el cargo exacto, no por
--    encontrar la palabra CONDUCTOR dentro del texto.
-- ------------------------------------------------------------
create or replace function perfil_cargo(cargo text)
returns text language sql stable set search_path = public as $fn$
  select case when cargo_norm(cargo) = 'QUICKER - CONDUCTOR' then 'VEHICULO' else 'MOTO' end;
$fn$;

-- ------------------------------------------------------------
-- 4) Inactivar a quienes su cargo no requiere registro.
--    Quedan en la matriz con la razón anotada; no se les exige,
--    no cuentan en el cumplimiento y no pueden diligenciar.
-- ------------------------------------------------------------
do $limpieza$
declare n int;
begin
  update colaboradores set
    activo = false,
    observacion_coordinador = 'Su cargo no requiere diligenciar los formularios HSEQ.',
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Inactivada el ' || to_char((now() at time zone 'America/Bogota')::date,'YYYY-MM-DD') ||
      ': el cargo ' || coalesce(cargo,'(sin cargo)') || ' no esta en la lista de cargos exigibles.', ' |'),
    actualizado_en = now()
  where activo and not cargo_aplica(cargo);
  get diagnostics n = row_count;
  raise notice 'Colaboradores inactivados por cargo no exigible: %', n;
end;
$limpieza$;

-- ------------------------------------------------------------
-- 5) Que la próxima carga de nómina no los vuelva a activar
-- ------------------------------------------------------------
create or replace function api_actualizar_matriz(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  texto text := btrim(replace(coalesce(payload->>'data',''), E'\r', ''));
  lineas text[]; hdr text[]; cols text[];
  idx jsonb := '{}'::jsonb;
  i int; j int;
  ncedula text; retiro text; activo_new boolean; cargo_new text;
  presentes text[] := '{}';
  c_act int := 0; c_new int := 0; c_inact int := 0; c_nocargo int := 0;
  hoy text := to_char((now() at time zone 'America/Bogota'), 'YYYY-MM-DD HH24:MI');
begin
  if texto = '' then raise exception 'Pega los datos de la matriz.'; end if;
  lineas := string_to_array(texto, E'\n');
  if coalesce(array_length(lineas,1),0) < 2 then raise exception 'Incluye la fila de titulos y al menos un registro.'; end if;

  hdr := string_to_array(lineas[1], E'\t');
  for i in 1 .. array_length(hdr,1) loop
    idx := idx || jsonb_build_object(btrim(hdr[i]), i);
  end loop;
  if not (idx ? 'ClientId') then raise exception 'No encuentro la columna "ClientId" (cedula). Incluye la fila de titulos.'; end if;
  if not (idx ? 'ClientName') then raise exception 'No encuentro la columna "ClientName" (nombre).'; end if;

  for j in 2 .. array_length(lineas,1) loop
    if btrim(lineas[j]) = '' then continue; end if;
    cols := string_to_array(lineas[j], E'\t');
    ncedula := regexp_replace(mat_val(cols, idx, 'ClientId'), '\D', '', 'g');
    if ncedula = '' then continue; end if;
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
        ciudad, telefono, celular, email, activo, tipo_vehiculo, observaciones_hsq)
      values (ncedula, nullif(mat_val(cols,idx,'State'),''), mat_val(cols,idx,'ClientName'),
        cargo_new, nullif(mat_val(cols,idx,'ProjectId'),''),
        nullif(mat_val(cols,idx,'ProjectName'),''), nullif(mat_val(cols,idx,'Ciudad'),''),
        nullif(mat_val(cols,idx,'Phone'),''), nullif(mat_val(cols,idx,'CelPhone'),''),
        nullif(mat_val(cols,idx,'Email'),''), activo_new,
        case when perfil_cargo(cargo_new) = 'VEHICULO' then 'VEHICULO' else 'MOTO' end,
        'Agregada el ' || hoy || ' desde actualizacion de matriz.')
      on conflict (cedula) do nothing;
      c_new := c_new + 1;
    end if;
  end loop;

  c_inact := matriz_cerrar_actualizacion(presentes);

  insert into config (clave, valor) values ('MATRIZ_ULTIMA_ACTUALIZACION', hoy)
    on conflict (clave) do update set valor = excluded.valor;
  insert into historial (tipo, cedula, detalle)
  values ('ACTUALIZACION_MATRIZ', '', 'Actualizados ' || c_act || ', nuevos ' || c_new ||
          ', inactivados ' || c_inact || ', con cargo no exigible ' || c_nocargo);

  return jsonb_build_object('actualizados', c_act, 'nuevos', c_new, 'inactivados', c_inact,
    'cargoNoExigible', c_nocargo,
    'provisionales', (select count(*) from colaboradores where provisional and activo),
    'totalEnData', coalesce(array_length(presentes,1),0), 'fecha', hoy);
end;
$fn$;

-- ------------------------------------------------------------
-- 6) Mensaje claro para quien intente registrar sin que su cargo
--    lo requiera (por si alguien queda activo por otra vía).
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  puede boolean;
  v_estado jsonb := '{}'::jsonb;
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
  puede := c.activo and cargo_aplica(c.cargo);

  if puede then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
      order by frm.orden
    loop
      select to_char(reg.hora,'HH24:MI') as h, reg.id::text as rid into r
        from registros reg
       where regexp_replace(reg.cedula,'\D','','g') = ncedula
         and reg.formulario_id = f.id
         and reg.fecha = hoy
         and coalesce(reg.estado,'') <> 'ANULADO'
       limit 1;
      if found then
        v_estado := v_estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        v_estado := v_estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
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
    'activo', puede,
    'observacionCoordinador', v_obs,
    'mensaje', case
      when puede then 'Activo habilitado para registro.'
      when not cargo_aplica(c.cargo) then
        'Tu cargo (' || coalesce(c.cargo,'sin cargo') || ') no requiere diligenciar estos formularios.'
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
      where frm.activo and pf.proyecto = proy and puede), '[]'::jsonb),
    'estadoDiario', v_estado,
    'documentos', docs
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 7) Al guardar tambien se verifica el cargo
-- ------------------------------------------------------------
create or replace function api_guardar_registro_check_cargo()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_cargo text;
begin
  select cargo into v_cargo from colaboradores
   where regexp_replace(cedula,'\D','','g') = regexp_replace(new.cedula,'\D','','g');
  if not cargo_aplica(v_cargo) then
    raise exception 'El cargo % no requiere diligenciar estos formularios.', coalesce(v_cargo,'(sin cargo)');
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_registro_cargo on registros;
create trigger trg_registro_cargo
  before insert on registros
  for each row execute function api_guardar_registro_check_cargo();


-- ============================================================
--  DIAGNÓSTICO — ejecuta esto después para ver cómo quedó
-- ============================================================
-- select coalesce(nullif(btrim(cargo),''),'(sin cargo)') as cargo,
--        cargo_aplica(cargo) as debe_registrar,
--        count(*) filter (where activo)  as activos,
--        count(*)                        as total
--   from colaboradores
--  group by 1, 2
--  order by debe_registrar desc, activos desc;

-- ============================================================
--  PARA AGREGAR OTRO CARGO A LA LISTA
--    update config
--       set valor = 'QUICKER - MENSAJERO|QUICKER - CONDUCTOR|OTRO CARGO'
--     where clave = 'CARGOS_EXIGIBLES';
--
--  Después hay que reactivar a esas personas:
--    update colaboradores set activo = true, observacion_coordinador = null
--     where not activo and cargo_aplica(cargo)
--       and observacion_coordinador ilike '%no requiere diligenciar%';
-- ============================================================
