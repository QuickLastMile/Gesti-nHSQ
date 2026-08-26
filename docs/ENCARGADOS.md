# Encargados por proyecto

Quién responde por cada operación, para que cada quien revise solo lo suyo:
**jefatura**, **líder** y **coordinador**.

## Qué se puede hacer

- **Administración → Encargados**: cargar de un pegón la tabla de la compañía
  (CECO · CLIENTE · JEFATURA · LÍDER), editar proyecto por proyecto, y asignar
  coordinadores.
- **Coordinador → Exportar**: un desplegable *Encargado* con los tres niveles.
- **Coordinador → Cumplimiento**: solo el filtro de **coordinador**, y el campo
  aparece únicamente cuando ya hay alguno asignado.
- **Dashboard**: tres filtros independientes — jefatura, líder y coordinador —
  que se pueden combinar entre sí y con el de proyecto. Todos los indicadores
  (activos, esperadas, cumplimiento por proyecto, ranking de mensajeros,
  alertas, inactividad y el periodo anterior) se recalculan sobre ese grupo.
- **Dashboard → Cumplimiento**: gráficas de % de cumplimiento por jefatura, por
  líder y por coordinador, más una tabla de detalle con esperados y faltantes.
  Quien no tenga encargado sale agrupado como **Sin asignar**: ese es el hueco
  que hay que ir cerrando.
- **Exportable CSV**: incluye cuatro columnas nuevas — `jefatura`, `lider`,
  `coordinador` y `frente` — para dinamizar por encargado en Excel.

## Cómo se cargan los jefes y líderes

La llave es el **CECO**, no el nombre del cliente: un mismo CECO puede
aparecer con nombres distintos (438 es *MEDERI* en la tabla de la compañía y
*Corporación Hospitalaria* en la nómina) y aun así queda bien enlazado.

Reglas de la carga:

- Un campo que llegue **vacío no borra** lo que ya estaba guardado. Se puede
  volver a pegar la tabla completa cada vez que cambie.
- `OTRO` se guarda como **sin asignar** (se puede desactivar con la casilla).
- Si un CECO aparece **repetido**, gana el valor que venga lleno. Ejemplo: 584
  aparece dos veces, una con `LAURA CASTAÑEDA` y otra con `OTRO`; queda Laura.
- Los CECOs cargados que hoy no tienen a nadie en la matriz quedan guardados
  igual (botón *Ver CECOs sin proyecto*). Cuando llegue gente con ese CECO, el
  jefe y el líder se aplican solos.

## El coordinador: el caso de los proyectos con varios

Un proyecto puede tener más de un coordinador (593 Cafam Comercial: uno de
Bogotá y otro de nacionales) y no existe un proyecto por ciudad. **No hay que
crear proyectos nuevos ni tocar la nómina.** Se usa el concepto de **frente**:
una división interna del proyecto, que puede ser por ciudad, por ruta o por
turno.

- Un proyecto **sin frentes** funciona exactamente como hoy: el coordinador
  general cubre a todos.
- Un proyecto **con frentes** tiene un coordinador por frente, y cada persona
  pertenece a uno. En la pantalla se marcan varias personas de una vez —
  incluso todas las de una ciudad con un clic — y se asignan al frente.
- Una persona puede tener un **coordinador propio**, que manda sobre el del
  frente y el del proyecto. Sirve para las excepciones sin inventar un frente.

El orden con que se resuelve, de mayor a menor peso:

```
coordinador propio de la persona
      > coordinador del frente
            > coordinador del proyecto
```

Jefatura y líder siguen la misma lógica pero sin el nivel de persona: si el
frente tiene jefe propio manda ese, si no, el del proyecto.

## Proyectos sin CECO

El CECO es la llave de todo: sin él una persona no puede tener jefe, líder ni
coordinador. Por eso:

- La **carga masiva rechaza** cualquier fila que no traiga CECO y dice cuántas
  rechazó y por qué. Sin código no hay a qué proyecto engancharla, y aceptarla
  crearía proyectos duplicados.
- El **ingreso provisional exige** que el proyecto exista en la matriz, y guarda
  su CECO. Antes no lo hacía: quien entraba por ahí quedaba sin encargados y
  aparecía en una fila fantasma sin código.
- Si aun así queda alguien sin CECO, la lista lo muestra aparte, marcado y sin
  posibilidad de editar, con la instrucción de corregirlo en la matriz.

