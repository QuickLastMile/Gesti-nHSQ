-- ============================================================
--  Visto bueno: "esto ya lo revise y esta bien"
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  Se podia rechazar un documento o un dato, pero no aprobarlo. Y
--  sin lo contrario, "no rechazado" es ambiguo: puede querer decir
--  que HSEQ lo reviso y estaba correcto, o que nadie lo ha abierto
--  nunca. Las dos cosas se ven igual en pantalla.
--
--  El visto bueno separa esas dos situaciones y, sobre todo, crea
--  una cola de trabajo real: "lo que esta cargado, en orden, y
--  todavia sin mirar".
--
--  LA REGLA QUE LO HACE SERVIR PARA ALGO
--  -------------------------------------
--  El visto bueno se cae solo cuando el valor cambia:
--    - un documento nuevo no hereda la aprobacion del anterior,
--    - un dato corregido vuelve a quedar sin revisar.
--  Sin eso, aprobar una vez valdria para siempre y el sello dejaria
--  de significar nada.
--
--  Y no se puede aprobar lo que esta pendiente o rechazado: seria
--  avalar justo lo que el sistema le esta reclamando.
--
--  Requiere db/rechazar_datos_vehiculo.sql y db/documentos_inactivos.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Donde vive el visto bueno
--  ------------------------------------------------------------
--  Un solo jsonb para documentos y datos: la clave es SOAT,
--  TECNOMECANICA, LICENCIA, vin, marca_vehiculo, etc.
--  Forma: {"SOAT": {"en": "...", "por": "hseq@..."}}
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists revisiones jsonb not null default '{}'::jsonb;

comment on column colaboradores.revisiones is
  'Visto bueno de HSEQ por documento o por dato. Se cae solo si el valor cambia.';

create or replace function quien_revisa()
returns text language sql stable set search_path = public as $fn$
  select coalesce(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''),
                  auth.uid()::text, 'desconocido');
$fn$;

-- ------------------------------------------------------------
--  2) Aprobar, y arrepentirse
-- ------------------------------------------------------------
create or replace function admin_aprobar(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_ced   text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_clave text := btrim(coalesce(payload->>'clave',''));
  v_todo  boolean := coalesce((payload->>'todo')::boolean, false);
  v_linea text := linea_efectiva(coalesce(payload->>'linea', ''));
  v_nom   text;
  v_est   jsonb;
  v_nuevo jsonb := '{}'::jsonb;
  k       text;
begin
  if v_ced = '' then raise exception 'Falta la cedula.'; end if;
  select c.nombre into v_nom from colaboradores c
   where regexp_replace(c.cedula,'\D','','g') = v_ced and c.linea = v_linea;
  if v_nom is null then raise exception 'Esa persona no esta en tu linea.'; end if;

  v_est := estado_documentos(v_ced);

  if v_todo then
    for k in select key from jsonb_each(v_est->'documentos')
              where not coalesce((value->>'exige')::boolean, false) loop
      v_nuevo := v_nuevo || jsonb_build_object(k, jsonb_build_object('en', now(), 'por', quien_revisa()));
    end loop;
    for k in select key from jsonb_each(v_est->'datos')
              where not coalesce((value->>'pide')::boolean, false)
                and coalesce(btrim(coalesce(value->>'valor','')), '') <> '' loop
      v_nuevo := v_nuevo || jsonb_build_object(k, jsonb_build_object('en', now(), 'por', quien_revisa()));
    end loop;
    if v_nuevo = '{}'::jsonb then
      raise exception 'No hay nada que aprobar: todo lo que tiene esta pendiente o rechazado.';
    end if;
  else
    if v_clave = '' then raise exception 'Falta que aprobar.'; end if;
    if coalesce((v_est->'documentos'->v_clave->>'exige')::boolean, false)
       or coalesce((v_est->'datos'->v_clave->>'pide')::boolean, false) then
      raise exception 'Eso esta pendiente: no se puede aprobar hasta que lo actualice.';
    end if;
    v_nuevo := jsonb_build_object(v_clave, jsonb_build_object('en', now(), 'por', quien_revisa()));
  end if;

  update colaboradores
     set revisiones = coalesce(revisiones,'{}'::jsonb) || v_nuevo,
         actualizado_en = now()
   where regexp_replace(cedula,'\D','','g') = v_ced;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', v_ced,
    'Revisado y aprobado: ' || (select string_agg(key, ', ') from jsonb_each(v_nuevo)));

  return jsonb_build_object('ok', true, 'documentosEstado', estado_documentos(v_ced));
end;
$fn$;

