-- ============================================================
--  Diagnóstico — ¿quién mete a Hoya bajo otro líder?
--  ------------------------------------------------------------
--  Una sola consulta, para que el editor de Supabase muestre todo
--  junto. No modifica nada.
--
--  Supabase → SQL Editor → New query → pegar todo → Run
--  Copia el resultado completo y pásamelo.
-- ============================================================

-- A) Cada persona que el dashboard agrupa en Hoya, con el encargado
--    que le quedó guardado. Aquí se ve quién trae al líder equivocado.
select 'A-PERSONA'                          as bloque,
       c.cedula                             as dato1,
       c.nombre                             as dato2,
       'CECO nomina: ' || coalesce(c.proyecto_id,'(vacio)')      as dato3,
       'nomina: '     || coalesce(c.proyecto,'(vacio)')          as dato4,
       'trasladado a: '|| coalesce(nullif(btrim(c.proyecto_operativo),''),'(no)') as dato5,
       'lider: '      || coalesce(nullif(c.enc_lider,''),'(sin lider)')           as dato6
from colaboradores c
where c.activo
  and (c.proyecto_efectivo ilike '%HOYA%' or c.proyecto ilike '%HOYA%')

union all

-- B) Lo configurado para los CECOs involucrados.
select 'B-CONFIGURADO',
       r.proyecto_id,
       coalesce(nullif(r.frente,''),'(todo el proyecto)'),
       'cliente: '   || coalesce(r.cliente,''),
       'jefe: '      || coalesce(r.jefatura,''),
       'lider: '     || coalesce(r.lider,''),
       'coord: '     || coalesce(r.coordinador,'')
from responsables_proyecto r
where r.proyecto_id in (
  select distinct coalesce(nullif(btrim(c.proyecto_id),''),'-')
  from colaboradores c
  where c.activo and (c.proyecto_efectivo ilike '%HOYA%' or c.proyecto ilike '%HOYA%'))

union all

-- C) Traslados cuyo destino no se pudo enlazar con ningún CECO.
select 'C-TRASLADO SIN CECO',
       c.cedula, c.nombre,
       'nomina: '      || coalesce(c.proyecto,''),
       'trasladado a: '|| coalesce(c.proyecto_operativo,''),
       'lider: '       || coalesce(nullif(c.enc_lider,''),'(sin lider)'),
       ''
from colaboradores c
where c.activo
  and coalesce(btrim(c.proyecto_operativo),'') <> ''
  and codigo_proyecto(c.proyecto_operativo) is null

union all

-- D) Nombres de proyecto que existen con más de un CECO.
select 'D-NOMBRE CON VARIOS CECOS',
       c.proyecto,
       count(distinct c.proyecto_id)::text || ' cecos',
       string_agg(distinct coalesce(c.proyecto_id,'(vacio)'), ', '),
       '', '', ''
from colaboradores c
where coalesce(c.proyecto,'') <> ''
group by c.proyecto
having count(distinct c.proyecto_id) > 1

order by 1, 2;
