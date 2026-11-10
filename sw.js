/* CARCOVE · Service Worker mínimo para la PWA.
 *
 * Política: SOLO RED, SIN CACHÉ.
 * - No usa Cache Storage ni IndexedDB: no guarda páginas, sesiones, credenciales
 *   ni respuestas de Supabase.
 * - Solo atiende la navegación del propio sitio (abrir/recargar la app) y la pasa
 *   directo a la red. Si no hay internet, muestra un aviso en lugar de la página
 *   de error del navegador.
 * - Todo lo demás (Supabase, CDN, imágenes, scripts) NO pasa por aquí: el
 *   navegador lo resuelve exactamente igual que sin Service Worker.
 *
 * Para desactivarlo en el futuro: reemplazar este archivo por uno que llame a
 * self.registration.unregister() en el evento "activate".
 */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

const OFFLINE_HTML = '<!doctype html><html lang="es"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">' +
  '<meta name="theme-color" content="#c8203a"><title>CARCOVE | Sin conexión</title>' +
  '<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;' +
  'background:#f3f4f7;font:15px/1.5 Inter,"Segoe UI",system-ui,-apple-system,Roboto,Arial,sans-serif;color:#16151a;padding:24px}' +
  '.b{background:#fff;border:1px solid #e4e2e8;border-radius:16px;padding:28px;max-width:420px;text-align:center}' +
  'h1{font-size:19px;margin:0 0 8px;color:#901028}button{margin-top:16px;border:0;border-radius:10px;padding:11px 18px;' +
  'font:inherit;font-weight:600;background:#c8203a;color:#fff;cursor:pointer}</style></head><body><div class="b">' +
  '<h1>Sin conexión a internet</h1><p>CARCOVE necesita internet para funcionar. Revisa tu conexión e inténtalo de nuevo.</p>' +
  '<button onclick="location.reload()">Reintentar</button></div></body></html>';

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.mode !== 'navigate') return; // no interviene: Supabase, CDN y recursos van directo a la red
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith(
    fetch(req).catch(() => new Response(OFFLINE_HTML, {
      status: 503,
      headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }
    }))
  );
});
