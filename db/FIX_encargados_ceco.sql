-- ============================================================
--  FIX — Proyectos sin CECO y encargados del proyecto efectivo
--  ------------------------------------------------------------
--  Dos problemas con una misma raíz: el CECO.
--
--  1) INGRESOS PROVISIONALES SIN CECO
--     admin_crear_provisional nunca guardaba proyecto_id. Como los
--     encargados se resuelven por CECO, esas personas quedaban
--     SIN jefe, SIN líder y SIN coordinador — y además la lista de
--     Encargados las juntaba a todas en una fila fantasma "CECO —"
--     que tomaba prestado el nombre de un proyecto cualquiera.
--     Eso explica el segundo "DOM CAFAM COMERCIAL" sin CECO.
--
--  2) LA LISTA AGRUPABA POR EL PROYECTO DE NÓMINA
--     El panel contaba a la gente por su proyecto de nómina, pero
--     el coordinador se resuelve por el proyecto donde labora. Un
--     trasladado se contaba en el proyecto que dejó y su
--     coordinador salía del proyecto al que se fue: por eso
--     Institucional decía "1 sin coordinador" aunque sus dos
--     frentes estuvieran completos.
--
--  Ejecutar DESPUÉS de: FIX_parametro_nombre.sql
--  Supabase → SQL Editor → New query → pegar todo → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) Un solo lugar donde se decide cuál es el CECO que manda
-- ------------------------------------------------------------
create or replace function ceco_efectivo(p_proy_id text, p_proy_oper text)
returns text language sql stable set search_path = public as $fn$
  select case
    when coalesce(btrim(p_proy_oper), '') <> ''
      then coalesce(nullif(codigo_proyecto(p_proy_oper), ''), btrim(coalesce(p_proy_id, '')))
    else btrim(coalesce(p_proy_id, ''))
  end;
$fn$;

comment on function ceco_efectivo(text, text) is
  'CECO por el que responde una persona: el del proyecto donde labora si esta trasladada, si no el de su nomina.';

-- calc_encargados pasa a usar esa misma regla, para que el panel y
-- el calculo no puedan volver a discrepar.
create or replace function calc_encargados(
  p_proy_id text, p_proy_oper text, p_frente text, p_coord_manual text,
  out jefatura text, out lider text, out coordinador text)
language plpgsql stable set search_path = public as $fn$
declare
  pid text := ceco_efectivo(p_proy_id, p_proy_oper);
  fr  text := coalesce(nullif(btrim(p_frente), ''), '');
  rg  responsables_proyecto%rowtype;
  rf  responsables_proyecto%rowtype;
begin
  if pid <> '' then
    select * into rg from responsables_proyecto r
      where r.proyecto_id = pid and r.frente = '' limit 1;
    if fr <> '' then
      select * into rf from responsables_proyecto r
        where r.proyecto_id = pid and r.frente = fr limit 1;
    end if;
  end if;

  jefatura    := coalesce(nullif(btrim(rf.jefatura), ''), nullif(btrim(rg.jefatura), ''), '');
  lider       := coalesce(nullif(btrim(rf.lider), ''),    nullif(btrim(rg.lider), ''),    '');
  coordinador := coalesce(nullif(btrim(p_coord_manual), ''),
                          nullif(btrim(rf.coordinador), ''),
                          nullif(btrim(rg.coordinador), ''), '');
end;
$fn$;

