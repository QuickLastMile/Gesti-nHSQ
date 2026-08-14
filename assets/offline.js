/* ============================================================
   Gestión HSEQ Motos — Registrar sin señal
   ------------------------------------------------------------
   Si al guardar no hay conexión, el registro queda en el celular
   y se envía solo cuando vuelve la señal. Guarda la hora en que
   se diligenció para que la trazabilidad no dependa de cuándo
   alcanzó a subirse.

   Se carga en mensajero.html, después de api.js.
   ============================================================ */
(function () {
  'use strict';

  var BD = 'hseq-offline', TIENDA = 'pendientes', VERSION = 1;
  var _db = null;

  function abrir() {
    if (_db) return Promise.resolve(_db);
    return new Promise(function (ok, no) {
      if (!window.indexedDB) return no(new Error('sin almacenamiento'));
      var req = indexedDB.open(BD, VERSION);
      req.onupgradeneeded = function () {
        var db = req.result;
        if (!db.objectStoreNames.contains(TIENDA)) {
          db.createObjectStore(TIENDA, { keyPath: 'id', autoIncrement: true });
        }
      };
      req.onsuccess = function () { _db = req.result; ok(_db); };
      req.onerror = function () { no(req.error || new Error('no se pudo abrir')); };
    });
  }

  function tx(modo) {
    return abrir().then(function (db) {
      return db.transaction(TIENDA, modo).objectStore(TIENDA);
    });
  }

  function guardar(item) {
    return tx('readwrite').then(function (t) {
      return new Promise(function (ok, no) {
        var r = t.add(item);
        r.onsuccess = function () { ok(r.result); };
        r.onerror = function () { no(r.error); };
      });
    });
  }

  function listar() {
    return tx('readonly').then(function (t) {
      return new Promise(function (ok, no) {
        var r = t.getAll();
        r.onsuccess = function () { ok(r.result || []); };
        r.onerror = function () { no(r.error); };
      });
    }).catch(function () { return []; });
  }

  function borrar(id) {
    return tx('readwrite').then(function (t) {
      return new Promise(function (ok) {
        var r = t.delete(id);
        r.onsuccess = function () { ok(); };
        r.onerror = function () { ok(); };
      });
    });
  }

  function actualizar(item) {
    return tx('readwrite').then(function (t) {
      return new Promise(function (ok) {
        var r = t.put(item);
        r.onsuccess = function () { ok(); };
        r.onerror = function () { ok(); };
      });
    });
  }

  /* ---------- hora local en formato que entiende el servidor ---------- */
  function ahoraISO() {
    var d = new Date();
    var off = -d.getTimezoneOffset();
    var s = off >= 0 ? '+' : '-';
    var p = function (n) { return String(Math.floor(Math.abs(n))).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' +
      p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) +
      s + p(off / 60) + ':' + p(off % 60);
  }

  /* ---------- aviso en pantalla ---------- */
  var css = ''
    + '#off-aviso{position:fixed;left:0;right:0;bottom:0;z-index:9998;padding:10px 14px;'
    + 'font:600 13px/1.35 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#fff;'
    + 'display:none;align-items:center;gap:9px;box-shadow:0 -4px 14px rgba(0,0,0,.14)}'
    + '#off-aviso.ver{display:flex}'
    + '#off-aviso.sin{background:#8a6412}'
    + '#off-aviso.cola{background:#0d5c41}'
    + '#off-aviso.enviando{background:#12875f}'
    + '#off-aviso b{font-weight:800}'
    + '#off-aviso .cnt{margin-left:auto;background:rgba(255,255,255,.22);border-radius:999px;padding:2px 9px}'
    + '@media print{#off-aviso{display:none !important}}';

  function pintarAviso(clase, texto, cuenta) {
    var a = document.getElementById('off-aviso');
    if (!a) {
      var st = document.createElement('style'); st.textContent = css;
      document.head.appendChild(st);
      a = document.createElement('div');
      a.id = 'off-aviso';
      document.body.appendChild(a);
    }
    if (!clase) { a.className = ''; return; }
    a.className = 'ver ' + clase;
    a.innerHTML = texto + (cuenta ? '<span class="cnt">' + cuenta + '</span>' : '');
  }

  function refrescarAviso() {
    return listar().then(function (p) {
      if (!navigator.onLine) {
        pintarAviso('sin', p.length
          ? 'Sin señal. Tienes registros guardados en el celular; se enviarán solos.'
          : 'Sin señal. Puedes seguir diligenciando: se guardará en el celular.', p.length || '');
      } else if (p.length) {
        pintarAviso('cola', 'Enviando lo que quedó guardado…', p.length);
      } else {
        pintarAviso(null);
      }
      return p.length;
    });
  }

  /* ---------- envío de lo pendiente ---------- */
  var enviando = false;

  function sincronizar() {
    if (enviando || !navigator.onLine) return Promise.resolve(0);
    enviando = true;
    var enviados = 0;
    return listar().then(function (pend) {
      if (!pend.length) { enviando = false; pintarAviso(null); return 0; }
      pintarAviso('enviando', 'Enviando registros guardados…', pend.length);
      var cadena = Promise.resolve();
      pend.forEach(function (item) {
        cadena = cadena.then(function () {
          return HSQ_API.call('guardarRegistro', item.payload).then(function () {
            enviados++;
            return borrar(item.id);
          }).catch(function (err) {
            var msg = String((err && err.message) || '');
            // Sin red: se deja para el próximo intento.
            if (/conexi|network|failed to fetch|load failed/i.test(msg)) throw new Error('sin_red');
            // El servidor lo rechazó (ya registró, pasaron 72 horas…): no se reintenta.
            item.error = msg;
            item.intentos = (item.intentos || 0) + 1;
            return actualizar(item).then(function () {
              avisarRechazo(item, msg);
              return borrar(item.id);
            });
          });
        });
      });
      return cadena.then(function () { return enviados; })
        .catch(function () { return enviados; });
    }).then(function (n) {
      enviando = false;
      return refrescarAviso().then(function (quedan) {
        if (n > 0 && !quedan) {
          pintarAviso('cola', '✓ Se enviaron <b>' + n + '</b> registro' + (n === 1 ? '' : 's') + ' que estaban guardados.', '');
          setTimeout(function () { refrescarAviso(); }, 6000);
        }
        return n;
      });
    }).catch(function () { enviando = false; return 0; });
  }

  function avisarRechazo(item, msg) {
    if (window.EVA && EVA.preguntar) {
      // EVA lo explica en el chat, que es donde el mensajero pregunta.
      try {
        window.dispatchEvent(new CustomEvent('hseq:rechazo', { detail: { msg: msg } }));
      } catch (e) { /* nada */ }
    }
    alert('Un registro que habías guardado sin señal no se pudo enviar:\n\n' + msg);
  }

  /* ---------- API pública ---------- */
  window.HSQ_OFFLINE = {
    // Guarda el registro para enviarlo después. Devuelve el comprobante local.
    encolar: function (payload, persona) {
      var copia = JSON.parse(JSON.stringify(payload));
      copia.capturado_en = ahoraISO();
      return guardar({ payload: copia, creado: Date.now(), intentos: 0 }).then(function () {
        refrescarAviso();
        return copia.capturado_en;
      });
    },
    pendientes: function () { return listar().then(function (p) { return p.length; }); },
    sincronizar: sincronizar,
    refrescar: refrescarAviso,
    ahoraISO: ahoraISO
  };

  window.addEventListener('online', function () { setTimeout(sincronizar, 800); });
  window.addEventListener('offline', refrescarAviso);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) sincronizar();
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { refrescarAviso(); sincronizar(); });
  } else {
    refrescarAviso(); sincronizar();
  }
})();
