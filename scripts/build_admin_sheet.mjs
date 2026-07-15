import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { FileBlob, SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const sourcePath =
  process.argv[2] ||
  process.env.HSQ_MATRIZ_ACTIVOS ||
  "C:/Users/Quick/Documents/CAFAM/MATRIZ/MATRIZ DE ACTIVOS JUNIO #1.xlsx";
const outputDir = path.join(repoRoot, "base");
const outputPath = `${outputDir}/Base_HSQ_Admin.xlsx`;

function excelDate(serial) {
  if (serial === null || serial === "" || Number.isNaN(Number(serial))) return null;
  return new Date(Date.UTC(1899, 11, 30) + Number(serial) * 24 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 10);
}

function yesNo(value) {
  return value ? "SI" : "NO";
}

function safe(value) {
  return value === undefined || value === null ? "" : value;
}

function writeSheet(sheet, rows, opts = {}) {
  if (!rows.length) return;
  const range = sheet.getRangeByIndexes(0, 0, rows.length, rows[0].length);
  range.values = rows;
  sheet.getRangeByIndexes(0, 0, 1, rows[0].length).format = {
    fill: opts.headerFill || "#0B3A5B",
    font: { bold: true, color: "#FFFFFF" },
  };
  range.format = {
    borders: { preset: "inside", style: "thin", color: "#D9E2EA" },
    wrapText: true,
  };
  sheet.freezePanes.freezeRows(1);
  sheet.showGridLines = false;
  try {
    range.format.autofitColumns();
    range.format.autofitRows();
  } catch {
    // Rendering remains usable if autofit is not available.
  }
}

function addTable(sheet, rows, tableName) {
  const colCount = rows[0].length;
  const rowCount = Math.max(rows.length, 2);
  const endCol = columnName(colCount);
  try {
    const table = sheet.tables.add(`A1:${endCol}${rowCount}`, true, tableName);
    table.showFilterButton = true;
    table.showBandedColumns = false;
    table.style = "TableStyleMedium2";
  } catch {
    // Tables are helpful but not required for the import to Google Sheets.
  }
}

function columnName(index1) {
  let n = index1;
  let s = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - m) / 26);
  }
  return s;
}

const input = await FileBlob.load(sourcePath);
const source = await SpreadsheetFile.importXlsx(input);
const sourceSheet = source.worksheets.getItem("LM");
const raw = sourceSheet.getRange("A1:AG947").values;
const headers = raw[0];
const idx = Object.fromEntries(headers.map((h, i) => [h, i]));

const activosRows = [
  [
    "estado_nomina",
    "tipo_documento",
    "cedula",
    "nombre",
    "cargo",
    "proyecto_id",
    "proyecto",
    "ciudad",
    "telefono",
    "celular",
    "email",
    "fecha_ingreso",
    "fecha_retiro",
    "activo_para_registro",
    "placa_moto",
    "tipo_vehiculo",
    "observaciones_hsq",
  ],
];

for (const row of raw.slice(1)) {
  if (!row[idx.ClientId] && !row[idx.ClientName]) continue;
  const state = String(safe(row[idx.State])).trim().toUpperCase();
  activosRows.push([
    safe(row[idx.State]),
    safe(row[idx.Columna1]) || "CEDULA",
    String(safe(row[idx.ClientId])),
    safe(row[idx.ClientName]),
    safe(row[idx.PlaceName]),
    safe(row[idx.ProjectId]),
    safe(row[idx.ProjectName]),
    safe(row[idx.Ciudad]),
    safe(row[idx.Phone]),
    safe(row[idx.CelPhone]),
    safe(row[idx.Email]),
    excelDate(row[idx.DateIngress]),
    excelDate(row[idx.DateRetirement]),
    yesNo(state === "A" && !row[idx.DateRetirement]),
    "",
    "MOTO",
    "",
  ]);
}

const projectMap = new Map();
for (const row of activosRows.slice(1)) {
  const id = row[5] || "SIN_ID";
  const name = row[6] || "Sin proyecto";
  if (!projectMap.has(`${id}|${name}`)) {
    projectMap.set(`${id}|${name}`, [id, name, "SI"]);
  }
}
const proyectosRows = [["proyecto_id", "proyecto", "activo"], ...Array.from(projectMap.values()).sort((a, b) => String(a[1]).localeCompare(String(b[1])))];

