-- ============================================================
--  Al renovar un documento, el anterior se borra
--  ------------------------------------------------------------
--  QUE PASABA
--  ----------
--  El bucket 'evidencias' llego a 4 961 MB con el plan en 1 GB.
--  De esos, 977 MB eran versiones viejas de SOAT, tecnomecanica y
--  licencia que nadie usa: 1 385 archivos que no estan referenciados
--  por ningun colaboradores.*_url.
--
--  La intencion de reemplazarlos estaba escrita en dos lugares y no
--  implementada en ninguno:
--
--    assets/api.js  "ruta FIJA por persona -> al renovar, el archivo
--                    nuevo reemplaza al anterior (no se acumula)"
--                   ...y la linea siguiente arma la ruta con Date.now().
--
--    db/storage.sql "El mensajero puede SOBREESCRIBIR solo los
--                    documentos del vehiculo"
--                   ...seguido de un drop policy y ningun create.
--
--  POR QUE NO SE BORRA LA FILA Y YA
--  --------------------------------
--  Borrar la fila de storage.objects NO libera el archivo: el objeto
--  queda huerfano en S3 y se sigue cobrando. Hay que llamar a la API
--  de Storage. De ahi la extension http y la llave de servicio.
--
--  POR QUE UNA COLA Y NO UN BORRADO DIRECTO
--  ----------------------------------------
--  Si el borrado fuera parte de api_actualizar_documentos y el
--  almacenamiento no respondiera, el mensajero no podria guardar su
--  documento. Se encola dentro de la transaccion (barato y seguro) y
--  se purga aparte.
--
--  POR QUE SE SIGUEN USANDO NOMBRES CON TIMESTAMP
--  ----------------------------------------------
--  Se penso en una ruta fija (documentos/<cedula>/SOAT.pdf) que se
--  sobreescriba sola, sin borrado ni llave. Se descarto por dos cosas:
--  el navegador seguiria mostrando el PDF viejo de cache, y sobre todo
--  el visto bueno se invalida cuando el valor CAMBIA — con una URL fija
--  el valor nunca cambia y una renovacion conservaria la aprobacion
--  anterior. Ver db/visto_bueno.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La llave de servicio, guardada en Vault
--  ------------------------------------------------------------
--  Se corre UNA sola vez y la corre una persona, no un script del
--  repo: la llave no puede quedar escrita aqui. Esta en
--  Supabase -> Project Settings -> API -> service_role.
--
--    select vault.create_secret('<SERVICE_ROLE_KEY>', 'service_role_key',
--           'Borrado de archivos reemplazados en el bucket evidencias');
--
--  Para verificar que quedo (sin mostrarla):
--    select name, created_at from vault.secrets where name='service_role_key';
-- ------------------------------------------------------------

create extension if not exists http with schema extensions;

-- ------------------------------------------------------------
--  2) La cola
-- ------------------------------------------------------------
create table if not exists storage_por_borrar (
  path        text primary key,
  motivo      text        not null default 'reemplazado',
  cedula      text,
  creado_en   timestamptz not null default now(),
  borrado_en  timestamptz,
  intentos    int         not null default 0,
  error       text
);

create index if not exists idx_por_borrar_pendientes
  on storage_por_borrar (creado_en) where borrado_en is null;

revoke all on storage_por_borrar from anon, authenticated;

-- De la URL guardada saca la ruta dentro del bucket.
create or replace function ruta_de_url(p_url text)
returns text language sql immutable set search_path = public as $$
  select nullif(substring(coalesce(p_url,'') from '/evidencias/(.*)$'), '');
$$;

-- ------------------------------------------------------------
--  3) El purgador
--  ------------------------------------------------------------
--  Un llamado borra hasta 100 archivos. Devuelve cuantos quedan.
--  Tres intentos fallidos y el archivo se deja quieto con su error
--  anotado, para que un problema puntual no bloquee la cola.
-- ------------------------------------------------------------
create or replace function purgar_storage(p_limite int default 100)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $fn$
declare
  v_key   text;
  v_base  text := 'https://scemoysbcgwxajgoybwc.supabase.co';
  v_paths text[];
  v_resp  extensions.http_response;
  v_ok    int := 0;
begin
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  if v_key is null then
    raise exception 'Falta la llave de servicio en Vault (nombre: service_role_key).';
  end if;

  select array_agg(path) into v_paths
    from (select path from storage_por_borrar
           where borrado_en is null and intentos < 3
           order by creado_en
           limit greatest(1, least(coalesce(p_limite,100), 100))) q;

  if v_paths is null then
    return jsonb_build_object('borrados', 0, 'pendientes', 0);
  end if;

  select * into v_resp from extensions.http((
      'DELETE',
      v_base || '/storage/v1/object/evidencias',
      array[ extensions.http_header('Authorization', 'Bearer ' || v_key),
             extensions.http_header('apikey', v_key) ],
      'application/json',
      jsonb_build_object('prefixes', to_jsonb(v_paths))::text
    )::extensions.http_request);

  if v_resp.status between 200 and 299 then
    update storage_por_borrar set borrado_en = now(), error = null
     where path = any(v_paths);
    v_ok := coalesce(array_length(v_paths,1), 0);
  else
    update storage_por_borrar
       set intentos = intentos + 1,
           error = 'HTTP ' || v_resp.status || ' ' || left(coalesce(v_resp.content,''), 300)
     where path = any(v_paths);
  end if;

  return jsonb_build_object(
    'borrados',  v_ok,
    'http',      v_resp.status,
    'detalle',   left(coalesce(v_resp.content,''), 200),
    'pendientes',(select count(*) from storage_por_borrar where borrado_en is null));
