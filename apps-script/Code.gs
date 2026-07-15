const HSQ_DEFAULT_ROOT = 'Registros HSQ';
const HSQ_EXPORT_FOLDER = 'Exportables HSQ';
const HSQ_ADMIN_SPREADSHEET_ID = '1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8';

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
      case 'registrarPlaca': result = registrarPlaca(payload.cedula, payload.placa); break;
      case 'cargarFormulario': result = cargarFormulario(payload.id_formulario); break;
      case 'guardarRegistro': result = guardarRegistro(payload); break;
      case 'generarExportable': result = generarExportable(payload); break;
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
  }
  return resp;
}

/**
 * Guarda por primera vez la placa del colaborador en Matriz_Activos.
 * Despues de esto, buscarActivo ya no volvera a pedirla.
 */
function registrarPlaca(cedula, placa) {
  const key = normalizeId_(cedula);
  if (!key) throw new Error('Digite una cedula valida.');
  const placaClean = String(placa || '').trim().toUpperCase();
  if (!placaClean) throw new Error('Digite una placa valida.');

  const sheet = getAdminSpreadsheet_().getSheetByName('Matriz_Activos');
  if (!sheet) throw new Error('No existe la hoja Matriz_Activos.');
  const values = sheet.getDataRange().getValues();
  const headers = values[0].map(function (h) { return String(h).trim(); });
  const cedIdx = headers.indexOf('cedula');
  const placaIdx = headers.indexOf('placa_moto');
  if (cedIdx === -1 || placaIdx === -1) throw new Error('Faltan columnas cedula o placa_moto en Matriz_Activos.');

  for (let i = 1; i < values.length; i++) {
    if (normalizeId_(values[i][cedIdx]) === key) {
      sheet.getRange(i + 1, placaIdx + 1).setValue(placaClean);
      return { ok: true, placa_moto: placaClean };
    }
  }
  throw new Error('No se encontro la cedula en Matriz_Activos.');
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

  const preguntas = readObjects_('Preguntas')
    .filter((q) => q.id_formulario === idFormulario && isActive_(q.activo))
    .sort((a, b) => Number(a.orden || 0) - Number(b.orden || 0));

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
    validarRespuestas_(preguntas, respuestas, archivos);

    const now = new Date();
    const tz = getConfig_().TIMEZONE || Session.getScriptTimeZone() || 'America/Bogota';
    const fecha = Utilities.formatDate(now, tz, 'yyyy-MM-dd');
    const hora = Utilities.formatDate(now, tz, 'HH:mm:ss');
    const idRegistro = [
      payload.id_formulario,
      Utilities.formatDate(now, tz, 'yyyyMMdd-HHmmss'),
      normalizeId_(payload.cedula),
    ].join('-');

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

      values.forEach((row) => {
        if (String(row[formIdx] || '') !== formId) return;
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
  const name = 'Exportable_' + formId + '_' + Utilities.formatDate(new Date(), tz, 'yyyyMMdd_HHmmss') + '.csv';
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

function readObjects_(sheetName) {
  const sheet = getAdminSpreadsheet_().getSheetByName(sheetName);
  if (!sheet) throw new Error('No existe la hoja ' + sheetName);
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values.shift().map((h) => String(h).trim());
  return values
    .filter((row) => row.some((cell) => cell !== '' && cell !== null))
    .map((row) => {
      const obj = {};
      headers.forEach((header, i) => {
        obj[header] = row[i];
      });
      return obj;
    });
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
