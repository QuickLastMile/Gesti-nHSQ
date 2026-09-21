-- ============================================================
--  Si hoy no es dia laboral, no se deja registrar
--  ------------------------------------------------------------
--  POR QUE
--  -------
--  Hasta ahora un mensajero podia registrar cualquier dia, y los
--  registros hechos en dias que su proyecto no opera habia que
--  descontarlos despues del indicador. Es mejor no dejarlos entrar:
--  el dato no se ensucia y el mensajero se entera en el momento,
--  no cuando alguien revisa el tablero.
--
--  QUE FRENA
--  ---------
--  Tres casos, con su propio mensaje:
--    - tiene una justificacion vigente (vacaciones, incapacidad,
--      descanso, permiso, suspension),
--    - su proyecto/ciudad no opera ese dia de la semana,
--    - es festivo y su proyecto no opera festivos.
--  La justificacion manda sobre el calendario.
--
--  EL INTERRUPTOR
--  --------------
--  config.BLOQUEAR_DIA_NO_LABORAL. En 'true' bloquea; en 'false'
--  solo avisa y deja registrar. Existe porque un calendario mal
--  configurado deja gente trancada: al momento de escribir esto,
--  BACK UP DOMICILIOS en MEDELLIN registra 98 veces en 15 dias
--  distintos, incluso entre semana. Antes de dejarlo en 'true'
--  conviene revisar esos calendarios.
--
--    update config set valor = 'false' where clave = 'BLOQUEAR_DIA_NO_LABORAL';
--
--  Requiere db/calendario_por_ciudad.sql.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

insert into config (clave, valor)
values ('BLOQUEAR_DIA_NO_LABORAL', 'true')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
--  1) Por que hoy no se le puede exigir registro
--  ------------------------------------------------------------
--  Devuelve '' si si es dia laboral. El texto va dirigido al
--  mensajero: le dice que pasa y a quien acudir.
-- ------------------------------------------------------------
create or replace function motivo_no_laboral(p_cedula text, p_proyecto text,
                                             p_ciudad text, p_fecha date)
returns text language plpgsql stable set search_path = public as $fn$
declare
  v_dias smallint[];
  v_fest boolean;
  j record;
  v_ciudad text := coalesce(nullif(btrim(coalesce(p_ciudad,'')),''), '');
begin
  -- Una justificacion manda sobre el calendario: si esta de vacaciones no
  -- deberia estar registrando, aunque el dia sea laboral.
  select tipo, coalesce(fecha_inicio, fecha) desde, coalesce(fecha_fin, fecha) hasta
    into j
    from justificaciones
   where regexp_replace(cedula,'\D','','g') = regexp_replace(coalesce(p_cedula,''),'\D','','g')
     and p_fecha between coalesce(fecha_inicio, fecha) and coalesce(fecha_fin, fecha)
   order by coalesce(fecha_fin, fecha) desc limit 1;
  if found then
    return 'Tienes ' || lower(j.tipo) || ' registrada'
        || case when j.desde = j.hasta then ' para hoy'
                else ' del ' || to_char(j.desde,'DD/MM') || ' al ' || to_char(j.hasta,'DD/MM') end
        || '. Si estas trabajando, avisale a tu coordinador para que lo ajuste.';
  end if;

  select k.dias_laborales, k.labora_festivos into v_dias, v_fest
    from calendario_de(p_proyecto, v_ciudad) k;
  v_dias := coalesce(v_dias,
    coalesce((select string_to_array(valor,',')::smallint[] from config where clave='CAL_DIAS_DEFECTO'),
             '{1,2,3,4,5,6}'::smallint[]));
  v_fest := coalesce(v_fest,
    coalesce((select valor='true' from config where clave='CAL_FESTIVOS_DEFECTO'), false));

  if not (extract(isodow from p_fecha)::smallint = any(v_dias)) then
    return 'Tu proyecto no opera los ' ||
      case extract(isodow from p_fecha)::int
        when 1 then 'lunes' when 2 then 'martes' when 3 then 'miercoles'
        when 4 then 'jueves' when 5 then 'viernes' when 6 then 'sabados'
        else 'domingos' end
      || case when v_ciudad <> '' then ' en ' || v_ciudad else '' end
      || '. Si si trabajas hoy, pidele a tu coordinador que ajuste el calendario.';
  end if;

  if not v_fest and exists (select 1 from festivos x where x.fecha = p_fecha) then
    return 'Hoy es festivo y tu proyecto no opera festivos. '
        || 'Si si trabajas hoy, pidele a tu coordinador que ajuste el calendario.';
  end if;

  return '';
