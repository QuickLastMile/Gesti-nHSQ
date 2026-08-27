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

Ambos se pueden volver a ejecutar sin duplicar nada.
