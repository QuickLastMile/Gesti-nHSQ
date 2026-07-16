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

  async function call(action, payload = {}) {
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
    return Promise.reject(new Error('Acción demo no soportada: ' + action));
  }

  window.HSQ_API = { call, isDemo: !configured };
})();
