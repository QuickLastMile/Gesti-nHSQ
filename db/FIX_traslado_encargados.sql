-- ============================================================
--  FIX — El traslado enlaza mal el proyecto destino
--  ------------------------------------------------------------
--  Cuando alguien está trasladado, sus encargados salen del
--  proyecto DONDE LABORA. Para saber cuál es, se busca el CECO a
--  partir del nombre del proyecto destino.
--
--  Esa búsqueda exigía que el nombre coincidiera letra por letra.
--  Si difiere en una tilde, en mayúsculas o en un espacio de más,
--  no encuentra nada y la persona se queda con los encargados de
--  su proyecto de NÓMINA — mientras el dashboard ya la muestra en
--  el proyecto destino. De ahí que un proyecto aparezca bajo un
--  líder que no es el suyo.
--
--  Ahora la comparación ignora tildes, mayúsculas y espacios
--  sobrantes. Y cuando un mismo nombre existe con varios CECOs,
--  se prefiere el que sí tiene encargados configurados, en vez de
--  tomar uno al azar.
--
--  Ejecutar DESPUÉS de: encargados_por_proyecto.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

create or replace function codigo_proyecto(nombre text)
returns text language sql stable set search_path = public as $fn$
  select c.proyecto_id
    from colaboradores c
   where btrim(coalesce(nombre,'')) <> ''
     and coalesce(c.proyecto_id,'') <> ''
     and sin_tildes(regexp_replace(btrim(coalesce(c.proyecto,'')), '\s+', ' ', 'g'))
       = sin_tildes(regexp_replace(btrim(coalesce(nombre,'')),      '\s+', ' ', 'g'))
   -- Ante varios CECOs con el mismo nombre, manda el que tiene encargados.
   order by (exists (select 1 from responsables_proyecto r
                      where r.proyecto_id = c.proyecto_id and r.frente = '')) desc,
            c.proyecto_id
   limit 1;
$fn$;

-- Vuelve a resolver los encargados de toda la matriz con la regla corregida.
select recalcular_encargados() as colaboradores_actualizados;

-- ------------------------------------------------------------
--  Comprobación: después de esto no debería quedar ningún
--  traslado sin CECO. Si alguno queda, el proyecto destino ya no
--  existe en la matriz y hay que corregirlo desde Colaboradores.
-- ------------------------------------------------------------
select c.cedula, c.nombre, c.proyecto as proyecto_nomina,
       c.proyecto_operativo as trasladado_a,
       coalesce(c.enc_lider,'') as lider_que_quedo
from colaboradores c
where c.activo
  and coalesce(btrim(c.proyecto_operativo),'') <> ''
  and codigo_proyecto(c.proyecto_operativo) is null;
