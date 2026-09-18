-- ============================================================
--  La coma decimal: 20,5 es lo mismo que 20.5
--  ------------------------------------------------------------
--  QUE PASABA
--  ----------
--  Los campos numericos eran <input type="number">. Cuando el
--  mensajero escribe "20,5" (que es como se escribe un decimal en
--  Colombia), el navegador NO lo convierte: descarta el valor
--  entero y el campo queda vacio, sin avisar.
--
--  Comprobado tecleando de verdad en Chrome es-419: escribe 20,5 y
--  el campo lee "". Resultado: la lectura se perdia, el aviso de
--  rango no salia, y al guardar le decia "falta la pregunta
--  obligatoria Temperatura" sin que entendiera por que.
--
--  QUE HACE ESTE SCRIPT
--  --------------------
--  La pantalla ya normaliza antes de enviar, pero la base tiene que
--  aguantar lo mismo: hay registros en cola sin conexion y celulares
--  con la version vieja en cache que van a seguir mandando comas
--  durante un tiempo. Aqui se limpia al entrar y se guarda con
--  punto, igual que el VIN se guarda en mayusculas.
--
--  Requiere db/temperatura_rangos_1.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Un solo sitio que entiende como escribe la gente
--  ------------------------------------------------------------
--  Devuelve null si no es un numero, para que quien llame decida
--  que hacer. Si vienen los dos separadores, el ultimo es el
--  decimal: "1.234,5" son mil doscientos treinta y cuatro con
--  cinco, y "1,234.5" lo mismo al reves.
-- ------------------------------------------------------------
create or replace function numero_limpio(p_texto text)
returns numeric language plpgsql immutable set search_path = public as $fn$
declare
  t text := regexp_replace(coalesce(p_texto, ''), '[[:space:]]', '', 'g');
  ultima_coma int;
  ultimo_punto int;
begin
  if t = '' then return null; end if;

  ultima_coma  := length(t) - position(',' in reverse(t)) + 1;
  ultimo_punto := length(t) - position('.' in reverse(t)) + 1;

  if position(',' in t) > 0 and position('.' in t) > 0 then
    if ultima_coma > ultimo_punto then
      t := replace(replace(t, '.', ''), ',', '.');   -- 1.234,5
    else
      t := replace(t, ',', '');                      -- 1,234.5
    end if;
  elsif position(',' in t) > 0 then
    t := replace(t, ',', '.');                       -- 20,5
  end if;

  begin
    return t::numeric;
  exception when others then
    return null;
  end;
end;
$fn$;

-- ------------------------------------------------------------
--  2) Fuera de rango, entendiendo la coma
-- ------------------------------------------------------------
create or replace function valor_fuera_de_rango(p_pregunta_id text, p_valor text)
returns boolean language plpgsql stable set search_path = public as $fn$
declare
  v_num numeric; v_min numeric; v_max numeric;
begin
  select pg.min_normal, pg.max_normal into v_min, v_max
    from preguntas pg where pg.id = p_pregunta_id;
  if v_min is null and v_max is null then return false; end if;

  v_num := numero_limpio(p_valor);
  if v_num is null then return false; end if;

  return (v_min is not null and v_num < v_min)
      or (v_max is not null and v_num > v_max);
end;
$fn$;

-- ------------------------------------------------------------
--  3) Al guardar se normaliza y se valida
--  ------------------------------------------------------------
--  Se guarda con punto siempre: si no, el mismo valor quedaria
--  escrito de dos maneras segun quien lo digito, y cualquier
--  cuenta o exportable tendria que adivinar.
-- ------------------------------------------------------------
create or replace function respuesta_valida_rango()
returns trigger language plpgsql set search_path = public as $fn$
declare
  v_num   numeric;
  v_min   numeric;
  v_max   numeric;
  v_nom   text;
  v_tipo  text;
begin
  select pg.min_valido, pg.max_valido, pg.pregunta, pg.tipo_respuesta
    into v_min, v_max, v_nom, v_tipo
    from preguntas pg where pg.id = new.pregunta_id;

  if coalesce(v_tipo, '') <> 'numero' then return new; end if;
  if coalesce(btrim(coalesce(new.valor, '')), '') = '' then return new; end if;

  v_num := numero_limpio(new.valor);
  if v_num is null then
    raise exception '% debe ser un numero. Escribiste "%".', v_nom, new.valor;
  end if;

  -- Queda guardado en el formato de siempre, venga como venga.
  -- Los ceros de sobra solo se quitan si hay decimales: sin ese
  -- resguardo, 20 se convertiria en 2.
  new.valor := v_num::text;
  if position('.' in new.valor) > 0 then
    new.valor := trim(trailing '.' from trim(trailing '0' from new.valor));
  end if;

  if (v_min is not null and v_num < v_min)
     or (v_max is not null and v_num > v_max) then
    raise exception '% fuera de lo posible: escribiste %. Revisa el dato, debe estar entre % y %.',
      v_nom, new.valor, coalesce(v_min::text, 'sin minimo'), coalesce(v_max::text, 'sin maximo');
  end if;

  return new;
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Como se interpreta cada forma de escribir.
select v as escrito, numero_limpio(v) as entendido
  from unnest(array['20,5','20.5','20','1.234,5','1,234.5','  17 ,5 ','abc','','25,0']) v;

-- b) La regla de rango ya no se deja enganar por la coma.
select v as escrito,
       valor_fuera_de_rango('THA_002', v) as temperatura_fuera
  from unnest(array['20,5','25,1','24,9','26','181']) v;

-- c) Cuantas respuestas numericas historicas quedaron con coma.
select p.formulario_id, p.pregunta, count(*) as con_coma
  from respuestas r
  join preguntas p on p.id = r.pregunta_id
 where p.tipo_respuesta = 'numero' and r.valor like '%,%'
 group by p.formulario_id, p.pregunta
 order by con_coma desc;
