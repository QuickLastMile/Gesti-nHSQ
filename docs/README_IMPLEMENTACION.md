# Automatizacion HSQ Motos

## Entregables

- Google Sheets administrador: https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit
- Frontend (GitHub Pages): `index.html`, `mensajero.html`, `coordinador.html`
- Backend (API Apps Script): `apps-script/Code.gs` — se despliega como Aplicación web (`/exec`)
- Conexión frontend ↔ backend: `assets/config.js`

## Links por area

- Mensajeros: https://quicklastmile.github.io/Gesti-nHSQ/mensajero.html
- Coordinador / Lider: https://quicklastmile.github.io/Gesti-nHSQ/coordinador.html
- HSQ / Area encargada: https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit
- Tecnologia / Desarrollo: https://github.com/QuickLastMile/Gesti-nHSQ

## Estructura de la base

- `Matriz_Activos`: colaboradores y datos base importados desde la matriz de activos.
- `Proyectos`: proyectos detectados en la matriz para filtros.
- `Formularios`: formularios activos.
- `Preguntas`: preguntas dinamicas por formulario.
- `Opciones`: listas para desplegables y casillas.
- `Tipos_Campo`: tipos permitidos para preguntas.
- `Exportador_Config`: filtros del exportador.

## Tipos de campo soportados

- `texto`
- `parrafo`
- `numero`
- `fecha`
- `hora`
- `desplegable`
- `si_no`
- `checkbox`
- `archivo`

## Estructura de almacenamiento en Drive

El script crea automaticamente:

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

Cada archivo diario guarda filas por registro y columnas por pregunta activa.

## Arquitectura actual

El frontend vive en **GitHub Pages** (`index.html`, `mensajero.html`, `coordinador.html`) y el
Apps Script quedó como **API JSON** (ya no sirve pantalla propia, por eso desaparece el aviso de Google).

## Instalacion (resumen)

1. Backend: pegue `apps-script/Code.gs` y `apps-script/appsscript.json` en su proyecto de Apps Script.
2. Ejecute `verificarConfiguracion` una vez y autorice permisos.
3. Despliegue como `Aplicacion web` con acceso **Cualquier persona**. Copie la URL `/exec`.
4. Pegue esa URL en `assets/config.js` (`API_URL`).
5. Suba a GitHub y active GitHub Pages (rama `main`, raíz).

Paso a paso completo: `docs/PUBLICAR.md`.

## Aviso de Google Apps Script

Ya no aplica: el banner `Un usuario de Google Apps Script creó esta aplicación` solo aparecía
cuando la pantalla vivía en `script.google.com`. Con el frontend en GitHub Pages, no se muestra.

## Nota sobre formularios actuales

Los enlaces actuales de Google Forms solicitaron acceso/cookies durante la revision, por eso la hoja `Preguntas` trae una precarga editable basada en el flujo esperado. HSQ puede reemplazar o ajustar esas preguntas directamente en la hoja.
