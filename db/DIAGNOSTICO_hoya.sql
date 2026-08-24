-- ============================================================
--  Diagnóstico — ¿por qué Hoya aparece bajo otro líder?
--  ------------------------------------------------------------
--  La pantalla de administración muestra lo CONFIGURADO por CECO.
--  El dashboard agrupa por el proyecto donde la persona labora y
--  usa el encargado ya RESUELTO en cada colaborador. Cuando los
--  dos no coinciden, es porque alguna persona tiene un CECO o un
--  traslado que no cuadra.
--
--  No modifica nada: solo consulta.
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- 1) Cada persona de Hoya, con su CECO y el encargado que le quedó.
--    Aquí se ve quién es el que trae a MARYU.
select 'PERSONAS' as bloque,
       c.cedula, c.nombre,
       c.proyecto_id                       as ceco_nomina,
       c.proyecto                          as proyecto_nomina,
       coalesce(c.proyecto_operativo,'')   as trasladado_a,
       c.proyecto_efectivo,
       coalesce(c.enc_jefatura,'')         as jefe,
       coalesce(c.enc_lider,'')            as lider,
       coalesce(c.enc_coordinador,'')      as coordinador,
       c.activo
from colaboradores c
where c.proyecto_efectivo ilike '%HOYA%'
   or c.proyecto ilike '%HOYA%'
order by c.enc_lider, c.nombre;

-- 2) Lo configurado para los CECOs que aparezcan arriba.
select 'CONFIGURADO' as bloque,
       r.proyecto_id, r.frente, coalesce(r.cliente,'') as cliente,
       coalesce(r.jefatura,'') as jefatura, coalesce(r.lider,'') as lider,
       coalesce(r.coordinador,'') as coordinador
from responsables_proyecto r
where r.proyecto_id in (
  select distinct coalesce(nullif(btrim(c.proyecto_id),''),'')
  from colaboradores c
  where c.proyecto_efectivo ilike '%HOYA%' or c.proyecto ilike '%HOYA%')
order by r.proyecto_id, r.frente;

-- 3) Traslados cuyo destino NO se pudo enlazar con ningún CECO.
--    Estos son los que quedan con el encargado del proyecto de
--    nómina aunque el dashboard ya los muestre en el destino.
select 'TRASLADO SIN CECO' as bloque,
       c.cedula, c.nombre, c.proyecto as proyecto_nomina,
       c.proyecto_operativo as trasladado_a,
       coalesce(c.enc_lider,'') as lider_que_quedo
from colaboradores c
where c.activo
  and coalesce(btrim(c.proyecto_operativo),'') <> ''
  and codigo_proyecto(c.proyecto_operativo) is null
order by c.nombre;

-- 4) Nombres de proyecto que existen con MÁS de un CECO.
--    Si Hoya sale aquí, ese es el origen del cruce.
select 'NOMBRE CON VARIOS CECOS' as bloque,
       c.proyecto, count(distinct c.proyecto_id) as cuantos_cecos,
       string_agg(distinct c.proyecto_id, ', ') as cecos
from colaboradores c
where coalesce(c.proyecto,'') <> ''
group by c.proyecto
having count(distinct c.proyecto_id) > 1
order by 2 desc, 1;
