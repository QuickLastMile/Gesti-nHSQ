const HSQ_DEFAULT_ROOT = 'Registros HSQ';
const HSQ_EXPORT_FOLDER = 'Exportables HSQ';
const HSQ_ADMIN_SPREADSHEET_ID = '1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8';

// Columnas de Matriz_Activos donde se guarda el vencimiento de cada documento.
// Se crean solas la primera vez que se registran.
const HSQ_DOC_COLS = {
  SOAT: 'soat_vence',
  TECNOMECANICA: 'tecnomecanica_vence',
  LICENCIA: 'licencia_vence',
};
const HSQ_DIAS_ALERTA = 30; // avisar cuando falten 30 dias o menos

// Bloque de documentacion que se agrega al INICIO del PREOPERACIONAL.
// La 1a pregunta decide; si es SI, se exigen los documentos del vehiculo.
const HSQ_GATE_DOC = 'DOC_PRIMERA_O_RENOVACION';
const HSQ_DOCS_PREOPERACIONAL = [
  {
    id_pregunta: HSQ_GATE_DOC, orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: '¿Es la primera inspeccion del vehiculo, o renovaste el SOAT o la Tecnomecanica?',
    tipo_respuesta: 'si_no', obligatorio: 'SI',
    ayuda: 'Si respondes SI, debes adjuntar la documentacion del vehiculo.',
  },
  {
    id_pregunta: 'DOC_LICENCIA_TRANSITO', orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: 'Licencia de Transito (Tarjeta de Propiedad)',
    tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: HSQ_GATE_DOC, depende_valor: 'SI',
    documento: 'LICENCIA',
  },
  {
    id_pregunta: 'DOC_SOAT', orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: 'SOAT', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: HSQ_GATE_DOC, depende_valor: 'SI',
    documento: 'SOAT',
  },
  {
    id_pregunta: 'DOC_TECNOMECANICA', orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: 'Revision Tecnomecanica', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: HSQ_GATE_DOC, depende_valor: 'SI',
    documento: 'TECNOMECANICA',
  },
  {
    id_pregunta: 'DOC_MARCA_VEHICULO', orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: 'Marca del vehiculo', tipo_respuesta: 'texto', obligatorio: 'SI', depende_de: HSQ_GATE_DOC, depende_valor: 'SI',
  },
  {
    id_pregunta: 'DOC_CILINDRAJE', orden: 0, seccion: 'Documentacion del vehiculo',
    pregunta: 'Tipo de cilindraje (CC)', tipo_respuesta: 'numero', obligatorio: 'SI', depende_de: HSQ_GATE_DOC, depende_valor: 'SI',
  },
];

/**
 * API JSON para el frontend alojado en GitHub Pages.
 * El frontend hace POST con cuerpo de texto plano { action, payload }.
 * Se usa POST/texto-plano para evitar el "preflight" de CORS.
 */
function doPost(e) {
  return handleApi_(e);
}

/**
 * GET: permite una verificacion de estado abriendo la URL /exec en el navegador,
 * y tambien soporta ?action=... para pruebas rapidas.
 */
function doGet(e) {
  if (e && e.parameter && e.parameter.action) return handleApi_(e);
  return jsonOutput_({
    ok: true,
    service: 'Gestion HSQ Motos - API',
    mensaje: 'El backend esta activo. El frontend vive en GitHub Pages.',
  });
}

function handleApi_(e) {
  var out;
  try {
    var body = {};
    if (e && e.postData && e.postData.contents) {
      body = JSON.parse(e.postData.contents);
    } else if (e && e.parameter && e.parameter.action) {
      body = {
        action: e.parameter.action,
        payload: e.parameter.payload ? JSON.parse(e.parameter.payload) : {},
      };
    }
    var action = body.action;
    var payload = body.payload || {};
    var result;
    switch (action) {
      case 'getBootstrap': result = getBootstrap(); break;
      case 'buscarActivo': result = buscarActivo(payload.cedula); break;
      case 'registrarPlaca': result = registrarPlaca(payload.cedula, payload.placa, payload.observacion); break;
      case 'cargarFormulario': result = cargarFormulario(payload.id_formulario); break;
      case 'guardarRegistro': result = guardarRegistro(payload); break;
      case 'generarExportable': result = generarExportable(payload); break;
      case 'actualizarMatriz': result = actualizarMatriz(payload); break;
      case 'getMatrizInfo': result = getMatrizInfo(); break;
      default: throw new Error('Accion no reconocida: ' + action);
    }
    out = { ok: true, result: result };
  } catch (err) {
    out = { ok: false, error: (err && err.message) ? err.message : String(err) };
  }
  return jsonOutput_(out);
}

function jsonOutput_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('HSQ')
    .addItem('Verificar configuracion', 'verificarConfiguracion')
    .addToUi();
}

function verificarConfiguracion() {
  const ss = getAdminSpreadsheet_();
  const required = [
    'Configuracion',
    'Matriz_Activos',
    'Proyectos',
    'Formularios',
    'Preguntas',
    'Opciones',
    'Tipos_Campo',
  ];
  const missing = required.filter((name) => !ss.getSheetByName(name));
  const msg = missing.length
    ? 'Faltan hojas: ' + missing.join(', ')
    : 'Configuracion HSQ lista. Puede desplegar el Web App.';
  SpreadsheetApp.getUi().alert(msg);
}

function getBootstrap() {
  return {
    formularios: getFormularios_(),
    proyectos: getProyectos_(),
    tiposCampo: readObjects_('Tipos_Campo').filter((r) => isActive_(r.activo || 'SI')),
  };
}

