# Operations guide

This guide covers day-2 operation of the Self-Service Portal: backup and restore (including the vault key), upgrades and configuration migrations, the log files and their formats, the catalogue of audit events, what to monitor, troubleshooting of the common problems, and running the test suite. Paths are relative to the portal root (`/opt/ssp` on Linux and the appliance, for example `D:\SelfServicePortal` on Windows). Background on the components is in [architecture.md](architecture.md).

## Contents

1. [Backup and restore](#1-backup-and-restore)
2. [Upgrades and migrations](#2-upgrades-and-migrations)
3. [Logs](#3-logs)
4. [Audit events](#4-audit-events)
5. [Monitoring and health](#5-monitoring-and-health)
6. [Troubleshooting](#6-troubleshooting)
7. [Running the test suite](#7-running-the-test-suite)

---

## 1. Backup and restore

### 1.1 What to back up

| Item | Path | Why |
|---|---|---|
| Configuration and local accounts | `config/` (`portal.config.json`, `local-users.json`; `_backup/` optional) | Everything set in the Admin pages |
| Catalog | `catalog/items/`, `catalog/_archive/` | Items edited or created by administrators, previous versions |
| Custom handlers | `automation/handlers/` and every folder in `automation.allowedHandlerRoots` | Your automation code |
| Requests | `data/requests/` | Request history, results, approvals |
| Vault (encrypted) | `data/vault/vault.json` | Stored credentials (useless without the key) |
| Security state | `data/security/` (`mfa.json` is essential; `sessions.json`, `lockouts.json`, `tickets.json` are transient) | MFA enrolments (encrypted with the vault key) |
| Branding | `data/brand/` | Uploaded logo |
| Audit trail | `logs/audit.jsonl` | Compliance evidence; **not** included in `ssp-backup` (see 1.2) |
| Job logs (optional) | `logs/jobs/` | Execution evidence shown in the request page |
| **Vault master key** | Linux/OVA: `/etc/ssp/vault.key`; Windows: the `keyfile` path, or `data/vault/master.key.dpapi` (see 1.4) | The only way to decrypt the vault and the MFA seeds |
| Service secrets | Linux: `/etc/ssp/portal.env`, `/etc/ssp/tls/`; Windows: session secret, PFX and its password | Sessions survive a restore; TLS endpoint |

`data/inventory/` is a cache and is rebuilt by the next inventory refresh; code (`modules/`, `web/`, `tools/`, shipped handlers) comes from the release.

All JSON files are written atomically (temporary file + rename), so a file-level copy of a running portal yields valid files. For a fully consistent point in time (a request moving between states while the copy runs), stop the service or use a snapshot-based backup.

### 1.2 Linux and appliance

Use `ssp-backup` (installed by `install.sh`), documented in [installation-linux.md section 11](installation-linux.md#11-backup-and-restore):

```bash
sudo ssp-backup                                 # /var/backups/ssp/ssp-backup-<host>-<ts>.tar.gz (+ .sha256)
sudo ssp-backup --exclude-key -o /mnt/backup    # vault key written to <archive>.vault.key: move it elsewhere
sudo ssp-backup --stop-service --keep 14        # consistent copy, keep 14 archives
```

The archive contains `/opt/ssp/{config,data,catalog,automation/handlers}` and `/etc/ssp`; it excludes `logs/`. Archive `logs/audit.jsonl` separately (log shipping or a second job), for example:

```bash
sudo tar -czf /var/backups/ssp/audit-$(date +%Y%m%d).tar.gz -C / opt/ssp/logs/audit.jsonl
```

Restore: [installation-linux.md section 11](installation-linux.md#11-backup-and-restore). Also restore `logs/audit.jsonl` if you need the audit history in Admin > Audit.

### 1.3 Windows

There is no backup script for Windows. Example with the portal running (use VSS-aware backup software, or stop the service, for a consistent copy):

```powershell
$src = 'D:\SelfServicePortal'; $dst = "E:\Backup\ssp\$(Get-Date -Format yyyyMMdd-HHmmss)"
foreach ($d in 'config', 'catalog', 'data', 'automation\handlers') {
    robocopy "$src\$d" "$dst\$d" /E /XD "$src\data\inventory" /NFL /NDL /NP | Out-Null
}
robocopy "$src\logs" "$dst\logs" audit.jsonl /NFL /NDL /NP | Out-Null
```

Restrict the backup folder's ACL like the portal folder. Back up the vault key to a different location (1.4).

Restore: install the **same release** (or extract it), stop the portal, copy the folders back, restore the vault key and the environment variables (`SSP_SESSION_SECRET`, `SSP_VAULT_KEYFILE`, PFX password), re-apply the folder ACL, start the portal.

### 1.4 The vault key

- The key decrypts `data/vault/vault.json` **and** the MFA seeds in `data/security/mfa.json`. Without it, every stored credential must be entered again and every user must re-enrol MFA.
- Whoever holds the key **and** the data can decrypt every credential. Keep the key in a different location (password safe, HSM-backed secret store, separate backup set) with its own access control.
- Linux/OVA: `/etc/ssp/vault.key` (base64, `ssp:ssp 0400`). `ssp-backup --exclude-key` writes it to a separate file.
- Windows with `keyfile`: back up the key file.
- Windows with `dpapi` (default): `data/vault/master.key.dpapi` can only be decrypted by the same Windows account and machine profile; a file backup of it is not enough for a restore on another server or under another account. Export it to a key file while running as the service account ([installation-windows.md section 7](installation-windows.md#7-vault-key-provider)) and keep that export as your key backup.
- The key is never rotated by the portal (re-keying is not supported yet; see [roadmap.md](roadmap.md)). More in [vault.md](vault.md).

## 2. Upgrades and migrations

| Platform | Procedure |
|---|---|
| Linux | `sudo ./packaging/linux/install.sh --upgrade` from the new release: pre-upgrade backup to `/var/backups/ssp`, code replaced, configuration/data/logs/`/etc/ssp` preserved, edited catalog items kept with the new shipped version put aside in `/var/lib/ssp/upgrades/<ts>/` ([installation-linux.md section 10](installation-linux.md#10-upgrade)) |
| Appliance | Same, from `/var/tmp` ([ova.md section 8](ova.md#8-updating-the-appliance)) |
| Windows | Stop, copy the new code over the folder keeping `catalog/items`, start ([installation-windows.md section 14](installation-windows.md#14-upgrade)) |

At the first start of the new release the portal upgrades its configuration by itself:

- New sections and keys are added with their defaults; existing values are never changed except by the one-time migrations listed in `_migrations` ([configuration.md](configuration.md#313-_migrations)).
- The previous configuration is copied to `config/_backup/portal.config.<timestamp>.json`; the console prints *Configuration upgraded: ...* and the audit log records `config.upgrade` with the list of changes.
- Legacy credentials (DPAPI CliXml files of sites and clouds) are moved into the vault on Windows (`vault.migrate`).

After an upgrade:

1. Check the console / journal and `logs/portal.log` for warnings.
2. Admin > Catalog: items that no longer validate against their handler are listed with the reasons and hidden from users. `pwsh -File tools/Test-CatalogItem.ps1` performs the same check from the command line.
3. Re-test vCenter and cloud connections if PowerCLI, AWS.Tools or Az were upgraded.

Rollback: restore the pre-upgrade backup (Linux: `tar -xzpf /var/backups/ssp/pre-upgrade-<ts>.tar.gz -C /`). Do not install an older release over a configuration that a newer release has already migrated.

## 3. Logs

| File | Format | Written by | Rotation |
|---|---|---|---|
| `logs/portal.log` | `<ISO timestamp with offset> [LEVEL] message`, levels `INFO`, `WARN`, `ERROR`, `DEBUG` | Web server, runners, inventory | None by the portal |
| `logs/audit.jsonl` | JSON Lines, one event per line (below) | Every process | None by the portal |
| `logs/jobs/REQ-yyyyMMdd-XXXXXX.log` | `yyyy-MM-dd HH:mm:ss [LEVEL] message`, levels `STEP`, `OK`, `INFO`, `WARN`, `ERROR`; vault secrets replaced by `********` | Runner (`Write-JobLog`, `Write-Host`, `Write-Warning`) | None |
| `logs/jobs/<name>.stdout.log`, `.stderr.log` | Raw console output; `<name>` is `REQ-...`, `inventory-<SITE>`, `conntest-<SITE>` or `conntest-cloud-<provider>` | Child processes | Overwritten by the next run of the same name |
| `logs/pode-errors_*.log`, `logs/pode-requests_*.log` | Pode error and request (access) logs, one file per day | Pode | New file per day; old files are kept |
| Linux journal | Console output of the service | `journalctl -u ssp-portal` | journald |
| Windows service console | Console output captured by your service wrapper | NSSM `AppStdout` / `AppStderr` | Wrapper settings |

`Start-Portal.ps1 -ShowErrors` sends Pode errors (with stack traces) to the console instead of `logs/pode-errors_*.log`; use it only for troubleshooting.

Example `portal.log` lines:

```text
2026-10-05T08:15:40.112+00:00 [INFO] Portal started on port 443 (catalog: 10 items).
2026-10-05T08:16:02.950+00:00 [WARN] BREAK-GLASS account LOCAL\breakglass signed in from 10.20.1.15.
2026-10-05T08:30:01.004+00:00 [ERROR] Inventory DC2 failed: Network: vcenter02.corp.example.com:443 is not reachable from the portal server (firewall / routing). Detail: ...
```

Example `audit.jsonl` line (fields: `ts` UTC ISO 8601, `actor`, `action`, `target`, `details`):

```json
{"ts":"2026-10-05T08:17:12.4410923Z","actor":"CORP\\jdoe","action":"request.create","target":"REQ-20261005-3FA9C1","details":{"item":"vm-windows-2025","version":"1.0.0","status":"PendingApproval"}}
```

Example job log:

```text
2026-10-05 08:18:03 [STEP ] Request REQ-20261005-3FA9C1 - Windows Server 2025 VM v1.0.0
2026-10-05 08:18:05 [STEP ] Connecting to vCenter vcenter01.corp.example.com (site DC1)
2026-10-05 08:18:09 [OK   ] Connected to vcenter01.corp.example.com - vCenter 8.0.3 build 24322831
2026-10-05 08:18:09 [INFO ] Parameters: CpuCount=4; Datastore=DC1-AP-DS01; ...
```

**Retention.** The portal never rotates or deletes `portal.log`, `audit.jsonl`, job logs, request documents or `config/_backup/` files. Admin > Audit shows the last 200 lines of the current `audit.jsonl`, and Admin > Security lists recent break-glass sign-ins from its last 2,000 lines. Ship `audit.jsonl` to your SIEM and rotate the files with OS tooling. Each write opens the file by path, so rename-based rotation is safe. Linux example (`/etc/logrotate.d/ssp-portal`):

```text
/opt/ssp/logs/portal.log /opt/ssp/logs/audit.jsonl {
    weekly
    rotate 52
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ssp ssp
}
```

Deleting old job logs removes them from the request page; removing request documents removes the requests from the portal. Automatic purging of requests is not supported yet.

## 4. Audit events

Every event is one line in `logs/audit.jsonl`. `actor` is the portal user name (`CORP\jdoe`, `LOCAL\admin`), `system` (timers, migrations), `runner` (job processes), `CLI\<os user>` (tools) or the typed user name for failed sign-ins.

**Sign-in and sessions**

| Action | Target / details | When |
|---|---|---|
| `auth.success` | details `ip`, `provider`, `mfa` | Successful sign-in (ticket issued) |
| `auth.breakglass` | details `ip`, `provider`, `mfa` | Successful sign-in of a local account flagged `breakGlass` (also a `WARN` line in `portal.log`) |
| `auth.failed` | details `ip`, `reason` (`invalid`, `locked`, `expired`, `mustchange`, `disabled`, `unavailable`, `error`) | Wrong credentials or directory error |
| `auth.locked` | details `ip` | Attempt while the user or IP is locked out |
| `auth.norole` | details `ip` | Valid credentials, but no role mapped |
| `auth.mfa.failed` | details `ip` | Wrong TOTP / recovery code at sign-in |
| `auth.reauth`, `auth.reauth.failed` | details `ip` | Password confirmation for a sensitive action |
| `mfa.enrolled` | - | Authenticator enrolled |
| `mfa.recoverycode.used` | details `left` | Recovery code consumed |
| `mfa.reset` | target user | Authenticator removed by an administrator or the CLI |
| `session.logout` | target: first 8 characters of the session id | User signed out |
| `session.revoke` | target: short session id or user name | Session(s) ended by an administrator, user deletion or MFA reset |
| `security.unlock` | target: lockout key (`u:<user>` or `ip:<address>`) | Lockout cleared |

**Administration**

| Action | Target / details |
|---|---|
| `security.policy.update` | details `sections` |
| `identity.provider.save`, `identity.provider.delete` | target provider id; details `enabled`, `hosts`, `security` |
| `identity.options` | details `defaultProvider`, `localUsersEnabled` |
| `identity.simulate` | target simulated user name; details `ok` |
| `localuser.save`, `localuser.delete` | target user; details `roles`, `teams`, `enabled`, `passwordChanged`, `breakGlass` |
| `settings.update` | details `sections` (branding, teams, roleMapping, vmNotes, policies) |
| `settings.logo` | details `file` |
| `portal.endpoint` | details `port`, `certificateFile` (from `tools/Set-PortalEndpoint.ps1`) |
| `config.upgrade` | details `added` or `teamScopes` (start-up migrations) |
| `catalog.create`, `catalog.update` | target item id; details `version`, `file` |
| `catalog.delete` | target item id; details `archivedAs` |
| `handler.create` | target: path of the generated handler skeleton |
| `site.create`, `site.update` | target site code; details `vcenter` |
| `site.credential` | target site code; details `username` |
| `site.test` | target site code; details `ok` |
| `cloud.update` | target `aws` / `azure`; details `secretChanged` |
| `cloud.test` | target `aws` / `azure`; details `ok` |
| `inventory.refresh` | target: site codes started |

**Vault**

| Action | Target / details |
|---|---|
| `vault.save` | target entry id; details `type`, `secretChanged`, `new` |
| `vault.delete` | target entry id |
| `vault.use` | target entry id; details `purpose` (`site`, `cloud`, `identity`, `item`), `item`, `request`. Written for every decryption: job credentials, vCenter / cloud connections (jobs, inventory, tests) and LDAP bind accounts (each `bindMode: search` sign-in). |
| `vault.migrate` | details `moved` (legacy credentials imported at start-up) |

**Requests and jobs**

| Action | Actor | Target / details |
|---|---|---|
| `request.create` | requester | request id; details `item`, `version`, `status` |
| `request.approve`, `request.reject` | approver | request id; details `comment` |
| `request.cancel` | requester or Admin | request id |
| `job.dispatch` | `system` | request id; details `pid` |
| `job.succeeded` | `runner` | request id |
| `job.failed` | `runner` | request id; details `error` |
| `job.timeout` | `system` | request id |

A runner that dies without recording its result is marked `Failed` by the dispatcher with a `WARN` line in `portal.log` (*marked Failed: runner not alive*) but without an audit event.

## 5. Monitoring and health

There is no dedicated health endpoint. Recommended checks:

| Check | How | Expected |
|---|---|---|
| Service running | `systemctl is-active ssp-portal`; Windows: service / task state | active / running |
| Web endpoint | `GET https://<fqdn>/login` (unauthenticated) | HTTP 200 (login page). `GET /api/branding` returns JSON. |
| TLS certificate | Expiry of the presented certificate | More than 30 days left |
| Disk space | Volume holding `logs/`, `data/`, `config/_backup/` | Above your threshold; these folders grow without limit (section 3) |
| Time | `chronyc tracking`, `w32tm /query /status` | Offset well below 30 s (MFA) |
| Errors | `[ERROR]` and `[WARN]` lines in `logs/portal.log`, for example `Dispatcher:`, `Dispatch of`, `runner not alive`, `Inventory <SITE> failed`, `LDAP provider <id>:`, `API error [<ref>]` | None, or investigated |
| Break-glass use | `auth.breakglass` in `audit.jsonl` (also Admin > Security) | Only during declared emergencies |
| Sign-in anomalies | Rate of `auth.failed`, `auth.locked`, `auth.mfa.failed`; current locks in Admin > Security or `data/security/lockouts.json` | No spikes |
| Sensitive changes | `security.policy.update`, `identity.provider.*`, `localuser.*`, `mfa.reset`, `vault.save`, `vault.delete`, `settings.update` with `roleMapping` | Matched by change records |
| Vault entries expiring | Admin > Vault (state *expiring* within 30 days, *expired*). Metadata is readable without the key, e.g. `jq -r '.entries[] \| select(.expiresAt) \| "\(.id) \(.expiresAt)"' /opt/ssp/data/vault/vault.json` | Rotated before expiry; an expired entry makes every job that uses it fail |
| Vault health | Admin > Vault status `healthy` | `true` |
| Inventory freshness | Admin > vCenter connections (*stale* after `inventory.staleAfterMinutes`), or `collectedAt` in `data/inventory/<SITE>.json` and `state` in `<SITE>.status.json` | Fresh, `Succeeded` |
| Job queue | Requests in `Queued` / `Running` for long, and the `Failed` rate (Admin > All requests, or `data/requests/*.json`) | Short queue; failures investigated |

## 6. Troubleshooting

### 6.1 Sign-in

The login page shows the same message for an unknown user and a wrong password. Find the real reason in the audit log (`auth.failed` with `reason`) and in `portal.log` (`LDAP provider <id>: ...`), then use the Admin tools:

- **Admin > Identity > Test connection** (per provider): connects with the configured transport security, binds with the service account (or reads the rootDSE anonymously for direct-bind providers) and, with a *lookup user*, finds the user and lists his groups. No user password is needed.
- **Admin > Identity > Sign-in simulation**: runs the real authentication for a user name and password and shows the provider, the groups found, the resulting roles and teams and whether MFA is required. It creates no session and is audited as `identity.simulate`.

| Symptom / message | Cause and fix |
|---|---|
| *Invalid username or password* | Wrong credentials, unknown domain (a `DOMAIN\user` or `user@domain` that no enabled provider lists in `domains` is rejected), wrong `userFilter` / `baseDn`, or `bindMode: direct` with a wrong `upnSuffix`. Check with *Sign-in simulation*. |
| *Your account is not authorised for this portal (no role assigned)* | The user's groups do not match `auth.roleMapping` (`auth.norole`). Compare the groups shown by the simulation with the role mapping; group names are CNs. Directory membership is read at sign-in. |
| *Directory server not reachable* | Network, DNS, port, or TLS failure (`unavailable`; does not count towards lockout). Test with `openssl s_client -connect dc01:636` or `ldapsearch -H ldaps://dc01 -x -b "" -s base`. |
| *The OpenLDAP client library (libldap) is not installed* / `Unable to load shared library 'libldap-2.5.so.0'` | Linux: install `openldap` / `libldap2` and the compatibility link (`install.sh --only packages`); see [installation-linux.md section 13](installation-linux.md#13-troubleshooting). |
| *The directory account is locked / disabled / expired*, *requires a password change* | AD sub-codes 775, 533, 701/532, 773; fix in the directory. |
| *More than one directory entry matches* | `userFilter` too broad. |
| StartTLS fails, LDAPS works (Linux) | The server refuses anonymous rootDSE reads; use LDAPS. |
| Certificate errors on LDAPS | Directory CA not trusted: Linux `tls.caFile`, `LDAPTLS_CACERT` or the OS trust store (restart after changing it); Windows `LocalMachine\Root`. |
| *Sign-in expired before it completed* | The one-time ticket was not redeemed within 60 s or came from another client IP. Behind a reverse proxy or load balancer, add it to `security.trustedProxies`. |
| *Administrative roles are only available from the management network* | `security.adminAllowedCidrs` excludes the client address (or a proxy hides it; see `trustedProxies`). |
| *Sign-in is temporarily unavailable* (HTTP 500) | Unexpected error, often the vault key (MFA seeds cannot be decrypted, see 6.4); details in `portal.log` (`Login error: ...`). |

### 6.2 MFA codes rejected

TOTP codes are accepted only within one 30-second step of the server time. If valid codes are refused:

1. Check the server clock: `chronyc tracking` / `timedatectl` (Linux), `w32tm /query /status` (Windows). Fix NTP ([requirements.md](requirements.md#7-time-synchronisation)).
2. Check that the phone uses automatic network time.
3. A code can be used only once (replay protection); wait for the next code.
4. The user can sign in with one of his recovery codes (`xxxx-xxxx`, single use) and re-enrol under *My account*.
5. Otherwise reset the authenticator: Admin > Security > *Reset a directory user's authenticator* (directory users, e.g. `CORP\jdoe`), Admin > Local users (local accounts), or `tools/Set-PortalLocalUser.ps1 -Username <name> -ResetMfa` on the server. A reset from the Admin pages also ends the user's sessions; the command-line tool does not.

### 6.3 Locked accounts and lost administrator access

Lockouts are kept per user (`u:<name>`) and per client IP (`ip:<address>`, threshold 4 times the user threshold) and expire after `security.lockout.durationMinutes`. Clear them in Admin > Security, or from the server:

```bash
# Linux / appliance: run the tool as the service account so file ownership stays correct
sudo runuser -u ssp -- env SSP_PORTAL_ROOT=/opt/ssp pwsh -NoProfile -File /opt/ssp/tools/Set-PortalLocalUser.ps1 -Username admin -Unlock -ResetMfa
```

```powershell
# Windows (elevated, in the portal folder)
pwsh -NoProfile -File .\tools\Set-PortalLocalUser.ps1 -Username admin -Unlock -ResetMfa
```

`-Unlock` clears the user lock only (`u:<username>`); clear IP locks in Admin > Security, or delete the `ip:...` entry from `data/security/lockouts.json` while the portal is stopped.

**Lost local administrator password.** Reset it on the server; the tool prompts for the new password, re-enables the account and forces a change at the next sign-in (`-NoPasswordChange` skips that):

```bash
sudo runuser -u ssp -- env SSP_PORTAL_ROOT=/opt/ssp pwsh -NoProfile -File /opt/ssp/tools/Set-PortalLocalUser.ps1 -Username admin
```

If local accounts are disabled (`auth.localUsers.enabled: false`), only accounts flagged break-glass can sign in. Create or flag one: `... Set-PortalLocalUser.ps1 -Username breakglass -Roles Admin -BreakGlass`. Other tool options: `-Roles`, `-Teams`, `-DisplayName`, `-Disable`, `-Remove`.

**Directory administrator lost his authenticator** and no other SecurityAdmin/Admin can reset it: stop the portal, remove the user's entry from `data/security/mfa.json` (the key is the lower-case portal user name, e.g. `corp\\jdoe` in JSON), start the portal; the user enrols again at the next sign-in.

### 6.4 Vault key mismatch

Message (Admin > Vault, job errors, connection tests):

> The vault master key (keyfile: /etc/ssp/vault.key) does not match data/vault/vault.json. Restore the original key file; a new key cannot open existing credentials.

| Cause | Fix |
|---|---|
| Key file replaced or regenerated, wrong `SSP_VAULT_KEYFILE`, restore of data without its key | Restore the original key from backup ([section 1.4](#14-the-vault-key)); restart the portal (the web server caches the key). |
| Windows `dpapi`: service account changed, first start done under another account, folder restored on another server | Run under the original account, or restore an exported key file. A DPAPI error (instead of the mismatch message) has the same causes. |
| Key really lost | Stop the portal, move `data/vault/vault.json` and `data/security/mfa.json` aside, provide a key (Linux: generate a new `/etc/ssp/vault.key` with `openssl rand -base64 32`, owner `ssp`, mode 0400; with `dpapi` or the default key file path the portal creates one), start (an empty vault bound to that key is created), re-enter every credential (vCenter, cloud, LDAP bind, item credentials) and let users re-enrol MFA. |

`Vault entry '<id>' expired on ...` and `... is not allowed for <purpose>` are not key problems: renew the entry or fix its scope in Admin > Vault ([vault.md](vault.md)).

### 6.5 Jobs

| Symptom | Check / fix |
|---|---|
| Request stays `Queued` | `jobs.maxConcurrent` slots taken by running jobs; `Dispatch of <id> failed` in `portal.log` (wrong `jobs.pwshPath`, process creation denied); dispatcher errors (`Dispatcher: ...`). The dispatcher runs every `jobs.dispatcherIntervalSeconds`. |
| `Failed`: *Runner process exited unexpectedly* | Read `logs/jobs/<REQ>.stderr.log` (module missing, `#Requires` failure, crash) and the job log. Also happens when the service was restarted while the job ran. |
| `Failed`: *Job exceeded its timeout of N minutes* | The runner was killed after `execution.timeoutMinutes` (or `jobs.defaultTimeoutMinutes`). Check what the handler waited for (guest customization, cloud status checks); raise the item's timeout if legitimate. Clean up partially created objects if the kill interrupted a rollback. |
| `Failed` with a handler message | Shown on the request page and in `logs/jobs/<REQ>.log`, with the PowerShell stack. vCenter connection errors carry a hint (certificate / authentication / DNS / network). |
| Running job must be stopped | Cancel is only possible before dispatch. Kill the runner process (its PID is `job.pid` in `data/requests/<REQ>.json` and in the job log); the dispatcher marks the request `Failed` on its next pass. |
| Handler refused: *outside the allowed handler folders* | Add the folder to `automation.allowedHandlerRoots`. |
| `Vault entry '<id>' is not allowed for item '<id>'` | The entry's scope does not include the item (or the request's team). |

### 6.6 Inventory not refreshing

Drop-downs (clusters, datastores, port groups, folders, VMs) come from `data/inventory/<SITE>.json`.

1. The site must be **enabled**; disabled sites are never refreshed.
2. Admin > vCenter connections shows the last state and error of each site; *Test connection* (starts a refresh when it succeeds) and the refresh button start one immediately.
3. Read `data/inventory/<SITE>.status.json` (`state`, `error`), `logs/jobs/inventory-<SITE>.stderr.log` and `Inventory <SITE> failed` lines in `portal.log`.
4. A refresh is skipped while the previous one is still running (`state: Running` with a live PID).
5. *Inventory for site X is not available yet* in a form means no successful collection exists yet.
6. Missing objects: clusters are limited to `allowedClusters`, port groups to `portgroupFilter`, and datastores to accessible ones that are not in maintenance mode, are connected to the selected cluster and have at least the input's `minFreeGB` free.

### 6.7 Other

| Symptom | Fix |
|---|---|
| *Unexpected server error (ref abcd1234)* | Search `portal.log` for `API error [abcd1234]`. |
| HTTP 403 *Missing anti-forgery header* from a script | Non-GET calls to `/api/*` must send `X-Portal-Request: 1` ([api.md](api.md)). |
| Catalog item missing for users | Disabled, invalid (Admin > Catalog lists errors), not in the user's roles or teams. |
| Changes to a site, policy or item not visible | They apply live; for the settings that need a restart see [configuration.md](configuration.md#5-live-settings-and-settings-that-need-a-restart). |

## 7. Running the test suite

`tests/Invoke-SmokeTest.ps1` is an offline test of the portal engine: no Pode server, no vCenter, no cloud. Run it from a **source checkout** (the Linux installer does not copy `tests/` into `/opt/ssp`):

```bash
pwsh -NoProfile -File tests/Invoke-SmokeTest.ps1
```

What it does:

- Copies the whole tree to a temporary folder (`ssportal-<random>` under the system temp directory), sets `SSP_PORTAL_ROOT` to it and creates the configuration from the defaults. Your checkout is not modified; the temporary folder is left in place for inspection and printed at the end.
- Injects a fake vCenter inventory, test catalog items and test handlers, then checks: roles and teams, local accounts and password policy, catalog loading and validation, lookups and server-side input validation, the approval workflow and state machine, the dispatcher and a **real out-of-process runner** (it starts `pwsh` child processes), audit events, Admin functions (local users, sites, catalog editor, customization, cloud settings), configuration migrations, the vault (encryption, scopes, rotation, secret masking in job logs, separation of duties), sign-in tickets, sessions, re-authentication, lockout, TOTP (RFC 6238 test vector, enrolment, replay, recovery codes), permissions and admin networks, identity provider routing and LDAP filter escaping.
- Prints `[PASS]` / `[FAIL]` per check and `Result: <n> passed, <m> failed`; the exit code is the number of failures (0 = success).

Requirements: PowerShell 7.2+ (7.4 recommended); Pode, PowerCLI and the cloud modules are not needed.

**Optional live LDAP tests.** Five additional checks run against a real directory when `LDAPTLS_CACERT` or `SSP_TEST_LDAP_CA` is set; otherwise they are reported as `[SKIP]`. The test creates an OpenLDAP-flavor provider with these fixed values:

| Setting | Value |
|---|---|
| Host / port | `SSP_TEST_LDAP_HOST` (default `127.0.0.1`), `SSP_TEST_LDAP_PORT` (default `3636`), LDAPS, certificate verification on |
| Base DN | `dc=example,dc=org` |
| Bind mode / account | `search`, bind DN `uid=svc-portal,ou=people,dc=example,dc=org`, password `Svc-Passw0rd!` |
| Login domains | `example.org`, `LAB` |

The directory must contain:

| Entry | Password | Groups (CN) | Expected result |
|---|---|---|---|
| `uid=svc-portal,ou=people,dc=example,dc=org` | `Svc-Passw0rd!` | - | Can bind and read users and groups |
| `inetOrgPerson` with `uid=bob` | `Bob-Passw0rd!` | `SSP-Requesters`, `SSP-Team-Cloud` | Signs in as `LAB\bob` with role Requester and team Cloud; a wrong password is refused |
| `inetOrgPerson` with `uid=alice` | `Alice-Passw0rd!` | `SSP-Admins` | Signs in as `alice@example.org` and is sent to MFA enrolment |

Groups are found with the default OpenLDAP group filter (`groupOfNames` / `member`, `groupOfUniqueNames` / `uniqueMember` or `posixGroup` / `memberUid`).

On Linux, `LDAPTLS_CACERT` must point to the CA certificate that issued the test server's certificate, and the certificate must match the host name or IP you test against; `SSP_TEST_LDAP_CA` only enables the tests and is not used as a CA file. On Windows, trust the CA in the Windows certificate store and set `SSP_TEST_LDAP_CA` to any value to enable the tests.

```bash
LDAPTLS_CACERT=/path/to/test-ca.crt SSP_TEST_LDAP_HOST=ldap.test.local SSP_TEST_LDAP_PORT=636 \
  pwsh -NoProfile -File tests/Invoke-SmokeTest.ps1
```

**Catalog validation.** `pwsh -File tools/Test-CatalogItem.ps1 [-Path <item.json>...]` validates catalog items (structure, input types, regular expressions, `dependsOn` order, handler existence and parameter matching) with the same validator the portal uses; the exit code is the number of invalid items. Use it in CI before publishing items ([catalog-authoring.md](catalog-authoring.md)).
