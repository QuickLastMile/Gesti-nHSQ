-- ============================================================
--  Rangos de medicion  (1 de 2: la base y las reglas)
--  ------------------------------------------------------------
--  QUE PASO
--  --------
--  Luisa (HSEQ Smith) reporto que 17 generaba alerta y 181 no.
--  Revisado: el numero NUNCA se miro. Temperatura y Humedad son
--  campos numericos libres sin ninguna condicion. Lo unico que
--  generaba alerta era que la persona respondiera SI en THA_004
--  ("¿el registro anterior tambien se salio?"). Por eso 17 alerto
--  en un registro (respondieron SI) y 17 no alerto en otro
--  (respondieron NO), y 181 paso derecho.
--
--  Es decir: la desviacion no la evaluaba el sistema, la evaluaba
--  el mensajero de memoria.
--
--  QUE HACE ESTE SCRIPT
--  --------------------
--  1. Cada pregunta numerica puede tener dos rangos:
--       - normal  (min_normal/max_normal): fuera de ahi es una
--         desviacion y marca el registro.
--       - posible (min_valido/max_valido): fuera de ahi es un
--         error de digitacion y NO se guarda.
--  2. Se siembran los parametros que ya estaban escritos en el
--     propio formulario: temperatura max 25 °C, humedad max 65 %.
--  3. La desviacion de 24 horas la calcula el sistema comparando
--     con la lectura anterior (AM y PM son el mismo grupo), en vez
--     de preguntarsela al mensajero.
--  4. La temperatura deja de precargarse con la lectura anterior.
--     Una medicion precargada se guarda igual sin medir nada.
--
--  Todo va en triggers sobre respuestas, no reescribiendo
--  api_guardar_registro: esa funcion son 300 lineas y ya se ha
--  revertido sola una vez por pegarle copias viejas.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Los rangos viven en la pregunta
--  ------------------------------------------------------------
--  Null = sin limite por ese lado. La temperatura no tiene minimo
--  normal: que el furgon venga frio no es una desviacion.
-- ------------------------------------------------------------
alter table preguntas
  add column if not exists min_normal numeric,
  add column if not exists max_normal numeric,
  add column if not exists min_valido numeric,
  add column if not exists max_valido numeric;

comment on column preguntas.max_normal is
  'Fuera de este rango es desviacion: marca el registro con alerta.';
comment on column preguntas.max_valido is
  'Fuera de este rango es error de digitacion: no deja guardar.';

-- ------------------------------------------------------------
--  2) Los parametros que ya estaban escritos en el formulario
-- ------------------------------------------------------------
update preguntas
   set max_normal = 25,      -- "Temperatura: maximo 25 °C"
       min_valido = -20,     -- por debajo no es una bodega, es un error
       max_valido = 60,
       no_precargar = true   -- una medicion jamas se precarga
 where id in ('THA_002', 'THP_002');

update preguntas
   set max_normal = 65,      -- "Humedad relativa: maximo 65 %"
       min_valido = 0,
       max_valido = 100,     -- no existe humedad relativa de 181
       no_precargar = true
 where id in ('THA_003', 'THP_003');

-- ------------------------------------------------------------
--  3) Una lectura esta fuera de rango?
--  ------------------------------------------------------------
--  Se usa en tres sitios, asi que vive en un solo lado. El valor
--  llega como texto: si no es un numero, no se opina.
-- ------------------------------------------------------------
create or replace function valor_fuera_de_rango(p_pregunta_id text, p_valor text)
returns boolean language plpgsql stable set search_path = public as $fn$
declare
  v_num numeric;
  v_min numeric;
  v_max numeric;
begin
  select pg.min_normal, pg.max_normal into v_min, v_max
    from preguntas pg where pg.id = p_pregunta_id;
  if v_min is null and v_max is null then return false; end if;

  begin
    v_num := btrim(coalesce(p_valor, ''))::numeric;
  exception when others then
    return false;
  end;

  return (v_min is not null and v_num < v_min)
      or (v_max is not null and v_num > v_max);
end;
$fn$;

-- ------------------------------------------------------------
--  4) El registro anterior se habia salido?
--  ------------------------------------------------------------
--  "24 horas continuas" en la practica son dos lecturas seguidas.
--  AM y PM son formularios distintos pero del mismo grupo, asi que
--  la lectura anterior puede ser la PM de ayer.
-- ------------------------------------------------------------
create or replace function lectura_anterior_fuera(p_cedula text, p_grupo text, p_antes_de uuid default null)
returns boolean language plpgsql stable set search_path = public as $fn$
declare
  v_ced  text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_prev uuid;
begin
  if coalesce(btrim(coalesce(p_grupo, '')), '') = '' then return false; end if;

  select rg.id into v_prev
    from registros rg
    join formularios fm on fm.id = rg.formulario_id
   where regexp_replace(rg.cedula, '\D', '', 'g') = v_ced
     and fm.grupo = p_grupo
     and coalesce(rg.estado, '') <> 'ANULADO'
     and (p_antes_de is null or rg.id <> p_antes_de)
   order by rg.fecha desc, rg.hora desc
   limit 1;

  if v_prev is null then return false; end if;

  return exists (
    select 1 from respuestas rp
     where rp.registro_id = v_prev
       and valor_fuera_de_rango(rp.pregunta_id, rp.valor));
