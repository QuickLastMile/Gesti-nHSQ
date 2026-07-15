# Frontend externo sin banner de Google Apps Script

## Por que aparece el banner

El aviso:

```text
Un usuario de Google Apps Script creo esta aplicacion
```

es una capa de seguridad de Google para aplicaciones publicadas con URL `script.google.com/macros/.../exec`.

No se puede quitar con CSS, HTML ni Apps Script. Tampoco depende del diseno del formulario. Google lo inserta por fuera del contenido de la app.

## Como quitarlo de verdad

Para que el formulario se vea como una pagina profesional sin marca de Apps Script, el frontend debe vivir fuera de Apps Script, por ejemplo en:

- GitHub Pages
- Firebase Hosting
- Netlify
- Vercel
- Un dominio propio de Quick

En ese modelo:

```text
Usuario
  -> pagina profesional externa
  -> backend/API
  -> Google Sheets + Drive
```

## Archivos preparados (ya implementado)

El frontend externo ya está construido en la raíz del repo:

```text
index.html          Lanzador de roles
mensajero.html      App de registro (móvil)
coordinador.html    App de exportación
assets/             Estilos + conexión al backend
```

Estas páginas no muestran marca de Apps Script porque se alojan en GitHub Pages.
El backend (`apps-script/Code.gs`) quedó como API JSON. Pasos en `docs/PUBLICAR.md`.

## Opcion recomendada para produccion

Para mantener evidencias, registros y exportables con seguridad, la opcion mas robusta es:

```text
Frontend: Firebase Hosting o GitHub Pages
Backend: Google Cloud Run / Firebase Functions
Datos: Google Sheets + Drive API
```

Apps Script puede seguir funcionando para prototipos o uso interno rapido, pero si la prioridad es imagen profesional, conviene separar el frontend.

## Opcion intermedia

Tambien se puede dejar:

```text
Frontend externo
Backend Apps Script
```

pero Apps Script tiene limitaciones de CORS y autenticacion cuando se consume desde otra pagina. Para registros simples puede funcionar con ajustes adicionales; para adjuntar evidencias y exportar con confianza, es mejor usar Cloud Run o Firebase Functions.

## Estado actual

- Frontend sin banner: `index.html`, `mensajero.html`, `coordinador.html` (GitHub Pages).
- Backend como API: `apps-script/Code.gs` desplegado como Aplicación web con acceso "Cualquier persona".
- La conexión entre ambos se define en `assets/config.js` (`API_URL`).