function buscarActivo(cedula) {
  const key = normalizeId_(cedula);
  if (!key) throw new Error('Digite una cedula valida.');

  const found = readObjects_('Matriz_Activos').find((row) => normalizeId_(row.cedula) === key);
  if (!found) {
    return { encontrado: false, mensaje: 'No se encontro la cedula en Matriz_Activos.' };
  }

  const activo = isActive_(found.activo_para_registro);
  const resp = {
    encontrado: true,
    activo,
    mensaje: activo ? 'Activo habilitado para registro.' : 'La persona no esta activa para registro.',
    datos: found,
    requierePlaca: !String(found.placa_moto || '').trim(),
  };
  if (activo) {
    resp.formulariosRequeridos = getFormularios_().map(function (f) {
      return { id_formulario: f.id_formulario, nombre_formulario: f.nombre_formulario };
    });
    resp.estadoDiario = getEstadoDiario_(found);
    resp.documentos = getDocumentos_(found);
  }
  return resp;
}

/**
 * Guarda o actualiza la placa del colaborador en Matriz_Activos.
 * - Primera vez: buscarActivo la pide y despues ya no la vuelve a pedir.
 * - Cambio de moto: el mensajero puede actualizarla cuando cambie de vehiculo.
 * Los registros ya guardados conservan la placa que tenian en su momento.
 */
function registrarPlaca(cedula, placa, observacion) {
  const key = normalizeId_(cedula);
  if (!key) throw new Error('Digite una cedula valida.');
  const placaClean = String(placa || '').trim().toUpperCase();
  if (!placaClean) throw new Error('Digite una placa valida.');
  const obs = String(observacion || '').trim();

  const sheet = getAdminSpreadsheet_().getSheetByName('Matriz_Activos');
  if (!sheet) throw new Error('No existe la hoja Matriz_Activos.');
  const values = sheet.getDataRange().getValues();
  const headers = values[0].map(function (h) { return String(h).trim(); });
  const cedIdx = headers.indexOf('cedula');
  const placaIdx = headers.indexOf('placa_moto');
  const obsIdx = headers.indexOf('observaciones_hsq');
  if (cedIdx === -1 || placaIdx === -1) throw new Error('Faltan columnas cedula o placa_moto en Matriz_Activos.');

  for (let i = 1; i < values.length; i++) {
    if (normalizeId_(values[i][cedIdx]) === key) {
      const placaAnterior = String(values[i][placaIdx] || '').trim().toUpperCase();
      const esCambio = placaAnterior && placaAnterior !== placaClean;

      // Al cambiar de moto (ya habia placa distinta) el motivo es obligatorio.
      if (esCambio && !obs) {
        throw new Error('Para cambiar la placa debes escribir el motivo del cambio.');
      }

      sheet.getRange(i + 1, placaIdx + 1).setValue(placaClean);

      if (esCambio) {
        const tz = getConfig_().TIMEZONE || 'America/Bogota';
        const fecha = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm');
        const nota = 'Placa ' + placaAnterior + ' -> ' + placaClean + ' (' + fecha + '): ' + obs;
        if (obsIdx !== -1) {
          const prev = String(values[i][obsIdx] || '').trim();
          sheet.getRange(i + 1, obsIdx + 1).setValue(prev ? (prev + ' | ' + nota) : nota);
        }
        registrarHistorial_('CAMBIO_PLACA', key, nota);
      }

      clearSheetCache_('Matriz_Activos');
      return { ok: true, placa_moto: placaClean, cambio: esCambio };
    }
  }
  throw new Error('No se encontro la cedula en Matriz_Activos.');
}

/**
 * Registra una linea en la hoja Historial_Cambios (la crea si no existe).
 * Deja auditoria de cambios de placa y actualizaciones de matriz.
 */
function registrarHistorial_(tipo, cedula, detalle) {
  try {
    const ss = getAdminSpreadsheet_();
    let sheet = ss.getSheetByName('Historial_Cambios');
    if (!sheet) {
      sheet = ss.insertSheet('Historial_Cambios');
      sheet.appendRow(['timestamp', 'fecha', 'tipo', 'cedula', 'detalle']);
      sheet.getRange(1, 1, 1, 5).setBackground('#0B3A5B').setFontColor('#FFFFFF').setFontWeight('bold');
      sheet.setFrozenRows(1);
    }
    const tz = getConfig_().TIMEZONE || 'America/Bogota';
    const now = new Date();
    sheet.appendRow([
      now,
      Utilities.formatDate(now, tz, 'yyyy-MM-dd HH:mm:ss'),
      tipo,
      "'" + String(cedula || ''),
      String(detalle || ''),
    ]);
  } catch (e) { /* el historial no debe frenar la operacion principal */ }
}

function appendHistorialBatch_(rows) {
  if (!rows || !rows.length) return;
  try {
    const ss = getAdminSpreadsheet_();
    let sheet = ss.getSheetByName('Historial_Cambios');
    if (!sheet) {
      sheet = ss.insertSheet('Historial_Cambios');
      sheet.appendRow(['timestamp', 'fecha', 'tipo', 'cedula', 'detalle']);
      sheet.getRange(1, 1, 1, 5).setBackground('#0B3A5B').setFontColor('#FFFFFF').setFontWeight('bold');
      sheet.setFrozenRows(1);
    }
    sheet.getRange(sheet.getLastRow() + 1, 1, rows.length, 5).setValues(rows);
  } catch (e) { /* noop */ }
}

/** Fecha en que se actualizo la matriz por ultima vez (para mostrarla al coordinador). */
function getMatrizInfo() {
  const cfg = getConfig_();
  return { ultimaActualizacion: cfg.MATRIZ_ULTIMA_ACTUALIZACION || '' };
}

function setConfigParam_(parametro, valor) {
  const sheet = getAdminSpreadsheet_().getSheetByName('Configuracion');
  if (!sheet) return;
  const values = sheet.getDataRange().getValues();
  const headers = values[0].map(function (h) { return String(h).trim(); });
  const pIdx = headers.indexOf('parametro');
  const vIdx = headers.indexOf('valor');
  if (pIdx === -1 || vIdx === -1) return;
  for (let i = 1; i < values.length; i++) {
    if (String(values[i][pIdx]).trim() === parametro) {
      sheet.getRange(i + 1, vIdx + 1).setValue(valor);
      clearSheetCache_('Configuracion');
      return;
    }
  }
  const row = new Array(headers.length).fill('');
  row[pIdx] = parametro;
  row[vIdx] = valor;
  sheet.appendRow(row);
  clearSheetCache_('Configuracion');
}

