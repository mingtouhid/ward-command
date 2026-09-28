const VERSION = "ward-sync-pwa-r1.3.29-notify-setup";
const PRECACHE = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "./apple-touch-icon.png",
  "./favicon-32.png",
  "./icons/badge-96.png",
  "./icons/icon-notif-192.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(VERSION).then(async (cache) => {
      await Promise.all(
        PRECACHE.map((url) => cache.add(url).catch(() => {}))
      );
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});


self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { body: event.data ? event.data.text() : "New Ward Command notification." }; }
  const title = data.title || "Ward Command";
  const options = {
    body: data.body || "You have a new ward notification.",
    icon: data.icon || "./icons/icon-notif-192.png",
    badge: data.badge || "./icons/badge-96.png",
    tag: data.tag || "ward-command",
    renotify: !!data.renotify,
    requireInteraction: !!data.requireInteraction,
    data: { url: data.url || "/#/home", ...(data.data || {}) }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = event.notification.data && event.notification.data.url || "/#/home";
  event.waitUntil((async () => {
    const clientsList = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of clientsList) {
      if ("focus" in client) {
        try { await client.navigate(target); } catch (e) {}
        return client.focus();
      }
    }
    if (self.clients.openWindow) return self.clients.openWindow(target);
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  const isAppShell =
    url.origin === self.location.origin &&
    (url.pathname.endsWith("/") ||
      url.pathname.endsWith("/index.html") ||
      url.pathname.endsWith("/manifest.json") ||
      url.pathname.includes("/icons/") ||
      url.pathname.endsWith("/icon-192.png") ||
      url.pathname.endsWith("/icon-512.png"));

  const isSupabase =
    url.hostname.endsWith("supabase.co") ||
    url.hostname.endsWith("supabase.in");

  if (isSupabase) return; // live API + realtime — never cache

  if (isAppShell) {
    event.respondWith(networkFirst(req));
    return;
  }

  if (url.origin !== self.location.origin) {
    event.respondWith(staleWhileRevalidate(req));
    return;
  }

  event.respondWith(networkFirst(req));
});

async function networkFirst(req) {
  const cache = await caches.open(VERSION);
  try {
    const fresh = await fetch(req);
    if (fresh && fresh.ok) cache.put(req, fresh.clone());
    return fresh;
  } catch (err) {
    const cached = await cache.match(req);
    if (cached) return cached;
    if (req.mode === "navigate") {
      const fallback = await cache.match("./index.html") || await cache.match("index.html");
      if (fallback) return fallback;
    }
    throw err;
  }
}

async function staleWhileRevalidate(req) {
  const cache = await caches.open(VERSION);
  const cached = await cache.match(req);
  const pending = fetch(req)
    .then((res) => {
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    })
    .catch(() => cached);
  return cached || pending;
}
