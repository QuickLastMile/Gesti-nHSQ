-- ============================================================
--  Actualizar documentacion cuando el mensajero quiera
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  Hasta ahora los documentos solo se podian subir cuando la app
--  los pedia, y solo dentro del preoperacional. Eso deja dos
--  huecos:
--
--   1. El que acaba de renovar el SOAT y lo tiene en la mano no
--      puede adjuntarlo: le toca esperar a que se le venza para
--      que la app se lo pida. Justo al reves de lo que conviene.
--   2. El que ya hizo el preoperacional de hoy no tiene donde
--      hacerlo hasta manana, aunque el documento ya este vencido.
--
--  QUE HACE
--  --------
--  Una accion propia, sin registro de por medio. Actualizar un
--  documento no es diligenciar un formulario: no debe contar como
--  registro del dia, ni chocar con el "un registro diario por
--  tipo", ni obligar a responder el preoperacional entero.
--
--  Valida lo mismo que el preoperacional (fecha obligatoria, tope
--  de anios configurable) y levanta el rechazo del documento que
--  se reemplaza, que es lo que ya hacia api_guardar_registro.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function api_actualizar_documentos(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula    text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  evidencias jsonb := coalesce(payload->'evidencias', '[]'::jsonb);
  fechas     jsonb := coalesce(payload->'fechas', '{}'::jsonb);
  c          colaboradores%rowtype;
  hoy        date := (now() at time zone 'America/Bogota')::date;
  d          record;
  v_url      text;
  v_fecha    text;
  v_hechos   text := '';
  n_hechos   int := 0;
begin
  if ncedula = '' then raise exception 'Datos incompletos.'; end if;
  select * into c from colaboradores
   where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then raise exception 'Cedula no encontrada.'; end if;
  if not c.activo then raise exception 'La persona no esta activa.'; end if;

  -- Uno por uno. El que no venga se queda como estaba: esta pantalla
  -- sirve para actualizar lo que se quiera, no para reemplazar todo.
  for d in select * from (values
      ('SOAT',          'DOC_SOAT'),
      ('TECNOMECANICA', 'DOC_TECNOMECANICA'),
      ('LICENCIA',      'DOC_LICENCIA_TRANSITO')
    ) as t(k, preg_id) loop

    select e->>'url' into v_url
      from jsonb_array_elements(evidencias) e
     where e->>'id_pregunta' = d.preg_id limit 1;

    if coalesce(btrim(coalesce(v_url,'')), '') = '' then continue; end if;

    v_fecha := substring(btrim(coalesce(fechas->>d.k, '')) from '\d{4}-\d{2}-\d{2}');
    if v_fecha is null then
      raise exception 'Adjuntaste % pero falta su fecha de vencimiento.', d.k;
    end if;
    perform revisar_vencimiento(d.k, v_fecha::date, hoy);

    -- Adjuntar un documento levanta su rechazo: ya hay algo nuevo que
    -- revisar, y dejarlo rechazado seguiria bloqueandolo sin razon.
    if d.k = 'SOAT' then
      update colaboradores
         set soat_url = v_url, soat_vence = v_fecha::date,
             soat_rechazado_en = null, soat_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    elsif d.k = 'TECNOMECANICA' then
      update colaboradores
         set tecnomecanica_url = v_url, tecnomecanica_vence = v_fecha::date,
             tecnomecanica_rechazado_en = null, tecnomecanica_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    else
      update colaboradores
         set licencia_url = v_url, licencia_vence = v_fecha::date,
             licencia_rechazado_en = null, licencia_rechazo_motivo = null,
             actualizado_en = now()
       where regexp_replace(cedula,'\D','','g') = ncedula;
    end if;

    v_hechos := v_hechos || d.k || ' (vence ' || v_fecha || '), ';
    n_hechos := n_hechos + 1;
  end loop;

  if n_hechos = 0 then
    raise exception 'No adjuntaste ningun documento.';
  end if;

  insert into historial (tipo, cedula, detalle)
  values ('DOCUMENTOS', ncedula,
    'Actualizados por el mensajero: ' || btrim(v_hechos, ', '));

  -- Se devuelve el estado nuevo para que la pantalla se repinte sola
  -- sin tener que volver a preguntar.
  return jsonb_build_object(
    'actualizados', n_hechos,
    'detalle', btrim(v_hechos, ', '),
    'documentosEstado', estado_documentos(ncedula));
end;
$fn$;

-- ------------------------------------------------------------
--  El router: va entre las abiertas
--  ------------------------------------------------------------
--  El mensajero no inicia sesion, igual que para guardar registro.
--  La cedula es la llave y la funcion valida que este activa.
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'hseq_api';
  if src is null then raise exception 'No existe hseq_api'; end if;
  if position('actualizarDocumentos' in src) > 0 then
    raise notice 'El router ya la conoce.';
    return;
  end if;

  nuevo := regexp_replace(src,
    '(when ''guardarRegistro''[[:space:]]+then result := api_guardar_registro\(payload\);)',
    '\1' || nl
      || '    -- Documentos sueltos: no es un registro del dia.' || nl
      || '    when ''actualizarDocumentos'' then result := api_actualizar_documentos(payload);');

  if nuevo = src then raise exception 'No encontre donde enganchar el router'; end if;

  execute 'create or replace function hseq_api(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) La funcion existe, con una sola firma.
select p.oid::regprocedure as firma
  from pg_proc p where p.proname = 'api_actualizar_documentos';

-- b) El router la conoce y sigue siendo abierta (no esta en la lista
--    de acciones que exigen sesion de coordinador).
select case when prosrc like '%actualizarDocumentos%' then 'ARREGLADO'
            else 'SIN ARREGLAR' end as router,
       case when prosrc ~ 'in \(''getCumplimientoDia''[^)]*actualizarDocumentos'
            then 'MAL: quedo protegida' else 'OK: abierta' end as permiso
  from pg_proc where proname = 'hseq_api';
