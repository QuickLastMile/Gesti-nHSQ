-- ============================================================
--  DOCUMENTOS - Etapa 1: el estado de cada uno
--  ------------------------------------------------------------
--  Hoy los tres documentos del vehiculo se manejan en bloque: una
--  pregunta -"primera vez o renovacion"- los abre todos, y estar
--  vencido solo genera una alerta.
--
--  Lo que se quiere es otra cosa: cada documento con su propio
--  estado, que se le pida SOLO el que esta pendiente, que un
--  documento vencido termine bloqueando, y que HSEQ pueda
--  rechazar uno mal cargado.
--
--  Esta etapa NO cambia nada de lo que ve el mensajero. Solo
--  deja puesto el estado por documento:
--
--    - donde se anota un rechazo
--    - cuantos dias de gracia hay tras un vencimiento
--    - una funcion que dice, para una cedula, que pasa con cada
--      documento
--
--  Se puede correr en plena operacion: nadie queda bloqueado.
--  El bloqueo llega en la etapa 3.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Donde se anota que un documento fue rechazado
--  ------------------------------------------------------------
--  Va en colaboradores, al lado de la fecha y el archivo de cada
--  documento, que es donde ya vive todo lo demas. Un rechazo se
--  levanta solo: al volver a adjuntar, se limpia.
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists soat_rechazado_en          timestamptz,
  add column if not exists soat_rechazo_motivo        text,
  add column if not exists tecnomecanica_rechazado_en timestamptz,
  add column if not exists tecnomecanica_rechazo_motivo text,
  add column if not exists licencia_rechazado_en      timestamptz,
  add column if not exists licencia_rechazo_motivo    text;

-- ------------------------------------------------------------
--  2) Cuantos dias de gracia despues de vencerse
--  ------------------------------------------------------------
--  Un documento que se vence hoy no deja a nadie varado el mismo
--  dia: hay margen para renovarlo. Pasado ese margen, bloquea.
--
--  Un documento que NUNCA se cargo, o uno RECHAZADO, no tienen
--  gracia: esos se piden de una.
--
--  Se cambia sin tocar codigo:
--    update config set valor = '5'
--     where clave = 'DIAS_GRACIA_VENCIMIENTO';
-- ------------------------------------------------------------
insert into config (clave, valor) values ('DIAS_GRACIA_VENCIMIENTO', '2')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
--  3) Que pasa con cada documento de una persona
--  ------------------------------------------------------------
--  Una sola fuente de verdad. La usan la pantalla del mensajero
--  para saber que pedir, y el guardado para saber que exigir: si
--  cada una lo calculara por su lado, tarde o temprano dirian
--  cosas distintas.
--
--  Por documento:
--    estado   sin_dato | vencido | por_vencer | ok
--    rechazado / motivo
--    exige    hay que volver a adjuntarlo
--    bloquea  no se puede registrar sin hacerlo
--
--  exige y bloquea NO son lo mismo: un documento recien vencido
--  se pide (exige) pero todavia deja pasar (no bloquea) mientras
--  duren los dias de gracia.
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
begin
  select * into c from colaboradores
   where regexp_replace(cedula, '\D', '', 'g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('documentos', '{}'::jsonb,
                              'exige', false, 'bloquea', false, 'gracia', gracia);
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

  return jsonb_build_object(
    'documentos', docs,
    'exige',   n_exige   > 0,
    'bloquea', n_bloquea > 0,
    'gracia',  gracia
  );
end;
$fn$;

