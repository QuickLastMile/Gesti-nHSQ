-- ============================================================
--  api_lineas tambien dice el rol
--  ------------------------------------------------------------
--  Ahora se entra una sola vez, por "Gestion administrativa", y el
--  acceso a la matriz y la configuracion aparece como un engranaje
--  en la barra -sin segunda contrasena- solo para quien puede
--  entrar ahi.
--
--  Para decidir si se muestra, la pantalla necesita saber el rol.
--  Se agrega al mismo llamado que ya alimenta el desplegable de
--  linea, para no hacer una consulta mas.
--
--  Ojo: esto decide lo que se VE, no lo que se PUEDE. Quien
--  manipule la pagina para mostrar el boton igual choca contra la
--  guarda de hseq_admin, que sigue exigiendo ADMIN o HSEQ.
--
--  Ejecutar DESPUES de db/lineas_4a_administracion.sql.
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
                        where r.user_id = auth.uid() and r.activo), false)
  );
$fn$;

revoke all on function api_lineas() from public, anon;
grant execute on function api_lineas() to authenticated;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion ya devuelve el rol.
select 'api_lineas' as funcion,
       case when prosrc like '%''admin''%' then 'ACTUALIZADA' else 'SIN ACTUALIZAR' end as estado
  from pg_proc where proname = 'api_lineas';

-- b) Quien vera el engranaje de configuracion (ADMIN y HSEQ).
select email, rol,
       case when rol in ('ADMIN','HSEQ') then 'SI' else 'no' end as ve_configuracion,
       case when todas_lineas then 'TODAS' else array_to_string(lineas, ', ') end as ve_lineas
  from app_roles
 where activo
 order by rol, email;
