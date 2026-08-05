# Política de retención de evidencias HSEQ

## Alcance

- Los registros, respuestas y justificaciones se conservan para consulta y auditoría.
- Las evidencias fotográficas operativas se conservan durante **365 días** desde su fecha de carga.
- Para SOAT, tecnomecánica y licencia de tránsito se conserva la versión vigente y se eliminan las versiones reemplazadas.
- Las rutas que todavía están asociadas al documento vigente de un colaborador están protegidas y nunca se incluyen en la limpieza.

## Automatización

La tarea `Retención de evidencias HSEQ` se ejecuta diariamente a las 03:15, hora de Colombia. Antes de limpiar, valida automáticamente las reglas que protegen los documentos vigentes.

También puede ejecutarse manualmente desde GitHub Actions en modo de simulación. La simulación informa cuántos archivos cumplen las condiciones, pero no elimina nada.

La credencial administrativa se guarda únicamente en GitHub Actions con el nombre `SUPABASE_RETENTION_KEY`. Nunca debe guardarse en el repositorio ni en el código público.

## Recuperación y revisión

La eliminación de archivos de Storage no forma parte de las copias de seguridad de la base de datos. Por eso, cualquier cambio del periodo de 365 días debe ser aprobado previamente por HSEQ y por el responsable de protección de datos.