const formulariosRows = [
  ["id_formulario", "nombre_formulario", "descripcion", "activo", "version", "requiere_activo"],
  ["PREOPERACIONAL", "Registro diario preoperacional", "Inspeccion diaria antes de operar la moto.", "SI", "1.0", "SI"],
  ["LIMPIEZA_MOTO", "Limpieza y desinfeccion de la moto", "Registro de limpieza, desinfeccion y evidencia fotografica.", "SI", "1.0", "SI"],
];

const tiposCampoRows = [
  ["tipo_respuesta", "descripcion", "usa_opciones", "permite_archivo"],
  ["texto", "Respuesta corta de texto", "NO", "NO"],
  ["parrafo", "Respuesta larga u observaciones", "NO", "NO"],
  ["numero", "Valor numerico", "NO", "NO"],
  ["fecha", "Fecha", "NO", "NO"],
  ["hora", "Hora", "NO", "NO"],
  ["desplegable", "Lista de una sola opcion", "SI", "NO"],
  ["si_no", "Seleccion SI o NO", "NO", "NO"],
  ["checkbox", "Varias opciones", "SI", "NO"],
  ["archivo", "Adjuntar evidencia", "NO", "SI"],
];

const opcionesRows = [
  ["grupo_opciones", "valor", "activo", "orden"],
  ["cumple_no_cumple_na", "Cumple", "SI", 1],
  ["cumple_no_cumple_na", "No cumple", "SI", 2],
  ["cumple_no_cumple_na", "No aplica", "SI", 3],
  ["si_no", "SI", "SI", 1],
  ["si_no", "NO", "SI", 2],
  ["nivel_combustible", "Lleno", "SI", 1],
  ["nivel_combustible", "Medio", "SI", 2],
  ["nivel_combustible", "Bajo", "SI", 3],
  ["estado_general", "Bueno", "SI", 1],
  ["estado_general", "Regular", "SI", 2],
  ["estado_general", "Malo", "SI", 3],
  ["productos_limpieza", "Agua y jabon", "SI", 1],
  ["productos_limpieza", "Desinfectante", "SI", 2],
  ["productos_limpieza", "Alcohol", "SI", 3],
  ["productos_limpieza", "Otro", "SI", 4],
  ["resultado_limpieza", "Aprobado", "SI", 1],
  ["resultado_limpieza", "Requiere correccion", "SI", 2],
];