end;
$fn$;

-- ------------------------------------------------------------
--  5) Valor imposible: no se guarda
--  ------------------------------------------------------------
--  Va BEFORE INSERT, igual que la validacion del VIN. Un 181 de
--  temperatura no es una desviacion que haya que gestionar, es un
--  dedo que se resbalo: reportarlo como desviacion ensucia el
--  indicador y manda a alguien a revisar un furgon que esta bien.
-- ------------------------------------------------------------
create or replace function respuesta_valida_rango()
returns trigger language plpgsql set search_path = public as $fn$
declare
  v_num   numeric;
  v_min   numeric;
  v_max   numeric;
  v_nom   text;
begin
  select pg.min_valido, pg.max_valido, pg.pregunta
    into v_min, v_max, v_nom
    from preguntas pg where pg.id = new.pregunta_id;

  if v_min is null and v_max is null then return new; end if;
  if coalesce(btrim(coalesce(new.valor, '')), '') = '' then return new; end if;

  begin
    v_num := btrim(new.valor)::numeric;
  exception when others then
    raise exception '% debe ser un numero. Escribiste "%".', v_nom, new.valor;
  end;

  if (v_min is not null and v_num < v_min)
     or (v_max is not null and v_num > v_max) then
    raise exception '% fuera de lo posible: escribiste %. Revisa el dato, debe estar entre % y %.',
      v_nom, new.valor, coalesce(v_min::text, 'sin minimo'), coalesce(v_max::text, 'sin maximo');
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_respuesta_rango on respuestas;
create trigger trg_respuesta_rango
  before insert on respuestas
  for each row execute function respuesta_valida_rango();

-- ------------------------------------------------------------
--  6) Fuera del rango normal: queda marcado
--  ------------------------------------------------------------
--  Trigger aparte del de respuesta_alerta para no tocar el que ya
--  funciona. Si ademas la lectura anterior se habia salido, son 24
--  horas continuas y se dice con todas las letras.
-- ------------------------------------------------------------
create or replace function respuesta_marca_desviacion()
returns trigger language plpgsql set search_path = public as $fn$
declare
  v_nom     text;
  v_min     numeric;
  v_max     numeric;
  v_ced     text;
  v_grupo   text;
  v_detalle text;
  v_sostenida boolean;
begin
  if not valor_fuera_de_rango(new.pregunta_id, new.valor) then
    return null;
  end if;

  select pg.pregunta, pg.min_normal, pg.max_normal
    into v_nom, v_min, v_max
    from preguntas pg where pg.id = new.pregunta_id;

  select regexp_replace(rg.cedula, '\D', '', 'g'), fm.grupo
    into v_ced, v_grupo
    from registros rg
    join formularios fm on fm.id = rg.formulario_id
   where rg.id = new.registro_id;
  if v_ced is null then return null; end if;

  v_sostenida := lectura_anterior_fuera(v_ced, v_grupo, new.registro_id);

  v_detalle := replace(btrim(coalesce(v_nom, new.pregunta_id)), '|', '/')
    || ' fuera de rango: ' || btrim(coalesce(new.valor, ''))
    || ' (permitido '
    || case when v_min is not null and v_max is not null
              then v_min::text || ' a ' || v_max::text
            when v_max is not null then 'maximo ' || v_max::text
            else 'minimo ' || v_min::text end
    || ')'
    || case when v_sostenida
              then '. DESVIACION SOSTENIDA: la lectura anterior tambien se salio'
            else '' end;

  update registros
     set alertas = case
           when position(v_detalle in coalesce(alertas, '')) > 0 then alertas
           else concat_ws(' | ', nullif(btrim(coalesce(alertas, '')), ''), v_detalle)
         end,
         estado = case when coalesce(estado, '') = 'ANULADO' then estado else 'CON_ALERTA' end
   where id = new.registro_id
     and coalesce(estado, '') <> 'ANULADO';

  return null;
end;
$fn$;

drop trigger if exists trg_respuesta_desviacion on respuestas;
create trigger trg_respuesta_desviacion
  after insert on respuestas
  for each row execute function respuesta_marca_desviacion();

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Los rangos quedaron sembrados.
select id, formulario_id, pregunta, min_normal, max_normal,
       min_valido, max_valido, no_precargar
  from preguntas
 where formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM') and tipo_respuesta = 'numero'
 order by id;

-- b) La regla, probada contra los valores de la pantalla de Luisa.
select v as valor,
       valor_fuera_de_rango('THA_002', v) as temperatura_fuera
  from unnest(array['181','17','21','16','24','26','no es numero']) v;

-- c) Cuantos registros historicos tienen lecturas fuera de rango
--    que hoy nadie marco.
select r.formulario_id,
       count(distinct r.id) as registros_con_lectura_fuera
  from registros r
  join respuestas rp on rp.registro_id = r.id
 where r.formulario_id in ('TEMP_HUM_AM','TEMP_HUM_PM')
   and coalesce(r.estado,'') <> 'ANULADO'
   and valor_fuera_de_rango(rp.pregunta_id, rp.valor)
 group by r.formulario_id
 order by r.formulario_id;
