-- ============================================================
--  HOTFIX — "column reference estado is ambiguous"
--  ------------------------------------------------------------
--  Al filtrar los registros anulados quedó la palabra "estado"
--  significando dos cosas dentro de la misma consulta: la variable
--  de la función y la columna de la tabla registros. Postgres no
--  sabe a cuál se refiere y falla al buscar la cédula.
--
--  Se renombra la variable a v_estado y la columna se escribe
--  calificada. Ninguna otra cosa cambia.
--
--  Supabase → SQL Editor → New query → pegar todo → Run
--  Después, el mensajero debe recargar la página.
-- ============================================================

create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  v_estado jsonb := '{}'::jsonb;      -- antes se llamaba "estado"
  docs jsonb := '{}'::jsonb;
  v_obs text;
  f record; r record; d record;
  dias int; est text;
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('encontrado', false, 'mensaje', 'No se encontro la cedula en la matriz.');
  end if;

  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');
  v_obs := btrim(coalesce(c.observacion_coordinador, ''));

  if c.activo then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
      order by frm.orden
    loop
      select to_char(reg.hora,'HH24:MI') as h, reg.id::text as rid into r
        from registros reg
       where regexp_replace(reg.cedula,'\D','','g') = ncedula
         and reg.formulario_id = f.id
         and reg.fecha = hoy
         and coalesce(reg.estado,'') <> 'ANULADO'
       limit 1;
      if found then
        v_estado := v_estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        v_estado := v_estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
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
      'proyecto_id', coalesce(c.proyecto_id,''), 'proyecto', proy,
      'proyecto_nomina', coalesce(c.proyecto,''),
      'trasladado', coalesce(btrim(c.proyecto_operativo),'') <> '',
      'ciudad', coalesce(c.ciudad,''), 'placa_moto', coalesce(c.placa_moto,''),
      'tipo_vehiculo', coalesce(c.tipo_vehiculo,'')
    ),
    'formulariosRequeridos', coalesce((
      select jsonb_agg(jsonb_build_object('id_formulario', frm.id, 'nombre_formulario', frm.nombre) order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy), '[]'::jsonb),
    'estadoDiario', v_estado,
    'documentos', docs
  );
end;
$fn$;

-- ------------------------------------------------------------
--  Comprobación: debe devolver los datos sin error.
--  select hseq_api('buscarActivo', '{"cedula":"1003706159"}'::jsonb);
-- ------------------------------------------------------------
