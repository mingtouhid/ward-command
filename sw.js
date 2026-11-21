const VERSION = "ward-sync-pwa-r2.0.0-17";
// R1.3.134: the on-device scanner engine lives in its own cache, filled and verified by the page; never deleted on update.
const OCR_CACHE = "ocr-assets-v7";
const PRECACHE = [
  "./",
  "./index.html",
  "./medical-banner-60s.svg",
  "./ward-sync-session-loader.svg",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-180.png",
  "./favicon-16.png",
  "./apple-touch-icon.png",
  "./favicon-32.png",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-180.png",
  "./icons/favicon-16.png",
  "./icons/icon-192-maskable.png",
  "./icons/icon-512-maskable.png",
  "./icons/apple-touch-icon.png",
  "./icons/favicon-32.png",
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
      Promise.all(keys.filter((k) => k !== VERSION && k !== OCR_CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});


self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { body: event.data ? event.data.text() : "New Ward Command notification." }; }
  const title = data.title || "Ward Command";
  const inner = data.data || {};
  const priority = String(data.priority || inner.priority || "normal").toLowerCase();
  const providedTag = data.tag || data.dedupe_key || inner.dedupe_key || data.event_id || inner.notification_id;
  const tag = providedTag ? String(providedTag) : ("wc-" + Date.now());
  const options = {
    body: data.body || "You have a new ward notification.",
    icon: data.icon || "./icons/icon-notif-192.png",
    badge: data.badge || "./icons/badge-96.png",
    tag,
    renotify: providedTag ? true : !!data.renotify,
    vibrate: priority === "high" ? [200, 100, 200] : [120],
    requireInteraction: !!data.requireInteraction,
    data: { url: data.url || "/#/home", ...(data.data || {}) }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

function notifAbs(url){
  try { return new URL(url || "/#/home", self.registration.scope).href; }
  catch (e) { return new URL("/#/home", self.registration.scope).href; }
}
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = (event.notification && event.notification.data) || {};
  const target = notifAbs(data.url || "/#/home");
  const payload = {
    id: data.notification_id || data.event_id || data.id || event.notification.tag || "",
    type: data.event_type || data.category || "",
    url: target,
    patient_id: data.patient_id || null,
    entity_id: data.task_id || data.handover_id || data.ect_plan_id || null
  };
  event.waitUntil((async () => {
    const clientsList = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const client = clientsList.find((c) => c && "focus" in c);
    if (client) {
      try { await client.focus(); } catch (e) {}
      try { client.postMessage({ type: "ward-notif", payload }); } catch (e) {}
      return;
    }
    if (self.clients.openWindow) await self.clients.openWindow(target);
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
  // scanner engine files: the page downloads them itself (with progress + integrity check) into OCR_CACHE
  if (url.origin === self.location.origin && url.pathname.startsWith("/ocr/")) return;

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
  const isNav = req.mode === "navigate";
  try {
    const fresh = await Promise.race([
      fetch(req),
      new Promise((_, reject) => setTimeout(() => reject(new Error("nav-timeout")), isNav ? 4000 : 12000))
    ]);
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