/**
 * Actualiza Matriz_Activos con el export de nomina pegado por el coordinador.
 * - Mapea por nombre de columna (ClientId, ClientName, State, ...).
 * - Conserva placa_moto, tipo_vehiculo y observaciones_hsq de cada persona.
 * - Inactiva automaticamente a quien no aparezca en la nueva data y deja nota.
 * - Agrega las cedulas nuevas como activas.
 * - Guarda la fecha de actualizacion y registra el historial.
 */
function actualizarMatriz(payload) {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const texto = String((payload && payload.data) || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
    if (!texto) throw new Error('Pega los datos de la matriz antes de actualizar.');

    const lines = texto.split('\n').filter(function (l) { return l.trim() !== ''; });
    if (lines.length < 2) throw new Error('Los datos deben incluir la fila de titulos y al menos un registro.');

    const src = lines.map(function (l) { return l.split('\t'); });
    const srcHeaders = src.shift().map(function (h) { return String(h).trim(); });
    const H = {};
    srcHeaders.forEach(function (h, i) { H[h] = i; });

    if (!('ClientId' in H)) {
      throw new Error('No encuentro la columna "ClientId" (cedula) en los datos pegados. Incluye la fila de titulos del export de nomina.');
    }
    if (!('ClientName' in H)) {
      throw new Error('No encuentro la columna "ClientName" (nombre) en los datos pegados.');
    }

    // Columna destino en Matriz_Activos <- columna del export de nomina.
    const MAP = {
      estado_nomina: 'State',
      tipo_documento: 'Columna1',
      nombre: 'ClientName',
      cargo: 'PlaceName',
      proyecto_id: 'ProjectId',
      proyecto: 'ProjectName',
      ciudad: 'Ciudad',
      telefono: 'Phone',
      celular: 'CelPhone',
      email: 'Email',
      fecha_ingreso: 'DateIngress',
      fecha_retiro: 'DateRetirement',
    };
    const get = function (row, srcName) {
      return (srcName in H) ? String(row[H[srcName]] == null ? '' : row[H[srcName]]).trim() : '';
    };

    const nuevos = {};
    src.forEach(function (row) {
      const ced = normalizeId_(get(row, 'ClientId'));
      if (!ced) return;
      const state = get(row, 'State').toUpperCase();
      const retiro = get(row, 'DateRetirement');
      nuevos[ced] = { row: row, activo: (state === 'A' && !retiro) ? 'SI' : 'NO' };
    });

    const sheet = getAdminSpreadsheet_().getSheetByName('Matriz_Activos');
    if (!sheet) throw new Error('No existe la hoja Matriz_Activos.');
    const values = sheet.getDataRange().getValues();
    const dHeaders = values[0].map(function (h) { return String(h).trim(); });
    const dIdx = {};
    dHeaders.forEach(function (h, i) { dIdx[h] = i; });
    const cedIdx = dIdx['cedula'];
    const activoIdx = dIdx['activo_para_registro'];
    const obsIdx = dIdx['observaciones_hsq'];
    if (cedIdx === undefined) throw new Error('Falta la columna cedula en Matriz_Activos.');

    const tz = getConfig_().TIMEZONE || 'America/Bogota';
    const now = new Date();
    const hoy = Utilities.formatDate(now, tz, 'yyyy-MM-dd HH:mm');
    const fechaLog = Utilities.formatDate(now, tz, 'yyyy-MM-dd HH:mm:ss');

    let cActualizados = 0, cInactivados = 0, cNuevos = 0, cReactivados = 0;
    const presentes = {};
    const hist = [];

    for (let i = 1; i < values.length; i++) {
      const ced = normalizeId_(values[i][cedIdx]);
      if (!ced) continue;
      if (nuevos[ced]) {
        presentes[ced] = true;
        const info = nuevos[ced];
        const antes = String(values[i][activoIdx] || '').trim().toUpperCase();
        Object.keys(MAP).forEach(function (dest) {
          if (dIdx[dest] === undefined) return;
          const val = get(info.row, MAP[dest]);
          if (val !== '') values[i][dIdx[dest]] = val;
        });
        if (activoIdx !== undefined) values[i][activoIdx] = info.activo;
        if (info.activo === 'SI' && antes !== 'SI' && antes !== 'A') cReactivados++;
        cActualizados++;
      } else {
        const antes = String(values[i][activoIdx] || '').trim().toUpperCase();
        if (activoIdx !== undefined && antes !== 'NO') {
          values[i][activoIdx] = 'NO';
          const nota = 'Inactivada el ' + hoy + ': no aparece en la matriz cargada.';
          if (obsIdx !== undefined) {
            const prev = String(values[i][obsIdx] || '').trim();
            values[i][obsIdx] = prev ? (prev + ' | ' + nota) : nota;
          }
          hist.push([now, fechaLog, 'INACTIVACION', "'" + ced, 'No aparece en la matriz cargada el ' + hoy]);
          cInactivados++;
        }
      }
    }

    // Reescribe las filas existentes (solo valores; el formato de la hoja se conserva).
    sheet.getRange(1, 1, values.length, values[0].length).setValues(values);

    // Agrega las cedulas nuevas.
    const nuevasFilas = [];
    Object.keys(nuevos).forEach(function (ced) {
      if (presentes[ced]) return;
      const info = nuevos[ced];
      const fila = new Array(dHeaders.length).fill('');
      fila[cedIdx] = get(info.row, 'ClientId');
      Object.keys(MAP).forEach(function (dest) {
        if (dIdx[dest] === undefined) return;
        fila[dIdx[dest]] = get(info.row, MAP[dest]);
      });
      if (activoIdx !== undefined) fila[activoIdx] = info.activo;
      if (dIdx['tipo_vehiculo'] !== undefined) fila[dIdx['tipo_vehiculo']] = 'MOTO';
      if (obsIdx !== undefined) fila[obsIdx] = 'Agregada el ' + hoy + ' desde actualizacion de matriz.';
      nuevasFilas.push(fila);
      hist.push([now, fechaLog, 'NUEVO', "'" + ced, 'Agregada el ' + hoy]);
      cNuevos++;
    });
    if (nuevasFilas.length) {
      sheet.getRange(sheet.getLastRow() + 1, 1, nuevasFilas.length, dHeaders.length).setValues(nuevasFilas);
    }

    hist.push([now, fechaLog, 'ACTUALIZACION_MATRIZ', '', 'Actualizados ' + cActualizados + ', nuevos ' + cNuevos + ', inactivados ' + cInactivados]);
    appendHistorialBatch_(hist);
    setConfigParam_('MATRIZ_ULTIMA_ACTUALIZACION', hoy);

    clearSheetCache_('Matriz_Activos');
    clearSheetCache_('Proyectos');

    return {
      ok: true,
      actualizados: cActualizados,
      nuevos: cNuevos,
      inactivados: cInactivados,
      reactivados: cReactivados,
      totalEnData: Object.keys(nuevos).length,
      fecha: hoy,
    };
  } finally {
    lock.releaseLock();
  }
}

