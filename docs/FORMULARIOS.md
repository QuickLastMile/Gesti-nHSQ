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

## Qué se dejó por fuera del formulario de limpieza de vehículos

El formulario original en Google pedía datos que la plataforma **ya tiene**, así
que no se vuelven a preguntar todos los días:

- Consentimiento, tipo y número de documento, nombres, celular, centro de
  trabajo, departamento y ciudad, placa → salen de la matriz al digitar la cédula.
- Modelo del vehículo y tipo de combustible → ya se preguntan en el
  preoperacional del mismo día.

Sí se conservó **Tipo de vehículo** (CARRY, NHR, NPR, tractocamión…), que es
información nueva: la matriz solo distingue entre moto y vehículo. Se pregunta
una vez y la precarga la deja lista para los días siguientes.

## Para que un conductor lo vea

Su proyecto debe tener el formulario habilitado en
**Administración → Formularios por proyecto**. Un proyecto sin el formulario
marcado no lo exige ni lo cuenta en el cumplimiento.

## Scripts

| Script | Qué agrega |
|---|---|
| `db/preoperacional_vehiculos.sql` | La columna `aplica_a` y las 17 preguntas del preoperacional de vehículo. |
| `db/limpieza_vehiculos.sql` | Las 9 preguntas de limpieza y desinfección de vehículo. |

Ambos se pueden volver a ejecutar sin duplicar nada.