## Traslados

Si alguien está **trasladado** a otra operación, sus encargados son los del
proyecto **donde está laborando**, no los de su proyecto de nómina. Es la misma
regla que ya aplica para exigirle y contarle el cumplimiento.

## Cómo se asignan los coordinadores

En el editor del proyecto, **Coordinación** es un solo bloque:

- Si el proyecto tiene **un solo coordinador**, lo escribes en la fila
  *Todo el proyecto* y listo.
- Si tiene **varios**, usa **+ Agregar otro coordinador** y ponle nombre a cada
  parte — por ciudad, por ruta o por turno.
- Con varias partes, la primera fila pasa a llamarse **Los demás (sin parte
  asignada)**: es el coordinador de respaldo para quien todavía no esté en
  ninguna. Llenarla es la forma rápida de dejar el proyecto sin pendientes.

El nombre de una parte ya guardada **no se puede editar**: renombrarla dejaría
huérfana a su gente. Si te equivocaste, quítala y créala de nuevo — su gente
vuelve al coordinador de todo el proyecto.

## Un coordinador con muchos proyectos

Dos caminos, según el momento:

**Carga inicial — quinta columna.** En *Encargados → Cargar tabla*, agrega una
columna `COORDINADOR` a la derecha de `LÍDER`. Se carga junto con el jefe y el
líder, así que un solo pegado deja todo listo. Es lo más rápido cuando vas a
armar el mapa completo desde Excel.

**Día a día — asignación múltiple.** En *Encargados → Proyectos*, botón
**Asignar un coordinador a varios proyectos**. Busca o filtra, pulsa *Marcar los
visibles*, escribe el nombre una vez y aplica.

El atajo real está en combinar el buscador con *Marcar los visibles*: buscar
`cafam` deja solo esos proyectos, y un clic los marca todos. Veinte proyectos en
un movimiento.

Solo cambia el coordinador: el jefe y el líder de cada proyecto se conservan. En
los proyectos divididos en partes, el coordinador que asignas así queda como
**respaldo** — cubre a quien no esté en ninguna parte, sin reemplazar a los
coordinadores de cada una. El mensaje de confirmación te dice en cuántos pasó eso.

Dejar el nombre vacío **quita** el coordinador de los proyectos marcados, con
confirmación previa.

## Qué significa cada color

- **Verde** — el proyecto está configurado: tiene jefe, líder y al menos un
  coordinador.
- **Ámbar con ⚠️** — falta configuración: no tiene jefe, o no tiene líder, o no
  tiene ningún coordinador. Eso sí hay que revisarlo.
- **N por asignar** (sin ⚠️) — el proyecto está bien configurado, solo falta
  meter a N personas en una parte. Es trabajo del día a día, no un error.

## Proyectos sin gente activa

Un proyecto con **0 activos** sigue existiendo porque tiene colaboradores en la
matriz, todos inactivos: es una operación cerrada. No es un pendiente, así que
**no aparece** en los filtros de trabajo *Sin jefe o sin líder* ni *Sin
coordinador*, y tampoco lleva el aviso ⚠️. Para verlos está el filtro
*Sin gente activa (históricos)*.

## Qué se puede borrar y qué no

**El proyecto no se puede borrar.** No existe como registro propio: aparece
porque hay gente suya en la matriz de nómina. Borrarlo sería borrar
colaboradores, y eso no se toca desde aquí.

Lo que sí se puede quitar:

- **La configuración de encargados de un proyecto** — jefe, líder, coordinadores
  y partes. Está al final del editor, en *Quién responde*. Útil si lo cargaste
  por error. La gente y el proyecto quedan intactos, y se puede volver a
  configurar cuando quieras.
- **Un CECO cargado que nunca tuvo gente** — botón *Eliminar* en la lista de
  *Ver CECOs sin proyecto*. La base rechaza el borrado si resulta que sí tiene
  gente, para que no se vaya por delante algo que sí se usa.

## Quién queda sin coordinador

El contador de la lista (*N sin coordinador*) cuenta personas, no frentes. Un
proyecto con todos sus frentes completos puede tener gente sin coordinador si
alguien **no está asignado a ningún frente**.

Para encontrarlos: abre el proyecto y usa el filtro de la lista de personas —
*Solo las que no tienen frente* o *Solo las que no tienen coordinador*.

