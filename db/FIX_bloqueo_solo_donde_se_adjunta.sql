-- ============================================================
--  El bloqueo, solo donde el documento se puede adjuntar
--  ------------------------------------------------------------
--  QUE PASO (18/09/2026, en caliente)
--  ---------------------------------
--  El bloqueo por documento pendiente se aplicaba en TODO
--  formulario con exige_documentos = true, y eso incluye
--  LIMPIEZA_MOTO. Pero la pantalla solo inyecta las preguntas de
--  documentos en el PREOPERACIONAL. Resultado: al mensajero con un
--  documento vencido, rechazado o sin cargar, la Limpieza le
--  respondia
--
--     "No puedes registrar hasta actualizar: SOAT (sin cargar).
--      Adjuntalo en este mismo formulario."
--
--  ...en una pantalla donde no hay donde adjuntarlo. Callejon sin
--  salida: ni guardaba ni podia arreglarlo. Estaba afectando a 74
--  personas activas.
--
--  EL ARREGLO
--  ----------
--  Un formulario ahora declara si RECIBE documentos, aparte de si
--  los EXIGE. Solo el que los recibe bloquea; en los demas el
--  pendiente queda como alerta del registro, que es donde el
--  coordinador lo ve. El documento se le sigue exigiendo igual en
--  el preoperacional, que es donde si lo puede subir.
--
--  POR QUE VA COMO PARCHE Y NO COMO FUNCION COMPLETA
--  -------------------------------------------------
--  api_guardar_registro son 300 lineas que han cambiado varias
--  veces; pegar aqui una copia significa arriesgarse a devolver
--  produccion a una version vieja sin darse cuenta. Este script
--  edita el cuerpo que este vivo, sea cual sea, y aborta si no
--  encuentra exactamente lo que espera. Se puede correr dos veces:
--  la segunda avisa y no hace nada.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Que formulario puede recibir los documentos
--  ------------------------------------------------------------
--  Va como columna y no fijo en el codigo para que el dia que otro
--  formulario pida documentos sea marcar una casilla, no llamarme.
-- ------------------------------------------------------------
alter table formularios
  add column if not exists recibe_documentos boolean not null default false;

-- Hoy es solo el preoperacional: es el unico donde la pantalla
-- inyecta SOAT, tecnomecanica y licencia.
update formularios set recibe_documentos = (id = 'PREOPERACIONAL');

-- ------------------------------------------------------------
--  2) Guardar registro: bloquea solo si el formulario los recibe
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nl  text := chr(13) || chr(10);
  a   text;
begin
  select prosrc into src from pg_proc where proname = 'api_guardar_registro';
  if src is null then raise exception 'No existe api_guardar_registro'; end if;
  if position('recibe_docs' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  -- a) La variable nueva
  a := '  exige_docs boolean := true;';
  if position(a in src) = 0 then raise exception 'No encontre la declaracion de exige_docs'; end if;
  src := replace(src, a, a || nl
    || '  -- Si ESTE formulario puede recibir los documentos. Bloquear en uno' || nl
    || '  -- que no los pide deja al mensajero sin salida: le exige adjuntar' || nl
    || '  -- algo en una pantalla que no tiene donde adjuntarlo.' || nl
    || '  recibe_docs boolean := false;');

  -- b) Se lee junto con exige_documentos, en la misma consulta
  a := '  select coalesce(exige_documentos, true) into exige_docs';
  if position(a in src) = 0 then raise exception 'No encontre la lectura de exige_documentos'; end if;
  src := replace(src, a,
       '  select coalesce(exige_documentos, true), coalesce(recibe_documentos, false)' || nl
    || '    into exige_docs, recibe_docs');

  -- c) El bloqueo se condiciona
  a := '    if faltan <> '''' then';
  if position(a in src) = 0 then raise exception 'No encontre el if del bloqueo'; end if;
  src := replace(src, a,
       '    -- Solo se bloquea donde el documento se puede adjuntar. En los' || nl
    || '    -- demas formularios el pendiente queda como alerta del registro:' || nl
    || '    -- negarle la limpieza a alguien que no tiene donde subir el SOAT' || nl
    || '    -- no consigue el documento, solo le tumba el dia de trabajo.' || nl
    || '    if faltan <> '''' and recibe_docs then');

  -- d) ...y donde no bloquea, queda dicho en la alerta del registro
  a := '        btrim(faltan, '', '');';
  if position(a in src) = 0 then raise exception 'No encontre el btrim del mensaje'; end if;
  src := replace(src, a, a || nl
    || '    elsif faltan <> '''' then' || nl
    || '      alertas_doc := alertas_doc || ''Pendiente por actualizar: ''' || nl
    || '        || btrim(faltan, '', '') || '' | '';');

  execute 'create or replace function api_guardar_registro(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(src);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Quien exige y quien recibe. Solo PREOPERACIONAL debe recibir.
select id, activo, exige_documentos, recibe_documentos
  from formularios order by id;

-- b) La funcion ya distingue los dos casos.
select case when prosrc like '%recibe_docs%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_guardar_registro';

-- c) Cuanta gente se destraba: tiene un documento que bloquea, la
--    limpieza habilitada, y no ha podido hacerla hoy.
with e as (
  select c.cedula, c.linea, coalesce(c.proyecto_efectivo, c.proyecto, '') as proyecto,
         (estado_documentos(c.cedula)->>'bloquea')::boolean as bloqueado
    from colaboradores c where c.activo
)
select e.linea, count(*) as se_destraban
  from e
 where e.bloqueado
   and exists (select 1 from proyectos_formularios pf
                where pf.proyecto = e.proyecto
                  and pf.formulario_id = 'LIMPIEZA_MOTO' and pf.activo)
   and not exists (select 1 from registros r
                    where regexp_replace(r.cedula, '\D', '', 'g')
                        = regexp_replace(e.cedula, '\D', '', 'g')
                      and r.formulario_id = 'LIMPIEZA_MOTO'
                      and r.fecha = (now() at time zone 'America/Bogota')::date)
 group by e.linea
 order by e.linea;
