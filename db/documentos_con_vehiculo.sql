-- ============================================================
--  Documentos: revisar tambien lo que el mensajero escribio
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  En Configuracion -> Documentos, HSEQ revisa el archivo que
--  adjunto el mensajero, pero no los datos que escribio a mano
--  (VIN, marca, cilindraje, propietario). Esos son justamente los
--  que se equivocan: un VIN de 6 digitos, un cilindraje en blanco,
--  el propietario sin cedula. Para verlos habia que bajar el
--  exportable, asi que en la practica nadie los revisaba.
--
--  Ahora viajan con cada persona y la pantalla los muestra al
--  abrir su ficha, marcando en rojo lo que falta o esta mal.
--
--  Requiere db/documentos_2_rechazo.sql y db/actualizar_documentos_2.sql
--  (que es el que agrego 'vehiculo' a estado_documentos).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'admin_documentos';
  if src is null then raise exception 'No existe admin_documentos'; end if;
  if position('''vehiculo''' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '        ''documentos'', e.est->''documentos''',
    '        ''documentos'', e.est->''documentos'',' || nl
 || '        ''vehiculo'',   e.est->''vehiculo'',' || nl
 || '        ''vin_valido'', (e.est->>''vin_valido'')::boolean');

  if nuevo = src then raise exception 'No encontre donde agregar el vehiculo'; end if;

  execute 'create or replace function admin_documentos(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya los entrega.
select case when prosrc like '%''vehiculo''%' and prosrc like '%vin_valido%'
            then 'ARREGLADA' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'admin_documentos';

-- b) Cuanta gente activa tiene algun dato del vehiculo mal o en blanco.
--    Son los que HSEQ va a ver marcados en rojo al abrir su ficha.
select c.linea,
       count(*) filter (where upper(regexp_replace(coalesce(c.vin,''), '[[:space:]-]', '', 'g'))
                              !~ '^[A-Z0-9]{17}$')                       as vin_mal,
       count(*) filter (where coalesce(btrim(coalesce(c.cilindraje,'')),'') = '')         as sin_cilindraje,
       count(*) filter (where coalesce(btrim(coalesce(c.propietario_cedula,'')),'') = '') as sin_cc_propietario
  from colaboradores c
 where c.activo
 group by c.linea
 order by c.linea;