Un caso que confunde: alguien **prestado a otro proyecto** responde a los
encargados del proyecto donde labora, no a los del suyo de nómina. La lista de
personas lo marca con 🔄 y dice de dónde viene.

## Actualizaciones de matriz

`frente` y `coordinador propio` **no se pierden** al actualizar la nómina: la
actualización no toca esas columnas. Si a alguien le cambia el proyecto, sus
encargados se recalculan solos.

## Si un filtro devuelve cero

Los filtros se **suman**. Si eliges un proyecto y además un líder, ves solo la
gente que cumple las dos condiciones; si ese proyecto no tiene ese líder
asignado, el resultado es cero y no hay ningún error.

Para ver dónde falta asignar: **Administración → Encargados**, filtro
*"Sin jefe o sin líder"* o *"Sin coordinador"*. Arriba de la lista sale contado
cuántos proyectos con gente activa siguen sin jefe.

## Dónde se actualiza la matriz

En **Administración → Actualizar matriz**, no en Coordinador → Exportar. Se movió
para separar lo que consulta un coordinador de lo que cambia la nómina.

Va por el router de administración, así que **exige sesión de HSQ**: la cuenta de
coordinador ya no alcanza para actualizar la matriz.

## Historial

**Administración → Historial** muestra lo que se ha cambiado, agrupado por día y
con hora, tipo, persona y proyecto. Filtros por texto, tipo y rango de fechas.

Incluye traslados, ingresos provisionales, actualizaciones de matriz, cambios de
encargados, justificaciones, anulaciones y cambios hechos por HSQ sobre una
ficha.

**No incluye las marcaciones del mensajero**: cuando sube sus documentos al
diligenciar (`DOCUMENTOS`) o registra su placa la primera vez (`CAMBIO_PLACA`).
Eso es operación diaria, no un cambio administrativo, y llenaría la bitácora de
ruido. Los equivalentes hechos por HSQ —`ADMIN_PLACA` y `ADMIN_ESTADO`— sí
aparecen.

Vive solo en Administración: no está en el dashboard.

## Scripts

Todos se pueden volver a ejecutar sin problema, **pero el orden importa**: varios
redefinen las mismas funciones, y correrlos al revés deshace lo corregido sin
avisar — el script dice "Success" igual.

| # | Script | Para qué |
|---|---|---|
| 1 | `db/encargados_por_proyecto.sql` | Base: tablas, columnas, resolución de encargados y funciones del panel. |
| 2 | `db/HOTFIX_recalcular_encargados.sql` | El `UPDATE` sin `WHERE` que Supabase bloquea. |
| 3 | `db/filtro_encargado_v2.sql` | Cumplimiento, dashboard y exportable aceptan los filtros por encargado. |
| 4 | `db/por_dia_esperadas.sql` | *Opcional.* Habilita el % diario en la tendencia del dashboard. |
| 5 | `db/FIX_parametro_nombre.sql` | El parámetro `nombre` chocaba con la columna `nombre` y ningún traslado enlazaba. |
| 6 | `db/FIX_encargados_ceco.sql` | Ingresos provisionales sin CECO y conteo por el proyecto donde se labora. |
| 7 | `db/URGENTE_permisos_routers.sql` | Control de acceso de los routers, matriz desde Administración y asignación masiva de coordinador. |

`db/DIAGNOSTICO_hoya.sql` no modifica nada: sirve para ver quién quedó sin CECO
o sin coordinador y por qué.

### Por qué ese orden

Cada script pisa lo que define. Los choques reales:

- **El 1 redefine los dos routers**, además de `codigo_proyecto`, `en_alcance`,
  `calc_encargados`, `admin_encargados`, `admin_personas_proyecto` y
  `admin_cargar_encargados`. Correrlo después del 5, 6 o 7 deshace esas
  correcciones. Va siempre de primero.
- **El 7 es la autoridad de los routers** y de `admin_cargar_encargados`. Va
  siempre de último.
- El 4 redefine `api_dashboard`, así que va después del 3.

### El 7 es de seguridad

Al reescribir los routers para agregarles las acciones de encargados se perdió la
validación de rol que ambos traían. `hseq_api` está concedido a `anon` — la llave
pública que va en `assets/config.js` —, así que sin esa validación cualquiera con
la llave podía llamar `generarExportable`, `getDashboard`, `anularRegistro` o
`actualizarMatriz`. El script 7 lo cierra y verifica el resultado: al final debe
imprimir **`protegido`** en las dos filas.