-- ------------------------------------------------------------
-- 2) El ingreso provisional guarda el CECO del proyecto elegido
-- ------------------------------------------------------------
create or replace function admin_crear_provisional(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  v_nombre text := btrim(coalesce(payload->>'nombre',''));
  v_proy text := btrim(coalesce(payload->>'proyecto',''));
  v_cargo text := btrim(coalesce(payload->>'cargo',''));
  v_ciudad text := btrim(coalesce(payload->>'ciudad',''));
  v_ceco text;
  hoy date := (now() at time zone 'America/Bogota')::date;
  ya colaboradores%rowtype;
begin
  if length(ncedula) < 5 then raise exception 'Digita una cedula valida.'; end if;
  if v_nombre = '' then raise exception 'Escribe el nombre completo.'; end if;
  if v_proy = '' then raise exception 'Selecciona el proyecto.'; end if;
  if v_cargo = '' then raise exception 'Selecciona el cargo.'; end if;

  -- Sin CECO la persona quedaria sin jefe, sin lider y sin coordinador.
  v_ceco := codigo_proyecto(v_proy);
  if coalesce(v_ceco,'') = '' then
    raise exception 'El proyecto "%" no existe en la matriz o no tiene CECO. Elige uno de la lista.', v_proy;
  end if;

  select * into ya from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula;
  if found then
    update colaboradores set
      activo = true,
      nombre = coalesce(nullif(btrim(colaboradores.nombre),''), upper(v_nombre)),
      proyecto = coalesce(nullif(btrim(colaboradores.proyecto),''), v_proy),
      proyecto_id = coalesce(nullif(btrim(colaboradores.proyecto_id),''), v_ceco),
      cargo = coalesce(nullif(btrim(colaboradores.cargo),''), upper(v_cargo)),
      observacion_coordinador = null,
      actualizado_en = now()
    where regexp_replace(cedula,'\D','','g') = ncedula;

    insert into historial (tipo, cedula, detalle)
    values ('PROVISIONAL', ncedula, 'Ya existia en la matriz; se reactivo desde configuracion.');

    return jsonb_build_object('cedula', ncedula, 'creado', false, 'reactivado', true,
      'mensaje', 'Esta persona ya estaba en la matriz. Se reactivo y ya puede registrar.');
  end if;

  insert into colaboradores (cedula, nombre, cargo, proyecto, proyecto_id, ciudad, activo,
                             tipo_vehiculo, provisional, provisional_desde, observaciones_hsq)
  values (ncedula, upper(v_nombre), upper(v_cargo), v_proy, v_ceco, nullif(upper(v_ciudad),''), true,
          case when sin_tildes(v_cargo) like '%CONDUCTOR%' then 'VEHICULO' else 'MOTO' end,
          true, hoy,
          'Ingreso provisional creado el ' || hoy || ' desde configuracion, pendiente de nomina.');

  insert into historial (tipo, cedula, detalle)
  values ('PROVISIONAL', ncedula, 'Ingreso provisional: ' || v_nombre || ' - ' || v_proy || ' - ' || v_cargo);

  return jsonb_build_object('cedula', ncedula, 'creado', true, 'reactivado', false,
    'mensaje', 'Listo. ' || v_nombre || ' ya puede registrar.');
end;
$fn$;

-- ------------------------------------------------------------
-- 3) Reparar lo que ya quedo sin CECO
-- ------------------------------------------------------------
update colaboradores
   set proyecto_id = codigo_proyecto(proyecto)
 where coalesce(btrim(proyecto_id), '') = ''
   and coalesce(btrim(proyecto), '') <> ''
   and coalesce(codigo_proyecto(proyecto), '') <> '';

-- ------------------------------------------------------------
-- 4) El panel cuenta por el proyecto donde la gente labora
-- ------------------------------------------------------------
create or replace function admin_encargados()
returns jsonb language sql security definer set search_path = public as $fn$
  with base as (
    select c.activo, c.cargo, c.enc_coordinador,
           btrim(coalesce(c.frente, '')) frente,
           ceco_efectivo(c.proyecto_id, c.proyecto_operativo) ceco,
           coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto) proy_nombre
    from colaboradores c
    where coalesce(c.proyecto, '') <> ''
  ),
  proys as (
    -- Sin CECO, dos proyectos distintos no pueden caer en la misma fila.
    select b.ceco,
           case when b.ceco = '' then b.proy_nombre else '' end agrupa_nombre,
           max(b.proy_nombre) nombre_visto,
           count(*) filter (where b.activo and cargo_aplica(b.cargo)) activos,
           count(*) filter (where b.activo and cargo_aplica(b.cargo)
                              and coalesce(b.enc_coordinador, '') = '') sin_coordinador,
           count(*) filter (where b.activo and cargo_aplica(b.cargo) and b.frente = '') sin_frente
    from base b
    group by b.ceco, case when b.ceco = '' then b.proy_nombre else '' end
  )
  select jsonb_build_object(
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'proyecto_id', p.ceco,
               'sin_ceco',    (p.ceco = ''),
               'proyecto',    case when p.ceco = '' then p.nombre_visto
                                   else coalesce(nullif(nombre_proyecto(p.ceco), ''), p.nombre_visto) end,
               'cliente',     coalesce(rg.cliente, ''),
               'jefatura',    coalesce(rg.jefatura, ''),
               'lider',       coalesce(rg.lider, ''),
               'coordinador', coalesce(rg.coordinador, ''),
               'activos',     p.activos,
               'sin_coordinador', p.sin_coordinador,
               'sin_frente',  p.sin_frente,
               'frentes', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'frente', f.frente, 'jefatura', coalesce(f.jefatura, ''),
                           'lider', coalesce(f.lider, ''), 'coordinador', coalesce(f.coordinador, ''),
                           'personas', (select count(*) from colaboradores cc
                                         where cc.activo and cargo_aplica(cc.cargo)
                                           and ceco_efectivo(cc.proyecto_id, cc.proyecto_operativo) = p.ceco
                                           and btrim(coalesce(cc.frente, '')) = f.frente))
                         order by f.frente)
                  from responsables_proyecto f
                  where p.ceco <> '' and f.proyecto_id = p.ceco and f.frente <> ''), '[]'::jsonb))
             order by (p.ceco = '') desc, case when p.ceco = '' then p.nombre_visto
                                               else coalesce(nullif(nombre_proyecto(p.ceco), ''), p.nombre_visto) end)
      from proys p
      left join responsables_proyecto rg on p.ceco <> '' and rg.proyecto_id = p.ceco and rg.frente = ''), '[]'::jsonb),
    -- CECOs cargados que hoy no tienen a nadie en la matriz.
    'huerfanos', coalesce((
      select jsonb_agg(jsonb_build_object('proyecto_id', r.proyecto_id, 'cliente', coalesce(r.cliente, ''),
                                          'jefatura', coalesce(r.jefatura, ''), 'lider', coalesce(r.lider, ''))
             order by r.proyecto_id)
      from responsables_proyecto r
      where r.frente = ''
        and not exists (select 1 from proys p where p.ceco = r.proyecto_id)), '[]'::jsonb)
  );
