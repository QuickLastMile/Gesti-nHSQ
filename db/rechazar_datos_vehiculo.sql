-- ============================================================
--  Rechazar tambien los datos escritos (VIN, marca, propietario)
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  Un documento se puede rechazar: HSEQ escribe el motivo y al
--  mensajero se lo vuelven a pedir. Los datos que el escribe a mano
--  no: si el VIN esta mal o el propietario no corresponde, no habia
--  forma de pedirle que lo corrigiera. Quedaba mal para siempre.
--
--  Ahora funcionan igual, pero campo por campo: se puede rechazar
--  solo el VIN y dejar lo demas quieto.
--
--  COMO SE PIDE DE VUELTA
--  ----------------------
--  Un campo se le vuelve a pedir cuando:
--    - lo rechazaron (con el motivo a la vista),
--    - esta vacio, o
--    - es un VIN que no tiene 17 caracteres.
--  El rechazo se levanta solo cuando manda un valor DISTINTO: si
--  reenvia el mismo, sigue pendiente.
--
--  Requiere db/actualizar_documentos_2.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Donde viven los rechazos
--  ------------------------------------------------------------
--  Un jsonb y no diez columnas: son cinco campos hoy y pueden ser
--  mas manana, y cada uno necesitaria su fecha y su motivo.
--  Forma: {"vin": {"motivo": "...", "en": "2026-09-18T..."}}
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists vehiculo_rechazos jsonb not null default '{}'::jsonb;

comment on column colaboradores.vehiculo_rechazos is
  'Datos del vehiculo devueltos al mensajero para que los corrija.';

-- ------------------------------------------------------------
--  2) Como se llama cada campo cuando hay que nombrarlo
-- ------------------------------------------------------------
create or replace function nombre_dato_vehiculo(p_campo text)
returns text language sql immutable set search_path = public as $fn$
  select case p_campo
    when 'vin'                then 'VIN'
    when 'marca_vehiculo'     then 'Marca del vehiculo'
    when 'cilindraje'         then 'Cilindraje'
    when 'propietario_nombre' then 'Nombre del propietario'
    when 'propietario_cedula' then 'Cedula del propietario'
    else p_campo end;
$fn$;

-- ------------------------------------------------------------
--  3) El estado tambien dice que datos hay que pedirle
-- ------------------------------------------------------------
create or replace function estado_documentos(p_cedula text)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  gracia int := coalesce(
    (select nullif(regexp_replace(coalesce(valor, ''), '\D', '', 'g'), '')::int
       from config where clave = 'DIAS_GRACIA_VENCIMIENTO'), 2);
  docs jsonb := '{}'::jsonb;
  d record;
  dias int; est text;
  hay_url boolean; rechazado boolean;
  exige boolean; bloquea boolean;
  n_exige int := 0; n_bloquea int := 0;
  vin_ok boolean;
  -- Datos escritos
  dat        jsonb := '{}'::jsonb;
  pendientes text[] := array[]::text[];
  rech       jsonb;
  f          record;
  v_valor    text;
  v_rech     jsonb;
  v_pide     boolean;
  v_porque   text;
  v_valido   boolean;
  ya_empezo  boolean;
