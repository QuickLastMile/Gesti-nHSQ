-- ============================================================
--  Usuarios y alcance por linea
--  ------------------------------------------------------------
--  quick.helpai2026        -> administradora global: TODAS las
--                             lineas, con desplegable para moverse.
--  gestionadmin.lastmile   -> jefes, lideres y coordinadores de
--                             Last Mile. Solo su linea.
--  gestionadmin.werehouse  -> lo mismo para Warehouse.
--
--  POR QUE COORDINADOR Y NO HSEQ EN LOS DE LINEA
--  El rol COORDINADOR llega a Cumplimiento y Dashboard, que ya
--  filtran por linea. HSEQ ademas entra a Administracion, que
--  TODAVIA NO filtra: le mostraria la matriz completa de la otra
--  linea. Cuando salga la etapa 4 se suben a HSEQ y ahi si cargan
--  su propia malla; mientras tanto la carga la administradora
--  global cambiando el desplegable.
--
--  Se puede volver a correr: actualiza en vez de duplicar.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

insert into app_roles (user_id, email, rol, activo, todas_lineas, lineas)
select u.id, u.email, v.rol, true, v.todas, v.lineas
  from (values
    ('quick.helpai2026@gmail.com',       'ADMIN',       true,  '{}'::text[]),
    ('gestionadmin.lastmile@gmail.com',  'COORDINADOR', false, array['LAST_MILE']),
    ('gestionadmin.werehouse@gmail.com', 'COORDINADOR', false, array['WAREHOUSE'])
  ) as v(correo, rol, todas, lineas)
  join auth.users u on lower(btrim(u.email)) = v.correo
on conflict (user_id) do update
  set email        = excluded.email,
      rol          = excluded.rol,
      activo       = true,
      todas_lineas = excluded.todas_lineas,
      lineas       = excluded.lineas;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Quien es quien. Si a alguno le falta el rol, es que el correo
--    no coincide exactamente con el de Authentication.
--    'correo_confirmado' en false = no puede iniciar sesion.
select u.email,
       u.email_confirmed_at is not null as correo_confirmado,
       r.rol,
       case when r.todas_lineas then 'TODAS' else array_to_string(r.lineas, ', ') end as ve,
       case when r.rol in ('ADMIN','HSEQ') then 'Administracion + Cumplimiento + Dashboard'
            when r.rol = 'COORDINADOR'     then 'Cumplimiento + Dashboard'
            else 'nada' end as pantallas,
       r.activo
  from auth.users u
  left join app_roles r on r.user_id = u.id
 where u.email is not null
 order by r.todas_lineas desc nulls last, u.email;

-- b) Los routers deben exigir rol. Si alguno dice SIN GUARDA, hay que
--    correr db/URGENTE_permisos_routers.sql: sin eso, hseq_api esta
--    concedido a anon y cualquiera con la llave publica lo llama.
select 'hseq_api' as router,
       case when prosrc like '%hseq_tiene_rol%' then 'CON GUARDA'
            else 'SIN GUARDA -> correr URGENTE_permisos_routers.sql' end as estado
  from pg_proc where proname = 'hseq_api'
union all
select 'hseq_admin',
       case when prosrc like '%hseq_tiene_rol%' then 'CON GUARDA'
            else 'SIN GUARDA -> correr URGENTE_permisos_routers.sql' end
  from pg_proc where proname = 'hseq_admin';
