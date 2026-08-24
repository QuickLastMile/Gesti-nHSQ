-- ============================================================
--  FIX — El parámetro "nombre" chocaba con la columna "nombre"
--  ------------------------------------------------------------
--  codigo_proyecto(nombre text) buscaba el CECO comparando:
--
--      where btrim(proyecto) = btrim(nombre)
--
--  Pero la tabla colaboradores TAMBIÉN tiene una columna llamada
--  "nombre". En PostgreSQL, cuando un identificador puede ser un
--  parámetro o una columna, gana la columna. Así que lo que se
--  evaluaba de verdad era:
--
--      el proyecto es igual al NOMBRE DE LA PERSONA
--
--  Eso nunca se cumple: la función devolvía NULL siempre. Por eso
--  ningún traslado enlazaba con su proyecto destino y la gente
--  trasladada conservaba los encargados de su proyecto de nómina
--  aunque el dashboard ya la mostrara en el destino.
--
--  La misma trampa estaba en en_alcance(tipo, nombre, ced), que
--  comparaba el encargado contra el nombre de la persona: por eso
--  la primera versión del filtro devolvía cero.
--
--  Se renombran los parámetros para que no puedan confundirse.
--  Hay que borrar las funciones antes: PostgreSQL no deja cambiar
--  el nombre de un parámetro con create or replace.
--
--  Ejecutar DESPUÉS de: filtro_encargado_v2.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) El CECO a partir del nombre del proyecto
-- ------------------------------------------------------------
drop function if exists codigo_proyecto(text);

create function codigo_proyecto(p_nombre text)
returns text language sql stable set search_path = public as $fn$
  select c.proyecto_id
    from colaboradores c
   where btrim(coalesce(p_nombre,'')) <> ''
     and coalesce(c.proyecto_id,'') <> ''
     and sin_tildes(regexp_replace(btrim(coalesce(c.proyecto,'')), '\s+', ' ', 'g'))
       = sin_tildes(regexp_replace(btrim(coalesce(p_nombre,'')),   '\s+', ' ', 'g'))
   -- Ante varios CECOs con el mismo nombre, manda el que tiene encargados.
   order by (exists (select 1 from responsables_proyecto r
                      where r.proyecto_id = c.proyecto_id and r.frente = '')) desc,
            c.proyecto_id
   limit 1;
$fn$;

-- ------------------------------------------------------------
-- 2) La versión vieja del filtro, con el mismo defecto.
--    Ya no la usa nadie, pero se deja sana para que no vuelva a
--    dar resultados en cero si algo la llama.
-- ------------------------------------------------------------
drop function if exists en_alcance(text, text, text);

create function en_alcance(p_tipo text, p_encargado text, p_cedula text)
returns boolean language sql stable set search_path = public as $fn$
  select coalesce(btrim(p_encargado), '') = ''
      or exists (
        select 1 from colaboradores c
         where regexp_replace(c.cedula, '\D', '', 'g') = regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g')
           and sin_tildes(btrim(coalesce(
                 case upper(btrim(coalesce(p_tipo, '')))
                   when 'LIDER'       then c.enc_lider
                   when 'COORDINADOR' then c.enc_coordinador
                   else c.enc_jefatura
                 end, '')))
             = sin_tildes(btrim(p_encargado))
      );
$fn$;

revoke all on function en_alcance(text, text, text) from public, anon;

-- ------------------------------------------------------------
-- 3) Recalcular toda la matriz con la regla ya corregida
-- ------------------------------------------------------------
select recalcular_encargados() as colaboradores_actualizados;

-- ------------------------------------------------------------
-- 4) Comprobación: los traslados y a quién le responden ahora.
--    "ceco_destino" no debe quedar vacío en ninguno; si alguno
--    queda, ese proyecto destino ya no existe en la matriz.
-- ------------------------------------------------------------
select c.cedula, c.nombre,
       c.proyecto              as proyecto_nomina,
       c.proyecto_operativo    as trasladado_a,
       coalesce(codigo_proyecto(c.proyecto_operativo),'(no resuelve)') as ceco_destino,
       coalesce(nullif(c.enc_jefatura,''),'(sin jefe)')  as jefe,
       coalesce(nullif(c.enc_lider,''),'(sin lider)')    as lider,
       coalesce(nullif(c.enc_coordinador,''),'(sin coord)') as coordinador
from colaboradores c
where c.activo
  and coalesce(btrim(c.proyecto_operativo),'') <> ''
order by c.nombre;
