# Dashboard HSEQ — centro de control

La pantalla inicial responde cuatro preguntas y nada más: **cómo estamos**,
**dónde está el problema**, **quién necesita seguimiento** y **qué hay que hacer**.
Todo lo demás sigue disponible, pero en su sección.

## Secciones

| Sección | Para qué sirve |
|---|---|
| **Resumen** | El estado en menos de diez segundos: KPI, alertas, cumplimiento por proyecto, tendencia y seguimiento. |
| **Seguimiento** | Quién responde por el cumplimiento, los pendientes críticos y el espacio reservado para la gestión. |
| **HSEQ** | Registros con novedad, top de fallas, actividad por día de la semana y franja horaria. |
| **Documentos** | SOAT, tecnomecánica y licencia: vencidos, sin fecha o por vencer. |
| **Preventivo** | Puntos reportados como *No cumple* tres veces o más en 30 días. |
| **Detalle** | Las tablas completas: proyectos, encargados, mejores y peores desempeños, cumplimiento por días y mensajero, y las gráficas históricas. |

Ninguna tarjeta desapareció en el rediseño: las veinte que existían siguen ahí,
reubicadas.

## Los KPI

El **cumplimiento** ocupa la tarjeta grande porque es el número que manda. A su
lado, cuatro cifras de apoyo:

- **Activos** — colaboradores habilitados para registrar en el filtro actual.
- **Obligados a diligenciar** — de esos, cuántos tenían días exigibles en el
  periodo. La diferencia son los que el calendario o una justificación dejó por
  fuera.
- **Diligenciados** — registros hechos, y cuántos mensajeros quedaron al día.
- **Pendientes** — **personas** que debían diligenciar y no lo hicieron, con los
  registros que faltaron como dato de apoyo.

## Semáforo

Un solo criterio en toda la pantalla, contra la meta configurada por proyecto
(90% por defecto):

- **Verde** — cumple la meta.
- **Amarillo** — está por encima del 80% de la meta, pero no la alcanza.
- **Rojo** — por debajo de eso.

## Lo que se puede tocar

- Una **barra** de *Cumplimiento por proyecto* filtra el dashboard por ese proyecto.
- Una **fila** de *Seguimiento de operación* filtra por esa jefatura, líder,
  coordinador o proyecto. *Sin asignar* no es una persona, así que no filtra.
- Una **alerta** lleva a la sección donde se resuelve.

## Seguimiento de operación

Una sola tabla que cambia de nivel — jefatura, líder, coordinador, proyecto o
mensajero — en vez de cuatro gráficas sueltas. Siempre ordena **de peor a mejor**:
lo que hay que atender queda arriba.

## Gestión de pendientes

La plataforma **no registra todavía las acciones de seguimiento** (llamadas,
mensajes, compromisos sobre un pendiente), así que el % de gestión no se puede
calcular. El espacio está reservado y marcado como tal: un porcentaje de
cumplimiento alto no prueba que el coordinador esté gestionando.

Para habilitarlo hace falta que el coordinador pueda marcar un pendiente como
gestionado desde la pantalla de Cumplimiento.

## Tendencia de cumplimiento

Muestra el porcentaje diario contra la meta, con selector de 7, 15 o 30 días.

Necesita saber cuántos registros se esperaban cada día, que es lo que agrega
`db/por_dia_esperadas.sql`. **Mientras no se ejecute**, la gráfica muestra
registros por día y lo dice en pantalla — nunca inventa un porcentaje.

## Detalles de uso

- Al entrar, el dashboard viene filtrado en **el día de hoy**. Para ver el mes,
  borra el campo *Día específico* o usa el enlace de la tendencia.
- Con un día específico seleccionado no hay serie que graficar: la tendencia lo
  dice y ofrece volver al mes.
- Ninguna tabla comparte fila con otra: todas ocupan el ancho completo.

## Los filtros de encargado se encadenan

Al elegir una **jefatura**, el filtro de *líder* deja solo los suyos; al elegir un
**líder**, el de *coordinador* deja solo los suyos. Si la selección que tenías
deja de ser posible, se limpia sola.

Se calcula con las combinaciones reales que hay en la operación —quién responde
a quién según la gente activa—, así que no hay listas inventadas: si un líder no
tiene coordinadores, el desplegable queda vacío.

## Días justificados

Las tablas de *Cumplimiento por proyecto*, *Detalle por encargado* y *Seguimiento
de operación* traen una columna **Justificados**: los días que no se exigieron
por descanso, permiso, incapacidad o vacaciones.

Son días-persona, la misma unidad de *Esperados*, y **ya vienen descontados** de
ese número. Sirven para no confundir un proyecto con poco esperado por
calendario con uno que tuvo muchos permisos.

Necesita `db/dashboard_justificados.sql`.

## Exportaciones

Excel y PDF siguen funcionando igual. El PDF dibuja las gráficas de las secciones
ocultas antes de capturarlas, así que no salen en blanco.

## Script

```
db/dashboard_justificados.sql
```

Reemplaza a `por_dia_esperadas.sql`: lo incluye completo y le suma los días
justificados y los filtros encadenados. Si ya corriste aquel, este lo actualiza;
si no, con este basta.
