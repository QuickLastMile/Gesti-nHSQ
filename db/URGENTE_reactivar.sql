-- ============================================================
--  URGENTE — Reactivar colaboradores inactivados por la matriz
--  ------------------------------------------------------------
--  EJECUTA PRIMERO EL PASO 1 (solo consulta, no cambia nada) y
--  mira el resultado. Después ejecuta el PASO 2 para reparar.
--
--  Supabase → SQL Editor → New query
-- ============================================================


-- ============================================================
--  PASO 1 — QUÉ PASÓ  (solo lectura, seguro)
-- ============================================================

-- 1.1 Cómo está la base ahora mismo
select
  count(*) filter (where activo)            as activos,
  count(*) filter (where not activo)        as inactivos,
  count(*)                                  as total,
  count(*) filter (where not activo
    and observaciones_hsq ilike '%no aparece en la matriz cargada%') as inactivados_por_matriz,
  count(*) filter (where not activo
    and coalesce(btrim(observacion_coordinador),'') <> '')           as inactivados_por_coordinador
from colaboradores;

-- 1.2 Las últimas actualizaciones de matriz (aquí se ve cuántos inactivó)
select creado_en, detalle
  from historial
 where tipo = 'ACTUALIZACION_MATRIZ'
 order by creado_en desc
 limit 5;

-- 1.3 De qué fecha viene la inactivación masiva
select
  substring(observaciones_hsq from 'Inactivada el ([0-9]{4}-[0-9]{2}-[0-9]{2})') as fecha_inactivacion,
  count(*) as cuantos
from colaboradores
where not activo and observaciones_hsq ilike '%no aparece en la matriz cargada%'
group by 1
order by 1 desc nulls last;


-- ============================================================
--  PASO 2 — REPARAR
--  Reactiva SOLO a quienes inactivó la actualización de matriz.
--  NO toca a los que un coordinador inactivó a propósito
--  (restricción, incapacidad, renuncia), que deben seguir inactivos.
--
--  Cambia la fecha por la que te haya salido en la consulta 1.3.
-- ============================================================

-- update colaboradores
--    set activo = true,
--        observaciones_hsq = btrim(
--          regexp_replace(coalesce(observaciones_hsq,''),
--            '\s*\|\s*Inactivada el [0-9]{4}-[0-9]{2}-[0-9]{2}[^|]*no aparece en la matriz cargada\.?', '', 'g'),
--          ' |') || ' | Reactivada el ' ||
--          to_char((now() at time zone 'America/Bogota')::date,'YYYY-MM-DD') ||
--          ': la matriz cargada estaba incompleta.',
--        actualizado_en = now()
--  where not activo
--    and observaciones_hsq ilike '%no aparece en la matriz cargada%'
--    and observaciones_hsq like '%Inactivada el 2026-08-18%'   -- <<< AJUSTA LA FECHA
--    and coalesce(btrim(observacion_coordinador),'') = '';     -- respeta las bajas del coordinador

-- Comprobar cómo quedó:
-- select count(*) filter (where activo) as activos,
--        count(*) filter (where not activo) as inactivos
--   from colaboradores;


-- ============================================================
--  PASO 3 — QUE NO VUELVA A PASAR
--  La actualización de matriz se niega a inactivar media
--  operación por un pegado incompleto. Si el archivo trae menos
--  del 60% del personal activo, aborta y no cambia nada.
--
--  Este paso SÍ se ejecuta completo (no está comentado).
-- ============================================================
create or replace function matriz_cerrar_actualizacion(presentes text[])
returns int language plpgsql security definer set search_path = public as $fn$
declare
  hoy text := to_char((now() at time zone 'America/Bogota')::date, 'YYYY-MM-DD');
  activos_antes int;
  van_a_caer int;
  n int;
begin
  if coalesce(array_length(presentes, 1), 0) = 0 then
    raise exception 'La matriz cargada no trajo ninguna cedula valida. No se cambio nada.';
  end if;

  select count(*) into activos_antes from colaboradores where activo;

  select count(*) into van_a_caer
    from colaboradores
   where activo and not provisional
     and not (regexp_replace(cedula,'\D','','g') = any(presentes));

  -- Red de seguridad: nunca se inactiva a mas de la mitad de la operacion
  -- de un solo golpe. Casi siempre significa que el pegado quedo incompleto.
  if activos_antes > 20 and van_a_caer > (activos_antes * 0.5) then
    raise exception
      'La matriz cargada dejaria inactivos a % de % colaboradores activos. Parece incompleta: revisa que hayas pegado el archivo completo con su fila de titulos. No se cambio nada.',
      van_a_caer, activos_antes;
  end if;

  -- Quien ya venia en la nomina deja de ser provisional.
  update colaboradores set
    provisional = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Confirmado en la matriz del ' || hoy || '.', ' |'),
    actualizado_en = now()
  where provisional
    and regexp_replace(cedula,'\D','','g') = any(presentes);

  update colaboradores set activo = false,
    observaciones_hsq = btrim(coalesce(observaciones_hsq,'') ||
      ' | Inactivada el ' || hoy || ': no aparece en la matriz cargada.', ' |'),
    actualizado_en = now()
  where activo
    and not provisional
    and not (regexp_replace(cedula,'\D','','g') = any(presentes));
  get diagnostics n = row_count;
  return n;
end;
$fn$;