$fn$;

-- Las personas del proyecto se buscan por el mismo criterio.
create or replace function admin_personas_proyecto(payload jsonb)
returns jsonb language sql security definer set search_path = public as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'cedula', c.cedula, 'nombre', coalesce(c.nombre, ''),
           'ciudad', coalesce(c.ciudad, ''), 'cargo', coalesce(c.cargo, ''),
           'frente', coalesce(c.frente, ''),
           'coordinador_propio', coalesce(c.coordinador, ''),
           'coordinador', coalesce(c.enc_coordinador, ''),
           'jefatura', coalesce(c.enc_jefatura, ''), 'lider', coalesce(c.enc_lider, ''),
           'trasladado', coalesce(nullif(btrim(c.proyecto_operativo), ''), '') <> '',
           'proyecto_nomina', coalesce(c.proyecto, ''))
         order by coalesce(c.ciudad, ''), c.nombre), '[]'::jsonb)
  from colaboradores c
  where c.activo and cargo_aplica(c.cargo)
    and ceco_efectivo(c.proyecto_id, c.proyecto_operativo) = btrim(coalesce(payload->>'proyecto_id', ''))
    -- Los proyectos sin CECO se distinguen por el nombre.
    and (btrim(coalesce(payload->>'proyecto_id', '')) <> ''
         or coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto) = btrim(coalesce(payload->>'proyecto', '')));
$fn$;

revoke all on function ceco_efectivo(text, text) from public, anon;

-- ------------------------------------------------------------
-- 5) Recalcular con todo ya corregido
-- ------------------------------------------------------------
select recalcular_encargados() as colaboradores_actualizados;

-- ------------------------------------------------------------
-- 6) Comprobación
--    a) No debería quedar gente activa sin CECO.
--    b) Quién sigue sin coordinador, y por qué.
-- ------------------------------------------------------------
select 'SIN CECO' as revisar, c.cedula, c.nombre, c.proyecto,
       case when c.provisional then 'ingreso provisional' else 'viene de la matriz' end as origen
from colaboradores c
where c.activo and cargo_aplica(c.cargo)
  and ceco_efectivo(c.proyecto_id, c.proyecto_operativo) = ''

union all

select 'SIN COORDINADOR', c.cedula, c.nombre,
       coalesce(nullif(btrim(c.proyecto_operativo), ''), c.proyecto),
       case when coalesce(btrim(c.proyecto_operativo), '') <> '' then 'trasladado a otro proyecto'
            when coalesce(btrim(c.frente), '') = '' then 'sin frente asignado'
            else 'su frente no tiene coordinador' end
from colaboradores c
where c.activo and cargo_aplica(c.cargo)
  and coalesce(c.enc_coordinador, '') = ''
order by 1, 4, 3;
