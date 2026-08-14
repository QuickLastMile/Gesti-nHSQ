-- ============================================================
--  Gestión HSEQ Motos — Cómo agregar formularios y editar preguntas
--  ------------------------------------------------------------
--  Las preguntas NO están en el código: viven en la base de datos.
--  Aquí están las plantillas para cada cambio. Copia el bloque que
--  necesites, ajústalo y ejecútalo en:
--     Supabase → SQL Editor → New query → Run
--
--  Todo el archivo está comentado a propósito: NO se ejecuta completo.
--  Descomenta (quita los guiones) solo lo que vayas a usar.
--
--  Cómo está hoy:
--    PREOPERACIONAL  48 preguntas  (PRE_001 … PRE_048)
--    LIMPIEZA_MOTO   14 preguntas  (LIM_001 … LIM_014)
-- ============================================================


-- ============================================================
--  0) VER lo que hay antes de tocar nada
-- ============================================================

-- Todas las preguntas de un formulario, en orden:
-- select id, orden, seccion, pregunta, tipo_respuesta, obligatorio, activo
--   from preguntas
--  where formulario_id = 'PREOPERACIONAL'
--  order by orden;

-- Buscar una pregunta por su texto:
-- select id, formulario_id, orden, pregunta
--   from preguntas
--  where pregunta ilike '%llantas%';


-- ============================================================
--  1) CAMBIAR EL TEXTO de una pregunta
--     Lo más común. No afecta los registros ya guardados.
-- ============================================================

-- update preguntas
--    set pregunta = 'Nuevo texto de la pregunta'
--  where id = 'PRE_012';

-- Cambiar también la ayuda que aparece debajo:
-- update preguntas
--    set pregunta = 'Nuevo texto',
--        ayuda    = 'Aclaración que se muestra en letra pequeña'
--  where id = 'PRE_012';


-- ============================================================
--  2) HACER una pregunta obligatoria u opcional
-- ============================================================

-- update preguntas set obligatorio = true  where id = 'PRE_012';
-- update preguntas set obligatorio = false where id = 'PRE_012';


-- ============================================================
--  3) QUITAR una pregunta
--     Se DESACTIVA, no se borra: así se conserva el histórico de
--     lo que ya respondieron con ella.
-- ============================================================

-- update preguntas set activo = false where id = 'PRE_012';

-- Para volver a mostrarla:
-- update preguntas set activo = true where id = 'PRE_012';


-- ============================================================
--  4) REORDENAR
--     'orden' admite decimales, así que para meter una pregunta
--     entre la 12 y la 13 basta con ponerle 12.5.
-- ============================================================

-- update preguntas set orden = 12.5 where id = 'PRE_049';

-- Renumerar de a uno todo un formulario (opcional, deja los enteros limpios):
-- with n as (
--   select id, row_number() over (order by orden) r
--     from preguntas where formulario_id = 'PREOPERACIONAL' and activo
-- )
-- update preguntas p set orden = n.r from n where n.id = p.id;


-- ============================================================
--  5) AGREGAR una pregunta
--     tipo_respuesta admite:
--       texto        una línea
--       parrafo      varias líneas
--       numero       solo números
--       fecha        calendario
--       hora         la pone el sistema
--       si_no        lista SI / NO
--       desplegable  lista de opciones (ver punto 6)
--       checkbox     varias opciones marcables
--       archivo      foto o PDF
--
--     Sigue la numeración: si la última es PRE_048, la nueva es PRE_049.
-- ============================================================

-- insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
--                        obligatorio, orden, ayuda, activo)
-- values ('PRE_049', 'PREOPERACIONAL', 'Seguridad',
--         '¿El espejo retrovisor está completo y sin fisuras?',
--         'si_no', true, 49, 'Revisa ambos espejos.', true);

-- Con lista de opciones (usa un grupo existente, ver punto 6):
-- insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
--                        obligatorio, orden, grupo_opciones, activo)
-- values ('PRE_050', 'PREOPERACIONAL', 'Seguridad',
--         'Estado de la cadena', 'desplegable', true, 50,
--         'cumple_no_cumple_na', true);

-- Que pida foto:
-- insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
--                        obligatorio, orden, activo)
-- values ('PRE_051', 'PREOPERACIONAL', 'Evidencia',
--         'Foto del odómetro', 'archivo', true, 51, true);


-- ============================================================
--  6) LISTAS DE OPCIONES (para 'desplegable' y 'checkbox')
--     Grupos que ya existen:
--       si_no, cumple_no_cumple_na, categoria_licencia,
--       partes_moto, tipo_limpieza, veces_día, lipieza_moto
-- ============================================================

-- Ver las opciones de un grupo:
-- select valor, orden, activo from opciones
--  where grupo = 'cumple_no_cumple_na' order by orden;

-- Agregar una opción a un grupo existente:
-- insert into opciones (grupo, valor, orden, activo)
-- values ('cumple_no_cumple_na', 'No aplica hoy', 4, true);

