# turnq design

> A message queue you can see inside. Retries, delays, replay and per-tenant fairness built in. One binary, five-minute setup.

Status: **Draft v0 (2026-11-25)**. This is the design of record until superseded by an RFC in `docs/rfcs/`.

| # | Document | What it decides |
|---|----------|-----------------|
| 0 | This file | Assumptions, open questions, the decisions that shape everything else |
| 1 | [Architecture](01-architecture.md) | Components, data flow, threading model, Go vs Rust |
| 2 | [Data model](02-data-model.md) | Queue, topic, message, lease, attempt, tenant, subscription, schedule, plus the state machine |
| 3 | [Storage](03-storage.md) | Commit log + Pebble view, key layout, retention, recovery, observability storage |
| 4 | [Tenant fairness](04-fairness.md) | Algorithm comparison, DRR design, pseudocode, edge cases |
| 5 | [Push delivery](05-push-delivery.md) | Dispatcher, signing, retries, endpoint health, SSRF |
| 6 | [Embedded mode](06-embedded-mode.md) | Shared abstraction, what degrades, migration |
| 7 | [API](07-api.md) | gRPC (`api/proto/turnq/v1`), REST endpoints, examples |
| 8 | [SDKs](08-sdks.md) | Go, TypeScript, Python |
| 9 | [Dashboard](09-dashboard.md) | Screens and the questions they answer |
| 10 | [Engineering](10-engineering.md) | Monorepo, CI, testing (crash, simulation, Jepsen-style), benchmarks |
| 11 | [Open source](11-open-source.md) | Licence, governance, versioning, docs site, quickstart |
| 12 | [Roadmap, risks, cuts](12-roadmap-risks.md) | v0.1 → post-1.0, risks, what to drop |

---

## Assumptions

1. **Name:** `turnq`. Binary `turnq`, default port `7400`, Go module `github.com/turnq/turnq` (placeholder org).
2. **Workload:** job and task queues for web/SaaS backends. Mostly JSON payloads, median about 1 KB, p99 under 256 KB, hard limit 1 MB (larger payloads go in object storage and you enqueue a pointer). This is not a Kafka replacement for multi-GB/s event streaming.
3. **v1 single-node targets** (8 vCPU, NVMe, 1 KB payloads, `fsync=always` with group commit): ≥ 50k msg/s publish+consume sustained, p99 publish→deliver < 10 ms at 50% of max load, 100M backlogged messages, 100k active tenants, 10k queues.
4. **Delivery:** at-least-once. Consumers must be idempotent, and we give them the tools for it (idempotency key, attempt number, an inbox helper).
5. **Operators:** small teams, often without a dedicated SRE. Defaults must be safe, and there should be one config file and one data directory.
6. **Clients:** Go, Node/TS and Python are tier 1. Others use REST or generated gRPC.
7. **Trust model:** a single organisation runs the broker. Tenants are *their* customers, not mutually hostile users of a shared turnq install. Per-tenant API keys exist, but full hard multi-tenancy (noisy-neighbour isolation of disk and CPU) is out of scope.

## Open questions for you (defaults below are what the rest of the docs assume)

| # | Question | Why it matters | Default I've assumed |
|---|----------|----------------|----------------------|
| Q1 | **Must Node/Python embed turnq truly in-process, or is "zero-ops local mode" enough?** | This is the one requirement that would flip Go → Rust. Go can't be cleanly embedded into other language runtimes. | Go embeds in-process. Node/Python "embedded" spawns and manages a bundled `turnq` binary on a Unix socket. It has the same semantics and nothing to operate, but it isn't the same process. See [06](06-embedded-mode.md). |
| Q2 | **Is there a future commercial offering (cloud or enterprise)?** | It affects Apache-2.0 vs a source-available licence, CLA vs DCO, and trademark policy. Changing these later is painful. | Pure Apache-2.0, DCO (no CLA), trademark held by the maintainers. If a cloud is planned, decide on trademark and CLA **before** the first external PR. |
| Q3 | **Does Postgres-as-storage matter for v0.5, or can it wait until after 1.0?** | Some users want "durability on managed RDS" more than a new disk format. It's also the cheapest pre-Raft HA story. | Interface in v0.1, `pgstore` in v0.5 (active/passive brokers via advisory lock). |
| Q4 | **PII and retention: will payloads contain personal data that needs per-tenant purge/erasure?** | Observability means storing payloads for days. That's a GDPR/DPA question, and it shapes the log compaction design. | Per-queue retention, a `PurgeTenant` API (tombstone + compaction), dashboard payload redaction by JSON path, optional at-rest encryption in v1.0. |
| Q5 | **Is strict ordering a core need, or is per-key FIFO enough?** | Global FIFO kills parallelism and fairness. | No global ordering guarantee. Strict FIFO per `ordering_key` (at most one in flight per key, blocking through retries). |

## The decisions that shape everything

| Decision | Choice | One-line justification |
|---|---|---|
| Language | **Go**, single static binary, `CGO_ENABLED=0` | Best ecosystem fit (gRPC/Connect, Pebble, Prometheus, OTel, cel-go) and a large contributor pool. Rust only wins if Q1 = "true in-process for all languages". |
| Storage | **Own segmented commit log (source of truth) + Pebble as a materialised view** | One fsync per group commit. Observability, replay and the future Raft log all come from the same log. Pebble is pure Go and proven in CockroachDB. |
| Delivery | At-least-once + idempotent publish + lease tokens | Exactly-once needs transactional coupling with the consumer's side effects, which a broker can't provide alone. See [02 §Why not exactly-once](02-data-model.md#why-not-exactly-once-in-v1). |
| Fairness | **Deficit Round Robin over per-(queue, tenant) virtual queues**, with parking for blocked tenants | O(1) per dequeue, simple weights, bounded unfairness. WFQ's tighter bounds aren't worth O(log n) plus virtual-time bookkeeping. |
| API | **ConnectRPC** (gRPC + gRPC-Web + JSON on one port) + REST transcoding from `google.api.http` annotations | gRPC streaming for SDKs, plain curl for humans, one port, one schema. |
| Push signing | **Standard Webhooks** spec (`webhook-id`, `webhook-timestamp`, `webhook-signature`) | Existing verifier libraries in every language, so we don't invent our own scheme. |
| Threading | **Sharded single-writer engine** (queues hashed to N shards, one goroutine per shard) | No locks on the hot path, deterministic, simulation-testable, and maps 1:1 onto Raft groups later. |
| Embedded API | `database/sql`-style drivers: `turnq.Open("file://./data")` vs `turnq.Open("turnq://host:7400")` | Switching modes means changing the connection string, not the code. |
| Clustering | Designed for (shards = future Raft groups, log = Raft log), shipped post-1.0 | Single node done well beats a buggy cluster. |
