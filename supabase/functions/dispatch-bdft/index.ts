// Ward Sync R1.8 dispatch-bdft
// Sends only rows from the bed-distribution outbox.
// A schedule authenticates with the dedicated Vault credential. The header is
// checked by ward_bdft_cron_ok and is not logged. A resident session may ask
// for immediate delivery of one bed-distribution notice. The claim still runs
// as the service role inside this function.
// The clinical dispatcher is a different function and is not changed here.

import { createClient } from "@supabase/supabase-js";
import webpush from "npm:web-push";
import { mintGoogleAccessToken, runBdftDispatch, sendFcmHttpV1, sendFcmLegacy } from "./worker.mjs";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function configured() {
  return !!(
    Deno.env.get("VAPID_PUBLIC_KEY") &&
    Deno.env.get("VAPID_PRIVATE_KEY") &&
    Deno.env.get("VAPID_SUBJECT")
  ) || !!Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || !!Deno.env.get("FCM_SERVER_KEY");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const body = await req.json().catch(() => ({}));
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const secretRing = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  if (configured() && (!supabaseUrl || !secretRing)) {
    return json({ ok: true, dispatch: "deferred", reason: "database role is not configured" });
  }
  const admin = configured()
    ? createClient(supabaseUrl, JSON.parse(secretRing).default, { auth: { persistSession: false, autoRefreshToken: false } })
    : null;
  const cronPresented = Boolean(req.headers.get("x-ward-bdft-secret"));
  let cronOk = false;
  if (cronPresented && admin) {
    const check = await admin.rpc("ward_bdft_cron_ok", { p_secret: req.headers.get("x-ward-bdft-secret") });
    cronOk = check.data === true;
  }
  const result = await runBdftDispatch({
    body,
    cronPresented,
    cronOk,
    providerConfigured: configured,
    scope: async (token, id) => {
      const res = await admin.rpc("ward_bdft_dispatch_scope", { p_token: token, p_notification_id: id });
      if (res.error) return { ok: false, error: res.error.message };
      return res.data || { ok: false };
    },
    claim: async (id) => {
      const res = await admin.rpc("ward_bdft_service_claim", { p_notification_id: id });
      if (res.error) return { error: res.error.message };
      return res.data || { claimed: false };
    },
    apply: async (deliveryId, resultName, errorText) => {
      const res = await admin.rpc("ward_bdft_service_apply", {
        p_delivery_id: deliveryId, p_result: resultName, p_error: errorText,
      });
      if (res.error) throw new Error(res.error.message);
    },
    loadTarget: async (claim) => {
      if (claim.subscriptionId) {
        const res = await admin.from("push_subscriptions").select("endpoint,p256dh,auth").eq("id", claim.subscriptionId).maybeSingle();
        if (res.error) throw new Error(res.error.message);
        if (!res.data?.endpoint) return null;
        return { kind: "webpush", endpoint: res.data.endpoint, keys: { p256dh: res.data.p256dh, auth: res.data.auth } };
      }
      if (claim.fcmTokenId) {
        const res = await admin.from("fcm_device_tokens").select("token").eq("id", claim.fcmTokenId).maybeSingle();
        if (res.error) throw new Error(res.error.message);
        if (!res.data?.token) return null;
        return { kind: "fcm", token: res.data.token };
      }
      return null;
    },
    sendWebPush: async (target, data) => {
      webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT"), Deno.env.get("VAPID_PUBLIC_KEY"), Deno.env.get("VAPID_PRIVATE_KEY"));
      await webpush.sendNotification(
        { endpoint: target.endpoint, keys: target.keys },
        JSON.stringify({ title: data.title, body: data.body, tag: data.tag, data: { url: data.url, notification_id: data.notification_id, event_type: "bdft" } }),
      );
    },
    sendFcm: async (target, data) => {
      const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "";
      if (raw) {
        const sa = JSON.parse(raw);
        const accessToken = await mintGoogleAccessToken(fetch, sa);
        return sendFcmHttpV1(fetch, String(sa.project_id || ""), accessToken, target.token, data.title, data.body, data);
      }
      const serverKey = Deno.env.get("FCM_SERVER_KEY") || "";
      if (!serverKey) throw new Error("FCM not configured");
      return sendFcmLegacy(fetch, serverKey, target.token, data.title, data.body, data);
    },
  });
  return json(result.body, result.status);
});
