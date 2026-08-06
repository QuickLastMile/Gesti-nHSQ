-- ============================================================
--  Gestión HSEQ Motos — Esquema de base de datos (PostgreSQL)
--  Migración desde Google Sheets/Drive.
--  Probado para Supabase (Postgres 15). Ejecutar todo de una vez
--  en: Supabase → SQL Editor → New query → pegar → Run.
-- ============================================================

create extension if not exists pgcrypto;   -- para gen_random_uuid()

-- ------------------------------------------------------------
-- 1) COLABORADORES  (reemplaza la hoja Matriz_Activos)
-- ------------------------------------------------------------
create table if not exists colaboradores (
  cedula                 text primary key,
  estado_nomina          text,
  tipo_documento         text,
  nombre                 text not null default '',
  cargo                  text,
  proyecto_id            text,
  proyecto               text,
  ciudad                 text,
  telefono               text,
  celular                text,
  email                  text,
  fecha_ingreso          date,
  fecha_retiro           date,
  activo                 boolean not null default true,   -- activo_para_registro
  placa_moto             text,
  tipo_vehiculo          text default 'MOTO',
  marca_vehiculo         text,
  cilindraje             text,
  -- Vencimientos y enlaces de documentos del vehículo
  soat_vence             date,
  tecnomecanica_vence    date,
  licencia_vence         date,
  soat_url               text,
  tecnomecanica_url      text,
  licencia_url           text,
  -- Observaciones
  observaciones_hsq      text,           -- notas del sistema (placas, inactivaciones)
  observacion_coordinador text,          -- por qué está inactivo (restricción, incapacidad)
  actualizado_en         timestamptz not null default now()
);
create index if not exists idx_colab_proyecto on colaboradores (proyecto_id) where activo;

-- ------------------------------------------------------------
-- 2) FORMULARIOS / PREGUNTAS / OPCIONES  (config administrable)
-- ------------------------------------------------------------
create table if not exists formularios (
  id           text primary key,          -- PREOPERACIONAL, LIMPIEZA_MOTO
  nombre       text not null,
  descripcion  text,
  activo       boolean not null default true,
  orden        int default 0
);

-- Asignación explícita de formularios por proyecto. La ausencia de una fila
-- activa significa que ese formulario NO es exigible para el proyecto.
-- Esto evita que formularios nuevos alteren automáticamente el cumplimiento.
create table if not exists proyectos_formularios (
  proyecto       text not null,
  formulario_id  text not null references formularios(id) on delete cascade,
  activo         boolean not null default true,
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid,
  primary key (proyecto, formulario_id)
);
create index if not exists idx_proy_form_activos
  on proyectos_formularios (proyecto, formulario_id) where activo;

create table if not exists preguntas (
  id                  text primary key,    -- PRE_001, LIM_008, ...
  formulario_id       text not null references formularios(id) on delete cascade,
  seccion             text,
  pregunta            text not null,
  tipo_respuesta      text not null,       -- texto, parrafo, numero, fecha, hora, desplegable, si_no, checkbox, archivo
  obligatorio         boolean not null default false,
  orden               numeric default 0,
  grupo_opciones      text,
  ayuda               text,
  imagen_url          text,                -- foto de referencia
  documento           text,               -- SOAT / TECNOMECANICA / LICENCIA (para fechas de vencimiento)
  depende_de          text,               -- pregunta condicional
  depende_valor       text,
  respuesta_alerta    text,
  evidencia_requerida_si text,
  activo              boolean not null default true
);
create index if not exists idx_preg_form on preguntas (formulario_id) where activo;

create table if not exists opciones (
  id        bigserial primary key,
  grupo     text not null,                 -- grupo_opciones
  valor     text not null,
  orden     int default 0,
  activo    boolean not null default true
);
create index if not exists idx_opc_grupo on opciones (grupo) where activo;