begin
  select * into c from colaboradores
   where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('documentos', '{}'::jsonb,
                              'exige', false, 'bloquea', false, 'gracia', gracia,
                              'vin', '', 'vin_valido', true, 'pide_vin', false,
                              'datos', '{}'::jsonb, 'datos_pendientes', '[]'::jsonb);
  end if;

  for d in select * from (values
      ('SOAT',          c.soat_vence,          c.soat_url,          c.soat_rechazado_en,          c.soat_rechazo_motivo),
      ('TECNOMECANICA', c.tecnomecanica_vence, c.tecnomecanica_url, c.tecnomecanica_rechazado_en, c.tecnomecanica_rechazo_motivo),
      ('LICENCIA',      c.licencia_vence,      c.licencia_url,      c.licencia_rechazado_en,      c.licencia_rechazo_motivo)
    ) as t(k, ven, url, rech_en, rech_motivo) loop

    hay_url   := coalesce(btrim(coalesce(d.url, '')), '') <> '';
    rechazado := d.rech_en is not null;

    if d.ven is null then
      dias := null;
      est  := 'sin_dato';
    else
      dias := d.ven - hoy;
      est  := case when dias < 0 then 'vencido'
                   when dias <= 15 then 'por_vencer'
                   else 'ok' end;
    end if;

    exige := (not hay_url) or rechazado or est = 'vencido';
    bloquea := (not hay_url)
            or rechazado
            or (est = 'vencido' and dias < -gracia);

    if exige   then n_exige   := n_exige + 1;   end if;
    if bloquea then n_bloquea := n_bloquea + 1; end if;

    docs := docs || jsonb_build_object(d.k, jsonb_build_object(
      'fecha',     coalesce(to_char(d.ven, 'YYYY-MM-DD'), ''),
      'dias',      dias,
      'estado',    est,
      'url',       coalesce(d.url, ''),
      'rechazado', rechazado,
      'motivo',    coalesce(d.rech_motivo, ''),
      'rechazado_en', coalesce(to_char(d.rech_en at time zone 'America/Bogota', 'YYYY-MM-DD'), ''),
      'exige',     exige,
      'bloquea',   bloquea,
      'motivo_exige', case
        when rechazado      then 'rechazado'
        when not hay_url    then 'falta'
        when est = 'vencido' then 'vencido'
        else '' end
    ));
  end loop;

  vin_ok := upper(regexp_replace(coalesce(c.vin, ''), '[[:space:]-]', '', 'g'))
            ~ '^[A-Z0-9]{17}$';

  -- ----------------------------------------------------------
  --  Los datos escritos, uno por uno
  --  --------------------------------------------------------
  --  A quien no ha cargado ni un documento no se le reclama nada
  --  todavia: el bloque de primera vez se los va a pedir enteros.
  -- ----------------------------------------------------------
  rech := coalesce(c.vehiculo_rechazos, '{}'::jsonb);
  ya_empezo := coalesce(btrim(coalesce(c.soat_url, '')), '') <> ''
            or coalesce(btrim(coalesce(c.tecnomecanica_url, '')), '') <> ''
            or coalesce(btrim(coalesce(c.licencia_url, '')), '') <> '';

  for f in select * from (values
      ('vin',                c.vin),
      ('marca_vehiculo',     c.marca_vehiculo),
      ('cilindraje',         c.cilindraje),
      ('propietario_nombre', c.propietario_nombre),
      ('propietario_cedula', c.propietario_cedula)
    ) as t(campo, valor) loop

    v_valor  := coalesce(btrim(coalesce(f.valor, '')), '');
    v_rech   := rech -> f.campo;
    v_valido := case when f.campo = 'vin' then vin_ok else v_valor <> '' end;

    if v_rech is not null then
      v_pide := true;  v_porque := 'rechazado';
    elsif v_valor = '' then
      v_pide := ya_empezo;  v_porque := case when ya_empezo then 'falta' else '' end;
    elsif f.campo = 'vin' and not vin_ok then
      v_pide := true;  v_porque := 'invalido';
    else
      v_pide := false; v_porque := '';
    end if;

    if v_pide then pendientes := pendientes || f.campo; end if;

    dat := dat || jsonb_build_object(f.campo, jsonb_build_object(
      'etiqueta',  nombre_dato_vehiculo(f.campo),
      'valor',     v_valor,
      'valido',    v_valido,
      'rechazado', v_rech is not null,
      'motivo',    coalesce(v_rech->>'motivo', ''),
      'rechazado_en', coalesce(left(coalesce(v_rech->>'en', ''), 10), ''),
      'pide',      v_pide,
      'motivo_pide', v_porque));
  end loop;

  return jsonb_build_object(
    'documentos', docs,
    'exige',   n_exige   > 0,
    'bloquea', n_bloquea > 0,
    'gracia',  gracia,
    'vin',        coalesce(c.vin, ''),
    'vehiculo', jsonb_build_object(
      'marca_vehiculo',     coalesce(c.marca_vehiculo, ''),
      'cilindraje',         coalesce(c.cilindraje, ''),
      'propietario_nombre', coalesce(c.propietario_nombre, ''),
      'propietario_cedula', coalesce(c.propietario_cedula, ''),
      'vin',                coalesce(c.vin, '')),
    'vin_valido', vin_ok,
    -- Se conserva para las pantallas que todavia lo leen.
    'pide_vin',   (not vin_ok) and ya_empezo,
    -- Lo nuevo: que campos hay que pedirle y por que.
    'datos', dat,
    'datos_pendientes', to_jsonb(pendientes)
  );
