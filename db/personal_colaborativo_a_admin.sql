-- ============================================================
--  Personal colaborativo: se muda de Coordinador a Configuración
--  ------------------------------------------------------------
--  db/personal_colaborativo.sql la puso en coordinador.html, colgada
--  del router hseq_api (igual que Detalle de reportes). Se pidio
--  moverla a admin.html, junto a la Matriz real -"cambiar la nomina
--  es tarea de HSQ", como ya dice el comentario de esa pagina-. Eso
--  significa cambiar de router: admin.html llama a hseq_admin, no a
--  hseq_api, y exige rol ADMIN/HSEQ (mas estricto que hseq_api, que
--  tambien dejaba entrar a COORDINADOR).
--
--  Las cuatro funciones (api_colaborativos_lista/guardar/estado/
--  eliminar) NO cambiaron: solo se les quito el enganche de un
--  router y se les puso el del otro.
--
--  De paso, en el frontend el cargue masivo paso de "pegar texto
--  copiado de Excel" a subir un archivo real (.xlsx/.xls/.csv) desde
--  el computador -se pidio explicitamente-. Se lee con la misma
--  libreria SheetJS que ya usaba el dashboard para exportar
--  (assets/vendor/xlsx.full.min.js), y se convierte al mismo formato
--  de texto (titulos + filas con tab) que ya entendia
--  api_colaborativos_guardar: la funcion no tuvo que cambiar.
--
--  Este script YA SE APLICO en produccion (2026-09-24).
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Quitar las 4 acciones de hseq_api
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  bloque_lista text := $tag$'colaborativosLista','colaborativosGuardar','colaborativosEstado','colaborativosEliminar',$tag$;
  bloque_case text := $tag$
    when 'colaborativosLista'    then result := api_colaborativos_lista(payload);
    when 'colaborativosGuardar'  then result := api_colaborativos_guardar(payload);
    when 'colaborativosEstado'   then result := api_colaborativos_estado(payload);
    when 'colaborativosEliminar' then result := api_colaborativos_eliminar(payload);$tag$;
  bloque_case_crlf text;
begin
  select prosrc into src from pg_proc where proname = 'hseq_api';
  if position('colaborativosLista' in src) = 0 then
    raise notice 'hseq_api ya no tenia estas acciones: no se toca.'; return;
  end if;

  nuevo := replace(src, bloque_lista, '');
  if nuevo = src then raise exception 'No encontre el bloque de acciones en la lista protegida'; end if;

  bloque_case_crlf := replace(bloque_case, chr(10), chr(13)||chr(10));
  if position(bloque_case_crlf in nuevo) > 0 then
    nuevo := replace(nuevo, bloque_case_crlf, '');
  elsif position(bloque_case in nuevo) > 0 then
    nuevo := replace(nuevo, bloque_case, '');
  else
    raise exception 'No encontre el bloque de case a quitar';
  end if;

  execute 'create or replace function hseq_api(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'hseq_api: quitadas las 4 acciones de colaborativos.';
end
$do$;

-- ------------------------------------------------------------
--  2) Agregarlas a hseq_admin
-- ------------------------------------------------------------
do $do$
declare
  src text;
  nuevo text;
  anchor_case text := $tag$when 'getMatrizInfo'             then result := api_matriz_info();$tag$;
begin
  select prosrc into src from pg_proc where proname = 'hseq_admin';
  if src is null then raise exception 'No existe hseq_admin'; end if;
  if position('colaborativosLista' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.'; return;
  end if;

  if position(anchor_case in src) = 0 then raise exception 'No encontre el case de getMatrizInfo'; end if;
  nuevo := replace(src, anchor_case,
    anchor_case || chr(13) || chr(10)
    || $tag$    when 'colaborativosLista'    then result := api_colaborativos_lista(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosGuardar'  then result := api_colaborativos_guardar(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosEstado'   then result := api_colaborativos_estado(payload);$tag$ || chr(13) || chr(10)
    || $tag$    when 'colaborativosEliminar' then result := api_colaborativos_eliminar(payload);$tag$);

  if nuevo = src then raise exception 'El parche no cambio nada'; end if;

  execute 'create or replace function hseq_admin(action text, payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
  raise notice 'hseq_admin: agregadas las 4 acciones de colaborativos.';
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
select prosrc like '%colaborativosLista%' as ya_no_en_api from pg_proc where proname = 'hseq_api';
  -- deberia dar false
select prosrc like '%colaborativosLista%' as ya_en_admin from pg_proc where proname = 'hseq_admin';
  -- deberia dar true
