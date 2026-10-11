// Served at the old worker URL so previously controlled clients can migrate.
// No fetch listener: all requests go to the network.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    await Promise.all(['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest']
      .map((name) => caches.delete(name)));
    await self.registration.unregister();
    const clients = await self.clients.matchAll({type: 'window'});
    await Promise.all(clients.map((client) => client.navigate(client.url)));
  })());
});
