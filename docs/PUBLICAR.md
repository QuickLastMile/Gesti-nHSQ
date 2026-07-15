# Cómo publicar la app (paso a paso)

Son 3 bloques: **backend** (Apps Script), **conectar** (config.js) y **publicar** (GitHub Pages). Solo hay que hacerlo una vez.

---

## 1) Backend: desplegar el Apps Script como API

1. Abre el Google Sheets administrador → **Extensiones → Apps Script**.
2. En el archivo `Code.gs`, pega el contenido de `apps-script/Code.gs` de este repo (reemplaza lo que haya).
3. Si tenías un archivo HTML llamado `Index`, ya **no se necesita**: puedes borrarlo.
4. Abre el manifiesto (icono ⚙️ *Configuración del proyecto* → marca "Mostrar `appsscript.json`") y pega el contenido de `apps-script/appsscript.json`. Lo importante es que quede:
   ```json
   "webapp": { "executeAs": "USER_DEPLOYING", "access": "ANYONE_ANONYMOUS" }
   ```
5. Guarda. Ejecuta una vez la función `verificarConfiguracion` para autorizar permisos (acepta los permisos de Google).
6. **Implementar → Nueva implementación → Aplicación web**:
   - *Ejecutar como:* **Yo** (tu cuenta).
   - *Quién tiene acceso:* **Cualquier persona**.
   - Implementar.
7. Copia la **URL que termina en `/exec`**.

> Nota de seguridad: "Cualquier persona" significa que el endpoint es público. El control real lo da la cédula: solo se puede registrar quien esté **activo** en `Matriz_Activos`. Como el frontend ya no vive en Apps Script, el aviso de Google desaparece.

### Si ya tenías un despliegue anterior
Para conservar la **misma URL**: ve a **Implementar → Administrar implementaciones**, edita el existente, elige **Nueva versión**, ajusta el acceso a "Cualquier persona" e implementa. Si creas uno nuevo, la URL cambia (y hay que actualizar el paso 2).

---

## 2) Conectar el frontend con el backend

1. Abre `assets/config.js`.
2. Reemplaza el valor de `API_URL` por tu URL `/exec` del paso anterior:
   ```js
   window.HSQ_CONFIG = {
     API_URL: 'https://script.google.com/macros/s/XXXXXXXX/exec',
     ...
   };
   ```
3. Guarda.

Mientras diga `PEGUE_AQUI`, las páginas quedan en **modo demostración**.

---

## 3) Publicar en GitHub Pages

1. Sube los cambios al repositorio (`git add . && git commit && git push`).
2. En GitHub: **Settings → Pages**.
3. En *Build and deployment* → *Source*: **Deploy from a branch**.
4. Rama: **main**, carpeta: **/ (root)**. Guarda.
5. Espera 1–2 minutos. Tu sitio queda en:
   - `https://quicklastmile.github.io/Gesti-nHSQ/`

Comparte con los mensajeros el link de `mensajero.html` y con los coordinadores el de `coordinador.html`.

---

## Probar que quedó bien

- Abre el link del mensajero en el celular.
- Digita una cédula que esté **activa** en `Matriz_Activos` → debe aparecer el nombre.
- Elige un formulario, responde y guarda → debe decir "Registro guardado".
- Revisa en Drive que se creó la carpeta del día con el registro y la evidencia.

## Errores comunes

- **"El servidor respondió en un formato inesperado"** → el Apps Script no está desplegado con acceso "Cualquier persona", o la `API_URL` es de un despliegue viejo. Repite el paso 1 y 2.
- **No aparece nadie al buscar** → la cédula no está en `Matriz_Activos` o está inactiva.
- **La página se ve sin estilos** → GitHub Pages tarda un par de minutos la primera vez; recarga con caché limpia.
