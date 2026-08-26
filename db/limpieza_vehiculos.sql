-- ============================================================
--  Gestión HSEQ — Una sola limpieza y desinfección: moto y vehículo
--  ------------------------------------------------------------
--  Mismo patrón del preoperacional: el formulario sigue siendo uno
--  (LIMPIEZA_MOTO) y cada pregunta queda marcada con a quién aplica.
--
--     aplica_a = null        → la responden todos
--     aplica_a = 'MOTO'      → solo QUICKER - MENSAJERO
--     aplica_a = 'VEHICULO'  → solo QUICKER - CONDUCTOR
--
--  El perfil sale del cargo. Al digitar la cédula, el sistema arma
--  el formulario que le corresponde a esa persona. No hace falta
--  tocar ninguna función: api_cargar_formulario y api_exportable ya
--  filtran por aplica_a para cualquier formulario.
--
--  El id del formulario NO cambia: los registros históricos lo
--  referencian. Solo cambia el nombre que se ve en pantalla.
--
--  Ejecutar DESPUÉS de: preoperacional_vehiculos.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) El nombre deja de hablar solo de motos
-- ------------------------------------------------------------
update formularios
   set nombre = 'Limpieza y desinfección del vehículo',
       descripcion = 'Limpieza y desinfección diaria. Las preguntas cambian según el cargo.'
 where id = 'LIMPIEZA_MOTO';

-- ------------------------------------------------------------
-- 2) Lo que ya existía y es propio de la moto
--    Quedan fuera fecha, hora, responsable, observaciones y
--    resultado: esas las responden los dos perfiles.
-- ------------------------------------------------------------
update preguntas set aplica_a = 'MOTO'
 where formulario_id = 'LIMPIEZA_MOTO'
   and id in (
     'LIM_003',              -- estado general antes de la limpieza
     'LIM_004',              -- limpieza externa de la moto
     'LIM_005',              -- manubrios y tablero
     'LIM_006',              -- baúl o caja de transporte
     'LIM_007',              -- desinfección de superficies
     'LIM_008',              -- productos utilizados
     'LIM_009', 'LIM_010'    -- evidencias antes y después
   );

-- ------------------------------------------------------------
-- 3) Listas de opciones del vehículo
--    Sin índice único en la tabla: se evita el duplicado a mano
--    para poder volver a ejecutar el script sin repetir opciones.
-- ------------------------------------------------------------
insert into opciones (grupo, valor, orden, activo)
select v.grupo, v.valor, v.orden, true
  from (values
    -- Tipo de vehículo
    ('tipo_vehiculo_lim', 'CARRY', 1),
    ('tipo_vehiculo_lim', 'NHR', 2),
    ('tipo_vehiculo_lim', 'NPR', 3),
    ('tipo_vehiculo_lim', 'NKR', 4),
    ('tipo_vehiculo_lim', 'TRACTOCAMIÓN', 5),
    ('tipo_vehiculo_lim', 'CAMIÓN RÍGIDO 4 EJES', 6),
    ('tipo_vehiculo_lim', 'CAMIÓN RÍGIDO 3 EJES', 7),
    ('tipo_vehiculo_lim', 'CAMIÓN 2 EJES', 8),
    ('tipo_vehiculo_lim', 'TURBOCAMIÓN', 9),
    ('tipo_vehiculo_lim', 'CARROTANQUE', 10),
    ('tipo_vehiculo_lim', 'SENCILLO', 11),
    ('tipo_vehiculo_lim', 'PATINETA', 12),
    -- Pasos de aseo
    ('pasos_aseo_veh', 'Limpieza', 1),
    ('pasos_aseo_veh', 'Limpieza y Desinfección', 2),
    ('pasos_aseo_veh', 'Desinfección', 3),
    -- Partes del vehículo
    ('partes_vehiculo_lim', 'Timón', 1),
    ('partes_vehiculo_lim', 'Cojinería', 2),
    ('partes_vehiculo_lim', 'Palanca de Cambios', 3),
    ('partes_vehiculo_lim', 'Freno de Mano', 4),
    ('partes_vehiculo_lim', 'Cinturón de Seguridad', 5),
    ('partes_vehiculo_lim', 'Manijas', 6),
    ('partes_vehiculo_lim', 'Vidrios', 7),
    ('partes_vehiculo_lim', 'Limpieza externa', 8),
    ('partes_vehiculo_lim', 'Área de Carga (Zona donde transportas la mercancía)', 9),
    -- Veces al día
    ('veces_aseo_dia', 'Una vez al día', 1),
    ('veces_aseo_dia', 'Dos veces al día (Iniciando y Finalizando la Jornada Laboral)', 2),
    ('veces_aseo_dia', 'Tres veces al día (Incluyendo Tiempos Muertos)', 3),
    ('veces_aseo_dia', 'Cuatro veces al día (Incluyendo Tiempos Muertos)', 4),
    -- Sustancia de LIMPIEZA
    ('sustancia_limpieza_veh', 'Detergente líquido + Agua', 1),
    ('sustancia_limpieza_veh', 'Multiusos + Agua', 2),
    ('sustancia_limpieza_veh', 'Jabón líquido + Agua', 3),
    ('sustancia_limpieza_veh', 'Paños húmedos sin alcohol + Agua', 4),
    ('sustancia_limpieza_veh', 'Sólo Agua', 5),
    ('sustancia_limpieza_veh', 'No Aplica (no se realizó LIMPIEZA)', 6),
    -- Sustancia de DESINFECCIÓN
    ('sustancia_desinfeccion_veh', 'Dilución de hipoclorito y agua', 1),
    ('sustancia_desinfeccion_veh', 'Alcohol del 60% al 95%', 2),
    ('sustancia_desinfeccion_veh', 'Hipoclorito Puro', 3),
    ('sustancia_desinfeccion_veh', 'Paños húmedos con alcohol', 4),
    ('sustancia_desinfeccion_veh', 'Amonio Cuaternario', 5),
    ('sustancia_desinfeccion_veh', 'No Aplica (no se realizó DESINFECCIÓN)', 6)
  ) as v(grupo, valor, orden)
 where not exists (
   select 1 from opciones o where o.grupo = v.grupo and o.valor = v.valor
 );

