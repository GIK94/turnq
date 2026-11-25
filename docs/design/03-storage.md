# 3. Storage design

## Decision: commit log as source of truth, Pebble as a materialised view

| Option | Verdict |
|---|---|
| A. Everything in Pebble (with Pebble WAL) | Simplest. But payloads go through LSM compaction (write amplification of 10–30× on 1 KB+ values), there's no natural replay stream, and you'd need a separate Raft log later. |
| **B. Own segmented log (payloads + transitions) + Pebble view with WAL disabled** | **Chosen.** One fsync per group commit. Payloads are written once, sequentially. The log is the replay stream, the timeline source and the future Raft log. Pebble holds only small keys. |
| C. Own log + own index (no KV) | Months of B-tree/LSM work for no differentiation. |

**Pebble vs BadgerDB:** Pebble. It's RocksDB-compatible, battle-tested in CockroachDB, has excellent range deletions and iterators, pure Go, and no value-log GC to tune. Badger's main advantage (key-value separation) is something we already get from our own log.

## Storage interface (pluggable)

The engine talks to a `Store`, never to Pebble directly:

```go
package store

type Store interface {
    // Append durably records engine records. The returned future resolves when
    // the records are durable according to the fsync policy. Records are applied
    // to the view in order.
    Append(recs []Record, durability Durability) Future

    // Read path (snapshot-consistent, never blocks Append).
    GetMessage(ctx context.Context, id MsgID) (*Message, error)
    Payload(ctx context.Context, ref PayloadRef) ([]byte, error)
    ScanReady(queue QueueID, tenant TenantID, after Cursor, limit int) ([]ReadyEntry, Cursor, error)
    ScanDue(until time.Time, limit int) ([]DueEntry, error)
    LookupIdempotency(queue QueueID, key string) (MsgID, bool, error)
    Timeline(ctx context.Context, id MsgID) ([]Event, error)
    Search(ctx context.Context, q Query) (Iterator[*Message], error)

    // Recovery: stream every non-terminal message so the engine can rebuild memory state.
    Recover(fn func(*Message) error) error

    Retention(ctx context.Context, policy RetentionPolicy) error
    Close() error
}
```

| Impl | Use | Status |
|---|---|---|
| `memstore` | Tests, ephemeral dev (`turnq dev --memory`) | v0.1 |
| `logstore` | Default: segmented log + Pebble | v0.1 |
| `pgstore` | Durability on managed Postgres. Single active broker (advisory lock), others hot standby. | v0.5 |
| `storetest` | Conformance suite every implementation must pass | v0.1 |

The engine (scheduling, fairness, limits) is **storage-agnostic**. Postgres isn't used as a queue (`SKIP LOCKED`). It's used as durable storage behind the same engine, so semantics stay identical.

## On-disk layout

```text
data/
├── TURNQ_FORMAT            # "format=1 shards=8 created=..." (refuse to open unknown formats)
├── LOCK                    # flock, single process
├── log/
│   ├── 00000000000000000000.seg     # 256 MiB segments
│   ├── 00000000000000000000.idx     # sparse index: record_index → file offset (every 4 KiB)
│   ├── 00000000000268435456.seg
│   └── ...
├── view/                   # Pebble directory (WAL disabled)
├── checkpoints/            # periodic Pebble checkpoints for fast restore/backup
└── tmp/
```

### Log record format

```text
┌──────────┬──────────┬──────────┬─────────┬────────────┬──────────────┐
│ len u32  │ crc32c   │ index u64│ type u8 │ shard u16  │ body (proto) │
└──────────┴──────────┴──────────┴─────────┴────────────┴──────────────┘
```

Record types: `PUBLISHED` (includes payload + headers), `FANOUT_PUBLISHED` (one payload, N message ids), `LEASED`, `EXTENDED`, `ACKED`, `NACKED`, `RETRY_SCHEDULED`, `LEASE_EXPIRED`, `DEAD_LETTERED`, `EXPIRED`, `CANCELLED`, `REPLAYED`, `PAYLOAD_RELOCATED`, `TOMBSTONE` (purge), `CONFIG_*`, `CHECKPOINT_MARK`.

A `PayloadRef` is `(segment_base, offset, len)` pointing into the `PUBLISHED` record's body, so payloads are read with `pread`, with no copy into Pebble.

## Pebble key layout (the view)

Keys are binary. Queue and tenant names are interned to `u32` ids (`c/q/` and `c/t/` maps) so keys stay short.