-- Crear un grupo nuevo y usarlo en una pregunta:
-- insert into opciones (grupo, valor, orden, activo) values
--   ('estado_llanta', 'Buena',    1, true),
--   ('estado_llanta', 'Regular',  2, true),
--   ('estado_llanta', 'Cambiar',  3, true);
-- update preguntas set grupo_opciones = 'estado_llanta' where id = 'PRE_050';

-- Quitar una opción sin borrarla:
-- update opciones set activo = false
--  where grupo = 'estado_llanta' and valor = 'Regular';


-- ============================================================
--  7) PREGUNTA CONDICIONAL
--     Se muestra solo cuando otra tiene cierto valor.
--     Ejemplo actual: PRE_040 aparece cuando PRE_039 = 'SI'.
-- ============================================================

-- insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
--                        obligatorio, orden, depende_de, depende_valor, activo)
-- values ('PRE_052', 'PREOPERACIONAL', 'Seguridad',
--         '¿Cuál fue la falla que detectaste?', 'parrafo',
--         false, 52, 'PRE_051', 'NO', true);
--   → aparece solo si en PRE_051 responden NO


-- ============================================================
--  8) QUE UNA RESPUESTA GENERE ALERTA
--     El registro queda marcado y sale en el tablero de novedades.
-- ============================================================

-- update preguntas set respuesta_alerta = 'NO' where id = 'PRE_012';
--   → si responden NO, el registro nace con alerta

-- Exigir evidencia cuando la respuesta es la que preocupa:
-- update preguntas set evidencia_requerida_si = 'No cumple' where id = 'PRE_012';


-- ============================================================
--  9) QUE NO SE PRECARGUE del día anterior
--     Útil en observaciones y novedades del turno.
-- ============================================================

-- update preguntas set no_precargar = true where id = 'PRE_038';


-- ============================================================
--  10) CREAR UN FORMULARIO NUEVO — los cuatro pasos
-- ============================================================

-- 10.1 El formulario
-- insert into formularios (id, nombre, descripcion, activo, orden)
-- values ('INSPECCION_CASCO', 'Inspección del casco',
--         'Revisión mensual del estado del casco.', true, 3);

-- 10.2 Sus preguntas
-- insert into preguntas (id, formulario_id, seccion, pregunta, tipo_respuesta,
--                        obligatorio, orden, activo) values
--   ('CAS_001', 'INSPECCION_CASCO', 'Datos del registro',
--    'Fecha de la inspección', 'fecha', true, 1, true),
--   ('CAS_002', 'INSPECCION_CASCO', 'Estado',
--    '¿La visera está sin rayones que obstruyan la visión?', 'si_no', true, 2, true),
--   ('CAS_003', 'INSPECCION_CASCO', 'Estado',
--    '¿La correa cierra y sujeta firme?', 'si_no', true, 3, true),
--   ('CAS_004', 'INSPECCION_CASCO', 'Evidencia',
--    'Foto del casco puesto', 'archivo', true, 4, true);

-- 10.3 Habilitarlo en los proyectos que lo deben diligenciar.
--      IMPORTANTE: sin este paso el formulario NO se le exige a nadie
--      y no afecta el cumplimiento. Es la red de seguridad del sistema.
--      Se puede hacer desde Administración → Formularios, o aquí:
-- insert into proyectos_formularios (proyecto, formulario_id, activo)
-- select distinct proyecto, 'INSPECCION_CASCO', true
--   from colaboradores where activo and coalesce(proyecto,'') <> ''
-- on conflict (proyecto, formulario_id) do update set activo = true;

--      Solo para un proyecto:
-- insert into proyectos_formularios (proyecto, formulario_id, activo)
-- values ('HEEL COLOMBIA LTDA CC 220509220239', 'INSPECCION_CASCO', true)
-- on conflict (proyecto, formulario_id) do update set activo = true;

-- 10.4 Comprobar cómo quedó
-- select id, orden, seccion, pregunta, tipo_respuesta
--   from preguntas where formulario_id = 'INSPECCION_CASCO' order by orden;


-- ============================================================
--  11) DESACTIVAR un formulario completo
-- ============================================================

-- update formularios set activo = false where id = 'INSPECCION_CASCO';

-- O quitárselo solo a un proyecto (mejor desde Administración → Formularios):
-- update proyectos_formularios set activo = false
--  where proyecto = 'ADIDAS CC 220508210002' and formulario_id = 'LIMPIEZA_MOTO';


-- ============================================================
--  ANTES DE EJECUTAR, TEN EN CUENTA
--  • Supabase corre todo el script como UNA transacción: si algo falla
--    a mitad, no queda nada aplicado. No hay riesgo de dejarlo a medias.
--  • Los cambios se ven de inmediato, sin publicar nada.
--    Si un mensajero ya tenía el formulario abierto, debe recargarlo.
--  • Nunca borres preguntas con DELETE: desactívalas. Borrarlas rompe
--    el histórico de los registros que las respondieron.
--  • Al agregar una pregunta obligatoria, los registros de días
--    anteriores no se ven afectados.
-- ============================================================
