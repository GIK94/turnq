# Governance

turnq is an Apache-2.0 project run in the open by its maintainers.

## Roles

| Role | Who | Can |
|---|---|---|
| **Contributor** | Anyone who opens an issue, PR, or discussion | Propose changes |
| **Reviewer** | Contributors with sustained quality reviews in an area | Approve PRs in that area (counts toward the review requirement) |
| **Maintainer** | Listed below | Merge, release, triage security reports, accept RFCs |

## Maintainers

| Name | GitHub | Areas |
|---|---|---|
| _TBD (project founder)_ | _@handle_ | all |

## Decision making

- Day-to-day: lazy consensus on PRs. If no maintainer objects within the review window, approved changes merge.
- RFCs: accepted when at least two maintainers approve (or the sole maintainer, while there is only one) and no maintainer objects after the 7-day comment period.
- Disagreements: discussed on the RFC/issue. If unresolved, maintainers vote with a simple majority. The project founder breaks ties until there are 3+ maintainers.

## Becoming a reviewer or maintainer

Reviewer: nominated by a maintainer after roughly 3 months of regular, high-quality contributions or reviews in an area.
Maintainer: nominated by an existing maintainer and approved by a two-thirds majority of maintainers.
Inactive maintainers (6 months without activity) move to emeritus status. They can return on request.

## Releases

Any maintainer can cut a release following [docs/VERSIONING.md](docs/VERSIONING.md) and the release checklist (including the "hard-to-get-right" checklist in `docs/design/12-roadmap-risks.md`).