end;
$fn$;

-- ------------------------------------------------------------
--  4) Guardar un dato y levantar su rechazo, en un solo sitio
--  ------------------------------------------------------------
--  Lo usan el trigger de respuestas (preoperacional) y el panel de
--  actualizar documentacion, para que la regla sea la misma por los
--  dos caminos.
-- ------------------------------------------------------------
create or replace function guardar_dato_vehiculo(p_cedula text, p_campo text, p_valor text)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare
  v_ced   text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nuevo text := btrim(coalesce(p_valor, ''));
  v_viejo text;
  v_cambio boolean;
begin
  if v_ced = '' or v_nuevo = '' then return false; end if;
  if p_campo not in ('vin','marca_vehiculo','cilindraje','propietario_nombre','propietario_cedula') then
    return false;
  end if;

  execute format('select btrim(coalesce(%I, '''')) from colaboradores
                   where regexp_replace(cedula, ''\D'', '''', ''g'') = $1', p_campo)
     into v_viejo using v_ced;

  v_cambio := coalesce(v_viejo, '') is distinct from v_nuevo;

  -- El rechazo se levanta solo si de verdad cambio: reenviar el mismo
  -- valor que le devolvieron no es corregirlo.
  execute format('update colaboradores
                     set %I = $2,
                         vehiculo_rechazos = case when $3 then vehiculo_rechazos - $4
                                                  else vehiculo_rechazos end,
                         actualizado_en = now()
                   where regexp_replace(cedula, ''\D'', '''', ''g'') = $1', p_campo)
    using v_ced, v_nuevo, v_cambio, p_campo;

  return v_cambio;
end;
$fn$;

-- El trigger del preoperacional ahora cubre los cinco campos.
create or replace function respuesta_copia_vehiculo()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_ced   text;
  v_campo text;
begin
  v_campo := case new.pregunta_id
    when 'DOC_VIN'             then 'vin'
    when 'DOC_MARCA_VEHICULO'  then 'marca_vehiculo'
    when 'DOC_CILINDRAJE'      then 'cilindraje'
    when 'DOC_PROP_NOMBRE'     then 'propietario_nombre'
    when 'DOC_PROP_CEDULA'     then 'propietario_cedula'
    else null end;
  if v_campo is null then return null; end if;
  if coalesce(btrim(coalesce(new.valor, '')), '') = '' then return null; end if;

  select regexp_replace(rg.cedula, '\D', '', 'g') into v_ced
    from registros rg where rg.id = new.registro_id;
  if v_ced is null then return null; end if;

  perform guardar_dato_vehiculo(v_ced, v_campo, new.valor);
  return null;
end;
$fn$;

-- ------------------------------------------------------------
--  5) HSEQ devuelve un dato, o se arrepiente
--  ------------------------------------------------------------
--  Mismo permiso que rechazar un documento: tambien los
--  coordinadores de linea, y solo sobre gente de su linea.
-- ------------------------------------------------------------
create or replace function admin_rechazar_dato(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_ced    text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_campo  text := btrim(coalesce(payload->>'campo',''));
  v_motivo text := btrim(coalesce(payload->>'motivo',''));
  v_linea  text := linea_efectiva(coalesce(payload->>'linea', ''));
  v_nom    text;
begin
  if v_ced = '' then raise exception 'Falta la cedula.'; end if;
  if v_campo not in ('vin','marca_vehiculo','cilindraje','propietario_nombre','propietario_cedula') then
    raise exception 'Ese dato no se puede devolver.';
  end if;
  -- El mensajero va a leer este texto: sin motivo no sabe que corregir.
  if length(v_motivo) < 5 then
    raise exception 'Escribe el motivo: el colaborador lo va a leer.';
  end if;

  select c.nombre into v_nom from colaboradores c
   where regexp_replace(c.cedula,'\D','','g') = v_ced and c.linea = v_linea;
  if v_nom is null then raise exception 'Esa persona no esta en tu linea.'; end if;

  update colaboradores
     set vehiculo_rechazos = coalesce(vehiculo_rechazos,'{}'::jsonb)
           || jsonb_build_object(v_campo, jsonb_build_object('motivo', v_motivo, 'en', now())),
         actualizado_en = now()
   where regexp_replace(cedula,'\D','','g') = v_ced;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', v_ced,
    'Devuelto para corregir: ' || nombre_dato_vehiculo(v_campo) || ' - ' || v_motivo);

  return jsonb_build_object('ok', true, 'campo', nombre_dato_vehiculo(v_campo),
                            'documentosEstado', estado_documentos(v_ced));
end;
$fn$;

create or replace function admin_levantar_rechazo_dato(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_ced   text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_campo text := btrim(coalesce(payload->>'campo',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea', ''));
  v_nom   text;
begin
  if v_ced = '' or v_campo = '' then raise exception 'Datos incompletos.'; end if;
  select c.nombre into v_nom from colaboradores c
   where regexp_replace(c.cedula,'\D','','g') = v_ced and c.linea = v_linea;
  if v_nom is null then raise exception 'Esa persona no esta en tu linea.'; end if;

  update colaboradores
     set vehiculo_rechazos = coalesce(vehiculo_rechazos,'{}'::jsonb) - v_campo,
         actualizado_en = now()
   where regexp_replace(cedula,'\D','','g') = v_ced;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', v_ced,
    'Se levanto la correccion de: ' || nombre_dato_vehiculo(v_campo));

  return jsonb_build_object('ok', true, 'documentosEstado', estado_documentos(v_ced));
end;
$fn$;

-- ------------------------------------------------------------
--  6) El router, y la pantalla de Documentos
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'hseq_admin';
  if position('rechazarDato' in src) > 0 then
    raise notice 'El router ya las conoce.'; return;
  end if;

  nuevo := replace(src,
    'if action in (''documentos'', ''rechazarDocumento'', ''levantarRechazo'') then',
    'if action in (''documentos'', ''rechazarDocumento'', ''levantarRechazo'',' || nl
 || '                ''rechazarDato'', ''levantarRechazoDato'') then');

  nuevo := regexp_replace(nuevo,
    '(when ''levantarRechazo''[[:space:]]+then result := admin_levantar_rechazo\(payload\);)',
    '\1' || nl
      || '    -- Datos escritos: se devuelven igual que un documento.' || nl
      || '    when ''rechazarDato''            then result := admin_rechazar_dato(payload);' || nl
      || '    when ''levantarRechazoDato''     then result := admin_levantar_rechazo_dato(payload);');

  if nuevo = src then raise exception 'No encontre donde enganchar el router'; end if;

  execute 'create or replace function hseq_admin(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- La pantalla necesita el estado campo por campo para pintar el boton.
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'admin_documentos';
  if position('''datos''' in src) > 0 then
    raise notice 'Ya estaba arreglada.'; return;
  end if;
  nuevo := replace(src,
    '        ''vehiculo'',   e.est->''vehiculo'',',
    '        ''vehiculo'',   e.est->''vehiculo'',' || nl
 || '        ''datos'',      e.est->''datos'',' || nl
 || '        ''datos_pendientes'', e.est->''datos_pendientes'',');
  if nuevo = src then raise exception 'No encontre donde agregar datos'; end if;
  execute 'create or replace function admin_documentos(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  7) Actualizar documentacion guarda por campo
--  ------------------------------------------------------------
--  Deja de hacer un UPDATE de los cinco a la vez y pasa por
--  guardar_dato_vehiculo, que es quien levanta el rechazo. Y exige
--  que lo devuelto llegue DISTINTO.
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(10); a text;
begin
  select prosrc into src from pg_proc where proname = 'api_actualizar_documentos';
  if position('guardar_dato_vehiculo' in src) > 0 then
    raise notice 'Ya estaba arreglada.'; return;
  end if;

  a := '  update colaboradores' || nl
    || '     set marca_vehiculo     = coalesce(v_marca, marca_vehiculo),' || nl
    || '         cilindraje         = coalesce(v_cc,    cilindraje),' || nl
    || '         propietario_nombre = coalesce(v_pnom,  propietario_nombre),' || nl
    || '         propietario_cedula = coalesce(v_pced,  propietario_cedula),' || nl
    || '         vin                = coalesce(v_vin,   vin),' || nl
    || '         actualizado_en     = now()' || nl
    || '   where regexp_replace(cedula,''\D'','''',''g'') = ncedula;';

  if position(a in src) = 0 then raise exception 'No encontre el update del vehiculo'; end if;

  nuevo := replace(src, a,
       '  faltan := '''';' || nl
    || '  declare r record;' || nl
    || '  begin' || nl
    || '    for r in select * from (values' || nl
    || '        (''vin'',                v_vin,   btrim(coalesce(c.vin, ''''))),' || nl
    || '        (''marca_vehiculo'',     v_marca, btrim(coalesce(c.marca_vehiculo, ''''))),' || nl
    || '        (''cilindraje'',         v_cc,    btrim(coalesce(c.cilindraje, ''''))),' || nl
    || '        (''propietario_nombre'', v_pnom,  btrim(coalesce(c.propietario_nombre, ''''))),' || nl
    || '        (''propietario_cedula'', v_pced,  btrim(coalesce(c.propietario_cedula, '''')))' || nl
    || '      ) as t(campo, nuevo, viejo) loop' || nl
    || '      if coalesce(c.vehiculo_rechazos, ''{}''::jsonb) ? r.campo' || nl
    || '         and (r.nuevo is null or r.nuevo = r.viejo) then' || nl
    || '        faltan := faltan || nombre_dato_vehiculo(r.campo) || '', '';' || nl
    || '      end if;' || nl
    || '    end loop;' || nl
    || '    if faltan <> '''' then' || nl
    || '      raise exception ''Te devolvieron para corregir: %. Escribe el valor correcto, no el mismo.'',' || nl
    || '        btrim(faltan, '', '');' || nl
    || '    end if;' || nl
    || '  end;' || nl
    || nl
    || '  perform guardar_dato_vehiculo(ncedula, ''marca_vehiculo'',     v_marca);' || nl
    || '  perform guardar_dato_vehiculo(ncedula, ''cilindraje'',         v_cc);' || nl
    || '  perform guardar_dato_vehiculo(ncedula, ''propietario_nombre'', v_pnom);' || nl
    || '  perform guardar_dato_vehiculo(ncedula, ''propietario_cedula'', v_pced);' || nl
    || '  perform guardar_dato_vehiculo(ncedula, ''vin'',                v_vin);');

  execute 'create or replace function api_actualizar_documentos(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las piezas estan.
select p.proname
  from pg_proc p
 where p.proname in ('nombre_dato_vehiculo','guardar_dato_vehiculo',
                     'admin_rechazar_dato','admin_levantar_rechazo_dato')
 order by p.proname;

-- b) El router las conoce y van con el permiso de rechazar documentos.
select case when prosrc like '%rechazarDato%' and prosrc like '%levantarRechazoDato%'
            then 'ARREGLADO' else 'SIN ARREGLAR' end as router
  from pg_proc where proname = 'hseq_admin';

-- c) A quien le falta o le sirve mal algun dato del vehiculo. Son los
--    que van a ver el bloque al abrir su proximo preoperacional.
select c.linea, count(*) as con_datos_pendientes
  from colaboradores c
 where c.activo
   and jsonb_array_length(estado_documentos(c.cedula)->'datos_pendientes') > 0
 group by c.linea
 order by c.linea;
