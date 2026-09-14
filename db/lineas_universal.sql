-- ============================================================
--  api_lineas tambien dice si la cuenta es universal
--  ------------------------------------------------------------
--  El dashboard muestra distinto segun el tipo de cuenta:
--
--    cuenta general (universal)  -> el tablero completo
--    cuenta de una linea         -> resumen, seguimiento y documentos
--
--  Hasta ahora la pantalla lo deducia de 'puede_cambiar', que es cierto
--  hoy -solo la cuenta universal tiene mas de una linea- pero deja de
--  serlo el dia que a una cuenta de linea se le asignen dos lineas, o
--  el dia que la universal quede con una sola linea activa. Mejor que
--  la base diga el dato en vez de que la pantalla lo adivine.
--
--  La firma no cambia (sigue sin parametros), asi que 'create or
--  replace' reemplaza de verdad y no deja una segunda funcion.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function api_lineas()
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'nombre', l.nombre) order by l.orden, l.id)
        from lineas l
       where l.activo and l.id = any(lineas_permitidas())), '[]'::jsonb),
    'actual', coalesce((select (lineas_permitidas())[1]), ''),
    -- Con una sola linea no hay nada que escoger: la pantalla muestra
    -- el nombre en vez del desplegable.
    'puede_cambiar', coalesce(array_length(lineas_permitidas(),1),0) > 1,
    'rol', coalesce((select r.rol from app_roles r
                      where r.user_id = auth.uid() and r.activo), ''),
    -- Quien entra a la matriz y la configuracion.
    'admin', coalesce((select r.rol in ('ADMIN','HSEQ') from app_roles r
                        where r.user_id = auth.uid() and r.activo), false),
    -- Cuenta general: no esta amarrada a una linea, las ve todas.
    'universal', coalesce((select r.todas_lineas from app_roles r
                            where r.user_id = auth.uid() and r.activo), false)
  );
$fn$;

revoke all on function api_lineas() from public, anon;
grant execute on function api_lineas() to authenticated;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Una sola firma, como debe ser.
select p.oid::regprocedure as firma
  from pg_proc p where p.proname = 'api_lineas';

-- b) Quien queda como cuenta general y quien como cuenta de linea.
--    'todas_lineas' en true = tablero completo y Excel/PDF.
select email, rol, todas_lineas as cuenta_general, lineas, activo
  from app_roles
 order by todas_lineas desc, email;
