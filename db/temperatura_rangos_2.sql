-- ============================================================
--  Rangos de medicion  (2 de 2: el formulario y Configuracion)
--  ------------------------------------------------------------
--  Requiere db/temperatura_rangos_1.sql ya corrido.
--
--  QUE HACE
--  --------
--  1. Se apaga THA_004 / THP_004, la pregunta que le pedia al
--     mensajero acordarse de si la lectura anterior tambien se
--     habia salido. El sistema ya lo sabe: lo calcula.
--  2. El aviso y la foto de la desviacion dejan de depender de esa
--     respuesta y pasan a depender de __DESVIACION__, una compuerta
--     que la pantalla evalua sola con el numero que se acaba de
--     escribir y con la lectura anterior.
--  3. api_cargar_formulario entrega los rangos de cada pregunta y
--     si la lectura anterior se habia salido.
--  4. Configuracion gana una pantalla para editar los rangos, que
--     es lo que pidio HSEQ: poder cambiar el 25 y el 65 sin
--     depender de nadie.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La pregunta de memoria sale del formulario
--  ------------------------------------------------------------
--  No se borra: se desactiva. Los registros viejos que la
--  respondieron tienen que seguir siendo legibles.
-- ------------------------------------------------------------
update preguntas set activo = false
 where id in ('THA_004', 'THP_004');

-- El aviso de que hacer y la foto ahora cuelgan de la desviacion
-- calculada, no de lo que el mensajero recuerde.
update preguntas
   set depende_de = '__DESVIACION__', depende_valor = 'SI'
 where id in ('THA_005', 'THA_006', 'THP_005', 'THP_006');

-- El texto explicaba como responder una pregunta que ya no existe.
update preguntas
   set pregunta = '¿Cuándo se considera una novedad?',
       ayuda = 'Se considera una novedad o desviación cuando la temperatura supera los 25 °C '
            || 'y/o la humedad relativa supera el 65 %, durante 24 horas seguidas.' || chr(13) || chr(10)
            || 'No tienes que calcularlo ni acordarte del registro anterior: escribe la medición '
            || 'tal como la ves y el sistema lo detecta solo. Si hay desviación te lo avisa aquí '
            || 'mismo y te pide la foto.'
 where id in ('THA_008', 'THP_008');

-- ------------------------------------------------------------
--  2) La pantalla necesita saber los rangos y la lectura anterior
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nl  text := chr(13) || chr(10);
  a   text;
begin
  select prosrc into src from pg_proc where proname = 'api_cargar_formulario';
  if src is null then raise exception 'No existe api_cargar_formulario'; end if;
  if position('max_normal' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  -- a) Los rangos viajan con cada pregunta
  a := '      ''depende_de'', depende_de, ''depende_valor'', depende_valor';
  if position(a in src) = 0 then raise exception 'No encontre el armado de preguntas'; end if;
  src := replace(src, a, a || ',' || nl
    || '      ''min_normal'', min_normal, ''max_normal'', max_normal,' || nl
    || '      ''min_valido'', min_valido, ''max_valido'', max_valido');

  -- b) Si la lectura anterior se habia salido: con eso y el numero
  --    que escriba ahora, la pantalla sabe si son 24 horas seguidas.
  a := '    ''previasFecha'', coalesce(prev->>''fecha'', ''''),';
  if position(a in src) = 0 then raise exception 'No encontre previasFecha'; end if;
  src := replace(src, a, a || nl
    || '    ''lecturaAnteriorFuera'', case when ncedula = '''' then to_jsonb(false)' || nl
    || '         else to_jsonb(lectura_anterior_fuera(ncedula, frm.grupo)) end,');

  execute 'create or replace function api_cargar_formulario(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(src);
end
$do$;

