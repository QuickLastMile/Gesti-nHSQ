-- ============================================================
--  HOTFIX — "UPDATE requires a WHERE clause"
--  ------------------------------------------------------------
--  Supabase bloquea cualquier UPDATE sin condición, como red de
--  seguridad. La función que recalcula los encargados tocaba toda
--  la tabla a propósito y quedó atrapada en esa regla.
--
--  Se le agrega una condición que siempre se cumple: el efecto es
--  el mismo (recorre toda la matriz) y ya no la bloquea.
--
--  Supabase → SQL Editor → New query → pegar todo → Run
--  Después, vuelve a darle Guardar en la pestaña Encargados.
-- ============================================================

create or replace function recalcular_encargados()
returns int language plpgsql set search_path = public as $fn$
declare n int;
begin
  -- El trigger before update hace el cálculo; basta con tocar cada fila.
  update colaboradores set actualizado_en = actualizado_en
   where cedula is not null;
  get diagnostics n = row_count;
  return n;
end;
$fn$;

revoke all on function recalcular_encargados() from public, anon;

-- Deja la matriz al día de una vez. Devuelve cuántas personas recalculó.
select recalcular_encargados() as colaboradores_actualizados;
