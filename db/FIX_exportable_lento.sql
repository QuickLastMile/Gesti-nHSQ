-- ============================================================
--  FIX — El exportable se cae con "statement timeout"
--  ------------------------------------------------------------
--  Sintoma: al pedir un rango de varios dias con todos los
--  proyectos, la pantalla responde
--      "Base de datos: canceling statement due to statement timeout"
--
--  Causa: api_exportable armaba el resultado dentro de un bucle,
--  pegando cada registro al final de un arreglo JSON:
--
--      filas := filas || jsonb_build_array(...)
--
--  Cada pegada copia el arreglo COMPLETO otra vez. Con 200
--  registros no se nota; con 8.000 el trabajo crece al cuadrado y
--  la base corta la consulta a los 8 segundos. Por eso un dia si
--  descarga y una semana no: no es el rango, es el bucle.
--
--  Ademas, por cada registro se hacian tres busquedas sueltas
--  (respuestas, evidencias y el encargado del colaborador), y el
--  filtro de encargado llamaba a en_alcance_enc una vez por fila.
--
--  Que hace este script: reescribe api_exportable para armar todo
--  en una sola consulta, con las respuestas y evidencias agrupadas
--  de una vez y el filtro de encargado aplicado una sola vez.
--  El resultado es identico, columna por columna.
--
--  No depende de los otros scripts pendientes y no los estorba.
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function api_exportable(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  fid text := payload->>'formulario';
  fi date := nullif(payload->>'fechaInicio','')::date;
  ff date := nullif(payload->>'fechaFin','')::date;
  filtro_proy text := btrim(coalesce(payload->>'proyecto',''));
  proy_nom text;
  enc_jef text := btrim(coalesce(payload->>'jefatura',''));
  enc_lid text := btrim(coalesce(payload->>'lider',''));
  enc_coo text := btrim(coalesce(payload->>'coordinador',''));
  enc_hay boolean := (btrim(coalesce(payload->>'jefatura','')) <> ''
                   or btrim(coalesce(payload->>'lider','')) <> ''
                   or btrim(coalesce(payload->>'coordinador','')) <> '');
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  perfil text := nullif(upper(btrim(coalesce(payload->>'perfil',''))), '');
  preguntas jsonb;
  filas jsonb;
  n int;
  tope int := 30000;
begin
  if fid is null or fid = '' then raise exception 'Selecciona un formulario.'; end if;
  if fi is null or ff is null or fi > ff then raise exception 'Rango de fechas invalido.'; end if;
  if perfil is not null and perfil not in ('MOTO','VEHICULO') then
    raise exception 'Perfil no valido: %', perfil;
  end if;

  -- El nombre del proyecto se resuelve una vez, no en cada fila.
  if filtro_proy <> '' then
    proy_nom := coalesce(nombre_proyecto(filtro_proy), filtro_proy);
  end if;

  preguntas := coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'pregunta', pregunta) order by orden)
      from preguntas
     where formulario_id = fid and activo
       and (perfil is null or aplica_a is null or aplica_a = perfil)), '[]'::jsonb);

  -- ----------------------------------------------------------
  -- 1) Los registros del rango, filtrados una sola vez.
  -- ----------------------------------------------------------
  drop table if exists pg_temp.tmp_exp;
  create temp table tmp_exp on commit drop as
  select r.id, r.fecha, r.hora, r.cedula,
         regexp_replace(r.cedula,'\D','','g') as ced_norm,
         r.nombre, r.cargo, r.proyecto_id, r.proyecto, r.ciudad,
         r.placa_moto, r.tipo_vehiculo, r.estado, r.alertas,
         r.diferido, r.creado_en
    from registros r
   where r.formulario_id = fid
     and r.fecha between fi and ff
     and coalesce(r.estado,'') <> 'ANULADO'
     and (filtro_proy = '' or r.proyecto = proy_nom)
     and (ncedula = '' or regexp_replace(r.cedula,'\D','','g') = ncedula)
     and (perfil is null or perfil_cargo(r.cargo) = perfil);

  -- El filtro de encargado se resuelve contra la matriz de una vez,
  -- no llamando a una funcion por cada registro.
  if enc_hay then
    delete from tmp_exp t
     where not exists (
       select 1 from colaboradores c
        where regexp_replace(c.cedula,'\D','','g') = t.ced_norm
          and (enc_jef = '' or sin_tildes(btrim(coalesce(c.enc_jefatura,'')))    = sin_tildes(enc_jef))
          and (enc_lid = '' or sin_tildes(btrim(coalesce(c.enc_lider,'')))       = sin_tildes(enc_lid))
          and (enc_coo = '' or sin_tildes(btrim(coalesce(c.enc_coordinador,''))) = sin_tildes(enc_coo)));
  end if;

  create index on tmp_exp (id);
  create index on tmp_exp (ced_norm);
  analyze tmp_exp;

  select count(*) into n from tmp_exp;

  -- Un archivo mas grande que esto no lo abre Excel comodo ni lo
  -- aguanta el navegador. Mejor decirlo claro que morir en el intento.
  if n > tope then
    raise exception 'La descarga trae % registros y el limite es %. Acorta el rango de fechas o filtra por proyecto o encargado.', n, tope;
  end if;

  -- ----------------------------------------------------------
  -- 2) Todo el archivo en una sola consulta.
  -- ----------------------------------------------------------
  filas := coalesce((
    select jsonb_agg(jsonb_build_object(
        'fecha', to_char(t.fecha,'YYYY-MM-DD'),
        'hora', to_char(t.hora,'HH24:MI:SS'),
        'id_registro', t.id,
        'cedula', t.cedula,
        'nombre', coalesce(t.nombre,''),
        'cargo', coalesce(t.cargo,''),
        'tipo', perfil_cargo(t.cargo),
        'proyecto_id', coalesce(t.proyecto_id,''),
        'proyecto', coalesce(t.proyecto,''),
        'ciudad', coalesce(t.ciudad,''),
        'jefatura', coalesce(enc.enc_jefatura,''),
        'lider', coalesce(enc.enc_lider,''),
        'coordinador', coalesce(enc.enc_coordinador,''),
        'frente', coalesce(enc.frente,''),
        'placa_moto', coalesce(t.placa_moto,''),
        'tipo_vehiculo', coalesce(t.tipo_vehiculo,''),
        'estado', coalesce(t.estado,''),
        'sin_conexion', case when t.diferido then 'SI' else 'NO' end,
        'enviado_en', to_char(t.creado_en at time zone 'America/Bogota','YYYY-MM-DD HH24:MI'),
        'estado_cumplimiento', case when coalesce(t.alertas,'') <> '' then 'REQUIERE_GESTION' else 'CUMPLE' end,
        'alertas_documentales', coalesce(t.alertas,''),
        'respuestas', coalesce(rp.resp, '{}'::jsonb),
        'evidencias', coalesce(ev.evid, '{}'::jsonb))
      order by t.fecha, t.hora)
    from tmp_exp t
    left join lateral (
      select c2.enc_jefatura, c2.enc_lider, c2.enc_coordinador, c2.frente
        from colaboradores c2
       where regexp_replace(c2.cedula,'\D','','g') = t.ced_norm
       limit 1) enc on true
    -- Las respuestas de TODOS los registros, agrupadas de una vez.
    left join (
      select rr.registro_id,
             jsonb_object_agg(rr.pregunta_id, rr.valor) as resp
        from respuestas rr
        join tmp_exp t2 on t2.id = rr.registro_id
       where rr.pregunta_id is not null
       group by rr.registro_id) rp on rp.registro_id = t.id
    -- Igual las evidencias. El "order by" deja de ultima la mas
    -- reciente, que es la que queda cuando la llave se repite.
    left join (
      select ee.registro_id,
             jsonb_object_agg(ee.pregunta_id,
                              coalesce(nullif(ee.storage_path,''), ee.url)
                              order by ee.subido_en) as evid
        from evidencias ee
        join tmp_exp t3 on t3.id = ee.registro_id
       where ee.pregunta_id is not null
         and (coalesce(ee.storage_path,'') <> '' or coalesce(ee.url,'') <> '')
       group by ee.registro_id) ev on ev.registro_id = t.id
  ), '[]'::jsonb);

  return jsonb_build_object('formulario', fid, 'perfil', coalesce(perfil,''),
    'preguntas', preguntas, 'filas', filas, 'total', n);
end;
$fn$;

-- ------------------------------------------------------------
--  Margen de tiempo para las consultas del coordinador
--  ------------------------------------------------------------
--  Un exportable de un mes completo es pesado por naturaleza. Los
--  8 segundos que trae Supabase por defecto quedan justos, asi que
--  a la sesion con login se le dan 30. El mensajero (anon, sin
--  login) se queda en el limite normal.
-- ------------------------------------------------------------
alter role authenticated set statement_timeout = '30s';

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
select 'api_exportable' as funcion,
       case when prosrc like '%tmp_exp%' then 'ACTUALIZADA'
            else 'SIGUE LA VERSION LENTA' end as estado
  from pg_proc where proname = 'api_exportable';

select rolname, rolconfig from pg_roles where rolname = 'authenticated';