end;
$fn$;

revoke all on function purgar_storage(int) from anon, authenticated, public;

-- ------------------------------------------------------------
--  4) De ahora en adelante: al reemplazar, se encola el anterior
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(10); n int;
begin
  select prosrc into src from pg_proc where proname = 'api_actualizar_documentos';
  if src is null then raise exception 'No existe api_actualizar_documentos'; end if;
  if position('storage_por_borrar' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  nuevo := src;

  nuevo := replace(nuevo,
    '    if d.k = ''SOAT'' then' || nl || '      update colaboradores',
    '    if d.k = ''SOAT'' then' || nl
 || '      insert into storage_por_borrar(path, motivo, cedula)' || nl
 || '      select ruta_de_url(c.soat_url), ''reemplazado'', ncedula' || nl
 || '       where ruta_de_url(c.soat_url) is not null' || nl
 || '         and ruta_de_url(c.soat_url) <> coalesce(ruta_de_url(v_url), '''')' || nl
 || '      on conflict (path) do nothing;' || nl
 || '      update colaboradores');

  nuevo := replace(nuevo,
    '    elsif d.k = ''TECNOMECANICA'' then' || nl || '      update colaboradores',
    '    elsif d.k = ''TECNOMECANICA'' then' || nl
 || '      insert into storage_por_borrar(path, motivo, cedula)' || nl
 || '      select ruta_de_url(c.tecnomecanica_url), ''reemplazado'', ncedula' || nl
 || '       where ruta_de_url(c.tecnomecanica_url) is not null' || nl
 || '         and ruta_de_url(c.tecnomecanica_url) <> coalesce(ruta_de_url(v_url), '''')' || nl
 || '      on conflict (path) do nothing;' || nl
 || '      update colaboradores');

  nuevo := replace(nuevo,
    '    else' || nl || '      update colaboradores' || nl || '         set licencia_url',
    '    else' || nl
 || '      insert into storage_por_borrar(path, motivo, cedula)' || nl
 || '      select ruta_de_url(c.licencia_url), ''reemplazado'', ncedula' || nl
 || '       where ruta_de_url(c.licencia_url) is not null' || nl
 || '         and ruta_de_url(c.licencia_url) <> coalesce(ruta_de_url(v_url), '''')' || nl
 || '      on conflict (path) do nothing;' || nl
 || '      update colaboradores' || nl || '         set licencia_url');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;
  n := (length(nuevo) - length(replace(nuevo,'storage_por_borrar',''))) / length('storage_por_borrar');
  if n <> 3 then raise exception 'Esperaba 3 inserciones, quedaron %', n; end if;

  execute 'create or replace function api_actualizar_documentos(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  5) Lo ya acumulado entra a la cola
--  ------------------------------------------------------------
--  Solo lo que NO esta apuntado por ningun colaboradores.*_url: por
--  definicion, versiones superadas.
-- ------------------------------------------------------------
insert into storage_por_borrar (path, motivo, cedula, creado_en)
select o.name, 'version vieja acumulada', split_part(o.name,'/',2), o.created_at
  from storage.objects o
 where o.bucket_id = 'evidencias'
   and o.name like 'documentos/%'
   and not exists (select 1 from colaboradores c
                    where c.soat_url          like '%'||o.name
                       or c.tecnomecanica_url like '%'||o.name
                       or c.licencia_url      like '%'||o.name)
on conflict (path) do nothing;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Que quedo montado.
select (select case when prosrc like '%storage_por_borrar%' then 'si' else 'NO' end
          from pg_proc where proname='api_actualizar_documentos') as encola_al_reemplazar,
       (select count(*) from pg_proc where proname='purgar_storage')  as purgador,
       (select count(*) from vault.secrets where name='service_role_key') as llave,
       (select count(*) from storage_por_borrar where borrado_en is null) as en_cola;

-- b) Cuanto se libera.
select count(*) archivos, pg_size_pretty(sum((o.metadata->>'size')::bigint)) peso
  from storage_por_borrar b
  join storage.objects o on o.bucket_id='evidencias' and o.name = b.path
 where b.borrado_en is null;

-- c) Purgar. Repetir hasta que 'pendientes' llegue a 0.
--    select purgar_storage(100);

-- d) Si algo fallo, aqui queda dicho por que.
-- select path, intentos, error from storage_por_borrar
--  where borrado_en is null and error is not null limit 10;
