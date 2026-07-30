-- ============================================================
--  Ajustes de configuración de preguntas (PREOPERACIONAL)
--  Ejecutar en Supabase → SQL Editor.
-- ============================================================

-- Mantenimiento: las preguntas 40, 41 y 42 solo se muestran cuando
-- la 39 ("¿Has realizado algún tipo de mantenimiento…?") se responde SI.
update preguntas
   set depende_de = 'PRE_039', depende_valor = 'SI'
 where id in ('PRE_040', 'PRE_041', 'PRE_042');

-- Verificación
select id, orden, depende_de, depende_valor, left(pregunta, 60) as pregunta
  from preguntas
 where id in ('PRE_039', 'PRE_040', 'PRE_041', 'PRE_042')
 order by orden;
