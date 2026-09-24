-- ============================================================
--  Pestaña "Detalle de reportes" en coordinador.html
--  ------------------------------------------------------------
--  Hasta ahora, para ver las respuestas y evidencias de un registro
--  puntual habia que descargar el exportable y abrirlo en Excel. Se
--  pidio poder consultarlo directamente en pantalla: filtrar por
--  proyecto, tipo de vehiculo, fecha, ciudad y encargado, buscar por
--  cedula o nombre (y si se busca, ver TODO el historial de esa
--  persona, no solo lo que cae en el filtro de fechas), y al elegir
--  un dia ver las preguntas con sus respuestas y las evidencias.
--
--  Tres funciones nuevas, cada una un paso:
--   1. api_reportes_lista    - la tabla filtrable/buscable.
--   2. api_reportes_persona  - al hacer click en un nombre: todos
--      sus registros, sin limite de fecha.
--   3. api_reportes_registro - al elegir un dia: preguntas,
--      respuestas y evidencias de ESE registro puntual.
--
--  api_reportes_registro reusa el patron de api_exportable (misma
--  idea de preguntas+respuestas+evidencias por registro), pero las
--  evidencias van en un jsonb_agg (arreglo), no jsonb_object_agg
--  (objeto): asi no se pierde ninguna foto si una pregunta tiene mas
--  de una (limpieza ahora admite hasta 4 fotos por la evidencia de
--  la moto, ver EVIDENCIA_LIMPIEZA_MULTIPLE en mensajero.html).
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) La lista: filtrable y buscable
--  ------------------------------------------------------------
create or replace function api_reportes_lista(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  buscar text := btrim(coalesce(payload->>'buscar',''));
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  proy text := btrim(coalesce(payload->>'proyecto',''));
  ciu text := btrim(coalesce(payload->>'ciudad',''));
  perfil text := nullif(upper(btrim(coalesce(payload->>'perfil',''))), '');
  jefatura text := btrim(coalesce(payload->>'jefatura',''));
  lider text := btrim(coalesce(payload->>'lider',''));
  coordinador text := btrim(coalesce(payload->>'coordinador',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ncedula text := regexp_replace(buscar, '\D', '', 'g');
  filas jsonb;
  total int;
  tope int := 500;
begin
  if perfil is not null and perfil not in ('MOTO','VEHICULO') then
    raise exception 'Perfil no valido: %', perfil;
  end if;
  -- Si hay busqueda, el rango de fechas se ignora: se quiere ver TODO
  -- el historial de esa persona, no solo lo que cae en el filtro.
  if buscar <> '' then fi := null; ff := null; end if;
  if fi is null then fi := hoy - 89; end if;
  if ff is null then ff := hoy; end if;
  if fi > ff then raise exception 'Rango de fechas invalido.'; end if;

  drop table if exists pg_temp.tmp_rep;
  create temp table tmp_rep on commit drop as
  select r.id, r.fecha, r.hora, r.cedula, r.nombre, r.cargo, r.proyecto, r.ciudad,
         r.placa_moto, r.tipo_vehiculo, r.estado, r.formulario_id
    from registros r
   where r.linea = v_linea
     and coalesce(r.estado,'') <> 'ANULADO'
     and r.fecha between fi and ff
     and (proy = '' or r.proyecto ilike '%'||proy||'%')
     and (ciu = '' or r.ciudad ilike '%'||ciu||'%')
     and (perfil is null or perfil_cargo(r.cargo) = perfil)
     and (buscar = ''
          or r.nombre ilike '%'||buscar||'%'
          or (ncedula <> '' and regexp_replace(r.cedula,'\D','','g') = ncedula));

  if jefatura <> '' or lider <> '' or coordinador <> '' then
    delete from tmp_rep t
     where not exists (
       select 1 from colaboradores c
        where regexp_replace(c.cedula,'\D','','g') = regexp_replace(t.cedula,'\D','','g')
          and (jefatura = '' or sin_tildes(btrim(coalesce(c.enc_jefatura,''))) = sin_tildes(jefatura))
          and (lider = '' or sin_tildes(btrim(coalesce(c.enc_lider,''))) = sin_tildes(lider))
          and (coordinador = '' or sin_tildes(btrim(coalesce(c.enc_coordinador,''))) = sin_tildes(coordinador)));
  end if;

  select count(*) into total from tmp_rep;

  filas := coalesce((
    select jsonb_agg(jsonb_build_object(
        'id_registro', t.id, 'fecha', to_char(t.fecha,'YYYY-MM-DD'), 'hora', to_char(t.hora,'HH24:MI'),
        'cedula', t.cedula, 'nombre', t.nombre, 'tipo', perfil_cargo(t.cargo),
        'proyecto', t.proyecto, 'ciudad', t.ciudad, 'placa_moto', t.placa_moto,
        'formulario_id', t.formulario_id, 'estado', t.estado,
        'jefatura', enc.enc_jefatura, 'lider', enc.enc_lider, 'coordinador', enc.enc_coordinador)
      order by t.fecha desc, t.hora desc)
    from (select * from tmp_rep order by fecha desc, hora desc limit tope) t
    left join lateral (
      select c2.enc_jefatura, c2.enc_lider, c2.enc_coordinador
        from colaboradores c2 where regexp_replace(c2.cedula,'\D','','g') = regexp_replace(t.cedula,'\D','','g')
        limit 1) enc on true
    ), '[]'::jsonb);

  return jsonb_build_object('filas', filas, 'total', total, 'limite', tope,
    'filtros', jsonb_build_object('desde', to_char(fi,'YYYY-MM-DD'), 'hasta', to_char(ff,'YYYY-MM-DD')));
end;
$fn$;

-- ------------------------------------------------------------
--  2) El historial completo de una persona (sin limite de fecha)
-- ------------------------------------------------------------
create or replace function api_reportes_persona(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  c colaboradores%rowtype;
  registros_j jsonb;
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula and linea = v_linea limit 1;
  if not found then raise exception 'No se encontro a esa persona en tu linea.'; end if;

  registros_j := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id_registro', r.id, 'fecha', to_char(r.fecha,'YYYY-MM-DD'), 'hora', to_char(r.hora,'HH24:MI'),
      'formulario_id', r.formulario_id, 'estado', r.estado, 'alertas', r.alertas)
      order by r.fecha desc, r.hora desc)
    from registros r
   where regexp_replace(r.cedula,'\D','','g') = ncedula
     and coalesce(r.estado,'') <> 'ANULADO'), '[]'::jsonb);

  return jsonb_build_object(
    'persona', jsonb_build_object('cedula', c.cedula, 'nombre', c.nombre, 'cargo', c.cargo,
      'proyecto', coalesce(c.proyecto_efectivo, c.proyecto), 'ciudad', c.ciudad,
      'placa_moto', c.placa_moto, 'tipo_vehiculo', c.tipo_vehiculo,
      'jefatura', c.enc_jefatura, 'lider', c.enc_lider, 'coordinador', c.enc_coordinador,
      'activo', c.activo),
    'registros', registros_j);
