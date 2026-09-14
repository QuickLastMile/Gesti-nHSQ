-- ============================================================
--  Los avisos del formulario de temperatura, con el texto real
--  ------------------------------------------------------------
--  Los avisos que puse al crear el formulario eran un resumen mio.
--  Estos son los del instructivo de la operacion, y traen dos cosas
--  que faltaban:
--
--   - Para que sirve: el material que se transporta son dispositivos
--     medicos e implantes, y de eso depende el criterio.
--   - Que las 24 horas continuas significan, en la practica, DOS
--     registros consecutivos fuera de parametros. Sin eso, la
--     pregunta de la desviacion se contesta a ojo.
--   - Un tercer paso ante la novedad: no manipular ni disponer del
--     material hasta recibir indicaciones.
--
--  Se agrega un aviso nuevo -"cuando se considera una novedad"-
--  justo antes de la pregunta, para que se lea en el momento de
--  responderla y no al principio del formulario.
--
--  Se puede volver a correr: actualiza en vez de duplicar.
--  Ejecutar DESPUES de db/temperatura_humedad.sql.
-- ============================================================

insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, ayuda, depende_de, depende_valor,
                       respuesta_alerta, alerta_en_registro, activo)
select v.id, v.formulario_id, v.seccion, v.pregunta, v.tipo, v.obligatorio, v.orden,
       v.ayuda, v.depende_de, v.depende_valor, v.respuesta_alerta, v.alerta, true