/**
 * Devuelve, para cada formulario activo, si esa persona ya lo registro HOY.
 * { ID_FORM: { hecho: true/false, idRegistro, hora } }
 */
function getEstadoDiario_(persona) {
  const tz = getConfig_().TIMEZONE || 'America/Bogota';
  const fecha = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  const cedulaKey = normalizeId_(persona.cedula);
  const estado = {};
  getFormularios_().forEach(function (f) { estado[f.id_formulario] = { hecho: false }; });

  const dayFolder = findDayFolder_(fecha);
  if (!dayFolder) return estado;

  Object.keys(estado).forEach(function (idForm) {
    const files = dayFolder.getFilesByName(fecha + '_' + idForm);
    while (files.hasNext()) {
      const file = files.next();
      if (file.getMimeType() !== MimeType.GOOGLE_SHEETS) continue;
      const sheet = SpreadsheetApp.openById(file.getId()).getSheetByName('Respuestas');
      if (!sheet || sheet.getLastRow() < 2) continue;
      const values = sheet.getDataRange().getValues();
      const headers = values.shift().map(String);
      const cedIdx = headers.indexOf('cedula');
      const idRegIdx = headers.indexOf('id_registro');
      const horaIdx = headers.indexOf('hora_registro');
      for (let i = 0; i < values.length; i++) {
        if (normalizeId_(values[i][cedIdx]) === cedulaKey) {
          estado[idForm] = {
            hecho: true,
            idRegistro: values[i][idRegIdx],
            hora: horaIdx !== -1 ? String(values[i][horaIdx]) : '',
          };
          break;
        }
      }
    }
  });
  return estado;
}

function cargarFormulario(idFormulario) {
  const formulario = getFormularios_().find((f) => f.id_formulario === idFormulario && isActive_(f.activo));
  if (!formulario) throw new Error('Formulario no encontrado o inactivo.');

  let preguntas = readObjects_('Preguntas')
    .filter((q) => q.id_formulario === idFormulario && isActive_(q.activo))
    .sort((a, b) => Number(a.orden || 0) - Number(b.orden || 0));

  // El PREOPERACIONAL inicia con el bloque de documentacion del vehiculo.
  // Las preguntas de vigencia que ya existen en la hoja (SOAT, Tecnomecanica,
  // Licencia) se suben al inicio, cada una debajo de su documento.
  if (idFormulario === 'PREOPERACIONAL') {
    const fechasHoja = {};
    const resto = [];
    preguntas.forEach(function (q) {
      const k = docKeyDePregunta_(q);
      if (k && !fechasHoja[k]) fechasHoja[k] = q;
      else resto.push(q);
    });
    const bloque = [];
    HSQ_DOCS_PREOPERACIONAL.forEach(function (d) {
      bloque.push(d);
      const k = sinTildes_(d.documento).trim();
      if (k && fechasHoja[k]) {
        bloque.push(fechasHoja[k]);
        delete fechasHoja[k];
      }
    });
    // Si quedo alguna vigencia sin documento asociado, va igual al inicio.
    Object.keys(fechasHoja).forEach(function (k) { bloque.push(fechasHoja[k]); });
    preguntas = bloque.concat(resto);
  }

  return {
    formulario,
    preguntas,
    opciones: getOpcionesPorGrupo_(),
  };
}

