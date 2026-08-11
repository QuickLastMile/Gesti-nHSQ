# Precarga de respuestas — reducir el tiempo de diligenciamiento

El mensajero ya no vuelve a responder cada día lo que no cambia. Al abrir un
formulario, el sistema trae las respuestas de **su último registro** en ese mismo
formulario; el mensajero solo corrige lo que hoy esté diferente y adjunta las fotos.

## Qué se precarga y qué no

| | Comportamiento |
|---|---|
| Texto, número, párrafo, sí/no, desplegable, casillas, fechas normales | **Se precargan** con la respuesta anterior |
| Fotos y adjuntos (`archivo`) | **Nunca** se precargan — son la evidencia del día |
| Fecha de la inspección y hora de inicio | Las pone el sistema, siempre las de hoy |
| Vencimientos de SOAT, tecnomecánica y licencia | Vienen de la matriz, como siempre |
| "¿Es la primera inspección / renovación?" | Queda en blanco: es una decisión de cada día |
| Preguntas marcadas con `no_precargar` | Se responden desde cero cada día |

En el preoperacional esto se traduce, con datos reales, en **41 de 48 preguntas
precargadas**. Las 7 restantes son la fecha y la hora del registro, los tres
vencimientos de documentos y los dos adjuntos de certificados.

La precarga es **por persona y por formulario**: cada quien ve sus propias
respuestas anteriores, y el preoperacional no se mezcla con el de limpieza.

## Puesta en marcha

1. Supabase → **SQL Editor** → **New query**.
2. Pegar todo el contenido de [`db/precarga_respuestas.sql`](../db/precarga_respuestas.sql) y ejecutar.
3. Listo. El frontend ya envía la cédula al cargar el formulario.

Si el script no se ejecuta, la aplicación sigue funcionando **sin** precarga: los
formularios se abren vacíos, como antes.

## Excluir preguntas de la precarga

Las preguntas abiertas de observaciones o novedades conviene responderlas cada
día: si se arrastran, una falla reportada una vez aparecería repetida
indefinidamente y ensuciaría el reporte de novedades.

Para excluir preguntas puntuales:

```sql
update preguntas set no_precargar = true
 where id in ('PRE_012', 'PRE_034');
```

Para excluir de una vez todas las de texto abierto y las que mencionan
observación, novedad o comentario, está el bloque comentado al final de
`db/precarga_respuestas.sql`.

Para revertir una exclusión:

```sql
update preguntas set no_precargar = false where id = 'PRE_012';
```

## Lo que ve el mensajero

Sobre las preguntas aparece un aviso ámbar con la fecha del registro del que se
tomaron las respuestas y cuántas vienen precargadas, junto con el recordatorio de
que las fotos sí debe tomarlas hoy. Cada pregunta precargada lleva la etiqueta
**"De tu último registro"** y una línea ámbar al costado, para que se distinga de
las que respondió en el momento.

## Consideración de control

La precarga acelera el diligenciamiento, pero también facilita que alguien guarde
sin inspeccionar realmente la moto. Los controles que siguen vigentes son la
evidencia fotográfica obligatoria del día, la hora del registro y el límite de un
registro diario. Si más adelante se quiere reforzar, dos opciones que no agregan
mayor fricción:

- Marcar como `no_precargar` las preguntas críticas de seguridad (frenos, luces,
  llantas), de modo que esas sí se respondan cada día.
- Pedir una confirmación explícita antes de guardar cuando **todas** las
  respuestas vengan precargadas y no se haya modificado ninguna.
