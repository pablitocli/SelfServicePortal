# Changelog

All notable changes to the Self-Service Portal are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Planned work is tracked in [docs/roadmap.md](docs/roadmap.md).

## [Unreleased]

## [1.2.0] - 2026-10-23

### Added
- **Online demo**: a static build of the real web UI with sample data and simulated jobs (`tools/build_demo.py`, sources in `demo/src`, `netlify.toml` for one-click deploys). Nothing executes; see `docs/demo.md`.
- **Aria Operations integration** (optional, per site): Admin > vCenter connections > Aria Operations stores the endpoint, auth source, account (vault entry `aria-<site>`) and certificate policy; *Test Aria and sync reports* reads the report definitions, and the Admin ticks those offered in forms. Jobs get a token per run (`execution.aria`, `Context.Aria`), released at the end and masked in logs. Library `automation/lib/Portal.AriaOps.psm1`.
- **VM troubleshooting** (`vm-troubleshoot`): one VM, last hour / day / week or around an incident; vSphere counters of the VM and host (CPU ready, co-stop, balloon, swap, disk latency, drops), snapshots, Tools, events; optional read-only guest diagnostics (uptime, pending reboot, memory, disks, stopped services, error events); Aria Operations health, alerts and MAX-rollup peaks. Verdict, findings ranked by severity and number of sources, HTML report with charts, evidence pack (zip), optional Aria report (PDF).
- **Incident evidence export (RCA)** (`vm-incident-evidence`), **Aria Operations report** (`aria-report`).
- **Reports**: DRS rule compliance (`report-drs-compliance`, data file *Expected DRS rules*), before / after change metrics (`report-change-impact`), orphaned VMDK assessment across all sites (`report-orphaned-vmdk`).
- **Day 2**: local admins & RDP users (`guest-local-groups`), initialize data disks with letters and CD-ROM move (`guest-data-disks`, dry run by default), move VMs to folder (`vm-move-folder`), move computer to OU over LDAP (`ad-move-computer`, no RSAT).
- **Windows VM build (batch, bootstrap)** (`vm-windows-batch`): VM list as CSV with per-row validation (*Validate only*), clone with hardware, portgroup and extra disks, then a portal-driven bootstrap through VMware Tools (static IP, rename, Windows Update rounds, activation, firewall / RDP, recovery partition and C: extension, data disks, CD-ROM letter, domain join, local groups), read-only validation and a closure report with ticket text. Profile *Citrix*. Coexists with `vm-windows-2025`.
- **Admin items**: promote domain controller with mandatory snapshot, prerequisite test and verification (`dc-promote`), copy customization spec between sites with passwords from the vault (`spec-copy`).
- Lookup sources `ariaReports`, `adDirectories`, `adOus`. Report chart sections (`New-PortalReportChart`, inline SVG). Requests can attach `.pdf`, `.zip` and `.json` files.
- Configuration: `sites[].aria`, `operations.troubleshooting` (time zone and thresholds), `operations.orphanedDisks`, `operations.batchBuild`; data file `drs-rules.json`. Upgrades add them (Aria disabled).

### Changed
- `vm-power` 1.1.0: several VMs per request (*Additional VMs*) and an opt-in hard reset when VMware Tools is not running.
- Upgrades add any missing `operations.*` section, not only a missing `operations`.

### Security
- No secret is written inside a guest by the new items: domain, DSRM and local account passwords travel only in the sensitive script of the step that needs them (VMware Tools), never on a command line or in a file; the batch build cleans its update runner at the end.
- Account names and OU distinguished names are validated before they reach a guest script or an LDAP filter; LDAP filter values are escaped.

### Documentation
- requirements.md: vCenter privileges of the 1.2 items, Aria Operations account (8.5), ESXi 443 for guest operations, new pre-use configuration rows 15-19. configuration.md, catalog-authoring.md and the item contract updated.

## [1.1.3] - 2026-10-06

### Changed
- **License:** Apache License 2.0 with the "Commons Clause" License Condition v1.0. Free to use, modify and share (including inside organizations); selling the software, or hosting, support or consulting services whose value derives substantially from it, is not permitted. See LICENSE and NOTICE.

## [1.1.2] - 2026-10-06

### Fixed
- Several instances on one server (for example a new release validated next to production on another port):
  - cross-process locks are scoped to the installation folder, so instances no longer wait on each other's locks;
  - the session cookie is named per port (`ssp_sid_<port>`, or `portal.sessionCookieName`), so signing in to one instance no longer signs you out of the other (browsers share cookies across ports);
  - `tools/Set-PortalEndpoint.ps1` always edits its own installation, even when a portal-root environment variable points elsewhere.
- Users are asked to sign in again once after the upgrade (new cookie name).