function guardarRegistro(payload) {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);

  try {
    if (!payload || !payload.id_formulario) throw new Error('No se recibio formulario.');
    const activoResp = buscarActivo(payload.cedula);
    if (!activoResp.encontrado || !activoResp.activo) {
      throw new Error(activoResp.mensaje || 'Cedula no habilitada.');
    }

    const estadoPrevio = getEstadoDiario_(activoResp.datos);
    if (estadoPrevio[payload.id_formulario] && estadoPrevio[payload.id_formulario].hecho) {
      throw new Error('Ya realizaste este registro hoy. Solo se permite un registro diario por tipo.');
    }

    const formData = cargarFormulario(payload.id_formulario);
    const preguntas = formData.preguntas;
    const respuestas = payload.respuestas || {};
    const archivos = payload.archivos || [];
    const now = new Date();
    const tz = getConfig_().TIMEZONE || Session.getScriptTimeZone() || 'America/Bogota';
    const fecha = Utilities.formatDate(now, tz, 'yyyy-MM-dd');
    const hora = Utilities.formatDate(now, tz, 'HH:mm:ss');
    const idRegistro = [
      payload.id_formulario,
      Utilities.formatDate(now, tz, 'yyyyMMdd-HHmmss'),
      normalizeId_(payload.cedula),
    ].join('-');

    // Vencimientos de documentos: si el mensajero marco "primera vez / renovacion",
    // se toman las fechas nuevas. Si no, se usa siempre la ya registrada (la
    // pregunta va bloqueada y no se puede alterar dia a dia).
    const gateDoc = String(respuestas[HSQ_GATE_DOC] || '').trim().toUpperCase();
    const fechasDoc = {};

    // Si marco "primera vez / renovacion" escribe la fecha nueva; si no, se usa
    // siempre la ya guardada (la pregunta va bloqueada y no se altera dia a dia).
    preguntas.forEach(function (q) {
      const k = docKeyDePregunta_(q);
      if (!k) return;
      if (gateDoc === 'SI') {
        const v = fechaISO_(respuestas[q.id_pregunta], tz);
        if (v) fechasDoc[k] = v;
      } else {
        const guardada = fechaISO_(activoResp.datos[HSQ_DOC_COLS[k]], tz);
        if (!guardada && isActive_(q.obligatorio)) {
          throw new Error('Aun no tienes registrada la fecha de ' + k + '. Responde SI en la primera pregunta y adjunta tus documentos.');
        }
        respuestas[q.id_pregunta] = guardada;
      }
    });

    validarRespuestas_(preguntas, respuestas, archivos);

    if (Object.keys(fechasDoc).length) {
      guardarFechasDocumentos_(payload.cedula, fechasDoc);
    }

    const folders = getStorageFolders_(fecha);
    const evidenciaFolder = getOrCreateFolder_(folders.day, 'Evidencias');
    const evidencias = saveEvidenceFiles_(archivos, evidenciaFolder, idRegistro);
    const dailySpreadsheet = getOrCreateDailySpreadsheet_(folders.day, fecha, payload.id_formulario);
    const sheet = getOrCreateResponseSheet_(dailySpreadsheet, formData.formulario, preguntas);
    const alertas = buildAlertas_(preguntas, respuestas);
    const headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];

    const fixed = {
      timestamp: now,
      fecha_registro: fecha,
      hora_registro: hora,
      id_registro: idRegistro,
      id_formulario: payload.id_formulario,
      formulario: formData.formulario.nombre_formulario,
      cedula: String(payload.cedula || ''),
      nombre: activoResp.datos.nombre || '',
      cargo: activoResp.datos.cargo || '',
      proyecto_id: String(activoResp.datos.proyecto_id || ''),
      proyecto: activoResp.datos.proyecto || '',
      ciudad: activoResp.datos.ciudad || '',
      placa_moto: activoResp.datos.placa_moto || '',
      tipo_vehiculo: activoResp.datos.tipo_vehiculo || '',
      estado_registro: alertas.length ? 'CON_ALERTA' : 'OK',
      alertas: alertas.join(' | '),
      evidencias_json: JSON.stringify(evidencias),
      respuestas_json: JSON.stringify(respuestas),
      usuario: Session.getActiveUser().getEmail() || '',
    };

    const row = headers.map((header) => {
      if (Object.prototype.hasOwnProperty.call(fixed, header)) return fixed[header];
      const question = preguntas.find((q) => questionHeader_(q) === header);
      if (!question) return '';
      const value = respuestas[question.id_pregunta];
      return Array.isArray(value) ? value.join(', ') : value || '';
    });

    sheet.appendRow(row);
    SpreadsheetApp.flush();

    const estadoDiario = getEstadoDiario_(activoResp.datos);
    const requeridos = getFormularios_();
    const completo = requeridos.every(function (f) {
      return estadoDiario[f.id_formulario] && estadoDiario[f.id_formulario].hecho;
    });
    const comprobante = {
      nombre: activoResp.datos.nombre || '',
      cedula: String(payload.cedula || ''),
      placa_moto: activoResp.datos.placa_moto || '',
      proyecto: activoResp.datos.proyecto || '',
      ciudad: activoResp.datos.ciudad || '',
      fecha: fecha,
      completo: completo,
      registros: requeridos
        .filter(function (f) { return estadoDiario[f.id_formulario] && estadoDiario[f.id_formulario].hecho; })
        .map(function (f) {
          return {
            id_formulario: f.id_formulario,
            formulario: f.nombre_formulario,
            hora: estadoDiario[f.id_formulario].hora,
            idRegistro: estadoDiario[f.id_formulario].idRegistro,
          };
        }),
    };

    return {
      ok: true,
      idRegistro,
      estado: fixed.estado_registro,
      alertas,
      archivoDiaUrl: dailySpreadsheet.getUrl(),
      estadoDiario: estadoDiario,
      completo: completo,
      comprobante: comprobante,
    };
  } finally {
    lock.releaseLock();
  }
}

