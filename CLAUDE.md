# Gestión HSEQ Motos

Registro operativo diario de vehículos para Quick Last Mile: preoperacional,
limpieza y temperatura. Lo diligencian mensajeros desde el celular; lo revisan
coordinadores y HSEQ desde el tablero.

En producción: <https://quicklastmile.github.io/Gesti-nHSQ/>

## Arquitectura

Frontend estático en **GitHub Pages** — HTML plano, sin build, sin framework,
sin `npm install`. Se edita el `.html` y se sube.

Backend en **Supabase (PostgreSQL)**. Proyecto `scemoysbcgwxajgoybwc`. Toda la
lógica vive en funciones `plpgsql`, no en el cliente.

Queda un backend viejo de **Apps Script** en `assets/config.js` (`API_URL`).
Está en desuso: Supabase manda mientras `SUPABASE_URL` y `SUPABASE_KEY` estén
puestas. No lo borres sin avisar.

### Los dos routers

Todo entra por una de dos funciones `SECURITY DEFINER`, que reciben
`(action, payload)` y despachan con un `case`:

| Router        | Quién lo llama            | Ejemplos de acción                                  |
|---------------|---------------------------|-----------------------------------------------------|
| `hseq_api`    | anon — el mensajero       | `buscarActivo`, `guardarRegistro`, `miCumplimiento` |
| `hseq_admin`  | authenticated — admin     | `dashboard`, `documentos`, `calendario`, `rangos`   |

Los guardan `hseq_tiene_rol` y `linea_efectiva`. El sistema es multi-línea:
`LAST_MILE` y `WAREHOUSE` no se ven entre sí.

### Páginas

| Archivo             | Para quién                                                 |
|---------------------|------------------------------------------------------------|
| `mensajero.html`    | El formulario del día                                       |
| `coordinador.html`  | Seguimiento del equipo a cargo                              |
| `admin.html`        | Configuración: calendario, documentos, rangos, formularios  |
| `dashboard.html`    | Indicadores y ranking                                       |
| `assets/api.js`     | Cliente: arma el payload y llama al router                  |
| `assets/asistente.js` | EVA, el asistente de ayuda                                |
| `db/*.sql`          | Un archivo por cambio, con el porqué arriba                 |

---

## Reglas que costaron caro

### 1. Nunca pegues una función SQL completa desde un archivo del repo

Los archivos de `db/` quedan atrás de producción. Pegar la función entera
**revierte cambios en silencio** — ya pasó dos veces. Una vez el archivo estaba
296 caracteres desactualizado y nadie lo notó hasta el otro día.

Parchea el cuerpo vivo, y que truene si el ancla no aparece:

```sql
do $do$
declare src text; nuevo text; nl text := chr(13) || chr(10);
begin
  select prosrc into src from pg_proc where proname = 'api_dashboard';
  if src is null then raise exception 'No existe api_dashboard'; end if;
  if position('mi_marca' in src) > 0 then
    raise notice 'Ya estaba puesto: no se toca.';
    return;
  end if;

  nuevo := replace(src, '<ancla exacta>', '<ancla>' || nl || '<lo nuevo>');
  if nuevo = src then raise exception 'No encontre donde tocar'; end if;

  execute 'create or replace function api_dashboard(payload jsonb default ''{}''::jsonb)'
       || ' returns jsonb language plpgsql security definer set search_path = public as '
       || quote_literal(nuevo);
end
$do$;
```

Cada script debe ser **idempotente** (el `position(...) > 0` de arriba) y traer
al final una sección de verificación que consulte datos reales.

**Saltos de línea:** las funciones creadas desde el MCP de Supabase tienen `\n`;
las viejas tienen `\r\n`. Si un `replace` no encaja, es casi siempre eso.
Confirma con `select position(chr(13) in prosrc) from pg_proc where proname=...`.

**Espacios:** para anclas con espaciado dudoso, usa `regexp_replace` con
`[[:space:]]+` en vez de `replace` literal.

### 2. Una variable que también es nombre de columna tumba la función

En `plpgsql`, si declaras `v_ciudad` y existe una columna `ciudad`, o peor, si
la variable se llama igual que la columna, la función revienta en producción.
Ya pasó dos veces. Revisa los nombres antes de aplicar.

### 3. Los scripts SQL van pegados en el chat

