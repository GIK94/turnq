# Security Policy

## Reporting a vulnerability

**Please do not open public issues for security problems.**

Report privately via **[GitHub Security Advisories](https://github.com/turnq/turnq/security/advisories/new)** (preferred), or email **security@turnq.dev** <!-- TODO: replace with a real, monitored address before launch -->.

Please include:
- affected version(s) and deployment mode (server / embedded / local sidecar)
- a description of the issue and its impact
- steps to reproduce or a proof of concept
- any suggested fix

## Our commitment

| Step | Target |
|---|---|
| Acknowledge receipt | 2 working days |
| Initial assessment and severity (CVSS v4) | 7 days |
| Fix for critical/high severity | 30 days |
| Coordinated public disclosure | At release of the fix, or 90 days after the report, whichever is sooner, unless agreed otherwise |

We credit reporters in the advisory unless you prefer to stay anonymous. We request CVE IDs through GitHub.

## Supported versions

| Version | Supported |
|---|---|
| Latest minor release | ✅ security + bug fixes |
| Previous minor release | ✅ security fixes for 6 months after the next minor |
| Older / pre-release (`< 0.1`) | ❌ |

After 1.0, each major version gets security fixes for at least 12 months after the next major is released.

## Scope

In scope: the `turnq` server and CLI, the embedded engine, official SDKs, the dashboard, official Docker images and Helm chart.

Particularly interesting areas: authentication and API-key scoping (including tenant isolation), push delivery (SSRF, signature verification), lease-token forgery, payload exposure via search/dashboard, and storage corruption from crafted input.

Out of scope: DoS from unauthenticated traffic on a broker deployed without auth contrary to docs; vulnerabilities in third-party dependencies with no demonstrated impact on turnq (please report those upstream).

## Release integrity

Release binaries and container images are signed with [cosign](https://github.com/sigstore/cosign) (keyless) and ship with an SBOM. Verify with:

```bash
cosign verify ghcr.io/turnq/turnq:<version> \
  --certificate-identity-regexp 'https://github.com/turnq/turnq/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
