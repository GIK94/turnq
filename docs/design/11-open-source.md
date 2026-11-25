# 11. Open-source setup

## Files in this repo

| File | Status |
|---|---|
| [`LICENSE`](../../LICENSE) | Apache 2.0, verbatim from apache.org |
| [`NOTICE`](../../NOTICE) | Required attribution file for Apache-2.0 distributions |
| [`CONTRIBUTING.md`](../../CONTRIBUTING.md) | Dev setup, DCO sign-off, PR flow, RFC process |
| [`CODE_OF_CONDUCT.md`](../../CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 (adopted by reference) |
| [`SECURITY.md`](../../SECURITY.md) | Private reporting, supported versions, disclosure timeline |
| [`GOVERNANCE.md`](../../GOVERNANCE.md) | Maintainers, decision making, becoming a maintainer |
| [`.github/ISSUE_TEMPLATE/`](../../.github/ISSUE_TEMPLATE/) | Bug report, feature request, config (routes questions to Discussions) |
| [`.github/PULL_REQUEST_TEMPLATE.md`](../../.github/PULL_REQUEST_TEMPLATE.md) | Checklist |
| [`docs/VERSIONING.md`](../VERSIONING.md) | SemVer and API/format stability policy |

**Decisions:**
- **DCO, not a CLA.** Lower friction, and it's the norm for CNCF-style projects. If a commercial offering is planned (open question Q2), revisit before the first external contribution. A CLA can't be added retroactively to past contributions without re-consent.
- **Trademark:** the name and logo are held by the maintainers. There's a short `TRADEMARKS.md` at v0.5 (forks must rename) to keep "turnq" meaning the real thing.
- **License headers:** an SPDX one-liner (`// SPDX-License-Identifier: Apache-2.0`) in every source file, enforced in CI. That's lighter than the full Apache boilerplate and recognised by scanners.
- **RFCs:** anything that changes public API, on-disk format or semantics needs an RFC in `docs/rfcs/NNNN-title.md`, with a 7-day comment period.

## Docs site structure (Starlight / Astro at `turnq.dev`)

```text
Getting started
  ├─ 5-minute quickstart            ← the most important page in the project
  ├─ Install (binary, Docker, Helm, Homebrew)
  ├─ Embedded mode (Go) / local mode (Node, Python)
Concepts
  ├─ Queues, topics, subscriptions
  ├─ Message lifecycle & state machine
  ├─ Delivery guarantees (and why not exactly-once)
  ├─ Retries, backoff, DLQ
  ├─ Delays, scheduling, cron
  ├─ Ordering keys & concurrency limits
  ├─ Tenants & fairness
  ├─ Push delivery (webhooks)
Guides
  ├─ Migrating from RabbitMQ (concept map: exchange→topic, DLX+TTL→retry policy …)
  ├─ Migrating from BullMQ / Sidekiq / Celery
  ├─ Idempotent consumers & the inbox pattern
  ├─ Serverless: Lambda, Cloudflare Workers, Vercel
  ├─ Debugging a stuck message
  ├─ Embedded → server migration
Operations
  ├─ Configuration reference
  ├─ Storage, fsync, retention, backups
  ├─ Monitoring (Prometheus, Grafana, OTel)
  ├─ Security (TLS, API keys, SSRF, encryption)
  ├─ Capacity planning & benchmarks
  ├─ Upgrades & compatibility
Reference
  ├─ REST API (generated from protos, OpenAPI)
  ├─ gRPC API
  ├─ CLI
  ├─ SDKs: Go · TypeScript · Python
Project
  ├─ Roadmap · Changelog · Versioning · Contributing · Design docs · RFCs
```

## 5-minute quickstart (draft of the page)

````markdown
# Quickstart

## 1. Run turnq (30 seconds)
```bash
docker run -p 7400:7400 -v turnq-data:/data ghcr.io/turnq/turnq:latest
# or: brew install turnq && turnq server --dev
```
Open http://localhost:7400/ui. Dev mode prints an admin API key on startup:
```bash
export TURNQ_KEY=tq_dev_...
```

## 2. Publish a job (30 seconds)
```bash
curl -X POST localhost:7400/v1/queues/emails/messages \
  -H "Authorization: Bearer $TURNQ_KEY" \
  -d '{"json": {"to": "ada@example.com"}, "options": {"tenant": "acme"}}'
```

## 3. Process it with retries (2 minutes)
```bash
npm i turnq
```
```ts
// worker.ts
import { connect } from "turnq";
const tq = await connect("turnq://localhost:7400", { apiKey: process.env.TURNQ_KEY });
tq.queue("emails").process(async (job) => {
  console.log("attempt", job.attempt, job.payload);
  if (job.attempt < 3) throw new Error("flaky SMTP");   // watch it retry
});
```
```bash
npx tsx worker.ts
```

## 4. See inside (1 minute)
Open the message in the dashboard and look at its **timeline**: published → leased → failed → retry scheduled → … → acked, with every error.

Or from the CLI:
```bash
turnq get <id> --timeline
```

## 5. Try the things RabbitMQ makes hard (1 minute)
```bash
# delayed job
turnq publish emails '{"to":"bob@example.com"}' --delay 30s
# cron
turnq schedule put digest --cron "*/1 * * * *" --queue emails --payload '{"digest":true}'
# replay everything that died in the last hour
turnq redrive emails --since 1h
```
Next: [Tenants & fairness](/concepts/fairness) · [Push to Lambda](/guides/serverless) · [Embed in Go](/getting-started/embedded)
````

**Quickstart success metric:** a new user goes from zero to seeing a retried message's timeline in under 5 minutes. Test it on someone outside the project every release.