function generarExportable(filtros) {
  const tz = getConfig_().TIMEZONE || 'America/Bogota';
  const inicio = parseDate_(filtros.fechaInicio);
  const fin = parseDate_(filtros.fechaFin);
  if (!inicio || !fin || inicio > fin) throw new Error('Rango de fechas invalido.');

  const formularios = (filtros.formularios || []).map(String).filter(Boolean);
  if (formularios.length !== 1) {
    throw new Error('Selecciona un solo formulario para exportar (Preoperacional o Limpieza, no ambos): tienen columnas diferentes.');
  }
  const formId = formularios[0];
  const proyectos = new Set((filtros.proyectos || []).map(String).filter(Boolean));
  // Filtro opcional por mensajero. Vacio = todos.
  const cedulaFiltro = normalizeId_(filtros.cedula);

  // Columnas que NO deben aparecer en el exportable del coordinador.
  const OCULTAR = ['respuestas_json', 'evidencias_json', 'timestamp', 'usuario'];

  const matched = [];        // filas como objetos { header: valor }
  const evidenceIds = [];    // id_pregunta de cada evidencia (columnas separadas)
  let baseHeaderOrder = null;

  for (let d = new Date(inicio); d <= fin; d.setDate(d.getDate() + 1)) {
    const fecha = Utilities.formatDate(d, tz, 'yyyy-MM-dd');
    const dayFolder = findDayFolder_(fecha);
    if (!dayFolder) continue;

    const files = dayFolder.getFilesByName(fecha + '_' + formId);
    while (files.hasNext()) {
      const file = files.next();
      if (file.getMimeType() !== MimeType.GOOGLE_SHEETS) continue;
      const sheet = SpreadsheetApp.openById(file.getId()).getSheetByName('Respuestas');
      if (!sheet || sheet.getLastRow() < 2) continue;

      const values = sheet.getDataRange().getValues();
      const headers = values.shift().map(String);
      if (!baseHeaderOrder) baseHeaderOrder = headers.slice();

      const formIdx = headers.indexOf('id_formulario');
      const projectIdIdx = headers.indexOf('proyecto_id');
      const projectIdx = headers.indexOf('proyecto');
      const cedulaIdx = headers.indexOf('cedula');

      values.forEach((row) => {
        if (String(row[formIdx] || '') !== formId) return;
        if (cedulaFiltro && normalizeId_(row[cedulaIdx]) !== cedulaFiltro) return;
        const projectOk =
          !proyectos.size ||
          proyectos.has(String(row[projectIdIdx] || '')) ||
          proyectos.has(String(row[projectIdx] || ''));
        if (!projectOk) return;

        const obj = {};
        headers.forEach((h, i) => { obj[h] = row[i]; });
        matched.push(obj);

        (safeParseJson_(obj.evidencias_json) || []).forEach((ev) => {
          if (ev && ev.id_pregunta && evidenceIds.indexOf(ev.id_pregunta) === -1) {
            evidenceIds.push(ev.id_pregunta);
          }
        });
      });
    }
  }

  // Encabezados de salida: base sin columnas ocultas + una columna por evidencia.
  const baseHeaders = (baseHeaderOrder || []).filter((h) => OCULTAR.indexOf(h) === -1);
  const evidenceHeaders = evidenceIds.map((id) => 'Evidencia ' + id);
  const outHeaders = baseHeaders.concat(evidenceHeaders);

  const csvRows = [outHeaders];
  matched.forEach((obj) => {
    const baseVals = baseHeaders.map((h) => (obj[h] !== undefined ? obj[h] : ''));
    const evMap = {};
    (safeParseJson_(obj.evidencias_json) || []).forEach((ev) => {
      if (ev && ev.id_pregunta) evMap[ev.id_pregunta] = ev.url || '';
    });
    const evVals = evidenceIds.map((id) => evMap[id] || '');
    csvRows.push(baseVals.concat(evVals));
  });

  // BOM UTF-8 + CRLF para que Excel muestre bien las tildes y las columnas.
  const csv = '\uFEFF' + csvRows.map((r) => r.map(csvEscape_).join(',')).join('\r\n');
  const exportFolder = getOrCreateFolder_(getRootFolder_(), HSQ_EXPORT_FOLDER);
  const sufijoCedula = cedulaFiltro ? '_CC' + cedulaFiltro : '';
  const name = 'Exportable_' + formId + sufijoCedula + '_' + Utilities.formatDate(new Date(), tz, 'yyyyMMdd_HHmmss') + '.csv';
  const file = exportFolder.createFile(Utilities.newBlob(csv, 'text/csv; charset=utf-8', name));

  return {
    ok: true,
    filas: matched.length,
    columnas: outHeaders.length,
    formulario: formId,
    url: file.getUrl(),
    downloadUrl: 'https://drive.google.com/uc?export=download&id=' + file.getId(),
    nombre: name,
  };
}

function safeParseJson_(value) {
  if (!value) return null;
  try { return JSON.parse(value); } catch (e) { return null; }
}

/* ============ Documentos del vehiculo (SOAT / Tecnomecanica / Licencia) ============ */

function sinTildes_(s) {
  return String(s == null ? '' : s)
    .replace(/[áàäâÁÀÄÂ]/g, 'A')
    .replace(/[éèëêÉÈËÊ]/g, 'E')
    .replace(/[íìïîÍÌÏÎ]/g, 'I')
    .replace(/[óòöôÓÒÖÔ]/g, 'O')
    .replace(/[úùüûÚÙÜÛ]/g, 'U')
    .replace(/[ñÑ]/g, 'N')
    .toUpperCase();
}

/**
 * Indica si una pregunta de tipo fecha corresponde al vencimiento de un documento.
 * Usa la columna opcional "documento" (SOAT/TECNOMECANICA/LICENCIA) y, si no existe,
 * reconoce la pregunta por su texto.
 */
function docKeyDePregunta_(q) {
  if (String(q.tipo_respuesta || '').trim() !== 'fecha') return '';
  const exp = sinTildes_(q.documento).trim();
  if (HSQ_DOC_COLS[exp]) return exp;
  const t = sinTildes_(q.pregunta);
  if (t.indexOf('SOAT') !== -1) return 'SOAT';
  if (/TECNO|TECNIC|MECANIC/.test(t)) return 'TECNOMECANICA';
  if (t.indexOf('LICENCIA') !== -1) return 'LICENCIA';
  return '';
}

function fechaISO_(v, tz) {
  if (v === null || v === undefined || v === '') return '';
  if (Object.prototype.toString.call(v) === '[object Date]') {
    return Utilities.formatDate(v, tz || 'America/Bogota', 'yyyy-MM-dd');
  }
  const s = String(v).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const m = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (m) return m[3] + '-' + ('0' + m[2]).slice(-2) + '-' + ('0' + m[1]).slice(-2);
  return s;
}

