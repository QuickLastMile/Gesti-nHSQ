-- ============================================================
--  El VIN incompleto se vuelve a pedir
--  ------------------------------------------------------------
--  Hay 184 colaboradores activos con el VIN mal guardado (de 1, 5
--  o 6 caracteres). La regla de los 17 protege de aqui en
--  adelante, pero a ellos NO los alcanza: las preguntas del
--  vehiculo solo aparecen la primera vez, y ellos ya tienen sus
--  documentos cargados. Sin esto, esos 184 quedan malos para
--  siempre.
--
--  QUE HACE
--  --------
--  1. El VIN y el propietario pasan a ser columnas de la matriz,
--     al lado de la marca y el cilindraje, que ya lo eran. Hasta
--     hoy vivian solo como respuesta de un registro, que es un
--     mal sitio para un dato permanente del vehiculo: obliga a
--     rebuscar el ultimo registro de cada quien cada vez que se
--     necesita.
--  2. Se rellenan con la ultima respuesta de cada persona.
--  3. Un trigger los mantiene al dia: cuando alguien responde
--     esas preguntas, el valor sube solo a la matriz.
--  4. estado_documentos avisa si el VIN guardado no sirve, para
--     que la pantalla lo vuelva a pedir.
--
--  Requiere db/documentos_1_estado.sql y db/vin_17_caracteres.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Las columnas
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists vin                text,
  add column if not exists propietario_nombre text,
  add column if not exists propietario_cedula text;

-- ------------------------------------------------------------
--  2) Se rellenan con lo que ya se respondio
--  ------------------------------------------------------------
--  La ultima respuesta no vacia de cada persona, descartando los
--  registros anulados. No se corrige nada: si el VIN guardado
--  esta malo, sube malo. Justamente por eso hace falta el punto 4.
-- ------------------------------------------------------------
with ultima as (
  select distinct on (ced_norm, pregunta_id)
         regexp_replace(rg.cedula, '\D', '', 'g') as ced_norm,
         r.pregunta_id, r.valor
    from respuestas r
    join registros rg on rg.id = r.registro_id
   where r.pregunta_id in ('DOC_VIN', 'DOC_PROP_NOMBRE', 'DOC_PROP_CEDULA')
     and coalesce(btrim(coalesce(r.valor, '')), '') <> ''
     and coalesce(rg.estado, '') <> 'ANULADO'
   order by ced_norm, r.pregunta_id, rg.fecha desc, rg.hora desc
),
plano as (
  select ced_norm,
         max(valor) filter (where pregunta_id = 'DOC_VIN')         as vin,
         max(valor) filter (where pregunta_id = 'DOC_PROP_NOMBRE') as prop_nombre,
         max(valor) filter (where pregunta_id = 'DOC_PROP_CEDULA') as prop_cedula
    from ultima
   group by ced_norm
)
update colaboradores c
   set vin                = coalesce(nullif(btrim(coalesce(c.vin, '')), ''), p.vin),
       propietario_nombre = coalesce(nullif(btrim(coalesce(c.propietario_nombre, '')), ''), p.prop_nombre),
       propietario_cedula = coalesce(nullif(btrim(coalesce(c.propietario_cedula, '')), ''), p.prop_cedula)
  from plano p
 where regexp_replace(c.cedula, '\D', '', 'g') = p.ced_norm;

-- ------------------------------------------------------------
--  3) Que se mantengan al dia solos
--  ------------------------------------------------------------
--  Va como trigger y no dentro de api_guardar_registro para no
--  reemplazar una funcion de 300 lineas por esto. Corre DESPUES
--  del trigger que valida el VIN, asi que ya recibe el valor
--  limpio y en mayusculas.
-- ------------------------------------------------------------
create or replace function respuesta_copia_vehiculo()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  ced text;
begin
  if new.pregunta_id not in ('DOC_VIN', 'DOC_PROP_NOMBRE', 'DOC_PROP_CEDULA') then
    return null;
  end if;
  if coalesce(btrim(coalesce(new.valor, '')), '') = '' then
    return null;
  end if;

  select regexp_replace(rg.cedula, '\D', '', 'g') into ced
    from registros rg where rg.id = new.registro_id;
  if ced is null then return null; end if;

  if new.pregunta_id = 'DOC_VIN' then
    update colaboradores set vin = new.valor, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ced;
  elsif new.pregunta_id = 'DOC_PROP_NOMBRE' then
    update colaboradores set propietario_nombre = new.valor, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ced;
  else
    update colaboradores set propietario_cedula = new.valor, actualizado_en = now()
     where regexp_replace(cedula, '\D', '', 'g') = ced;
  end if;

  return null;
end;
$fn$;

drop trigger if exists trg_respuesta_vehiculo on respuestas;
create trigger trg_respuesta_vehiculo
  after insert on respuestas
  for each row execute function respuesta_copia_vehiculo();

