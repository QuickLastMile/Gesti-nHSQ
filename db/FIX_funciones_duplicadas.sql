-- ============================================================
--  FIX - Funciones duplicadas por el parametro opcional
--  ------------------------------------------------------------
--  SINTOMA: "function api_get_bootstrap() is not unique" al abrir
--  el dashboard o cumplimiento.
--
--  CAUSA: a varias funciones que no recibian nada se les agrego
--  'payload jsonb default ...' para poder mandarles la linea.
--  'create or replace' NO reemplaza una firma por otra: crea una
--  segunda funcion. Quedaron las dos, ambas llamables sin
--  argumentos, y Postgres no puede elegir.
--
--  Se borra la version vieja. La nueva queda sola y el router la
--  encuentra sin ambiguedad.
--
--  Correr una sola vez, despues de db/temperatura_y_filtros.sql.
--  Los scripts de origen ya traen estos drop, asi que volver a
--  correrlos no reproduce el problema.
-- ============================================================

drop function if exists api_get_bootstrap();
drop function if exists api_lista_encargados();
drop function if exists admin_proyectos();
drop function if exists admin_calendario();
drop function if exists admin_encargados();
drop function if exists admin_formularios_proyecto();

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- Cada nombre debe aparecer UNA sola vez, con su parametro.
select p.oid::regprocedure as firma
  from pg_proc p
 where p.proname in ('api_get_bootstrap','api_lista_encargados','admin_proyectos',
                     'admin_calendario','admin_encargados','admin_formularios_proyecto',
                     'formularios_exigibles_dia')
 order by p.proname;