Completos, en bloque ```sql, para copiar y pegar en el SQL Editor de Supabase.
Nunca solo como archivo. Si pasa de ~300 líneas, córtalo en los límites de
función y manda varios bloques.

### 4. Verifica el push antes de decir que quedó publicado

```bash
git -c credential.helper=wincred push origin HEAD
git ls-remote --heads origin main
```

Si el push se cuelga: borra `.git/index.lock` y `.git/refs/heads/main.lock`, y
no lances dos pushes a la vez. `git ls-remote` es lectura y responde rápido
aunque la escritura esté trabada — sirve para confirmar.

Autor de los commits: `quickhelpai2026-star@users.noreply.github.com`
(la cuenta tiene el email privado; con otro email GitHub rechaza con GH007).

No preguntes antes de subir: se sube directo.

### 5. Sube el `?v=N` al tocar assets

`assets/api.js`, `assets/styles.css` y `assets/asistente.js` se cachean. Si
editas uno, sube el número en **todas** las páginas que lo cargan, o la gente
sigue viendo la versión vieja.

### 6. El service worker sirve páginas viejas al probar

En el navegador, antes de creerle a lo que ves:

```js
navigator.serviceWorker.getRegistrations().then(r => r.forEach(x => x.unregister()));
caches.keys().then(k => k.forEach(c => caches.delete(c)));
```

Y reinicia el servidor de preview.

### 7. Nada de heredocs de bash para contenido con acentos o comillas

Se corrompe. Usa la herramienta Write.

---

## Cómo trabajar

**Servidor local:** ya está en `.claude/launch.json` como `hseq-static`
(`python -m http.server 8731`). Arráncalo con la herramienta de preview, no con
Bash.

`admin.html` no tiene login propio: redirige a `coordinador.html`. Para probarlo
sin sesión, copia el archivo y neutraliza los dos redirects
(`location.replace('coordinador.html')` y `location.href = 'index.html'`).

**Validar antes de aplicar:**

```bash
python -c "import pglast,sys; pglast.parse_sql(open(sys.argv[1],encoding='utf-8').read()); print('ok')" db/mi_script.sql
node -e "new Function(require('fs').readFileSync('assets/api.js','utf8')); console.log('ok')"
```

**Editar HTML grande:** `mensajero.html` y `admin.html` pasan de 85 000 líneas.
Para varios cambios en un archivo, escribe un script de Python en el scratchpad
con un helper que exija exactamente una coincidencia:

```python
def cambiar(viejo, nuevo, que):
    global s
    n = s.count(viejo)
    if n != 1:
        raise SystemExit('%s: esperaba 1, encontre %d' % (que, n))
    s = s.replace(viejo, nuevo, 1)
```

Abre y guarda con `io.open(p, encoding='utf-8', newline='')` para no cambiar los
finales de línea.

**Commits:** mensaje en español, en una línea, que diga el efecto y no el
mecanismo. El estilo del repo es "Ningún registro se podía enviar: una compuerta
que ya no existía", no "fix: remove orphan reference".

---

## Conceptos del dominio

**Exigibilidad.** A una persona se le exige un formulario un día si: su
proyecto/ciudad opera ese día de la semana, no es festivo (o el proyecto sí
opera festivos), no tiene justificación vigente, el formulario aplica a su cargo
y la frecuencia le toca ese día. Es la regla central — `dias_exigibles`,
`registro_exigido`, `formularios_exigibles_dia`.

**Calendario por ciudad.** `proyectos_calendario` tiene llave
`(proyecto, ciudad)`. La fila de la ciudad manda sobre la del proyecto; la
ciudad sin fila propia hereda. Resuelve `calendario_de(proyecto, ciudad)`.

**Cumplimiento.** Numerador y denominador se cuentan contra el mismo conjunto
(`tmp_ok` en `api_dashboard`), así que no puede pasar del 100%. Si alguna vez
vuelve a pasar, es que se rompió esa invariante.

**Operan vs activos.** "Activos" es la nómina; "operan" es cuántos de esos
tienen algún día exigible en el rango filtrado. Un domingo pueden ser 70 de 274.

**Rangos de medición.** Cada pregunta de medición tiene `min_normal`/`max_normal`
(rango operativo, dispara desviación) y `min_valido`/`max_valido` (lo
físicamente posible, rechaza el guardado). Solo la cuenta global los edita, y
solo aplican al formulario de temperatura.

**Coma decimal.** `numero_limpio(text)` acepta `20,5` y `20.5` — toma el último
separador como decimal y guarda con punto. Cuidado con recortar ceros: `20` no
puede volverse `2`.

**Documentos.** Solo la preoperacional bloquea por documentos vencidos
(`formularios.recibe_documentos`); los demás avisan y dejan pasar. Los datos
escritos (VIN, placa) se pueden rechazar uno por uno, y el valor corregido tiene
que llegar distinto. El visto bueno se cae solo si el valor cambia después.

---

## Pendientes

- **`BLOQUEAR_DIA_NO_LABORAL` está en `true`.** Revisar primero el calendario de
  BACK UP DOMICILIOS · MEDELLÍN: registra 98 veces en 15 días distintos,
  incluso entre semana, y el bloqueo dejaría 8 personas trancadas cada día.
  Para apagarlo mientras se revisa:
  `update config set valor='false' where clave='BLOQUEAR_DIA_NO_LABORAL';`
- **Cruz Verde:** cargar qué ciudades trabajan domingos. La herramienta ya está
  en Configuración → Calendario → "Ajustar por ciudad".
- **Visto bueno:** marcar como revisado lo que hoy está en orden, para que la
  cola no arranque con 4 184 ítems.
