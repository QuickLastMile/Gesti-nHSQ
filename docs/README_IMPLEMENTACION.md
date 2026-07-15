# Automatizacion HSQ Motos

## Entregables

- Google Sheets administrador: https://docs.google.com/spreadsheets/d/1WokV7ZlyxblP8ugbkM-tXoADf7d9wN7JSykSNImFdz8/edit
- Aplicacion web Apps Script: https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec
- Frontend externo preparado: `public/index.html`
- Base local de respaldo: `C:\Users\Quick\Downloads\HSQ_Automatizacion\outputs\Base_HSQ_Admin.xlsx`
- Script backend Apps Script: `C:\Users\Quick\Downloads\HSQ_Automatizacion\Code.gs`
- Formulario web Apps Script: `C:\Users\Quick\Downloads\HSQ_Automatizacion\Index.html`

## Links por area

- Mensajeros: https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec
- Coordinador / Lider: https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec
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

## Instalacion en Apps Script

1. Abra el Google Sheets administrador.
2. Vaya a `Extensiones > Apps Script`.
3. Pegue el contenido de `Code.gs` en el archivo `Code.gs`.
4. Cree un archivo HTML llamado exactamente `Index`.
5. Pegue el contenido de `Index.html`.
6. Guarde el proyecto.
7. Ejecute `verificarConfiguracion` una vez y autorice permisos.
8. Despliegue como `Implementar > Nueva implementacion > Aplicacion web`.
9. En acceso, use la politica que defina HSQ: dominio interno o usuarios autorizados.

## Solucion de error: no se encontro el archivo HTML llamado Index

Si al abrir el link aparece:

```text
Exception: No se encontro el archivo HTML llamado Index.
```

significa que el proyecto de Apps Script tiene `Code.gs`, pero no tiene el archivo HTML que el backend intenta cargar.

Para corregirlo:

1. Abra el proyecto en Apps Script.
2. En el panel izquierdo, presione `+`.
3. Seleccione `HTML`.
4. Escriba el nombre `Index`.
5. Pegue todo el contenido de `apps-script/Index.html`.
6. Guarde.
7. Vaya a `Implementar > Administrar implementaciones`.
8. Edite la implementacion web.
9. En `Version`, seleccione `Nueva version`.
10. Presione `Implementar`.

Despues abra nuevamente el link `/exec`.

## Aviso de Google Apps Script

El banner superior `Un usuario de Google Apps Script creo esta aplicacion` no se puede ocultar desde el codigo. Es impuesto por Google en las aplicaciones publicadas con `script.google.com`.

Para quitarlo, use un frontend externo. La primera version esta en:

```text
public/index.html
```

Ver: `docs/FRONTEND_EXTERNO.md`.

## Nota sobre formularios actuales

Los enlaces actuales de Google Forms solicitaron acceso/cookies durante la revision, por eso la hoja `Preguntas` trae una precarga editable basada en el flujo esperado. HSQ puede reemplazar o ajustar esas preguntas directamente en la hoja.