### Documentation
- [operations.md 2.1](docs/operations.md#21-validating-a-new-release-side-by-side): running a new release side by side on another port.

## [1.1.1] - 2026-10-06

### Changed
- **No deployment-specific data in the shipped catalog.** Items reference team **roles** (`@datacenter`, `@cloud`) instead of team ids, have no `sites` list, and read per-site names (templates, customization specs, SQL media) as `@site:<key>` from the new configuration segment `sites[].catalogValues`, declared in `catalog.siteValues`.
- New configuration section `catalog` (`teamRoles`, `siteValues`). Team roles are mapped in Admin > Customization > Teams; catalog values are edited per site in Admin > vCenter connections. Upgrades map the roles to the existing teams and add the values with `TBD-` placeholders.
- Default team ids are now `Infrastructure` and `Cloud` (groups `SSP-Team-Infrastructure`, `SSP-Team-Cloud`).
- The job runner refuses to start a job while a fixed parameter is empty or still `TBD-`, naming the missing value.
- Catalog validation rejects unmapped team roles and undeclared `@site:` keys.

### Documentation
- [docs/requirements.md section 10](docs/requirements.md#10-deployment-specific-configuration-before-first-use): every configuration segment to complete before first use. [configuration.md 3.16](docs/configuration.md#316-catalog) documents the `catalog` section.

## [1.1.0] - 2026-10-05

### Added
- **21 operational catalog items (25 item files)**, each with a handler and offline tests: distributed port group, DRS rules, vMotion, host maintenance mode, decommission with quarantine and purge, snapshot clean-up, isolated test clone, right-sizing report, SQL Server 2022 unattended install, Windows roles (including MSDTC), agent baseline, AlmaLinux baseline, vSphere health, version compliance, hardening compliance, certificate expiry, capacity forecast, vendor-agnostic backup policy (vSphere tag), cloud cost reports and power actions (AWS / Azure), three-tier blueprint, and new datastore (VMFS / NFS, optional datastore cluster). See [docs/roadmap.md](docs/roadmap.md#40-delivered-in-110).
- **Storage rescan controls**: the LUN list of *New datastore* comes from an explicit **Rescan storage** action that requires a recent authentication (5 minutes), runs once per cluster at a time, has a 10-minute cool-down (`operations.storage.rescanCooldownMinutes`) and is audited with user, time and IP. Requests of re-authenticated items keep the evidence (`authorization`).
- **Reports**: handlers write HTML + CSV reports (`automation/lib/Portal.Report.psm1`); the request page lists them and the portal serves them with a script-free CSP.
- **Admin > Data files**: software repository (Approved / Pending / Retired packages; the backup agent stays Pending), version baseline, hardening baseline and backup policies, validated on save with a backup copy.
- New lookup sources: `hosts`, `vdSwitches`, `storageDevices`, `softwareSets`, `backupPolicies`; `vms` filters by power state and cluster.
- Inventory collects hosts (version, build, maintenance), distributed switches, VM sizing, and a daily capacity sample (`data/inventory/history/<SITE>.jsonl`) for the forecast.
- `operations` configuration section; job context gains `ReportDir`, `Approval`, `Authorization`, `Operations`, `Teams`, `ItemId`.
- Guest operations library (`automation/lib/Portal.Guest.psm1`) and backup connector templates (`catalog/_connectors/backup/`, not active).
- `tests/Invoke-HandlerTests.ps1` (offline handler tests with PowerCLI / cloud stubs) and the item contract `docs/dev/ITEM-CONTRACT.md`.

### Changed
- Single-option lookups are pre-selected only for required inputs.
- `.gitignore` ignores every live `config/*.json` (only `*.default.json` is tracked).

## [1.0.2] - 2026-10-05

### Security
- Sign-in page: the sign-in logic moved from an inline script to `web/assets/login.js`. With Pode's security headers (Content-Security-Policy) the inline script was blocked, and the browser fell back to submitting the form with GET, placing the username and password in the URL (and in the request log). The form now also declares `method="post"`, so credentials can never end up in a URL even if scripts are blocked.
- Smoke tests reject inline `<script>` blocks and non-POST forms in `web/*.html`.

## [1.0.1] - 2026-10-05

### Fixed
- First start failed with "The property 'Count' cannot be found on this object" in `Get-PortalVaultStatus` when the credential vault was still empty.
- The DPAPI vault key provider (Windows) now creates `data/vault` itself before writing the protected key.

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

[Unreleased]: https://github.com/OWNER/SelfServicePortal/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/OWNER/SelfServicePortal/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/OWNER/SelfServicePortal/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/OWNER/SelfServicePortal/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/OWNER/SelfServicePortal/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/OWNER/SelfServicePortal/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/OWNER/SelfServicePortal/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/OWNER/SelfServicePortal/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/OWNER/SelfServicePortal/releases/tag/v1.0.0
