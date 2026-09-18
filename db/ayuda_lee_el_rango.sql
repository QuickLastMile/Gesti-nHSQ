-- ============================================================
--  El texto de ayuda lee el rango, no lo repite
--  ------------------------------------------------------------
--  QUE PASABA
--  ----------
--  HSEQ cambiaba el maximo en Configuracion -> Rangos de medicion
--  y el mensajero seguia viendo "Maximo permitido: 25" debajo del
--  campo. El numero estaba escrito a mano en el texto de ayuda,
--  que es un segundo sitio donde vivia el mismo dato.
--
--  Y no era uno: por cada jornada estaba repetido en TRES textos
--  (la tarjeta de parametros, la ayuda del campo y la explicacion
--  de cuando es novedad). Seis en total contando manana y tarde.
--  Cualquier cambio dejaba al mensajero leyendo un limite y al
--  sistema aplicando otro.
--
--  EL ARREGLO
--  ----------
--  El texto deja de repetir el numero y pasa a citarlo:
--
--      {max}              el maximo de ESTA pregunta
--      {min}              el minimo de ESTA pregunta
--      {max:THA_002}      el maximo de otra pregunta
--      {min:THA_002}      el minimo de otra pregunta
--
--  La pantalla los reemplaza al pintar. El limite queda en un solo
--  sitio (el rango) y el texto no se puede desincronizar. Si el
--  rango esta vacio se lee "sin limite".
--
--  Sirve para cualquier pregunta, no solo temperatura: si manana
--  otra medicion necesita parametros, se escribe {max} en su ayuda
--  y queda igual de viva.
--
--  Requiere db/temperatura_rangos_1.sql y mensajero.html con
--  conRangos() (a partir del commit de este mismo cambio).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- La ayuda del propio campo: cita su propio maximo.
update preguntas set ayuda = 'Recuerde que son grados centígrados (°C). Máximo permitido: {max}.'
 where id in ('THA_002','THP_002');

update preguntas set ayuda = 'Recuerde que el valor es porcentual (%). Máximo permitido: {max}.'
 where id in ('THA_003','THP_003');

-- La tarjeta de parametros: cita el de temperatura y el de humedad.
update preguntas
   set ayuda = 'Durante el transporte de material, la temperatura y la humedad deben mantenerse dentro de los parámetros establecidos para garantizar que los dispositivos médicos e implantes se conserven en buen estado.'
            || chr(13) || chr(10) || 'Temperatura: máximo {max:THA_002} °C.'
            || chr(13) || chr(10) || 'Humedad relativa: máximo {max:THA_003} %.'
            || chr(13) || chr(10) || 'Estos valores NO deben superarse durante 24 horas continuas.'
 where id = 'THA_001';

update preguntas
   set ayuda = 'Durante el transporte de material, la temperatura y la humedad deben mantenerse dentro de los parámetros establecidos para garantizar que los dispositivos médicos e implantes se conserven en buen estado.'
            || chr(13) || chr(10) || 'Temperatura: máximo {max:THP_002} °C.'
            || chr(13) || chr(10) || 'Humedad relativa: máximo {max:THP_003} %.'
            || chr(13) || chr(10) || 'Estos valores NO deben superarse durante 24 horas continuas.'
 where id = 'THP_001';

-- Cuando es novedad: mismo criterio, citado.
update preguntas
   set ayuda = 'Se considera una novedad o desviación cuando la temperatura supera los {max:THA_002} °C y/o la humedad relativa supera el {max:THA_003} %, durante 24 horas seguidas.'
            || chr(13) || chr(10)
            || 'No tienes que calcularlo ni acordarte del registro anterior: escribe la medición tal como la ves y el sistema lo detecta solo. Si hay desviación te lo avisa aquí mismo y te pide la foto.'
 where id = 'THA_008';

update preguntas
   set ayuda = 'Se considera una novedad o desviación cuando la temperatura supera los {max:THP_002} °C y/o la humedad relativa supera el {max:THP_003} %, durante 24 horas seguidas.'
            || chr(13) || chr(10)
            || 'No tienes que calcularlo ni acordarte del registro anterior: escribe la medición tal como la ves y el sistema lo detecta solo. Si hay desviación te lo avisa aquí mismo y te pide la foto.'
 where id = 'THP_008';

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Los seis textos ya citan el rango en vez de repetirlo.
select pg.id, coalesce(fm.etiqueta,'') as jornada, pg.pregunta,
       left(pg.ayuda, 90) as ayuda
  from preguntas pg join formularios fm on fm.id = pg.formulario_id
 where fm.controla_rangos and pg.activo and pg.ayuda like '%{%'
 order by fm.orden, pg.orden;

-- b) Que no quede ningun numero suelto escrito a mano.
select pg.id, pg.pregunta, pg.ayuda
  from preguntas pg join formularios fm on fm.id = pg.formulario_id
 where fm.controla_rangos and pg.activo
   and pg.ayuda ~ 'm[aá]ximo[^{]*[0-9]'
 order by pg.id;
