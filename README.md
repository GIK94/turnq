# turnq

**A message queue you can see inside.** Retries, delays, cron, replay and per-tenant fairness built in. HTTP push delivery for serverless. One binary, five-minute setup, or embed it in your app.

> **Status: design phase.** Nothing is runnable yet. Start with the [design docs](docs/design/README.md) and the [roadmap](docs/design/12-roadmap-risks.md).

## Why turnq (vs RabbitMQ)

| You want to… | RabbitMQ | turnq |
|---|---|---|
| Find out why a message is stuck | Not possible per message | `turnq explain <id>`: ranked reasons, plus a full timeline of every attempt |
| Retry with exponential backoff | DLX + TTL queue chains | `retry: {max_attempts: 8, backoff: exponential}` |
| Delay or schedule a job | Plugin or TTL tricks | `--delay 5m`, `--at`, cron schedules |
| Replay a DLQ | Shovel / custom scripts | `turnq redrive emails --filter '…' --spread 10m` |
| Stop one customer starving others | Not built in | Weighted fair queuing per tenant, by default |
| Deliver to Lambda / Workers / Vercel | Not built in | Signed webhooks with retries and circuit breaking |
| Operate it | Erlang cluster | One static binary, one data dir |
| Use it in tests or a small app | Run a broker | `turnq.Open("file://./data")` in-process |

## Concepts in one minute

Queues (work, with competing consumers) and topics (fan-out to subscription queues). Messages are delivered at-least-once with lease tokens. Idempotency keys deduplicate publishes. Retries, delays, priorities, ordering keys, concurrency limits and tenant fairness are queue configuration, not patterns you build yourself.

## Docs

- [Design overview, assumptions & open questions](docs/design/README.md)
- [Architecture](docs/design/01-architecture.md) · [Data model](docs/design/02-data-model.md) · [Storage](docs/design/03-storage.md) · [Fairness](docs/design/04-fairness.md) · [Push delivery](docs/design/05-push-delivery.md) · [Embedded mode](docs/design/06-embedded-mode.md)
- [API](docs/design/07-api.md) ([protos](api/proto/turnq/v1/)) · [SDKs](docs/design/08-sdks.md) · [Dashboard](docs/design/09-dashboard.md)
- [Engineering & testing](docs/design/10-engineering.md) · [Open source](docs/design/11-open-source.md) · [Roadmap & risks](docs/design/12-roadmap-risks.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please read the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues per [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
