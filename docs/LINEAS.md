# Líneas de negocio

La plataforma nació para **Last Mile**. Ahora entra **Warehouse**, y vendrán más.
Cada línea tiene su propia matriz de activos y alimenta su propia configuración,
y no deben verse entre ellas.

## Quién ve qué

| Usuario | Alcance |
|---|---|
| Administradora general y HSEQ | Todas las líneas, con desplegable en la barra |
| Jefes, líderes y coordinadores | Una sola línea, sin poder salirse |
| Mensajero | No escoge: su cédula ya dice a qué línea pertenece |

Un usuario **sin línea asignada no ve nada**. Falla cerrado a propósito: es
preferible que alguien reclame acceso a que alguien vea lo que no es suyo.

El desplegable **propone**, la base **dispone**: cada llamada pasa por
`linea_efectiva()`, que valida contra las líneas permitidas del usuario. Si
mañana se olvida un filtro en el HTML, no se filtra información igual.

## Una sola puerta

Desde la página de inicio hay dos tarjetas: **Soy Mensajero** (sin contraseña) y
**Gestión administrativa**. El acceso suelto a Administración desapareció: se
entra una sola vez, con la misma cuenta.

Dentro, el engranaje de **Configuración** en la barra lleva a la matriz y la
configuración, **sin pedir la contraseña otra vez**, y solo aparece si el rol es
ADMIN o HSEQ. Un COORDINADOR no lo ve.

Eso decide lo que se **ve**, no lo que se **puede**: quien manipule la página
para mostrar el botón igual choca contra la guarda de `hseq_admin`, que sigue
exigiendo ADMIN o HSEQ.

La sesión vive **por pestaña**, así que el salto a Configuración tiene que ser
en la misma pestaña. Salir desde Configuración cierra toda la sesión, no solo
esa pantalla.

## Dónde está el selector

En la barra superior de **Administración**, **Cumplimiento** y **Dashboard** —
las pantallas con sesión. En la página de inicio no va: es pública, el mensajero
entra ahí sin sesión y no debe escoger línea.

Con una sola línea permitida muestra el nombre como etiqueta fija, sin
desplegable: no hay nada que escoger. Al cambiar de línea se recarga la
pantalla, en vez de dejar mezclados los datos de dos operaciones.

La elección se guarda **por pestaña**, así que cambiar de línea no le cambia la
vista a nadie más y se va al cerrar sesión.

`admin.html` no carga `assets/api.js` —tiene su propia capa de sesión—, así que
allí el selector está implementado aparte, con el mismo token. Si el script de
líneas todavía no se ha corrido, la barra se queda como estaba y no rompe nada.

## El cargue de matriz es por línea

Antes, actualizar la matriz inactivaba a **todo** el que no apareciera en el
texto pegado. Con una sola línea estaba bien; con dos era una bomba: pegar la
matriz de Warehouse habría intentado inactivar a todo Last Mile.

Desde `db/lineas_2_matriz.sql` el cargue:

- se hace **sobre la línea activa** en el panel;
- solo inactiva gente de esa línea;
- la red de seguridad del 50 % se mide **dentro** de la línea;
- una cédula que ya pertenece a otra línea **no se mueve**: se cuenta aparte y
  se reporta, porque un traslado entre líneas es una decisión, no el efecto
  secundario de un pegado.

## La línea de cada registro

Se guarda **en el registro**, no se consulta al vuelo. Si alguien se pasa de
línea, su historia no se muda con él — el mismo criterio que ya se usa con
proyecto y cargo.

El sello lo pone un trigger, no las funciones: hay cinco que insertan registros
(normal, diferido, provisional, traslado) y a un trigger no se le olvida ninguna.

## Cómo asignarle la línea a un usuario

`app_roles` no se toca desde la app, así que se hace en el editor SQL:

```sql
-- Usuario universal (ve todas, con desplegable):
update app_roles set todas_lineas = true, lineas = '{}'
 where email = 'correo@quicklastmile.com';

-- Usuario de una sola línea (no puede salirse de ella):
update app_roles set todas_lineas = false, lineas = array['WAREHOUSE']
 where email = 'warehouse@quicklastmile.com';
```

El usuario se crea antes en **Supabase → Authentication → Add user**.

## Scripts

| Script | Qué hace |
|---|---|
| `db/lineas_1_fundacion.sql` | Tabla de líneas, la línea de cada colaborador y de cada registro, y el alcance por usuario. No cambia el comportamiento de nadie. |
| `db/lineas_2_matriz.sql` | El cargue de matriz queda amarrado a la línea activa. **Correr antes de cargar cualquier matriz nueva.** |
| `db/lineas_3_lecturas.sql` | Dashboard, cumplimiento del día, exportable y lista de encargados devuelven solo la línea activa. |
| `db/lineas_4a_administracion.sql` | Administración (Buscar, Proyectos, Calendario, Formularios, Historial) muestra solo la línea activa. |
| `db/lineas_perfil_usuario.sql` | `api_lineas` devuelve también el rol, para decidir si se muestra el engranaje de Configuración. |
| `db/lineas_4b_escrituras.sql` | Las escrituras de Administración validan la línea. **Correr antes de subir a HSEQ a los usuarios de línea.** |

## Escribir fuera de la línea: bloqueado

Guardar una ficha, mover a alguien de proyecto, asignar encargados o habilitar
un formulario verifican que el destino sea de la línea activa. El mensaje dice
**de qué línea es** lo que se intentó tocar, no solo "no autorizado".

El criterio: lo que **ya tiene línea** solo se toca desde esa línea; lo que
todavía no tiene gente —un CECO recién cargado— se deja pasar, para no bloquear
la configuración inicial de una línea nueva.

Tres casos con regla propia:

- **Borrar un CECO sin gente** solo lo puede hacer el usuario universal: no
  tiene línea deducible, y una línea borraría lo que la otra acaba de cargar.
- **Asignar parte o coordinador propio** a varias personas se rechaza entero si
  alguna es de otra línea, en vez de hacer el cambio a medias.
- **El cargue de la tabla de encargados** salta las filas de otra línea y dice
  cuántas fueron.

Con esto ya se puede subir a HSEQ a los usuarios de línea.

## Detalles que conviene saber

- Un **CECO huérfano** (cargado pero sin gente) no tiene línea deducible, así que
  solo lo ve el usuario universal.
- En el **historial**, los movimientos sin cédula (calendario, cargues de tabla)
  tampoco tienen línea, así que también son solo para el universal.

## Una consulta que no pasa por el router

`api_lista_encargados` se expone directo, además del router, para que la
pantalla pueda mandarle la línea del desplegable. Cambiar el router es donde más
caro sale equivocarse —ya pasó una vez con los permisos—, así que se evitó.
`api_lineas` funciona igual.
