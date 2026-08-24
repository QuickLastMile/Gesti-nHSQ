# Encargados por proyecto

Quién responde por cada operación, para que cada quien revise solo lo suyo:
**jefatura**, **líder** y **coordinador**.

## Qué se puede hacer

- **Administración → Encargados**: cargar de un pegón la tabla de la compañía
  (CECO · CLIENTE · JEFATURA · LÍDER), editar proyecto por proyecto, y asignar
  coordinadores.
- **Coordinador → Exportar** y **Coordinador → Cumplimiento**: un desplegable
  *Encargado* filtra por jefe, líder o coordinador.
- **Dashboard**: el mismo desplegable en la barra de filtros. Todos los
  indicadores (activos, esperadas, cumplimiento por proyecto, ranking de
  mensajeros, alertas, inactividad y el periodo anterior) se recalculan sobre
  ese grupo.
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

## Traslados

Si alguien está **trasladado** a otra operación, sus encargados son los del
proyecto **donde está laborando**, no los de su proyecto de nómina. Es la misma
regla que ya aplica para exigirle y contarle el cumplimiento.

## Actualizaciones de matriz

`frente` y `coordinador propio` **no se pierden** al actualizar la nómina: la
actualización no toca esas columnas. Si a alguien le cambia el proyecto, sus
encargados se recalculan solos.

## Scripts

Ejecutar en Supabase → SQL Editor, en este orden:

1. `db/encargados_por_proyecto.sql` — tablas, columnas, resolución de
   encargados, funciones del panel y routers.
2. `db/filtro_encargado.sql` — cumplimiento, dashboard y exportable aceptan el
   filtro.

Ambos se pueden volver a ejecutar sin problema.
