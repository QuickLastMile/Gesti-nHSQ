# Puesta en producción con Supabase Pro

## Orden de implementación

1. Publicar la versión del portal que exige inicio de sesión para coordinación.
2. Ejecutar `db/security_production.sql` en el editor SQL de Supabase.
3. Volver a ejecutar `db/functions_admin.sql` y las funciones actualizadas de `db/functions_coord2.sql`.
4. Confirmar que cada usuario interno tenga un rol en `public.app_roles`.
5. Probar mensajero, coordinación, administración, exportación y consulta de evidencias.
6. Activar el plan Pro y configurar los avisos de consumo.

## Roles internos

Los roles permitidos son `ADMIN`, `HSEQ` y `COORDINADOR`. Para autorizar a un usuario ya creado en Supabase Auth:

```sql
insert into public.app_roles (user_id, email, rol, activo)
select id, email, 'COORDINADOR', true
from auth.users
where lower(email) = lower('usuario@empresa.com')
on conflict (user_id) do update
set email = excluded.email,
    rol = excluded.rol,
    activo = true;
```

Para retirar el acceso sin borrar el usuario:

```sql
update public.app_roles
set activo = false
where lower(email) = lower('usuario@empresa.com');
```

## Evidencias

- El bucket `evidencias` queda privado.
- Los mensajeros únicamente pueden cargar archivos durante su sesión anónima.
- Solo usuarios internos activos pueden consultar evidencias.
- Los enlaces incluidos en exportables son temporales y vencen en siete días.
- Nunca se debe compartir la `service_role key` ni incluirla en el portal.

## Respaldos

- Revisar en el panel de Supabase que los respaldos diarios de la base estén activos después del cambio a Pro.
- Hacer una prueba trimestral de restauración en un proyecto separado.
- El respaldo de la base no reemplaza el respaldo de Storage: copiar el bucket privado a un almacenamiento corporativo al menos una vez por semana.
- Definir una política de retención para evidencias según lo aprobado por HSEQ y protección de datos.

## Control de consumo y costos

- Registrar un responsable técnico y uno de HSEQ para recibir alertas.
- Configurar avisos internos al 70 %, 85 % y 95 % del presupuesto mensual.
- Revisar semanalmente crecimiento de Storage, transferencia, usuarios activos y tamaño de base durante el primer mes.
- Evitar conservar duplicados y establecer cuándo se archivan o eliminan evidencias antiguas.

## Prueba de aceptación

- Mensajero sin SOAT o tecnomecánica: no puede continuar.
- Documento vencido: permite continuar, genera alerta y aparece en cumplimiento/exportable.
- Licencia: exige frente y reverso legibles.
- Coordinador: exige correo, contraseña y rol activo.
- Administrador: puede consultar y anular; la anulación conserva trazabilidad.
- Evidencias: no abren mediante un enlace público permanente.
- CSV: abre en columnas en Excel y contiene las alertas documentales.
