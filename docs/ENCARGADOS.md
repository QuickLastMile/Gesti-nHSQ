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

## Scripts

Ejecutar en Supabase → SQL Editor, en este orden:

1. `db/encargados_por_proyecto.sql` — tablas, columnas, resolución de
   encargados, funciones del panel y routers.
2. `db/filtro_encargado_v2.sql` — cumplimiento, dashboard y exportable aceptan
   los filtros, y el dashboard devuelve el cumplimiento agrupado por nivel.

Ambos se pueden volver a ejecutar sin problema.
