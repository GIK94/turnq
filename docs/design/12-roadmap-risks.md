# 12. Roadmap, risks and cuts

## Phased roadmap

### v0.1: "See inside" MVP (single binary)
**Theme:** a credible job queue with best-in-class visibility. Ship it, get 10 real users.

| In | Out (deferred) |
|---|---|
| Single binary, Docker image, `turnq server --dev` | Postgres store |
| `logstore` (segmented log + Pebble), `memstore`, `fsync=always/interval` | Payload relocation compaction (just keep segments longer; document it) |
| Queues (no topics yet), publish/lease/ack/nack/extend, lease tokens | Topics & subscriptions |
| Retries (fixed/exponential/jitter), max attempts, DLQ state, delays | Ordering keys |
| Idempotency keys + dedup window | Per-key concurrency/rate limits |
| Priorities | Push delivery |
| **Tenant DRR fairness** (weights, `max_in_flight`) | Tenant quotas, tenant rate limits |
| Cron schedules (UTC + IANA tz, misfire=skip/fire_once) | Cron `fire_all`, `skip_if_running` |
| **Timeline, Explain, search by id/key/tenant/state, replay single, redrive DLQ** | CEL filters, indexed payload fields |
| REST + Connect/gRPC (unary + streaming consume) | Vanguard full REST transcoding polish |
| Go SDK (remote + `file://` embedded), Node SDK (remote only) | Python SDK, Node `local:` sidecar |
| Dashboard: Overview, Queues, Queue detail, Message detail (timeline + explain), DLQ | Tenants screen, Push, Consumers |
| Prometheus metrics, API keys (admin/publish/consume scopes), TLS | OTel, tenant-scoped keys, OIDC |
| Crash test loop, model-based tests, sim harness skeleton | Full Jepsen-style suite |

### v0.5: "Job queue parity+"
Topics/subscriptions with CEL filters · **push delivery** (Standard Webhooks, circuit breaker, SSRF guard, async completion) · ordering keys · per-key concurrency and rate limits · tenant quotas and rate limits · tenant-scoped API keys · CEL search + indexed fields + filtered replay with spread · Python SDK · Node/Python `local:` sidecar · OTel propagation · Tenants/Push/Consumers/Schedules screens · `pgstore` (active/passive) · payload relocation compaction + `PurgeTenant` · `turnq migrate` · Helm chart · public benchmarks v1 · full deterministic simulation in CI.

### v1.0: "Production contract"
**Stability:** `turnq.v1` API frozen · on-disk format v1 frozen with upgrade path · SDK 1.0s · documented guarantees backed by the published Jepsen-style report · at-rest encryption (AES-GCM per segment, key file/KMS) · OIDC for the dashboard · payload redaction rules · Ed25519 push signatures · live `Watch` streams in the dashboard · partitioned queues · backups (online checkpoint + log shipping to S3) · audit log for admin actions · security review/fuzzing campaign.

### Post-1.0: clustering and beyond
1. **Replication (v1.x):** each shard becomes a Raft group (etcd/raft library). The commit log *is* the Raft log, so no storage redesign. Start with 3-node clusters, all shards replicated. Leader-only scheduling and cron. Lease deadlines are leader-local with term fencing, so a lease token embeds the term.
2. **Shard placement and rebalancing (v2):** move shards between nodes, and add nodes without downtime.
3. Time-based fairness (`drr_time`), workflow primitives (job dependencies/chains), a Kafka-style replayable stream retention mode, multi-region async replication, and a tiered payload store (S3) for large DLQs.

## Key risks and trade-offs

| Risk | Impact | Mitigation |
|---|---|---|
| **Correctness bugs in lease/retry/recovery** | Lost or duplicated work destroys trust permanently | Deterministic simulation from day one, model-based tests, crash loops, LazyFS, published invariants. Never ship a storage format change without the crash suite. |
| **Own log + Pebble view = two storage systems** | Divergence bugs, more code | View is rebuildable from log. `turnq verify` in CI. Strict "apply is a pure function" rule. |
| **Observability write amplification** | Throughput claim fails | `timeline: failures` mode, benchmark S9 tracked in CI. Indexes opt-in beyond the basics. |
| **Scope creep** (it's 5 products: queue, job runner, webhook service, scheduler, embedded DB) | Never reaching 1.0 | The v0.1 cut above. Push and topics wait for v0.5. Say no to AMQP compatibility. |
| **Single-node limits** before clustering | "Not production-ready" perception | Honest docs: single node with fsync is more durable than many Redis setups. `pgstore` as an HA story in v0.5. Clear capacity numbers. |
| **Cardinality explosions** (tenants × queues × metrics) | OOM, Prometheus meltdown | Tenant metrics opt-in/top-K, idle tenant eviction, bounded head buffers |
| **Clock skew / DST for cron** | Missed or double-fired jobs | Idempotent cron keys `cron:{name}:{fire_ts}`, IANA tz with explicit DST rules (skip non-existent times, fire once for ambiguous times), misfire policy, clock-jump metric |
| **Hot queue on one shard** | Throughput ceiling per queue (~one core) | Partitioned queues in v1.0. Document the per-queue ceiling. |
| **Go GC tail latency** under huge backlogs | p999 spikes | Off-heap-ish structures (slices of structs, no pointers in head buffers), `GOMEMLIMIT`, benchmark p999 |
| **Embedded mode expectations** ("SQLite" implies multi-process) | Confused users | Docs and error messages say single process. Sidecar for multi-process. |
| **Security of push** (SSRF, secrets) | Broker used as a pivot into internal networks | Dial-time IP filtering on by default, admin-only override, secrets encrypted |
| **Competing with free, mature incumbents** | Low adoption | Win on the demo: the noisy-tenant benchmark chart + a "why is this stuck?" screen in the README GIF + the 5-minute quickstart |

## Hard-to-get-right checklist (owner must sign off per release)

- [ ] **Ordering:** per-key FIFO holds across retries, restarts and redrives. No global ordering is promised anywhere in the docs.
- [ ] **Lease expiry races:** stale-token ack rejected. Extend after expiry rejected. Expiry and ack in the same tick are resolved deterministically (whichever the shard loop processes first).
- [ ] **Clock skew:** delays/cron use wall clock, leases use monotonic. Jump detection metric.
- [ ] **Backpressure:** bounded queues at every hop, credits on streams, 429 + Retry-After, disk watermarks.
- [ ] **Poison messages:** lease expiry counts as an attempt. The suspected-crash flag works. Ordering-key poison is visible in Explain.
- [ ] **Recovery:** torn tail truncated, view replayed, leases restored, no acked publish lost under `fsync=always`.

## If time is limited, cut in this order

1. **Postgres store**: interface only. `logstore` is enough.
2. **Python SDK / sidecar mode**: REST is curl-able, and Go + Node cover most early adopters.
3. **Topics/fan-out**: most job-queue users need queues only. Topics are a v0.5 headline.
4. **CEL search**: id/idempotency-key/tenant/state search covers about 80% of debugging.
5. **Per-key rate limits** (keep per-key concurrency, which is more requested).
6. **Payload relocation compaction**: accept larger disk usage. Document it.
7. **Dashboard polish**: keep Message detail + DLQ excellent and ship the other screens bare.

**Never cut:** timeline + Explain (the positioning), DRR fairness (the differentiator), retries/delays/DLQ (table stakes), crash testing (trust), the 5-minute quickstart (adoption).
