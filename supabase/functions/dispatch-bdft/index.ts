// Ward Sync R1.8 dispatch-bdft
// Sends only bed-distribution device rows claimed by ward_bdft_claim_delivery.
// A live ward session is required. A service bearer is not accepted.
// ward_dispatch_anon_key is not read or created.
//
// When VAPID or FCM environment is absent, this returns deferred and does not claim.
// Those variables are the same ones already used by dispatch-notification.
// This file does not create them.
//
// No pg_cron job calls this function. The publishing phone calls it with the
// resident session. Unattended retry needs an operator-approved schedule that
// can present an eligible resident session. Do not add a service-role cron.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";
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
  const result = await runBdftDispatch({
    body,
    providerConfigured: configured,
    claim: async (token, id) => {
      const res = await admin.rpc("ward_bdft_claim_delivery", { p_token: token, p_notification_id: id });
      if (res.error) return { error: res.error.message };
      return res.data || { claimed: false };
    },
    apply: async (token, deliveryId, resultName, errorText) => {
      const res = await admin.rpc("ward_bdft_apply_provider", {
        p_token: token, p_delivery_id: deliveryId, p_result: resultName, p_error: errorText,
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
