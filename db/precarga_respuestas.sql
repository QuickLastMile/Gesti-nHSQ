-- ============================================================
--  Gestión HSEQ Motos — Precarga de respuestas del último registro
--  Objetivo: el mensajero no vuelve a responder lo mismo cada día.
--  Al abrir el formulario se traen las respuestas de su último
--  registro; solo modifica lo que cambió y adjunta las fotos.
--
--  Las EVIDENCIAS nunca se precargan: siempre se toman del día.
--
--  Ejecutar DESPUÉS de: schema.sql, functions.sql, functions_write.sql
--  Supabase → SQL Editor → New query → pegar → Run.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Interruptor por pregunta: permite excluir de la precarga
--    aquellas respuestas que deben escribirse cada día
--    (por ejemplo: observaciones o novedades del turno).
-- ------------------------------------------------------------
alter table preguntas
  add column if not exists no_precargar boolean not null default false;

comment on column preguntas.no_precargar is
  'true = la respuesta nunca se precarga; el mensajero debe responderla cada día.';

-- ------------------------------------------------------------
-- 2) Respuestas del último registro de la persona en ese formulario.
--    Se excluyen:
--      · preguntas de tipo archivo (las evidencias son del día)
--      · fechas de vencimiento de documentos (vienen de la matriz)
--      · la fecha y la hora del propio registro (son de hoy, siempre)
--      · la pregunta que abre el bloque documental (decisión diaria)
--      · las marcadas con no_precargar
-- ------------------------------------------------------------
create or replace function api_respuestas_previas(ced text, fid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(ced, ''), '\D', '', 'g');
  ult record;
  mapa jsonb;
begin
  if ncedula = '' or coalesce(fid, '') = '' then
    return jsonb_build_object('valores', '{}'::jsonb);
  end if;

  select id, fecha into ult
  from registros
  where regexp_replace(cedula, '\D', '', 'g') = ncedula
    and formulario_id = fid
  order by fecha desc, creado_en desc
  limit 1;

  if not found then
    return jsonb_build_object('valores', '{}'::jsonb);
  end if;

  select coalesce(jsonb_object_agg(r.pregunta_id, r.valor), '{}'::jsonb)
    into mapa
  from respuestas r
  join preguntas p on p.id = r.pregunta_id
  where r.registro_id = ult.id
    and p.formulario_id = fid
    and p.activo
    and not p.no_precargar
    and p.tipo_respuesta <> 'archivo'
    and p.tipo_respuesta <> 'hora'          -- la hora es la del momento
    and doc_key(p.pregunta, p.tipo_respuesta, p.documento) is null
    -- La fecha del propio registro es siempre la de hoy, nunca la anterior.
    and not (p.tipo_respuesta = 'fecha' and (
          sin_tildes(p.seccion) like '%DATOS DEL REGISTRO%'
          or sin_tildes(p.pregunta) ~ 'FECHA DE (LA )?(INSPECCION|LIMPIEZA|REGISTRO)'))
    and p.id <> 'DOC_PRIMERA_O_RENOVACION'
    and coalesce(btrim(r.valor), '') <> '';

  return jsonb_build_object(
    'valores', coalesce(mapa, '{}'::jsonb),
    'fecha', to_char(ult.fecha, 'YYYY-MM-DD')
  );
end;
$$;

-- ------------------------------------------------------------
-- 3) cargarFormulario ahora acepta la cédula y devuelve, además
--    de las preguntas, las respuestas previas para precargar.
--    Sin cédula el comportamiento es exactamente el anterior.
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
      'depende_de', depende_de, 'depende_valor', depende_valor
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
-- 4) Opcional — excluir de la precarga las preguntas abiertas de
--    observaciones/novedades, para que no se arrastre de un día
--    al siguiente una falla ya reportada.
--    Descomentar y ejecutar si se quiere aplicar.
-- ------------------------------------------------------------
-- update preguntas
--    set no_precargar = true
--  where activo
--    and (tipo_respuesta = 'parrafo'
--         or sin_tildes(pregunta) ~ 'OBSERVACION|NOVEDAD|COMENTARIO');