from (values
  ('THA_001', 'TEMP_HUM_AM', 'Criterio de aceptación', 'Control de temperatura y humedad', 'info', false, 1, 'Durante el transporte de material, la temperatura y la humedad deben mantenerse dentro de los parámetros establecidos para garantizar que los dispositivos médicos e implantes se conserven en buen estado.
Temperatura: máximo 25 °C.
Humedad relativa: máximo 65 %.
Estos valores NO deben superarse durante 24 horas continuas.', null, null, null, false),
  ('THA_002', 'TEMP_HUM_AM', 'Medición', 'Temperatura', 'numero', true, 2, 'Recuerde que son grados centígrados (°C). Máximo permitido: 25.', null, null, null, false),
  ('THA_003', 'TEMP_HUM_AM', 'Medición', 'Humedad', 'numero', true, 3, 'Recuerde que el valor es porcentual (%). Máximo permitido: 65.', null, null, null, false),
  ('THA_008', 'TEMP_HUM_AM', 'Medición', '¿Cuándo se considera una novedad?', 'info', false, 4, 'Se considera una novedad o desviación cuando la temperatura supera los 25 °C y/o la humedad relativa supera el 65 %, durante 24 horas seguidas.
En la práctica son dos (2) registros consecutivos por fuera de los parámetros: si el anterior se salió y este también, responda SÍ.', null, null, null, false),
  ('THA_004', 'TEMP_HUM_AM', 'Medición', 'De acuerdo con el último registro de temperatura y humedad que usted realizó, ¿se evidencia una condición sostenida durante 24 horas continuas con temperatura superior a 25 °C y/o humedad relativa mayor al 65 %?', 'si_no', true, 5, null, null, null, 'SI', true),
  ('THA_005', 'TEMP_HUM_AM', 'Reporte de desviaciones', '¿Qué debe hacer ahora?', 'info', false, 6, '1. Notifique de inmediato al Coordinador HSEQ, al número +57 310 719 6685.
2. Adjunte la evidencia fotográfica del registro de temperatura y humedad en la siguiente pregunta.
3. NO manipule ni disponga del material hasta recibir indicaciones.', 'THA_004', 'SI', null, false),
  ('THA_006', 'TEMP_HUM_AM', 'Reporte de desviaciones', 'Soporte fotográfico de la desviación', 'archivo', true, 7, 'Foto del registro de temperatura y humedad.', 'THA_004', 'SI', null, false),
  ('THA_007', 'TEMP_HUM_AM', 'Tratamiento de datos', 'Tratamiento de datos personales', 'info', false, 8, 'De acuerdo con la Ley 1581 de 2012 y sus decretos reglamentarios, al registrar autoriza de manera libre, expresa e informada a Quick Help el tratamiento de sus datos personales con fines de gestión de capacitación, verificación del aprendizaje y cumplimiento del Sistema de Gestión de Seguridad y Salud en el Trabajo (SG-SST).', null, null, null, false)
) as v(id, formulario_id, seccion, pregunta, tipo, obligatorio, orden, ayuda,
       depende_de, depende_valor, respuesta_alerta, alerta)
on conflict (id) do update
  set formulario_id = excluded.formulario_id,
      seccion = excluded.seccion,
      pregunta = excluded.pregunta,
      tipo_respuesta = excluded.tipo_respuesta,
      obligatorio = excluded.obligatorio,
      orden = excluded.orden,
      ayuda = excluded.ayuda,
      depende_de = excluded.depende_de,
      depende_valor = excluded.depende_valor,
      respuesta_alerta = excluded.respuesta_alerta,
      alerta_en_registro = excluded.alerta_en_registro,
      activo = true;
insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
                       obligatorio, orden, ayuda, depende_de, depende_valor,
                       respuesta_alerta, alerta_en_registro, activo)
select v.id, v.formulario_id, v.seccion, v.pregunta, v.tipo, v.obligatorio, v.orden,
       v.ayuda, v.depende_de, v.depende_valor, v.respuesta_alerta, v.alerta, true
from (values
  ('THP_001', 'TEMP_HUM_PM', 'Criterio de aceptación', 'Control de temperatura y humedad', 'info', false, 1, 'Durante el transporte de material, la temperatura y la humedad deben mantenerse dentro de los parámetros establecidos para garantizar que los dispositivos médicos e implantes se conserven en buen estado.
Temperatura: máximo 25 °C.
Humedad relativa: máximo 65 %.
Estos valores NO deben superarse durante 24 horas continuas.', null, null, null, false),
  ('THP_002', 'TEMP_HUM_PM', 'Medición', 'Temperatura', 'numero', true, 2, 'Recuerde que son grados centígrados (°C). Máximo permitido: 25.', null, null, null, false),
  ('THP_003', 'TEMP_HUM_PM', 'Medición', 'Humedad', 'numero', true, 3, 'Recuerde que el valor es porcentual (%). Máximo permitido: 65.', null, null, null, false),
  ('THP_008', 'TEMP_HUM_PM', 'Medición', '¿Cuándo se considera una novedad?', 'info', false, 4, 'Se considera una novedad o desviación cuando la temperatura supera los 25 °C y/o la humedad relativa supera el 65 %, durante 24 horas seguidas.
En la práctica son dos (2) registros consecutivos por fuera de los parámetros: si el anterior se salió y este también, responda SÍ.', null, null, null, false),
  ('THP_004', 'TEMP_HUM_PM', 'Medición', 'De acuerdo con el último registro de temperatura y humedad que usted realizó, ¿se evidencia una condición sostenida durante 24 horas continuas con temperatura superior a 25 °C y/o humedad relativa mayor al 65 %?', 'si_no', true, 5, null, null, null, 'SI', true),
  ('THP_005', 'TEMP_HUM_PM', 'Reporte de desviaciones', '¿Qué debe hacer ahora?', 'info', false, 6, '1. Notifique de inmediato al Coordinador HSEQ, al número +57 310 719 6685.
2. Adjunte la evidencia fotográfica del registro de temperatura y humedad en la siguiente pregunta.
3. NO manipule ni disponga del material hasta recibir indicaciones.', 'THP_004', 'SI', null, false),
  ('THP_006', 'TEMP_HUM_PM', 'Reporte de desviaciones', 'Soporte fotográfico de la desviación', 'archivo', true, 7, 'Foto del registro de temperatura y humedad.', 'THP_004', 'SI', null, false),
  ('THP_007', 'TEMP_HUM_PM', 'Tratamiento de datos', 'Tratamiento de datos personales', 'info', false, 8, 'De acuerdo con la Ley 1581 de 2012 y sus decretos reglamentarios, al registrar autoriza de manera libre, expresa e informada a Quick Help el tratamiento de sus datos personales con fines de gestión de capacitación, verificación del aprendizaje y cumplimiento del Sistema de Gestión de Seguridad y Salud en el Trabajo (SG-SST).', null, null, null, false)
) as v(id, formulario_id, seccion, pregunta, tipo, obligatorio, orden, ayuda,
       depende_de, depende_valor, respuesta_alerta, alerta)
on conflict (id) do update
  set formulario_id = excluded.formulario_id,
      seccion = excluded.seccion,
      pregunta = excluded.pregunta,
      tipo_respuesta = excluded.tipo_respuesta,
      obligatorio = excluded.obligatorio,
      orden = excluded.orden,
      ayuda = excluded.ayuda,
      depende_de = excluded.depende_de,
      depende_valor = excluded.depende_valor,
      respuesta_alerta = excluded.respuesta_alerta,
      alerta_en_registro = excluded.alerta_en_registro,
      activo = true;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) El formulario completo, en orden. Deben salir 4 avisos (info)
--    y 4 preguntas de verdad por jornada.
select formulario_id, orden, id, tipo_respuesta,
       case when depende_de is not null then 'solo si ' || depende_de || '=' || depende_valor
            else '' end as condicion,
       left(pregunta, 45) as titulo
  from preguntas
 where formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM') and activo
 order by formulario_id, orden;

-- b) Cuantos avisos por jornada.
select formulario_id,
       count(*) filter (where tipo_respuesta = 'info') as avisos,
       count(*) filter (where tipo_respuesta <> 'info') as preguntas
  from preguntas
 where formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM') and activo
 group by formulario_id order by formulario_id;
