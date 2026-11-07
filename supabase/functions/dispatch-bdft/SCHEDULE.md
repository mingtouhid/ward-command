# dispatch-bdft schedule

Durable retries call this function with the Supabase project's existing service role. That value is the `default` key already present in the function environment as `SUPABASE_SECRET_KEYS`. Do not create `ward_dispatch_anon_key`. Do not put a resident session on the schedule.

```http
POST /functions/v1/dispatch-bdft
Authorization: Bearer <existing platform service role>
apikey: <same existing platform service role>
Content-Type: application/json

{}
```

The function selects `dispatch_due` bed-distribution notices. It does not accept an event type, an audience, or a resident session on this path. A body that names another event type is rejected.

Provision the schedule from the Supabase project that already hosts `dispatch-notification`, using that project's service role. This repository cannot create the schedule: the project credential and the permission to add a schedule are not available here. Until an operator adds it, unpublished retries stay queued. A resident who just published may still call the same URL with their own ward session and that notice's id. That call cannot edit the board and cannot drain any other notice.

The clinical `dispatch-notification` function is unchanged. Its service credential remains limited to admin-scoped events.
