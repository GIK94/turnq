## What and why

<!-- What does this change, and why? Link issues: "Fixes #123". -->

## How was it tested?

<!-- Unit / sim seeds / integration / crash / manual. Paste relevant output. -->

## Checklist

- [ ] Commits are signed off (`git commit -s`, DCO)
- [ ] Tests added or updated
- [ ] `make lint test` passes locally
- [ ] Engine/store/WAL change: `make sim SEEDS=1000` passes
- [ ] Proto change: `make proto` run, generated code committed, `buf breaking` passes (or the break is justified below)
- [ ] User-visible change: docs updated + `CHANGELOG.md` entry under *Unreleased*
- [ ] Semantics/API/disk-format change: links an accepted RFC

## Breaking changes / risk

<!-- None, or describe and justify. -->
