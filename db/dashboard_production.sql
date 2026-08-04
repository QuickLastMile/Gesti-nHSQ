-- Dashboard ejecutivo HSEQ y alertas documentales a 15 dias.
create or replace function api_dashboard(payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hoy date := (now() at time zone 'America/Bogota')::date;
  anio_f int := coalesce(nullif(payload->>'anio','')::int, extract(year from hoy)::int);
  mes_f int := nullif(payload->>'mes','')::int;
  proy text := btrim(coalesce(payload->>'proyecto',''));
  desde date;
  hasta date;
  nforms int;
  activos int;
  realizadas bigint;
  esperadas bigint;
begin
  desde := case when mes_f is null then make_date(anio_f,1,1) else make_date(anio_f,mes_f,1) end;
  hasta := case when mes_f is null then make_date(anio_f,12,31) else (desde + interval '1 month - 1 day')::date end;
  hasta := least(hasta,hoy);
  if hasta < desde then hasta := desde; end if;

  select count(*) into nforms from formularios where activo;
  select count(*) into activos from colaboradores c
   where c.activo and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy);
  select count(*) into realizadas from registros r
   where r.fecha between desde and hasta and coalesce(r.estado,'') <> 'ANULADO'
     and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy);
  esperadas := activos::bigint * greatest((hasta-desde)+1,0) * nforms;

  return jsonb_build_object(
    'filtros',jsonb_build_object('anio',anio_f,'mes',mes_f,'proyecto',proy,'desde',desde,'hasta',hasta),
    'resumen',jsonb_build_object(
      'activos',activos,'realizadas',realizadas,'esperadas',esperadas,
      'no_realizadas',greatest(esperadas-realizadas,0),
      'porcentaje',case when esperadas>0 then round(realizadas::numeric*1000/esperadas)/10 else 0 end,
      'con_alerta',(select count(*) from registros r where r.fecha between desde and hasta
        and coalesce(r.alertas,'')<>'' and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy))
    ),
    'por_dia',coalesce((select jsonb_agg(x order by x.fecha) from (
      select d::date fecha, count(r.id) realizadas
      from generate_series(desde,hasta,'1 day') d
      left join registros r on r.fecha=d::date and coalesce(r.estado,'')<>'ANULADO'
       and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by d
    ) x),'[]'::jsonb),
    'por_mes',coalesce((select jsonb_agg(x order by x.mes) from (
      select to_char(d,'YYYY-MM') mes, count(r.id) realizadas
      from generate_series(make_date(anio_f,1,1),least(make_date(anio_f,12,31),hoy),'1 month') d
      left join registros r on date_trunc('month',r.fecha)=d and coalesce(r.estado,'')<>'ANULADO'
       and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by d
    ) x),'[]'::jsonb),
    'por_anio',coalesce((select jsonb_agg(x order by x.anio) from (
      select extract(year from r.fecha)::int anio,count(*) realizadas
      from registros r where coalesce(r.estado,'')<>'ANULADO'
       and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by extract(year from r.fecha)
    ) x),'[]'::jsonb),
    'por_proyecto',coalesce((select jsonb_agg(x order by x.realizadas desc) from (
      select coalesce(r.proyecto,'Sin proyecto') proyecto,count(*) realizadas,
             count(*) filter(where coalesce(r.alertas,'')<>'') con_alerta
      from registros r where r.fecha between desde and hasta and coalesce(r.estado,'')<>'ANULADO'
       and (proy='' or r.proyecto=proy or r.proyecto_id::text=proy)
      group by coalesce(r.proyecto,'Sin proyecto')
    ) x),'[]'::jsonb),
    'alertas',coalesce((select jsonb_agg(x order by x.prioridad,x.dias_restantes,x.proyecto,x.nombre) from (
      select c.cedula,c.nombre,c.proyecto,c.placa_moto,d.documento,d.fecha_vencimiento,
             d.fecha_vencimiento-hoy dias_restantes,
             case when d.fecha_vencimiento is null then 'SIN FECHA'
                  when d.fecha_vencimiento<hoy then 'VENCIDO' else 'PRÓXIMO A VENCER' end estado,
             case when d.fecha_vencimiento is null or d.fecha_vencimiento<hoy then 1 else 2 end prioridad
      from colaboradores c
      cross join lateral (values ('SOAT',c.soat_vence),('TECNOMECÁNICA',c.tecnomecanica_vence),('LICENCIA',c.licencia_vence)) d(documento,fecha_vencimiento)
      where c.activo and (proy='' or c.proyecto=proy or c.proyecto_id::text=proy)
        and (d.fecha_vencimiento is null or d.fecha_vencimiento<=hoy+15)
    ) x),'[]'::jsonb),
    'actualizado',to_char(now() at time zone 'America/Bogota','YYYY-MM-DD HH24:MI')
  );
end;
$$;

revoke all on function api_dashboard(jsonb) from public, anon;
grant execute on function api_dashboard(jsonb) to authenticated;
