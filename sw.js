/* ============================================================
   Gestión HSEQ Motos — Service Worker
   ------------------------------------------------------------
   Guarda la aplicación en el celular para que abra sin señal.
   Solo cachea los archivos propios: las llamadas a la base de
   datos NUNCA se cachean, para no mostrar información vieja.
   ============================================================ */
var VERSION = 'hseq-v1';
var ARCHIVOS = [
  'mensajero.html',
  'index.html',
  'assets/styles.css',
  'assets/config.js',
  'assets/api.js',
  'assets/offline.js',
  'assets/asistente.js',
  'assets/logo-quick.png',
  'assets/eva-aros.png',
  'assets/eva-cuerpo.png',
  'assets/eva-ojos.png',
  'assets/bot-quick.png',
  'manifest.json'
];

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(VERSION).then(function (c) {
      // Si algún archivo falla, la instalación no se cae por eso.
      return Promise.all(ARCHIVOS.map(function (a) {
        return c.add(new Request(a, { cache: 'reload' })).catch(function () {});
      }));
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (ks) {
      return Promise.all(ks.map(function (k) {
        return k === VERSION ? null : caches.delete(k);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET') return;

  var url;
  try { url = new URL(req.url); } catch (err) { return; }

  // Todo lo que va a la base de datos o al almacenamiento pasa derecho.
  if (url.origin !== self.location.origin) return;
  if (/\/(rest|auth|storage)\/v1\//.test(url.pathname)) return;

  // Los archivos de la app: primero la red, y si no hay, lo guardado.
  e.respondWith(
    fetch(req).then(function (res) {
      if (res && res.ok) {
        var copia = res.clone();
        caches.open(VERSION).then(function (c) { c.put(req, copia); });
      }
      return res;
    }).catch(function () {
      return caches.match(req).then(function (r) {
        if (r) return r;
        // Si pide una página que no está guardada, se abre la de registro.
        if (req.mode === 'navigate') return caches.match('mensajero.html');
        return new Response('', { status: 504, statusText: 'sin conexion' });
      });
    })
  );
});
