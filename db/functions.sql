-- ============================================================
--  Gestión HSEQ Motos — Funciones de la API (lectura) + seguridad
--  Ejecutar DESPUÉS de schema.sql, en Supabase → SQL Editor → Run.
--  Milestone 1: conectar el frontend y LEER datos reales.
--  (Guardar registros/placas y cumplimiento van en un archivo aparte.)
-- ============================================================

-- ------------------------------------------------------------
--  Seguridad: se cierra el acceso directo a las tablas (RLS).
--  El anon (publishable key) SOLO podrá ejecutar la función hseq_api.
-- ------------------------------------------------------------
alter table colaboradores    enable row level security;
alter table formularios      enable row level security;
alter table proyectos_formularios enable row level security;
alter table preguntas        enable row level security;
alter table opciones         enable row level security;
alter table registros        enable row level security;
alter table respuestas       enable row level security;
alter table evidencias       enable row level security;
alter table justificaciones  enable row level security;
alter table historial        enable row level security;
alter table config           enable row level security;

-- Regla única reutilizable por formularios, escritura y dashboard.
create or replace function formulario_habilitado(v_proyecto text, v_formulario text)
returns boolean language sql stable set search_path = public as $$
  select exists (
    select 1
    from proyectos_formularios pf
    join formularios f on f.id=pf.formulario_id and f.activo
    where pf.proyecto=coalesce(v_proyecto,'')
      and pf.formulario_id=v_formulario
      and pf.activo
  );
$$;

-- ------------------------------------------------------------
--  1) getBootstrap
-- ------------------------------------------------------------
create or replace function api_get_bootstrap()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'formularios', coalesce((
      select jsonb_agg(jsonb_build_object('id_formulario', f.id, 'nombre_formulario', f.nombre) order by f.orden)
      from formularios f
      where f.activo and exists (
        select 1 from proyectos_formularios pf
        join colaboradores c on c.proyecto=pf.proyecto and c.activo
        where pf.formulario_id=f.id and pf.activo
      )), '[]'::jsonb),
    'proyectos', coalesce((
      select jsonb_agg(jsonb_build_object('proyecto_id', proyecto_id, 'proyecto', proyecto))
      from (select distinct c.proyecto_id, c.proyecto
            from colaboradores c
            where c.activo and coalesce(c.proyecto,'') <> ''
              and exists (
                select 1 from proyectos_formularios pf
                join formularios f on f.id=pf.formulario_id and f.activo
                where pf.proyecto=c.proyecto and pf.activo
              )
            order by c.proyecto) p), '[]'::jsonb)
  );
$$;

-- ------------------------------------------------------------
--  2) buscarActivo(cedula)
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  v_obs text;
  estado jsonb := '{}'::jsonb;
  docs   jsonb := '{}'::jsonb;
  f record; r record; d record;
  dias int; est text;
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;

  select * into c from colaboradores
    where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('encontrado', false, 'mensaje', 'No se encontro la cedula.');
  end if;

  v_obs := coalesce(nullif(btrim(c.observacion_coordinador), ''), '');

  if c.activo then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto=coalesce(c.proyecto,'')
      order by frm.orden
    loop
      select id::text as rid, to_char(hora,'HH24:MI') as h into r
        from registros
       where regexp_replace(cedula,'\D','','g') = ncedula
         and formulario_id = f.id and fecha = hoy limit 1;
      if found then
        estado := estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        estado := estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      end if;
    end loop;

    for d in select * from (values
        ('SOAT',          c.soat_vence,          c.soat_url),
        ('TECNOMECANICA', c.tecnomecanica_vence, c.tecnomecanica_url),
        ('LICENCIA',      c.licencia_vence,      c.licencia_url)
      ) as t(k, ven, url) loop
      if d.ven is null then
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha','', 'dias', null, 'estado','sin_dato','url', coalesce(d.url,'')));
      else
        dias := d.ven - hoy;
        est := case when dias < 0 then 'vencido' when dias <= 15 then 'por_vencer' else 'ok' end;
        docs := docs || jsonb_build_object(d.k,
          jsonb_build_object('fecha', to_char(d.ven,'YYYY-MM-DD'), 'dias', dias, 'estado', est, 'url', coalesce(d.url,'')));
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'encontrado', true,
    'activo', c.activo,
    'observacionCoordinador', v_obs,
    'mensaje', case when c.activo then 'Activo habilitado para registro.'
                    when v_obs <> '' then 'No estas habilitado para registrar. Motivo: ' || v_obs
                    else 'La persona no esta activa para registro.' end,
    'requierePlaca', (coalesce(btrim(c.placa_moto),'') = ''),
    'datos', jsonb_build_object(
      'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
      'proyecto_id', coalesce(c.proyecto_id,''), 'proyecto', coalesce(c.proyecto,''),
      'ciudad', coalesce(c.ciudad,''), 'placa_moto', coalesce(c.placa_moto,''),
      'tipo_vehiculo', coalesce(c.tipo_vehiculo,'')
    ),
    'formulariosRequeridos', coalesce((
      select jsonb_agg(jsonb_build_object('id_formulario', frm.id, 'nombre_formulario', frm.nombre) order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto=coalesce(c.proyecto,'')), '[]'::jsonb),
    'estadoDiario', estado,
    'documentos', docs
  );
end;
$$;

-- ------------------------------------------------------------
--  3) cargarFormulario(id_formulario [, cedula])
--     Devuelve las preguntas crudas; el bloque de documentación del
--     preoperacional lo agrega el frontend (igual que hoy).
--     Con cédula agrega además 'previas': las respuestas del último
--     registro, para no volver a diligenciar lo repetitivo.
--     Ver db/precarga_respuestas.sql (define api_respuestas_previas).
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

  -- api_respuestas_previas vive en db/precarga_respuestas.sql. Si aún no se
  -- ejecutó ese script, el formulario sigue funcionando sin precarga.
  begin
    prev := api_respuestas_previas(ced, fid);
  exception when undefined_function then
    prev := jsonb_build_object('valores', '{}'::jsonb);
  end;

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
--  Router: una sola entrada, como el "handleApi_" de Apps Script.
-- ------------------------------------------------------------
create or replace function hseq_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  case action
    when 'getBootstrap'     then result := api_get_bootstrap();
    when 'buscarActivo'     then result := api_buscar_activo(payload);
    when 'cargarFormulario' then result := api_cargar_formulario(payload);
    else raise exception 'Accion no reconocida: %', action;
  end case;
  return jsonb_build_object('ok', true, 'result', result);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

-- El anon (publishable key) solo puede ejecutar el router.
grant execute on function hseq_api(text, jsonb) to anon;