end;
$fn$;

-- ------------------------------------------------------------
--  3) Preguntas, respuestas y evidencias de UN registro puntual
-- ------------------------------------------------------------
create or replace function api_reportes_registro(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  rid uuid := nullif(payload->>'id_registro','')::uuid;
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  r registros%rowtype;
  preguntas_j jsonb;
  respuestas_j jsonb;
  evidencias_j jsonb;
begin
  if rid is null then raise exception 'Falta el id del registro.'; end if;
  select * into r from registros where id = rid and linea = v_linea;
  if not found then raise exception 'Registro no encontrado en tu linea.'; end if;

  preguntas_j := coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'pregunta', p.pregunta, 'seccion', p.seccion,
        'tipo_respuesta', p.tipo_respuesta, 'orden', p.orden) order by p.orden)
      from preguntas p
     where p.formulario_id = r.formulario_id and p.activo
       and (p.aplica_a is null or p.aplica_a = perfil_cargo(r.cargo))), '[]'::jsonb);

  respuestas_j := coalesce((
    select jsonb_object_agg(rp.pregunta_id, rp.valor)
      from respuestas rp where rp.registro_id = rid), '{}'::jsonb);

  -- jsonb_agg (arreglo), no jsonb_object_agg: si una pregunta tiene mas
  -- de una evidencia (limpieza ahora admite hasta 4 fotos), se ven todas.
  evidencias_j := coalesce((
    select jsonb_agg(jsonb_build_object('pregunta_id', ee.pregunta_id, 'nombre', ee.nombre,
        'storage_path', ee.storage_path, 'url', ee.url) order by ee.subido_en)
      from evidencias ee where ee.registro_id = rid), '[]'::jsonb);

  return jsonb_build_object(
    'registro', jsonb_build_object('id', r.id, 'fecha', to_char(r.fecha,'YYYY-MM-DD'), 'hora', to_char(r.hora,'HH24:MI'),
      'cedula', r.cedula, 'nombre', r.nombre, 'proyecto', r.proyecto, 'ciudad', r.ciudad,
      'placa_moto', r.placa_moto, 'formulario_id', r.formulario_id, 'estado', r.estado, 'alertas', r.alertas,
      'diferido', r.diferido),
    'preguntas', preguntas_j, 'respuestas', respuestas_j, 'evidencias', evidencias_j);
end;
$fn$;

-- ------------------------------------------------------------
--  4) Router: tres acciones nuevas, protegidas igual que el resto
--  ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  anchor_lista text := $tag$'listaEncargados','alertasMantenimiento','getTemperatura',$tag$;
  anchor_case  text := $tag$when 'getTemperatura'     then result := api_temperatura(payload);$tag$;
begin
  select prosrc into src from pg_proc where proname = 'hseq_api';
  if src is null then raise exception 'No existe hseq_api'; end if;
  if position('reportesLista' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  if position(anchor_lista in src) = 0 then raise exception 'No encontre la lista de acciones protegidas'; end if;
  nuevo := replace(src, anchor_lista, anchor_lista || $tag$'reportesLista','reportesPersona','reportesRegistro',$tag$);

  if position(anchor_case in nuevo) = 0 then raise exception 'No encontre el case de getTemperatura'; end if;
  nuevo := replace(nuevo, anchor_case,
    anchor_case || chr(13) || chr(10)
    || $tag$    when 'reportesLista'     then result := api_reportes_lista(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'reportesPersona'   then result := api_reportes_persona(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'reportesRegistro'  then result := api_reportes_registro(payload);$tag$);

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;

  execute 'create or replace function hseq_api(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);

  raise notice 'hseq_api parchado con reportesLista/reportesPersona/reportesRegistro.';
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
select prosrc like '%reportesLista%' as tiene_lista,
       prosrc like '%api_reportes_persona(payload)%' as tiene_persona,
       prosrc like '%api_reportes_registro(payload)%' as tiene_registro
  from pg_proc where proname = 'hseq_api';
