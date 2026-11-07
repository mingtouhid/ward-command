// Ward Sync R1.8 dispatch-bdft
// Not deployed by this change. It does not send a push and it does not claim a delivery.
// A live ward session is required. A service bearer is not a substitute.
// ward_dispatch_anon_key is not read or created.
//
// Delivery state lives in ward_bdft_claim_delivery and ward_bdft_apply_provider.
// Those functions are what a deployed sender must call: claim one device row,
// send that row, then record sent, transient, or permanent. This file does not
// perform that send, so a deploy of this source cannot burn retry attempts.
//
// Existing pg_cron jobs do not call this function. Unattended retry needs a
// later schedule that uses the platform role already configured for
// dispatch-notification, plus the VAPID or FCM environment that function uses.
// Until then, publication stores the notice and an eligible session can retry.

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const body = await req.json().catch(() => ({}));
  if (!body?.notification_id || !body?.session_token) {
    return json({ ok: false, error: "notification_id and session_token are required" }, 400);
  }
  return json({
    ok: true,
    dispatch: "deferred",
    reason: "BDFT sender is not deployed. The notice stays queued.",
    notification_id: body.notification_id,
  });
});