-- ------------------------------------------------------------
-- 4) Las preguntas propias del vehículo
--    El orden se intercala con las de moto (3.x a 10.x) para que
--    queden entre la hora y el responsable, que son compartidos.
-- ------------------------------------------------------------
insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, grupo_opciones, ayuda, aplica_a, activo) values
  ('LIV_001', 'LIMPIEZA_MOTO', 'Datos del vehículo', 'Tipo de vehículo',
   'desplegable', true, 3.1, 'tipo_vehiculo_lim',
   'Se guarda y queda precargado para los siguientes días.', 'VEHICULO', true),

  ('LIV_002', 'LIMPIEZA_MOTO', 'Limpieza y desinfección', '¿Qué pasos de aseo realizaste hoy a tu vehículo?',
   'desplegable', true, 4.1, 'pasos_aseo_veh', null, 'VEHICULO', true),

  ('LIV_003', 'LIMPIEZA_MOTO', 'Limpieza y desinfección', '¿A qué partes del vehículo lo realizaste?',
   'checkbox', true, 5.1, 'partes_vehiculo_lim', 'Marca todas las que apliquen.', 'VEHICULO', true),

  ('LIV_004', 'LIMPIEZA_MOTO', 'Limpieza y desinfección', '¿Cuántas veces los realizaste al día?',
   'desplegable', true, 6.1, 'veces_aseo_dia', null, 'VEHICULO', true),

  ('LIV_005', 'LIMPIEZA_MOTO', 'Limpieza y desinfección', '¿Con qué sustancia se realizó la LIMPIEZA de tus elementos de trabajo?',
   'desplegable', true, 7.1, 'sustancia_limpieza_veh', null, 'VEHICULO', true),

  ('LIV_006', 'LIMPIEZA_MOTO', 'Limpieza y desinfección', '¿Con qué sustancia se realizó la DESINFECCIÓN de tus elementos de trabajo?',
   'desplegable', true, 7.2, 'sustancia_desinfeccion_veh', null, 'VEHICULO', true),

  ('LIV_007', 'LIMPIEZA_MOTO', 'Evidencia', 'Sube la evidencia de la limpieza y desinfección que realizaste',
   'archivo', true, 9.1, null, null, 'VEHICULO', true),

  ('LIV_008', 'LIMPIEZA_MOTO', 'Evidencia', 'Soporte de asistencia a centro especializado en lavado de vehículos',
   'archivo', false, 10.1, null,
   'Solo si lavaste en un centro especializado.', 'VEHICULO', true),

  ('LIV_009', 'LIMPIEZA_MOTO', 'Evidencia', 'Documento que autoriza los vertimientos del centro de lavado',
   'archivo', false, 10.2, null,
   'Al asistir a un centro de lavado, recuerda solicitarlo.', 'VEHICULO', true)

on conflict (id) do update set
  seccion = excluded.seccion, pregunta = excluded.pregunta,
  tipo_respuesta = excluded.tipo_respuesta, obligatorio = excluded.obligatorio,
  orden = excluded.orden, grupo_opciones = excluded.grupo_opciones,
  ayuda = excluded.ayuda, aplica_a = excluded.aplica_a, activo = excluded.activo;

-- ------------------------------------------------------------
-- 5) Comprobación
--    a) Cómo queda repartido el formulario.
--    b) El formulario que vería un conductor y el de un mensajero.
-- ------------------------------------------------------------
select coalesce(aplica_a, 'AMBOS') as le_aplica_a, count(*) as preguntas
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
 group by coalesce(aplica_a, 'AMBOS')
 order by 1;

select 'CONDUCTOR' as perfil, orden, id, seccion, pregunta
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
   and (aplica_a is null or aplica_a = 'VEHICULO')
union all
select 'MENSAJERO', orden, id, seccion, pregunta
  from preguntas
 where formulario_id = 'LIMPIEZA_MOTO' and activo
   and (aplica_a is null or aplica_a = 'MOTO')
 order by 1, 2;

-- ------------------------------------------------------------
--  Recuerda: para que un conductor vea este formulario, su
--  proyecto debe tenerlo habilitado en
--  Administración → Formularios por proyecto.
-- ------------------------------------------------------------
