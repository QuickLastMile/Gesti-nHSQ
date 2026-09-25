-- ============================================================
--  Los usuarios anonimos que se acumulaban
--  ------------------------------------------------------------
--  QUE PASABA
--  ----------
--  Para subir una foto, Storage exige un token de usuario: no basta
--  la llave anon. Por eso la app crea una sesion anonima de Supabase
--  Auth. Esa sesion se guardaba en sessionStorage, que el navegador
--  borra al cerrar la pestana, asi que al dia siguiente el mismo
--  mensajero estrenaba usuario.
--
--  Medido el 25/09/2026: 11 894 usuarios anonimos, ~370 nuevos al dia,
--  practicamente uno por persona por jornada (449 personas registraron
--  ese dia, se crearon 321 anonimos). Cada uno arrastraba su fila en
--  auth.sessions, auth.refresh_tokens y auth.mfa_amr_claims: 18 MB de
--  la base en desecho puro, creciendo para siempre.
--
--  EL ARREGLO ESTA EN EL FRONTEND
--  ------------------------------
--  assets/api.js -> el objeto `memoria`: el token y el refresh pasan a
--  localStorage, que sobrevive al cierre de la pestana. Se sigue
--  escribiendo tambien en sessionStorage y se lee de ahi como respaldo,
--  porque en modo privado localStorage puede fallar y el mensajero no
--  se puede quedar sin subir la foto.
--
--  Las sesiones de coordinador y admin NO cambian: esas siguen en
--  sessionStorage a proposito, para que no queden abiertas en un
--  computador compartido.
--
--  BORRAR ESTOS USUARIOS ES SEGURO
--  -------------------------------
--  No hay llave foranea de storage.objects hacia auth.users en este
--  proyecto: los 19 780 archivos quedan intactos aunque su dueno
--  desaparezca. Las unicas cascadas son a tablas de auth y a app_roles,
--  y un usuario anonimo no tiene rol. Verificado antes de borrar.
--
--  Supabase -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Antes de borrar: confirmar que nada cuelga de ahi
--  ------------------------------------------------------------
--  Si algun dia esta consulta muestra storage.objects con CASCADE,
--  NO borrar: se llevaria las fotos por delante.
-- ------------------------------------------------------------
select c.conname, c.conrelid::regclass as tabla,
       case c.confdeltype when 'c' then 'CASCADE (borra la fila hija)'
            when 'n' then 'SET NULL' when 'd' then 'SET DEFAULT'
            else 'NO ACTION / RESTRICT (falla)' end as al_borrar
  from pg_constraint c
 where c.contype = 'f' and c.confrelid = 'auth.users'::regclass
 order by 2;

-- ------------------------------------------------------------
--  2) Cuantos hay y cuantos se irian
-- ------------------------------------------------------------
select count(*) filter (where coalesce(is_anonymous,false)) as anonimos,
       count(*) filter (where coalesce(is_anonymous,false)
                          and created_at < now() - interval '2 days') as a_borrar,
       count(*) filter (where not coalesce(is_anonymous,false)) as cuentas_reales
  from auth.users;

-- ------------------------------------------------------------
--  3) La limpieza
--  ------------------------------------------------------------
--  Solo anonimos, y solo los de hace mas de dos dias: asi nadie que
--  este subiendo una foto en este momento pierde la sesion. Si igual
--  le pasara, la app le crea otra sola.
--
--  Por lotes de 2 000 para no dejar la tabla bloqueada un rato largo.
--  Se puede volver a correr cuando se quiera; es idempotente.
-- ------------------------------------------------------------
do $$
declare n int; total int := 0;
begin
  loop
    delete from auth.users
     where id in (select id from auth.users
                   where coalesce(is_anonymous,false)
                     and created_at < now() - interval '2 days'
                   limit 2000);
    get diagnostics n = row_count;
    total := total + n;
    exit when n = 0;
  end loop;
  raise notice 'Usuarios anonimos borrados: %', total;
end $$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Que quedo, y que NO se toco.
select (select count(*) from auth.users where coalesce(is_anonymous,false))     as anonimos_quedan,
       (select count(*) from auth.users where not coalesce(is_anonymous,false)) as cuentas_reales,
       (select count(*) from app_roles)                                          as roles_intactos,
       (select count(*) from storage.objects where bucket_id='evidencias')       as archivos_intactos;

-- b) El ritmo de creacion. Despues del arreglo del frontend esto deberia
--    caer de ~370 al dia a un punado: solo telefonos nuevos o gente que
--    borro los datos del navegador.
select created_at::date as dia, count(*) as anonimos_nuevos
  from auth.users where coalesce(is_anonymous,false)
 group by 1 order by 1 desc limit 10;

-- NOTA sobre el espacio: borrar filas no devuelve los MB al disco, los
-- deja libres para reusar. Las tablas de auth no van a seguir creciendo,
-- pero tampoco se encogen solas. Si algun dia hace falta recuperarlos:
--   vacuum full auth.users, auth.sessions, auth.refresh_tokens;
-- toma un bloqueo exclusivo, asi que fuera de horario.
