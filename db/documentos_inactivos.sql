-- ============================================================
--  Por que esa persona no tiene documentacion
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  La pantalla de Documentos solo listaba activos. Al que esta
--  inactivo por restriccion, incapacidad larga, renuncia o porque
--  salio de la matriz, simplemente no se le veia: su documentacion
--  faltante no aparecia por ningun lado, y si alguien lo buscaba
--  por cedula no entendia por que no salia.
--
--  Y hay un caso mas silencioso: 301 personas estan inactivas
--  porque su cargo NO diligencia formularios HSEQ. Esas nunca
--  debieron tener documentacion, pero su ficha vacia se lee igual
--  que un incumplimiento.
--
--  QUE HACE
--  --------
--  1. Una opcion mas en el filtro Mostrar: "Incluir inactivos".
--     No entran por defecto: son 429 y taparian a los que si hay
--     que gestionar.
--  2. Cada persona viaja con su estado (activo / si su cargo
--     aplica) y con el motivo que quedo escrito al inactivarla.
--  3. Un inactivo nunca cuenta como "pendiente": se lista para
--     consultarlo, no para perseguirlo. Y va al final de la lista.
--
--  Requiere db/documentos_2_rechazo.sql y db/documentos_con_vehiculo.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'admin_documentos';
  if src is null then raise exception 'No existe admin_documentos'; end if;
  if position('incluirInactivos' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  -- 1) La opcion nueva del filtro
  nuevo := replace(src,
    '  solo_pend   boolean := coalesce((payload->>''soloPendientes'')::boolean, true);',
    '  solo_pend   boolean := coalesce((payload->>''soloPendientes'')::boolean, true);' || nl
 || '  -- Un inactivo no tiene documentacion porque no se le esta pidiendo.' || nl
 || '  -- Sin poder verlo, su ficha vacia parece un incumplimiento.' || nl
 || '  con_inact   boolean := coalesce((payload->>''incluirInactivos'')::boolean, false);');

  -- 2) En que estado esta y por que
  nuevo := replace(nuevo,
    '        ''placa'',      coalesce(c.placa_moto, ''''),',
    '        ''placa'',      coalesce(c.placa_moto, ''''),' || nl
 || '        ''activo'',     c.activo,' || nl
 || '        ''aplica'',     cargo_aplica(c.cargo),' || nl
 || '        ''motivo_inactivo'', btrim(coalesce(' || nl
 || '           nullif(btrim(coalesce(c.observacion_coordinador, '''')), ''''),' || nl
 || '           c.observaciones_hsq, '''')),');

  -- 3) Entran solo si se piden
  nuevo := replace(nuevo,
    '    where c.activo' || nl || '      and c.linea = v_linea',
    '    where (c.activo or con_inact)' || nl || '      and c.linea = v_linea');

  -- 4) A un inactivo no se le reclama nada
  nuevo := replace(nuevo,
    '      and (not solo_pend or (e.est->>''exige'')::boolean)',
    '      and (not solo_pend or ((e.est->>''exige'')::boolean and c.activo))');

  -- 5) Y va al final de la lista
  nuevo := replace(nuevo,
    '      case when (e.est->>''bloquea'')::boolean then 0',
    '      -- Los inactivos van al final: estan para consultarlos, no para' || nl
 || '      -- gestionarlos.' || nl
 || '      case when not c.activo then 3' || nl
 || '           when (e.est->>''bloquea'')::boolean then 0');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function admin_documentos(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya trae las cinco piezas.
select case when prosrc like '%incluirInactivos%'
             and prosrc like '%motivo_inactivo%'
             and prosrc like '%c.activo or con_inact%'
             and prosrc like '%when not c.activo then 3%'
            then 'ARREGLADA' else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'admin_documentos';

-- b) Cuantos inactivos hay y por que, para saber que se va a ver.
select c.linea,
       count(*) filter (where not c.activo) as inactivos,
       count(*) filter (where not c.activo and not cargo_aplica(c.cargo)) as cargo_no_aplica,
       count(*) filter (where not c.activo
                          and coalesce(btrim(coalesce(c.observacion_coordinador, c.observaciones_hsq, '')), '') = '')
         as sin_motivo_escrito
  from colaboradores c
 group by c.linea
 order by c.linea;

-- c) Los motivos mas frecuentes, tal como los va a leer HSEQ.
select upper(btrim(coalesce(nullif(btrim(coalesce(observacion_coordinador,'')),''),
                            observaciones_hsq, '(sin motivo)'))) as motivo,
       count(*) as personas
  from colaboradores where not activo
 group by 1 order by personas desc limit 10;
