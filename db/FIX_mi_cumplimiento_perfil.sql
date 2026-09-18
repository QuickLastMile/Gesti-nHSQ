-- ============================================================
--  "Mi cumplimiento" volvio a quedar en la version vieja
--  ------------------------------------------------------------
--  QUE PASO
--  --------
--  db/temperatura_y_filtros.sql cambio formularios_exigibles_dia
--  de dos argumentos a tres (le agrego el perfil, porque la de dos
--  no sabia de cargos y le contaba temperatura a quien no la hace)
--  y borro la de dos. Pero despues se volvio a correr una copia
--  vieja de api_mi_cumplimiento, que sigue llamandola con dos.
--
--  Resultado: la pantalla "Mi cumplimiento" del mensajero responde
--
--     function formularios_exigibles_dia(text, date) does not exist
--
--  ...siempre, para todos. No impide registrar, pero la pantalla
--  no sirve.
--
--  EL ARREGLO
--  ----------
--  Se le devuelve el perfil a la funcion viva: se declara, se
--  calcula con perfil_cargo, se pasa en las dos llamadas, y el
--  conteo de formularios del proyecto tambien respeta aplica_a.
--  Va como parche sobre lo que este vivo, no como copia completa:
--  pegar una copia es justo lo que causo este problema.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

do $do$
declare
  src text;
  nl  text := chr(13) || chr(10);
  a   text;
begin
  select prosrc into src from pg_proc where proname = 'api_mi_cumplimiento';
  if src is null then raise exception 'No existe api_mi_cumplimiento'; end if;
  if position('v_perfil' in src) > 0 then
    raise notice 'Ya estaba arreglada: no se toca.';
    return;
  end if;

  -- a) La variable
  a := '  ultimo date;';
  if position(a in src) = 0 then raise exception 'No encontre las declaraciones'; end if;
  src := replace(src, a, a || nl
    || '  -- El cargo manda: a un mensajero no se le exige temperatura.' || nl
    || '  v_perfil text;');

  -- b) Se calcula junto con el proyecto
  a := '  proy := coalesce(c.proyecto_efectivo, c.proyecto, '''');';
  if position(a in src) = 0 then raise exception 'No encontre el calculo del proyecto'; end if;
  src := replace(src, a, a || nl || '  v_perfil := perfil_cargo(c.cargo);');

  -- c) El conteo de formularios del proyecto respeta el cargo
  a := '   where pf.proyecto = proy and pf.activo;';
  if position(a in src) = 0 then raise exception 'No encontre el conteo de formularios'; end if;
  src := replace(src, a,
       '   where pf.proyecto = proy and pf.activo' || nl
    || '     and (f.aplica_a is null or f.aplica_a = v_perfil);');

  -- d) Las dos llamadas, con el perfil
  a := 'formularios_exigibles_dia(proy, g::date)';
  if position(a in src) = 0 then raise exception 'No encontre la llamada de los esperados'; end if;
  src := replace(src, a, 'formularios_exigibles_dia(proy, g::date, v_perfil)');

  a := 'formularios_exigibles_dia(proy, d)';
  if position(a in src) = 0 then raise exception 'No encontre la llamada de la racha'; end if;
  src := replace(src, a, 'formularios_exigibles_dia(proy, d, v_perfil)');

  execute 'create or replace function api_mi_cumplimiento(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(src);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Ya usa el perfil.
select case when prosrc like '%v_perfil%' then 'ARREGLADA'
            else 'SIN ARREGLAR' end as estado
  from pg_proc where proname = 'api_mi_cumplimiento';

-- b) Que responda de verdad, para un mensajero de cada linea.
select c.linea, c.nombre,
       api_mi_cumplimiento(jsonb_build_object('cedula', c.cedula))->>'porcentaje' as cumplimiento,
       api_mi_cumplimiento(jsonb_build_object('cedula', c.cedula))->>'esperados'  as esperados
  from colaboradores c
 where c.activo
   and c.cedula in (select min(c2.cedula) from colaboradores c2 where c2.activo group by c2.linea)
 order by c.linea;
