/* ============================================================
   CONFIGURACIÓN — Gestión HSEQ Motos
   ------------------------------------------------------------
   👉 SOLO tienes que editar la línea API_URL.
   Pega aquí la URL que termina en /exec de tu despliegue de
   Apps Script (Implementar > Administrar implementaciones).

   Si la dejas con el texto PEGUE_AQUI, las páginas funcionan
   en modo DEMO (datos de ejemplo, no guarda nada real).
   ============================================================ */
window.HSQ_CONFIG = {
  API_URL: 'https://script.google.com/macros/s/AKfycbyDhvIfqO6kY4uwqL4aiTLEZe2pdaiV-mFwpZ3ytzV5TjQvJUhrPMSNoJtPNT948pYl7w/exec',
  APP_NAME: 'Gestión HSEQ Motos',
  SUBTITLE: 'Registro operativo de motos',

  // 🔒 PIN para entrar a la página del Coordinador (exportables).
  // Cámbialo por el que quieras. Déjalo en '' (vacío) para desactivar el PIN.
  COORD_PIN: '1234',

  // ── Migración a base de datos (Supabase) ──────────────────
  // La app sigue usando Apps Script por defecto. Para PROBAR la versión
  // con base de datos, agrega ?db=1 al final del link (ej:
  // mensajero.html?db=1). Producción no se afecta.
  SUPABASE_URL: 'https://scemoysbcgwxajgoybwc.supabase.co',
  // Llave anon "legacy" (JWT). Storage la acepta para subir evidencias.
  SUPABASE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNjZW1veXNiY2d3eGFqZ295YndjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxNTY1MzUsImV4cCI6MjEwMDczMjUzNX0.yqxM8PUc4FeCAcbxjEXimMVFj_0shpmPPjbO7d3ALFo',
};
