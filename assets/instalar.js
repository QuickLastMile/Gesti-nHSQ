/* ============================================================
   Gestión HSEQ Motos — Instalar la app en el celular
   ------------------------------------------------------------
   Muestra un botón para instalar cuando el navegador lo permite.
   En iPhone no existe ese aviso automático, así que se explica
   el paso a paso. Si ya está instalada, no molesta.
   ============================================================ */
(function () {
  'use strict';

  var instalable = null;

  function yaInstalada() {
    return window.matchMedia('(display-mode: standalone)').matches ||
      window.navigator.standalone === true;
  }

  function esIOS() {
    return /iphone|ipad|ipod/i.test(navigator.userAgent) && !window.MSStream;
  }

  var css = ''
    + '#inst-app{position:fixed;left:12px;right:12px;bottom:12px;z-index:9997;'
    + 'background:#0d5c41;color:#fff;border-radius:14px;padding:12px 14px;display:none;'
    + 'align-items:center;gap:12px;box-shadow:0 10px 26px rgba(7,56,43,.3);'
    + 'font:500 13.5px/1.35 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}'
    + '#inst-app.ver{display:flex}'
    + '#inst-app img{width:42px;height:42px;flex:0 0 auto;border-radius:10px}'
    + '#inst-app b{display:block;font-size:14.5px;margin-bottom:2px}'
    + '#inst-app .txt{flex:1;min-width:0}'
    + '#inst-app button{border:0;border-radius:9px;padding:9px 14px;font:700 13px inherit;cursor:pointer;flex:0 0 auto}'
    + '#inst-si{background:#ffc21f;color:#07382b}'
    + '#inst-no{background:transparent;color:#a9c4ba;padding:9px 6px}'
    + '@media(max-width:420px){#inst-app{flex-wrap:wrap}#inst-app .txt{flex:1 1 100%;order:-1}}'
    + '@media print{#inst-app{display:none !important}}';

  function tarjeta(titulo, detalle, alInstalar) {
    var st = document.createElement('style'); st.textContent = css;
    document.head.appendChild(st);
    var d = document.createElement('div');
    d.id = 'inst-app';
    d.innerHTML = '<img src="assets/icono-192.png" alt="">' +
      '<span class="txt"><b>' + titulo + '</b>' + detalle + '</span>' +
      '<button id="inst-no" type="button">Ahora no</button>' +
      '<button id="inst-si" type="button">Instalar</button>';
    document.body.appendChild(d);
    d.classList.add('ver');
    document.getElementById('inst-no').addEventListener('click', function () {
      d.remove();
      localStorage.setItem('inst-no', String(Date.now()));
    });
    document.getElementById('inst-si').addEventListener('click', function () {
      alInstalar(d);
    });
  }

  function pospuesta() {
    var t = Number(localStorage.getItem('inst-no') || 0);
    return t && (Date.now() - t) < 7 * 24 * 3600 * 1000;   // no insistir en una semana
  }

  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    instalable = e;
    if (yaInstalada() || pospuesta()) return;
    setTimeout(function () {
      if (document.getElementById('inst-app')) return;
      tarjeta('Instala la app en tu celular',
        'Queda con su ícono y abre más rápido, sin buscar el enlace.',
        function (d) {
          d.remove();
          instalable.prompt();
          instalable = null;
        });
    }, 4000);
  });

  window.addEventListener('appinstalled', function () {
    localStorage.removeItem('inst-no');
    var d = document.getElementById('inst-app');
    if (d) d.remove();
  });

  // Si el navegador no ofrece el aviso automático (iPhone siempre, y a veces
  // Android), se remite a la guía con el paso a paso de cada navegador.
  window.addEventListener('load', function () {
    setTimeout(function () {
      if (instalable || yaInstalada() || pospuesta()) return;
      if (document.getElementById('inst-app')) return;
      tarjeta('Instala la app en tu celular',
        'Queda con su ícono y abre más rápido. Te muestro cómo.',
        function () { location.href = 'instalar.html'; });
    }, 5000);
  });

  // Para poder ofrecerla también desde el asistente
  window.HSQ_INSTALAR = {
    disponible: function () { return !!instalable || esIOS(); },
    pedir: function () {
      if (instalable) { instalable.prompt(); instalable = null; return true; }
      return false;
    }
  };
})();