function estadoDocumento_(fechaIso, hoyIso) {
  if (!fechaIso) return { fecha: '', dias: null, estado: 'sin_dato' };
  const dias = Math.floor((Date.parse(fechaIso + 'T00:00:00') - Date.parse(hoyIso + 'T00:00:00')) / 86400000);
  if (isNaN(dias)) return { fecha: fechaIso, dias: null, estado: 'sin_dato' };
  let estado = 'ok';
  if (dias < 0) estado = 'vencido';
  else if (dias <= HSQ_DIAS_ALERTA) estado = 'por_vencer';
  return { fecha: fechaIso, dias: dias, estado: estado };
}

function getDocumentos_(persona) {
  const tz = getConfig_().TIMEZONE || 'America/Bogota';
  const hoy = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  const out = {};
  Object.keys(HSQ_DOC_COLS).forEach(function (k) {
    out[k] = estadoDocumento_(fechaISO_(persona[HSQ_DOC_COLS[k]], tz), hoy);
  });
  return out;
}

/** Guarda las fechas de vencimiento en Matriz_Activos (crea las columnas si faltan). */
function guardarFechasDocumentos_(cedula, dates) {
  const key = normalizeId_(cedula);
  const sheet = getAdminSpreadsheet_().getSheetByName('Matriz_Activos');
  if (!sheet || !key) return;

  let headers = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 1)).getValues()[0]
    .map(function (h) { return String(h).trim(); });

  const faltantes = [];
  Object.keys(dates).forEach(function (k) {
    const col = HSQ_DOC_COLS[k];
    if (col && headers.indexOf(col) === -1 && faltantes.indexOf(col) === -1) faltantes.push(col);
  });
  if (faltantes.length) {
    sheet.getRange(1, headers.length + 1, 1, faltantes.length).setValues([faltantes]);
    headers = headers.concat(faltantes);
  }

  const cedIdx = headers.indexOf('cedula');
  if (cedIdx === -1) return;
  const values = sheet.getDataRange().getValues();
  for (let i = 1; i < values.length; i++) {
    if (normalizeId_(values[i][cedIdx]) === key) {
      const detalle = [];
      Object.keys(dates).forEach(function (k) {
        const c = headers.indexOf(HSQ_DOC_COLS[k]);
        if (c !== -1) {
          sheet.getRange(i + 1, c + 1).setValue(dates[k]);
          detalle.push(k + ': ' + dates[k]);
        }
      });
      clearSheetCache_('Matriz_Activos');
      if (detalle.length) registrarHistorial_('DOCUMENTOS', key, 'Vencimientos actualizados -> ' + detalle.join(', '));
      return;
    }
  }
}