create or replace function admin_quitar_aprobacion(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_ced   text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_clave text := btrim(coalesce(payload->>'clave',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea', ''));
  v_nom   text;
begin
  if v_ced = '' or v_clave = '' then raise exception 'Datos incompletos.'; end if;
  select c.nombre into v_nom from colaboradores c
   where regexp_replace(c.cedula,'\D','','g') = v_ced and c.linea = v_linea;
  if v_nom is null then raise exception 'Esa persona no esta en tu linea.'; end if;

  update colaboradores
     set revisiones = coalesce(revisiones,'{}'::jsonb) - v_clave,
         actualizado_en = now()
   where regexp_replace(cedula,'\D','','g') = v_ced;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', v_ced, 'Se quito el visto bueno de: ' || v_clave);

  return jsonb_build_object('ok', true, 'documentosEstado', estado_documentos(v_ced));
end;
$fn$;

-- ------------------------------------------------------------
--  3) El estado lo entrega, y cuenta lo que falta por mirar
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(10);
begin
  select prosrc into src from pg_proc where proname = 'estado_documentos';
  if position('revisado' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := replace(src, '  ya_empezo  boolean;',
    '  ya_empezo  boolean;' || nl || '  rev        jsonb;' || nl
 || '  v_rev      jsonb;' || nl || '  n_sin_rev  int := 0;');

  nuevo := replace(nuevo,
    '  for d in select * from (values' || nl || '      (''SOAT'',',
    '  -- Que no este rechazado no quiere decir que alguien lo haya mirado.' || nl
 || '  rev := coalesce(c.revisiones, ''{}''::jsonb);' || nl || nl
 || '  for d in select * from (values' || nl || '      (''SOAT'',');

  nuevo := replace(nuevo, '      ''exige'', exige, ''bloquea'', bloquea,',
    '      ''exige'', exige, ''bloquea'', bloquea,' || nl
 || '      ''revisado'',    (rev ? d.k),' || nl
 || '      ''revisado_en'', coalesce(left(coalesce(rev->d.k->>''en'', ''''), 10), ''''),' || nl
 || '      ''revisado_por'', coalesce(rev->d.k->>''por'', ''''),');

  nuevo := replace(nuevo, '    if exige   then n_exige   := n_exige + 1;   end if;',
    '    if exige   then n_exige   := n_exige + 1;   end if;' || nl
 || '    if not exige and not (rev ? d.k) then n_sin_rev := n_sin_rev + 1; end if;');

  nuevo := replace(nuevo, '      ''pide'',      v_pide, ''motivo_pide'', v_porque));',
    '      ''pide'',      v_pide, ''motivo_pide'', v_porque,' || nl
 || '      ''revisado'',    (rev ? f.campo),' || nl
 || '      ''revisado_en'', coalesce(left(coalesce(rev->f.campo->>''en'', ''''), 10), ''''),' || nl
 || '      ''revisado_por'', coalesce(rev->f.campo->>''por'', '''')));');

  nuevo := replace(nuevo, '    if v_pide then pendientes := pendientes || f.campo; end if;',
    '    if v_pide then pendientes := pendientes || f.campo; end if;' || nl
 || '    if not v_pide and v_valor <> '''' and not (rev ? f.campo) then' || nl
 || '      n_sin_rev := n_sin_rev + 1;' || nl || '    end if;');

  nuevo := replace(nuevo, '    ''datos_pendientes'', to_jsonb(pendientes));',
    '    ''datos_pendientes'', to_jsonb(pendientes),' || nl
 || '    -- Cuantas cosas estan bien pero nadie las ha mirado todavia.' || nl
 || '    ''sin_revisar'', n_sin_rev);');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;
  execute 'create or replace function estado_documentos(p_cedula text)'
       || ' returns jsonb language plpgsql stable security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  4) El visto bueno se cae cuando el valor cambia
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

  execute format('update colaboradores
                     set %I = $2,
                         vehiculo_rechazos = case when $3 then vehiculo_rechazos - $4
                                                  else vehiculo_rechazos end,
                         revisiones        = case when $3 then coalesce(revisiones, ''{}''::jsonb) - $4
                                                  else revisiones end,
                         actualizado_en = now()
                   where regexp_replace(cedula, ''\D'', '''', ''g'') = $1', p_campo)
    using v_ced, v_nuevo, v_cambio, p_campo;

  return v_cambio;
end;
$fn$;

-- Un documento nuevo no hereda la aprobacion del anterior.
do $do$
declare src text; nuevo text;
begin
  select prosrc into src from pg_proc where proname = 'api_actualizar_documentos';
  if position('revisiones' in src) > 0 then
    raise notice 'Ya estaba arreglada (panel).'; return;
  end if;
  nuevo := src;
  nuevo := replace(nuevo, 'set soat_url = v_url, soat_vence = v_fecha::date,',
    'set soat_url = v_url, soat_vence = v_fecha::date,
             revisiones = coalesce(revisiones, ''{}''::jsonb) - ''SOAT'',');
  nuevo := replace(nuevo, 'set tecnomecanica_url = v_url, tecnomecanica_vence = v_fecha::date,',
    'set tecnomecanica_url = v_url, tecnomecanica_vence = v_fecha::date,
             revisiones = coalesce(revisiones, ''{}''::jsonb) - ''TECNOMECANICA'',');
  nuevo := replace(nuevo, 'set licencia_url = v_url, licencia_vence = v_fecha::date,',
    'set licencia_url = v_url, licencia_vence = v_fecha::date,
             revisiones = coalesce(revisiones, ''{}''::jsonb) - ''LICENCIA'',');
  if nuevo = src then raise exception 'No encontre los updates'; end if;
  execute 'create or replace function api_actualizar_documentos(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_guardar_registro';
  if position('revisiones' in src) > 0 then
    raise notice 'Ya estaba arreglada (preoperacional).'; return;
  end if;
  nuevo := replace(src,
    '    actualizado_en = now()' || nl || '  where regexp_replace(cedula,''\D'','''',''g'') = ncedula;',
    '    -- Un documento nuevo llega sin revisar, aunque el anterior lo' || nl
 || '    -- estuviera: lo que aprobo HSEQ ya no es el archivo que hay.' || nl
 || '    revisiones = coalesce(revisiones, ''{}''::jsonb)' || nl
 || '      - case when coalesce(btrim(coalesce(v_soat_u,'''')),'''')  <> '''' then ''SOAT'' else '''' end' || nl
 || '      - case when coalesce(btrim(coalesce(v_tecno_u,'''')),'''') <> '''' then ''TECNOMECANICA'' else '''' end' || nl
 || '      - case when coalesce(btrim(coalesce(v_lic_u,'''')),'''')   <> '''' then ''LICENCIA'' else '''' end,' || nl
 || '    actualizado_en = now()' || nl || '  where regexp_replace(cedula,''\D'','''',''g'') = ncedula;');
  if nuevo = src then raise exception 'No encontre el update de la matriz'; end if;
  execute 'create or replace function api_guardar_registro(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  5) El router y el filtro "solo sin revisar"
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'hseq_admin';
  if position('aprobarDato' in src) > 0 then
    raise notice 'El router ya las conoce.'; return;
  end if;
  nuevo := replace(src,
    '''rechazarDato'', ''levantarRechazoDato'') then',
    '''rechazarDato'', ''levantarRechazoDato'',' || nl
 || '                ''aprobarDato'', ''quitarAprobacion'') then');
  nuevo := regexp_replace(nuevo,
    '(when ''levantarRechazoDato''[[:space:]]+then result := admin_levantar_rechazo_dato\(payload\);)',
    '\1' || nl
      || '    -- Visto bueno: "esto ya lo revise y esta bien".' || nl
      || '    when ''aprobarDato''             then result := admin_aprobar(payload);' || nl
      || '    when ''quitarAprobacion''        then result := admin_quitar_aprobacion(payload);');
  if nuevo = src then raise exception 'No encontre donde enganchar'; end if;
  execute 'create or replace function hseq_admin(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'admin_documentos';
  if position('soloSinRevisar' in src) > 0 then
    raise notice 'Ya estaba arreglada.'; return;
  end if;
  nuevo := replace(src,
    '  con_inact   boolean := coalesce((payload->>''incluirInactivos'')::boolean, false);',
    '  con_inact   boolean := coalesce((payload->>''incluirInactivos'')::boolean, false);' || nl
 || '  -- Lo que esta cargado y en orden, pero que nadie ha mirado todavia.' || nl
 || '  sin_rev     boolean := coalesce((payload->>''soloSinRevisar'')::boolean, false);');
  nuevo := replace(nuevo,
    '        ''justificacion'', case when ju.tipo is null then null else',
    '        ''sin_revisar'', (e.est->>''sin_revisar'')::int,' || nl
 || '        ''justificacion'', case when ju.tipo is null then null else');
  nuevo := replace(nuevo,
    '      and (not solo_pend or ((e.est->>''exige'')::boolean and c.activo))',
    '      and (not solo_pend or ((e.est->>''exige'')::boolean and c.activo))' || nl
 || '      and (not sin_rev or ((e.est->>''sin_revisar'')::int > 0 and c.activo))');
  if nuevo = src then raise exception 'No encontre donde tocar'; end if;
  execute 'create or replace function admin_documentos(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Todas las piezas.
select (select case when prosrc like '%revisado%' then 'si' else 'NO' end from pg_proc where proname='estado_documentos') as estado,
       (select case when prosrc like '%revisiones%' then 'si' else 'NO' end from pg_proc where proname='guardar_dato_vehiculo') as dato,
       (select case when prosrc like '%revisiones%' then 'si' else 'NO' end from pg_proc where proname='api_actualizar_documentos') as panel,
       (select case when prosrc like '%revisiones%' then 'si' else 'NO' end from pg_proc where proname='api_guardar_registro') as preoperacional,
       (select case when prosrc like '%aprobarDato%' then 'si' else 'NO' end from pg_proc where proname='hseq_admin') as router,
       (select case when prosrc like '%soloSinRevisar%' then 'si' else 'NO' end from pg_proc where proname='admin_documentos') as filtro;

-- b) Cuanto hay por revisar hoy. Al principio es todo: nadie ha
--    aprobado nada todavia.
select c.linea,
       count(*) filter (where c.activo) as activos,
       sum((estado_documentos(c.cedula)->>'sin_revisar')::int)
         filter (where c.activo) as cosas_sin_revisar
  from colaboradores c
 group by c.linea
 order by c.linea;
