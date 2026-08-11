-- ============================================================
--  Gestión HSEQ Motos — Reglas de captura de evidencia
--  Dos controles por pregunta, configurables sin tocar código:
--
--   · permitir_galeria    → el archivo puede elegirse del celular.
--                           Si es false, se abre la cámara y la foto
--                           debe ser reciente (no vale una vieja).
--   · verificar_vehiculo  → la foto debe contener una moto o vehículo;
--                           si no, no deja guardar.
--
--  Ejecutar DESPUÉS de: schema.sql, functions.sql, functions_write.sql,
--  precarga_respuestas.sql. Supabase → SQL Editor → New query → Run.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Columnas de configuración
-- ------------------------------------------------------------
alter table preguntas
  add column if not exists permitir_galeria   boolean not null default false,
  add column if not exists verificar_vehiculo boolean not null default false;

comment on column preguntas.permitir_galeria is
  'true = el archivo puede elegirse de la galería. false = se exige tomar la foto en el momento.';
comment on column preguntas.verificar_vehiculo is
  'true = la foto debe contener una moto o vehículo para poder guardar.';

-- ------------------------------------------------------------
-- 2) Reglas actuales
--    LIM_012 — evidencia de la limpieza: foto tomada en el momento
--              y con la moto visible.
--    LIM_013 / LIM_014 — soportes del centro de lavado y permiso de
--              vertimientos: son papeles, se pueden adjuntar de la galería.
-- ------------------------------------------------------------
update preguntas set permitir_galeria = false, verificar_vehiculo = true
 where id = 'LIM_012';

update preguntas set permitir_galeria = true, verificar_vehiculo = false
 where id in ('LIM_013', 'LIM_014');

-- Los documentos del vehículo se adjuntan desde donde el mensajero los tenga.
update preguntas set permitir_galeria = true
 where id in ('DOC_SOAT', 'DOC_TECNOMECANICA', 'DOC_LICENCIA_TRANSITO');

-- ------------------------------------------------------------
-- 3) cargarFormulario devuelve las dos banderas nuevas.
-- ------------------------------------------------------------
create or replace function api_cargar_formulario(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  fid text := payload->>'id_formulario';
  ced text := coalesce(payload->>'cedula', '');
  frm record;
  preg jsonb;
  opc  jsonb;
  prev jsonb;
begin
  select * into frm from formularios where id = fid and activo;
  if not found then raise exception 'Formulario no encontrado o inactivo.'; end if;

  preg := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id_pregunta', id, 'pregunta', pregunta, 'tipo_respuesta', tipo_respuesta,
      'obligatorio', case when obligatorio then 'SI' else 'NO' end,
      'orden', orden, 'seccion', seccion, 'grupo_opciones', grupo_opciones,
      'ayuda', ayuda, 'imagen_url', imagen_url, 'documento', documento,
      'depende_de', depende_de, 'depende_valor', depende_valor,
      'permitir_galeria', permitir_galeria,
      'verificar_vehiculo', verificar_vehiculo
    ) order by orden)
    from preguntas where formulario_id = fid and activo
  ), '[]'::jsonb);

  opc := coalesce((
    select jsonb_object_agg(grupo, arr) from (
      select grupo, jsonb_agg(valor order by orden) arr
      from opciones where activo group by grupo
    ) t
  ), '{}'::jsonb);

  prev := api_respuestas_previas(ced, fid);

  return jsonb_build_object(
    'formulario', jsonb_build_object(
      'id_formulario', frm.id, 'nombre_formulario', frm.nombre,
      'descripcion', frm.descripcion, 'activo', case when frm.activo then 'SI' else 'NO' end),
    'preguntas', preg,
    'opciones', opc,
    'previas', prev->'valores',
    'previasFecha', coalesce(prev->>'fecha', '')
  );
end;
$$;

-- ------------------------------------------------------------
--  Para aplicar la regla a otra pregunta más adelante:
--    update preguntas set verificar_vehiculo = true where id = 'PRE_0XX';
--  Para levantarla:
--    update preguntas set verificar_vehiculo = false where id = 'LIM_012';
-- ------------------------------------------------------------
