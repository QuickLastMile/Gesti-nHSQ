-- ============================================================
--  Detalle de reportes: ciudad como desplegable y se ve la alerta
--  ------------------------------------------------------------
--  api_reportes_lista ahora tambien devuelve:
--   - 'ciudades': las ciudades activas de la linea, para llenar el
--     desplegable (antes Ciudad era texto libre). Sin acotar por
--     los demas filtros, para que no se vaya encogiendo.
--   - 'alertas' en cada fila (ya vivia en la tabla, solo faltaba
--     devolverlo).
--
--  Del lado del frontend (coordinador.html):
--   - Ciudad paso de <input> a <select>.
--   - El detalle de un registro ahora muestra por que quedo "Con
--     alerta" (reusa detallesAlerta(), el mismo desglose que ya
--     usaba la pestana Cumplimiento) -antes la marca de alerta se
--     veia en la lista pero el texto no se mostraba en ningun lado.
--   - Boton "Limpiar" que regresa todos los filtros a su valor por
--     defecto (fecha de hoy, sin busqueda, sin sub-pestana).
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

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
  form_f text := btrim(coalesce(payload->>'formulario',''));
  jefatura text := btrim(coalesce(payload->>'jefatura',''));
  lider text := btrim(coalesce(payload->>'lider',''));
  coordinador text := btrim(coalesce(payload->>'coordinador',''));
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  ncedula text := regexp_replace(buscar, '\D', '', 'g');
  filas jsonb;
  ciudades jsonb;
  total int;
  tope int := 500;
begin
  if perfil is not null and perfil not in ('MOTO','VEHICULO') then
    raise exception 'Perfil no valido: %', perfil;
  end if;
  if buscar <> '' then fi := null; ff := null; end if;
  if fi is null then fi := hoy - 89; end if;
  if ff is null then ff := hoy; end if;
  if fi > ff then raise exception 'Rango de fechas invalido.'; end if;

  drop table if exists pg_temp.tmp_rep;
  create temp table tmp_rep on commit drop as
  select r.id, r.fecha, r.hora, r.cedula, r.nombre, r.cargo, r.proyecto, r.ciudad,
         r.placa_moto, r.tipo_vehiculo, r.estado, r.formulario_id, r.alertas
    from registros r
   where r.linea = v_linea
     and coalesce(r.estado,'') <> 'ANULADO'
     and r.fecha between fi and ff
     and (proy = '' or r.proyecto ilike '%'||proy||'%')
     -- Ahora que Ciudad es un desplegable con las ciudades reales,
     -- coincidencia exacta -antes era ilike, para texto libre.
     and (ciu = '' or r.ciudad = ciu)
     and (perfil is null or perfil_cargo(r.cargo) = perfil)
     and (form_f = '' or r.formulario_id = form_f)
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
        'formulario_id', t.formulario_id, 'estado', t.estado, 'alertas', t.alertas,
        'jefatura', enc.enc_jefatura, 'lider', enc.enc_lider, 'coordinador', enc.enc_coordinador)
      order by t.fecha desc, t.hora desc)
    from (select * from tmp_rep order by fecha desc, hora desc limit tope) t
    left join lateral (
      select c2.enc_jefatura, c2.enc_lider, c2.enc_coordinador
        from colaboradores c2 where regexp_replace(c2.cedula,'\D','','g') = regexp_replace(t.cedula,'\D','','g')
        limit 1) enc on true
    ), '[]'::jsonb);

  -- Sin acotar por el filtro de fecha/proyecto/etc: si se acotara, el
  -- desplegable se iria encogiendo con cada filtro aplicado.
  ciudades := coalesce((
    select jsonb_agg(distinct r.ciudad order by r.ciudad)
      from registros r
     where r.linea = v_linea
       and coalesce(r.estado,'') <> 'ANULADO'
       and r.ciudad is not null and r.ciudad <> ''), '[]'::jsonb);

  return jsonb_build_object('filas', filas, 'total', total, 'limite', tope, 'ciudades', ciudades,
    'filtros', jsonb_build_object('desde', to_char(fi,'YYYY-MM-DD'), 'hasta', to_char(ff,'YYYY-MM-DD')));
end;
$fn$;
