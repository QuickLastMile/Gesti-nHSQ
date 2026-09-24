-- ============================================================
--  Detalle de reportes: sub-pestañas por formulario y filtro de línea
--  ------------------------------------------------------------
--  Sobre lo que ya quedo en db/detalle_de_reportes.sql: mezclar todos
--  los formularios en una sola lista hacia que el mismo nombre y la
--  misma fecha aparecieran varias veces (una fila por formulario que
--  esa persona diligencio ese dia), y parecia informacion duplicada.
--
--  Este script agrega:
--   1. api_reportes_formularios - que formularios estan activos en
--      la linea que se este mirando, para armar las sub-pestanas.
--      Un formulario esta "activo en la linea" si esta prendido
--      (proyectos_formularios.activo) en al menos un proyecto que
--      tenga colaboradores activos de esa linea.
--   2. api_reportes_lista ahora acepta 'formulario' para filtrar por
--      una sola sub-pestana.
--   3. El filtro por linea: solo lo ve la cuenta general (la que
--      puede ver mas de una linea). No recarga toda la pagina como
--      el selector de arriba -ese es para todo el tablero-, solo
--      cambia lo que esta pestana consulta.
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Formularios activos de una linea (para las sub-pestanas)
-- ------------------------------------------------------------
create or replace function api_reportes_formularios(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_linea text := linea_efectiva(coalesce(payload->>'linea',''));
  lista jsonb;
begin
  lista := coalesce((
    select jsonb_agg(jsonb_build_object('id', f.id, 'nombre', f.nombre, 'orden', f.orden) order by f.orden)
      from formularios f
     where f.activo
       and exists (
         select 1 from proyectos_formularios pf
          where pf.formulario_id = f.id and pf.activo
            and pf.proyecto in (
              select distinct coalesce(c.proyecto_efectivo, c.proyecto)
                from colaboradores c where c.linea = v_linea and c.activo))
    ), '[]'::jsonb);
  return jsonb_build_object('formularios', lista);
end;
$fn$;

-- ------------------------------------------------------------
--  2) api_reportes_lista: se agrega el filtro 'formulario'
-- ------------------------------------------------------------
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
         r.placa_moto, r.tipo_vehiculo, r.estado, r.formulario_id
    from registros r
   where r.linea = v_linea
     and coalesce(r.estado,'') <> 'ANULADO'
     and r.fecha between fi and ff
     and (proy = '' or r.proyecto ilike '%'||proy||'%')
     and (ciu = '' or r.ciudad ilike '%'||ciu||'%')
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
--  3) Router: la accion nueva, protegida igual que el resto
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  anchor_lista text := $tag$'reportesLista','reportesPersona','reportesRegistro',$tag$;
  anchor_case  text := $tag$when 'reportesRegistro'  then result := api_reportes_registro(payload);$tag$;
begin
  select prosrc into src from pg_proc where proname = 'hseq_api';
  if src is null then raise exception 'No existe hseq_api'; end if;
  if position('reportesFormularios' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  if position(anchor_lista in src) = 0 then raise exception 'No encontre la lista de acciones de reportes'; end if;
  nuevo := replace(src, anchor_lista, anchor_lista || $tag$'reportesFormularios',$tag$);

  if position(anchor_case in nuevo) = 0 then raise exception 'No encontre el case de reportesRegistro'; end if;
  nuevo := replace(nuevo, anchor_case,
    anchor_case || chr(13) || chr(10)
    || $tag$    when 'reportesFormularios' then result := api_reportes_formularios(payload);$tag$);

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;

  execute 'create or replace function hseq_api(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);

  raise notice 'hseq_api parchado con reportesFormularios.';
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) El router quedo con la accion nueva.
select prosrc like '%reportesFormularios%' as tiene_accion from pg_proc where proname = 'hseq_api';

-- b) Formularios activos por linea, con datos reales.
select c.linea, f.id, f.nombre, f.orden
  from formularios f
  join proyectos_formularios pf on pf.formulario_id = f.id and pf.activo
  join (select distinct linea, coalesce(proyecto_efectivo, proyecto) as proyecto
          from colaboradores where activo) c on c.proyecto = pf.proyecto
 where f.activo
 group by c.linea, f.id, f.nombre, f.orden
 order by c.linea, f.orden;
