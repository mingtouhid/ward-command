import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SECRET_KEYS = Deno.env.get("SUPABASE_SECRET_KEYS")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT")!;
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "";
const FCM_SERVER_KEY = Deno.env.get("FCM_SERVER_KEY") || "";

const serviceKey = JSON.parse(SUPABASE_SECRET_KEYS).default;
const admin = createClient(SUPABASE_URL, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function getGoogleAccessToken(sa: Record<string, unknown>): Promise<string> {
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const now = Math.floor(Date.now() / 1000);
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const payload = btoa(JSON.stringify(claim))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const unsigned = `${header}.${payload}`;

  const pem = String(sa.private_key).replace(/\\n/g, "\n");
  const pemBody = pem.replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "").replace(/\s+/g, "");
  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const jwt = `${unsigned}.${sig}`;

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const tokenJson = await tokenRes.json();
  if (!tokenRes.ok || !tokenJson.access_token) {
    throw new Error(tokenJson.error_description || "Failed to mint FCM access token");
  }
  return tokenJson.access_token as string;
}

async function sendFcmHttpV1(
  projectId: string,
  accessToken: string,
  deviceToken: string,
  title: string,
  body: string,
  data: Record<string, string>,
) {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: deviceToken,
          notification: { title, body },
          data,
          android: {
            priority: "HIGH",
            notification: { channel_id: data.category || "general" },
          },
        },
      }),
    },
  );
  const text = await res.text();
  if (!res.ok) throw new Error(`FCM v1 ${res.status}: ${text}`);
  return text;
}

