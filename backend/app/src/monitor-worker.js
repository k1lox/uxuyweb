// No fetch handler or cache: trading pages, API responses and keys never enter a service-worker cache.
self.addEventListener("install", event => event.waitUntil(self.skipWaiting()));
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("push", event => {
  event.waitUntil((async () => {
    let payload;
    try { payload = event.data.json(); } catch { return; }
    if (!payload || typeof payload.id !== "string" || typeof payload.title !== "string"
      || typeof payload.body !== "string" || !Number.isFinite(payload.expiresAt)
      || payload.expiresAt <= Date.now() || payload.expiresAt > Date.now() + 35000) return;
    const tag = "monitor-" + payload.id.slice(0, 100);
    if ((await self.registration.getNotifications({ tag })).length) return;
    await self.registration.showNotification(payload.title.slice(0, 120), {
      body: payload.body.slice(0, 240), tag, silent: false,
      icon: "/icons/Icon-192.png", badge: "/icons/Icon-192.png",
      data: { url: "/monitor/" },
    });
  })());
});
self.addEventListener("notificationclick", event => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing = windows.find(client => new URL(client.url).origin === self.location.origin && new URL(client.url).pathname === "/monitor/");
    if (existing) await existing.focus();
    else await self.clients.openWindow("/monitor/");
  })());
});
