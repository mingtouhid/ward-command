const VERSION = "ward-sync-pwa-r2.0.0-44";
// R1.3.134: the on-device scanner engine lives in its own cache, filled and verified by the page; never deleted on update.
const OCR_CACHE = "ocr-assets-v7";
const PRECACHE = [
  "./",
  "./index.html",
  "./medical-banner-50px-v5.svg",
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
  const inner = data.data && typeof data.data === "object" ? data.data : {};
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
    data: {
      ...inner,
      url: notifAbs(data.url || inner.url || "./#/home")
    }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

function notifAbs(url){
  const scope = new URL(self.registration.scope);
  const fallback = new URL("./#/home", scope);
  try {
    const candidate = new URL(url || "./#/home", scope);
    const scopePath = scope.pathname.endsWith("/") ? scope.pathname : scope.pathname + "/";
    if (candidate.origin !== scope.origin || !candidate.pathname.startsWith(scopePath)) {
      return fallback.href;
    }
    candidate.username = "";
    candidate.password = "";
    return candidate.href;
  } catch (e) {
    return fallback.href;
  }
}

// The page's existing cold-start parser reads ?wn=... and decodes it once
// after URLSearchParams has performed its own query-string decoding.
function notifLaunchUrl(target, payload){
  try {
    const launch = new URL(target);
    launch.searchParams.set("wn", encodeURIComponent(JSON.stringify(payload)));
    return launch.href;
  } catch (e) {
    return target;
  }
}

function isWardAppClient(client, scope){
  if (!client || !client.url) return false;
  try {
    const url = new URL(client.url);
    const scopePath = scope.pathname.endsWith("/") ? scope.pathname : scope.pathname + "/";
    return url.origin === scope.origin && url.pathname.startsWith(scopePath);
  } catch (e) {
    return false;
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = (event.notification && event.notification.data) || {};
  const target = notifAbs(data.url || "./#/home");
  const payload = {
    id: data.notification_id || data.event_id || data.id || event.notification.tag || "",
    type: data.event_type || data.category || "",
    url: target,
    patient_id: data.patient_id || null,
    entity_id: data.task_id || data.handover_id || data.ect_plan_id || null,
    roster_id: data.roster_id || null,
    roster_type: data.roster_type || null,
    roster_version: data.roster_version || null,
    metadata: data.metadata || null
  };
  event.waitUntil((async () => {
    const scope = new URL(self.registration.scope);
    const clientsList = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const appClients = clientsList
      .filter((client) => isWardAppClient(client, scope))
      .sort((a, b) => {
        const score = (client) =>
          (client.focused ? 4 : 0) + (client.visibilityState === "visible" ? 2 : 0);
        return score(b) - score(a);
      });

    // Reuse the focused/visible Ward Sync window. Do not navigate it directly:
    // the app's ward-notif handler persists the payload and applies role-aware routing.
    for (const client of appClients) {
      try { await client.focus(); } catch (e) {}
      try {
        client.postMessage({ type: "ward-notif", payload });
        return;
      } catch (e) {
        // Try another in-scope app window before opening a fresh one.
      }
    }

    // A cold launch must carry the same structured data as a live-window click.
    if (self.clients.openWindow) {
      await self.clients.openWindow(notifLaunchUrl(target, payload));
    }
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
