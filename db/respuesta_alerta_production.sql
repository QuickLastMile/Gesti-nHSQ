-- ============================================================
-- Alertas operativas según preguntas.respuesta_alerta
-- 1. Marca automáticamente los registros nuevos.
-- 2. Recupera las alertas de registros históricos.
-- Es idempotente: puede ejecutarse nuevamente sin duplicar textos.
-- ============================================================

create or replace function public.sincronizar_respuesta_alerta_registro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  detalle text;
  coincide boolean := false;
begin
  select pregunta, respuesta_alerta into p
  from public.preguntas
  where id = new.pregunta_id
    and nullif(btrim(coalesce(respuesta_alerta, '')), '') is not null
  limit 1;

  if not found then return new; end if;

  coincide := upper(btrim(coalesce(new.valor, ''))) = upper(btrim(p.respuesta_alerta))
    or exists (
      select 1
      from regexp_split_to_table(coalesce(new.valor, ''), '\s*,\s*') opcion
      where upper(btrim(opcion)) = upper(btrim(p.respuesta_alerta))
    );

  if not coincide then return new; end if;

  detalle := 'Respuesta de alerta: '
    || replace(btrim(coalesce(p.pregunta, new.pregunta_id)), '|', '/')
    || ' = ' || replace(btrim(p.respuesta_alerta), '|', '/');

  update public.registros
  set alertas = case
        when position(detalle in coalesce(alertas, '')) > 0 then alertas
        else concat_ws(' | ', nullif(btrim(coalesce(alertas, '')), ''), detalle)
      end,
      estado = case when coalesce(estado, '') = 'ANULADO' then estado else 'CON_ALERTA' end
  where id = new.registro_id
    and coalesce(estado, '') <> 'ANULADO';

  return new;
end;
$$;

drop trigger if exists trg_respuesta_alerta_registro on public.respuestas;
create trigger trg_respuesta_alerta_registro
after insert or update of valor on public.respuestas
for each row execute function public.sincronizar_respuesta_alerta_registro();

-- La función solo debe ejecutarse por el trigger, no directamente desde la API.
revoke execute on function public.sincronizar_respuesta_alerta_registro() from public, anon, authenticated;

-- Recupera novedades ya diligenciadas antes de crear el trigger.
do $$
declare
  x record;
begin
  for x in
    select rs.registro_id,
      'Respuesta de alerta: '
        || replace(btrim(coalesce(p.pregunta, rs.pregunta_id)), '|', '/')
        || ' = ' || replace(btrim(p.respuesta_alerta), '|', '/') as detalle
    from public.respuestas rs
    join public.preguntas p on p.id = rs.pregunta_id
    join public.registros r on r.id = rs.registro_id
    where nullif(btrim(coalesce(p.respuesta_alerta, '')), '') is not null
      and coalesce(r.estado, '') <> 'ANULADO'
      and (
        upper(btrim(coalesce(rs.valor, ''))) = upper(btrim(p.respuesta_alerta))
        or exists (
          select 1
          from regexp_split_to_table(coalesce(rs.valor, ''), '\s*,\s*') opcion
          where upper(btrim(opcion)) = upper(btrim(p.respuesta_alerta))
        )
      )
  loop
    update public.registros
    set alertas = case
          when position(x.detalle in coalesce(alertas, '')) > 0 then alertas
          else concat_ws(' | ', nullif(btrim(coalesce(alertas, '')), ''), x.detalle)
        end,
        estado = 'CON_ALERTA'
    where id = x.registro_id;
  end loop;
end;
$$;

select
  count(*) filter (where coalesce(alertas, '') like '%Respuesta de alerta:%') as registros_con_respuesta_alerta,
  count(*) filter (where coalesce(alertas, '') <> '') as registros_con_cualquier_alerta
from public.registros
where coalesce(estado, '') <> 'ANULADO';