-- ------------------------------------------------------------
--  3) Configuracion: ver y editar los rangos
--  ------------------------------------------------------------
--  Solo preguntas numericas, de cualquier formulario. No es un
--  editor de preguntas completo: es justo lo que HSEQ necesita
--  cambiar, y nada mas, para que no se pueda romper otra cosa.
-- ------------------------------------------------------------
create or replace function admin_rangos(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
begin
  return jsonb_build_object('filas', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',           pg.id,
             'formulario',   fm.nombre,
             'formulario_id', pg.formulario_id,
             'pregunta',     pg.pregunta,
             'activo',       pg.activo,
             'min_normal',   pg.min_normal,
             'max_normal',   pg.max_normal,
             'min_valido',   pg.min_valido,
             'max_valido',   pg.max_valido)
           order by fm.orden, pg.orden)
      from preguntas pg
      join formularios fm on fm.id = pg.formulario_id
     where pg.tipo_respuesta = 'numero' and pg.activo and fm.activo
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
begin
  if v_id = '' then raise exception 'Falta la pregunta.'; end if;
  select pg.pregunta into v_nom from preguntas pg where pg.id = v_id;
  if v_nom is null then raise exception 'Esa pregunta no existe.'; end if;

  -- Un rango al reves no avisa de nada: marcaria todo o no marcaria nada.
  if v_mn is not null and v_xn is not null and v_mn > v_xn then
    raise exception 'El minimo normal no puede ser mayor que el maximo.';
  end if;
  if v_mv is not null and v_xv is not null and v_mv > v_xv then
    raise exception 'El minimo posible no puede ser mayor que el maximo.';
  end if;
  -- Lo posible tiene que contener a lo normal, si no hay valores que
  -- serian desviacion y a la vez no se podrian escribir.
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
--  4) El router de Administracion las conoce
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'hseq_admin';
  if src is null then raise exception 'No existe hseq_admin'; end if;
  if position('guardarRango' in src) > 0 then
    raise notice 'El router ya las conoce.';
    return;
  end if;

  -- El ancla va por expresion regular y no por texto exacto: el
  -- espaciado entre columnas del case ha cambiado entre versiones,
  -- y un ancla literal falla por un espacio de mas.
  nuevo := regexp_replace(src,
    '(when ''guardarPin''[[:space:]]+then result := admin_guardar_pin\(payload\);)',
    '\1' || nl
      || '    -- Rangos de medicion: los edita HSEQ sin tocar nada mas.' || nl
      || '    when ''rangos''                   then result := admin_rangos(payload);' || nl
      || '    when ''guardarRango''             then result := admin_guardar_rango(payload);');

  if nuevo = src then raise exception 'No encontre donde enganchar el router'; end if;

  execute 'create or replace function hseq_admin(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  5) El mensajero ve la misma alerta que ve el coordinador
--  ------------------------------------------------------------
--  api_guardar_registro arma su respuesta ANTES de que corran los
--  triggers, asi que devolvia estado OK aunque el registro quedara
--  CON_ALERTA. El mensajero guardaba una lectura de 30 grados y la
--  pantalla le decia "guardado" sin mas. Ahora el estado y las
--  alertas se releen del registro ya escrito.
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_guardar_registro';
  if src is null then raise exception 'No existe api_guardar_registro'; end if;
  if position('rr.estado' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '    ''estado'', case when alertas_doc <> '''' then ''CON_ALERTA'' else ''OK'' end,' || nl
 || '    ''alertas'', case when alertas_doc <> '''' then jsonb_build_array(alertas_doc) else ''[]''::jsonb end,',

    '    ''estado'', coalesce((select rr.estado from registros rr where rr.id = rid),' || nl
 || '                       case when alertas_doc <> '''' then ''CON_ALERTA'' else ''OK'' end),' || nl
 || '    ''alertas'', case when coalesce(btrim(coalesce(' || nl
 || '                       (select rr.alertas from registros rr where rr.id = rid), '''')), '''') <> ''''' || nl
 || '                     then jsonb_build_array((select rr.alertas from registros rr where rr.id = rid))' || nl
 || '                     else ''[]''::jsonb end,');

  if nuevo = src then raise exception 'No encontre el armado de la respuesta'; end if;

  execute 'create or replace function api_guardar_registro(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) El formulario que ve el mensajero: THA_004 ya no aparece, y
--    el aviso y la foto cuelgan de __DESVIACION__.
select id, orden, left(pregunta, 45) as pregunta, tipo_respuesta,
       depende_de, depende_valor
  from preguntas
 where formulario_id = 'TEMP_HUM_AM' and activo
 order by orden;

-- b) La carga ya entrega rangos y lectura anterior.
select case when prosrc like '%max_normal%' and prosrc like '%lecturaAnteriorFuera%'
            then 'ARREGLADA' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_cargar_formulario';

-- c) Configuracion ya tiene que mostrar estas preguntas.
select jsonb_array_length(admin_rangos()->'filas') as preguntas_numericas;

-- d) El router las conoce.
select case when prosrc like '%guardarRango%' then 'ARREGLADO' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'hseq_admin';
