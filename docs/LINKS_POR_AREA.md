# Links por area

## Mensajeros

Usan este link para registrar:

https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec

Modulo a usar:

- Pestana `Registrar`.
- Digitar cedula.
- Seleccionar formulario.
- Responder preguntas.
- Adjuntar evidencia cuando aplique.
- Guardar registro.

## Coordinador / Lider de operacion

Usan este mismo link para consultar y generar exportables:

https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec

Modulo a usar:

- Pestana `Exportar`.
- Filtrar por fecha inicial y fecha final.
- Filtrar por uno o varios proyectos.
- Filtrar por formulario.
- Generar exportable CSV.

## HSQ / Area encargada

Usan esta base para administrar matriz, formularios, preguntas y opciones:

https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit

Hojas principales:

- `Matriz_Activos`: altas, retiros, proyecto, ciudad, placa y estado.
- `Preguntas`: agregar, quitar, ordenar o cambiar preguntas.
- `Opciones`: valores de desplegables y checkboxes.
- `Formularios`: activar o desactivar formularios.
- `Proyectos`: proyectos disponibles para filtros.

## Tecnologia / Administrador del sistema

Repositorio:

https://github.com/QuickLastMile/Gesti-nHSQ

Archivos clave:

- `apps-script/Code.gs`
- `apps-script/Index.html`
- `apps-script/appsscript.json`
- `base/Base_HSQ_Admin.xlsx`
- `scripts/build_admin_sheet.mjs`

## Almacenamiento de respuestas

El sistema crea automaticamente carpetas en Google Drive cuando se reciben registros:

```text
Registros HSQ/
  ano/
    ano-mes/
      ano-mes-dia/
        ano-mes-dia_PREOPERACIONAL
        ano-mes-dia_LIMPIEZA_MOTO
        Evidencias/
```

Los exportables se guardan en:

```text
Registros HSQ/
  Exportables HSQ/
```
