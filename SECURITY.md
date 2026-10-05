# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes |

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub's *Report a vulnerability* button (Security tab →
Private vulnerability reporting) of this repository. Do not open a public issue, pull request or discussion.

Include: affected version, a description of the issue and its impact, steps to reproduce or a proof of concept,
and any suggested fix. Remove real host names, credentials and personal data.

We aim to acknowledge reports within 5 working days and to agree on a disclosure timeline with the reporter.
Fixes are released as a patch version and noted in `CHANGELOG.md`.

## Scope

In scope: the portal code in this repository (web application, API, modules, job runner, catalog handlers,
installers and the OVA build). Out of scope: third-party products the portal automates (vSphere, Active Directory,
cloud providers), deployments that ignore the hardening guidance in [docs/security.md](docs/security.md), and
denial-of-service through resource exhaustion of an unprotected lab instance.

The security model and hardening checklist are described in [docs/security.md](docs/security.md).
