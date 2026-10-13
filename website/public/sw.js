// Installable browser companion. Account/API/media responses are never cached.
// Network-only operation avoids serving stale quotas or another user's account.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  if (event.request.mode === 'navigate' && new URL(event.request.url).pathname === '/studio') {
    event.respondWith(fetch(event.request).catch(() => new Response('<!doctype html><title>Focus Studio</title><body style="font:18px system-ui;padding:50px;background:#131318;color:#eeeee9"><h1>You’re offline.</h1><p>Reconnect to open Browser Studio. Recordings are not uploaded to our server.</p><a style="color:#ab95ff" href="/studio">Try again</a></body>', {headers:{'Content-Type':'text/html; charset=utf-8'}})));
  }
});