-- ------------------------------------------------------------
--  4) estado_documentos avisa si hay que volver a pedir el VIN
--  ------------------------------------------------------------
--  Lo lee de la matriz, que es una sola fila: si lo buscara entre
--  las respuestas, la pantalla de Configuracion tendria que
--  rebuscar el ultimo registro de cada una de las 600 personas
--  cada vez que se abre.
-- ------------------------------------------------------------
create or replace function estado_documentos(p_cedula text)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  gracia int := coalesce(
    (select nullif(regexp_replace(coalesce(valor, ''), '\D', '', 'g'), '')::int
       from config where clave = 'DIAS_GRACIA_VENCIMIENTO'), 2);
  docs jsonb := '{}'::jsonb;
  d record;
  dias int; est text;
  hay_url boolean; rechazado boolean;
  exige boolean; bloquea boolean;
  n_exige int := 0; n_bloquea int := 0;
  vin_ok boolean;
begin
  select * into c from colaboradores
   where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('documentos', '{}'::jsonb,
                              'exige', false, 'bloquea', false, 'gracia', gracia,
                              'vin', '', 'vin_valido', true, 'pide_vin', false);
  end if;

  for d in select * from (values
      ('SOAT',          c.soat_vence,          c.soat_url,          c.soat_rechazado_en,          c.soat_rechazo_motivo),
      ('TECNOMECANICA', c.tecnomecanica_vence, c.tecnomecanica_url, c.tecnomecanica_rechazado_en, c.tecnomecanica_rechazo_motivo),
      ('LICENCIA',      c.licencia_vence,      c.licencia_url,      c.licencia_rechazado_en,      c.licencia_rechazo_motivo)
    ) as t(k, ven, url, rech_en, rech_motivo) loop

    hay_url   := coalesce(btrim(coalesce(d.url, '')), '') <> '';
    rechazado := d.rech_en is not null;

    if d.ven is null then
      dias := null;
      est  := 'sin_dato';
    else
      dias := d.ven - hoy;
      est  := case when dias < 0 then 'vencido'
                   when dias <= 15 then 'por_vencer'
                   else 'ok' end;
    end if;

    -- Falta el archivo, lo rechazaron, o se vencio: hay que actualizarlo.
    exige := (not hay_url) or rechazado or est = 'vencido';

    -- Solo el vencimiento tiene dias de gracia. Lo que nunca se cargo y
    -- lo rechazado se piden de una: no hay nada vigente que proteger.
    bloquea := (not hay_url)
            or rechazado
            or (est = 'vencido' and dias < -gracia);

    if exige   then n_exige   := n_exige + 1;   end if;
    if bloquea then n_bloquea := n_bloquea + 1; end if;

    docs := docs || jsonb_build_object(d.k, jsonb_build_object(
      'fecha',     coalesce(to_char(d.ven, 'YYYY-MM-DD'), ''),
      'dias',      dias,
      'estado',    est,
      'url',       coalesce(d.url, ''),
      'rechazado', rechazado,
      'motivo',    coalesce(d.rech_motivo, ''),
      'rechazado_en', coalesce(to_char(d.rech_en at time zone 'America/Bogota', 'YYYY-MM-DD'), ''),
      'exige',     exige,
      'bloquea',   bloquea,
      -- Para que la pantalla pueda decirle por que se lo estan pidiendo.
      'motivo_exige', case
        when rechazado      then 'rechazado'
        when not hay_url    then 'falta'
        when est = 'vencido' then 'vencido'
        else '' end
    ));
  end loop;

  -- El VIN guardado: si no son 17 caracteres, no identifica ningun
  -- vehiculo y hay que volver a pedirlo.
  vin_ok := upper(regexp_replace(coalesce(c.vin, ''), '[[:space:]-]', '', 'g'))
            ~ '^[A-Z0-9]{17}$';

  return jsonb_build_object(
    'documentos', docs,
    'exige',   n_exige   > 0,
    'bloquea', n_bloquea > 0,
    'gracia',  gracia,
    'vin',        coalesce(c.vin, ''),
    'vin_valido', vin_ok,
    -- Solo se le pide si ya tiene algo cargado: a quien esta empezando
    -- se lo van a pedir igual en el bloque de primera vez.
    'pide_vin',   (not vin_ok)
                  and coalesce(btrim(coalesce(c.soat_url, '')), '') <> ''
  );
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Cuantos quedaron con VIN en la matriz, y cuantos malos.
select c.linea,
       count(*) filter (where coalesce(btrim(coalesce(c.vin,'')),'') <> '') as con_vin,
       count(*) filter (
         where coalesce(btrim(coalesce(c.vin,'')),'') <> ''
           and upper(regexp_replace(c.vin, '[[:space:]-]', '', 'g')) !~ '^[A-Z0-9]{17}$'
       ) as vin_malo
  from colaboradores c
 where c.activo
 group by c.linea
 order by c.linea;

-- b) A cuantos les va a reaparecer la pregunta del VIN.
select c.linea, count(*) as le_vuelven_a_pedir_el_vin
  from colaboradores c
 where c.activo and (estado_documentos(c.cedula)->>'pide_vin')::boolean
 group by c.linea
 order by c.linea;

-- c) El trigger quedo puesto (deben salir los dos de respuestas).
select tgname from pg_trigger
 where tgrelid = 'respuestas'::regclass and not tgisinternal
 order by tgname;
