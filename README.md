# Gestión HSQ Motos

Plataforma web para registrar el preoperacional y la limpieza de las motos, y exportar los registros. Reemplaza los formularios rígidos de Google Forms por un frontend profesional propio, administrado desde Google Sheets.

## Arquitectura

```text
Mensajero / Coordinador (celular o PC)
        │
        ▼
Frontend en GitHub Pages   ← HTML + CSS + JS, sin banner de Google
        │  (fetch JSON)
        ▼
Backend en Google Apps Script  ← misma cuenta, mismos datos
        │
        ▼
Google Sheets (base administrable) + Google Drive (registros y evidencias)
```

El frontend es estático y bonito; toda la lógica de datos sigue en Apps Script, que ahora funciona como **API** (ya no muestra pantalla propia, por eso desaparece el aviso *"Un usuario de Google Apps Script creó esta aplicación"*).

## Páginas (GitHub Pages)

- **Inicio / lanzador:** `index.html` — elige rol.
- **Mensajero (móvil):** `mensajero.html` — digita cédula, elige formulario, responde y guarda. Optimizado para celular, la cámara se abre directo para las evidencias.
- **Coordinador:** `coordinador.html` — filtra por fecha, proyecto y formulario, y genera el exportable CSV.

Diseño y conexión compartidos en `assets/` (`styles.css`, `config.js`, `api.js`).

URL pública (cuando actives Pages):

- Inicio: `https://quicklastmile.github.io/Gesti-nHSQ/`
- Mensajero: `https://quicklastmile.github.io/Gesti-nHSQ/mensajero.html`
- Coordinador: `https://quicklastmile.github.io/Gesti-nHSQ/coordinador.html`

## Puesta en marcha (resumen)

1. **Backend:** pega `apps-script/Code.gs` y `apps-script/appsscript.json` en tu proyecto de Apps Script y despliega como **Aplicación web** con acceso **Cualquier persona**. Copia la URL `/exec`.
2. **Conectar:** pega esa URL en `assets/config.js` (línea `API_URL`).
3. **Publicar:** sube los cambios a GitHub y activa **GitHub Pages** (rama `main`, carpeta raíz).

Paso a paso detallado en [`docs/PUBLICAR.md`](docs/PUBLICAR.md).

Mientras `config.js` conserve el texto `PEGUE_AQUI`, las páginas funcionan en **modo demostración** (datos de ejemplo, no guardan nada). Útil para revisar el diseño.

## Base administrable (HSQ)

HSQ administra matriz, formularios, preguntas y opciones sin tocar código:

https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit

Hojas principales:

- `Matriz_Activos`: colaboradores, proyectos y estado activo/inactivo.
- `Formularios`: formularios disponibles.
- `Preguntas`: preguntas dinámicas por formulario.
- `Opciones`: opciones para desplegables y checkboxes.
- `Proyectos`: proyectos disponibles para filtros.

## Almacenamiento en Drive

El backend crea automáticamente:

```text
Registros HSQ/
  2026/
    2026-07/
      2026-07-15/
        2026-07-15_PREOPERACIONAL
        2026-07-15_LIMPIEZA_MOTO
        Evidencias/
  Exportables HSQ/
```

Cada día queda separado por carpeta y formulario, pensado para ~1000 registros diarios.

## Estructura del repositorio

```text
index.html            Lanzador de roles
mensajero.html        App de registro (móvil)
coordinador.html      App de exportación
assets/
  styles.css          Sistema de diseño compartido
  config.js           ⚙️ URL del backend (edítalo aquí)
  api.js              Cliente que habla con Apps Script
apps-script/
  Code.gs             Backend (API JSON + lógica de datos)
  appsscript.json     Manifiesto (acceso "Cualquier persona")
base/                 Base administrable inicial (.xlsx)
docs/                 Guías de implementación y enlaces por área
```
