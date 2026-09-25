-- ============================================================
--  Cargue colaborativo: las dos formas del cargo, y avisa lo que no entiende
--  ------------------------------------------------------------
--  QUE HABIA
--  ---------
--  La regla era, literalmente, "si no dice conductor es mensajero":
--
--      cargo_v := case when cargo_txt ~* 'conductor|vehiculo|veh[ií]culo'
--                       then 'QUICKER - CONDUCTOR' else 'QUICKER - MENSAJERO' end;
--
--  Funcionaba para 'Conductor' y tambien para 'QUICKER - CONDUCTOR'
--  (contiene la palabra), pero cualquier otra cosa -un cargo distinto,
--  una abreviatura, una celda con un numero- se volvia mensajero EN
--  SILENCIO. Asi entraron 133 personas de LTSA con el tipo cambiado y
--  no se supo hasta dias despues.
--
--  QUE QUEDA
--  ---------
--  Cada forma se reconoce explicitamente, sin tildes ni signos:
--
--    CONDUCTOR  <- Conductor, CONDUCTOR, Conductora, Vehiculo, Vehículo,
--                  QUICKER - CONDUCTOR, QUICKER CONDUCTOR, Quicker-Conductor
--    MENSAJERO  <- Mensajero, MENSAJERO, Moto, Motorizado,
--                  QUICKER - MENSAJERO, Quicker Mensajero
--    MENSAJERO  <- celda vacia (asi esta escrito en la ayuda de la pantalla)
--    MENSAJERO  <- cualquier otra cosa, PERO contada y con ejemplo
--
--  El "vacio" se mide sobre el texto original, no sobre el normalizado:
--  una columna codificada 1/2 se queda sin letras al normalizar y se
--  colaria como celda vacia sin reportarse.
--
--  El resultado del cargue devuelve ahora 'conductores', 'mensajeros',
--  'no_entendidas', 'ejemplos' (hasta 5, sin repetir) y
--  'hay_columna_cargo'. La pantalla los muestra y avisa en ambar.
--
--  Para corregir lo que ya entro mal: db/colaborativo_corregir_tipo.sql
--  (no hay que borrar ni volver a cargar).
--
--  Supabase -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

