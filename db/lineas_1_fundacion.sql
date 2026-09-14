-- ============================================================
--  LINEAS DE NEGOCIO - Etapa 1: la base
--  ------------------------------------------------------------
--  La plataforma nacio para LAST MILE. Ahora entra WAREHOUSE y
--  vendran mas lineas. Cada una tiene su propia matriz de activos,
--  su propia gente y su propia configuracion, y no se pueden ver
--  entre ellas.
--
--  Esta etapa NO cambia el comportamiento de nadie. Solo deja
--  puesta la estructura:
--
--    - la tabla de lineas
--    - la linea de cada colaborador (todo lo de hoy queda en LAST_MILE)
--    - la linea de cada registro, sellada por trigger
--    - a que lineas puede entrar cada usuario
--
--  Despues de correrlo, Last Mile sigue viendo exactamente lo
--  mismo que hoy. El aislamiento llega en la etapa 2.
--
--  Supabase -> SQL Editor -> New query -> pegar todo -> Run
-- ============================================================

-- ------------------------------------------------------------
--  1) Las lineas
-- ------------------------------------------------------------
create table if not exists lineas (
  id      text primary key,          -- LAST_MILE, WAREHOUSE, ...
  nombre  text not null,
  activo  boolean not null default true,
  orden   int not null default 100,
  creado_en timestamptz not null default now()
);
alter table lineas enable row level security;

insert into lineas (id, nombre, orden) values
  ('LAST_MILE', 'Last Mile', 10),
  ('WAREHOUSE', 'Warehouse', 20)
on conflict (id) do nothing;

-- ------------------------------------------------------------
--  2) La linea de cada colaborador
--  ------------------------------------------------------------
--  Todo lo que existe hoy es Last Mile. El default hace que un
--  cargue viejo no rompa nada; la etapa 3 lo amarra al cargue.
-- ------------------------------------------------------------
alter table colaboradores
  add column if not exists linea text not null default 'LAST_MILE';

alter table colaboradores drop constraint if exists fk_colab_linea;
alter table colaboradores add constraint fk_colab_linea
  foreign key (linea) references lineas(id);

create index if not exists idx_colab_linea on colaboradores (linea) where activo;

-- ------------------------------------------------------------
--  3) La linea de cada registro
--  ------------------------------------------------------------
--  Se guarda EN el registro, no se consulta al vuelo. Si manana
--  alguien se pasa de linea, su historia no se muda con el: el
--  mismo criterio que ya se usa con proyecto y cargo.
-- ------------------------------------------------------------
alter table registros add column if not exists linea text;

update registros r
   set linea = c.linea
  from colaboradores c
 where c.cedula = r.cedula
   and r.linea is distinct from c.linea;

update registros set linea = 'LAST_MILE' where linea is null;

alter table registros drop constraint if exists fk_reg_linea;
alter table registros add constraint fk_reg_linea
  foreign key (linea) references lineas(id);

create index if not exists idx_reg_linea_fecha on registros (linea, fecha);

-- El sello es automatico: hay cinco funciones distintas que insertan
-- registros (normal, diferido, provisional...). Un trigger no se le
-- olvida a ninguna.
create or replace function registro_sella_linea()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.linea is null then
    select c.linea into new.linea
      from colaboradores c
     where regexp_replace(c.cedula,'\D','','g') = regexp_replace(new.cedula,'\D','','g')
     limit 1;
  end if;
  new.linea := coalesce(new.linea, 'LAST_MILE');
  return new;
end;
$fn$;

drop trigger if exists trg_registro_linea on registros;
create trigger trg_registro_linea
  before insert or update of cedula on registros
  for each row execute function registro_sella_linea();

-- ------------------------------------------------------------
--  4) A que lineas puede entrar cada usuario
--  ------------------------------------------------------------
--  Dos formas de acceso:
--    todas_lineas = true  -> usuario universal (la administradora
--                            general y el equipo HSEQ). Ve todo y
--                            puede cambiar de linea.
--    lineas = '{...}'     -> usuario de linea (jefes, lideres,
--                            coordinadores). Solo lo suyo.
--
--  Un usuario sin nada asignado NO ve nada. Falla cerrado a
--  proposito: es preferible que alguien reclame acceso a que
--  alguien vea lo que no es suyo.
-- ------------------------------------------------------------
alter table app_roles add column if not exists lineas text[] not null default '{}';
alter table app_roles add column if not exists todas_lineas boolean not null default false;

