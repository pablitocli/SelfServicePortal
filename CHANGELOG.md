# Changelog

All notable changes to the Self-Service Portal are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Planned work is tracked in [docs/roadmap.md](docs/roadmap.md).

## [Unreleased]

## [1.0.0] - 2026-10-05

First public release.

### Added

#### Platform
- Web portal and REST API on PowerShell 7 and Pode, with no database and no build step. State is kept in JSON files under `data/` with cross-process locking.
- Runs on Windows and Linux. HTTPS with a Windows certificate-store thumbprint, or a PEM/PFX file. `-Http` switch for lab use only.
- Automatic configuration migrations at start-up. Upgrades keep configuration, users, branding, secrets, requests and logs.

#### Service catalog (marketplace)
- JSON-driven catalog (`catalog/items/*.json`) with a published JSON schema and an item template. Each item is rendered as a marketplace card and a request form, grouped by category, with search.
- Input types `text`, `textarea`, `number`, `select`, `boolean`, `ipv4` and `credential`. Attributes for defaults, help, transforms, regex/length/range validation, form sections and conditional visibility (`visibleWhen`).
- Dynamic lookups from a cached vCenter inventory (`clusters`, `datastores`, `datastoreClusters`, `portgroups`, `templates`, `folders`, `vms`), from sites, and from the cloud landing-zone settings (`awsSubnets`, `awsInstanceTypes`, `azureSubnets`, `azureVmSizes`), with `dependsOn`, regex filters and free-space thresholds.
- Server-side re-validation of every submitted value, including every select value against its allowed options.
- Catalog validator shared by the loader, the editor and `tools/Test-CatalogItem.ps1`. Invalid items are skipped and reported to administrators with the reasons.
- Hot reload: items and handler scripts are picked up without a restart.
- Per-site fixed parameters (`{ "DC1": ..., "*": ... }`), and vault credential bindings per handler parameter (`execution.credentials`).
- Admin catalog editor: create, edit, validate and archive items, inspect handler parameters, generate a handler skeleton, and edit the raw JSON. Previous versions are archived in `catalog/_archive/`.

#### Requests, approvals and execution
- Request lifecycle `PendingApproval` → `Queued` → `Dispatched` → `Running` → `Succeeded` / `Failed`, plus `Rejected` and `Cancelled`, with full history.
- Optional approval per item, with configurable approver roles. Self-approval is blocked by default, and rejection requires a comment.
- Out-of-process job runner (one `pwsh` process per request) with a concurrency limit, per-item timeouts, crash detection, a live job log, structured results and rollback on failure (`jobs.rollbackOnFailure`).
- Handlers are confined to `automation/handlers` and the folders listed in `automation.allowedHandlerRoots`.
- The execution contract is snapshotted with each request at submission time.

#### Teams
- Teams (for example Infrastructure and Cloud) scope catalog items, request lists and approvals. Membership comes from directory groups or from the local-user settings.

#### VM notes
- Configurable VM notes fields for new builds (text, textarea, select, required, help, pattern). They are written to the vSphere VM notes, and as `Note-<Label>` tags on AWS and Azure.

#### Branding and customization
- Admin > Customization: product name, organization, logo (PNG/JPEG/WebP, max 512 KB), colors, login message, footer and support contact; teams; directory role mapping; VM notes; policies. All are applied live.

#### Connections
- vCenter connections per site: endpoint, service account, application/database workload clusters, allowed clusters, port-group filter, folder, DNS settings, certificate policy and connection test. Scheduled and on-demand inventory refresh.
- AWS (access key or assumed role) and Azure (service principal or managed identity) connections, with landing-zone settings, images and a connection test.

#### Shipped catalog items
- Datacenter (vSphere): Windows Server 2025 VM, AlmaLinux VM. The template is fixed per site, the workload type selects the cluster, and VM notes are included.
- Datacenter operations (day 2): VM power action, add disk, resize CPU/memory, pre-change snapshot with expiry stamp.
- Cloud Ops: AWS EC2 and Azure VM, each with Windows Server 2025 or AlmaLinux.

#### Credential vault
- AES-256-GCM vault for automation credentials (username/password, SSH key, API token, certificate, service principal). Key providers: `auto`, `keyfile`, `dpapi`, `env`.
- Secrets are write-only through the UI and API, and decrypted only by job runners and connection tests. Scopes cover system, teams and catalog items, with tags, expiry and version history. Every use is audited and secrets are masked in job logs.
- `credential` catalog inputs with `vaultTags` filtering.
- Automatic migration of legacy DPAPI CliXml site and cloud credentials into the vault.

#### Identity
- Sign-in with local accounts, Active Directory and OpenLDAP (LDAPS, StartTLS, and Kerberos/NTLM sign-and-seal on Windows). Direct or search bind, and nested, `memberOf` or search group resolution.
- Admin > Identity: provider management, connection test and sign-in simulation.
- Roles `Requester`, `Approver`, `Admin`, plus `CatalogAdmin`, `SecurityAdmin` and `VaultAdmin` for separation of duties, mapped from directory groups.

#### User security
- Password policy (length, character classes, history, maximum age), forced password change, and account lockout.
- TOTP MFA with one-time recovery codes. MFA is required for the administrative roles by default.
- Break-glass local accounts that remain usable when local sign-in is disabled.
- Active-session list and revocation. 30-minute idle timeout with a warning, and an absolute session lifetime.
- Re-authentication for sensitive actions. Catalog items can opt in with `security.requireReauth`, and inputs with `requireReauth`.
- Administrative roles can be restricted to admin networks (CIDR). Trusted reverse proxies are supported.
- Vault administrators cannot approve jobs that use vault credentials (configurable).
- Anti-forgery header on state-changing calls. Local passwords are hashed with PBKDF2-SHA256. Audit trail of security and workflow events.

#### Linux and appliance
- Linux installer (`packaging/linux/install.sh`) for AlmaLinux, RHEL and Rocky Linux 9, and Ubuntu 24.04. It is idempotent, supports offline installation, and runs the portal as a systemd service. Includes a backup script.
- OVA appliance based on AlmaLinux 9, built with Packer. Per-instance settings come from OVF properties and are applied by a first-boot service.

#### Tooling and documentation
- `tools/` scripts for prerequisites, endpoint configuration, local users, credential registration and catalog validation.
- Offline smoke test suite (`tests/Invoke-SmokeTest.ps1`).
- Technical documentation in `docs/`.

[Unreleased]: https://github.com/OWNER/SelfServicePortal/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/OWNER/SelfServicePortal/releases/tag/v1.0.0
