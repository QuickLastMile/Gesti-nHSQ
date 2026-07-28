-- ============================================================
--  Gestión HSEQ Motos — Reglas del almacenamiento (bucket evidencias)
--  Ejecutar en SQL Editor. Requiere que el bucket 'evidencias' exista.
-- ============================================================

-- 1) El mensajero (anon) puede SUBIR evidencias.
drop policy if exists "anon_sube_evidencias" on storage.objects;
create policy "anon_sube_evidencias" on storage.objects
  for insert to anon
  with check (bucket_id = 'evidencias');

-- 2) El mensajero puede SOBREESCRIBIR solo los documentos del vehículo
--    (carpeta documentos/). Así, al renovar SOAT/Tecnomecánica/Licencia,
--    el archivo nuevo reemplaza al anterior y NO se acumula basura.
drop policy if exists "anon_reemplaza_documentos" on storage.objects;
create policy "anon_reemplaza_documentos" on storage.objects
  for update to anon
  using (bucket_id = 'evidencias' and name like 'documentos/%')
  with check (bucket_id = 'evidencias' and name like 'documentos/%');

-- 3) VER los archivos: solo usuarios con sesión REAL (encargado HSQ),
--    no los anónimos que se crean para subir fotos.
drop policy if exists "hsq_ve_evidencias" on storage.objects;
create policy "hsq_ve_evidencias" on storage.objects
  for select to authenticated
  using (bucket_id = 'evidencias' and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false);