| Prefix | Key | Value | Purpose |
|---|---|---|---|
| `m` | `m/{msg_id}` | Message meta (proto, ~150 B): state, attempt, tenant, queue, available_at, payload_ref, headers ref, idem, ordering key, lease info, last_error | Point lookup |
| `r` | `r/{q}/{t}/{9-prio}/{seq}` | msg_id | Ready index (per tenant virtual queue, priority-ordered then FIFO) |
| `d` | `d/{due_ms}/{msg_id}` | q | Scheduled + retrying (timer source) |
| `l` | `l/{deadline_ms}/{msg_id}` | lease epoch | Lease expiry (persisted for recovery) |
| `k` | `k/{q}/{ordering_key}` | head msg_id / holder | Ordering key locks |
| `i` | `i/{q}/{idem_key}` | msg_id, first_seen | Dedup (TTL via retention sweep) |
| `s` | `s/{q}/{state}/{created_ms}/{msg_id}` | ∅ | Browse by state (DLQ list, "all retrying") |
| `x` | `x/{q}/{t}/{created_ms}/{msg_id}` | state | Browse by tenant |
| `f` | `f/{q}/{field_no}/{value}/{created_ms}/{msg_id}` | ∅ | Indexed payload fields |
| `e` | `e/{msg_id}/{event_seq}` | Event (proto, ~40–120 B) | Timeline |
| `g` | `g/{segment_base}` | live payload count, bytes | Segment GC accounting |
| `c` | `c/{kind}/{name}` | config | Queues, topics, subs, schedules, tenants, hashed API keys |
| `meta` | `meta/applied_index` | u64 | Last log index applied (written in every batch) |

**Write cost per happy-path message:** publish = 5 keys (m, r, s, x, + i if keyed), lease = 4 (m, r-del, l, s-move), ack = 4 (m, l-del, s-move, e). These are small keys in batched, WAL-less writes, which is well inside Pebble's budget (>1M small ops/s on NVMe), so the 50k msg/s target leaves headroom.

## Memory model (bounded, no matter the backlog)

The shard does **not** keep every ready message in memory:

- Per (queue, tenant) virtual queue: an in-memory **head buffer** of up to 256 entries (`{msg_id, prio, seq, ordering_key_hash, key_limit_hash}`, ~48 B).
- When the head buffer drops below 64 entries, the shard asynchronously **pages in** the next entries from `r/{q}/{t}/…` via a Pebble iterator.
- Delayed messages: a hierarchical **timer wheel** for anything due in the next 10 minutes. Beyond that, `d/` is scanned every 30 s for items entering the horizon.
- Leases: an in-memory min-heap (bounded by in-flight count, which consumer credits bound).
- **100M backlog cost:** about 100k tenants × 256 × 48 B ≈ 1.2 GB worst case. That's tunable via `head_buffer`, and idle tenants are evicted from memory.

## Group commit and fsync policy

```yaml
storage:
  fsync: always          # always | interval | never
  fsync_interval: 10ms   # for interval
  group_commit: { max_delay: 1ms, max_bytes: 256KiB }
```

- `always` (default): publish replies only after fsync. Group commit amortises the cost, so throughput scales with concurrency.
- `interval`: up to `fsync_interval` of acknowledged publishes can be lost on power failure (not on process crash, since the data is in the OS page cache).
- `never`: dev/benchmarks only. The startup banner warns loudly.

## Crash recovery

