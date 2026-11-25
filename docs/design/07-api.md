# 7. API

**Transport:** [ConnectRPC](https://connectrpc.com) on a single port (`7400`). It serves gRPC, gRPC-Web, and Connect (JSON over HTTP/1.1 or HTTP/2) from the same handlers. REST resource routes are transcoded from the `google.api.http` annotations (via Vanguard, or grpc-gateway as a fallback). So there's **one schema, three wire formats, and curl works**.

Proto sources live in [`api/proto/turnq/v1/`](../../api/proto/turnq/v1/):

| File | Service | Plane |
|---|---|---|
| [`types.proto`](../../api/proto/turnq/v1/types.proto) | — | Shared resources (Message, Queue, Event, Schedule, PushEndpoint …) |
| [`broker.proto`](../../api/proto/turnq/v1/broker.proto) | `BrokerService` | Data plane: Publish, Lease, Consume (bidi stream), Ack/Nack/Extend, Cancel |
| [`inspect.proto`](../../api/proto/turnq/v1/inspect.proto) | `InspectService` | Observability: Get, Timeline, **Explain**, Search, Replay, Redrive, stats |
| [`admin.proto`](../../api/proto/turnq/v1/admin.proto) | `AdminService` | Control plane: queues, topics, subscriptions, schedules, tenants, push endpoints, API keys |

## Conventions

- **Auth:** `Authorization: Bearer tq_live_…` (API key) or mTLS. Keys carry scopes (`publish`, `consume`, `inspect`, `admin`, `payload:read`), plus optional queue globs and tenant restrictions. A **tenant-scoped key forces `tenant`** on publish (an override attempt returns 403) and filters every inspect result.
- **Errors:** Connect/gRPC codes, with a `turnq.v1.ErrorDetail{reason, retry_after}`. REST maps these to HTTP: `RESOURCE_EXHAUSTED` → 429 + `Retry-After`, `FAILED_PRECONDITION` (`LEASE_EXPIRED`) → 409, `NOT_FOUND` → 404, `INVALID_ARGUMENT` → 400.
- **Idempotency:** `options.idempotency_key` on publish. REST also accepts an `Idempotency-Key` header.
- **Resource creation:** queues are auto-created on first publish with server defaults (`auto_create_queues: true`, which can be disabled in prod). All admin resources are `PUT` (upsert) for GitOps via `turnq apply -f`.
- **Pagination:** `page_size` + opaque `page_token`.
- **Versioning:** the package `turnq.v1` is frozen at 1.0. New experimental RPCs go in `turnq.v1alpha1`.

## REST endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/queues/{queue}/messages` | Publish |
| POST | `/v1/queues/{queue}/messages:batch` | Publish batch (≤ 500) |
| POST | `/v1/topics/{topic}/messages` | Publish to topic (fan-out) |
| POST | `/v1/queues/{queue}/leases` | Long-poll lease (pull consumer over HTTP) |
| POST | `/v1/leases/{token}:ack` | Ack |
| POST | `/v1/leases/{token}:nack` | Nack (retry / permanent / release) |
| POST | `/v1/leases/{token}:extend` | Heartbeat |
| POST | `/v1/messages/{id}:cancel` | Cancel a scheduled/ready/retrying message |
| GET | `/v1/messages/{id}` | Get message (`?include_payload=true`) |
| GET | `/v1/messages/{id}/timeline` | Full timeline |
| GET | `/v1/messages/{id}/explain` | Why is it not moving? |
| POST | `/v1/messages:search` | Search / filter |
| POST | `/v1/messages:replay` | Replay one or a filtered set |
| POST | `/v1/queues/{queue}/dead:redrive` | Redrive DLQ |
| GET | `/v1/operations/{id}` | Long-running op progress |
| GET | `/v1/queues` · `/v1/queues/{name}` · `/v1/queues/{name}/stats` · `/v1/queues/{name}/tenants` | Queue info |
| PUT / DELETE | `/v1/queues/{name}` | Upsert / delete queue |
| POST | `/v1/queues/{name}:pause` · `:resume` · `:purge` | Queue ops |
| PUT | `/v1/topics/{name}` · `/v1/topics/{topic}/subscriptions/{name}` | Topics & subs |
| PUT / GET / DELETE | `/v1/schedules/{name}` · POST `:trigger` | Cron |
| PUT | `/v1/tenants/{name}` · POST `:purge` | Tenants |
| PUT | `/v1/push-endpoints/{name}` · POST `:rotate-secret` · GET `/health` | Push |
| POST / DELETE | `/v1/api-keys` · `/v1/api-keys/{id}` | Keys |
| GET | `/metrics` · `/healthz` · `/readyz` · `/ui/` | Ops |

## Examples

### Publish with delay, tenant and idempotency key

```bash
curl -sX POST localhost:7400/v1/queues/emails/messages \
  -H "Authorization: Bearer $TURNQ_KEY" \
  -H "Idempotency-Key: welcome-u42" \
  -d '{
        "json": {"to": "ada@example.com", "template": "welcome"},
        "options": {"tenant": "acme", "delay": "300s", "priority": 5}
      }'
```
```json
{ "id": "msg_01jdq3v8x7k2m9p4r6t8w0y2a4", "duplicate": false, "state": "MESSAGE_STATE_SCHEDULED" }
```

Running the same command again returns the same id with `"duplicate": true` (HTTP 200, not 409, so the operation is idempotent).

### Pull over HTTP (long-poll), then ack or nack

```bash
curl -sX POST localhost:7400/v1/queues/emails/leases \
  -H "Authorization: Bearer $TURNQ_KEY" \
  -d '{"max_messages": 2, "wait": "20s", "lease": "60s", "consumer_id": "cron-box-1"}'
```
```json
{
  "deliveries": [{
    "message": {
      "id": "msg_01jdq3v8x7k2m9p4r6t8w0y2a4", "queue": "emails", "tenant": "acme",
      "payload": "eyJ0byI6ICJhZGFAZXhhbXBsZS5jb20iLCAidGVtcGxhdGUiOiAid2VsY29tZSJ9",
      "headers": {"content-type": "application/json"},
      "attempt": 1, "idempotencyKey": "welcome-u42", "state": "MESSAGE_STATE_LEASED"
    },
    "leaseToken": "lt_AAABk3x…",
    "leaseDeadline": "2026-11-25T10:06:00.004Z"
  }]
}
```

```bash
curl -sX POST localhost:7400/v1/leases/lt_AAABk3x…:ack -H "Authorization: Bearer $TURNQ_KEY"
# {}

curl -sX POST localhost:7400/v1/leases/lt_AAABk3x…:nack -H "Authorization: Bearer $TURNQ_KEY" \
  -d '{"error": {"code": "SMTP_421", "message": "try later"}, "retry_after": "120s"}'
# {"state": "MESSAGE_STATE_RETRYING", "nextAt": "2026-11-25T10:08:02Z"}
```

A stale token:
```http
HTTP/1.1 409 Conflict
{"code":"failed_precondition","message":"lease expired; message was re-leased (attempt 2)","details":[{"reason":"LEASE_EXPIRED"}]}
```

### Explain a stuck message

```bash
curl -s localhost:7400/v1/messages/msg_01jdq3…/explain -H "Authorization: Bearer $TURNQ_KEY"
```
```json
{
  "state": "MESSAGE_STATE_READY",
  "reasons": [
    {"code": "ORDERING_KEY_BLOCKED",
     "text": "Waiting behind msg_01jdq2… which holds ordering key \"user:42\" (state RETRYING, attempt 5/8, next try 10:14:03Z)",
     "until": "2026-11-25T10:14:03Z"},
    {"code": "TENANT_CAP", "text": "Tenant acme has 50/50 messages in flight on this queue"}
  ]
}
```

### Search and replay

```bash
curl -sX POST localhost:7400/v1/messages:search -H "Authorization: Bearer $TURNQ_KEY" -d '{
  "queue": "orders.billing", "states": ["MESSAGE_STATE_DEAD"],
  "createdAfter": "2026-11-24T00:00:00Z",
  "filter": "payload.amount > 1000 && message.last_error.http_status == 503",
  "pageSize": 50
}'

curl -sX POST localhost:7400/v1/queues/orders.billing/dead:redrive -H "Authorization: Bearer $TURNQ_KEY" \
  -d '{"filter": "message.last_error.http_status == 503", "spread": "600s", "dryRun": false}'
# {"id":"op_01jdq…","kind":"redrive","status":"STATUS_RUNNING","matched":"1832"}
```

`spread` staggers redriven messages over 10 minutes, so you don't DDoS the endpoint that just recovered.

### Cron schedule

```bash
curl -sX PUT localhost:7400/v1/schedules/nightly-report -H "Authorization: Bearer $TURNQ_KEY" -d '{
  "cron": "0 2 * * *", "timezone": "Europe/Berlin", "queue": "reports",
  "payload": "eyJraW5kIjoibmlnaHRseSJ9", "tenant": "acme", "misfire": "MISFIRE_FIRE_ONCE"
}'
```

### Push endpoint

```bash
curl -sX PUT localhost:7400/v1/push-endpoints/billing-lambda -H "Authorization: Bearer $TURNQ_KEY" -d '{
  "queue": "orders.billing",
  "url": "https://abc.lambda-url.eu-west-1.on.aws/",
  "timeout": "30s", "maxConcurrency": 20
}'
# response includes "secret": "whsec_…" exactly once
```

## Streaming consume (gRPC / Connect bidi)

```text
client → Start{queue:"emails", consumer_id:"w-7", credits:32, lease:"30s"}
server → Delivery × ≤32
client → Ack{token}           server → SettleResult{ok}
client → Credit{add:1}        (SDKs auto-replenish credits on ack/nack)
client → Extend{token,"30s"}  server → SettleResult{new_deadline}
server → Heartbeat (15 s idle)
```

When the stream drops, leases are **not** revoked. They expire normally, since the consumer may still finish and ack via unary `Ack`. On graceful shutdown, SDKs send `Nack{release:true}` for unstarted deliveries so they're redelivered immediately without an attempt penalty.

## CLI (same API)

```bash
turnq publish emails '{"to":"ada@example.com"}' --tenant acme --delay 5m --key welcome-u42
turnq consume emails --exec ./handle.sh            # pipes payload to stdin; exit 0 = ack
turnq get msg_01jdq3…  --timeline
turnq explain msg_01jdq3…
turnq search orders.billing --state dead --filter 'payload.amount > 1000'
turnq redrive orders.billing --filter 'message.last_error.http_status == 503' --spread 10m
turnq apply -f turnq.yaml                          # declarative config
turnq top                                          # live TUI: queues, rates, tenants
```
