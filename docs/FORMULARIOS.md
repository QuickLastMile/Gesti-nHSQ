# Un formulario, dos perfiles

Los dos formularios diarios son **uno solo cada uno**, no dos versiones
separadas. Cada pregunta lleva marcado a quién le aplica:

| `aplica_a` | Quién la responde |
|---|---|
| vacío | Todos |
| `MOTO` | Solo **QUICKER - MENSAJERO** |
| `VEHICULO` | Solo **QUICKER - CONDUCTOR** |

El perfil sale del **cargo** del colaborador. Al digitar la cédula, el sistema
arma el formulario que le corresponde a esa persona: el mensajero nunca ve las
preguntas del conductor y viceversa.

Aplica a los dos:

- `PREOPERACIONAL` — Registro diario preoperacional
- `LIMPIEZA_MOTO` — Limpieza y desinfección del vehículo

El **id no cambia** aunque el formulario ya cubra los dos perfiles: los registros
históricos lo referencian. Lo que cambia es el nombre que se ve en pantalla.

## Por qué no hay que tocar código

`api_cargar_formulario`, `api_respuestas_previas` (la precarga), `api_exportable`
y la validación al guardar ya filtran por `aplica_a` para **cualquier**
formulario. Agregar preguntas de un perfil nuevo es solo insertar filas.

## El orden intercalado

Las preguntas del vehículo usan **órdenes decimales** — 3.1, 7.2, 10.1 — para
caer entre las de moto sin renumerar nada. Así cada perfil ve su formulario en
una secuencia lógica, aunque compartan la misma tabla.

## El diferenciador en el exportable

En **Coordinador → Exportar**, el filtro *Tipo de vehículo* (Motos / Vehículos)
descarga solo las columnas de ese perfil. Sin filtro salen todas, y las que no
apliquen quedan vacías. El CSV trae además una columna `tipo` con `MOTO` o
`VEHICULO` por registro.

## Cuantos registros aguanta el exportable

El exportable arma el archivo en una sola consulta, asi que un rango de varios
dias con todos los proyectos sale en segundos. El tope es de **30.000 registros**
por descarga: pasado ese punto avisa y pide acortar el rango o filtrar, en vez
de dejar la pantalla colgada.

Si aparece *canceling statement due to statement timeout*, falta correr
`db/FIX_exportable_lento.sql`.

Los enlaces de las fotos se firman **en lotes de 200**, no uno por uno: una
semana de todos los proyectos son miles de archivos y pedirlos todos a la vez
hacia que el servidor respondiera una pagina de error.

Si algun lote falla, el archivo igual se genera: esas evidencias salen como
ruta en vez de enlace y el mensaje de la pantalla dice cuantas fueron.

## El formulario de limpieza no comparte preguntas

En limpieza y desinfección, los dos formularios son **independientes**: el
conductor ve solo las preguntas `LIV_*` y el mensajero exactamente las que
siempre vio. No hay preguntas compartidas.

Se hizo así porque compartirlas producía duplicados: el conductor veía dos veces
la evidencia, el soporte del centro de lavado y el permiso de vertimientos —
una vez en la versión de moto y otra en la suya.

La fecha y la hora no se preguntan en la versión de vehículo: el sistema las
registra solo.

## Qué se dejó por fuera del formulario de limpieza de vehículos

El formulario original en Google pedía datos que la plataforma **ya tiene**, así
que no se vuelven a preguntar todos los días: consentimiento, tipo y número de
documento, nombres, celular, centro de trabajo, departamento y ciudad, y placa.
Todo eso sale de la matriz al digitar la cédula.

Lo demás sí se conserva, incluidos **tipo de vehículo**, **modelo** y **tipo de
combustible**. Son estáticos por persona, así que se preguntan una vez y la
precarga los deja listos para los días siguientes.

## La infografía de los 10 pasos

La pregunta *¿Qué pasos de aseo realizaste hoy a tu vehículo?* muestra la
infografía de referencia, igual que la versión de moto. La imagen vive en
`assets/pasos-limpieza-vehiculo.png` y la columna `imagen_url` de la pregunta
apunta a ella. También acepta un enlace de Google Drive: la app reconoce el
formato y muestra la miniatura sola.

## Cada cuánto se exige un formulario

En **Administración → Formularios por proyecto**, los formularios de **limpieza
y desinfección** traen debajo un selector de frecuencia. El preoperacional no lo
tiene: se hace todos los días sin excepción.

- **Todos los días del calendario** — lo de siempre, y el valor por defecto.
- **Solo los lunes** (o el día que se elija) — para las operaciones que solo
  hacen la limpieza una vez por semana, por auditoría.

La frecuencia se combina con el calendario del proyecto: si el día elegido no es
laboral, o cae festivo y el proyecto no labora festivos, esa semana no se exige.
El panel avisa en amarillo si el día elegido no está en el calendario del
proyecto, porque en ese caso el formulario **nunca** llegaría a pedirse.

Qué formularios admiten frecuencia lo decide la columna `permite_frecuencia` de
la tabla `formularios`, no el código: para habilitarla en otro formulario basta
con marcarla ahí.

Cambia en los cuatro lados a la vez:

| Dónde | Qué pasa |
|---|---|
| Mensajero | El formulario no le aparece los días que no le tocan |
| Cumplimiento diario | No queda como pendiente un día que no se exigía |
| Dashboard | Las *esperadas* cuentan solo los días que aplican |
| Mi cumplimiento | La racha no se rompe por un día que no se pedía nada |

### Dos cosas que conviene saber

Un registro **ya hecho** en un día que ahora no se exige sigue contando como
hecho. No se borra ni se esconde nada.

El cambio **aplica también hacia atrás**: el dashboard recalcula las esperadas de
los meses anteriores con la nueva frecuencia, así que el porcentaje de esos meses
sube. Si hace falta conservar la historia tal como se midió, hay que agregarle
una fecha de vigencia a la frecuencia — hoy no la tiene.

## Para que un conductor lo vea

Su proyecto debe tener el formulario habilitado en
**Administración → Formularios por proyecto**. Un proyecto sin el formulario
marcado no lo exige ni lo cuenta en el cumplimiento.

## Scripts

| Script | Qué agrega |
|---|---|
| `db/preoperacional_vehiculos.sql` | La columna `aplica_a` y las 17 preguntas del preoperacional de vehículo. |
| `db/limpieza_vehiculos.sql` | Las preguntas de limpieza y desinfección de vehículo. |
| `db/limpieza_vehiculos_v2.sql` | Corrección: separa por completo los dos formularios, agrega modelo y combustible, y pone la infografía. |
| `db/FIX_exportable_lento.sql` | Arregla el *statement timeout* del exportable en rangos largos. |
| `db/frecuencia_formulario.sql` | Frecuencia diaria o semanal por proyecto y formulario. Correr **después** de `dashboard_justificados.sql`. |
| `db/frecuencia_solo_limpieza.sql` | Deja el selector de frecuencia solo en limpieza. Correr **después** del anterior. |

Ambos se pueden volver a ejecutar sin duplicar nada.