1. Acquire `LOCK`. Read `TURNQ_FORMAT`.
2. Open Pebble. Read `meta/applied_index = A`. With the WAL disabled, Pebble's durable state is a **consistent prefix** of applied batches (memtables flush in order, and `applied_index` is in every batch).
3. Scan log segments from the one containing `A+1`. Validate CRC per record. **Truncate at the first torn or corrupt record in the last segment** (a torn tail is expected after a crash). Corruption in a non-tail segment is a fatal error with a clear message (`turnq repair`).
4. Re-apply records `A+1..end` to Pebble (they're idempotent: apply is a pure function of record + prior state).
5. `Recover()`: rebuild shard memory (ready head buffers, timer wheel, lease heap, ordering-key holders, in-flight counts per tenant/key) by iterating `l/`, `k/`, `d/` (horizon only), and the first page of each `r/{q}/{t}`.
6. **Leases found in `l/` are kept, with their remaining duration re-armed on the monotonic clock.** We don't expire them all immediately: consumers may still be alive and reconnect with valid tokens. Token validation survives restart because tokens are HMAC'd with a persisted key.
7. Rate-limit token buckets start full (documented: a restart can allow one burst).

Target: < 5 s recovery for a 10M-message backlog (bounded by step 5 being lazy).

Periodic **Pebble flush + checkpoint** every 5 min (or 1 GiB of log) bounds replay length.

## Retention and compaction

**Message retention:** a background sweeper walks `s/{q}/{terminal_state}/{created_ms}` older than the retention horizon and deletes `m`, `s`, `x`, `f`, `e` keys with **range deletes where possible**. It decrements `g/{segment}` live counts.

**Log segment GC:** a segment is deletable when
1. all its records are below the last checkpoint's `applied_index`, **and**
2. its live payload count is 0 (all referenced messages are terminal and past retention).

**Long-lived payloads pin old segments.** A message delayed 90 days, or sitting in a DLQ for 14 days, keeps a 256 MiB segment alive. Compaction handles this: when a segment is older than `compaction.min_age` (1h) and live bytes are under 20%, the compactor re-appends those payloads as `PAYLOAD_RELOCATED` records at the head and updates `m/` refs, after which the old segment becomes deletable. This is rate-limited to an IO budget (default 20 MB/s).

**Purge / GDPR:** `PurgeTenant(tenant)` writes a `TOMBSTONE`, deletes view keys immediately (so the data is unreadable via the API), and marks affected segments for priority compaction, so payload bytes physically disappear within `compaction.purge_sla` (default 24h). This is documented honestly.

## Observability data: how we get "see inside" without killing throughput

The insight is that **the timeline is a projection of the commit log**, which we're writing anyway. It doesn't need a second pipeline.

| Concern | Approach |
|---|---|
| Event capture cost | Events are derived by the view applier from records already in the log. There's no extra fsync and no extra hot-path work in the shard. |
| Event volume | `timeline: full` (default) stores ~3 events per happy-path message. `failures` stores only nack/expiry/DLQ/replay events. The happy path is reconstructed from `m/` timestamps (created, leased_at, acked_at). `off` stores only `m/`. |
| Indexing | Always: id, idempotency key, queue+state, queue+tenant. Opt-in: ≤ 8 JSON-path fields per queue, extracted once at publish in the gateway (off-shard). |
| Ad-hoc payload search | CEL expression evaluated over a **bounded scan** narrowed by indexes (queue, state, tenant, time range). Default scan budget is 100k messages or 2 s, with a resumable cursor. No full-text index (that's an explicit non-goal; export to your log stack if needed). |
| Read isolation | Search and inspect run on Pebble snapshots, in a separate goroutine pool with a concurrency limit, never on shard goroutines. |
| Metrics | Per-queue counters/gauges are maintained in-shard (atomic, cheap). **Tenant labels are opt-in** (`metrics.tenant_labels: top_k=50`) to avoid Prometheus cardinality explosions. Per-tenant detail is served via the API/dashboard from the view instead. |
| Retention | Timeline retention = message retention. Aggregated time series (1-min buckets, 7 days) live in the view under `ts/` for the dashboard's charts, so Prometheus isn't required to see a graph. |
| Tracing | `traceparent` stored in headers. The broker emits `publish` and `deliver` spans (OTel messaging semconv). The consumer SDK starts a `process` span **linked** to the publish span. Sampling follows the producer's decision. |

### Example: what a timeline looks like (API output)

```json
{
  "id": "msg_01jdq3v8x7k2m9p4r6t8w0y2a4",
  "queue": "emails", "tenant": "acme", "state": "dead",
  "events": [
    {"at":"2026-11-25T10:00:00.001Z","type":"published","source":"api","idempotency_key":"welcome-u42"},
    {"at":"2026-11-25T10:00:00.004Z","type":"leased","attempt":1,"consumer":"worker-7","lease_until":"…:30.004Z"},
    {"at":"2026-11-25T10:00:02.310Z","type":"nacked","attempt":1,"error":{"code":"SMTP_421","message":"try later"}},
    {"at":"2026-11-25T10:00:02.310Z","type":"retry_scheduled","attempt":1,"next_at":"…:03.400Z","backoff":"1.09s"},
    {"at":"2026-11-25T10:00:03.401Z","type":"leased","attempt":2,"consumer":"worker-2"},
    {"at":"2026-11-25T10:00:33.401Z","type":"lease_expired","attempt":2,"note":"no heartbeat; suspected consumer crash"},
    {"at":"…","type":"dead_lettered","attempt":8,"reason":"max_attempts"}
  ]
}
```

## Hard parts flagged

- **Clock jumps:** `available_at` and cron times are wall-clock (they must be, since users mean "at 02:00 Berlin"). The timer wheel is driven by the monotonic clock and re-anchored to the wall clock every second. A backward jump of more than 1 s is logged and exported as a metric. Messages already due stay due, and we never "un-fire". Run NTP. This is documented.
- **Torn writes:** CRC per record plus truncate-tail-only. Tested with LazyFS (drops un-fsynced data) and kill -9 loops.
- **View/log divergence bugs:** `turnq verify` replays the log into a scratch view and diffs it against the live view. It runs in CI chaos tests and can be run by operators.