-- ------------------------------------------------------------
--  4) La pantalla del mensajero recibe el estado nuevo
--  ------------------------------------------------------------
--  Mismo contenido de antes mas los campos nuevos, asi que la
--  pantalla de hoy sigue funcionando igual: lee los que ya leia
--  e ignora el resto.
-- ------------------------------------------------------------
create or replace function api_buscar_activo(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  ncedula text := regexp_replace(coalesce(payload->>'cedula',''), '\D', '', 'g');
  c colaboradores%rowtype;
  hoy date := (now() at time zone 'America/Bogota')::date;
  proy text;
  puede boolean;
  v_perfil text;
  v_estado jsonb := '{}'::jsonb;
  v_docs jsonb := '{}'::jsonb;
  v_obs text;
  f record; r record;
begin
  if ncedula = '' then raise exception 'Digite una cedula valida.'; end if;
  select * into c from colaboradores where regexp_replace(cedula,'\D','','g') = ncedula limit 1;
  if not found then
    return jsonb_build_object('encontrado', false, 'mensaje', 'No se encontro la cedula en la matriz.');
  end if;

  proy := coalesce(c.proyecto_efectivo, c.proyecto, '');
  v_obs := btrim(coalesce(c.observacion_coordinador, ''));
  puede := c.activo and cargo_aplica(c.cargo);
  v_perfil := perfil_cargo(c.cargo);

  if puede then
    for f in
      select frm.id, frm.nombre
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy
        -- Hay formularios de un solo cargo: la temperatura la mide el
        -- conductor, no el mensajero.
        and (frm.aplica_a is null or frm.aplica_a = v_perfil)
        -- Un formulario semanal solo aparece el dia que le toca.
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from hoy)::smallint = pf.dia_semana)
      order by frm.orden
    loop
      select to_char(reg.hora,'HH24:MI') as h, reg.id::text as rid into r
        from registros reg
       where regexp_replace(reg.cedula,'\D','','g') = ncedula
         and reg.formulario_id = f.id
         and reg.fecha = hoy
         and coalesce(reg.estado,'') <> 'ANULADO'
       limit 1;
      if found then
        v_estado := v_estado || jsonb_build_object(f.id,
          jsonb_build_object('hecho', true, 'hora', coalesce(r.h,''), 'idRegistro', r.rid));
      else
        v_estado := v_estado || jsonb_build_object(f.id, jsonb_build_object('hecho', false));
      end if;
    end loop;

    -- El estado de los documentos ya no se calcula aqui: se pregunta.
    v_docs := estado_documentos(ncedula);
  end if;

  return jsonb_build_object(
    'encontrado', true,
    'activo', puede,
    'observacionCoordinador', v_obs,
    'mensaje', case
      when puede then 'Activo habilitado para registro.'
      when not cargo_aplica(c.cargo) then
        'Tu cargo (' || coalesce(c.cargo,'sin cargo') || ') no requiere diligenciar estos formularios.'
      when v_obs <> '' then 'No estas habilitado para registrar. Motivo: ' || v_obs
      else 'La persona no esta activa para registro.' end,
    'requierePlaca', (coalesce(btrim(c.placa_moto),'') = ''),
    'datos', jsonb_build_object(
      'cedula', c.cedula, 'nombre', coalesce(c.nombre,''), 'cargo', coalesce(c.cargo,''),
      'proyecto_id', coalesce(c.proyecto_id,''), 'proyecto', proy,
      'proyecto_nomina', coalesce(c.proyecto,''),
      'trasladado', coalesce(btrim(c.proyecto_operativo),'') <> '',
      'ciudad', coalesce(c.ciudad,''), 'placa_moto', coalesce(c.placa_moto,''),
      'tipo_vehiculo', coalesce(c.tipo_vehiculo,'')
    ),
    'formulariosRequeridos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id_formulario', frm.id, 'nombre_formulario', frm.nombre,
               -- Los del mismo grupo se pintan como una sola fila con un
               -- boton por jornada.
               'grupo', coalesce(frm.grupo,''), 'etiqueta', coalesce(frm.etiqueta,''))
             order by frm.orden)
      from formularios frm
      join proyectos_formularios pf on pf.formulario_id=frm.id and pf.activo
      where frm.activo and pf.proyecto = proy and puede
        and (frm.aplica_a is null or frm.aplica_a = v_perfil)
        and (pf.frecuencia <> 'SEMANAL'
             or extract(isodow from hoy)::smallint = pf.dia_semana)), '[]'::jsonb),
    'estadoDiario', v_estado,
    -- Lo de siempre, para que la pantalla actual no se entere del cambio.
    'documentos', coalesce(v_docs->'documentos', '{}'::jsonb),
    -- Lo nuevo, para la pantalla que viene.
    'documentosEstado', v_docs
  );
end;
$fn$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las columnas nuevas quedaron.
select column_name
  from information_schema.columns
 where table_name = 'colaboradores'
   and column_name like '%rechaz%'
 order by column_name;

-- b) Los dias de gracia.
select clave, valor from config where clave = 'DIAS_GRACIA_VENCIMIENTO';

-- c) Como quedaria clasificada la gente HOY, si el bloqueo ya existiera.
--    Sirve para medir el impacto antes de encenderlo en la etapa 3.
select c.linea,
       count(*) as activos,
       count(*) filter (where (estado_documentos(c.cedula)->>'exige')::boolean)   as les_falta_algo,
       count(*) filter (where (estado_documentos(c.cedula)->>'bloquea')::boolean) as quedarian_bloqueados
  from colaboradores c
 where c.activo
 group by c.linea
 order by c.linea;