-- ------------------------------------------------------------
-- 3) REGISTROS  (cada diligenciamiento del formulario)
-- ------------------------------------------------------------
create table if not exists registros (
  id            uuid primary key default gen_random_uuid(),
  cedula        text not null references colaboradores(cedula),
  formulario_id text not null references formularios(id),
  fecha         date not null,
  hora          time,
  creado_en     timestamptz not null default now(),
  estado        text default 'OK',         -- OK / CON_ALERTA
  alertas       text,
  -- "foto" de los datos de la persona al momento del registro (para auditoría/exportable)
  nombre        text,
  cargo         text,
  proyecto_id   text,
  proyecto      text,
  ciudad        text,
  placa_moto    text,
  tipo_vehiculo text,
  usuario       text,
  -- Regla: un registro por persona, por formulario, por día.
  constraint uq_registro_diario unique (cedula, formulario_id, fecha)
);
create index if not exists idx_reg_fecha_form on registros (fecha, formulario_id);
create index if not exists idx_reg_cedula_fecha on registros (cedula, fecha);
create index if not exists idx_reg_proyecto on registros (proyecto_id, fecha);

-- Respuestas normalizadas (una fila por pregunta respondida) => exportar es SQL directo.
create table if not exists respuestas (
  id           bigserial primary key,
  registro_id  uuid not null references registros(id) on delete cascade,
  pregunta_id  text not null,
  valor        text
);
create index if not exists idx_resp_registro on respuestas (registro_id);

-- Evidencias/documentos: el archivo vive en el almacenamiento; aquí va el enlace.
create table if not exists evidencias (
  id           bigserial primary key,
  registro_id  uuid not null references registros(id) on delete cascade,
  pregunta_id  text,
  nombre       text,
  storage_path text,                       -- ruta en el bucket
  url          text,
  subido_en    timestamptz not null default now()
);
create index if not exists idx_evi_registro on evidencias (registro_id);

-- ------------------------------------------------------------
-- 4) CUMPLIMIENTO: justificaciones e historial de cambios
-- ------------------------------------------------------------
create table if not exists justificaciones (
  id          bigserial primary key,
  fecha       date not null,
  cedula      text not null,
  nombre      text,
  proyecto    text,
  motivo      text not null,
  creado_en   timestamptz not null default now(),
  constraint uq_justificacion unique (fecha, cedula)
);
create index if not exists idx_just_fecha on justificaciones (fecha);

create table if not exists historial (
  id          bigserial primary key,
  creado_en   timestamptz not null default now(),
  tipo        text,                         -- CAMBIO_PLACA, INACTIVACION, DOCUMENTOS, ACTUALIZACION_MATRIZ...
  cedula      text,
  detalle     text
);
create index if not exists idx_hist_cedula on historial (cedula);

-- ------------------------------------------------------------
-- 5) CONFIG  (parámetros varios, ej. última actualización de matriz)
-- ------------------------------------------------------------
create table if not exists config (
  clave   text primary key,
  valor   text
);

-- ------------------------------------------------------------
-- 6) Datos base mínimos (los 2 formularios). Editables luego.
-- ------------------------------------------------------------
insert into formularios (id, nombre, descripcion, orden) values
  ('PREOPERACIONAL', 'Registro diario preoperacional', 'Inspección diaria antes de operar la moto.', 1),
  ('LIMPIEZA_MOTO',  'Limpieza y desinfección de la moto', 'Limpieza y desinfección diaria.', 2)
on conflict (id) do nothing;

-- Compatibilidad inicial: al instalar por primera vez, los proyectos ya
-- existentes conservan los formularios activos actuales. Los formularios y
-- proyectos creados después quedan sin asignación hasta que HSEQ los active.
insert into proyectos_formularios (proyecto, formulario_id, activo)
select p.proyecto, f.id, true
from (
  select distinct proyecto from colaboradores where coalesce(proyecto,'') <> ''
) p
cross join formularios f
where f.activo
  and not exists (select 1 from proyectos_formularios)
on conflict (proyecto, formulario_id) do nothing;

-- ------------------------------------------------------------
-- 7) Vista de apoyo: activos por proyecto (para cumplimiento/dashboard)
-- ------------------------------------------------------------
create or replace view v_activos as
  select cedula, nombre, proyecto_id, proyecto, ciudad, placa_moto
  from colaboradores
  where activo;

-- ============================================================
--  Seguridad (RLS) y funciones: ver db/setup.md
--  El acceso "sin login" se maneja con funciones SECURITY DEFINER
--  (el mensajero NO lee la matriz directamente).
-- ============================================================
