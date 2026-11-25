# Contributing to turnq

Thanks for helping build a queue people can see inside. This guide gets you from clone to merged PR.

## Ground rules

- Be kind. We follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- **Security issues are never filed publicly.** See [SECURITY.md](SECURITY.md).
- Small PRs merge faster. Open an issue first for anything bigger than a bug fix.
- Changes to the **public API, on-disk format, or delivery semantics** need an RFC (`docs/rfcs/`). See [below](#rfcs).

## Development setup

Requirements: Go (version in `go.mod`), Node 22+ with pnpm, Python 3.11+ with `uv`, Docker, and [`buf`](https://buf.build/docs/installation).

```bash
git clone https://github.com/turnq/turnq && cd turnq
make tools        # installs pinned linters/generators into ./bin
make build        # builds ./bin/turnq (and the dashboard)
make test         # unit tests with -race
make dev          # runs turnq server --dev on :7400 with the dashboard at /ui
```

Other useful targets: `make lint`, `make proto`, `make sim SEEDS=1000`, `make integration`, `make crash`, `make bench-smoke`. Run `make help` for the list.

## Making a change

1. Fork and branch from `main` (`fix/lease-race`, `feat/cron-misfire`).
2. Write tests first for bug fixes: a failing test that reproduces the bug.
3. Engine, store, or WAL changes **must** pass `make sim SEEDS=1000` locally. CI runs more.
4. If you touch `api/proto`, run `make proto` and commit the generated code. `buf breaking` must pass, or your PR must say why it's an intentional (pre-1.0) break.
5. Update docs (`docs/site`) in the same PR for user-visible changes.
6. Add a changelog entry in `CHANGELOG.md` under `Unreleased`.

### Commit sign-off (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/) instead of a CLA. Every commit must be signed off:

```bash
git commit -s -m "engine: reject ack with stale lease epoch"
```

This adds `Signed-off-by: Your Name <you@example.com>` and certifies you have the right to submit the work under Apache-2.0.

### Commit messages

`<area>: <imperative summary>`, e.g. `push: honour Retry-After on 503`. Areas: `engine`, `store`, `wal`, `push`, `cron`, `api`, `server`, `inspect`, `dashboard`, `sdk/go`, `sdk/node`, `sdk/python`, `docs`, `ci`, `bench`.

### Source headers

Every source file starts with an SPDX identifier:

```go
// SPDX-License-Identifier: Apache-2.0
```

## Pull request review

- One maintainer approval is required, or two for changes under `internal/engine`, `internal/store`, `internal/wal`, or `api/proto`.
- CI must be green. Flaky test? Open an issue and tag `flaky`. Don't just re-run.
- Maintainers aim for a first response within 3 working days.

## RFCs

Write `docs/rfcs/NNNN-short-title.md` (copy `0000-template.md`) for: new public APIs, semantic changes (delivery, ordering, retries), on-disk format changes, new dependencies in the core, or new top-level features. Open it as a PR with the `rfc` label. There's a minimum 7-day comment period, then maintainers accept, reject, or postpone.

## Good first issues

Look for [`good first issue`](https://github.com/turnq/turnq/labels/good%20first%20issue) and [`help wanted`](https://github.com/turnq/turnq/labels/help%20wanted). Comment on an issue to claim it.

## Questions

Use [GitHub Discussions](https://github.com/turnq/turnq/discussions) for questions and ideas. Issues are for bugs and accepted work.
