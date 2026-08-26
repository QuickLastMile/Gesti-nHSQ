-- ============================================================
--  Limpieza y desinfección de vehículos — corrección
--  ------------------------------------------------------------
--  Tres cosas del primer intento:
--
--  1) Marqué como MOTO una lista de preguntas tomada del archivo
--     base del repositorio, pero la base real tiene otras. Por eso
--     al conductor le seguían apareciendo preguntas de moto —
--     evidencia, soporte de lavadero, permiso de vertimientos —
--     duplicadas con las suyas.
--
--     Se corrige de raíz y sin depender de acertar ningún id:
--     TODO lo que ya existía en el formulario pasa a ser de moto.
--     El conductor ve únicamente las preguntas LIV_*, y el
--     mensajero ve exactamente lo mismo que veía antes.
--
--  2) Faltaban modelo y tipo de combustible. Se agregan.
--
--  3) La pregunta de pasos de aseo lleva la infografía de
--     referencia, igual que en el formulario de moto.
--
--  Ejecutar DESPUÉS de: limpieza_vehiculos.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) Lo que ya existía es de la moto, sin excepción
--    Así no queda ninguna pregunta repetida en el formulario del
--    conductor, sin importar qué preguntas haya hoy en la base.
-- ------------------------------------------------------------
update preguntas
   set aplica_a = 'MOTO'
 where formulario_id = 'LIMPIEZA_MOTO'
   and id not like 'LIV\_%';

-- ------------------------------------------------------------
-- 2) Opciones nuevas: combustible
-- ------------------------------------------------------------
insert into opciones (grupo, valor, orden, activo)
select v.grupo, v.valor, v.orden, true
  from (values
    ('combustible_veh', 'ACPM', 1),
    ('combustible_veh', 'DIÉSEL', 2),
    ('combustible_veh', 'ELÉCTRICO', 3),
    ('combustible_veh', 'GAS', 4),
    ('combustible_veh', 'GASOLINA', 5)
  ) as v(grupo, valor, orden)
 where not exists (
   select 1 from opciones o where o.grupo = v.grupo and o.valor = v.valor
 );

-- ------------------------------------------------------------
-- 3) Modelo y tipo de combustible, que faltaban
-- ------------------------------------------------------------
insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, grupo_opciones, ayuda, aplica_a, activo) values
  ('LIV_010', 'LIMPIEZA_MOTO', 'Datos del vehículo', 'Modelo (AÑO)',
   'numero', true, 3.2, null,
   'Se guarda y queda precargado para los siguientes días.', 'VEHICULO', true),

  ('LIV_011', 'LIMPIEZA_MOTO', 'Datos del vehículo', 'Tipo de combustible',
   'desplegable', true, 3.3, 'combustible_veh',
   'Se guarda y queda precargado para los siguientes días.', 'VEHICULO', true)

on conflict (id) do update set
  seccion = excluded.seccion, pregunta = excluded.pregunta,
  tipo_respuesta = excluded.tipo_respuesta, obligatorio = excluded.obligatorio,
  orden = excluded.orden, grupo_opciones = excluded.grupo_opciones,
  ayuda = excluded.ayuda, aplica_a = excluded.aplica_a, activo = excluded.activo;

-- ------------------------------------------------------------
-- 4) La infografía de los 10 pasos, en la pregunta de pasos de aseo
--    ------------------------------------------------------------
--    La imagen debe estar publicada en el repositorio, en
--    assets/pasos-limpieza-vehiculo.png
--
--    Si prefieres tenerla en Drive, reemplaza la URL de abajo por
--    el enlace del archivo: la app reconoce los enlaces de Drive y
--    muestra la miniatura sola.
-- ------------------------------------------------------------
update preguntas
   set imagen_url = 'https://quicklastmile.github.io/Gesti-nHSQ/assets/pasos-limpieza-vehiculo.png',
       ayuda = 'Toca la imagen para ver los 10 pasos de la limpieza y desinfección rutinaria.'
 where id = 'LIV_002';

-- ------------------------------------------------------------
-- 5) Comprobación
--    a) Reparto del formulario.
--    b) Lo que ve cada perfil, en orden. En CONDUCTOR no debe
--       aparecer ninguna pregunta que no empiece por LIV_.
-- ------------------------------------------------------------
select coalesce(aplica_a, 'AMBOS') as le_aplica_a, count(*) as preguntas
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
 group by coalesce(aplica_a, 'AMBOS')
 order by 1;

select 'CONDUCTOR' as perfil, orden, id, seccion, pregunta,
       case when imagen_url is null then '' else 'con imagen' end as extra
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
   and (aplica_a is null or aplica_a = 'VEHICULO')
union all
select 'MENSAJERO', orden, id, seccion, pregunta,
       case when imagen_url is null then '' else 'con imagen' end
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
   and (aplica_a is null or aplica_a = 'MOTO')
 order by 1, 2;