end;
$fn$;

-- ------------------------------------------------------------
--  2) El guardado se frena
--  ------------------------------------------------------------
--  Va despues del "ya registraste hoy" para que ese mensaje, que es
--  mas concreto, siga saliendo primero.
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10); a text;
begin
  select prosrc into src from pg_proc where proname = 'api_guardar_registro';
  if src is null then raise exception 'No existe api_guardar_registro'; end if;
  if position('motivo_no_laboral' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;
  a := '  select coalesce(exige_documentos, true), coalesce(recibe_documentos, false)';
  if position(a in src) = 0 then raise exception 'No encontre donde insertar'; end if;
  nuevo := replace(src, a,
       '  -- Si hoy no es dia laboral para el, no se le deja registrar: asi no' || nl
    || '  -- quedan registros que despues hay que descontar del indicador. Se' || nl
    || '  -- puede apagar desde config si algun calendario esta mal puesto.' || nl
    || '  if coalesce((select valor from config where clave = ''BLOQUEAR_DIA_NO_LABORAL''), ''true'') = ''true'' then' || nl
    || '    declare v_motivo text;' || nl
    || '    begin' || nl
    || '      v_motivo := motivo_no_laboral(ncedula, proy, c.ciudad, hoy);' || nl
    || '      if v_motivo <> '''' then raise exception ''%'', v_motivo; end if;' || nl
    || '    end;' || nl
    || '  end if;' || nl
    || nl
    || a);
  execute 'create or replace function api_guardar_registro(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  3) Y la pantalla lo sabe antes de que llene nada
-- ------------------------------------------------------------
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_buscar_activo';
  if position('motivoNoLaboral' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;
  nuevo := replace(src,
    '    ''estadoDiario'', v_estado,',
    '    ''estadoDiario'', v_estado,' || nl
 || '    -- Para decirselo antes de que llene nada.' || nl
 || '    ''motivoNoLaboral'', case when puede then motivo_no_laboral(ncedula, proy, c.ciudad, hoy) else '''' end,' || nl
 || '    ''bloqueaDiaNoLaboral'', coalesce((select valor from config where clave = ''BLOQUEAR_DIA_NO_LABORAL''), ''true'') = ''true'',');
  if nuevo = src then raise exception 'No encontre donde insertar'; end if;
  execute 'create or replace function api_buscar_activo(payload jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las tres piezas.
select (select valor from config where clave='BLOQUEAR_DIA_NO_LABORAL') as interruptor,
       (select case when prosrc like '%motivo_no_laboral%' then 'si' else 'NO' end
          from pg_proc where proname='api_guardar_registro') as guardar,
       (select case when prosrc like '%motivoNoLaboral%' then 'si' else 'NO' end
          from pg_proc where proname='api_buscar_activo') as pantalla;

-- b) A cuanta gente habria frenado este mes. Si el numero sorprende, el
--    calendario de ese proyecto es lo que hay que revisar, no el bloqueo.
with r as (
  select r.linea, r.cedula, coalesce(r.proyecto,'') proy,
         coalesce(nullif(btrim(coalesce(r.ciudad,'')),''),'(sin ciudad)') ciudad,
         motivo_no_laboral(r.cedula, coalesce(r.proyecto,''), r.ciudad, r.fecha) motivo
    from registros r
   where r.fecha >= date_trunc('month', (now() at time zone 'America/Bogota')::date)::date
     and coalesce(r.estado,'') <> 'ANULADO')
select linea,
       count(*) as registros_del_mes,
       count(*) filter (where motivo <> '') as se_habrian_frenado,
       count(distinct cedula) filter (where motivo <> '') as personas
  from r group by linea order by linea;

-- c) Donde se concentra, para saber que calendario revisar primero.
with r as (
  select coalesce(r.proyecto,'') proy,
         coalesce(nullif(btrim(coalesce(r.ciudad,'')),''),'(sin ciudad)') ciudad,
         r.cedula, r.fecha,
         motivo_no_laboral(r.cedula, coalesce(r.proyecto,''), r.ciudad, r.fecha) motivo
    from registros r
   where r.fecha >= date_trunc('month', (now() at time zone 'America/Bogota')::date)::date
     and coalesce(r.estado,'') <> 'ANULADO')
select proy, ciudad, count(*) registros, count(distinct cedula) personas, count(distinct fecha) dias
  from r where motivo <> ''
 group by proy, ciudad order by registros desc limit 10;
