-- ============================================================
--  La pantalla del mensajero dice si es personal colaborativo
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  El colaborativo no esta vinculado en Quick ni aparece en la
--  matriz real: lo carga el coordinador aparte. Registra igual que
--  los demas, pero su ficha se veia identica a la de alguien de
--  nomina, y quien mira la pantalla no tenia como distinguirlo.
--
--  QUE HACE
--  --------
--  api_buscar_activo agrega 'es_colaborativo' dentro de 'datos'.
--  Con eso mensajero.html pinta la ficha en ambar en vez de verde y
--  la insignia dice "Habilitado - Colaborativo".
--
--  Requiere db/personal_colaborativo.sql (de ahi sale la columna).
--
--  Supabase -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_buscar_activo';
  if src is null then raise exception 'No existe api_buscar_activo'; end if;
  if position('es_colaborativo' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '      ''tipo_vehiculo'', coalesce(c.tipo_vehiculo,'''')' || nl || '    ),',
    '      ''tipo_vehiculo'', coalesce(c.tipo_vehiculo,''''),' || nl
 || '      ''es_colaborativo'', coalesce(c.es_colaborativo, false)' || nl || '    ),');

  if nuevo = src then raise exception 'No encontre donde insertar'; end if;

  execute 'create or replace function api_buscar_activo(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya lo entrega.
select case when prosrc like '%es_colaborativo%' then 'ARREGLADA' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_buscar_activo';

-- b) Contra gente real: los colaborativos deben responder true.
select c.cedula, c.proyecto, c.ciudad,
       (api_buscar_activo(jsonb_build_object('cedula', c.cedula))->'datos'->>'es_colaborativo') as lo_dice
  from colaboradores c
 where c.es_colaborativo and c.activo
 limit 5;

-- c) Cuanta gente es colaborativa y como se reparte. Si las ciudades son
--    muchas mas que los proyectos, el filtro util en Configuracion es el
--    de ciudad, no el de proyecto.
select count(*) as personas,
       count(distinct proyecto) as proyectos,
       count(distinct nullif(btrim(coalesce(ciudad,'')),'')) as ciudades
  from colaboradores where es_colaborativo;
