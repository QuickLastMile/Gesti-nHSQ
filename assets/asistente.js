/* ============================================================
   QUICKY — Asistente de ayuda de Gestión HSEQ Motos
   ------------------------------------------------------------
   No usa inteligencia artificial: reconoce palabras clave y
   responde con la guía correspondiente. Cuando algo depende del
   proyecto o del formulario, lo pregunta y arma la respuesta.

   Se integra con una sola línea al final de cualquier página:
     <script src="assets/asistente.js?v=1"></script>
   ============================================================ */
(function () {
  'use strict';

  var BASE = (function () {
    var s = document.currentScript && document.currentScript.src;
    return s ? s.replace(/assets\/asistente\.js.*$/, '') : '';
  })();

  /* ---------- utilidades de texto ---------- */
  function normalizar(t) {
    return String(t || '')
      .toLowerCase()
      .normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/[^a-z0-9ñ\s]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function esc(t) {
    return String(t == null ? '' : t)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /* ============================================================
     BASE DE CONOCIMIENTO
     k  = palabras o frases que disparan la respuesta
     r  = respuesta (admite <b> y <br>)
     c  = sugerencias que se ofrecen después
     pide = 'proyecto' | 'formulario' → hace una repregunta
     r2 = respuesta final usando lo que contestó el usuario
     ============================================================ */
  var INTENTS = [

    /* ---------- saludo y generales ---------- */
    { id: 'saludo', peso: 0.9,
      k: ['hola', 'buenas', 'buenos dias', 'buenas tardes', 'buenas noches', 'hey', 'que tal', 'saludos'],
      r: '¡Hola! Soy <b>Quicky</b>, el asistente de Gestión HSEQ Motos.<br><br>Puedo indicarte dónde está cada cosa y cómo hacerla. ¿Qué necesitas?',
      c: ['¿Dónde está el dashboard?', '¿Cómo veo el cumplimiento?', '¿Quién no ha marcado?', 'Justificar una ausencia'] },

    { id: 'ayuda', peso: 0.8,
      k: ['ayuda', 'ayudame', 'que puedes hacer', 'que sabes', 'opciones', 'menu', 'no se que preguntar', 'para que sirves', 'que haces'],
      r: 'Te ayudo con todo lo de la plataforma. Los temas más consultados:<br><br>• <b>Dashboard</b> e indicadores<br>• <b>Cumplimiento</b>: quién marcó y quién no<br>• <b>Justificaciones</b>: incapacidad, permiso, vacaciones<br>• <b>Documentos</b>: SOAT, tecnomecánica, licencia<br>• <b>Registro diario</b> del mensajero<br>• <b>Administración</b>: matriz, días laborales, formularios<br><br>Escríbeme con tus palabras, yo te entiendo.',
      c: ['Ver el dashboard', 'Cumplimiento de un proyecto', 'Registrar una incapacidad', 'Un documento vencido'] },

    { id: 'gracias', peso: 0.9,
      k: ['gracias', 'muchas gracias', 'listo gracias', 'perfecto gracias', 'vale gracias', 'ok gracias'],
      r: 'Con gusto. Aquí estoy si necesitas algo más.',
      c: ['Ver el dashboard', '¿Quién no ha marcado hoy?'] },

    { id: 'que_es', peso: 0.7,
      k: ['que es esto', 'que es esta app', 'para que sirve la app', 'de que se trata', 'que es la plataforma', 'que es gestion hseq'],
      r: '<b>Gestión HSEQ Motos</b> reemplaza los formularios de Google para el control diario de la flota.<br><br>El mensajero registra desde el celular su <b>preoperacional</b> y su <b>limpieza y desinfección</b>; el coordinador ve quién cumplió y justifica ausencias; HSEQ administra la matriz y la configuración; y la dirección consulta los indicadores en el dashboard.',
      c: ['¿Cuáles son los módulos?', 'Ver el dashboard'] },

    { id: 'modulos', peso: 0.7,
      k: ['modulos', 'que modulos', 'partes de la app', 'secciones', 'paginas', 'cuantas paginas'],
      r: 'Hay cuatro módulos:<br><br>1. <b>Mensajero</b> — registro diario, sin usuario ni contraseña<br>2. <b>Coordinador</b> — cumplimiento, justificaciones y exportables<br>3. <b>Administración HSEQ</b> — matriz, días laborales y formularios<br>4. <b>Dashboard</b> — indicadores para la dirección',
      c: ['Abrir el dashboard', 'Abrir coordinador', 'Abrir administración'] },

    /* ---------- navegación ---------- */
    { id: 'dashboard', peso: 1.2,
      k: ['dashboard', 'tablero', 'donde esta el dashboard', 'indicadores', 'estadisticas', 'graficas', 'grafico', 'analitica', 'resumen ejecutivo', 'kpi'],
      r: 'El <b>dashboard</b> está en la barra superior del panel de coordinador, botón <b>Dashboard</b>.<br><br>Tiene cuatro vistas en el menú de la izquierda:<br>• <b>Resumen</b> — activos, registros, cumplimiento y novedades<br>• <b>Cumplimiento</b> — ranking por proyecto y por mensajero<br>• <b>Operación</b> — hábitos de registro y novedades<br>• <b>Documentos</b> — vencidos y próximos a vencer',
      link: 'dashboard.html', linkTxt: 'Abrir el dashboard',
      c: ['¿Cómo filtro por proyecto?', '¿Cómo exporto el dashboard?', 'Ver documentos por vencer'] },

    { id: 'coordinador', peso: 1.1,
      k: ['coordinador', 'panel coordinador', 'donde entro como coordinador', 'pagina del coordinador'],
      r: 'El <b>panel de coordinador</b> tiene dos pestañas:<br><br>• <b>Exportar</b> — descargar la información a Excel y actualizar la matriz<br>• <b>Cumplimiento</b> — ver quién marcó, quién no, y justificar',
      link: 'coordinador.html', linkTxt: 'Abrir coordinador',
      c: ['¿Quién no ha marcado?', 'Descargar la información'] },

    { id: 'admin', peso: 1.1,
      k: ['administracion', 'admin', 'panel hseq', 'configuracion', 'configurar', 'ajustes', 'parametrizar'],
      r: 'El <b>panel de Administración HSEQ</b> tiene tres pestañas:<br><br>• <b>Colaboradores</b> — activar, inactivar, placa y documentos<br>• <b>Calendario</b> — días laborales y meta por proyecto<br>• <b>Formularios</b> — qué formulario aplica a cada proyecto',
      link: 'admin.html', linkTxt: 'Abrir administración',
      c: ['Activar o inactivar un mensajero', 'Cambiar los días laborales', 'Cambiar la meta'] },

    { id: 'link_mensajero', peso: 1.0,
      k: ['link del mensajero', 'enlace mensajero', 'donde registran los mensajeros', 'pagina del mensajero', 'link para registrar', 'donde diligencian'],
      r: 'Los mensajeros registran en la página <b>Registrar</b>. No necesitan usuario ni contraseña: solo digitan su cédula.<br><br>Comparte ese enlace por WhatsApp y pídeles guardarlo en la pantalla de inicio del celular.',
      link: 'mensajero.html', linkTxt: 'Abrir el registro del mensajero',
      c: ['¿Cómo registra el mensajero?', 'No aparece mi cédula'] },

    /* ---------- cumplimiento ---------- */
    { id: 'cumplimiento', peso: 1.2,
      k: ['cumplimiento', 'porcentaje', 'como veo el cumplimiento', 'nivel de cumplimiento', 'indicador de cumplimiento', 'como va el cumplimiento'],
      r: 'Puedes verlo en dos lugares:<br><br>• <b>Coordinador → Cumplimiento</b>: el detalle del día, persona por persona<br>• <b>Dashboard → Cumplimiento</b>: el ranking por proyecto y por mensajero, con el semáforo contra la meta<br><br>El cálculo descuenta las ausencias justificadas y respeta los días laborales de cada proyecto.',
      c: ['¿Quién no ha marcado?', '¿Cómo se calcula el cumplimiento?', 'Cambiar la meta'] },

    { id: 'no_marcaron', peso: 1.4, pide: 'proyecto',
      k: ['quien no ha marcado', 'no han marcado', 'no marcaron', 'no ha marcado', 'sin marcar', 'sin registrar', 'quienes no marcaron', 'que mensajeros no', 'quien no marco', 'quienes faltan', 'no han diligenciado', 'quien falta por registrar', 'pendientes', 'quien no registro', 'faltantes', 'no diligenciaron', 'quien no ha diligenciado', 'mensajeros pendientes'],
      r: 'Te lo muestro en <b>Coordinador → Cumplimiento</b>.<br><br>¿De qué proyecto quieres verlo? Escribe el nombre (o responde <b>todos</b>).',
      r2: function (v) {
        var todos = /^(todos|todo|ninguno|general|na)$/.test(normalizar(v));
        return 'Listo. Haz esto:<br><br>1. Entra a <b>Coordinador → Cumplimiento</b><br>2. Elige la <b>fecha</b> que quieres revisar<br>3. En <b>Proyecto</b> ' +
          (todos ? 'déjalo vacío para ver todos' : 'escribe <b>' + esc(v) + '</b> y selecciónalo de la lista') +
          '<br>4. Presiona <b>Consultar</b><br><br>Verás cuatro grupos: <b>Completos</b>, <b>Pendientes</b>, <b>Justificados</b> y los que <b>requieren gestión</b>. Toca <b>Pendientes</b> para ver solo a los que faltan.';
      },
      link: 'coordinador.html', linkTxt: 'Abrir cumplimiento',
      c: ['Justificar a los pendientes', 'Descargar la información'] },

    { id: 'ranking', peso: 1.0,
      k: ['ranking', 'cual proyecto cumple', 'que proyecto cumple', 'cual cumple mas', 'cumple mas', 'cumple menos', 'comparar', 'mejores', 'peores', 'mas juicioso', 'menos juicioso', 'quien cumple mas', 'quien cumple menos', 'top', 'comparar proyectos'],
      r: 'En <b>Dashboard → Cumplimiento</b> encuentras dos rankings:<br><br>• Por <b>proyecto</b>, con el semáforo contra la meta<br>• Por <b>mensajero</b>, de mayor a menor cumplimiento<br><br>Sirve para reconocer a los que cumplen y para gestionar a los que no.',
      link: 'dashboard.html', linkTxt: 'Ver el ranking',
      c: ['¿Cómo se calcula el cumplimiento?'] },

    { id: 'como_calcula', peso: 1.0,
      k: ['como se calcula', 'como calcula el cumplimiento', 'de donde sale el porcentaje', 'la formula', 'que son los esperados', 'como se mide'],
      r: 'Se compara lo <b>realizado</b> contra lo <b>esperado</b>:<br><br>• <b>Esperado</b> = colaboradores activos × días que el proyecto labora × formularios habilitados<br>• Se <b>descuentan</b> los días con justificación (incapacidad, permiso, vacaciones…)<br>• No se cuentan domingos ni festivos, salvo que el proyecto los tenga habilitados<br><br>Por eso es importante mantener el calendario y las justificaciones al día.',
      c: ['Cambiar los días laborales', 'Justificar una ausencia'] },

    /* ---------- justificaciones ---------- */
    { id: 'justificar', peso: 1.3,
      k: ['justificar', 'justificacion', 'como justifico', 'novedad de un colaborador', 'no laboro', 'no trabajo ese dia', 'excusa', 'ausencia'],
      r: 'Para justificar a alguien que no laboró:<br><br>1. <b>Coordinador → Cumplimiento</b><br>2. Consulta la fecha y el proyecto<br>3. Busca a la persona y presiona <b>Justificar</b><br>4. Elige el <b>tipo</b> y guarda<br><br>Los tipos disponibles son: <b>Incapacidad</b>, <b>Descanso</b>, <b>Permiso</b>, <b>Vacaciones</b>, <b>Suspensión</b> y <b>Renuncia</b>.<br><br>Esos días dejan de exigirse y el cumplimiento se recalcula solo.',
      link: 'coordinador.html', linkTxt: 'Ir a justificar',
      c: ['Justificar una incapacidad', 'Justificar vacaciones', '¿Puedo justificar días pasados?'] },

    { id: 'incapacidad', peso: 1.4,
      k: ['incapacidad', 'incapacitado', 'esta enfermo', 'eps', 'medico', 'licencia medica', 'esta incapacitado'],
      r: 'La <b>Incapacidad</b> se registra así:<br><br>1. <b>Coordinador → Cumplimiento</b>, consulta la fecha y el proyecto<br>2. En la persona, presiona <b>Justificar</b><br>3. Tipo: <b>Incapacidad (elegir días)</b><br>4. Marca <b>Desde</b> y <b>Hasta</b> según lo que diga la incapacidad<br>5. En la observación puedes anotar el número de la incapacidad o la EPS<br><br>Todos esos días quedan descontados del cumplimiento de una sola vez.',
      link: 'coordinador.html', linkTxt: 'Registrar la incapacidad',
      c: ['Justificar vacaciones', '¿Puedo justificar días pasados?'] },

    { id: 'vacaciones', peso: 1.2,
      k: ['vacaciones', 'esta de vacaciones', 'periodo de vacaciones'],
      r: 'Tipo <b>Vacaciones (elegir días)</b> en la ventana de justificación, marcando el rango completo <b>Desde</b> y <b>Hasta</b>. Con una sola justificación quedan cubiertos todos los días.',
      c: ['Registrar una incapacidad', 'Justificar un permiso'] },

    { id: 'permiso', peso: 1.2,
      k: ['permiso', 'calamidad', 'cita medica', 'diligencia', 'dia libre'],
      r: 'Tipo <b>Permiso (elegir días)</b>. Si es un solo día, pon la misma fecha en <b>Desde</b> y <b>Hasta</b>. Conviene escribir el motivo en la observación para dejar el soporte.',
      c: ['Registrar una incapacidad', 'Justificar un descanso'] },

    { id: 'descanso', peso: 1.2,
      k: ['descanso', 'dia de descanso', 'compensatorio', 'franco'],
      r: 'Tipo <b>Descanso</b>. Aplica al día que estás consultando, así que no pide rango de fechas. Úsalo para el descanso rotativo de la operación.',
      c: ['Cambiar los días laborales del proyecto'] },

    { id: 'renuncia', peso: 1.2,
      k: ['renuncia', 'renuncio', 'se retiro', 'ya no trabaja', 'retiro', 'lo despidieron', 'termino contrato'],
      r: 'Tipo <b>Renuncia</b>: además de justificar, <b>inactiva a la persona</b> para que deje de exigírsele registro desde ese día.<br><br>Si fue un retiro por otra causa, puedes inactivarlo también desde <b>Administración → Colaboradores</b>.',
      c: ['Inactivar un colaborador'] },

    { id: 'suspension', peso: 1.1,
      k: ['suspension', 'suspendido', 'sancion', 'suspender'],
      r: 'Tipo <b>Suspensión (elegir fechas)</b>, marcando el rango. Los días quedan fuera del cálculo mientras dure la medida.',
      c: ['Justificar una incapacidad'] },

    { id: 'justificar_pasado', peso: 1.0,
      k: ['dias pasados', 'retroactivo', 'fecha anterior', 'ayer', 'la semana pasada', 'mes pasado', 'justificar despues', 'atrasado'],
      r: 'Sí. En <b>Cumplimiento</b> consulta la <b>fecha</b> que necesitas —aunque ya haya pasado— y justifica desde ahí. También puedes usar un rango <b>Desde/Hasta</b> hacia atrás.<br><br>El indicador se recalcula de inmediato, incluso para periodos ya cerrados.',
      c: ['Registrar una incapacidad'] },

    /* ---------- exportar ---------- */
    { id: 'exportar', peso: 1.3, pide: 'formulario',
      k: ['exportar', 'descargar', 'excel', 'csv', 'sacar la informacion', 'bajar los datos', 'reporte', 'informe', 'exportable', 'archivo'],
      r: 'La descarga se hace en <b>Coordinador → Exportar</b>.<br><br>¿Cuál formulario necesitas: <b>preoperacional</b> o <b>limpieza</b>?',
      r2: function (v) {
        var n = normalizar(v);
        var lim = /limpieza|desinfec|aseo|lavado/.test(n);
        var f = lim ? 'Limpieza y desinfección de la moto' : 'Registro diario preoperacional';
        return 'Perfecto. En <b>Coordinador → Exportar</b>:<br><br>1. En <b>Formulario</b> elige <b>' + f + '</b><br>2. Marca la <b>fecha inicial</b> y la <b>fecha final</b><br>3. Si quieres, filtra por <b>proyecto</b> o por <b>cédula</b><br>4. Presiona <b>Generar exportable</b> y luego <b>Descargar CSV</b><br><br>El archivo se abre en Excel e incluye los enlaces de las evidencias.<br><br><i>Se exporta un formulario a la vez porque cada uno tiene columnas distintas.</i>';
      },
      link: 'coordinador.html', linkTxt: 'Ir a exportar',
      c: ['¿Puedo exportar el dashboard?', 'Ver las fotos de un registro'] },

    { id: 'exportar_dash', peso: 1.0,
      k: ['exportar el dashboard', 'descargar el dashboard', 'dashboard en pdf', 'dashboard en excel', 'imprimir el dashboard'],
      r: 'Sí. En la esquina superior derecha del dashboard están los botones <b>Excel</b> y <b>PDF</b>. Descargan la vista con los filtros que tengas puestos, lista para llevar a comité.',
      link: 'dashboard.html', linkTxt: 'Abrir el dashboard',
      c: ['¿Cómo filtro por proyecto?'] },

    { id: 'evidencias', peso: 1.1,
      k: ['fotos', 'evidencias', 'ver las fotos', 'imagenes', 'soportes', 'ver evidencia', 'donde quedan las fotos', 'adjuntos'],
      r: 'Las fotos quedan guardadas con cada registro.<br><br>• En el <b>exportable</b> viene el enlace de cada evidencia<br>• En <b>Administración → Colaboradores</b> ves los documentos del vehículo de cada persona<br><br>Las imágenes no son públicas: se abren con un enlace temporal desde el panel autorizado.',
      c: ['Descargar la información', 'Ver documentos de un colaborador'] },

    /* ---------- documentos ---------- */
    { id: 'documentos', peso: 1.2,
      k: ['documentos', 'soat', 'tecnomecanica', 'tecno mecanica', 'licencia', 'vencimiento', 'vencido', 'vence', 'por vencer', 'vigencia'],
      r: 'El control documental está en <b>Dashboard → Documentos</b>. Puedes filtrar por:<br><br>• <b>Vencidos</b> — ya pasaron la fecha<br>• <b>Próximos a vencer</b> — dentro de los siguientes 15 días<br>• <b>Sin fecha</b> — no tienen vigencia registrada<br><br>El sistema alerta <b>15 días antes</b> del vencimiento, para gestionar la renovación a tiempo.',
      link: 'dashboard.html', linkTxt: 'Ver documentos',
      c: ['¿Cómo actualizo el SOAT?', '¿Un vencido bloquea el registro?'] },

    { id: 'actualizar_doc', peso: 1.3,
      k: ['actualizar soat', 'actualizo el soat', 'como actualizo', 'actualizar el soat', 'renovar', 'renovacion', 'subir el soat', 'cambiar la fecha del soat', 'actualizar tecnomecanica', 'nuevo soat', 'como subo el documento', 'cargar documento'],
      r: 'Lo hace el propio mensajero desde su registro:<br><br>1. Entra a <b>Registrar</b> y abre el <b>preoperacional</b><br>2. En la primera pregunta responde <b>SÍ</b> a «¿Es la primera inspección o realizó renovación?»<br>3. Se abre el bloque de documentos: adjunta el archivo y escribe la <b>nueva fecha de vencimiento</b><br>4. Guarda<br><br>La matriz se actualiza sola y el documento anterior se reemplaza.<br><br><b>Importante:</b> el SOAT y la tecnomecánica se adjuntan en <b>PDF</b>.',
      c: ['¿Por qué solo PDF?', '¿Un vencido bloquea el registro?'] },

    { id: 'solo_pdf', peso: 1.2,
      k: ['pdf', 'solo pdf', 'por que pdf', 'no me deja subir la foto del soat', 'formato del documento', 'no acepta la imagen'],
      r: 'El <b>SOAT</b> y la <b>tecnomecánica</b> se suben únicamente en <b>PDF</b>, porque es el archivo que entregan al expedirlos y así se lee completo y sin problemas.<br><br>Si solo tienes la foto, conviértela a PDF desde el celular (en la app de archivos o con cualquier app de escáner) y súbela.<br><br>La <b>licencia de tránsito</b> sí va como dos fotos: frente y reverso.',
      c: ['¿Cómo actualizo el SOAT?'] },

    { id: 'vencido_bloquea', peso: 1.1,
      k: ['bloquea', 'me bloquea', 'no me deja por el soat', 'documento vencido bloquea', 'puedo registrar con el soat vencido'],
      r: 'Un documento <b>vencido no bloquea</b> el registro: el mensajero puede seguir trabajando, pero el registro queda marcado <b>con alerta</b> y aparece en el tablero para gestión.<br><br>Lo que sí impide guardar es <b>no tener el documento cargado</b>. En ese caso debe adjuntarlo primero.',
      c: ['¿Cómo actualizo el SOAT?', 'Ver documentos vencidos'] },

    /* ---------- registro del mensajero ---------- */
    { id: 'como_registra', peso: 1.1,
      k: ['como registra', 'como se diligencia', 'como lleno el formulario', 'como hago el preoperacional', 'como marco', 'proceso del mensajero'],
      r: 'El mensajero:<br><br>1. Abre la página <b>Registrar</b><br>2. Digita su <b>cédula</b> y presiona buscar<br>3. Ve sus formularios del día y toca el que está pendiente<br>4. Responde, adjunta la foto y guarda<br><br>La fecha y la hora las pone el sistema. Al terminar los dos formularios recibe un <b>comprobante</b> descargable.',
      link: 'mensajero.html', linkTxt: 'Abrir el registro',
      c: ['No aparece mi cédula', 'Ya registré hoy y quiero corregir'] },

    { id: 'no_aparece_cedula', peso: 1.3,
      k: ['no aparece mi cedula', 'no encuentra la cedula', 'cedula no encontrada', 'no me deja entrar con la cedula', 'no estoy en el sistema', 'no aparece el mensajero', 'no me reconoce'],
      r: 'Puede ser por dos motivos:<br><br>• La persona <b>no está en la matriz</b> — hay que actualizarla con el reporte de nómina desde <b>Coordinador → Actualizar matriz</b><br>• Está <b>inactiva</b> — se activa en <b>Administración → Colaboradores</b>, buscando por cédula<br><br>Verifica también que la cédula esté escrita sin puntos ni espacios.',
      c: ['Actualizar la matriz', 'Activar un colaborador'] },

    { id: 'ya_registre', peso: 1.2,
      k: ['ya registre', 'ya diligencie', 'me equivoque', 'error en el registro', 'corregir un registro', 'volver a registrar', 'registrar dos veces', 'duplicado', 'anular'],
      r: 'Solo se permite <b>un registro por día y por formulario</b>, para que nadie duplique.<br><br>Si quedó mal diligenciado, el coordinador puede <b>anularlo</b> desde <b>Coordinador → Exportar</b>, en «Administrar registros consultados». Queda el rastro de quién lo anuló y por qué; después la persona puede registrar de nuevo.',
      link: 'coordinador.html', linkTxt: 'Ir a anular',
      c: ['Descargar la información'] },

    { id: 'placa', peso: 1.2,
      k: ['placa', 'cambiar placa', 'cambio de moto', 'otra moto', 'moto prestada', 'placa equivocada', 'registrar la placa'],
      r: 'La placa queda guardada la primera vez y no se vuelve a pedir.<br><br>Para cambiarla: en la página <b>Registrar</b>, después de buscar la cédula, presiona <b>Cambiar placa</b>, escribe la nueva y el <b>motivo</b> (es obligatorio). El cambio queda en el historial.<br><br>HSEQ también puede corregirla desde <b>Administración → Colaboradores</b>.',
      c: ['Abrir el registro del mensajero'] },

    { id: 'precarga', peso: 1.1,
      k: ['precarga', 'precargadas', 'salen llenas', 'aparecen llenas', 'ya estan respondidas', 'vienen respondidas', 'respuestas guardadas', 'aparecen las respuestas', 'ya vienen llenas', 'no tengo que responder todo', 'respuestas anteriores', 'se llena solo'],
      r: 'Sí, es una función nueva: al abrir el formulario aparecen las <b>respuestas del último registro</b>, con la fecha de la que vienen.<br><br>El mensajero <b>revisa</b>, corrige solo lo que cambió y guarda. Lo corregido queda como base para el día siguiente.<br><br>Las <b>fotos nunca se precargan</b>: hay que tomarlas cada día.',
      c: ['¿Cómo registra el mensajero?'] },

    { id: 'error_adjuntar', peso: 1.3,
      k: ['no puedo adjuntar', 'error al adjuntar', 'no sube la foto', 'no me deja subir', 'no carga la imagen', 'problema con la foto', 'la foto no carga', 'no me deja guardar la evidencia', 'falla al subir'],
      r: 'Revisa estas tres cosas:<br><br>1. <b>SOAT y tecnomecánica</b> van en <b>PDF</b>; las demás evidencias, en foto<br>2. El archivo no puede pesar más de <b>12 MB</b><br>3. Si la carga se queda pegada, suele ser la señal: intenta con wifi o vuelve a intentarlo en un momento<br><br>Si sigue fallando, avísale a HSEQ con el nombre del mensajero y la hora del intento.',
      c: ['¿Por qué solo PDF?', 'Contactar a HSEQ'] },

    { id: 'no_guarda', peso: 1.2,
      k: ['no me deja guardar', 'no guarda', 'error al guardar', 'no se guarda el registro', 'da error', 'sale error', 'me sale un error'],
      r: 'Lo más frecuente:<br><br>• Falta una <b>pregunta obligatoria</b> — el mensaje de abajo te dice cuál<br>• Falta <b>adjuntar</b> una evidencia obligatoria<br>• <b>Ya registraste</b> ese formulario hoy<br>• La sesión expiró (en los paneles con login): vuelve a entrar<br><br>El aviso rojo al final del formulario indica exactamente qué falta.',
      c: ['Ya registré hoy y quiero corregir', 'No puedo adjuntar la foto'] },

    { id: 'sin_internet', peso: 1.0,
      k: ['sin internet', 'internet', 'no tengo internet', 'sin señal', 'se fue la señal', 'sin datos', 'offline', 'no tengo conexion', 'se cayo la señal'],
      r: 'El registro necesita conexión para guardarse. Si no hay señal en el punto de entrega, el mensajero puede hacerlo apenas recupere datos o wifi, <b>el mismo día</b>.<br><br>Si el día se pasó sin registrar y hubo un motivo válido, el coordinador puede justificarlo.',
      c: ['Justificar una ausencia'] },

    /* ---------- administración ---------- */
    { id: 'activar', peso: 1.3,
      k: ['activar', 'inactivar', 'inactivo', 'inactiva', 'activo un mensajero', 'activo a', 'desactivar', 'dar de baja', 'quitar un mensajero', 'habilitar', 'deshabilitar', 'activar colaborador'],
      r: 'En <b>Administración → Colaboradores</b>:<br><br>1. Busca por <b>cédula</b> o por nombre<br>2. Cambia el estado a <b>activo</b> o <b>inactivo</b><br>3. Si lo inactivas, escribe el <b>motivo</b> (restricción, incapacidad larga, retiro…)<br><br>A los inactivos no se les exige registro y no afectan el cumplimiento.',
      link: 'admin.html', linkTxt: 'Abrir colaboradores',
      c: ['Actualizar la matriz', 'Ver documentos de un colaborador'] },

    { id: 'matriz', peso: 1.2,
      k: ['matriz', 'actualizar matriz', 'nomina', 'personal nuevo', 'ingresos', 'nuevos mensajeros', 'agregar personal', 'subir la nomina'],
      r: 'En <b>Coordinador → Actualizar matriz de activos</b>:<br><br>1. Copia el <b>export de nómina completo</b> desde Excel, <b>con la fila de títulos</b><br>2. Pégalo en el recuadro<br>3. Presiona <b>Actualizar matriz</b><br><br>El sistema agrega a los nuevos, inactiva a los que ya no aparecen y <b>conserva</b> placas, documentos y observaciones de los que siguen.',
      link: 'coordinador.html', linkTxt: 'Ir a actualizar matriz',
      c: ['Activar un colaborador', 'No aparece mi cédula'] },

    { id: 'dias_laborales', peso: 1.3,
      k: ['dias laborales', 'domingos', 'festivos', 'dias que labora', 'calendario', 'trabaja domingo', 'no trabajamos sabado', 'dias habiles', 'que dias'],
      r: 'En <b>Administración → Calendario</b>:<br><br>1. Busca el proyecto<br>2. Marca los días que <b>sí</b> opera (lunes a domingo)<br>3. Activa <b>Festivos</b> si trabaja en días festivos<br>4. Presiona <b>Guardar</b><br><br>Por defecto todos quedan de <b>lunes a sábado</b>. Los días no marcados dejan de exigirse y el cumplimiento se recalcula.',
      link: 'admin.html', linkTxt: 'Abrir calendario',
      c: ['Cambiar la meta', '¿Cómo se calcula el cumplimiento?'] },

    { id: 'meta', peso: 1.2,
      k: ['meta', 'cambiar la meta', 'objetivo', '90', 'semaforo', 'porcentaje objetivo'],
      r: 'Cada proyecto tiene su <b>meta</b>, configurable en <b>Administración → Calendario</b>, en la casilla <b>Meta %</b> al lado de los días.<br><br>Por defecto es <b>90%</b>. Es la que enciende el semáforo del dashboard: verde si cumple, ámbar si está cerca, rojo si no.',
      link: 'admin.html', linkTxt: 'Cambiar la meta',
      c: ['Ver el ranking por proyecto'] },

    { id: 'formularios_proyecto', peso: 1.3,
      k: ['formularios por proyecto', 'quitar el formulario', 'quitar un formulario', 'formulario de limpieza', 'desactivar el formulario', 'que formulario aplica', 'quitar un formulario', 'no aplica limpieza', 'solo preoperacional', 'habilitar formulario', 'asignar formulario'],
      r: 'En <b>Administración → Formularios</b>:<br><br>1. Busca el proyecto<br>2. Marca o desmarca <b>Registro diario preoperacional</b> y <b>Limpieza y desinfección</b><br><br>Lo que quede desmarcado <b>no se le exige</b> a ese proyecto y no afecta su cumplimiento. Es útil cuando una operación no maneja limpieza de vehículos.',
      link: 'admin.html', linkTxt: 'Abrir formularios',
      c: ['¿Cómo se calcula el cumplimiento?'] },

    { id: 'cambiar_pregunta', peso: 1.1,
      k: ['cambiar una pregunta', 'agregar una pregunta', 'agregar pregunta', 'nueva pregunta', 'editar pregunta', 'quitar una pregunta', 'preguntas del formulario', 'cambiar el texto de la pregunta', 'editar preguntas', 'quitar pregunta', 'modificar el formulario', 'nueva pregunta', 'cambiar el orden'],
      r: 'Las preguntas viven en la base de datos, no en el código. Para agregar, cambiar el texto, el orden o desactivar una, se edita la tabla de <b>preguntas</b>.<br><br>Escríbele a quien administra la plataforma con el texto exacto, el tipo de respuesta (sí/no, lista, foto, texto) y en qué formulario va.',
      c: ['Contactar a HSEQ'] },

    { id: 'agregar_proyecto', peso: 1.1,
      k: ['nuevo proyecto', 'agregar proyecto', 'proyecto nuevo', 'cliente nuevo', 'nueva operacion'],
      r: 'Un proyecto nuevo aparece solo cuando entra personal suyo a la matriz.<br><br>1. Actualiza la matriz con la nómina que incluya a esos colaboradores<br>2. Ve a <b>Administración → Formularios</b> y habilítale los formularios<br>3. En <b>Calendario</b>, ajústale los días laborales y la meta<br><br>Sin el paso 2 no se le exige nada y su cumplimiento no se calcula.',
      c: ['Actualizar la matriz', 'Cambiar los días laborales'] },

    /* ---------- acceso ---------- */
    { id: 'acceso', peso: 1.2,
      k: ['no puedo entrar', 'contraseña', 'clave', 'olvide la clave', 'usuario', 'login', 'iniciar sesion', 'me saco', 'sesion expiro', 'no me deja ingresar'],
      r: 'Los paneles de <b>coordinador</b>, <b>administración</b> y <b>dashboard</b> piden correo y contraseña. Los mensajeros no necesitan cuenta.<br><br>• Si dice <b>sesión expirada</b>, vuelve a iniciar sesión: la sesión dura una hora<br>• Si olvidaste la contraseña o necesitas una cuenta nueva, pídesela al administrador de la plataforma<br><br>Por seguridad, las contraseñas no se comparten por chat.',
      c: ['¿Quién tiene acceso?'] },

    { id: 'roles', peso: 1.0,
      k: ['quien tiene acceso', 'roles', 'permisos', 'quien puede ver', 'quien entra'],
      r: 'Hay tres roles:<br><br>• <b>Coordinador</b> — cumplimiento, justificaciones y exportables de su operación<br>• <b>HSEQ</b> — todo lo anterior más la matriz y la configuración<br>• <b>Administrador</b> — acceso completo<br><br>El mensajero solo puede crear su propio registro: no ve información de nadie más.',
      c: ['No puedo entrar'] },

    { id: 'seguridad', peso: 0.9,
      k: ['seguridad', 'seguro', 'datos', 'privacidad', 'quien ve mis datos', 'respaldo', 'backup', 'se pierde la informacion'],
      r: 'La información está en una base de datos propia de la compañía, con copias de seguridad automáticas.<br><br>• Ninguna tabla queda expuesta al navegador<br>• Las fotos son privadas y se abren con enlaces temporales<br>• Los cambios de placa, inactivaciones y actualizaciones quedan en un historial<br>• Las evidencias se conservan <b>365 días</b>',
      c: ['¿Quién tiene acceso?'] },

    /* ---------- soporte ---------- */
    { id: 'contacto', peso: 1.0,
      k: ['contacto', 'soporte', 'ayuda humana', 'con quien hablo', 'a quien le escribo', 'reportar un problema', 'no funciona', 'esta caido', 'hablar con alguien'],
      r: 'Si es algo que no puedo resolver aquí, escríbele al <b>área de HSEQ</b> con estos datos, para que lo revisen rápido:<br><br>• Nombre y <b>cédula</b> del mensajero<br>• <b>Fecha y hora</b> del intento<br>• Qué formulario estaba diligenciando<br>• El <b>mensaje de error</b> exacto que apareció',
      c: ['No puedo adjuntar la foto', 'No me deja guardar'] },

    { id: 'bot', peso: 0.8,
      k: ['quien eres', 'como te llamas', 'eres un robot', 'eres una ia', 'inteligencia artificial', 'chatgpt', 'bot'],
      r: 'Soy <b>Quicky</b>, el asistente de la plataforma. No soy inteligencia artificial: reconozco palabras clave y te doy la guía que corresponde.<br><br>Si no entiendo algo, dímelo con otras palabras o elige uno de los temas que te sugiero.',
      c: ['¿Qué puedes hacer?'] },

    { id: 'costo', peso: 0.8,
      k: ['costo', 'cuanto cuesta', 'licencia', 'precio', 'vale', 'pago'],
      r: 'La plataforma es <b>desarrollo propio</b>: no tiene costo de licenciamiento ni cobro por usuario. La infraestructura hoy opera sin costo y la proyección al crecer el volumen es de unos <b>USD 25 al mes</b>.',
      c: ['¿Qué es esta plataforma?'] }
  ];

  /* ---------- motor de coincidencias ----------
     La comparación es por palabra completa (admitiendo el plural), para que
     "formula" no se dé por encontrada dentro de "formulario". */
  var _re = {};
  function regexDe(k) {
    if (!_re[k]) {
      _re[k] = new RegExp('(^|\\s)' + k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(es|s)?($|\\s)');
    }
    return _re[k];
  }

  function puntuar(texto, intent) {
    var p = 0;
    for (var i = 0; i < intent.k.length; i++) {
      var k = intent.k[i];
      if (regexDe(k).test(texto)) p += 3 + k.split(' ').length;
    }
    return p * (intent.peso || 1);
  }

  function buscar(texto) {
    var t = normalizar(texto);
    if (!t) return null;
    var mejor = null, max = 0;
    for (var i = 0; i < INTENTS.length; i++) {
      var p = puntuar(t, INTENTS[i]);
      if (p > max) { max = p; mejor = INTENTS[i]; }
    }
    return max >= 2.5 ? mejor : null;
  }

  // Cuando no hay coincidencia clara: nunca "no sé", siempre una salida.
  function sugerenciasParecidas(texto) {
    var t = normalizar(texto), fuera = [];
    var pistas = [
      { re: /(quien|quienes|cuant)/, c: ['¿Quién no ha marcado?', 'Ver el ranking de cumplimiento'] },
      { re: /(donde|encuentro|ubica)/, c: ['¿Dónde está el dashboard?', 'Abrir coordinador'] },
      { re: /(como|puedo|hago)/, c: ['¿Cómo veo el cumplimiento?', '¿Cómo exporto la información?'] },
      { re: /(no|error|falla|problema)/, c: ['No me deja guardar', 'No puedo adjuntar la foto'] },
      { re: /(dia|fecha|mes|hoy)/, c: ['Justificar días pasados', 'Ver registros por día'] }
    ];
    for (var i = 0; i < pistas.length; i++) {
      if (pistas[i].re.test(t)) fuera = fuera.concat(pistas[i].c);
    }
    if (!fuera.length) {
      fuera = ['¿Dónde está el dashboard?', '¿Quién no ha marcado?', 'Justificar una ausencia', 'Descargar la información'];
    }
    return fuera.slice(0, 4);
  }

  /* ---------- interfaz ---------- */
  var abierto = false, pendiente = null, saludado = false;

  var css = ''
    + '#qk-bot,#qk-panel{position:fixed;z-index:9999;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}'
    + '#qk-bot{right:18px;bottom:18px;width:74px;height:74px;border:0;background:transparent;cursor:pointer;padding:0;'
    + 'animation:qk-flota 3.4s ease-in-out infinite;-webkit-tap-highlight-color:transparent}'
    + '#qk-bot:hover{animation-play-state:paused;transform:scale(1.08)}'
    + '#qk-bot img{width:100%;height:100%;object-fit:contain;filter:drop-shadow(0 6px 14px rgba(7,56,43,.35))}'
    + '#qk-bot::before{content:"";position:absolute;inset:8px;border-radius:50%;background:radial-gradient(circle,rgba(255,194,31,.45),transparent 68%);'
    + 'animation:qk-pulso 2.6s ease-in-out infinite;z-index:-1}'
    + '@keyframes qk-flota{0%,100%{transform:translateY(0)}50%{transform:translateY(-9px)}}'
    + '@keyframes qk-pulso{0%,100%{transform:scale(.85);opacity:.55}50%{transform:scale(1.15);opacity:.9}}'
    + '#qk-globo{position:fixed;right:96px;bottom:38px;z-index:9999;max-width:210px;background:#fff;color:#1b2b25;'
    + 'border:1px solid #d9e7e1;border-radius:14px;padding:10px 12px;font-size:13.5px;line-height:1.35;'
    + 'box-shadow:0 10px 26px rgba(7,56,43,.18);animation:qk-entra .3s ease}'
    + '#qk-globo b{color:#0d5c41}'
    + '#qk-globo::after{content:"";position:absolute;right:-7px;bottom:16px;width:12px;height:12px;background:#fff;'
    + 'border-right:1px solid #d9e7e1;border-top:1px solid #d9e7e1;transform:rotate(45deg)}'
    + '@keyframes qk-entra{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}'
    + '#qk-panel{right:18px;bottom:104px;width:352px;max-width:calc(100vw - 32px);height:min(520px,calc(100vh - 140px));'
    + 'background:#fff;border-radius:18px;box-shadow:0 18px 48px rgba(7,56,43,.28);display:none;flex-direction:column;overflow:hidden;'
    + 'border:1px solid #d9e7e1}'
    + '#qk-panel.abierto{display:flex;animation:qk-entra .22s ease}'
    + '#qk-head{background:#07382b;color:#fff;padding:13px 14px;display:flex;align-items:center;gap:10px;flex:0 0 auto}'
    + '#qk-head img{width:36px;height:36px;object-fit:contain}'
    + '#qk-head b{font-size:15px;display:block}'
    + '#qk-head span{font-size:11.5px;color:#a9c4ba}'
    + '#qk-cerrar{margin-left:auto;background:transparent;border:0;color:#a9c4ba;font-size:22px;cursor:pointer;line-height:1;padding:2px 6px}'
    + '#qk-cerrar:hover{color:#fff}'
    + '#qk-msgs{flex:1 1 auto;overflow-y:auto;padding:14px;background:#f4f8f5;display:flex;flex-direction:column;gap:10px}'
    + '.qk-m{max-width:88%;padding:10px 12px;border-radius:14px;font-size:13.5px;line-height:1.45}'
    + '.qk-bot{background:#fff;color:#243a32;border:1px solid #e2ece7;border-bottom-left-radius:5px;align-self:flex-start}'
    + '.qk-yo{background:#0d5c41;color:#fff;border-bottom-right-radius:5px;align-self:flex-end}'
    + '.qk-m b{color:inherit}.qk-bot b{color:#0d5c41}'
    + '.qk-link{display:inline-block;margin-top:9px;background:#0d5c41;color:#fff !important;text-decoration:none;'
    + 'padding:7px 12px;border-radius:9px;font-size:12.5px;font-weight:700}'
    + '.qk-link:hover{background:#12875f}'
    + '#qk-chips{flex:0 0 auto;padding:8px 12px 0;display:flex;flex-wrap:wrap;gap:6px;background:#f4f8f5}'
    + '.qk-chip{background:#fff;border:1px solid #cbe0d6;color:#0d5c41;border-radius:999px;padding:6px 11px;'
    + 'font-size:12px;cursor:pointer;font-weight:600;font-family:inherit}'
    + '.qk-chip:hover{background:#e4f4ec}'
    + '#qk-form{flex:0 0 auto;display:flex;gap:8px;padding:10px 12px;background:#f4f8f5;border-top:1px solid #e2ece7}'
    + '#qk-in{flex:1;border:1px solid #cbe0d6;border-radius:10px;padding:9px 11px;font-size:13.5px;font-family:inherit;outline:0;min-width:0}'
    + '#qk-in:focus{border-color:#12875f}'
    + '#qk-send{background:#0d5c41;color:#fff;border:0;border-radius:10px;width:40px;cursor:pointer;font-size:16px}'
    + '#qk-send:hover{background:#12875f}'
    // Cuando la página tiene barra inferior (botón Guardar), el asistente sube.
    + 'body.qk-subir #qk-bot{bottom:92px}body.qk-subir #qk-panel{bottom:176px}body.qk-subir #qk-globo{bottom:112px}'
    + '@media(max-width:640px){#qk-panel{right:10px;left:10px;width:auto;bottom:98px;height:min(70vh,460px)}'
    + '#qk-globo{display:none}#qk-bot{width:64px;height:64px;right:14px;bottom:14px}'
    + 'body.qk-subir #qk-panel{bottom:170px}}'
    + '@media(print){#qk-bot,#qk-panel,#qk-globo{display:none !important}}';

  function montar() {
    var st = document.createElement('style');
    st.textContent = css;
    document.head.appendChild(st);

    var btn = document.createElement('button');
    btn.id = 'qk-bot';
    btn.type = 'button';
    btn.setAttribute('aria-label', 'Abrir el asistente de ayuda');
    btn.innerHTML = '<img src="' + BASE + 'assets/bot-quick.png" alt="">';
    document.body.appendChild(btn);

    var panel = document.createElement('div');
    panel.id = 'qk-panel';
    panel.innerHTML =
      '<div id="qk-head">' +
        '<img src="' + BASE + 'assets/bot-quick.png" alt="">' +
        '<div><b>Quicky</b><span>Asistente de Gestión HSEQ</span></div>' +
        '<button id="qk-cerrar" type="button" aria-label="Cerrar">&times;</button>' +
      '</div>' +
      '<div id="qk-msgs"></div>' +
      '<div id="qk-chips"></div>' +
      '<form id="qk-form" autocomplete="off">' +
        '<input id="qk-in" placeholder="Escribe tu pregunta…" aria-label="Tu pregunta">' +
        '<button id="qk-send" type="submit" aria-label="Enviar">&#10148;</button>' +
      '</form>';
    document.body.appendChild(panel);

    btn.addEventListener('click', alternar);
    document.getElementById('qk-cerrar').addEventListener('click', alternar);
    document.getElementById('qk-form').addEventListener('submit', function (e) {
      e.preventDefault();
      var v = document.getElementById('qk-in').value.trim();
      if (!v) return;
      document.getElementById('qk-in').value = '';
      preguntar(v);
    });

    // La página del mensajero tiene barra inferior con el botón Guardar:
    // mientras esté visible, el asistente se corre hacia arriba.
    var barra = document.getElementById('bottombar');
    if (barra) {
      var ajustar = function () {
        document.body.classList.toggle('qk-subir', !barra.classList.contains('hidden'));
      };
      ajustar();
      new MutationObserver(ajustar).observe(barra, { attributes: true, attributeFilter: ['class'] });
    }

    // Saludo discreto la primera vez que se abre la página.
    setTimeout(function () {
      if (abierto || sessionStorage.getItem('qk-visto')) return;
      var g = document.createElement('div');
      g.id = 'qk-globo';
      g.innerHTML = '¿Necesitas ayuda? Soy <b>Quicky</b>, pregúntame lo que sea de la plataforma.';
      document.body.appendChild(g);
      g.addEventListener('click', alternar);
      setTimeout(function () { if (g.parentNode) g.remove(); }, 9000);
    }, 2600);
  }

  function alternar() {
    var p = document.getElementById('qk-panel');
    abierto = !abierto;
    p.classList.toggle('abierto', abierto);
    var g = document.getElementById('qk-globo');
    if (g) g.remove();
    if (abierto) {
      sessionStorage.setItem('qk-visto', '1');
      if (!saludado) {
        saludado = true;
        decir('¡Hola! Soy <b>Quicky</b> 👋<br>Te ayudo a encontrar cualquier cosa en la plataforma. Pregúntame con tus palabras.');
        chips(['¿Dónde está el dashboard?', '¿Quién no ha marcado hoy?', 'Registrar una incapacidad', 'Descargar la información']);
      }
      var i = document.getElementById('qk-in');
      if (window.innerWidth > 640) setTimeout(function () { i.focus(); }, 120);
    }
  }

  function decir(html, link, linkTxt) {
    var m = document.createElement('div');
    m.className = 'qk-m qk-bot';
    m.innerHTML = html + (link ? '<br><a class="qk-link" href="' + BASE + link + '">' + esc(linkTxt || 'Abrir') + '</a>' : '');
    var c = document.getElementById('qk-msgs');
    c.appendChild(m);
    c.scrollTop = c.scrollHeight;
  }

  function decirYo(t) {
    var m = document.createElement('div');
    m.className = 'qk-m qk-yo';
    m.textContent = t;
    var c = document.getElementById('qk-msgs');
    c.appendChild(m);
    c.scrollTop = c.scrollHeight;
  }

  function chips(lista) {
    var cont = document.getElementById('qk-chips');
    cont.innerHTML = '';
    (lista || []).forEach(function (t) {
      var b = document.createElement('button');
      b.className = 'qk-chip';
      b.type = 'button';
      b.textContent = t;
      b.addEventListener('click', function () { preguntar(t); });
      cont.appendChild(b);
    });
  }

  function pensando(fn) {
    var c = document.getElementById('qk-msgs');
    var m = document.createElement('div');
    m.className = 'qk-m qk-bot';
    m.textContent = '···';
    c.appendChild(m);
    c.scrollTop = c.scrollHeight;
    setTimeout(function () { m.remove(); fn(); }, 380);
  }

  function preguntar(texto) {
    decirYo(texto);
    chips([]);

    // ¿Está respondiendo una repregunta?
    if (pendiente) {
      var p = pendiente;
      pendiente = null;
      // Si en vez de responder cambia de tema, se atiende el tema nuevo.
      var otro = buscar(texto);
      if (otro && otro.id !== p.id) return responder(otro);
      return pensando(function () {
        decir(p.r2(texto), p.link, p.linkTxt);
        chips(p.c || []);
      });
    }

    var intent = buscar(texto);
    if (!intent) {
      return pensando(function () {
        decir('No estoy seguro de haber entendido. Puedo ayudarte con el cumplimiento, las justificaciones, los documentos, el registro diario y la configuración.<br><br>Prueba con una de estas, o escríbemelo con otras palabras:');
        chips(sugerenciasParecidas(texto));
      });
    }
    responder(intent);
  }

  function responder(intent) {
    pensando(function () {
      decir(intent.r, intent.pide ? null : intent.link, intent.linkTxt);
      if (intent.pide) { pendiente = intent; chips([]); }
      else chips(intent.c || []);
    });
  }

  // Expuesto para poder revisar el reconocimiento sin abrir el chat.
  window.QUICKY = {
    buscar: buscar,
    normalizar: normalizar,
    intents: INTENTS,
    preguntar: function (t) { if (!abierto) alternar(); preguntar(t); }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', montar);
  } else {
    montar();
  }
})();
