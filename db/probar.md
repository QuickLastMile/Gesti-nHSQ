# Probar la conexión a la base de datos (Milestone 1: leer)

Objetivo: confirmar que la página **lee datos reales desde Postgres**, sin afectar la app en producción (los mensajeros siguen con la versión actual).

## Antes de probar

1. **Crear las tablas** — ya hecho si corriste [`schema.sql`](schema.sql).
2. **Crear las funciones y la seguridad** — en Supabase → SQL Editor → pega [`functions.sql`](functions.sql) → **Run**.
3. **Importar datos** (para tener qué leer): Table Editor → importar CSV desde tus hojas:
   - `Matriz_Activos` → **colaboradores**
   - `Preguntas` → **preguntas**
   - `Opciones` → **opciones**
   > Ojo: en `colaboradores` la columna de activo es `activo` (verdadero/falso). Si tu hoja trae `SI/NO`, avísame y te paso cómo convertirlo al importar.

## Cómo probar

Abre la página del mensajero **agregando `?db=1`** al final del link:

```
https://quicklastmile.github.io/Gesti-nHSQ/mensajero.html?db=1
```

- Arriba debe aparecer la franja **"Modo base de datos (prueba) · conectado a Supabase"**.
- Digita una cédula que hayas importado y que esté **activa** → debe traer el nombre, proyecto, etc. **desde Postgres**.
- Elige un formulario → deben cargar las preguntas desde la base.

> El link **sin** `?db=1` sigue funcionando con Apps Script como hasta ahora. Nada se rompe en producción.

## Qué falta (siguiente milestone)

En esta etapa solo se puede **leer y consultar**. **Guardar** registros, placas y las vistas de cumplimiento se conectan en el siguiente paso (incluye subir las fotos al almacenamiento de Supabase). Lo hago cuando confirmes que la lectura funciona.

## Si algo falla

- **"Base de datos: permission denied for function hseq_api"** → falta el `grant execute` (está al final de `functions.sql`; vuelve a correrlo).
- **No trae la persona** → la cédula no se importó o quedó como inactiva. Revisa la tabla `colaboradores`.
- **No cargan preguntas** → no se importó la hoja `Preguntas`, o el `formulario_id` no coincide con `PREOPERACIONAL`/`LIMPIEZA_MOTO`.
- Cualquier error, mándame el texto exacto y lo resolvemos.
