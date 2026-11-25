# 8. SDK design

## Principles

1. **The handler is the API.** Most users write one function: return normally to ack, throw/return an error to retry. Leases, heartbeats, credits and graceful shutdown are automatic.
2. **Errors decide fate.** `Retry(after)`, `Permanent(err)` (→ dead) and anything else (→ retry with queue backoff).
3. **Same options everywhere:** `tenant`, `idempotencyKey`, `orderingKey`, `priority`, `delay`/`at`, `ttl`, `maxAttempts`, `headers`.
4. **Connection string picks the mode:** `turnq://`, `file://` (Go), `local:` (Node/Python sidecar), `mem://`.
5. **OTel by default:** if a global tracer provider exists, publish injects `traceparent` and the handler runs inside a `process` span linked to it.
6. **Typed payloads:** generics in Go/TS (`Queue<T>`), Pydantic/dataclass support in Python. JSON is the default codec, and the codec is pluggable.
7. **Heartbeats:** auto-extend at `lease/3` while the handler runs, up to `lease_max`.

## Go

```go
package main

import (
    "context"
    "errors"
    "log"
    "time"

    turnq "github.com/turnq/turnq/sdk/go"
    _ "github.com/turnq/turnq/embedded" // only needed for file:// and mem://
)

type Email struct {
    To       string `json:"to"`
    Template string `json:"template"`
}

func main() {
    ctx := context.Background()

    // Embedded today ...
    c, err := turnq.Open("file://./data")
    // ... server tomorrow, no other code changes:
    // c, err := turnq.Open("turnq://turnq.internal:7400", turnq.WithAPIKey(os.Getenv("TURNQ_KEY")))
    if err != nil { log.Fatal(err) }
    defer c.Close()

    emails := turnq.Queue[Email](c, "emails",
        turnq.Retry(8, turnq.Exponential(time.Second, time.Hour).WithJitter()),
        turnq.KeyLimit("header:user_id", 2),            // ≤ 2 in flight per user
    )

    // Publish: delay, tenant, idempotency
    res, err := emails.Publish(ctx, Email{To: "ada@example.com", Template: "welcome"},
        turnq.Tenant("acme"),
        turnq.IdempotencyKey("welcome-u42"),
        turnq.Delay(5*time.Minute),
        turnq.Header("user_id", "42"),
    )
    log.Println(res.ID, res.Duplicate)

    // Cron
    _ = c.Admin().PutSchedule(ctx, turnq.Schedule{
        Name: "nightly-report", Cron: "0 2 * * *", Timezone: "Europe/Berlin",
        Queue: "reports", Payload: turnq.JSON(map[string]string{"kind": "nightly"}),
    })

    // Consume
    w := emails.Worker(func(ctx context.Context, job *turnq.Job[Email]) error {
        log.Printf("attempt %d for %s (tenant %s)", job.Attempt, job.ID, job.Tenant)
        err := send(ctx, job.Payload)
        switch {
        case errors.Is(err, ErrBadAddress):
            return turnq.Permanent(err)                  // → dead, no retries
        case errors.Is(err, ErrRateLimited):
            return turnq.RetryAfter(30*time.Second, err) // overrides backoff
        }
        return err                                       // nil → ack; other → retry w/ backoff
    }, turnq.Concurrency(16))

    if err := w.Run(ctx); err != nil { log.Fatal(err) } // blocks; SIGTERM → graceful drain
}
```

**Exactly-once-effect helper (inbox pattern):**

```go
w := emails.Worker(turnq.WithInbox(db, func(ctx context.Context, tx *sql.Tx, job *turnq.Job[Email]) error {
    // runs inside tx; WithInbox inserts job.ID into turnq_inbox in the same tx and
    // skips the handler if it was already processed.
    return chargeCard(ctx, tx, job.Payload)
}))
```

## Node.js / TypeScript

