# Links por área

> Los links definitivos aparecen cuando actives GitHub Pages (ver `docs/PUBLICAR.md`).
> Formato: `https://quicklastmile.github.io/Gesti-nHSQ/…`

## Mensajeros

App de registro (optimizada para celular):

https://quicklastmile.github.io/Gesti-nHSQ/mensajero.html

Flujo:

- Digitar la cédula y buscar.
- Verificar que aparezca el nombre (debe estar activo en `Matriz_Activos`).
- Seleccionar el tipo de registro.
- Responder las preguntas.
- Adjuntar la foto de evidencia cuando aplique (se abre la cámara).
- Guardar.

## Coordinador / Líder de operación

App de exportación:

https://quicklastmile.github.io/Gesti-nHSQ/coordinador.html

Flujo:

- Filtrar por fecha inicial y final.
- Filtrar por uno o varios proyectos.
- Filtrar por formulario.
- Generar exportable CSV (se guarda en Drive y aparece el enlace).

## HSQ / Área encargada

Base para administrar matriz, formularios, preguntas y opciones:

https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit

Hojas principales:

- `Matriz_Activos`: altas, retiros, proyecto, ciudad, placa y estado.
- `Preguntas`: agregar, quitar, ordenar o cambiar preguntas.
- `Opciones`: valores de desplegables y checkboxes.
- `Formularios`: activar o desactivar formularios.
- `Proyectos`: proyectos disponibles para filtros.

## Tecnología / Administrador del sistema

Repositorio:

https://github.com/QuickLastMile/Gesti-nHSQ

Archivos clave:

- `assets/config.js` — URL del backend (conexión).
- `apps-script/Code.gs` — backend (API + lógica de datos).
- `apps-script/appsscript.json` — manifiesto (acceso "Cualquier persona").
- `mensajero.html`, `coordinador.html`, `index.html` — frontend.
- `docs/PUBLICAR.md` — pasos de despliegue.

## Almacenamiento de respuestas

El sistema crea automáticamente carpetas en Google Drive:

```text
Registros HSQ/
  año/
    año-mes/
      año-mes-día/
        año-mes-día_PREOPERACIONAL
        año-mes-día_LIMPIEZA_MOTO
        Evidencias/
```

Los exportables se guardan en:

```text
Registros HSQ/
  Exportables HSQ/
```
