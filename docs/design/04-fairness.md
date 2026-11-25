# 4. Multi-tenant fairness

## Goal

Within a queue, when consumers have capacity, each **backlogged** tenant gets a share of deliveries proportional to its weight, regardless of how many messages it has queued. A tenant that publishes 10M messages must not add latency to a tenant that publishes 10.

"Fair" here means fair **delivery slots** (lease grants), optionally weighted by a per-message `cost`. It doesn't mean fair CPU time at the consumer. Time-based fairness is covered under post-1.0 below.

## Algorithms compared

| Algorithm | Dequeue cost | Fairness bound | State per tenant | Weights | Notes |
|---|---|---|---|---|---|
| Single FIFO | O(1) | None | — | No | What RabbitMQ does. The noisy tenant wins. |
| Round robin over per-tenant queues | O(1) | 1 message | queue + list node | No | Ignores weights and cost |
| **Deficit Round Robin (DRR)** | **O(1) amortised** | ≤ quantum + max_cost per round | queue + deficit counter | **Yes (quantum × weight)** | Simple, robust, constant time |
| Weighted Fair Queuing (WFQ / virtual finish time) | O(log n) (heap) | Tightest (≈ 1 packet) | finish tag + global virtual time | Yes | Virtual time bookkeeping is subtle with idle/active churn and with blocked tenants |
| Stochastic Fair Queuing (hash into K buckets) | O(1) | Probabilistic. Collisions share a bucket. | K buckets | Weak | Good for unbounded keys (network flows). We know tenant ids, so it's unnecessary. |
| Virtual queues + random pick (power of two choices) | O(1) | Statistical | queue | Approx | Too fuzzy to explain to users |

**Choice: DRR** over per-(queue, tenant) virtual queues, with:
- `quantum = base_quantum × weight` (default `base_quantum = 1` cost unit ≈ one message), which gives near-WRR smoothness,
- an **active list** that only contains tenants that are both backlogged **and eligible**,
- **parking** of tenants blocked by limits, with a wake-up timer or event, so the scheduler never spins.

Why not WFQ: the tighter bound (1 message vs ~1 quantum) is invisible at job-queue timescales, and with per-tenant concurrency and rate limits, tenants constantly become ineligible. In WFQ that requires careful virtual-time handling (stale finish tags give a returning tenant a burst or a penalty). With DRR, "remove from active list, reset or keep deficit" is a one-line, well-understood rule.

## Structures (per queue, per shard)

```go
type VQueue struct {            // one per (queue, tenant) with ready messages
    tenant     TenantID
    weight     uint32
    deficit    int64
    heads      [10]*ring        // per-priority head buffers (9 first), paged from Pebble r/
    inFlight   uint32           // leased count for this tenant on this queue
    state      enum{Active, Parked, Empty}
    wakeAt     time.Time        // for rate-limit parking
    listNode   *list.Element    // position in active list
}

type Scheduler struct {
    active       *list.List           // round-robin order of eligible tenants
    vqs          map[TenantID]*VQueue
    parkedTimers TimerWheel           // wakes rate-limited tenants
    cursor       *list.Element        // current tenant in round
    quantumGiven bool                 // whether current tenant has received its quantum this visit
}
```

## Pseudocode

```go
// Called whenever a consumer has credits. Returns up to n deliveries.
func (s *Scheduler) Next(n int, now time.Time) []Delivery {
    out := make([]Delivery, 0, n)
    visitedWithoutProgress := 0

    for len(out) < n && s.active.Len() > 0 {
        vq := s.current()

        if !s.quantumGiven {
            vq.deficit += int64(base_quantum * vq.weight)
            s.quantumGiven = true
        }

        progressed := false
        for len(out) < n {
            msg, ok := vq.peekEligible(now)      // highest priority, skipping messages whose
                                                 // ordering key or key-limit is blocked (see below)
            if !ok {
                // Tenant has backlog but nothing eligible: park instead of spinning.
                s.park(vq, now)
                break
            }
            cost := msg.cost                     // default 1
            if cost > vq.deficit { break }       // wait for next round

            if why := s.tenantBlocked(vq, now); why != nil {   // max_in_flight / rate limit
                s.park(vq, now, why)
                break
            }
            vq.pop(msg)
            vq.deficit -= cost
            vq.inFlight++
            s.chargeLimits(vq, msg, now)         // token buckets, key counters
            out = append(out, s.lease(msg))
            progressed = true

            if vq.isEmpty() {
                s.deactivate(vq)                 // remove from active list
                vq.deficit = 0                   // classic DRR: no banking credit while idle
                break
            }
        }

        if progressed { visitedWithoutProgress = 0 } else { visitedWithoutProgress++ }
        if visitedWithoutProgress > s.active.Len() { break } // everyone is waiting on deficit; next call continues
        s.advance()                              // move cursor to next tenant, quantumGiven = false
    }
    return out
}

func (s *Scheduler) OnPublishReady(msg *Message) {   // publish, delay elapsed, retry elapsed
    vq := s.getOrCreate(msg.tenant)
    vq.push(msg)
    if vq.state == Empty {
        vq.state = Active
        s.active.PushBack(vq)                     // join at the tail: no jumping the round
    }
}

func (s *Scheduler) OnAckOrNack(msg *Message) {
    vq := s.vqs[msg.tenant]
    vq.inFlight--
    s.releaseKeyLimits(msg)
    if vq.state == Parked && s.tenantBlocked(vq, now) == nil && vq.hasEligible() {
        s.unpark(vq)                              // back to tail of active list
    }
}

func (s *Scheduler) park(vq *VQueue, now time.Time, why ...) {
    s.active.Remove(vq.listNode)
    vq.state = Parked
    // keep deficit (capped at quantum*weight) so a briefly-parked tenant isn't punished
    vq.deficit = min(vq.deficit, int64(base_quantum*vq.weight))
    if rateLimited(why) { s.parkedTimers.Add(vq, nextTokenAt) }
    // concurrency-parked tenants are unparked by OnAckOrNack / lease expiry
}
```

