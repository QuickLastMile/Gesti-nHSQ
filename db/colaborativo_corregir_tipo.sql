-- ============================================================
--  Colaborativo: corregir mensajero / conductor sin volver a cargar
--  ------------------------------------------------------------
--  QUE PASO
--  --------
--  Un archivo de LTSA entro con 134 personas y quedaron 133 como
--  mensajero y 1 como conductor, cuando el Excel si distinguia los
--  dos. El motor de exigibilidad solo entiende 'QUICKER - MENSAJERO'
--  y 'QUICKER - CONDUCTOR' (config CARGOS_EXIGIBLES), asi que
--  api_colaborativos_guardar traduce lo que venga en la columna
--  Cargo con:
--
--      cargo_txt ~* 'conductor|vehiculo|veh[ií]culo'
--
--  Esa expresion NO distingue mayusculas: 'Conductor', 'CONDUCTOR' y
--  'conductor' entran igual. Y como una fila si quedo bien, la
--  columna Cargo existia y se leyo. Lo que quedo mal fue el contenido
--  de las otras filas, que no se guarda en ningun lado: no hay forma
--  de reconstruirlo desde la base.
--
--  De ahi que la solucion no sea adivinar, sino poder corregirlo.
--
--  QUE SE AGREGA
--  -------------
--   1. api_colaborativos_tipo: cambia el tipo de una lista de cedulas.
--      Toca SOLO es_colaborativo = true, asi que no puede rozar la
--      matriz real ni por error ni a proposito.
--   2. api_colaborativos_guardar ahora devuelve cuantos quedaron de
--      cada tipo y si el archivo traia columna Cargo. Sin eso, un
--      archivo mal armado pasaba desapercibido hasta que un conductor
--      terminaba llenando el formato de moto.
--
--  NOTA: volver a subir el archivo tampoco duplica ni borra a nadie
--  -actualiza por cedula-, pero requiere tener el archivo corregido a
--  la mano. Esto sirve cuando no se tiene.
--
--  Supabase -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Cambiar el tipo de una lista de cedulas
-- ------------------------------------------------------------
create or replace function api_colaborativos_tipo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  tipo    text := upper(btrim(coalesce(payload->>'tipo','')));
  proy    text := btrim(coalesce(payload->>'proyecto',''));
  ceds    text[];
  v_cargo text;
  n int;
begin
  if tipo not in ('MOTO','VEHICULO') then
    raise exception 'Tipo invalido: usa MOTO o VEHICULO.';
  end if;
  v_cargo := case when tipo = 'VEHICULO' then 'QUICKER - CONDUCTOR'
                  else 'QUICKER - MENSAJERO' end;

  select array_agg(distinct regexp_replace(x,'\D','','g'))
    into ceds
    from jsonb_array_elements_text(coalesce(payload->'cedulas','[]'::jsonb)) x
   where regexp_replace(x,'\D','','g') <> '';

  if ceds is null or coalesce(array_length(ceds,1),0) = 0 then
    raise exception 'No llego ninguna cedula.';
  end if;

  update colaboradores
     set cargo = v_cargo, tipo_vehiculo = tipo, actualizado_en = now()
   where es_colaborativo and linea = v_linea
     and regexp_replace(cedula,'\D','','g') = any(ceds)
     and (proy = '' or proyecto = proy);
  get diagnostics n = row_count;

  return jsonb_build_object(
    'cambiados', n,
    'pedidos', array_length(ceds,1),
    'sin_encontrar', array_length(ceds,1) - n);
end;
$fn$;

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'hseq_admin';
  if src is null then raise exception 'No existe hseq_admin'; end if;
  if position('colaborativosTipo' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;
  nuevo := replace(src,
    '    when ''colaborativosEliminar'' then result := api_colaborativos_eliminar(payload);',
    '    when ''colaborativosEliminar'' then result := api_colaborativos_eliminar(payload);' || nl
 || '    when ''colaborativosTipo''     then result := api_colaborativos_tipo(payload);');
  if nuevo = src then raise exception 'No encontre donde insertar'; end if;
  execute 'create or replace function hseq_admin(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  2) El cargue dice cuantos quedaron de cada tipo
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_colaborativos_guardar';
  if src is null then raise exception 'No existe api_colaborativos_guardar'; end if;
  if position('c_cond' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '  c_nuevos int := 0; c_act int := 0; c_saltados int := 0;',
    '  c_nuevos int := 0; c_act int := 0; c_saltados int := 0;' || nl
 || '  c_cond int := 0; c_mens int := 0;');

  nuevo := replace(nuevo,
    '                     then ''QUICKER - CONDUCTOR'' else ''QUICKER - MENSAJERO'' end;',
    '                     then ''QUICKER - CONDUCTOR'' else ''QUICKER - MENSAJERO'' end;' || nl
 || '    if cargo_v = ''QUICKER - CONDUCTOR'' then c_cond := c_cond + 1;' || nl
 || '    else c_mens := c_mens + 1; end if;');

  nuevo := replace(nuevo,
    'return jsonb_build_object(''nuevos'', c_nuevos, ''actualizados'', c_act, ''saltados'', c_saltados);',
    'return jsonb_build_object(''nuevos'', c_nuevos, ''actualizados'', c_act, ''saltados'', c_saltados,' || nl
 || '    ''conductores'', c_cond, ''mensajeros'', c_mens,' || nl
 || '    ''hay_columna_cargo'', (idx ? ''Cargo''));');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function api_colaborativos_guardar(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las tres piezas.
select (select count(*) from pg_proc where proname='api_colaborativos_tipo') as funcion,
       (select case when prosrc like '%colaborativosTipo%' then 'si' else 'NO' end
          from pg_proc where proname='hseq_admin') as en_el_router,
       (select case when prosrc like '%c_cond%' then 'si' else 'NO' end
          from pg_proc where proname='api_colaborativos_guardar') as cargue_cuenta_tipos;

-- b) Como esta repartido hoy el personal colaborativo.
select proyecto,
       count(*) personas,
       count(*) filter (where cargo = 'QUICKER - CONDUCTOR') conductores,
       count(*) filter (where cargo = 'QUICKER - MENSAJERO') mensajeros
  from colaboradores where es_colaborativo
 group by 1 order by 2 desc;

-- c) Ensayo en seco: de una lista de cedulas, a cuantas llegaria el cambio.
--    Las que no son colaborativas quedan fuera por construccion.
-- with pedido as (select array['1023370294','79817266'] ceds)
-- select count(*) alcanzadas from colaboradores c, pedido p
--  where c.es_colaborativo and c.linea = 'LAST_MILE'
--    and regexp_replace(c.cedula,'\D','','g') = any(p.ceds);