function getAdminSpreadsheet_() {
  const id = PropertiesService.getScriptProperties().getProperty('ADMIN_SPREADSHEET_ID') || HSQ_ADMIN_SPREADSHEET_ID;
  if (id) return SpreadsheetApp.openById(id);
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getConfig_() {
  const out = {};
  readObjects_('Configuracion').forEach((row) => {
    if (row.parametro) out[row.parametro] = row.valor;
  });
  return out;
}

// TTL de cache por hoja (segundos). La matriz cambia con placas, TTL corto.
const HSQ_CACHE_TTL = { Matriz_Activos: 60 };
const HSQ_CACHE_TTL_DEFAULT = 300;

function readObjects_(sheetName) {
  const cache = CacheService.getScriptCache();
  const cacheKey = 'hsq_sheet_' + sheetName;
  const cached = cache.get(cacheKey);
  if (cached) {
    try { return JSON.parse(cached); } catch (e) { /* cache corrupto, se relee */ }
  }

  const sheet = getAdminSpreadsheet_().getSheetByName(sheetName);
  if (!sheet) throw new Error('No existe la hoja ' + sheetName);
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values.shift().map((h) => String(h).trim());
  const objects = values
    .filter((row) => row.some((cell) => cell !== '' && cell !== null))
    .map((row) => {
      const obj = {};
      headers.forEach((header, i) => {
        obj[header] = row[i];
      });
      return obj;
    });

  // CacheService limita a ~100KB por clave: si no cabe (matriz grande), simplemente no se cachea.
  try {
    cache.put(cacheKey, JSON.stringify(objects), HSQ_CACHE_TTL[sheetName] || HSQ_CACHE_TTL_DEFAULT);
  } catch (e) { /* demasiado grande para cache; se seguira leyendo directo */ }
  return objects;
}

function clearSheetCache_(sheetName) {
  try { CacheService.getScriptCache().remove('hsq_sheet_' + sheetName); } catch (e) { /* noop */ }
}

function getFormularios_() {
  return readObjects_('Formularios').filter((row) => isActive_(row.activo));
}

function getProyectos_() {
  return readObjects_('Proyectos').filter((row) => isActive_(row.activo));
}

function getOpcionesPorGrupo_() {
  const opciones = {};
  readObjects_('Opciones')
    .filter((row) => isActive_(row.activo))
    .sort((a, b) => Number(a.orden || 0) - Number(b.orden || 0))
    .forEach((row) => {
      const group = row.grupo_opciones;
      if (!opciones[group]) opciones[group] = [];
      opciones[group].push(row.valor);
    });
  return opciones;
}

function validarRespuestas_(preguntas, respuestas, archivos) {
  const fileQuestionIds = new Set((archivos || []).map((f) => f.id_pregunta));
  preguntas.forEach((q) => {
    // Pregunta condicional: si la condicion no se cumple, no se exige.
    if (q.depende_de) {
      const gate = respuestas[q.depende_de];
      const gateVal = Array.isArray(gate) ? gate.join(',') : String(gate == null ? '' : gate);
      if (gateVal.trim().toUpperCase() !== String(q.depende_valor || '').trim().toUpperCase()) return;
    }
    const value = respuestas[q.id_pregunta];
    const empty = value === undefined || value === null || value === '' || (Array.isArray(value) && !value.length);
    const hasFile = fileQuestionIds.has(q.id_pregunta);
    if (isActive_(q.obligatorio) && q.tipo_respuesta === 'archivo' && !hasFile) {
      throw new Error('Falta adjuntar evidencia: ' + q.pregunta);
    }
    if (isActive_(q.obligatorio) && q.tipo_respuesta !== 'archivo' && empty) {
      throw new Error('Falta responder: ' + q.pregunta);
    }
    if (q.evidencia_requerida_si && String(value) === String(q.respuesta_alerta) && !hasFile) {
      throw new Error('La respuesta requiere evidencia: ' + q.pregunta);
    }
  });
}

function buildAlertas_(preguntas, respuestas) {
  return preguntas
    .filter((q) => q.respuesta_alerta && String(respuestas[q.id_pregunta]) === String(q.respuesta_alerta))
    .map((q) => q.id_pregunta + ': ' + q.pregunta);
}

function getStorageFolders_(fecha) {
  const parts = fecha.split('-');
  const root = getRootFolder_();
  const year = getOrCreateFolder_(root, parts[0]);
  const month = getOrCreateFolder_(year, parts[0] + '-' + parts[1]);
  const day = getOrCreateFolder_(month, fecha);
  return { root, year, month, day };
}

function getRootFolder_() {
  const config = getConfig_();
  return getOrCreateFolder_(DriveApp.getRootFolder(), config.ROOT_FOLDER_NAME || HSQ_DEFAULT_ROOT);
}

function getOrCreateFolder_(parent, name) {
  const folders = parent.getFoldersByName(name);
  return folders.hasNext() ? folders.next() : parent.createFolder(name);
}

function findDayFolder_(fecha) {
  const parts = fecha.split('-');
  const root = findFolder_(DriveApp.getRootFolder(), (getConfig_().ROOT_FOLDER_NAME || HSQ_DEFAULT_ROOT));
  if (!root) return null;
  const year = findFolder_(root, parts[0]);
  if (!year) return null;
  const month = findFolder_(year, parts[0] + '-' + parts[1]);
  if (!month) return null;
  return findFolder_(month, fecha);
}

function findFolder_(parent, name) {
  const folders = parent.getFoldersByName(name);
  return folders.hasNext() ? folders.next() : null;
}

function getOrCreateDailySpreadsheet_(folder, fecha, idFormulario) {
  const name = fecha + '_' + idFormulario;
  const files = folder.getFilesByName(name);
  while (files.hasNext()) {
    const file = files.next();
    if (file.getMimeType() === MimeType.GOOGLE_SHEETS) return SpreadsheetApp.openById(file.getId());
  }
  const ss = SpreadsheetApp.create(name);
  DriveApp.getFileById(ss.getId()).moveTo(folder);
  return ss;
}

function getOrCreateResponseSheet_(ss, formulario, preguntas) {
  const sheet = ss.getSheetByName('Respuestas') || ss.insertSheet('Respuestas');
  const baseHeaders = [
    'timestamp',
    'fecha_registro',
    'hora_registro',
    'id_registro',
    'id_formulario',
    'formulario',
    'cedula',
    'nombre',
    'cargo',
    'proyecto_id',
    'proyecto',
    'ciudad',
    'placa_moto',
    'tipo_vehiculo',
    'estado_registro',
    'alertas',
  ];
  const questionHeaders = preguntas.map(questionHeader_);
  const trailingHeaders = ['evidencias_json', 'respuestas_json', 'usuario'];
  const desired = baseHeaders.concat(questionHeaders, trailingHeaders);

  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.appendRow(desired);
    formatHeader_(sheet);
    return sheet;
  }

  const current = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0].map(String);
  const missing = desired.filter((h) => current.indexOf(h) === -1);
  if (missing.length) {
    sheet.getRange(1, current.length + 1, 1, missing.length).setValues([missing]);
    formatHeader_(sheet);
  }
  return sheet;
}

function formatHeader_(sheet) {
  sheet.setFrozenRows(1);
  sheet.getRange(1, 1, 1, sheet.getLastColumn())
    .setBackground('#0B3A5B')
    .setFontColor('#FFFFFF')
    .setFontWeight('bold');
}

function saveEvidenceFiles_(archivos, folder, idRegistro) {
  return (archivos || []).map((file) => {
    const data = String(file.dataUrl || '').split(',');
    const meta = data[0] || '';
    const base64 = data[1] || '';
    const mime = (meta.match(/data:(.*);base64/) || [])[1] || file.tipo || 'application/octet-stream';
    const bytes = Utilities.base64Decode(base64);
    const safeName = sanitizeFileName_(idRegistro + '_' + file.id_pregunta + '_' + (file.nombre || 'evidencia'));
    const blob = Utilities.newBlob(bytes, mime, safeName);
    const created = folder.createFile(blob);
    return {
      id_pregunta: file.id_pregunta,
      nombre: file.nombre,
      url: created.getUrl(),
      id: created.getId(),
    };
  });
}

function questionHeader_(q) {
  return q.id_pregunta + ' - ' + q.pregunta;
}

function isActive_(value) {
  return String(value || '').trim().toUpperCase() === 'SI' || String(value || '').trim().toUpperCase() === 'A';
}

function normalizeId_(value) {
  return String(value || '').replace(/\D/g, '');
}

function parseDate_(value) {
  if (!value) return null;
  const parts = String(value).split('-').map(Number);
  if (parts.length !== 3) return null;
  return new Date(parts[0], parts[1] - 1, parts[2]);
}

function csvEscape_(value) {
  const text = value instanceof Date
    ? Utilities.formatDate(value, getConfig_().TIMEZONE || 'America/Bogota', 'yyyy-MM-dd HH:mm:ss')
    : String(value === null || value === undefined ? '' : value);
  return '"' + text.replace(/"/g, '""') + '"';
}

function sanitizeFileName_(name) {
  return String(name).replace(/[\\/:*?"<>|#%{}~&]/g, '_').slice(0, 180);
}
