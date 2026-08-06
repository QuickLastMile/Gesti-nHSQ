-- Seguridad para produccion: roles, Storage privado y politicas de acceso.

create table if not exists app_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  rol text not null check (rol in ('ADMIN','HSEQ','COORDINADOR')),
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

alter table app_roles enable row level security;
revoke all on app_roles from anon, authenticated;

-- La asignación de formularios por proyecto solo se consulta/modifica a
-- través de funciones protegidas; nunca directamente desde el navegador.
alter table proyectos_formularios enable row level security;
revoke all on proyectos_formularios from anon, authenticated;

-- Evita bloquear al usuario real que ya administra la aplicacion.
insert into app_roles(user_id, email, rol, activo)
select id, email, 'ADMIN', true
from auth.users
where coalesce(is_anonymous, false) = false
on conflict (user_id) do nothing;

create or replace function hseq_tiene_rol(roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app_roles r
    where r.user_id = auth.uid() and r.activo and r.rol = any(roles)
  );
$$;

revoke all on function hseq_tiene_rol(text[]) from public;
grant execute on function hseq_tiene_rol(text[]) to authenticated;

-- Los documentos HSEQ contienen datos personales: el bucket debe ser privado.
update storage.buckets set public = false where id = 'evidencias';

drop policy if exists "anon_sube_evidencias" on storage.objects;
drop policy if exists "anon_reemplaza_documentos" on storage.objects;
drop policy if exists "hsq_ve_evidencias" on storage.objects;
drop policy if exists "mensajero_sube_evidencias" on storage.objects;
drop policy if exists "personal_hseq_ve_evidencias" on storage.objects;

-- El mensajero recibe una sesion anonima de Supabase Auth solo para subir.
create policy "mensajero_sube_evidencias" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'evidencias'
    and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = true
  );

-- Solo usuarios reales con rol autorizado pueden consultar documentos.
create policy "personal_hseq_ve_evidencias" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'evidencias'
    and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
    and hseq_tiene_rol(array['ADMIN','HSEQ','COORDINADOR'])
  );
