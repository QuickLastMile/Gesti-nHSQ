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
  const supaOn = Boolean(supaCfg);

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
  // Sesión del coordinador / HSQ (los tokens de Supabase caducan cada hora).
  function claveSesion() {
    return sessionStorage.getItem('hsq_coord_token') ? 'hsq_coord_token'
         : (sessionStorage.getItem('hsq_admin_token') ? 'hsq_admin_token' : '');
  }
  function tokenSesion() {
    return sessionStorage.getItem('hsq_coord_token') || sessionStorage.getItem('hsq_admin_token') || '';
  }
  function guardarSesion(d, tipo) {
    if (!d || !d.access_token) return false;
    sessionStorage.setItem(tipo === 'admin' ? 'hsq_admin_token' : 'hsq_coord_token', d.access_token);
    if (d.refresh_token) sessionStorage.setItem('hsq_refresh_token', d.refresh_token);
    return true;
  }
  function cerrarSesion() {
    // Tambien la linea: si entra otra persona en esta pestana, no debe
    // heredar la linea que dejo seleccionada la anterior.
    ['hsq_coord_token', 'hsq_admin_token', 'hsq_refresh_token', 'hsq_linea']
      .forEach((k) => sessionStorage.removeItem(k));
  }

  // Renueva el token con el refresh_token guardado en el login.
  async function refrescarSesion() {
    const rt = sessionStorage.getItem('hsq_refresh_token');
    const clave = claveSesion();
    if (!rt || !clave) return false;
    try {
      const res = await fetch(CFG.SUPABASE_URL.replace(/\/$/, '') + '/auth/v1/token?grant_type=refresh_token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
        body: JSON.stringify({ refresh_token: rt }),
      });
      const d = await res.json();
      if (!d || !d.access_token) return false;
      sessionStorage.setItem(clave, d.access_token);
      if (d.refresh_token) sessionStorage.setItem('hsq_refresh_token', d.refresh_token);
      return true;
    } catch (e) { return false; }
  }

  function errorSesion() {
    const err = new Error('Tu sesión expiró. Vuelve a iniciar sesión.');
    err.sesionExpirada = true;
    return err;
  }

  // Llamada base a la función hseq_api de Postgres.
  async function rpc(action, payload = {}, reintento) {
    const sessionToken = tokenSesion();
    // La linea activa acompana a toda consulta con sesion. El servidor la
    // valida igual: esto es comodidad, no seguridad.
    if (sessionToken && !payload.linea) {
      const l = lineaActiva();
      if (l) payload = Object.assign({}, payload, { linea: l });
    }
    let res;
    try {
      res = await fetch(CFG.SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/hseq_api', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: CFG.SUPABASE_KEY,
          Authorization: 'Bearer ' + (sessionToken || CFG.SUPABASE_KEY),
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
      // Token caducado: se renueva solo y se reintenta una vez.
      if (/jwt (expired|invalid)|invalid.*jwt|token.*expir/i.test(data.message)) {
        if (!reintento && await refrescarSesion()) return rpc(action, payload, true);
        cerrarSesion();
        throw errorSesion();
      }
      throw new Error('Base de datos: ' + data.message);
    }
    if (!data || data.ok !== true) {
      const msg = (data && data.error) || 'Error de la base de datos.';
      if (/inicia(r)? sesion|debes iniciar/i.test(msg)) throw errorSesion();
      throw new Error(msg);
    }
    return data.result;
  }


  // Llama una funcion SQL sin pasar por el router. Se usa para las que
  // necesitan la linea del desplegable y cambiar el router saldria caro.
  async function rpcDirecto(fn, payload) {
    const token = tokenSesion();
    const res = await fetch(CFG.SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: CFG.SUPABASE_KEY,
        Authorization: 'Bearer ' + (token || CFG.SUPABASE_KEY),
      },
      body: JSON.stringify(payload || {}),
    });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!data || data.message) throw new Error((data && data.message) || 'Error de la base de datos.');
    return data;
  }

  // ---------- Restablecer la contrasena ----------
  // Manda el correo con el enlace. El 'redirect_to' apunta a clave.html,
  // que es la pantalla que sabe recibirlo; hay que tenerla listada en
  // Supabase -> Authentication -> URL Configuration -> Redirect URLs, o
  // Supabase la ignora y devuelve al Site URL.
  async function pedirRestablecer(email) {
    const correo = String(email || '').trim();
    if (!correo) throw new Error('Escribe tu correo.');
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');
    const destino = new URL('clave.html', location.href).href;
    const res = await fetch(base + '/auth/v1/recover?redirect_to=' + encodeURIComponent(destino), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
      body: JSON.stringify({ email: correo }),
    });
    if (!res.ok) {
      let data = {};
      try { data = await res.json(); } catch (e) { /* respuesta sin cuerpo */ }
      // El limite de envios de Supabase es bajo y se topa con facilidad.
      if (res.status === 429) {
        throw new Error('Ya se pidieron varios correos seguidos. Espera unos minutos.');
      }
      throw new Error(data.msg || data.error_description || 'No se pudo enviar el correo.');
    }
    return true;
  }

  // ---------- Ver / ocultar la contrasena ----------
  // Envuelve el campo y le pone un boton. Se usa igual en las tres
  // pantallas de ingreso, para que se comporte siempre igual.
  function ojoClave(idInput) {
    const inp = document.getElementById(idInput);
    if (!inp || inp.dataset.conOjo) return;
    inp.dataset.conOjo = '1';

    const caja = document.createElement('span');
    caja.className = 'campo-clave';
    inp.parentNode.insertBefore(caja, inp);
    caja.appendChild(inp);

    const OJO = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z" stroke="currentColor" stroke-width="1.9"/><circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="1.9"/></svg>';
    const TACHADO = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M2.5 12S6 5.5 12 5.5c1.6 0 3 .5 4.2 1.1M21.5 12s-1.2 2.2-3.4 4M9.9 9.9a3 3 0 0 0 4.2 4.2" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/><path d="m4 4 16 16" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>';

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'ojo-clave';
    btn.innerHTML = OJO;
    btn.setAttribute('aria-label', 'Mostrar contrasena');
    btn.setAttribute('aria-pressed', 'false');
    caja.appendChild(btn);

    btn.addEventListener('click', () => {
      const visible = inp.type === 'text';
      inp.type = visible ? 'password' : 'text';
      btn.innerHTML = visible ? OJO : TACHADO;
      btn.setAttribute('aria-label', visible ? 'Mostrar contrasena' : 'Ocultar contrasena');
      btn.setAttribute('aria-pressed', visible ? 'false' : 'true');
      // Al volver del boton, el cursor queda donde estaba.
      inp.focus();
    });
  }

  // ---------- Linea de negocio ----------
  // Se guarda por pestana: cambiar de linea no le cambia la vista a
  // nadie mas, y al cerrar sesion se va con ella.
  function lineaActiva() {
    try { return sessionStorage.getItem('hsq_linea') || ''; } catch (e) { return ''; }
  }

  function fijarLinea(id) {
    try { sessionStorage.setItem('hsq_linea', id || ''); } catch (e) { /* modo privado */ }
  }

  // api_lineas() no vive en el router: se llama directo y exige sesion.
  async function lineasPermitidas() {
    const token = tokenSesion();
    if (!token) return { lineas: [], actual: '', puede_cambiar: false };
    const res = await fetch(CFG.SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/api_lineas', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: CFG.SUPABASE_KEY,
        Authorization: 'Bearer ' + token,
      },
      body: '{}',
    });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!data || data.message) throw new Error((data && data.message) || 'No se pudieron leer las lineas.');
    return data;
  }

  // Pinta el selector en la barra. Con una sola linea muestra el nombre
  // como etiqueta fija: no hay nada que escoger.
  async function montarSelectorLinea(idCaja, alCambiar) {
    const caja = document.getElementById(idCaja);
    if (!caja) return null;
    let info;
    try { info = await lineasPermitidas(); } catch (e) { caja.innerHTML = ''; return null; }
    // Cuenta general (ve todas las lineas) o cuenta de una linea. Hasta que
    // no se corra el script que agrega 'universal', se deduce de si puede
    // cambiar de linea, que hoy es justamente lo que distingue a las dos.
    info.general = (info.universal === undefined) ? !!info.puede_cambiar : !!info.universal;
    const lineas = info.lineas || [];
    if (!lineas.length) { caja.innerHTML = ''; return null; }

    const guardada = lineaActiva();
    const valida = lineas.some((l) => l.id === guardada);
    const actual = valida ? guardada : (info.actual || lineas[0].id);
    fijarLinea(actual);

    const esc = (t) => String(t).replace(/[&<>"']/g, (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    if (!info.puede_cambiar || lineas.length < 2) {
      const n = (lineas.find((l) => l.id === actual) || lineas[0]).nombre;
      // Sin tocar la clase: cada pantalla trae la suya -el dashboard usa
      // otra- y pisarla le quitaba el formato a esa barra.
      caja.innerHTML = '<span class="header-linea__tag">Línea</span>'
        + '<span class="header-linea__fija">' + esc(n) + '</span>';
      return info;
    }

    caja.innerHTML = '<span class="header-linea__tag">Línea</span>'
      + '<select id="' + idCaja + 'Sel" aria-label="Linea de negocio">'
      + lineas.map((l) => '<option value="' + esc(l.id) + '"'
          + (l.id === actual ? ' selected' : '') + '>' + esc(l.nombre) + '</option>').join('')
      + '</select>';
    document.getElementById(idCaja + 'Sel').addEventListener('change', (ev) => {
      fijarLinea(ev.target.value);
      if (typeof alCambiar === 'function') alCambiar(ev.target.value);
    });
    return info;
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
    // Esta no pasa por el router: necesita la linea del desplegable.
    if (action === 'listaEncargados') {
      return rpcDirecto('api_lista_encargados', { payload: { linea: lineaActiva() } });
    }

    let result = await rpc(action, payload);
    if (action === 'cargarFormulario' && payload && payload.id_formulario === 'PREOPERACIONAL') {
      result = inyectarDocsPreoperacional(result);
    }
    return result;
  }

  // Bloque de documentacion que se antepone al preoperacional.
  //
  // Ya no se le pregunta al mensajero si es la primera vez: el servidor
  // lo sabe y manda, en 'documentosEstado', que documento hay que pedirle
  // y por que. Aqui solo se arman las preguntas de los que falten.
  const DOC_PREGUNTA = {
    SOAT:          { id: 'DOC_SOAT',              label: 'SOAT' },
    TECNOMECANICA: { id: 'DOC_TECNOMECANICA',     label: 'Revisi\u00f3n Tecnomec\u00e1nica' },
    LICENCIA:      { id: 'DOC_LICENCIA_TRANSITO', label: 'Licencia de Tr\u00e1nsito (Tarjeta de Propiedad)' },
  };

  // Datos del vehiculo: se piden UNA vez, cuando no hay ningun documento
  // cargado todavia. En una renovacion no tiene sentido volver a pedir la
  // marca o el VIN, que no cambian.
  const DATOS_VEHICULO = [
    { id_pregunta: 'DOC_MARCA_VEHICULO', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Marca del vehículo', tipo_respuesta: 'texto', obligatorio: 'SI' },
    { id_pregunta: 'DOC_CILINDRAJE', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Tipo de cilindraje (CC)', tipo_respuesta: 'numero', obligatorio: 'SI' },
    { id_pregunta: 'DOC_PROP_NOMBRE', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Nombre del propietario del vehículo', tipo_respuesta: 'texto', obligatorio: 'SI' },
    { id_pregunta: 'DOC_PROP_CEDULA', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'Cédula del propietario del vehículo', tipo_respuesta: 'numero', obligatorio: 'SI' },
    { id_pregunta: 'DOC_VIN', orden: 0, seccion: 'Documentación del vehículo', pregunta: 'VIN (Número de Identificación Vehicular)', tipo_respuesta: 'texto', obligatorio: 'SI' },
  ];

  const AYUDA_EXIGE = {
    falta:     'Todavía no lo tenemos. Adjúntalo para poder registrar.',
    vencido:   'Está vencido. Adjunta el documento renovado.',
    rechazado: 'Fue revisado y no sirvió.',
  };

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
    const estado = (data && data.documentosEstado) || {};
    const docs = estado.documentos || {};

    // Las preguntas de fecha de cada documento viven en la hoja: se
    // separan para poder ponerlas junto a su archivo.
    const fechasHoja = {}, resto = [];
    pregs.forEach((q) => {
      const k = docKeyApi(q);
      if (k && !fechasHoja[k]) fechasHoja[k] = q; else resto.push(q);
    });

    const pendientes = Object.keys(DOC_PREGUNTA).filter((k) => docs[k] && docs[k].exige);
    const bloque = [];

    pendientes.forEach((k) => {
      const d = docs[k];
      const meta = DOC_PREGUNTA[k];
      const porque = d.motivo_exige === 'rechazado' && d.motivo
        ? 'Fue revisado y no sirvió: ' + d.motivo
        : (AYUDA_EXIGE[d.motivo_exige] || '');
      bloque.push({
        id_pregunta: meta.id, orden: 0, seccion: 'Documentación del vehículo',
        pregunta: meta.label, tipo_respuesta: 'archivo', obligatorio: 'SI',
        documento: k, ayuda: porque,
      });
      // Su fecha de vencimiento, al lado y editable.
      if (fechasHoja[k]) { bloque.push(fechasHoja[k]); delete fechasHoja[k]; }
    });

    // Primera vez de verdad: ningun documento cargado. Ahi si se piden
    // los datos del vehiculo.
    const primeraVez = Object.keys(DOC_PREGUNTA)
      .every((k) => !(docs[k] && String(docs[k].url || '').trim()));
    if (pendientes.length && primeraVez) DATOS_VEHICULO.forEach((q) => bloque.push(q));

    // Las fechas de los documentos que NO se estan pidiendo se dejan
    // igual que siempre: se pintan bloqueadas con lo que ya hay.
    Object.keys(fechasHoja).forEach((k) => resto.unshift(fechasHoja[k]));

    data.preguntas = bloque.concat(resto);
    // La pantalla necesita saber cuantas preguntas son del bloque 1.
    data.bloqueDocumentos = bloque.length;
    data.documentosPendientes = pendientes;
    return data;
  }

  // Pide los datos a la base y arma el CSV en el navegador (sin Drive).
  // Clave que la pantalla pone en el desplegable de formularios para
  // pedir la documentacion en vez de las respuestas de un formulario.
  const DOCUMENTACION = '__DOCUMENTACION__';

  // Una fila por colaborador activo, con su documentacion. No lleva
  // fechas: es el estado de hoy, no un historico.
  async function exportableDocumentacion(filtros) {
    const p = {
      proyecto: (filtros.proyectos && filtros.proyectos[0]) || filtros.proyecto || '',
      cedula: filtros.cedula || '',
    };
    const r = await rpc('exportarDocumentacion', p);
    // Los enlaces vienen como 'evidencias', asi que se firman con el
    // mismo camino del exportable normal.
    const sinFirmar = await firmarEvidenciasExportable(r.filas || []);

    const cols = [
      ['cedula', 'Cedula'], ['nombre', 'Nombre'], ['cargo', 'Cargo'], ['tipo', 'Tipo'],
      ['proyecto_id', 'Codigo proyecto'], ['proyecto', 'Proyecto'], ['ciudad', 'Ciudad'],
      ['linea', 'Linea'], ['jefatura', 'Jefatura'], ['lider', 'Lider'], ['coordinador', 'Coordinador'],
      ['placa_registrada', 'Placa registrada'], ['tipo_vehiculo', 'Tipo de vehiculo'],
      ['marca_vehiculo', 'Marca del vehiculo'], ['cilindraje', 'Cilindraje'],
      ['propietario_nombre', 'Propietario - nombre'], ['propietario_cedula', 'Propietario - cedula'],
      ['vin', 'VIN'],
      ['soat_vence', 'SOAT vence'], ['soat_adjunto', 'SOAT adjunto'],
      ['tecnomecanica_vence', 'Tecnomecanica vence'], ['tecnomecanica_adjunta', 'Tecnomecanica adjunta'],
      ['licencia_vence', 'Licencia vence'], ['licencia_adjunta', 'Licencia adjunta'],
      ['documentacion_completa', 'Documentacion completa'],
      ['datos_vehiculo_completos', 'Datos del vehiculo completos'],
      ['estado_documental', 'Estado documental'],
      ['documentos_cargados_el', 'Documentos cargados el'],
      ['ultima_actualizacion', 'Ultima actualizacion'],
    ];
    const evIds = ['SOAT', 'TECNOMECANICA', 'LICENCIA'];
    const encabezados = cols.map((c) => c[1]).concat(evIds.map((id) => 'Enlace ' + id));

    const esc = (v) => '"' + String(v === null || v === undefined ? '' : v).replace(/"/g, '""') + '"';
    const lineas = [encabezados.map(esc).join(';')];
    (r.filas || []).forEach((f) => {
      lineas.push(cols.map((c) => f[c[0]])
        .concat(evIds.map((id) => (f.evidencias || {})[id] || ''))
        .map(esc).join(';'));
    });

    const csv = '\ufeffsep=;\r\n' + lineas.join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }));
    const stamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '').slice(0, 15);
    const sufijo = (p.cedula ? '_CC' + p.cedula : '');
    return {
      ok: true, filas: r.total || 0, columnas: encabezados.length,
      evidenciasSinFirmar: sinFirmar || 0,
      nombre: 'Documentacion' + sufijo + '_' + stamp + '.csv',
      url: url, downloadUrl: url, esArchivoLocal: true,
    };
  }

  async function exportableSupabase(filtros) {
    // La documentacion no es un formulario: sale por otro camino.
    const cual = (filtros.formularios && filtros.formularios[0]) || filtros.formulario || '';
    if (cual === DOCUMENTACION) return exportableDocumentacion(filtros);
    const p = {
      formulario: (filtros.formularios && filtros.formularios[0]) || filtros.formulario || '',
      fechaInicio: filtros.fechaInicio,
      fechaFin: filtros.fechaFin,
      proyecto: (filtros.proyectos && filtros.proyectos[0]) || filtros.proyecto || '',
      cedula: filtros.cedula || '',
      perfil: filtros.perfil || '',        // MOTO / VEHICULO / vacío = todos
      jefatura: filtros.jefatura || '',
      lider: filtros.lider || '',
      coordinador: filtros.coordinador || '',
    };
    const r = await rpc('generarExportable', p);
    const sinFirmar = await firmarEvidenciasExportable(r.filas || []);

    // 'tipo' distingue moto de vehículo en el mismo archivo.
    const base = ['fecha', 'hora', 'cedula', 'nombre', 'cargo', 'tipo', 'proyecto_id', 'proyecto',
      'jefatura', 'lider', 'coordinador', 'frente',
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
    const lineas = [encabezados.map(esc).join(';')];
    (r.filas || []).forEach((f) => {
      const fila = base.map((c) => f[c])
        .concat(preg.map((q) => (f.respuestas || {})[q.id] || ''))
        .concat(evIds.map((id) => (f.evidencias || {})[id] || ''));
      lineas.push(fila.map(esc).join(';'));
    });

    // BOM UTF-8 + CRLF para que Excel muestre bien tildes y columnas.
    const csv = '﻿sep=;\r\n' + lineas.join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }));
    const sufijo = (p.perfil ? '_' + p.perfil : '') + (p.cedula ? '_CC' + p.cedula : '');
    const stamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '').slice(0, 15);
    return {
      ok: true, filas: r.total || 0, columnas: encabezados.length,
      evidenciasSinFirmar: sinFirmar || 0,
      nombre: 'Exportable_' + p.formulario + sufijo + '_' + stamp + '.csv',
      url: url, downloadUrl: url, esArchivoLocal: true,
      registros: r.filas || [],
    };
  }

  // Convierte lo guardado en la base (ruta o enlace publico) en la ruta
  // dentro del bucket, que es lo que entiende Storage.
  function rutaEvidencia(valor) {
    let ruta = String(valor || '');
    const marca = '/evidencias/';
    const pos = ruta.indexOf(marca);
    if (pos !== -1) ruta = ruta.slice(pos + marca.length);
    try { ruta = decodeURIComponent(ruta); } catch (e) { /* ya venia sin codificar */ }
    return ruta.replace(/^\/+/, '');
  }

  // Devuelve cuantas evidencias quedaron sin enlace firmado.
  //
  // Storage firma en lote: un pedido por cada 200 archivos. Antes se hacia
  // uno por archivo y todos a la vez, asi que una semana de todos los
  // proyectos disparaba miles de peticiones simultaneas y el servidor
  // respondia con una pagina de error.
  async function firmarEvidenciasExportable(filas) {
    const token = sessionStorage.getItem('hsq_coord_token') || sessionStorage.getItem('hsq_admin_token') || '';
    if (!token) return 0;
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');

    const firmadas = new Map();   // ruta -> enlace firmado
    const entradas = [];
    (filas || []).forEach((fila) => Object.entries(fila.evidencias || {}).forEach(([id, valor]) => {
      const ruta = rutaEvidencia(valor);
      if (!ruta) return;
      entradas.push({ fila, id, ruta });
      if (!firmadas.has(ruta)) firmadas.set(ruta, '');
    }));
    if (!entradas.length) return 0;

    const lista = [...firmadas.keys()];
    const LOTE = 200;      // archivos por pedido
    const A_LA_VEZ = 4;    // pedidos en paralelo

    const trozos = [];
    for (let i = 0; i < lista.length; i += LOTE) trozos.push(lista.slice(i, i + LOTE));

    const firmarTrozo = async (rutas) => {
      let datos = null;
      try {
        const res = await fetch(base + '/storage/v1/object/sign/evidencias', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY, Authorization: 'Bearer ' + token },
          body: JSON.stringify({ expiresIn: 604800, paths: rutas }),
        });
        // Si el servidor responde una pagina de error, esto falla: se deja la
        // evidencia sin firmar en vez de tumbar toda la descarga.
        datos = await res.json();
      } catch (e) { return; }
      if (!Array.isArray(datos)) return;
      datos.forEach((d) => {
        if (d && d.signedURL && d.path) firmadas.set(d.path, base + '/storage/v1' + d.signedURL);
      });
    };

    let siguiente = 0;
    await Promise.all(Array.from({ length: Math.min(A_LA_VEZ, trozos.length) }, async () => {
      while (siguiente < trozos.length) await firmarTrozo(trozos[siguiente++]);
    }));

    let sinFirmar = 0;
    entradas.forEach((it) => {
      const enlace = firmadas.get(it.ruta);
      if (enlace) it.fila.evidencias[it.id] = enlace;
      else sinFirmar++;
    });
    return sinFirmar;
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

  // El token dura una hora. Antes se reutilizaba sin mirar la fecha, así que a
  // quien dejaba el formulario abierto un rato le fallaba la subida con
  // '"exp" claim timestamp check failed'. Se descarta con dos minutos de
  // margen para que no venza justo mientras sube la foto.
  function tokenVencido(jwt) {
    try {
      let carga = String(jwt).split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      while (carga.length % 4) carga += '=';
      const exp = JSON.parse(atob(carga)).exp;
      if (!exp) return true;
      return exp * 1000 <= Date.now() + 120000;
    } catch (e) {
      return true;   // si no se puede leer, es más seguro pedir uno nuevo
    }
  }

  async function tokenStorage(renovar) {
    if (!renovar) {
      if (_stToken && !tokenVencido(_stToken)) return _stToken;
      const cache = sessionStorage.getItem('hsq_st_token');
      if (cache && !tokenVencido(cache)) { _stToken = cache; return _stToken; }
    }
    _stToken = null;
    sessionStorage.removeItem('hsq_st_token');
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');

    const guardar = (d) => {
      if (!d || !d.access_token) return null;
      _stToken = d.access_token;
      sessionStorage.setItem('hsq_st_token', _stToken);
      if (d.refresh_token) sessionStorage.setItem('hsq_st_refresh', d.refresh_token);
      return _stToken;
    };

    // Primero se renueva el usuario anónimo que ya existe. Crear uno nuevo
    // cada hora llenaría Supabase de usuarios temporales sin necesidad.
    const rt = sessionStorage.getItem('hsq_st_refresh');
    if (rt) {
      try {
        const r = await fetch(base + '/auth/v1/token?grant_type=refresh_token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
          body: JSON.stringify({ refresh_token: rt }),
        });
        const d = await r.json();
        const tok = guardar(d);
        if (tok) return tok;
      } catch (e) { /* si no se puede renovar, se crea uno nuevo */ }
      sessionStorage.removeItem('hsq_st_refresh');
    }

    let res;
    try {
      res = await fetch(base + '/auth/v1/signup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
        body: JSON.stringify({}),
      });
    } catch (e) { throw new Error('No se pudo preparar la subida de fotos (conexión).'); }
    const tok = guardar(await res.json());
    if (!tok) {
      throw new Error('Para subir fotos, activa "Anonymous sign-ins" en Supabase (Authentication).');
    }
    return tok;
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
    const extension = blob.type === 'application/pdf' ? '.pdf' : '.jpg';
    if (DOC_ARCHIVO[a.id_pregunta]) {
      path = ['documentos', ced, DOC_ARCHIVO[a.id_pregunta] + '_' + stamp + extension].map(encodeURIComponent).join('/');
    } else {
      const hoy = new Date().toISOString().slice(0, 10);
      path = [ced, hoy, fid + '_' + a.id_pregunta + '_' + stamp + extension].map(encodeURIComponent).join('/');
    }
    // Se intenta con el token que hay; si el servidor lo rechaza por sesión,
    // se pide uno nuevo y se reintenta. El mensajero no tiene que hacer nada.
    let res, msg = '';
    for (let intento = 0; intento < 2; intento++) {
      const st = await tokenStorage(intento > 0);
      try {
        res = await fetch(base + '/storage/v1/object/evidencias/' + path, {
          method: 'POST',
          headers: {
            apikey: CFG.SUPABASE_KEY,
            Authorization: 'Bearer ' + st,
            'Content-Type': blob.type || 'image/jpeg',
          },
          body: blob,
        });
      } catch (e) {
        throw new Error('No se pudo subir la evidencia. Revisa tu conexión.');
      }
      if (res.ok) break;
      msg = '';
      try { msg = (await res.json()).message || ''; } catch (e) { /* noop */ }
      const esSesion = res.status === 401 || res.status === 403 || /exp|jwt|token|expired/i.test(msg);
      if (!esSesion || intento === 1) {
        throw new Error(esSesion
          ? 'La sesión para subir fotos venció. Vuelve a intentarlo; si sigue, recarga la página.'
          : 'No se pudo subir la evidencia' + (msg ? ': ' + msg : '') + '. Verifica el permiso del bucket "evidencias".');
      }
    }
    return {
      id_pregunta: a.id_pregunta,
      nombre: a.nombre || 'evidencia.jpg',
      path: path,
      url: base + '/storage/v1/object/authenticated/evidencias/' + path,
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

  // Inicia sesión (coordinador/HSQ) y guarda el token + refresh_token.
  async function iniciarSesion(email, password, tipo) {
    const base = CFG.SUPABASE_URL.replace(/\/$/, '');
    const res = await fetch(base + '/auth/v1/token?grant_type=password', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: CFG.SUPABASE_KEY },
      body: JSON.stringify({ email: String(email || '').trim(), password: password }),
    });
    const d = await res.json();
    if (!d || !d.access_token) {
      throw new Error(d.error_description || d.msg || d.error || 'Correo o contraseña incorrectos.');
    }
    guardarSesion(d, tipo);
    return d;
  }

  window.HSQ_API = {
    call,
    isDemo: !supaOn && !configured,
    backend: supaOn ? 'supabase' : (configured ? 'appsscript' : 'demo'),
    iniciarSesion,
    guardarSesion,
    cerrarSesion,
    refrescarSesion,
    haySesion: () => !!tokenSesion(),
    // Linea de negocio activa (solo pantallas con sesion).
    montarSelectorLinea,
    lineaActiva,
    fijarLinea,
    ojoClave,
    pedirRestablecer,
    DOCUMENTACION,
  };
})();