```ts
import { connect, Permanent, RetryAfter } from "turnq";

type Email = { to: string; template: string };

// "local:./data" spawns/attaches the bundled sidecar; swap for "turnq://host:7400"
const tq = await connect(process.env.TURNQ_URL ?? "local:./data", {
  apiKey: process.env.TURNQ_KEY,
});

const emails = tq.queue<Email>("emails", {
  retry: { maxAttempts: 8, backoff: { type: "exponential", initial: "1s", max: "1h", jitter: "full" } },
});

// publish
const { id, duplicate } = await emails.publish(
  { to: "ada@example.com", template: "welcome" },
  { tenant: "acme", idempotencyKey: "welcome-u42", delay: "5m", priority: 5, orderingKey: "user:42" },
);

// publish at an exact time
await emails.publish({ to: "bob@example.com", template: "trial-ending" }, { at: new Date("2026-12-01T09:00:00Z") });

// cron
await tq.schedules.put("nightly-report", {
  cron: "0 2 * * *", timezone: "Europe/Berlin", queue: "reports", payload: { kind: "nightly" },
});

// consume
const worker = emails.process(async (job) => {
  job.log(`attempt ${job.attempt}`);              // appended to the message timeline (v0.5)
  try {
    await sendEmail(job.payload);
  } catch (e: any) {
    if (e.code === "BAD_ADDRESS") throw new Permanent(e);
    if (e.status === 429) throw new RetryAfter("30s", e);
    throw e;                                         // retry with backoff
  }
}, { concurrency: 16, tenant: undefined /* or "acme" to only serve one tenant */ });

process.on("SIGTERM", () => worker.close());         // drains, releases unstarted leases

// webhook receiver (push delivery) in a Next.js / Vercel route
import { verifyWebhook } from "turnq/webhooks";
export async function POST(req: Request) {
  const job = await verifyWebhook<Email>(req, process.env.TURNQ_WEBHOOK_SECRET!); // throws 401 on bad sig
  await sendEmail(job.payload);                      // dedupe on job.id if side effects matter
  return new Response(null, { status: 204 });
}
```

## Python

```python
import os
from datetime import timedelta
from pydantic import BaseModel
import turnq
from turnq import Permanent, RetryAfter

class Email(BaseModel):
    to: str
    template: str

tq = turnq.connect(os.getenv("TURNQ_URL", "local:./data"), api_key=os.getenv("TURNQ_KEY"))

emails = tq.queue("emails", model=Email,
                  retry=turnq.Retry(max_attempts=8, backoff=turnq.exponential("1s", "1h", jitter=True)))

# publish
res = emails.publish(Email(to="ada@example.com", template="welcome"),
                     tenant="acme", idempotency_key="welcome-u42", delay=timedelta(minutes=5))
print(res.id, res.duplicate)

# cron
tq.schedules.put("nightly-report", cron="0 2 * * *", timezone="Europe/Berlin",
                 queue="reports", payload={"kind": "nightly"})

# consume (sync or async)
@emails.worker(concurrency=8)
async def send(job: turnq.Job[Email]) -> None:
    try:
        await send_email(job.payload)
    except BadAddress as e:
        raise Permanent(e)
    except Throttled as e:
        raise RetryAfter(timedelta(seconds=30)) from e

if __name__ == "__main__":
    turnq.run_workers()   # handles SIGTERM, heartbeats, graceful drain
```

```python
# FastAPI webhook receiver
from turnq.webhooks import verify
@app.post("/turnq")
async def hook(request: Request):
    job = verify(await request.body(), request.headers, secret=os.environ["TURNQ_WEBHOOK_SECRET"])
    ...
    return Response(status_code=204)
```

## SDK packaging

| SDK | Package | Transport | Embedded |
|---|---|---|---|
| Go | `github.com/turnq/turnq/sdk/go` (separate module, tiny deps) | connect-go | `github.com/turnq/turnq/embedded` (in-process) |
| Node/TS | `turnq` on npm (ESM + CJS), `@turnq/bin-*` optional deps | `@connectrpc/connect-node` (HTTP/2) | sidecar via `local:` |
| Python | `turnq` on PyPI, wheels with bundled binary | `httpx` + Connect JSON for unary, gRPC (`grpcio`, optional extra) for streaming | sidecar via `local:` |

All SDKs pass `sdk/conformance`: a language-neutral YAML scenario suite (publish/lease/ack/retry/delay/dedup/ordering/limits) driven by a small runner per language against both the server and local modes.