do $do$
declare src text; nuevo text; nl text := chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_colaborativos_guardar';
  if src is null then raise exception 'No existe api_colaborativos_guardar'; end if;
  if position('c_raros' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  nuevo := replace(src,
    '  c_cond int := 0; c_mens int := 0;',
    '  c_cond int := 0; c_mens int := 0; c_raros int := 0;' || nl
 || '  cargo_norm text; raros jsonb := ''[]''::jsonb;');

  nuevo := replace(nuevo,
    '    cargo_v := case when cargo_txt ~* ''conductor|vehiculo|veh[ií]culo''' || nl
 || '                     then ''QUICKER - CONDUCTOR'' else ''QUICKER - MENSAJERO'' end;' || nl
 || '    if cargo_v = ''QUICKER - CONDUCTOR'' then c_cond := c_cond + 1;' || nl
 || '    else c_mens := c_mens + 1; end if;',

    '    -- Se acepta tanto ''Conductor''/''Mensajero'' como ''QUICKER - CONDUCTOR''/' || nl
 || '    -- ''QUICKER - MENSAJERO''. Se quitan tildes y cualquier signo para que'  || nl
 || '    -- ''Quicker-Conductor'', ''QUICKER  CONDUCTOR'' y ''conductor'' sean lo mismo.' || nl
 || '    cargo_norm := regexp_replace(' || nl
 || '                    translate(upper(btrim(cargo_txt)), ''ÁÉÍÓÚÜÑ'', ''AEIOUUN''),' || nl
 || '                    ''[^A-Z]+'', '' '', ''g'');' || nl
 || '    if cargo_norm ~ ''CONDUCTOR|VEHICULO'' then' || nl
 || '      cargo_v := ''QUICKER - CONDUCTOR''; c_cond := c_cond + 1;' || nl
 || '    elsif cargo_norm ~ ''MENSAJERO|MOTO'' then' || nl
 || '      cargo_v := ''QUICKER - MENSAJERO''; c_mens := c_mens + 1;' || nl
 || '    elsif btrim(cargo_txt) = '''' then' || nl
 || '      -- Vacio es mensajero a proposito: asi esta escrito en la ayuda.' || nl
 || '      cargo_v := ''QUICKER - MENSAJERO''; c_mens := c_mens + 1;' || nl
 || '    else' || nl
 || '      -- No se entiende. Entra como mensajero para no frenar el cargue,' || nl
 || '      -- pero se reporta para que se pueda corregir en lote.' || nl
 || '      cargo_v := ''QUICKER - MENSAJERO''; c_mens := c_mens + 1; c_raros := c_raros + 1;' || nl
 || '      if jsonb_array_length(raros) < 5 and not (raros @> to_jsonb(btrim(cargo_txt))) then' || nl
 || '        raros := raros || to_jsonb(btrim(cargo_txt));' || nl
 || '      end if;' || nl
 || '    end if;');

  nuevo := replace(nuevo,
    '    ''hay_columna_cargo'', (idx ? ''Cargo''));',
    '    ''hay_columna_cargo'', (idx ? ''Cargo''),' || nl
 || '    ''no_entendidas'', c_raros, ''ejemplos'', raros);');

  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function api_colaborativos_guardar(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Quedo puesto.
select case when prosrc like '%c_raros%' then 'si' else 'NO' end as clasifica_explicito,
       case when prosrc like '%no_entendidas%' then 'si' else 'NO' end as reporta
  from pg_proc where proname = 'api_colaborativos_guardar';

-- b) La misma regla, contra todo lo que puede venir en la columna Cargo.
--    Ninguna fila deberia salir distinta a lo que dice la columna esperado.
with casos(v, esperado) as (values
  ('Conductor','CONDUCTOR'), ('CONDUCTOR','CONDUCTOR'), ('conductor','CONDUCTOR'),
  ('Conductora','CONDUCTOR'), ('Vehiculo','CONDUCTOR'), ('Vehículo','CONDUCTOR'),
  ('QUICKER - CONDUCTOR','CONDUCTOR'), ('QUICKER CONDUCTOR','CONDUCTOR'),
  ('Quicker-Conductor','CONDUCTOR'),
  ('Mensajero','MENSAJERO'), ('MENSAJERO','MENSAJERO'), ('Moto','MENSAJERO'),
  ('Motorizado','MENSAJERO'), ('QUICKER - MENSAJERO','MENSAJERO'),
  ('Quicker Mensajero','MENSAJERO'),
  ('','VACIA'), ('   ','VACIA'),
  ('Auxiliar','NO ENTENDIDA'), ('N/A','NO ENTENDIDA'), ('1','NO ENTENDIDA')
), calc as (
  select v, esperado,
         regexp_replace(translate(upper(btrim(v)),'ÁÉÍÓÚÜÑ','AEIOUUN'), '[^A-Z]+', ' ', 'g') norm
    from casos)
select v as trae, esperado,
       case when norm ~ 'CONDUCTOR|VEHICULO' then 'CONDUCTOR'
            when norm ~ 'MENSAJERO|MOTO'     then 'MENSAJERO'
            when btrim(v) = ''               then 'VACIA'
            else 'NO ENTENDIDA' end as da,
       case when case when norm ~ 'CONDUCTOR|VEHICULO' then 'CONDUCTOR'
                      when norm ~ 'MENSAJERO|MOTO'     then 'MENSAJERO'
                      when btrim(v) = ''               then 'VACIA'
                      else 'NO ENTENDIDA' end = esperado then 'ok' else '<<< REVISAR' end as veredicto
  from calc;