-- Los que ya existen son de Last Mile, salvo que sean ADMIN/HSEQ:
-- esos quedan como universales para que nada se les cierre hoy.
update app_roles
   set todas_lineas = true
 where rol in ('ADMIN','HSEQ') and not todas_lineas;

update app_roles
   set lineas = array['LAST_MILE']
 where not todas_lineas and coalesce(array_length(lineas,1),0) = 0;

-- ------------------------------------------------------------
--  5) Las dos preguntas que se hace el sistema
-- ------------------------------------------------------------
-- Que lineas puede ver quien esta llamando.
create or replace function lineas_permitidas()
returns text[] language sql stable security definer set search_path = public as $fn$
  select case
    when coalesce((select r.todas_lineas from app_roles r
                    where r.user_id = auth.uid() and r.activo), false)
      then coalesce((select array_agg(l.id order by l.orden, l.id)
                       from lineas l where l.activo), '{}'::text[])
    else coalesce((select r.lineas from app_roles r
                    where r.user_id = auth.uid() and r.activo), '{}'::text[])
  end;
$fn$;

revoke all on function lineas_permitidas() from public, anon;
grant execute on function lineas_permitidas() to authenticated;

-- Sobre que linea se esta trabajando. El desplegable PROPONE,
-- esta funcion DISPONE: si el usuario no tiene esa linea, no pasa.
-- Por eso el aislamiento no depende de que la pantalla filtre bien.
create or replace function linea_efectiva(p_linea text default '')
returns text language plpgsql stable security definer set search_path = public as $fn$
declare
  permitidas text[] := lineas_permitidas();
  pedida text := nullif(btrim(coalesce(p_linea,'')), '');
begin
  if coalesce(array_length(permitidas,1),0) = 0 then
    raise exception 'Tu usuario no tiene ninguna linea asignada. Pidele a HSEQ que te la asigne.';
  end if;
  if pedida is null then
    return permitidas[1];
  end if;
  if not (upper(pedida) = any(permitidas)) then
    raise exception 'No tienes acceso a la linea %.', pedida;
  end if;
  return upper(pedida);
end;
$fn$;

revoke all on function linea_efectiva(text) from public, anon;
grant execute on function linea_efectiva(text) to authenticated;

-- Lo que necesita el desplegable del encabezado.
create or replace function api_lineas()
returns jsonb language sql security definer set search_path = public as $fn$
  select jsonb_build_object(
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'nombre', l.nombre) order by l.orden, l.id)
        from lineas l
       where l.activo and l.id = any(lineas_permitidas())), '[]'::jsonb),
    'actual', coalesce((select (lineas_permitidas())[1]), ''),
    -- Con una sola linea no hay nada que escoger: la pantalla muestra
    -- el nombre en vez del desplegable.
    'puede_cambiar', coalesce(array_length(lineas_permitidas(),1),0) > 1
  );
$fn$;

revoke all on function api_lineas() from public, anon;
grant execute on function api_lineas() to authenticated;

-- ------------------------------------------------------------
--  6) Como asignarle la linea a un usuario
--  ------------------------------------------------------------
--  app_roles no se toca desde la app (esta revocada para anon y
--  authenticated), asi que esto se hace aqui. Descomenta y ajusta
--  el correo.
--
--  -- Usuario universal (ve todas las lineas, con desplegable):
--  update app_roles set todas_lineas = true, lineas = '{}'
--   where email = 'correo@quicklastmile.com';
--
--  -- Usuario de una sola linea (no puede salirse de ella):
--  update app_roles set todas_lineas = false, lineas = array['WAREHOUSE']
--   where email = 'warehouse@quicklastmile.com';
--
--  Para crear el usuario de una linea nueva: Supabase -> Authentication
--  -> Add user, y despues insertarlo aqui con su rol y su linea.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  Verificacion
-- ------------------------------------------------------------
-- a) Las lineas quedaron creadas.
select id, nombre, activo from lineas order by orden;

-- b) Toda la gente de hoy quedo en Last Mile.
select linea, count(*) filter (where activo) as activos, count(*) as total
  from colaboradores group by linea order by linea;

-- c) Todos los registros quedaron sellados.
select linea, count(*) as registros, min(fecha) as desde, max(fecha) as hasta
  from registros group by linea order by linea;

-- d) Quien ve que. 'todas_lineas' = usuario universal.
select email, rol, todas_lineas, lineas, activo from app_roles order by rol, email;
