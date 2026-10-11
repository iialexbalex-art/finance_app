{{flutter_js}}
{{flutter_build_config}}

(async () => {
  // Retire only Flutter's worker/caches, preserving Supabase sessions and journals.
  const isFlutterWorker = (worker) => worker &&
    new URL(worker.scriptURL).origin === location.origin &&
    new URL(worker.scriptURL).pathname === '/flutter_service_worker.js';
  if ('serviceWorker' in navigator) {
    try {
      const controlled = isFlutterWorker(navigator.serviceWorker.controller);
      const registrations = await navigator.serviceWorker.getRegistrations();
      for (const registration of registrations) {
        if ([registration.active, registration.waiting, registration.installing].some(isFlutterWorker)) {
          await registration.unregister();
        }
      }
      if ('caches' in window) {
        await Promise.all(['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest']
          .map((name) => caches.delete(name)));
      }
      if (controlled) {
        location.reload();
        return;
      }
    } catch (error) {
      console.warn('Could not retire the previous Flutter offline cache', error);
    }
  }
  // No serviceWorkerSettings: new installations never register an offline worker.
  _flutter.loader.load();
})();
