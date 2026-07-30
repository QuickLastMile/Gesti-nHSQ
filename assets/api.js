/* ============================================================
   Cliente de API — Gestión HSEQ Motos
   Habla con el backend de Apps Script (desplegado como Web App).
   Usa POST con cuerpo de texto plano para evitar el "preflight"
   de CORS que bloquea a las páginas de GitHub Pages.
   Si no hay API_URL configurada, cae en modo DEMO.
   ============================================================ */
(function () {
  const CFG = window.HSQ_CONFIG || {};
  const configured =
    typeof CFG.API_URL === 'string' &&
    CFG.API_URL.indexOf('/exec') !== -1 &&
    !/PEGUE_AQUI|TU_URL/i.test(CFG.API_URL);

  // Modo base de datos (Supabase): solo si la URL trae ?db=1. Producción no se afecta.
  const supaCfg = CFG.SUPABASE_URL && CFG.SUPABASE_KEY && /supabase\.co/.test(CFG.SUPABASE_URL);
  let supaOn = false;
  try { supaOn = supaCfg && new URLSearchParams(location.search).get('db') === '1'; } catch (e) { supaOn = false; }

  async function call(action, payload = {}) {
    if (supaOn) return supabaseCall(action, payload);
    if (!configured) return demo(action, payload);

    let res;
    try {
      res = await fetch(CFG.API_URL, {
        method: 'POST',
        // Sin cabecera Content-Type: fetch envía text/plain => petición simple, sin preflight CORS.
        body: JSON.stringify({ action, payload }),
        redirect: 'follow',
      });
    } catch (err) {
      throw new Error('No se pudo conectar con el servidor. Revisa tu conexión a internet.');
    }

    let data;
    try {
      data = await res.json();
    } catch (e) {
      throw new Error('El servidor respondió en un formato inesperado. Verifica que el Apps Script esté desplegado con acceso "Cualquier persona".');
    }

    if (!data || data.ok !== true) {
      throw new Error((data && data.error) || 'Error del servidor.');
    }
    return data.result;
  }

  /* -------------------- Modo BASE DE DATOS (Supabase) -------------------- */
  // Llamada base a la función hseq_api de Postgres.
  async function rpc(action, payload = {}) {
    let res;
    try {
      res = await fetch(CFG.SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/hseq_api', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: CFG.SUPABASE_KEY,
          Authorization: 'Bearer ' + CFG.SUPABASE_KEY,
        },
        body: JSON.stringify({ action, payload }),
      });
    } catch (err) {
      throw new Error('No se pudo conectar con la base de datos. Revisa tu conexión.');
    }
    let data;
    try { data = await res.json(); } catch (e) {
      throw new Error('La base de datos respondió en un formato inesperado.');
    }
    // Si PostgREST devuelve un error propio (permiso, función inexistente…)
    if (data && data.message && data.ok === undefined) {
      throw new Error('Base de datos: ' + data.message);
    }
    if (!data || data.ok !== true) {
      throw new Error((data && data.error) || 'Error de la base de datos.');
    }
    return data.result;
  }

  async function supabaseCall(action, payload = {}) {
    // Al guardar registro, primero se suben las fotos al almacenamiento y se
    // reemplazan por sus enlaces (una función SQL no puede recibir archivos).
    if (action === 'guardarRegistro') {
      payload = await prepararRegistro(payload);
    }
    // El exportable se arma en el navegador a partir de los datos de la base.
    if (action === 'generarExportable') {
      return exportableSupabase(payload);
    }

    let result = await rpc(action, payload);
    if (action === 'cargarFormulario' && payload && payload.id_formulario === 'PREOPERACIONAL') {
      result = inyectarDocsPreoperacional(result);
    }
    return result;
  }

  // Bloque de documentación que se antepone al preoperacional (igual que el backend).
  const DOCS_PREOP = [
    { id_pregunta: 'DOC_PRIMERA_O_RENOVACION', orden: 0, seccion: 'Documentación del vehículo', pregunta: '¿Es la primera inspección del vehículo, o renovaste el SOAT o la Tecnomecánica?', tipo_respuesta: 'si_no', obligatorio: 'SI', ayuda: 'Si respondes SÍ, debes adjuntar la documentación del vehículo.' },
    { id_pregunta: 'DOC_LICENCIA_TRANSITO', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Licencia de Tránsito (Tarjeta de Propiedad)', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI', documento: 'LICENCIA' },
    { id_pregunta: 'DOC_SOAT', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'SOAT', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI', documento: 'SOAT' },
    { id_pregunta: 'DOC_TECNOMECANICA', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Revisión Tecnomecánica', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI', documento: 'TECNOMECANICA' },
    { id_pregunta: 'DOC_MARCA_VEHICULO', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Marca del vehículo', tipo_respuesta: 'texto', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
    { id_pregunta: 'DOC_CILINDRAJE', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Tipo de cilindraje (CC)', tipo_respuesta: 'numero', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
    { id_pregunta: 'DOC_PROP_NOMBRE', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Nombre del propietario del vehículo', tipo_respuesta: 'texto', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
    { id_pregunta: 'DOC_PROP_CEDULA', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Cédula del propietario del vehículo', tipo_respuesta: 'numero', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
    { id_pregunta: 'DOC_VIN', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'VIN (Número de Identificación Vehicular)', tipo_respuesta: 'texto', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
  ];
  function sinT(s) {
    return String(s == null ? '' : s)
      .replace(/[áàäâÁÀÄÂ]/g, 'A').replace(/[éèëêÉÈËÊ]/g, 'E').replace(/[íìïîÍÌÏÎ]/g, 'I')
      .replace(/[óòöôÓÒÖÔ]/g, 'O').replace(/[úùüûÚÙÜÛ]/g, 'U').replace(/[ñÑ]/g, 'N').toUpperCase();
  }
  function docKeyApi(q) {
    if (String(q.tipo_respuesta || '').trim() !== 'fecha') return '';
    const doc = sinT(q.documento).trim();
    if (doc === 'SOAT' || doc === 'TECNOMECANICA' || doc === 'LICENCIA') return doc;
    const t = sinT(q.pregunta);
    if (t.indexOf('SOAT') !== -1) return 'SOAT';
    if (/TECNO|TECNIC|MECANIC/.test(t)) return 'TECNOMECANICA';
    if (t.indexOf('LICENCIA') !== -1) return 'LICENCIA';
    return '';
  }
  function inyectarDocsPreoperacional(data) {
    const pregs = (data && data.preguntas) || [];
    const fechasHoja = {}, resto = [];
    pregs.forEach((q) => { const k = docKeyApi(q); if (k && !fechasHoja[k]) fechasHoja[k] = q; else resto.push(q); });
    const bloque = [];
    DOCS_PREOP.forEach((d) => {
      bloque.push(d);
      const k = sinT(d.documento).trim();
      if (k && fechasHoja[k]) { bloque.push(fechasHoja[k]); delete fechasHoja[k]; }
    });
    Object.keys(fechasHoja).forEach((k) => bloque.push(fechasHoja[k]));
    data.preguntas = bloque.concat(resto);
    return data;
  }

  // Pide los datos a la base y arma el CSV en el navegador (sin Drive).
  async function exportableSupabase(filtros) {
    const p = {
      formulario: (filtros.formularios && filtros.formularios[0]) || filtros.formulario || '',
      fechaInicio: filtros.fechaInicio,
      fechaFin: filtros.fechaFin,
      proyecto: (filtros.proyectos && filtros.proyectos[0]) || filtros.proyecto || '',
      cedula: filtros.cedula || '',
    };
    const r = await rpc('generarExportable', p);

    const base = ['fecha', 'hora', 'cedula', 'nombre', 'cargo', 'proyecto_id', 'proyecto',
      'ciudad', 'placa_moto', 'tipo_vehiculo', 'estado', 'estado_cumplimiento',
      'alertas_documentales', 'id_registro'];
    const preg = r.preguntas || [];
    // Solo columnas de evidencia que realmente tengan algún archivo.
    const evIds = [];
    (r.filas || []).forEach((f) => Object.keys(f.evidencias || {}).forEach((k) => {
      if (evIds.indexOf(k) === -1) evIds.push(k);
    }));

    const encabezados = base
      .concat(preg.map((q) => q.id + ' - ' + q.pregunta))
      .concat(evIds.map((id) => 'Evidencia ' + id));

    const esc = (v) => '"' + String(v === null || v === undefined ? '' : v).replace(/"/g, '""') + '"';
    const lineas = [encabezados.map(esc).join(',')];
    (r.filas || []).forEach((f) => {
      const fila = base.map((c) => f[c])
        .concat(preg.map((q) => (f.respuestas || {})[q.id] || ''))
        .concat(evIds.map((id) => (f.evidencias || {})[id] || ''));
      lineas.push(fila.map(esc).join(','));
    });

    // BOM UTF-8 + CRLF para que Excel muestre bien tildes y columnas.
    const csv = '﻿' + lineas.join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }));
    const sufijo = p.cedula ? '_CC' + p.cedula : '';
    const stamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '').slice(0, 15);
    return {
      ok: true, filas: r.total || 0, columnas: encabezados.length,
      nombre: 'Exportable_' + p.formulario + sufijo + '_' + stamp + '.csv',
      url: url, downloadUrl: url, esArchivoLocal: true,
    };
  }

  // Sube las fotos al almacenamiento y arma el registro con sus enlaces.
  async function prepararRegistro(payload) {
    const evidencias = [];
    for (const a of (payload.archivos || [])) {
      evidencias.push(await subirEvidencia(a, payload.cedula, payload.id_formulario));
    }
    return {
      cedula: payload.cedula,
      id_formulario: payload.id_formulario,
      respuestas: payload.respuestas,
      evidencias,
    };
  }

  // Sesión anónima: Storage necesita un token de usuario (no solo la llave anon)
  // para permitir la subida. Se crea un usuario temporal y se reutiliza su token.
  let _stToken = null;
  async function tokenStorage() {
    if (_stToken) return _stToken;
    const cache = sessionStorage.getItem('hsq_st_token');
    if (cache) { _stToken = cache; return _stToken; }
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');
    let res;
    try {
      res = await fetch(base + '/auth/v1/signup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
        body: JSON.stringify({}),
      });
    } catch (e) { throw new Error('No se pudo preparar la subida de fotos (conexión).'); }
    const data = await res.json();
    if (!data || !data.access_token) {
      throw new Error('Para subir fotos, activa "Anonymous sign-ins" en Supabase (Authentication).');
    }
    _stToken = data.access_token;
    sessionStorage.setItem('hsq_st_token', _stToken);
    return _stToken;
  }

  // Documentos del vehículo: ruta FIJA por persona -> al renovar, el archivo
  // nuevo reemplaza al anterior (no se acumula). Evidencias normales: ruta única.
  const DOC_ARCHIVO = { DOC_SOAT: 'SOAT', DOC_TECNOMECANICA: 'TECNOMECANICA', DOC_LICENCIA_TRANSITO: 'LICENCIA' };

  async function subirEvidencia(a, cedula, fid) {
    const blob = dataURLaBlob(a.dataUrl);
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');
    const ced = cedula || 'sin_cedula';
    const stamp = Date.now() + '_' + Math.random().toString(36).slice(2, 8);
    let path;
    if (DOC_ARCHIVO[a.id_pregunta]) {
      path = ['documentos', ced, DOC_ARCHIVO[a.id_pregunta] + '_' + stamp + '.jpg'].map(encodeURIComponent).join('/');
    } else {
      const hoy = new Date().toISOString().slice(0, 10);
      path = [ced, hoy, fid + '_' + a.id_pregunta + '_' + stamp + '.jpg'].map(encodeURIComponent).join('/');
    }
    const st = await tokenStorage();
    const headers = {
      apikey: CFG.SUPABASE_KEY,
      Authorization: 'Bearer ' + st,
      'Content-Type': blob.type || 'image/jpeg',
    };
    let res;
    try {
      res = await fetch(base + '/storage/v1/object/evidencias/' + path, {
        method: 'POST',
        headers: headers,
        body: blob,
      });
    } catch (e) {
      throw new Error('No se pudo subir la evidencia. Revisa tu conexión.');
    }
    if (!res.ok) {
      let msg = '';
      try { msg = (await res.json()).message || ''; } catch (e) { /* noop */ }
      throw new Error('No se pudo subir la evidencia' + (msg ? ': ' + msg : '') + '. Verifica el permiso del bucket "evidencias".');
    }
    return {
      id_pregunta: a.id_pregunta,
      nombre: a.nombre || 'evidencia.jpg',
      path: path,
      url: base + '/storage/v1/object/public/evidencias/' + path,
    };
  }

  function dataURLaBlob(dataUrl) {
    const partes = String(dataUrl || '').split(',');
    const mime = (partes[0].match(/data:(.*?);base64/) || [])[1] || 'image/jpeg';
    const bin = atob(partes[1] || '');
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return new Blob([arr], { type: mime });
  }

  /* -------------------- Modo DEMO -------------------- */
  function demo(action, payload) {
    const wait = (v) => new Promise((r) => setTimeout(() => r(v), 350));
    if (action === 'getBootstrap') {
      return wait({
        formularios: [
          { id_formulario: 'PREOPERACIONAL', nombre_formulario: 'Registro diario preoperacional' },
          { id_formulario: 'LIMPIEZA_MOTO', nombre_formulario: 'Limpieza y desinfección de la moto' },
        ],
        proyectos: [
          { proyecto_id: '432', proyecto: 'ICONTEC - INT. COL NORMAS TECNICAS' },
          { proyecto_id: '440', proyecto: 'GASES LINDE COLOMBIA S.A.' },
        ],
      });
    }
    if (action === 'buscarActivo') {
      return wait({
        encontrado: true,
        activo: true,
        mensaje: 'Activo habilitado para registro.',
        requierePlaca: false,
        formulariosRequeridos: [
          { id_formulario: 'PREOPERACIONAL', nombre_formulario: 'Registro diario preoperacional' },
          { id_formulario: 'LIMPIEZA_MOTO', nombre_formulario: 'Limpieza y desinfección de la moto' },
        ],
        estadoDiario: {
          PREOPERACIONAL: { hecho: false },
          LIMPIEZA_MOTO: { hecho: false },
        },
        documentos: {
          SOAT: { fecha: '2026-12-01', dias: 138, estado: 'ok' },
          TECNOMECANICA: { fecha: '2026-08-05', dias: 20, estado: 'por_vencer' },
          LICENCIA: { fecha: '', dias: null, estado: 'sin_dato' },
        },
        datos: {
          cedula: payload.cedula,
          nombre: 'EJEMPLO COLABORADOR',
          cargo: 'QUICKER - MENSAJERO',
          proyecto: 'Proyecto de ejemplo',
          ciudad: 'MEDELLÍN',
          placa_moto: 'ABC12D',
        },
      });
    }
    if (action === 'registrarPlaca') {
      return wait({ ok: true, placa_moto: String(payload.placa || '').toUpperCase() });
    }
    if (action === 'cargarFormulario') {
      const id = payload.id_formulario;
      const opciones = {
        cumple_no_cumple_na: ['Cumple', 'No cumple', 'No aplica'],
        productos_limpieza: ['Agua y jabón', 'Desinfectante', 'Alcohol', 'Otro'],
      };
      const preguntas = id === 'LIMPIEZA_MOTO'
        ? [
            { id_pregunta: 'LIM_001', orden: 1, seccion: 'Datos', pregunta: 'Fecha de limpieza', tipo_respuesta: 'fecha', obligatorio: 'SI' },
            { id_pregunta: 'LIM_008', orden: 2, seccion: 'Desinfección', pregunta: 'Productos utilizados', tipo_respuesta: 'checkbox', obligatorio: 'SI', grupo_opciones: 'productos_limpieza' },
            { id_pregunta: 'LIM_010', orden: 3, seccion: 'Evidencia', pregunta: 'Foto después de la limpieza', tipo_respuesta: 'archivo', obligatorio: 'SI' },
          ]
        : [
            { id_pregunta: 'DOC_PRIMERA_O_RENOVACION', orden: 0, seccion: 'Documentación del vehículo', pregunta: '¿Es la primera inspección del vehículo, o renovaste el SOAT o la Tecnomecánica?', tipo_respuesta: 'si_no', obligatorio: 'SI', ayuda: 'Si respondes SÍ, debes adjuntar la documentación.' },
            { id_pregunta: 'DOC_LICENCIA_TRANSITO', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Licencia de Tránsito (Tarjeta de Propiedad)', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
            { id_pregunta: 'DOC_SOAT', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'SOAT', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
            { id_pregunta: 'DOC_TECNOMECANICA', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Revisión Tecnomecánica', tipo_respuesta: 'archivo', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
            { id_pregunta: 'DOC_MARCA_VEHICULO', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Marca del vehículo', tipo_respuesta: 'texto', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
            { id_pregunta: 'DOC_CILINDRAJE', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Tipo de cilindraje (CC)', tipo_respuesta: 'numero', obligatorio: 'SI', depende_de: 'DOC_PRIMERA_O_RENOVACION', depende_valor: 'SI' },
            { id_pregunta: 'PRE_001', orden: 1, seccion: 'Datos', pregunta: 'Fecha de la inspección', tipo_respuesta: 'fecha', obligatorio: 'SI' },
            { id_pregunta: 'PRE_003', orden: 2, seccion: 'Moto', pregunta: 'Kilometraje actual', tipo_respuesta: 'numero', obligatorio: 'SI' },
            { id_pregunta: 'PRE_005', orden: 3, seccion: 'Seguridad', pregunta: 'Estado de llantas', tipo_respuesta: 'desplegable', obligatorio: 'SI', grupo_opciones: 'cumple_no_cumple_na' },
            { id_pregunta: 'PRE_013', orden: 4, seccion: 'Evidencia', pregunta: 'Evidencia fotográfica', tipo_respuesta: 'archivo', obligatorio: 'NO' },
          ];
      return wait({ formulario: { id_formulario: id }, preguntas, opciones });
    }
    if (action === 'guardarRegistro') {
      const idForm = payload.id_formulario;
      const otro = idForm === 'PREOPERACIONAL' ? 'LIMPIEZA_MOTO' : 'PREOPERACIONAL';
      const hora = new Date().toTimeString().slice(0, 8);
      // En demo, el segundo registro completa el día.
      const completo = window.__demoDone === true;
      const estadoDiario = {};
      estadoDiario[idForm] = { hecho: true, idRegistro: 'DEMO-' + idForm, hora: hora };
      estadoDiario[otro] = window.__demoDone ? { hecho: true, idRegistro: 'DEMO-' + otro, hora: hora } : { hecho: false };
      window.__demoDone = true;
      return wait({
        ok: true, idRegistro: 'DEMO-' + idForm, estado: 'OK', alertas: [], archivoDiaUrl: '#',
        estadoDiario: estadoDiario, completo: completo,
        comprobante: {
          nombre: 'EJEMPLO COLABORADOR', cedula: '1017654321', placa_moto: 'ABC12D',
          proyecto: 'Proyecto de ejemplo', ciudad: 'MEDELLÍN',
          fecha: new Date().toISOString().slice(0, 10), completo: completo,
          registros: Object.keys(estadoDiario).filter((k) => estadoDiario[k].hecho).map((k) => ({
            id_formulario: k, formulario: k, hora: estadoDiario[k].hora, idRegistro: estadoDiario[k].idRegistro,
          })),
        },
      });
    }
    if (action === 'generarExportable') {
      return wait({ ok: true, filas: 12, columnas: 20, formulario: (payload.formularios || ['DEMO'])[0], url: '#', downloadUrl: '#', nombre: 'Exportable_DEMO.csv' });
    }
    if (action === 'getCumplimientoDia') {
      const forms = [
        { id: 'PREOPERACIONAL', nombre: 'Preoperacional' },
        { id: 'LIMPIEZA_MOTO', nombre: 'Limpieza' },
      ];
      const personas = [
        { cedula: '1017654321', nombre: 'ANA DEMO', proyecto: 'Proyecto de ejemplo', ciudad: 'MEDELLÍN', placa: 'ABC12D',
          estados: { PREOPERACIONAL: { hecho: false, hora: '' }, LIMPIEZA_MOTO: { hecho: false, hora: '' } }, completo: false, justificado: false, justificacion: null },
        { cedula: '1020304050', nombre: 'CARLOS DEMO', proyecto: 'Proyecto de ejemplo', ciudad: 'BOGOTÁ', placa: 'XYZ98Z',
          estados: { PREOPERACIONAL: { hecho: true, hora: '06:12' }, LIMPIEZA_MOTO: { hecho: true, hora: '07:40' } }, completo: true, justificado: false, justificacion: null },
        { cedula: '1030405060', nombre: 'LUIS DEMO', proyecto: 'Proyecto de ejemplo', ciudad: 'CALI', placa: 'JKL45M',
          estados: { PREOPERACIONAL: { hecho: false, hora: '' }, LIMPIEZA_MOTO: { hecho: false, hora: '' } }, completo: false, justificado: true, justificacion: { tipo: 'VACACIONES', motivo: 'Vacaciones' } },
      ];
      return wait({
        fecha: payload.fecha, proyecto: payload.proyecto || '', formularios: forms, personas: personas,
        resumen: { total: 3, completos: 1, pendientes: 1, justificados: 1, esperados: 2, porcentaje: 50 },
      });
    }
    if (action === 'guardarJustificacion') {
      return wait({ ok: true, actualizado: false });
    }
    if (action === 'getDashboard') {
      return wait({
        anio: Number(payload.anio) || 2026, mes: payload.mes ? Number(payload.mes) : null, proyecto: payload.proyecto || '',
        resumen: { activos: 90, realizadas: 2480, esperadas: 5040, no_realizadas: 2560, porcentaje: 49.2 },
        por_mes: [
          { etiqueta: '2026-06', realizadas: 79, esperadas: 180, no_realizadas: 101, porcentaje: 43.9 },
          { etiqueta: '2026-07', realizadas: 2401, esperadas: 4860, no_realizadas: 2459, porcentaje: 49.4 },
        ],
        por_proyecto: [
          { proyecto: 'ICONTEC - INT. COL NORMAS TECNICAS', realizadas: 1200, esperadas: 2000, no_realizadas: 800, porcentaje: 60 },
          { proyecto: 'GASES LINDE COLOMBIA S.A.', realizadas: 1280, esperadas: 3040, no_realizadas: 1760, porcentaje: 42.1 },
        ],
      });
    }
    if (action === 'getMatrizInfo') {
      return wait({ ultimaActualizacion: '2026-07-15 09:30 (demo)' });
    }
    if (action === 'actualizarMatriz') {
      return wait({ ok: true, actualizados: 8, nuevos: 2, inactivados: 1, reactivados: 0, totalEnData: 10, fecha: new Date().toISOString().slice(0, 16).replace('T', ' ') });
    }
    return Promise.reject(new Error('Acción demo no soportada: ' + action));
  }

  window.HSQ_API = {
    call,
    isDemo: !supaOn && !configured,
    backend: supaOn ? 'supabase' : (configured ? 'appsscript' : 'demo'),
  };
})();