const preguntasRows = [
  [
    "id_pregunta",
    "id_formulario",
    "seccion",
    "orden",
    "pregunta",
    "tipo_respuesta",
    "obligatorio",
    "grupo_opciones",
    "ayuda",
    "activo",
    "respuesta_alerta",
    "evidencia_requerida_si",
  ],
  ["PRE_001", "PREOPERACIONAL", "Datos del registro", 1, "Fecha de la inspeccion", "fecha", "SI", "", "", "SI", "", ""],
  ["PRE_002", "PREOPERACIONAL", "Datos del registro", 2, "Hora de inicio", "hora", "SI", "", "", "SI", "", ""],
  ["PRE_003", "PREOPERACIONAL", "Moto", 3, "Kilometraje actual", "numero", "SI", "", "Digite solo numeros.", "SI", "", ""],
  ["PRE_004", "PREOPERACIONAL", "Moto", 4, "Nivel de combustible", "desplegable", "SI", "nivel_combustible", "", "SI", "Bajo", ""],
  ["PRE_005", "PREOPERACIONAL", "Seguridad", 5, "Estado de llantas", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_006", "PREOPERACIONAL", "Seguridad", 6, "Estado de frenos", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_007", "PREOPERACIONAL", "Seguridad", 7, "Luces, direccionales y stop funcionan correctamente", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_008", "PREOPERACIONAL", "Seguridad", 8, "Pito, espejos y tablero en buen estado", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_009", "PREOPERACIONAL", "Documentos", 9, "Documentos al dia: SOAT, tecnomecanica y licencia", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_010", "PREOPERACIONAL", "Moto", 10, "Se evidencian fugas, ruidos o fallas visibles", "si_no", "SI", "", "", "SI", "SI", "SI"],
  ["PRE_011", "PREOPERACIONAL", "Seguridad", 11, "Cuenta con elementos de proteccion personal", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["PRE_012", "PREOPERACIONAL", "Observaciones", 12, "Observaciones generales", "parrafo", "NO", "", "", "SI", "", ""],
  ["PRE_013", "PREOPERACIONAL", "Evidencia", 13, "Evidencia fotografica del estado general", "archivo", "NO", "", "Adjunte foto si hay novedad o si HSQ lo exige.", "SI", "", ""],
  ["LIM_001", "LIMPIEZA_MOTO", "Datos del registro", 1, "Fecha de limpieza y desinfeccion", "fecha", "SI", "", "", "SI", "", ""],
  ["LIM_002", "LIMPIEZA_MOTO", "Datos del registro", 2, "Hora del procedimiento", "hora", "SI", "", "", "SI", "", ""],
  ["LIM_003", "LIMPIEZA_MOTO", "Estado inicial", 3, "Estado general antes de la limpieza", "desplegable", "SI", "estado_general", "", "SI", "Malo", "SI"],
  ["LIM_004", "LIMPIEZA_MOTO", "Limpieza", 4, "Limpieza externa de la moto realizada", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["LIM_005", "LIMPIEZA_MOTO", "Limpieza", 5, "Limpieza de manubrios, tablero y zonas de contacto", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["LIM_006", "LIMPIEZA_MOTO", "Limpieza", 6, "Limpieza de baul, maletero o caja de transporte", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["LIM_007", "LIMPIEZA_MOTO", "Desinfeccion", 7, "Desinfeccion de superficies de contacto realizada", "desplegable", "SI", "cumple_no_cumple_na", "", "SI", "No cumple", "SI"],
  ["LIM_008", "LIMPIEZA_MOTO", "Desinfeccion", 8, "Productos utilizados", "checkbox", "SI", "productos_limpieza", "Puede seleccionar varios.", "SI", "", ""],
  ["LIM_009", "LIMPIEZA_MOTO", "Evidencia", 9, "Evidencia antes de la limpieza", "archivo", "NO", "", "", "SI", "", ""],
  ["LIM_010", "LIMPIEZA_MOTO", "Evidencia", 10, "Evidencia despues de la limpieza", "archivo", "SI", "", "", "SI", "", ""],
  ["LIM_011", "LIMPIEZA_MOTO", "Responsable", 11, "Responsable que realiza el registro", "texto", "SI", "", "Se puede diligenciar automaticamente con la cedula.", "SI", "", ""],
  ["LIM_012", "LIMPIEZA_MOTO", "Observaciones", 12, "Observaciones generales", "parrafo", "NO", "", "", "SI", "", ""],
  ["LIM_013", "LIMPIEZA_MOTO", "Resultado", 13, "Resultado final de limpieza", "desplegable", "SI", "resultado_limpieza", "", "SI", "Requiere correccion", "SI"],
];

const configRows = [
  ["parametro", "valor", "descripcion"],
  ["ROOT_FOLDER_NAME", "Registros HSQ", "Carpeta principal donde Apps Script organizara mes, dia y evidencias."],
  ["TIMEZONE", "America/Bogota", "Zona horaria para fechar carpetas y registros."],
  ["DAILY_STORAGE", "MES/DIA/FORMULARIO", "Estructura objetivo: ano/mes/dia/archivo por formulario."],
  ["EXPORT_FOLDER_NAME", "Exportables HSQ", "Carpeta donde se guardan archivos CSV exportados."],
  ["MAX_REGISTROS_DIA_ESTIMADO", 1000, "Volumen diario esperado."],
  ["PREGUNTAS_PROMEDIO_FORMULARIO", 13, "Cantidad promedio indicada por HSQ."],
  ["WEB_APP_URL", "https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec", "URL oficial que usan mensajeros, coordinadores y HSQ."],
];

const instruccionesRows = [
  ["Modulo", "Uso"],
  ["Matriz_Activos", "Actualizar altas, retiros, proyecto, placa y estado. El formulario solo permite registros si activo_para_registro = SI."],
  ["Formularios", "Activar o desactivar formularios completos."],
  ["Preguntas", "Agregar, quitar, ordenar o modificar preguntas. Use id_pregunta estable para no romper historicos."],
  ["Opciones", "Administrar listas desplegables y casillas multiples."],
  ["Proyectos", "Lista de proyectos para filtrar exportables por uno o varios proyectos."],
  ["Apps Script", "Pegar Code.gs e Index.html en un proyecto de Apps Script vinculado a esta base."],
  ["Nota formularios actuales", "Los enlaces de Google Forms indicados solicitan acceso/cookies, por eso las preguntas iniciales son una precarga editable."],
];

const exportadorRows = [
  ["campo", "tipo", "descripcion"],
  ["fecha_inicio", "fecha", "Fecha inicial del exportable."],
  ["fecha_fin", "fecha", "Fecha final del exportable."],
  ["proyectos", "multi_desplegable", "Uno o varios proyectos; vacio equivale a todos."],
  ["formularios", "multi_desplegable", "Uno o varios formularios; vacio equivale a todos."],
  ["formato", "desplegable", "CSV inicialmente; XLSX se puede agregar como segunda fase."],
];

const respuestasEjemploRows = [
  [
    "timestamp",
    "fecha_registro",
    "id_registro",
    "id_formulario",
    "cedula",
    "nombre",
    "proyecto_id",
    "proyecto",
    "ciudad",
    "placa_moto",
    "estado_registro",
    "respuestas_json",
    "evidencias_json",
  ],
  [
    new Date(),
    new Date(),
    "PREOPERACIONAL-20260715-000001",
    "PREOPERACIONAL",
    "1026142877",
    "EJEMPLO TRABAJADOR",
    "432",
    "ICONTEC - INT. COL NORMAS TECNICAS CC 220508200002",
    "MEDELLIN",
    "",
    "OK",
    '{"PRE_001":"2026-07-15","PRE_005":"Cumple"}',
    "[]",
  ],
];

const workbook = Workbook.create();
const sheets = {
  instrucciones: workbook.worksheets.add("Instrucciones"),
  config: workbook.worksheets.add("Configuracion"),
  activos: workbook.worksheets.add("Matriz_Activos"),
  proyectos: workbook.worksheets.add("Proyectos"),
  formularios: workbook.worksheets.add("Formularios"),
  preguntas: workbook.worksheets.add("Preguntas"),
  opciones: workbook.worksheets.add("Opciones"),
  tipos: workbook.worksheets.add("Tipos_Campo"),
  exportador: workbook.worksheets.add("Exportador_Config"),
  ejemplo: workbook.worksheets.add("Respuestas_Ejemplo"),
};

const sheetRows = [
  [sheets.instrucciones, instruccionesRows, "Tabla_Instrucciones"],
  [sheets.config, configRows, "Tabla_Configuracion"],
  [sheets.activos, activosRows, "Tabla_Matriz_Activos"],
  [sheets.proyectos, proyectosRows, "Tabla_Proyectos"],
  [sheets.formularios, formulariosRows, "Tabla_Formularios"],
  [sheets.preguntas, preguntasRows, "Tabla_Preguntas"],
  [sheets.opciones, opcionesRows, "Tabla_Opciones"],
  [sheets.tipos, tiposCampoRows, "Tabla_Tipos_Campo"],
  [sheets.exportador, exportadorRows, "Tabla_Exportador_Config"],
  [sheets.ejemplo, respuestasEjemploRows, "Tabla_Respuestas_Ejemplo"],
];

for (const [sheet, rows, tableName] of sheetRows) {
  writeSheet(sheet, rows);
  addTable(sheet, rows, tableName);
}

sheets.activos.getRange("L:M").format = { numberFormat: "yyyy-mm-dd" };
sheets.ejemplo.getRange("A:B").format = { numberFormat: "yyyy-mm-dd hh:mm" };
sheets.instrucciones.getRange("A1:B1").format = { fill: "#006D77", font: { bold: true, color: "#FFFFFF" } };
sheets.config.getRange("A1:C1").format = { fill: "#006D77", font: { bold: true, color: "#FFFFFF" } };

try {
  sheets.formularios.dataValidations.add({
    range: "D2:D200",
    rule: { type: "list", values: ["SI", "NO"] },
  });
  sheets.preguntas.dataValidations.add({
    range: "F2:F500",
    rule: { type: "list", values: tiposCampoRows.slice(1).map((r) => r[0]) },
  });
  sheets.preguntas.dataValidations.add({
    range: "G2:G500",
    rule: { type: "list", values: ["SI", "NO"] },
  });
  sheets.preguntas.dataValidations.add({
    range: "J2:J500",
    rule: { type: "list", values: ["SI", "NO"] },
  });
} catch {
  // Validation rules can be added directly in Google Sheets if conversion omits them.
}

const errors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 100 },
  summary: "final formula error scan",
});
console.log(errors.ndjson);

await fs.mkdir(outputDir, { recursive: true });
const preview = await workbook.render({
  sheetName: "Preguntas",
  range: "A1:L28",
  scale: 1,
  format: "png",
});
await fs.writeFile(`${outputDir}/preview_preguntas.png`, new Uint8Array(await preview.arrayBuffer()));

const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(JSON.stringify({ outputPath, rows: { activos: activosRows.length - 1, proyectos: proyectosRows.length - 1, preguntas: preguntasRows.length - 1 } }, null, 2));
