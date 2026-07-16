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
};
