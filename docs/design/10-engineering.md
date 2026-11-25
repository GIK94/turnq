# 10. Repository, CI, testing and benchmarks

## Monorepo layout

```text
turnq/
├── api/proto/turnq/v1/          # source of truth for all APIs (buf)
├── gen/go/turnq/v1/             # generated Go (committed, so `go get` works without buf)
├── cmd/turnq/                   # main: `turnq server|publish|consume|get|explain|search|redrive|apply|migrate|verify|top`
├── internal/
│   ├── engine/                  # shards, command loop, state machine (pure, clock/IO injected)
│   │   ├── fairness/            # DRR scheduler
│   │   ├── limits/              # token buckets, key concurrency
│   │   ├── timers/              # hierarchical timer wheel
│   │   └── lease/
│   ├── store/
│   │   ├── logstore/            # segmented log + pebble view
│   │   ├── memstore/
│   │   ├── pgstore/             # v0.5
│   │   └── storetest/           # conformance suite for Store impls
│   ├── wal/                     # segment files, record codec, CRC, group commit
│   ├── cron/                    # parser wrapper, tz/DST, misfire
│   ├── push/                    # dispatcher, signer, circuit breaker, SSRF dialer
│   ├── server/                  # connect handlers, auth, REST transcoding, quotas
│   ├── inspect/                 # search (CEL), explain, replay/redrive operations
│   ├── observability/           # metrics, OTel, ts/ rollups
│   ├── config/
│   └── sim/                     # deterministic simulation harness
├── embedded/                    # public: registers file:// and mem:// drivers
├── sdk/
│   ├── go/                      # separate go.mod (lightweight client)
│   ├── node/                    # pnpm workspace; packages turnq + @turnq/bin-*
│   ├── python/                  # uv/hatch; maturin-free (binary bundled as data)
│   └── conformance/             # language-neutral YAML scenarios + runners
├── web/dashboard/               # React + Vite
├── test/
│   ├── integration/             # black-box against built binary (testcontainers for pg)
│   ├── crash/                   # kill -9 loops, LazyFS, disk-full
│   └── jepsen/                  # history recorder + checker (Go, Elle-inspired)
├── bench/
│   ├── harness/                 # open-loop load generator, HdrHistogram
│   ├── scenarios/               # YAML scenarios
│   └── competitors/             # docker-compose for RabbitMQ, Redis+BullMQ
├── deploy/
│   ├── docker/Dockerfile        # distroless static, non-root, multi-arch
│   ├── helm/turnq/
│   └── grafana/turnq.json
├── docs/
│   ├── design/                  # these docs
│   ├── rfcs/                    # RFC process for significant changes
│   └── site/                    # Starlight (Astro) docs site
├── .github/                     # workflows, templates
├── Makefile
├── buf.yaml / buf.gen.yaml
├── .goreleaser.yaml
├── LICENSE · NOTICE · CONTRIBUTING.md · CODE_OF_CONDUCT.md · SECURITY.md · GOVERNANCE.md
└── README.md
```

**Module boundaries:** the root module (`github.com/turnq/turnq`) contains server + engine + `embedded`. `sdk/go` is its own module, so remote-only users don't pull in Pebble. `internal/` keeps the engine API private until it's stable.

## Makefile and CI

