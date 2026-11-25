# Versioning and stability policy

turnq follows [Semantic Versioning 2.0.0](https://semver.org). Several surfaces are versioned, and each has its own contract.

## Surfaces

| Surface | Version scheme | Contract |
|---|---|---|
| Server binary / Docker image | SemVer `vMAJOR.MINOR.PATCH` | Described below |
| gRPC/REST API | Proto package (`turnq.v1`, `turnq.v1alpha1`) | `v1` is wire- and JSON-compatible for its whole life. Breaking changes require `v2`. |
| On-disk format | `TURNQ_FORMAT format=N` | Forward upgrade is automatic. Downgrade is only via `turnq migrate` export/import. |
| SDKs (Go, Node, Python) | Independent SemVer per SDK | Each SDK documents the minimum server version it supports |
| Config file | `version: 1` key | Old keys are deprecated with warnings for at least one minor release before removal |
| CLI | Follows server version | Flags and output marked `--output json` are stable. Human-readable output is not. |
| Metrics names | Follows server version | Renames go through a deprecation (both names exported for one minor) |

## Before 1.0 (`0.x`)

- **Minor** releases (`0.4 → 0.5`) **may** contain breaking changes. Every one is listed under "Breaking" in `CHANGELOG.md`, with a migration note.
- **Patch** releases (`0.5.1 → 0.5.2`) never break anything.
- The on-disk format may change between minors, but **an upgrade path is always provided** (automatic on startup or via `turnq migrate`). We never require you to drop data.
- The `turnq.v1` proto package is "release candidate". `buf breaking` runs in CI, and intentional breaks need an RFC.

## From 1.0

- **Major**: breaking changes to `turnq.v1` semantics, config, CLI JSON output, or removal of deprecated features. We target at most one major per year.
- **Minor**: new features, new optional fields/RPCs, new config keys, new disk format versions *with automatic upgrade*.
- **Patch**: bug and security fixes only.
- **Rolling upgrades** (post-clustering): `N → N+1` minor is supported in mixed-version clusters.
- **Delivery semantics are API.** Changing what at-least-once, ordering keys, dedup windows, or retry accounting mean is a breaking change, even when the wire format is unchanged.

## Stability levels for features

| Level | Marked as | Promise |
|---|---|---|
| **Stable** | default | Covered by SemVer |
| **Beta** | `beta` in docs; config under `beta:` | May change in a minor with a migration note. Will not be removed without a deprecation cycle. |
| **Experimental** | `turnq.v1alpha1` APIs, `--experimental-*` flags, `experimental:` config | Can change or disappear in any minor. Not for production. |

## Deprecation policy

1. Announce in the CHANGELOG and docs. Emit a runtime warning (log + `turnq_deprecated_usage_total` metric).
2. Keep the deprecated behaviour for **at least one minor release before 1.0**, and **until the next major after 1.0**.
3. Remove it, with a migration guide.

## Support window

See [SECURITY.md](../SECURITY.md#supported-versions).
