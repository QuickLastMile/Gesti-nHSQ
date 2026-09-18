-- ============================================================
--  Tres ajustes: datos del vehiculo, y quien toca los rangos
--  ------------------------------------------------------------
--  1. "Actualizar documentacion" tambien pide los datos del
--     vehiculo (marca, cilindraje, propietario, VIN), que hasta
--     ahora solo se preguntaban en el primer registro. Van
--     precargados con lo que ya este guardado y solo son
--     obligatorios cuando faltan: actualizar un documento no
--     puede obligar a reescribir lo demas, ni borrarlo.
--
--  2. Los rangos de medicion los edita SOLO la cuenta general.
--     Un coordinador de linea no deberia poder mover el limite
--     que le aplica a otra linea.
--
--  3. La pantalla de rangos es solo para el formulario de
--     temperatura. Antes listaba cualquier pregunta numerica, y
--     ahi salian cosas como el cilindraje, que no es una medicion
--     con parametros sino un dato del vehiculo.
--
--  Requiere db/actualizar_documentos.sql y db/temperatura_rangos_2.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Que formulario se controla por rangos
--  ------------------------------------------------------------
--  Va como columna y no fijo en el codigo, igual que
--  recibe_documentos: el dia que otra medicion necesite
--  parametros es marcar una casilla.
-- ------------------------------------------------------------
alter table formularios
  add column if not exists controla_rangos boolean not null default false;

update formularios
   set controla_rangos = (coalesce(grupo,'') = 'TEMP_HUM');

-- ------------------------------------------------------------
--  2) Los rangos: solo la cuenta general, solo temperatura
-- ------------------------------------------------------------
create or replace function admin_rangos(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
begin
  if not es_cuenta_general() then
    raise exception 'Solo la cuenta general puede ver y cambiar los rangos de medicion.';
  end if;

  return jsonb_build_object('filas', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', pg.id, 'formulario', fm.nombre, 'formulario_id', pg.formulario_id,
             'etiqueta', coalesce(fm.etiqueta, ''),
             'pregunta', pg.pregunta, 'activo', pg.activo,
             'min_normal', pg.min_normal, 'max_normal', pg.max_normal,
             'min_valido', pg.min_valido, 'max_valido', pg.max_valido)
           order by fm.orden, pg.orden)
      from preguntas pg
      join formularios fm on fm.id = pg.formulario_id
     where pg.tipo_respuesta = 'numero' and pg.activo and fm.activo
       and fm.controla_rangos
  ), '[]'::jsonb));
end;
$fn$;

