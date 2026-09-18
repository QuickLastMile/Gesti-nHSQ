-- ============================================================
--  El VIN son 17 caracteres, tambien en la base
--  ------------------------------------------------------------
--  Venian VIN de 1, 5 o 6 digitos. Un VIN incompleto no
--  identifica ningun vehiculo: el dato queda sin servir y el
--  error se descubre meses despues, cuando ya no hay a quien
--  preguntarle.
--
--  La pantalla ya lo valida y ademas limpia espacios y guiones.
--  Esto es la segunda red: cubre un celular con la version vieja
--  guardada, y deja la regla escrita donde vive el dato.
--
--  Va como TRIGGER y no dentro de api_guardar_registro a
--  proposito: asi no hay que reemplazar esa funcion de 300
--  lineas cada vez que cambie una regla de un solo campo.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

create or replace function respuesta_valida_vin()
returns trigger language plpgsql set search_path = public as $fn$
declare
  limpio text;
begin
  if new.pregunta_id <> 'DOC_VIN' then
    return new;
  end if;

  -- Sin respuesta no se opina: si el VIN es obligatorio lo decide el
  -- formulario, no este trigger.
  if coalesce(btrim(coalesce(new.valor, '')), '') = '' then
    return new;
  end if;

  -- Se guarda siempre en mayusculas y sin separadores, venga como venga.
  limpio := upper(regexp_replace(new.valor, '[[:space:]-]', '', 'g'));

  if limpio !~ '^[A-Z0-9]{17}$' then
    raise exception 'El VIN son 17 caracteres entre letras y numeros. Llegaron % (%). Revisalo en la licencia de transito.',
      length(limpio), limpio;
  end if;

  new.valor := limpio;
  return new;
end;
$fn$;

drop trigger if exists trg_respuesta_vin on respuestas;
create trigger trg_respuesta_vin
  before insert or update of valor on respuestas
  for each row execute function respuesta_valida_vin();

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) El trigger quedo puesto.
select tgname, tgenabled
  from pg_trigger
 where tgrelid = 'respuestas'::regclass and not tgisinternal
 order by tgname;

-- b) Los VIN que ya estan guardados y NO cumplen. Son los que hay que
--    perseguir: el trigger solo cuida los nuevos, no arregla el pasado.
select count(*) as vin_guardados,
       count(*) filter (
         where upper(regexp_replace(coalesce(r.valor,''), '[[:space:]-]', '', 'g'))
               !~ '^[A-Z0-9]{17}$'
       ) as vin_malos
  from respuestas r
 where r.pregunta_id = 'DOC_VIN'
   and coalesce(btrim(coalesce(r.valor,'')), '') <> '';

-- c) Quienes son, para pedirles que lo corrijan. La columna
--    'datos_vehiculo_completos' del exportable de documentacion los
--    seguira mostrando como completos: tienen VIN, solo que malo.
select distinct regexp_replace(rg.cedula, '\D', '', 'g') as cedula,
       rg.nombre, rg.proyecto, r.valor as vin_guardado,
       length(upper(regexp_replace(coalesce(r.valor,''), '[[:space:]-]', '', 'g'))) as largo
  from respuestas r
  join registros rg on rg.id = r.registro_id
 where r.pregunta_id = 'DOC_VIN'
   and coalesce(btrim(coalesce(r.valor,'')), '') <> ''
   and upper(regexp_replace(coalesce(r.valor,''), '[[:space:]-]', '', 'g')) !~ '^[A-Z0-9]{17}$'
 order by largo, cedula;