### How the other limits compose (evaluation order per candidate message)

1. **Queue paused / queue rate limit**: if blocked, the whole scheduler sleeps until the next token arrives.
2. **DRR picks tenant** (only eligible tenants are in the active list).
3. **Tenant caps** (`max_in_flight`, tenant rate): if hit, park the tenant.
4. **Priority within tenant**: scan priority buckets 9 → 0.
5. **Ordering key / key limits**: `peekEligible` skips messages whose key is saturated. The head buffer keeps a small *skip list* of blocked keys so this is O(blocked keys in the head), and a key whose holder is acked wakes that tenant.
6. **Cost vs deficit.**

## Complexity and scaling

| Operation | Cost |
|---|---|
| Next() per delivery | O(1) amortised (+ O(b) skipped blocked-key messages in the head buffer, bounded by 256) |
| Publish-ready | O(1) |
| Ack | O(1) |
| Memory | ~200 B per active tenant + head buffers. 100k active tenants ≈ 20 MB + head buffers. |
| Idle tenants | Evicted from memory once empty with no in-flight messages for 5 min, and recreated on demand |

## Edge cases

| Case | Behaviour |
|---|---|
| New tenant appears mid-round | Joins at the tail with deficit 0, so it can't jump ahead. Worst-case wait is one round, which with quantum = 1 is roughly `active_tenants` deliveries. |
| 100k tenants with 1 message each + 1 tenant with 10M | Each tenant gets 1/(100k+1) of slots. The big tenant gets 1 per round, as intended. Latency for small tenants is bounded by round length, not by the big tenant's backlog. |
| All tenants blocked by caps | Active list is empty, so `Next` returns nothing. Consumers wait (long-poll or stream idle). Explain shows "all tenants at cap". |
| Tenant weight changed live | Applies from the next quantum grant. No rebalancing needed. |
| Message with cost > quantum × weight | Deficit accumulates across rounds until it's sufficient. Cost is also capped at `max_cost` (default 100) to keep the bound sane. |
| Consumer filters by tenant (`Consume(tenant=acme)`) | Bypasses DRR and dequeues directly from that vq. Tenant caps still apply. |
| Retry-heavy tenant | Retries re-enter its own vq after backoff. They compete only with that tenant's own messages, so one tenant's retry storm can't take others' slots. |
| Delayed burst (1M messages due at 09:00) for one tenant | They land in that tenant's vq. Fairness still holds, and other tenants aren't affected. |
| Untenanted messages | Tenant `_default` (weight configurable). If a team never sets tenant, behaviour equals a normal FIFO+priority queue. |
| Partitioned queues | Fairness is per partition. With tenant-hash partitioning, a tenant lives in one partition and fairness is exact per partition. |
| Restart | Deficits reset to 0. That's harmless, since every tenant restarts equal. |

## Per-tenant quotas (enforced at publish, in the gateway, off-shard)

- `max_queued` / `max_bytes`: counters kept in the shard and mirrored to an atomic snapshot the gateway reads. Over quota → `RESOURCE_EXHAUSTED` with `turnq-quota: tenant` detail.
- Publish rate: a token bucket in the gateway (per node).

## Post-1.0: time-based fairness

`fairness.mode: drr_time` charges the **actual processing time** at ack (`cost = ack_at - leased_at`, in 100 ms units), letting deficit go negative ("debt"). Tenants whose jobs are 100× slower then get proportionally fewer slots. This is valuable for mixed workloads. It's deferred because it interacts with lease expiry accounting and needs good simulation coverage first.