create or replace function admin_guardar_rango(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_id  text := btrim(coalesce(payload->>'id', ''));
  v_mn  numeric := nullif(btrim(coalesce(payload->>'min_normal','')), '')::numeric;
  v_xn  numeric := nullif(btrim(coalesce(payload->>'max_normal','')), '')::numeric;
  v_mv  numeric := nullif(btrim(coalesce(payload->>'min_valido','')), '')::numeric;
  v_xv  numeric := nullif(btrim(coalesce(payload->>'max_valido','')), '')::numeric;
  v_nom text;
  v_ok  boolean;
begin
  if not es_cuenta_general() then
    raise exception 'Solo la cuenta general puede cambiar los rangos de medicion.';
  end if;
  if v_id = '' then raise exception 'Falta la pregunta.'; end if;

  -- La guarda de verdad: aunque alguien llame la accion a mano, solo
  -- puede tocar preguntas de un formulario marcado para rangos.
  select pg.pregunta, fm.controla_rangos into v_nom, v_ok
    from preguntas pg
    join formularios fm on fm.id = pg.formulario_id
   where pg.id = v_id;
  if v_nom is null then raise exception 'Esa pregunta no existe.'; end if;
  if not coalesce(v_ok, false) then
    raise exception 'Esa pregunta no se controla por rangos.';
  end if;

  if v_mn is not null and v_xn is not null and v_mn > v_xn then
    raise exception 'El minimo normal no puede ser mayor que el maximo.';
  end if;
  if v_mv is not null and v_xv is not null and v_mv > v_xv then
    raise exception 'El minimo posible no puede ser mayor que el maximo.';
  end if;
  if v_mv is not null and v_mn is not null and v_mv > v_mn then
    raise exception 'El minimo posible (%) deja por fuera el rango normal (%).', v_mv, v_mn;
  end if;
  if v_xv is not null and v_xn is not null and v_xv < v_xn then
    raise exception 'El maximo posible (%) deja por fuera el rango normal (%).', v_xv, v_xn;
  end if;

  update preguntas
     set min_normal = v_mn, max_normal = v_xn,
         min_valido = v_mv, max_valido = v_xv
   where id = v_id;

  insert into historial (tipo, cedula, detalle)
  values ('RANGOS', '',
    'Rango de "' || v_nom || '": normal ' || coalesce(v_mn::text,'-') || ' a ' || coalesce(v_xn::text,'-')
    || ', posible ' || coalesce(v_mv::text,'-') || ' a ' || coalesce(v_xv::text,'-'));

  return jsonb_build_object('ok', true, 'pregunta', v_nom);
end;
$fn$;

-- ------------------------------------------------------------
--  3) El estado tambien entrega los datos del vehiculo
--  ------------------------------------------------------------
--  La pantalla los necesita para precargarlos. Se agregan al
--  mismo sitio donde ya viajaba el VIN.
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'estado_documentos';
  if src is null then raise exception 'No existe estado_documentos'; end if;
  if position('''vehiculo''' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := regexp_replace(src,
    '(''vin'',[[:space:]]+coalesce\(c\.vin, ''''\),)',
    '\1' || nl
      || '    -- Datos del vehiculo, para poder precargarlos donde se piden.' || nl
      || '    ''vehiculo'', jsonb_build_object(' || nl
      || '      ''marca_vehiculo'',     coalesce(c.marca_vehiculo, ''''),' || nl
      || '      ''cilindraje'',         coalesce(c.cilindraje, ''''),' || nl
      || '      ''propietario_nombre'', coalesce(c.propietario_nombre, ''''),' || nl
      || '      ''propietario_cedula'', coalesce(c.propietario_cedula, ''''),' || nl
      || '      ''vin'',                coalesce(c.vin, '''')),');

  if nuevo = src then raise exception 'No encontre donde agregar el vehiculo'; end if;

  execute 'create or replace function estado_documentos(p_cedula text)'
       || ' returns jsonb language plpgsql stable security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  4) Actualizar documentos guarda tambien el vehiculo
-- ------------------------------------------------------------
create or replace function api_actualizar_documentos(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula    text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  evidencias jsonb := coalesce(payload->'evidencias', '[]'::jsonb);
  fechas     jsonb := coalesce(payload->'fechas', '{}'::jsonb);
  veh        jsonb := coalesce(payload->'vehiculo', '{}'::jsonb);
  c          colaboradores%rowtype;
  hoy        date := (now() at time zone 'America/Bogota')::date;
  d          record;
  v_url      text;
  v_fecha    text;
  v_hechos   text := '';
  n_hechos   int := 0;
  -- Vehiculo: lo que llega, ya limpio. Null = no lo mandaron.
  v_marca    text := nullif(btrim(coalesce(veh->>'marca_vehiculo','')), '');
  v_cc       text := nullif(btrim(coalesce(veh->>'cilindraje','')), '');
  v_pnom     text := nullif(btrim(coalesce(veh->>'propietario_nombre','')), '');
  v_pced     text := nullif(btrim(coalesce(veh->>'propietario_cedula','')), '');
  v_vin      text := nullif(upper(regexp_replace(coalesce(veh->>'vin',''), '[[:space:]-]', '', 'g')), '');
  faltan     text := '';
begin
  if ncedula = '' then raise exception 'Datos incompletos.'; end if;
  select * into c from colaboradores
   where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if not c.activo then raise exception 'La persona no esta activa.'; end if;

  -- ----------------------------------------------------------
  --  Datos del vehiculo
  --  --------------------------------------------------------
  --  Se piden una sola vez. Lo que ya esta guardado no se borra
  --  porque el campo llegue vacio: actualizar el SOAT no puede
  --  costarle el VIN a nadie.
  -- ----------------------------------------------------------
  if v_vin is not null and v_vin !~ '^[A-Z0-9]{17}$' then
    raise exception 'El VIN son 17 caracteres entre letras y numeros. Llegaron % (%). Buscalo en el SOAT.',
      length(v_vin), v_vin;
  end if;

  if coalesce(v_marca, nullif(btrim(coalesce(c.marca_vehiculo,'')), '')) is null then
    faltan := faltan || 'la marca del vehiculo, ';
  end if;
  if coalesce(v_cc, nullif(btrim(coalesce(c.cilindraje,'')), '')) is null then
    faltan := faltan || 'el cilindraje, ';
  end if;
  if coalesce(v_pnom, nullif(btrim(coalesce(c.propietario_nombre,'')), '')) is null then
    faltan := faltan || 'el nombre del propietario, ';
  end if;
  if coalesce(v_pced, nullif(btrim(coalesce(c.propietario_cedula,'')), '')) is null then
    faltan := faltan || 'la cedula del propietario, ';
  end if;
  if coalesce(v_vin, nullif(btrim(coalesce(c.vin,'')), '')) is null then
    faltan := faltan || 'el VIN, ';
  end if;
  if faltan <> '' then
    raise exception 'Faltan datos del vehiculo: %. Se piden una sola vez.', btrim(faltan, ', ');
  end if;

  update colaboradores
     set marca_vehiculo     = coalesce(v_marca, marca_vehiculo),
         cilindraje         = coalesce(v_cc,    cilindraje),
         propietario_nombre = coalesce(v_pnom,  propietario_nombre),
         propietario_cedula = coalesce(v_pced,  propietario_cedula),
         vin                = coalesce(v_vin,   vin),
         actualizado_en     = now()
   where regexp_replace(cedula,'\D','','g') = ncedula;

  -- ----------------------------------------------------------
  --  Documentos, uno por uno
  --  --------------------------------------------------------
  --  El que no venga se queda como estaba. Se puede actualizar
  --  uno solo sin tocar los otros dos.
  -- ----------------------------------------------------------
  for d in select * from (values
      ('SOAT',          'DOC_SOAT'),
      ('TECNOMECANICA', 'DOC_TECNOMECANICA'),
      ('LICENCIA',      'DOC_LICENCIA_TRANSITO')
    ) as t(k, preg_id) loop

    select e->>'url' into v_url
      from jsonb_array_elements(evidencias) e
     where e->>'id_pregunta' = d.preg_id limit 1;

    if coalesce(btrim(coalesce(v_url,'')), '') = '' then continue; end if;

    v_fecha := substring(btrim(coalesce(fechas->>d.k, '')) from '\d{4}-\d{2}-\d{2}');
    if v_fecha is null then
      raise exception 'Adjuntaste % pero falta su fecha de vencimiento.', d.k;
    end if;
    perform revisar_vencimiento(d.k, v_fecha::date, hoy);

    if d.k = 'SOAT' then
      update colaboradores
         set soat_url = v_url, soat_vence = v_fecha::date,
             soat_rechazado_en = null, soat_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    elsif d.k = 'TECNOMECANICA' then
      update colaboradores
         set tecnomecanica_url = v_url, tecnomecanica_vence = v_fecha::date,
             tecnomecanica_rechazado_en = null, tecnomecanica_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    else
      update colaboradores
         set licencia_url = v_url, licencia_vence = v_fecha::date,
             licencia_rechazado_en = null, licencia_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    end if;

    v_hechos := v_hechos || d.k || ' (vence ' || v_fecha || '), ';
    n_hechos := n_hechos + 1;
  end loop;

  -- Guardar solo los datos del vehiculo es valido: puede estar
  -- corrigiendo el VIN sin tener documento nuevo que subir.
  if n_hechos = 0 and v_marca is null and v_cc is null
     and v_pnom is null and v_pced is null and v_vin is null then
    raise exception 'No adjuntaste ningun documento ni cambiaste ningun dato.';
  end if;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', ncedula,
    'Actualizados por el mensajero: '
    || coalesce(nullif(btrim(v_hechos, ', '), ''), 'datos del vehiculo'));

  return jsonb_build_object(
    'actualizados', n_hechos,
    'detalle', btrim(v_hechos, ', '),
    'documentosEstado', estado_documentos(ncedula));
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Solo temperatura se controla por rangos.
select id, nombre, controla_rangos from formularios order by orden, id;

-- b) El estado ya entrega los datos del vehiculo.
select estado_documentos('1017135472')->'vehiculo' as vehiculo;

-- c) La pantalla de rangos solo muestra temperatura (y como esta
--    consulta no corre como la cuenta general, debe dar error: eso
--    tambien es la prueba de que quedo restringida).
select jsonb_array_length(admin_rangos()->'filas') as preguntas;
