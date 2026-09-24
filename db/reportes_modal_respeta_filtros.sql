-- ============================================================
--  Detalle de reportes: el modal ya respeta los filtros activos
--  ------------------------------------------------------------
--  api_reportes_persona traia SIEMPRE todo el historial de la
--  persona, sin importar el rango de fechas ni la sub-pestana de
--  formulario que se tuviera aplicados en la lista. Ahora respeta
--  ambos -salvo cuando se busca por cedula o nombre, que sigue
--  trayendo todo el historial a proposito-.
--
--  Este cambio va de la mano con el rediseño del modal en
--  coordinador.html: la cuadricula de "un boton por dia" se
--  reemplazo por dos listas desplegables (Formulario, solo si hay
--  mas de uno entre lo que se trajo; y Dia), para no verse tan
--  cargado. Tambien cambio el valor por defecto del filtro de fecha
--  de "ultimos 30 dias" a "solo hoy".
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function api_reportes_persona(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  form_f text := btrim(coalesce(payload->>'formulario',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  c colaboradores%rowtype;
  registros_j jsonb;
begin
  if ncedula = '' then raise exception 'Falta la cedula.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula and linea = v_linea limit 1;
  if not found then raise exception 'No se encontro a esa persona en tu linea.'; end if;

  -- Sin fechaInicio/fechaFin (busqueda por cedula o nombre) se ve TODO el
  -- historial. Con fechas, respeta el mismo rango y formulario que ya
  -- tenia aplicado la lista.
  registros_j := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id_registro', r.id, 'fecha', to_char(r.fecha,'YYYY-MM-DD'), 'hora', to_char(r.hora,'HH24:MI'),
      'formulario_id', r.formulario_id, 'estado', r.estado, 'alertas', r.alertas)
      order by r.fecha desc, r.hora desc)
    from registros r
   where regexp_replace(r.cedula,'\D','','g') = ncedula
     and coalesce(r.estado,'') <> 'ANULADO'
     and (fi is null or r.fecha >= fi)
     and (ff is null or r.fecha <= ff)
     and (form_f = '' or r.formulario_id = form_f)), '[]'::jsonb);

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
--  Verificacion (con datos reales de WAREHOUSE)
-- ------------------------------------------------------------
-- Sin filtro deberia traer mas registros que filtrando "solo hoy",
-- y filtrando por un formulario deberia traer menos que sin filtro.
