# Windows installation guide

This guide installs the Self-Service Portal on Windows Server: PowerShell 7.4, the PowerShell modules, the folder layout and permissions, a dedicated service account, the vault key provider, the session secret, the TLS certificate, running the portal unattended, the firewall rule, upgrades and removal. For Linux use [installation-linux.md](installation-linux.md); for the virtual appliance use [ova.md](ova.md). Check [requirements.md](requirements.md) first.

> The repository ships **no Windows service wrapper**. Section 11 shows how to run the portal with NSSM or with a scheduled task. Those are examples to adapt and test in your environment, not shipped, supported components.

## Contents

1. [Supported versions](#1-supported-versions)
2. [Prerequisites](#2-prerequisites)
3. [PowerShell 7.4](#3-powershell-74)
4. [PowerShell modules](#4-powershell-modules)
5. [Folder layout and permissions](#5-folder-layout-and-permissions)
6. [Service account](#6-service-account)
7. [Vault key provider](#7-vault-key-provider)
8. [Session secret](#8-session-secret)
9. [TLS certificate](#9-tls-certificate)
10. [First start](#10-first-start)
11. [Running as a service](#11-running-as-a-service)
12. [Firewall](#12-firewall)
13. [First sign-in and checks](#13-first-sign-in-and-checks)
14. [Upgrade](#14-upgrade)
15. [Uninstall](#15-uninstall)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. Supported versions

| Component | Version |
|---|---|
| Windows Server | 2019, 2022, 2025 (Desktop Experience or Server Core), x64 |
| PowerShell | 7.4 or later |
| Pode | 2.14.x (2.14.1 is the version pinned by the Linux installer) |

Sizing is the same as on Linux: minimum 2 vCPU / 4 GB / 40 GB, recommended 4 vCPU / 8 GB / 60 GB ([requirements.md](requirements.md#2-sizing)).

## 2. Prerequisites

- Local administrator rights for the installation.
- Domain membership if you use a gMSA (recommended) or AD sign-in with `security: negotiate`.
- DNS record for the portal FQDN; time synchronised with the domain (MFA codes need +/- 30 s, [requirements.md](requirements.md#7-time-synchronisation)).
- Outbound HTTPS to the PowerShell Gallery for the online module installation, or an offline module bundle (`Save-PSResource`, see [installation-linux.md section 5.2](installation-linux.md#52-offline-air-gapped-install); copy the saved folders to `C:\Program Files\PowerShell\Modules`).
- The release archive (`SelfServicePortal-<version>.zip`).

## 3. PowerShell 7.4

Install PowerShell 7.4 or later **machine-wide**:

```powershell
# Where winget is available:
winget install --id Microsoft.PowerShell -e --scope machine
# Otherwise (e.g. Windows Server 2019, Server Core): the MSI from https://aka.ms/powershell-release?tag=stable
msiexec.exe /i PowerShell-7.4.x-win-x64.msi /qn ADD_PATH=1 ENABLE_PSREMOTING=0
```

Verify in a new console: `pwsh -NoProfile -c '$PSVersionTable.PSVersion'`. The default path is `C:\Program Files\PowerShell\7\pwsh.exe`; use that full path in the service definition and in `jobs.pwshPath` (section 10) because a service account's `PATH` may differ from yours.

`Start-Portal.ps1` started from Windows PowerShell 5.1 relaunches itself in `pwsh`, but the service should call `pwsh.exe` directly.

## 4. PowerShell modules

From an **elevated** `pwsh` console, install Pode at the tested version first, then the rest with the shipped helper:

```powershell
Install-PSResource -Name Pode -Version 2.14.1 -Scope AllUsers -TrustRepository
Set-Location D:\SelfServicePortal            # after extracting the release (section 5)
.\tools\Install-PortalPrerequisites.ps1      # Pode (skipped, already present), VMware.PowerCLI, AWS.Tools, Az
# Leave providers out you do not use:
.\tools\Install-PortalPrerequisites.ps1 -Skip Aws, Azure
```

`Install-PortalPrerequisites.ps1` installs for all users (`C:\Program Files\PowerShell\Modules`):

| Set | Modules |
|---|---|
| Core | `Pode` (latest from the Gallery if none is installed, hence the explicit pin above) |
| VSphere | `VMware.PowerCLI` (also sets the PowerCLI configuration for all users: no CEIP, `InvalidCertificateAction Ignore`) |
| Aws | `AWS.Tools.Common`, `AWS.Tools.EC2`, `AWS.Tools.SecurityToken`, `AWS.Tools.SimpleSystemsManagement` |
| Azure | `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources`, `Az.KeyVault`, `Az.MarketplaceOrdering` |

Modules that are already installed are skipped, never upgraded. The helper installs `VMware.PowerCLI` only; to use the renamed `VCF.PowerCLI`, install it yourself (`Install-PSResource VCF.PowerCLI -Scope AllUsers`) and run the helper with `-Skip VSphere`. Each job loads its modules from this machine-wide location, so they must be readable by the service account (the default ACL of `C:\Program Files` is).

## 5. Folder layout and permissions

Unblock the downloaded archive **before** extracting it, so Windows does not mark every file as coming from the internet, then extract it to a data volume:

```powershell
Unblock-File .\SelfServicePortal-<version>.zip
Expand-Archive .\SelfServicePortal-<version>.zip -DestinationPath D:\
# -> D:\SelfServicePortal\Start-Portal.ps1, modules\, web\, automation\, catalog\, config\, tools\, ...
```

If you extracted without unblocking, `Start-Portal.ps1` removes the mark-of-the-web from the whole tree each time it starts, so only the launcher itself has to be allowed once: depending on the execution policy you get a single *Run once* prompt, or (with `RemoteSigned`) an error. In that case run `Unblock-File D:\SelfServicePortal\Start-Portal.ps1`, or start it with `pwsh -ExecutionPolicy Bypass -File ...` as the service definitions in section 11 do.

The portal writes into `config\`, `data\`, `logs\`, `catalog\` and `automation\handlers\`, and keeps its secrets in `data\vault\` and `data\security\`. On Linux these are protected with file modes; on Windows they rely on the **folder ACL**, which you must restrict:

```powershell
$root = 'D:\SelfServicePortal'
$svc  = 'CORP\gmsa-ssp$'          # the service account (section 6)
icacls $root /inheritance:r /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' "${svc}:(OI)(CI)M"
```

Nobody else (in particular not `BUILTIN\Users`) should be able to read the folder.

Resulting layout:

| Path | Content |
|---|---|
| `D:\SelfServicePortal\Start-Portal.ps1`, `modules\`, `web\`, `tools\`, `automation\` | Code (replaced on upgrade, except custom handlers) |
| `config\portal.config.json`, `config\local-users.json` | Live configuration and local accounts (created at first start) |
| `catalog\items\` | Catalog items (administrators edit them) |
| `data\requests`, `data\inventory`, `data\vault`, `data\security`, `data\brand` | Runtime state, vault, sessions, MFA, logo |
| `logs\` | `portal.log`, `audit.jsonl`, Pode logs, `jobs\` |

The full description is in [architecture.md](architecture.md#6-data-layout).

## 6. Service account

Run the portal under a **dedicated** account, never under your own administrator account and preferably not as `LocalSystem`. The same account runs every job, inventory refresh and connection test (they are child processes), and with the default `dpapi` vault key provider it is also the account that can decrypt the vault (section 7).

Recommended: a **group Managed Service Account (gMSA)**. On a domain controller or a machine with the AD module:

```powershell
# Once per forest, if no KDS root key exists yet (wait for replication before using it):
#   Add-KdsRootKey -EffectiveImmediately
New-ADServiceAccount -Name gmsa-ssp -DNSHostName ssp01.corp.example.com `
    -PrincipalsAllowedToRetrieveManagedPassword 'SSP01$'
# On the portal server (RSAT AD PowerShell installed):
Install-ADServiceAccount -Identity gmsa-ssp
Test-ADServiceAccount -Identity gmsa-ssp          # must return True
```

Grant the account:

| Right | Why |
|---|---|
| *Log on as a service* (NSSM / Windows service) or *Log on as a batch job* (scheduled task) | Local Security Policy or GPO: User Rights Assignment |
| Modify on `D:\SelfServicePortal` | Section 5 |
| Read on the TLS certificate's private key | Section 9 (thumbprint mode only) |
| Read on the vault key file | Section 7 (`keyfile` mode only) |

The account needs no local administrator rights. Pode uses its own socket listener (not HTTP.sys), so no `netsh http add urlacl` reservation is required, also for port 443.

A classic domain user account works too (set a long random password and exclude it from interactive logon). Directory, vCenter and cloud permissions are not granted to this Windows account: they belong to the service accounts stored in the vault ([requirements.md](requirements.md#8-service-accounts-and-permissions)).

## 7. Vault key provider

The credential vault (vCenter, cloud, LDAP bind and guest credentials, plus every user's MFA seed) is encrypted with a 256-bit master key. Decide where that key lives **before the first start**, because the first start creates it.

| `vault.keyProvider` | Key location | Behaviour on Windows |
|---|---|---|
| `auto` (default) | `SSP_VAULT_KEYFILE` if set, else `SSP_VAULT_KEY` if set, else **DPAPI** | Without environment variables, `auto` means `dpapi` on Windows. |
| `dpapi` | `data\vault\master.key.dpapi` | The key is protected with Windows DPAPI for the **account that runs the portal** (`ConvertFrom-SecureString` without a key). Only that account, on that machine profile, can unprotect it. |
| `keyfile` | `SSP_VAULT_KEYFILE`, else `vault.keyFile`, else `data\vault\master.key` | A base64 file; portable; protect it with NTFS ACLs. |
| `env` | `SSP_VAULT_KEY` | Base64 key in the environment (containers). |

**DPAPI is bound to the service account.** Consequences:

- Starting the portal once interactively under your own account creates `master.key.dpapi` for **your** account; the service account then cannot open it (the vault reports an error and jobs fail). If that happened before any credential was stored, stop the portal and delete `data\vault\master.key.dpapi`, `data\vault\vault.json` and `data\security\mfa.json`, then start under the service account.
- **Changing the service account** (for example from a domain user to a gMSA), or restoring the folder on another server, makes the key unreadable. Before the change, export the key while still running as the old account and switch to the `keyfile` provider (below), or re-enter every credential and reset every MFA enrolment afterwards.
- A DPAPI-protected key cannot be restored on a different machine from a file backup alone. For disaster recovery, `keyfile` is easier to handle.

**Recommended for production: `keyfile`** stored outside the portal folder:

```powershell
$dir = 'D:\ssp-secrets'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
icacls $dir /inheritance:r /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' 'CORP\gmsa-ssp$:(OI)(CI)R'
$key = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
Set-Content -Path "$dir\vault.key" -Value $key -NoNewline -Encoding ascii
Remove-Variable key
[Environment]::SetEnvironmentVariable('SSP_VAULT_KEYFILE', "$dir\vault.key", 'Machine')
```

Alternatively set `"vault": { "keyProvider": "keyfile", "keyFile": "D:\\ssp-secrets\\vault.key" }` in `config\portal.config.json` instead of the environment variable. Back the key up separately from the portal data ([operations.md](operations.md#1-backup-and-restore)).

**Exporting an existing DPAPI key to a key file** (not a shipped tool; run it **as the current service account**, for example from a one-off scheduled task running as the gMSA, then stop the portal, set `SSP_VAULT_KEYFILE`, start the portal):

```powershell
# Example - runs as the account that owns the DPAPI key.
$ss  = Get-Content -LiteralPath 'D:\SelfServicePortal\data\vault\master.key.dpapi' -Raw | ConvertTo-SecureString
$b64 = [Net.NetworkCredential]::new('', $ss).Password        # the base64 key, same format as a key file
Set-Content -LiteralPath 'D:\ssp-secrets\vault.key' -Value $b64 -NoNewline -Encoding ascii
```

If the key does not match `data\vault\vault.json`, the portal refuses to decrypt and reports *The vault master key (...) does not match data/vault/vault.json* in Admin > Vault and in job errors. See [vault.md](vault.md) for the complete key management guide.

## 8. Session secret

The session cookie is signed with the secret in the environment variable named by `portal.sessionSecretEnvVar` (default `SSP_SESSION_SECRET`). Without it, every restart signs everybody out and the console warns at start-up.

```powershell
$bytes  = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$secret = [Convert]::ToHexString($bytes)                   # 64 hex characters
[Environment]::SetEnvironmentVariable('SSP_SESSION_SECRET', $secret, 'Machine')
Remove-Variable secret, bytes
```

Machine environment variables are readable by every local user and are only picked up by processes started afterwards (restart the service; a running console does not see them). With NSSM you can instead store it in the service environment (`nssm set SSP-Portal AppEnvironmentExtra SSP_SESSION_SECRET=<value>`), which keeps it out of other processes' environment; it is then stored in the service's registry key.

## 9. TLS certificate

The default configuration listens on **8443/tcp** with `protocol: Https` and a placeholder thumbprint, so the first start uses a Pode **self-signed** certificate (warning on the console). For production, use one of:

**A. Certificate in the machine store (thumbprint).** Request a server-authentication certificate whose SAN contains the portal FQDN, import it with its private key into `Cert:\LocalMachine\My`, then grant the service account read access to the private key (*certlm.msc* > the certificate > *All Tasks* > *Manage Private Keys...* > add `CORP\gmsa-ssp$` with *Read*). Configure:

```powershell
pwsh -File D:\SelfServicePortal\tools\Set-PortalEndpoint.ps1 -Port 443 -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
```

The portal checks `Cert:\LocalMachine\My\<thumbprint>` at start-up and refuses to start if it is missing. `portal.certificateStoreLocation` selects another store location.

**B. PFX file.** Store the PFX outside the portal folder with an ACL like the key file in section 7, put its password into an environment variable and reference the **variable name**:

```powershell
[Environment]::SetEnvironmentVariable('SSP_PFX_PASSWORD', '<pfx password>', 'Machine')
pwsh -File D:\SelfServicePortal\tools\Set-PortalEndpoint.ps1 -Port 443 `
     -CertificateFile D:\ssp-secrets\portal.pfx -CertificatePasswordEnvVar SSP_PFX_PASSWORD
```

A PEM certificate with `-CertificateKeyFile` is accepted as well. `certificateFile` takes precedence over the thumbprint. `Set-PortalEndpoint.ps1` writes `config\portal.config.json` (creating it from the defaults if needed) and audits the change as `portal.endpoint`; the new endpoint applies at the next start.

Trust your internal root and intermediate CAs in `LocalMachine\Root` / `CA` when vCenter or the domain controllers use certificates from them.

## 10. First start

Run a foreground start to create the configuration and check the endpoint. Do it **as the service account** when you use the `dpapi` vault provider (section 7); with `keyfile` you may do it from an elevated console:

```powershell
Set-Location D:\SelfServicePortal
pwsh -NoProfile -File .\Start-Portal.ps1                # -ShowErrors prints Pode errors to the console
```

At the first start the portal:

- creates `config\portal.config.json` and `config\local-users.json` from the `*.default.json` files (an upgrade never overwrites them);
- removes the mark-of-the-web from the tree;
- creates or validates the vault key;
- warns when the session secret is missing, when local accounts are enabled, and when it falls back to a self-signed certificate;
- listens on `portal.port` and starts the dispatcher and inventory timers.

Set the full path of `pwsh.exe` for the job runners in `config\portal.config.json`:

```json
"jobs": { "pwshPath": "C:\\Program Files\\PowerShell\\7\\pwsh.exe", ... }
```

Stop the foreground instance with Ctrl+C before installing the service.

## 11. Running as a service

### 11.1 NSSM (example)

[NSSM](https://nssm.cc/) wraps a console program as a Windows service with restart on failure and log rotation. Example, to adapt:

```powershell
$nssm = 'C:\Tools\nssm\nssm.exe'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
& $nssm install SSP-Portal $pwsh
& $nssm set SSP-Portal AppParameters '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\SelfServicePortal\Start-Portal.ps1'
& $nssm set SSP-Portal AppDirectory D:\SelfServicePortal
& $nssm set SSP-Portal DisplayName 'Self-Service Portal'
& $nssm set SSP-Portal Start SERVICE_DELAYED_AUTO_START
& $nssm set SSP-Portal AppStdout D:\SelfServicePortal\logs\service-console.log
& $nssm set SSP-Portal AppStderr D:\SelfServicePortal\logs\service-console.log
& $nssm set SSP-Portal AppRotateFiles 1
& $nssm set SSP-Portal AppRotateBytes 10485760
& $nssm set SSP-Portal AppExit Default Restart
& $nssm set SSP-Portal AppRestartDelay 10000
# Run as the gMSA (empty password for a gMSA):
sc.exe config SSP-Portal obj= 'CORP\gmsa-ssp$' password= ''
Start-Service SSP-Portal
```

NSSM stops the service by sending Ctrl+C to the console, which lets Pode shut down cleanly. Job processes started by the portal are children of the service process; stopping or restarting the service while jobs run can terminate them, and the dispatcher then marks them `Failed`. Check Admin > All requests for running jobs before stopping.

### 11.2 Scheduled task at start-up (example)

Without third-party tools, a scheduled task can start the portal at boot under the gMSA:

```powershell
$action    = New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
               -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\SelfServicePortal\Start-Portal.ps1' `
               -WorkingDirectory 'D:\SelfServicePortal'
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'CORP\gmsa-ssp$' -LogonType Password -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
               -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'SSP-Portal' -TaskPath '\SelfServicePortal\' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings
Start-ScheduledTask -TaskPath '\SelfServicePortal\' -TaskName 'SSP-Portal'
```

`-LogonType Password` with a gMSA lets Task Scheduler retrieve the managed password; the account needs *Log on as a batch job*. `ExecutionTimeLimit` zero disables the default 72-hour limit. Task Scheduler's restart-on-failure is less robust than a service manager; monitor the portal (section 13 and [operations.md](operations.md#5-monitoring-and-health)).

### 11.3 Environment of the service

The service sees machine environment variables (`SSP_SESSION_SECRET`, `SSP_VAULT_KEYFILE`, the PFX password variable, `HTTPS_PROXY` / `NO_PROXY` for AWS and Azure behind a proxy) set **before** it starts. `SSP_PORTAL_ROOT` is set by `Start-Portal.ps1` itself. After changing a variable, restart the service.

## 12. Firewall

```powershell
New-NetFirewallRule -Name 'SSP-Portal-HTTPS' -DisplayName 'Self-Service Portal (HTTPS)' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443 -Profile Domain
```

Use the port configured in `portal.port` (8443 by default). Outbound flows are listed in [requirements.md](requirements.md#52-outbound-from-the-portal-server).

## 13. First sign-in and checks

1. Browse to `https://<fqdn>/` (or `:8443`). Sign in as `admin` / `ChangeMe-2026!`. The portal forces a password change and, because Admin requires MFA by default, an authenticator enrolment (keep the recovery codes).
2. Admin > Customization: branding, teams, role mapping. Admin > Identity: directory providers ([identity.md](identity.md)); test them with *Test connection* and *Sign-in simulation*.
3. Admin > vCenter connections and Cloud connections: service accounts, then *Test connection*. The test runs out-of-process under the service account, so a green result also validates the vault key and the account's network path.
4. Admin > Catalog: replace the `TBD-...` template and customization specification names in the build items.
5. Admin > Customization > Policies / Admin > Identity: disable local accounts except a break-glass account.
6. Check `logs\portal.log` and `logs\pode-errors_*.log`, and that `logs\audit.jsonl` records your actions.

## 14. Upgrade

The release archive ships only `config\*.default.json`, so it never contains your live configuration. It does contain the shipped `catalog\items\*.json` and `automation\handlers\*.ps1`: extracting it over the folder **overwrites shipped catalog items you have edited** and updates the shipped handlers. Custom items and handlers (other file names) are untouched.

1. Back up ([operations.md](operations.md#1-backup-and-restore)) and make sure no job is running.
2. Stop the portal: `Stop-Service SSP-Portal` (or `Stop-ScheduledTask -TaskPath '\SelfServicePortal\' -TaskName 'SSP-Portal'`).
3. Unblock and extract the new release to a staging folder:
   ```powershell
   Unblock-File .\SelfServicePortal-<new>.zip
   Expand-Archive .\SelfServicePortal-<new>.zip -DestinationPath C:\Temp\ssp-new
   $new = 'C:\Temp\ssp-new\SelfServicePortal'; $dst = 'D:\SelfServicePortal'
   ```
4. Copy the code over the installation, keeping your catalog items; then add only catalog items that do not exist yet:
   ```powershell
   robocopy $new $dst /E /XD "$new\catalog\items" /NFL /NDL
   robocopy "$new\catalog\items" "$dst\catalog\items" /XC /XN /XO /NFL /NDL   # copies new files only
   ```
   Compare the new shipped items in `$new\catalog\items` with yours and merge changes by hand. Keep the previous `automation\handlers` from your backup if you had modified shipped handlers.
5. Install missing or newer modules required by the release (for example `Install-PSResource Pode -Version <required> -Scope AllUsers`, then `.\tools\Install-PortalPrerequisites.ps1`).
6. Start the portal. At start-up it adds new settings to the configuration (*Configuration upgraded: ...* on the console, `config.upgrade` in the audit log), backs up the previous file in `config\_backup\` and runs one-time migrations ([configuration.md](configuration.md#313-_migrations)).
7. Check `logs\portal.log` and Admin > Catalog for items reported as invalid.

Rollback: stop the portal and restore the folder from the backup.

## 15. Uninstall

```powershell
# 1. Back up first (configuration, data, catalog, handlers, logs\audit.jsonl, and the vault key).
# 2. Remove the service or task:
Stop-Service SSP-Portal; & 'C:\Tools\nssm\nssm.exe' remove SSP-Portal confirm
#    or: Unregister-ScheduledTask -TaskPath '\SelfServicePortal\' -TaskName 'SSP-Portal' -Confirm:$false
# 3. Firewall rule and environment variables:
Remove-NetFirewallRule -Name 'SSP-Portal-HTTPS'
'SSP_SESSION_SECRET', 'SSP_VAULT_KEYFILE', 'SSP_PFX_PASSWORD' | ForEach-Object { [Environment]::SetEnvironmentVariable($_, $null, 'Machine') }
# 4. Files (stored credentials become unrecoverable without the vault key backup):
Remove-Item -Recurse -Force D:\SelfServicePortal, D:\ssp-secrets
```

Optionally remove the TLS certificate, the PowerShell modules (`Uninstall-PSResource`), PowerShell 7 itself, and the gMSA (`Uninstall-ADServiceAccount` on the server, `Remove-ADServiceAccount` in AD).

## 16. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `... is not digitally signed` / *Run once?* | Files still blocked: `Unblock-File` the zip before extracting, or `Get-ChildItem D:\SelfServicePortal -Recurse \| Unblock-File`. |
| `Certificate <thumb> not found in Cert:\LocalMachine\My` | Wrong thumbprint or certificate not imported in the machine store (section 9). |
| TLS handshake fails although the certificate is present | The service account cannot read the private key (section 9 A). Run once with `-ShowErrors`. |
| `portal.certificateFile '...' not found` | Path wrong or not readable by the service account. |
| Everybody is signed out after a restart; warning `SSP_SESSION_SECRET is not set` | Section 8; restart the service after setting the variable. |
| Admin > Vault shows an error / jobs fail with a vault or DPAPI error | The key is protected for another account, or the key file does not match `vault.json` (section 7, [operations.md](operations.md#6-troubleshooting)). |
| Jobs stay `Queued` or fail immediately with *Runner process exited unexpectedly* | `jobs.pwshPath` is not resolvable for the service account (set the full path), or a module is missing: read `logs\jobs\REQ-....stderr.log`. |
| vCenter test fails only from the portal | Run the test from Admin: it runs as the service account. Check proxy (PowerCLI uses NoProxy), DNS and port 443. |
| AD sign-in with `negotiate` fails | Clock skew, SPN / Kerberos issues, or port 389 blocked. LDAPS (636) is the default and recommended. |

More in [operations.md](operations.md#6-troubleshooting).