See [`Makefile`](../../Makefile) and [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

| CI job | Trigger | What |
|---|---|---|
| `lint` | PR | golangci-lint, `buf lint`, `buf breaking --against main`, eslint/ruff, license headers |
| `unit` | PR | `go test -race -shuffle=on ./...` on linux/macos/windows; node + python unit tests |
| `sim` | PR (short: 200 seeds), nightly (50k seeds) | Deterministic simulation. Failing seed printed for repro. |
| `integration` | PR | Binary + SDK conformance (server + local modes), Postgres store via testcontainers |
| `crash` | nightly | kill -9 loop (1k iterations), LazyFS un-fsynced data loss, disk-full, corrupt-tail |
| `jepsen-lite` | nightly | History-checked workloads under faults |
| `bench-smoke` | PR touching `internal/engine|store|wal` | 60 s benchmark, comment regression > 10% |
| `release` | tag `v*` | goreleaser (linux/darwin/windows × amd64/arm64), cosign signatures, SBOM (syft), multi-arch Docker to GHCR, npm/PyPI publish |
| `codeql` + `govulncheck` | weekly + PR | Security |

## Testing strategy

### 1. Unit + property tests
- Engine state machine tested as a pure function: `(state, command, clock) → (state', records, replies)`.
- **Model-based property tests** (`pgregory.net/rapid`): random command sequences against the real engine and a ~300-line reference model (maps + slices, obviously correct). Assert identical observable results. Covers: dedup windows, ordering keys, key limits, DRR shares (within bound), retry/backoff schedule, lease epoch fencing.
- DRR fairness property: over any window of `R` rounds, each backlogged tenant's delivered cost is within `[R·q·w − max_cost, R·q·w + max_cost]`.

### 2. Deterministic simulation testing (the big investment)
Engine, WAL, store and the network layer take injected `Clock`, `Rand`, `FS`, `Net`. `internal/sim` runs the whole broker plus simulated producers and consumers in **one goroutine-scheduled, seeded world**:
- Fault injection: crash at any syscall, torn writes, fsync lies (dropped un-synced pages), slow disk, clock jumps (±hours), consumer stalls past lease, network partitions between client and broker.
- Invariants checked continuously (see the Jepsen-style list below).
- Any failure is reproducible with `go test ./internal/sim -seed=…`.
This is how FoundationDB and TigerBeetle got their reliability. It is the single best defence against lease-expiry and recovery races.

### 3. Integration
The built binary in Docker. Every SDK runs the conformance suite in both `turnq://` and `local:` modes. REST examples from the docs are executed as tests (docs can't rot).

### 4. Crash and storage chaos
- `test/crash`: a producer with idempotency keys + a consumer recording acks to an external ledger. `kill -9` the broker at random intervals ×1000. On restart, verify **no acked publish is lost**, every message is eventually acked or dead, and `turnq verify` (log ⇄ view) passes.
- **LazyFS** (FUSE filesystem that loses un-fsynced data on "crash") to validate the `fsync=always` claims honestly.
- Disk full: publishes rejected cleanly, no corruption, recovery after space is freed.
- Bit-flip in a non-tail segment: a clear fatal error, plus `turnq repair` behaviour.

### 5. Jepsen-style history checking (single node now, cluster later)
Record every client operation (invoke/complete with timestamps). The checker asserts:

| Invariant | Check |
|---|---|
| No lost messages | Every publish acked to the producer is eventually delivered (or reaches `dead`/`expired`/`cancelled` with a reason) |
| Lease exclusivity | No two consumers hold valid, unexpired lease tokens for the same message at the same (broker) time. A late ack with a stale token is always rejected. |
| Dedup | Two publishes with the same idempotency key within the window → one message |
| Per-key ordering | With `ordering: per_key`, successful processing order per key = publish order |
| Delay correctness | No delivery before `available_at` (allowing for broker clock) |
| Attempt accounting | Message reaches `dead` at exactly `max_attempts` |
| Duplicate rate | Measured and reported (expected > 0 only under crash/expiry faults) |

Post-1.0, the same checker runs against a Raft cluster with partitions (Jepsen proper, or Maelstrom for protocol prototypes).

### 6. Fuzzing
Go native fuzzing for: WAL record decoder, CEL filter inputs, REST/JSON decoding, cron expressions, JSONPath extraction, lease token parsing.

## Benchmark plan

**Rules (for credibility):** reproducible scripts in `bench/`, same machine class (e.g. AWS `c7gd.2xlarge` with local NVMe), competitors configured per their own production docs, **equivalent durability compared** (fsync per publish confirm vs fsync per publish confirm), open-loop load generation (no coordinated omission), HdrHistogram, publish raw data + configs. Invite the competitor communities to review the settings.

| Competitor | Config |
|---|---|
| RabbitMQ 4.x | Quorum queues (durable default) and classic queues v2. Publisher confirms, manual acks, prefetch tuned. Also `x-delayed-message` plugin for delay scenarios. |
| Redis 7/8 + BullMQ | AOF `appendfsync always` (durability-equivalent) and `everysec` (shown separately, clearly labelled) |
| turnq | `fsync=always` (default) and `interval` |

| Scenario | Measures |
|---|---|
| S1 Throughput (256 B, 1 KB, 16 KB payloads; 1/16/64 producers & consumers) | Max sustained msg/s publish+ack |
| S2 Latency at fixed load (25/50/75% of each system's max) | p50/p99/p999 publish→deliver, publish-confirm latency |
| S3 Deep backlog: 50M messages queued, then consume | Memory usage, consume rate stability, recovery time |
| S4 Delayed jobs: 10M scheduled over 1h | Timer accuracy (fire-time error p99), CPU |
| S5 Retry storm: 30% of jobs fail with backoff | Throughput of healthy jobs, retry accuracy |
| S6 **Noisy tenant**: tenant A publishes 1M burst, 100 small tenants publish 10/s | p99 latency of small tenants (RabbitMQ/BullMQ have no fairness, which is the headline chart) |
| S7 DLQ redrive 1M | Time to redrive, impact on live traffic |
| S8 Crash recovery: kill -9 with 10M backlog | Time to ready, lost acked publishes (must be 0) |
| S9 Observability overhead | turnq with `timeline: full` vs `failures` vs `off` (to prove the "see inside without killing throughput" claim) |
| S10 Push delivery | Deliveries/s to a local HTTP sink, behaviour under sink 503 storms (circuit) |

Results are published in `docs/site/benchmarks` with methodology, plus a "where turnq is slower" section. Honesty is a feature.
