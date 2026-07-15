# Gestion HSQ Motos

Sistema para reemplazar formularios rigidos de Google Forms por un formulario web dinamico administrado desde Google Sheets.

## Que incluye

- Formulario web para mensajeros en `apps-script/Index.html`.
- Backend de Google Apps Script en `apps-script/Code.gs`.
- Manifiesto de Apps Script en `apps-script/appsscript.json`.
- Base administrable inicial en `base/Base_HSQ_Admin.xlsx`.
- Guia de implementacion en `docs/README_IMPLEMENTACION.md`.
- Script auxiliar para regenerar la base en `scripts/build_admin_sheet.mjs`.

## Base administrable

La base inicial ya fue importada como Google Sheets:

https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit

## Link del formulario web

Aplicacion web de Apps Script:

https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec

Uso por area:

- Mensajeros: pestana `Registrar`.
- Coordinador / Lider: pestana `Exportar`.
- HSQ: edicion de matriz, preguntas y opciones en la base administrable.

Detalle de enlaces por rol: `docs/LINKS_POR_AREA.md`.

Hojas principales:

- `Matriz_Activos`: colaboradores, proyectos y estado activo/inactivo.
- `Formularios`: formularios disponibles.
- `Preguntas`: preguntas dinamicas por formulario.
- `Opciones`: opciones para desplegables y checkboxes.
- `Proyectos`: proyectos disponibles para filtros.
- `Exportador_Config`: estructura del modulo exportador.

## Almacenamiento

El Apps Script crea automaticamente la estructura:

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

Cada dia queda separado por carpeta y formulario, pensado para un volumen aproximado de 1000 registros diarios.

## Instalacion rapida

1. Abra el Google Sheets administrador.
2. Vaya a `Extensiones > Apps Script`.
3. Copie `apps-script/Code.gs` en el archivo `Code.gs`.
4. Cree un archivo HTML llamado `Index` y copie `apps-script/Index.html`.
5. Copie el contenido de `apps-script/appsscript.json` en la configuracion del manifiesto.
6. Ejecute `verificarConfiguracion` una vez para autorizar permisos.
7. Despliegue como `Aplicacion web`.

Mas detalle en `docs/README_IMPLEMENTACION.md`.

## Nota

Los enlaces actuales de Google Forms solicitaron acceso/cookies durante la revision, por eso la hoja `Preguntas` trae una precarga editable. HSQ puede reemplazar esas preguntas directamente en la base administrable sin cambiar codigo.
