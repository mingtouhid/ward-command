// R1.8 BDFT delivery loop. No network calls live in this file.
// index.ts supplies Web Push, FCM HTTP, and the database.

const ELIGIBLE = new Set(["resident", "admin", "sr"]);

export function providerFailureClass(err) {
  const message = String(err && err.message || err || "");
  const code = Number(err && (err.statusCode || err.status) || 0);
  if (code === 404 || code === 410) return "permanent";
  if (/NOT_FOUND|UNREGISTERED|InvalidRegistration|NotRegistered/i.test(message)) return "permanent";
  return "transient";
}

function b64url(bytes) {
  const text = typeof bytes === "string" ? bytes : String.fromCharCode(...new Uint8Array(bytes));
  return btoa(text).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function mintGoogleAccessToken(fetchImpl, sa, cryptoSubtle) {
  const subtle = cryptoSubtle || globalThis.crypto.subtle;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const now = Math.floor(Date.now() / 1000);
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = String(sa.private_key || "").replace(/\\n/g, "\n");
  const body = pem.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "").replace(/\s+/g, "");
  const keyData = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await subtle.importKey("pkcs8", keyData, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claim}`));
  const res = await fetchImpl("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${claim}.${b64url(sig)}` }),
  });
  const json = await res.json();
  if (!res.ok || !json.access_token) throw new Error(json.error_description || "Failed to mint FCM access token");
  return json.access_token;
}

export async function sendFcmHttpV1(fetchImpl, projectId, accessToken, deviceToken, title, body, data) {
  const res = await fetchImpl(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        token: deviceToken,
        notification: { title, body },
        data,
        android: { priority: "HIGH", notification: { channel_id: data.category || "clinical" } },
      },
    }),
  });
  const text = await res.text();
  if (!res.ok) {
    const error = new Error(`FCM v1 ${res.status}: ${text}`);
    error.statusCode = res.status;
    throw error;
  }
  return text;
}

export async function sendFcmLegacy(fetchImpl, serverKey, deviceToken, title, body, data) {
  const res = await fetchImpl("https://fcm.googleapis.com/fcm/send", {
    method: "POST",
    headers: { Authorization: `key=${serverKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ to: deviceToken, priority: "high", notification: { title, body }, data }),
  });
  const json = await res.json();
  if (!res.ok || json.failure) {
    const error = new Error(`FCM legacy failed: ${JSON.stringify(json)}`);
    error.statusCode = res.status;
    throw error;
  }
  return json;
}

function messageData(claim) {
  return {
    title: String(claim.title || ""),
    body: String(claim.body || ""),
    tag: String(claim.tag || ""),
    url: String(claim.targetUrl || ""),
    notification_id: String(claim.notificationId || ""),
    event_type: "bdft",
    category: "clinical",
  };
}

export function serviceKeyFromEnv(env) {
  try {
    const parsed = JSON.parse(String(env && env.SUPABASE_SECRET_KEYS || ""));
    return String(parsed.default || "");
  } catch (e) {
    return "";
  }
}

function sameSecret(left, right) {
  const a = String(left || "");
  const b = String(right || "");
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function authorizeBdftRequest({ authorization, apikey, body, env }) {
  const bearer = String(authorization || "").replace(/^Bearer\s+/i, "");
  const key = serviceKeyFromEnv(env);
  const isService = !!key && (sameSecret(bearer, key) || sameSecret(apikey, key));
  const session = body && body.session_token ? String(body.session_token) : "";
  if (body && body.event_type && body.event_type !== "bdft") {
    return { ok: false, status: 403, error: "This worker only sends bed distribution" };
  }
  if (body && body.recipient_scope && body.recipient_scope !== "bdft_residents") {
    return { ok: false, status: 403, error: "This worker only sends bed distribution" };
  }
  if (isService && session) {
    return { ok: false, status: 400, error: "A service retry cannot carry a resident session" };
  }
  if (isService) {
    return { ok: true, mode: "service" };
  }
  if (session) {
    if (!body.notification_id) return { ok: false, status: 400, error: "notification_id is required" };
    return { ok: true, mode: "resident", sessionToken: session, notificationId: String(body.notification_id) };
  }
  return { ok: false, status: 401, error: "authentication required" };
}

export async function runBdftDispatch(ctx) {
  const auth = authorizeBdftRequest({
    authorization: ctx.authorization, apikey: ctx.apikey, body: ctx.body || {}, env: ctx.env || {},
  });
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };
  if (!ctx.providerConfigured()) {
    return { status: 200, body: { ok: true, dispatch: "deferred", reason: "provider not configured" } };
  }
  let notificationId = null;
  if (auth.mode === "resident") {
    const scope = await ctx.scope(auth.sessionToken, auth.notificationId);
    if (!scope || scope.ok !== true) {
      return { status: 403, body: { ok: false, error: (scope && scope.error) || "not allowed to dispatch this notice" } };
    }
    notificationId = auth.notificationId;
  }
  let sent = 0;
  let failed = 0;
  let stopped = 0;
  for (let n = 0; n < 50; n++) {
    const claim = await ctx.claim(notificationId);
    if (claim && claim.error) return { status: 403, body: { ok: false, error: claim.error } };
    if (!claim || !claim.claimed) {
      return { status: 200, body: { ok: true, dispatch: sent || failed || stopped ? "done" : "idle", mode: auth.mode, sent, failed, stopped } };
    }
    const role = String(claim.role || "").toLowerCase();
    const data = messageData(claim);
    if (!ELIGIBLE.has(role) || claim.clinicalAlerts === false || (claim.eventType && claim.eventType !== "bdft") || !data.tag.startsWith("bdft:") || !data.url.includes("/bdft/")) {
      await ctx.apply(claim.deliveryId, "permanent", "recipient or link is not eligible for bed distribution");
      stopped++;
      continue;
    }
    try {
      const target = await ctx.loadTarget(claim);
      if (!target) {
        const missing = new Error("device record missing");
        missing.permanent = true;
        throw missing;
      }
      if (target.kind === "webpush") await ctx.sendWebPush(target, data);
      else if (target.kind === "fcm") await ctx.sendFcm(target, data);
      else throw new Error("unknown device");
      await ctx.apply(claim.deliveryId, "sent", null);
      sent++;
    } catch (err) {
      const kind = err && err.permanent ? "permanent" : providerFailureClass(err);
      await ctx.apply(claim.deliveryId, kind, String(err && err.message || err));
      if (kind === "permanent") stopped++;
      else failed++;
    }
  }
  return { status: 200, body: { ok: true, dispatch: "partial", mode: auth.mode, sent, failed, stopped } };
}