async function sendFcmLegacy(serverKey: string, deviceToken: string, title: string, body: string, data: Record<string, string>) {
  const res = await fetch("https://fcm.googleapis.com/fcm/send", {
    method: "POST",
    headers: {
      Authorization: `key=${serverKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      to: deviceToken,
      priority: "high",
      notification: { title, body },
      data,
    }),
  });
  const jsonBody = await res.json();
  if (!res.ok || jsonBody.failure) {
    throw new Error(`FCM legacy failed: ${JSON.stringify(jsonBody)}`);
  }
  return jsonBody;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const notificationId = body?.notification_id;
    const sessionToken = body?.session_token;
    const officeAdminToken = body?.office_admin_token;
    // v7: server-side callers (monthly-archive) authenticate with the service/secret key and
    // may ONLY dispatch events whose recipient_scope is 'admins'.
    const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const apikeyHeader = req.headers.get("apikey") || "";
    const isService = !sessionToken && !officeAdminToken && !!serviceKey && (bearer === serviceKey || apikeyHeader === serviceKey);

    if (!notificationId || (!sessionToken && !officeAdminToken && !isService)) {
      return json({ ok: false, error: "notification_id and an authorised session are required" }, 400);
    }

    let session: { resident_id: string } | null = null;
    let officeAdminAuthorized = false;
    if (!isService && !sessionToken && officeAdminToken) {
      const { data, error: officeAdminError } = await admin.rpc("office_admin_authorize_roster_notification", {
        p_token: officeAdminToken,
        p_notification_id: notificationId,
      });
      if (officeAdminError) throw officeAdminError;
      if (!data || data.ok !== true) return json({ ok: false, error: "Office Administration session is not authorised for this roster notification" }, 401);
      officeAdminAuthorized = true;
    } else if (!isService) {
      const { data, error: sessionError } = await admin
        .from("ward_sessions")
        .select("token,resident_id,expires_at")
        .eq("token", sessionToken)
        .gt("expires_at", new Date().toISOString())
        .maybeSingle();
      if (sessionError) throw sessionError;
      if (!data) return json({ ok: false, error: "Invalid or expired ward session" }, 401);
      session = data;
    }

    const { data: event, error: eventError } = await admin
      .from("notification_events")
      .select("*")
      .eq("id", notificationId)
      .maybeSingle();
    if (eventError) throw eventError;
    if (!event) return json({ ok: false, error: "Notification event not found" }, 404);
    if (isService && event.recipient_scope !== "admins") {
      return json({ ok: false, error: "Service dispatch is limited to admin events" }, 403);
    }
    if (!isService && event.recipient_scope === "admins") {
      return json({ ok: false, error: "Admin events are dispatched by the server" }, 403);
    }
    if (officeAdminAuthorized && (event.event_type !== "roster_publish" || !["roster_residents", "roster_consultants"].includes(event.recipient_scope))) {
      return json({ ok: false, error: "Office Administration sessions may dispatch roster notifications only" }, 403);
    }
    if (session && event.actor_id && event.actor_id !== session.resident_id) {
      return json({ ok: false, error: "Session is not authorized to dispatch this event" }, 403);
    }

    let recipientIds: string[] = [];
    if (event.recipient_scope === "admins") {
      const { data, error } = await admin.from("residents").select("id,role").eq("active", true);
      if (error) throw error;
      recipientIds = (data ?? []).filter((r) => String(r.role || "").toLowerCase() === "admin").map((r) => r.id);
    } else if (event.recipient_scope === "roster_residents" || event.recipient_scope === "roster_consultants") {
      const { data, error } = await admin.from("residents").select("id,role").eq("active", true);
      if (error) throw error;
      const eligibleRoles = event.recipient_scope === "roster_consultants"
        ? new Set(["consultant"])
        // The existing Ward Sync permission model intentionally gives admin accounts
        // resident permissions; office_admin is a separate, non-clinical role.
        : new Set(["resident", "admin"]);
      recipientIds = (data ?? [])
        .filter((r) => eligibleRoles.has(String(r.role || "").toLowerCase()))
        .map((r) => r.id);
    } else if (event.recipient_scope === "active_team") {
      const { data, error } = await admin.from("residents").select("id").eq("active", true);
      if (error) throw error;
      recipientIds = (data ?? []).map((r) => r.id);
    } else if (event.recipient_scope === "task_assignees") {
      if (!event.task_id) return json({ ok: false, error: "Task notification has no task_id" }, 400);
      const { data: task, error } = await admin.from("tasks").select("assigned_to").eq("id", event.task_id).maybeSingle();
      if (error) throw error;
      if (task?.assigned_to) recipientIds = [task.assigned_to];
    } else if (event.recipient_scope === "handover") {
      if (!event.handover_id) return json({ ok: false, error: "Handover notification has no handover_id" }, 400);
      const { data: handover, error } = await admin.from("handovers").select("from_id,to_id").eq("id", event.handover_id).maybeSingle();
      if (error) throw error;
      if (handover?.to_id && handover.to_id !== handover.from_id) {
        const { data: recipient } = await admin.from("residents").select("id").eq("id", handover.to_id).eq("active", true).maybeSingle();
        if (recipient) recipientIds = [recipient.id];
      } else if (handover && !handover.to_id) {
        // R1.6: shift-targeted handover. Whoever signs in for that shift takes it, so tell every active
        // resident/admin (not interns, not view-only consultants) except the sender.
        const { data, error: teamError } = await admin.from("residents").select("id,role").eq("active", true);
        if (teamError) throw teamError;
        recipientIds = (data ?? [])
          .filter((r) => r.id !== handover.from_id && r.role !== "intern" && r.role !== "consultant")
          .map((r) => r.id);
      }
    }

    if (!recipientIds.length) {
      return json({ ok: true, notification_id: notificationId, recipients: 0, deliveries_created: 0, sent: 0, failed: 0, fcm_sent: 0, fcm_failed: 0, message: "No eligible recipients" });
    }

    const { data: preferences, error: preferenceError } = await admin
      .from("notification_preferences")
      .select("*")
      .in("resident_id", recipientIds);
    if (preferenceError) throw preferenceError;
    const preferenceMap = new Map((preferences ?? []).map((p) => [p.resident_id, p]));
    recipientIds = recipientIds.filter((residentId) => {
      const pref = preferenceMap.get(residentId);
      if (!pref) return true;
      if (event.category === "clinical") return pref.clinical_alerts;
      if (event.category === "handovers") return pref.handovers;
      if (event.category === "tasks") return pref.tasks;
      if (event.category === "ect") return pref.ect;
      if (event.category === "archive") return true; // failure alerts are not optional
      return true;
    });

    const { data: subscriptions, error: subscriptionError } = await admin
      .from("push_subscriptions")
      .select("*")
      .in("resident_id", recipientIds)
      .eq("active", true);
    if (subscriptionError) throw subscriptionError;

    const { data: fcmTokens, error: fcmError } = await admin
      .from("fcm_device_tokens")
      .select("*")
      .in("resident_id", recipientIds)
      .eq("active", true);
    if (fcmError) throw fcmError;

    const deliveryRows = (subscriptions ?? []).map((sub) => ({
      notification_id: notificationId,
      resident_id: sub.resident_id,
      subscription_id: sub.id,
      status: "pending",
      attempts: 0,
      updated_at: new Date().toISOString(),
    }));
    if (deliveryRows.length) {
      const { error } = await admin.from("notification_deliveries").upsert(deliveryRows, {
        onConflict: "notification_id,subscription_id",
        ignoreDuplicates: true,
      });
      if (error) throw error;
    }

    const fcmDeliveryRows = (fcmTokens ?? []).map((tok) => ({
      notification_id: notificationId,
      resident_id: tok.resident_id,
      subscription_id: null,
      fcm_token_id: tok.id,
      status: "pending",
      attempts: 0,
      updated_at: new Date().toISOString(),
    }));
    if (fcmDeliveryRows.length) {
      const { error } = await admin.from("notification_deliveries").upsert(fcmDeliveryRows, {
        onConflict: "notification_id,fcm_token_id",
        ignoreDuplicates: true,
      });
      if (error) throw error;
    }

    let fcmDeliveryStates: { fcm_token_id: string; status: string }[] = [];
    if (fcmDeliveryRows.length) {
      const { data, error } = await admin
        .from("notification_deliveries")
        .select("fcm_token_id,status")
        .eq("notification_id", notificationId)
        .in("fcm_token_id", fcmDeliveryRows.map((row) => row.fcm_token_id));
      if (error) throw error;
      fcmDeliveryStates = data ?? [];
    }
    const fcmStateMap = new Map(fcmDeliveryStates.map((row) => [row.fcm_token_id, row.status]));
    const pendingFcmTokens = (fcmTokens ?? []).filter((tok) => ["pending", "failed"].includes(fcmStateMap.get(tok.id)));

    let subscriptionDeliveryStates: { subscription_id: string; status: string }[] = [];
    if (deliveryRows.length) {
      const { data, error } = await admin
        .from("notification_deliveries")
        .select("subscription_id,status")
        .eq("notification_id", notificationId)
        .in("subscription_id", deliveryRows.map((row) => row.subscription_id as string));
      if (error) throw error;
      subscriptionDeliveryStates = data ?? [];
    }
    const subscriptionStateMap = new Map(subscriptionDeliveryStates.map((row) => [row.subscription_id, row.status]));
    const pendingSubscriptions = (subscriptions ?? []).filter((sub) => ["pending", "failed"].includes(subscriptionStateMap.get(sub.id)));

    let sent = 0;
    let failed = 0;
    for (const sub of pendingSubscriptions) {
      const payload = JSON.stringify({
        title: event.title,
        body: event.body,
        tag: `ward-command-${event.event_type}-${notificationId}`,
        priority: event.priority || "normal",
        dedupe_key: event.dedupe_key || undefined,
        data: {
          url: event.target_url,
          notification_id: notificationId,
          event_type: event.event_type,
          category: event.category,
          patient_id: event.patient_id,
          task_id: event.task_id,
          handover_id: event.handover_id,
          ect_plan_id: event.ect_plan_id,
          roster_id: event.metadata?.roster_id || "",
          roster_type: event.metadata?.roster_type || "",
          roster_version: String(event.metadata?.roster_version || ""),
        },
      });
      try {
        const { data: claimed, error: claimError } = await admin.from("notification_deliveries")
          .update({ status: "sending", attempts: 1, updated_at: new Date().toISOString() })
          .eq("notification_id", notificationId)
          .eq("subscription_id", sub.id)
          .in("status", ["pending", "failed"])
          .select("id")
          .maybeSingle();
        if (claimError) throw claimError;
        if (!claimed) continue;
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          payload,
        );
        await admin.from("notification_deliveries").update({
          status: "sent", sent_at: new Date().toISOString(), updated_at: new Date().toISOString(), last_error: null,
        }).eq("notification_id", notificationId).eq("subscription_id", sub.id);
        await admin.from("push_subscriptions").update({
          last_success_at: new Date().toISOString(), updated_at: new Date().toISOString(),
        }).eq("id", sub.id);
        sent++;
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        failed++;
        await admin.from("notification_deliveries").update({
          status: "failed", last_error: message, updated_at: new Date().toISOString(),
        }).eq("notification_id", notificationId).eq("subscription_id", sub.id);
        const statusCode = (err as any)?.statusCode;
        await admin.from("push_subscriptions").update({
          active: statusCode === 404 || statusCode === 410 ? false : true,
          last_failure_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("id", sub.id);
      }
    }

    let fcmSent = 0;
    let fcmFailed = 0;
    const dataPayload: Record<string, string> = {
      title: String(event.title || ""),
      body: String(event.body || ""),
      notification_id: String(notificationId),
      event_type: String(event.event_type || ""),
      category: String(event.category || "general"),
      patient_id: String(event.patient_id || ""),
      task_id: String(event.task_id || ""),
      handover_id: String(event.handover_id || ""),
      ect_plan_id: String(event.ect_plan_id || ""),
      roster_id: String(event.metadata?.roster_id || ""),
      roster_type: String(event.metadata?.roster_type || ""),
      roster_version: String(event.metadata?.roster_version || ""),
      url: String(event.target_url || "/"),
    };

    let accessToken = "";
    let projectId = "";
    if (FIREBASE_SERVICE_ACCOUNT_JSON) {
      try {
        const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
        projectId = String(sa.project_id || "");
        accessToken = await getGoogleAccessToken(sa);
      } catch (e) {
        console.error("FCM service account init failed", e);
      }
    }

    for (const tok of pendingFcmTokens) {
      try {
        const { data: claimed, error: claimError } = await admin.from("notification_deliveries")
          .update({ status: "sending", attempts: 1, updated_at: new Date().toISOString() })
          .eq("notification_id", notificationId)
          .eq("fcm_token_id", tok.id)
          .in("status", ["pending", "failed"])
          .select("id")
          .maybeSingle();
        if (claimError) throw claimError;
        if (!claimed) continue;

        if (accessToken && projectId) {
          await sendFcmHttpV1(projectId, accessToken, tok.token, event.title, event.body, dataPayload);
        } else if (FCM_SERVER_KEY) {
          await sendFcmLegacy(FCM_SERVER_KEY, tok.token, event.title, event.body, dataPayload);
        } else {
          throw new Error("FCM not configured: set FIREBASE_SERVICE_ACCOUNT_JSON or FCM_SERVER_KEY on the edge function");
        }

        await admin.from("notification_deliveries").update({
          status: "sent", sent_at: new Date().toISOString(), updated_at: new Date().toISOString(), last_error: null,
        }).eq("notification_id", notificationId).eq("fcm_token_id", tok.id);
        await admin.from("fcm_device_tokens").update({
          last_success_at: new Date().toISOString(), updated_at: new Date().toISOString(),
        }).eq("id", tok.id);
        fcmSent++;
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        fcmFailed++;
        await admin.from("notification_deliveries").update({
          status: "failed", last_error: message, updated_at: new Date().toISOString(),
        }).eq("notification_id", notificationId).eq("fcm_token_id", tok.id);
        const gone = /NOT_FOUND|UNREGISTERED|InvalidRegistration|NotRegistered/i.test(message);
        await admin.from("fcm_device_tokens").update({
          active: gone ? false : true,
          last_failure_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("id", tok.id);
      }
    }

    return json({
      ok: true,
      notification_id: notificationId,
      recipients: recipientIds.length,
      deliveries_created: (subscriptionDeliveryStates?.length ?? 0) + (fcmDeliveryStates?.length ?? 0),
      sent,
      failed,
      fcm_sent: fcmSent,
      fcm_failed: fcmFailed,
    });
  } catch (error) {
    console.error(error);
    return json({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }, 500);
  }
});
