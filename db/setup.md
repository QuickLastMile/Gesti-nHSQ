# Migración a base de datos — Puesta en marcha

Guía para crear la base en **Supabase (plan gratis)**, empezar a probar y ver costos reales. Es la Fase 2 del plan.

---

## Paso 1 — Crear el proyecto (5 min, gratis)

1. Entra a **https://supabase.com** → *Start your project* → crea cuenta (con Google o correo).
2. **New project**:
   - *Name:* `hseq-motos`
   - *Database password:* genera una y **guárdala** (la necesitas para respaldos).
   - *Region:* elige la más cercana (ej. **East US** o **São Paulo**).
3. Espera ~2 minutos a que se cree.

## Paso 2 — Crear las tablas

1. En el proyecto: menú izquierdo → **SQL Editor** → **New query**.
2. Abre el archivo [`db/schema.sql`](schema.sql), copia **todo** y pégalo.
3. Presiona **Run**. Debe decir *Success*. Ya tienes la base creada.

## Paso 3 — Crear el almacenamiento de fotos

1. Menú izquierdo → **Storage** → **New bucket**.
2. Nombre: `evidencias`. Déjalo **privado** (no público).
3. *Create bucket*.

## Paso 4 — Copiar las llaves de conexión

1. Menú → **Project Settings** (engranaje) → **API**.
2. Copia dos valores y me los pasas (o los pones tú en la config):
   - **Project URL** (algo como `https://xxxx.supabase.co`)
   - **anon public** key (una clave larga)

> La `anon key` está **hecha para ir en el frontend**; es pública por diseño. La seguridad no depende de ocultarla, sino de las reglas (ver abajo).

## Paso 5 — Traer tus datos actuales

Exporta de Google Sheets a CSV e impórtalos (Supabase → **Table Editor** → tabla → **Insert → Import from CSV**):

- Hoja `Matriz_Activos` → tabla `colaboradores`
- Hoja `Preguntas` → tabla `preguntas`
- Hoja `Opciones` → tabla `opciones`

(Te ayudo a cuadrar las columnas cuando lleguemos aquí.)

---

## Seguridad con acceso "sin login"

El mensajero **no** consulta la matriz directamente. Todo pasa por **funciones** de la base (tipo las "acciones" de hoy) que solo devuelven lo justo:

- `buscar_activo(cedula)` → devuelve solo los datos de esa persona, no toda la matriz.
- `guardar_registro(...)` → solo **crea** registros; no puede leer los de otros.
- Las tablas quedan **cerradas** al público (RLS activado); la `anon key` solo puede **ejecutar esas funciones**.
- La vista de coordinador queda tras **PIN** (o login solo para coordinadores, recomendado).

Estas funciones y reglas las creo yo en el siguiente paso (otro `.sql` para pegar y ejecutar).

---

## Costos reales (para eso arrancamos)

| Plan | Base | Almacenamiento | Costo |
|---|---|---|---|
| **Supabase Free** | 500 MB | 1 GB | **US$0** — ideal para pruebas |
| **Supabase Pro** | 8 GB | 100 GB incl. | ~US$25/mes al crecer |
| **Optimización a escala** | Postgres (Neon/VPS) | Cloudflare R2 (sin cobro por descarga) | ~US$8–20/mes |

- Con la **compresión de fotos ya activa**, el consumo baja 4–5×.
- Empezamos en **Free ($0)**: probamos el flujo real y **medimos** cuánto crecen datos y fotos por día. Con ese dato real decidimos el plan definitivo sin adivinar.

---

## Qué sigue después de estos pasos

1. **(este archivo)** Crear base + storage + traer datos. ← empezamos aquí
2. Funciones de la base (buscar_activo, guardar_registro, cumplimiento, exportable…).
3. Conectar el frontend actual a Supabase (nueva capa de datos; la interfaz no cambia).
4. Pruebas en paralelo con datos reales → medir costos.
5. Corte y dominio propio.

> Cuando termines los pasos 1–4 de arriba y me pases la **Project URL** + **anon key**, sigo con las funciones y la conexión del frontend.
