# Credential vault

The vault stores the credentials the portal uses: vCenter service accounts, cloud identities, directory bind accounts, and credentials that catalog jobs need (guest OS administrators, API tokens, keys). Secrets are encrypted at rest and write-only through the UI and API. Each entry is scoped to platform use, specific catalog items and teams, and every decryption is audited. Code: `modules/Portal.Vault.psm1` and `automation/Invoke-CatalogJob.ps1`. Tests: section *Vault* of `tests/Invoke-SmokeTest.ps1`.

See also [security.md](security.md) (security model) and [identity.md](identity.md) (directory bind accounts).

## Contents

1. [Purpose and principles](#1-purpose-and-principles)
2. [Cryptography](#2-cryptography)
3. [Master key providers](#3-master-key-providers)
4. [Scope](#4-scope)
5. [Entries](#5-entries)
6. [Using credentials in catalog items](#6-using-credentials-in-catalog-items)
7. [Job log masking](#7-job-log-masking)
8. [Backup and master-key rotation](#8-backup-and-master-key-rotation)
9. [Migration of legacy credentials](#9-migration-of-legacy-credentials)
10. [Administration (UI and API)](#10-administration-ui-and-api)
11. [CLI notes](#11-cli-notes)

---

## 1. Purpose and principles

| Principle | Implementation |
|---|---|
| Encrypted at rest | AES-256-GCM per secret version, with a master key held outside the data file |
| Write-only | The UI and API can create, replace and delete secrets but never return them. Entry views contain metadata only. |
| Decrypted only where needed | Job runners, connection tests (vCenter, cloud) and the identity layer (LDAP bind) decrypt secrets in memory, in the process that uses them |
| Least privilege | Each entry has a scope: platform use (`system`), catalog items, teams |
| Accountability | Every decryption is audited as `vault.use` (with the request id for jobs), and the entry records `lastUsedAt`, `lastUsedBy` and `useCount` |
| Separation of duties | `VaultAdmin` manages the vault but, by default, cannot approve jobs that use it ([security.md](security.md#separation-of-duties)) |

## 2. Cryptography

| Item | Value |
|---|---|
| Cipher | AES-256-GCM (`System.Security.Cryptography.AesGcm`) |
| Nonce | 96 bits, random per encryption |
| Tag | 128 bits |
| Associated data (AAD) | `<entry id>\|<version>`. A ciphertext moved to another entry or version fails authentication. |
| Stored value | `base64(nonce ‖ tag ‖ ciphertext)` |
| Plaintext | JSON `{"secret": "...", "passphrase": "..."}` |
| Key check value | The constant `ssp-vault-key-check-v1`, encrypted with AAD `keycheck` and stored as `keyCheck` in `data/vault/vault.json` |
| Other uses of the key | MFA seeds (`data/security/mfa.json`), AAD `value\|mfa\|<user>` |

On every read, the portal decrypts the key check value first. If decryption fails, every vault operation stops with:

> The vault master key (*provider*: *location*) does not match data/vault/vault.json. Restore the original key file; a new key cannot open existing credentials.

**Admin > Vault** shows the same message (status `healthy: false`). A record whose tag does not verify (wrong key, or a modified file) fails with "Vault record cannot be decrypted: the master key does not match or the record was altered."

On Linux, `data/vault/vault.json` and an auto-created key file are set to mode `0600`. On Windows, files inherit the ACL of the portal folder.

## 3. Master key providers

The master key is 32 random bytes. `vault.keyProvider` in `portal.config.json` selects where the key comes from:

| Provider | Key source | Created automatically | Platform |
|---|---|---|---|
| `keyfile` | Base64 key in a file: `SSP_VAULT_KEYFILE` if set, otherwise `vault.keyFile` (absolute, or relative to the portal root), otherwise `data/vault/master.key` | Yes, if the file does not exist (a `WARN` line asks you to back it up) | All. Linux / appliance default. |
| `dpapi` | `data/vault/master.key.dpapi`, protected with Windows DPAPI for the **account that runs the portal** | Yes | Windows only |
| `env` | Base64 key in the `SSP_VAULT_KEY` environment variable | **No**: the portal fails if it is missing | All (containers) |
| `auto` (default) | `keyfile` if `SSP_VAULT_KEYFILE` is set, else `env` if `SSP_VAULT_KEY` is set, else `dpapi` on Windows, else `keyfile` | | All |

- The Linux installer and the OVA generate `/etc/ssp/vault.key` (`ssp:ssp 0400`, `openssl rand -base64 32`) and set `SSP_VAULT_KEYFILE` in `/etc/ssp/portal.env` ([installation-linux.md](installation-linux.md#6-file-locations)).
- `dpapi` binds the key to the service account and the machine. Changing the service account or moving to another server makes the key unreadable. If you need to recover on another machine, use `keyfile` with a protected path and back up that file.
- The portal process caches the key after first use. Restart the service after changing the key configuration. Job runners and connection tests are separate processes and load the key each time.
- The start-up sequence creates or validates the key (`Get-PortalVaultStatus`) before serving requests.

## 4. Scope

Each entry has `scope = { system, items[], teams[] }`:

| Use | Purpose | Allowed when |
|---|---|---|
| vCenter connection (`sites[].credential`) | `site` | `scope.system = true` |
| Cloud connection (`clouds.<provider>.credentialRef`) | `cloud` | `scope.system = true` |
| Directory bind account (`auth.providers[].bindCredential`) | `identity` | `scope.system = true` |
| Catalog job | `item` | `scope.items` contains `*` or the item id, **and** either `scope.teams` is empty or it intersects the request's teams (the item's `access.teams` at submission) |

- `system` and `items` are independent. Platform use ignores `items` and `teams`, and job use ignores `system`.
- `items: ["*"]` allows every catalog item, including items created later by a `CatalogAdmin`. Prefer explicit item ids.
- A request with no teams cannot use an entry restricted to teams.
- An out-of-scope use fails with "Vault entry '<id>' is not allowed for item '<item>' (check its scope in Admin > Vault)."

## 5. Entries

### 5.1 Types

| Type | Typical secret | `username` |
|---|---|---|
| `UsernamePassword` | Password | Account (UPN, `DOMAIN\user`, DN, `user@vsphere.local`) |
| `SshKey` | Private key (PEM/OpenSSH text). The passphrase is optional. | SSH user |
| `ApiToken` | Token | Optional |
| `Certificate` | Base64 PFX. The passphrase is optional. | Optional |
| `ServicePrincipal` | Client secret or secret access key | Client id or access key id. `fields` holds extras (Azure: `tenantId`). |

The type is descriptive: whatever the type, the secret reaches a handler as the password of a `PSCredential` ([6](#6-using-credentials-in-catalog-items)).

### 5.2 Fields

| Field | Description |
|---|---|
| `id` | 2 to 63 characters: lowercase letters, digits, `.`, `_`, `-`, starting with a letter or digit. Immutable. Referenced by configuration and catalog items. |
| `name`, `description` | Display text (no `<` or `>`) |
| `type` | See [5.1](#51-types). Required on creation. |
| `username`, `target` | Account and target (host, URL, account). `target` is informational. |
| `fields` | Free-form object for non-secret extras |
| `scope` | `{ system: bool, items: [], teams: [] }`. Teams must exist. |
| `tags` | Free-form labels. `credential` inputs can filter on them (`vaultTags`). |
| `expiresAt` | Optional date (`YYYY-MM-DD`) |
| `secret` | Write-only. Required on creation. Sending it again creates a new version. |
| `passphrase` | Write-only. Stored with the secret and replaced, or cleared, every time the secret is replaced. |
| (server-managed) | `createdAt/By`, `updatedAt/By`, `lastUsedAt/By`, `useCount`, `version`, `versions` (number of retired versions), `hasPassphrase`, `state` |

### 5.3 Expiry and states

| `state` | Condition | Effect |
|---|---|---|
| `ok` | No expiry date, or more than 30 days left | |
| `expiring` | Less than 30 days left | Highlighted in Admin > Vault |
| `expired` | Past `expiresAt` | **Every use is refused** ("Vault entry '<id>' expired on ..."). Jobs and connections that use it fail. |

The date is evaluated in the server's local time, so a date-only value expires at 00:00 on that day.

### 5.4 Versions

Replacing the secret increments `version`. The previous ciphertext moves to `versions[]` (with `retiredAt` and `retiredBy`), and at most `vault.maxVersions` retired versions are kept (default 5). Retired versions are kept for audit and recovery on disk only: **no UI or API reads or restores them yet**. They remain decryptable by anyone who holds both the key and `vault.json`.

## 6. Using credentials in catalog items

Credentials can reach a handler in two ways:

| Mechanism | Defined in | Chosen by |
|---|---|---|
| Fixed binding | `execution.credentials`: `{ "<HandlerParameter>": "<vault id>" }` | Item author (`CatalogAdmin`), within the entry's scope |
| `credential` input | `inputs[]` with `"type": "credential"` and optional `vaultTags` | Requester, from the in-scope entries |

Rules:

- The handler must declare the parameter, typed `[pscredential]`. The runner binds credentials only to declared parameters, and saving the item fails if `execution.credentials` names an undeclared parameter or an invalid id. Whether the entry exists and is in scope is checked at run time.
- A `credential` input lists the entries whose scope allows the item (and whose tags match `vaultTags`, if set): `POST /api/catalog/:id/options/:input` returns `{value: id, label: "name (username)"}`, never the secret. The submitted id is re-validated against the same list when the request is created.
- Both mechanisms are recorded in the request snapshot at submission (`execution.credentials`, `execution.credentialInputs`). Requests that use either one are subject to [separation of duties](security.md#separation-of-duties).
- At run time, `Invoke-CatalogJob.ps1` calls `Get-PortalVaultSecret -Purpose item -ItemId <item> -Teams <request teams> -RequestId <id>`, enforces scope and expiry, and passes a `PSCredential` (`UserName` = entry `username`, or the entry id if empty; password = secret). The job log records `Credential <param> <- vault '<id>' (user <name>)`, and the audit trail records `vault.use` with `{purpose: "item", item, request}`.
- **Not passed to handlers yet:** the passphrase, which is decrypted only to be masked in the log, `fields` and `target`. A handler that needs a key passphrase must currently use a separate entry.

### Example

Hypothetical item: the handler `Set-VsphereGuestConfig.ps1` is not shipped. It uses a fixed domain-join account and a guest administrator chosen by the requester.

```json
{
  "$schema": "../schema/catalog-item.schema.json",
  "id": "vm-guest-config",
  "version": "1.0.0",
  "name": "Configure guest OS",
  "category": "Datacenter operations",
  "summary": "Joins a VM to the domain and applies the baseline.",
  "access": { "roles": ["Requester"], "teams": ["Infrastructure"] },
  "approval": { "required": true, "approverRoles": ["Approver"] },
  "security": { "requireReauth": true },
  "execution": {
    "handler": "Set-VsphereGuestConfig.ps1",
    "requiresVCenter": true,
    "siteInput": "Site",
    "timeoutMinutes": 30,
    "credentials": { "DomainJoinCredential": "ad-domain-join" }
  },
  "inputs": [
    { "name": "Site", "label": "Datacenter", "type": "select", "required": true, "source": { "type": "sites" } },
    { "name": "VMName", "label": "Virtual machine", "type": "select", "required": true,
      "source": { "type": "vms", "dependsOn": ["Site"] } },
    { "name": "GuestCredential", "label": "Guest administrator", "type": "credential", "required": true,
      "vaultTags": ["windows-guest"] }
  ]
}
```

```powershell
# automation/handlers/Set-VsphereGuestConfig.ps1
param(
    [Parameter(Mandatory)] [string]       $Site,
    [Parameter(Mandatory)] [string]       $VMName,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,       # credential input
    [Parameter(Mandatory)] [pscredential] $DomainJoinCredential,  # execution.credentials
    [Parameter(Mandatory)] $Context
)
Write-JobLog "Guest account: $($GuestCredential.UserName)"       # never log GetNetworkCredential().Password
# Invoke-VMScript -VM $VMName -GuestCredential $GuestCredential -Server $Context.VIServer ...
```

Matching vault entries:

| id | type | scope | tags |
|---|---|---|---|
| `ad-domain-join` | `UsernamePassword` | `items: ["vm-guest-config"]`, `teams: ["Infrastructure"]` | |
| `guest-win-local` | `UsernamePassword` | `items: ["vm-guest-config"]` | `windows-guest` |

> `catalog/schema/catalog-item.schema.json` does not describe `security`, `execution.credentials`, the `credential` input type or `vaultTags` yet, so an editor that validates against the schema flags them. The portal's own validator (`Test-PortalCatalogDefinition`, `tools/Test-CatalogItem.ps1`) accepts them. See [catalog-authoring.md](catalog-authoring.md).

## 7. Job log masking

- The runner collects each decrypted secret and passphrase of the job. `Write-JobLog` replaces every occurrence of a value of 4 or more characters with `********` before writing `logs/jobs/<id>.log`. The smoke test checks this.
- Masked: `Write-JobLog` calls, `Write-Host` / information and warning streams from the handler (redirected through `Write-JobLog`), and the error message and stack trace of a failed job.
- The parameter summary shows credentials as `<credential user>`.
- **Not masked:** the raw process logs `logs/jobs/<id>.stdout.log` and `<id>.stderr.log`, anything a handler writes to other files or systems, transformed values (Base64, URL-encoded, partial), secrets shorter than 4 characters, and usernames. Handlers must never print secrets.

## 8. Backup and master-key rotation

**Back up the key separately from the data.** Without the key, the vault and every MFA enrolment are unrecoverable. With the key and `data/vault/vault.json` together, anyone can decrypt every secret.

| Provider | What to back up |
|---|---|
| `keyfile` | The key file (`/etc/ssp/vault.key` on Linux). `ssp-backup --exclude-key` writes it beside the archive so that you can store it elsewhere ([installation-linux.md](installation-linux.md#11-backup-and-restore)). |
| `env` | The value of `SSP_VAULT_KEY`, from your secret manager |
| `dpapi` | `data/vault/master.key.dpapi` is useful only on the same machine with the same service account. For off-machine recovery, use `keyfile`. |

**Secret rotation** means replacing the secret of an entry (Admin > Vault > Edit > *New secret*). Its references stay valid, and the previous version is retired ([5.4](#54-versions)).

**Master-key rotation is not implemented.** The portal cannot re-encrypt the vault under a new key. If the key is lost or must be replaced:

1. Stop the service.
2. Move `data/vault/vault.json` aside. A new key cannot open it.
3. Install the new key (or let the `keyfile` / `dpapi` provider create one), then start the service.
4. Re-enter every secret: vCenter connections, cloud connections, directory bind accounts, and catalog credentials, using the same ids so that references keep working.
5. Reset MFA for every enrolled user (Admin > Security / Local users, or `tools/Set-PortalLocalUser.ps1 -ResetMfa`). Their seeds were encrypted with the old key, and their sign-in fails until the reset.

## 9. Migration of legacy credentials

Earlier releases stored the vCenter credentials (`sites[].credential.type = "CliXml"`) and cloud secrets (`data/secrets/<provider>.cloud.xml`, or `clouds.<provider>.credentialPath`) as DPAPI-protected CliXml files. At every start, `Import-PortalLegacySecrets` (idempotent) does the following:

| Legacy | Vault entry | Configuration change |
|---|---|---|
| Site `CliXml` credential | `vcenter-<site>` (`UsernamePassword`, `target` = vCenter, system scope) | `sites[].credential = { type: "Vault", id }` |
| Cloud CliXml secret (no `credentialRef`) | `cloud-<provider>` (`ServicePrincipal`, system scope) | `clouds.<provider>.credentialRef = id` |

The source file is renamed to `*.migrated`, and the migration is audited as `vault.migrate`. DPAPI CliXml files can be read only on the Windows machine and by the account that created them. If reading fails, the portal logs a warning and the site keeps its old credential type: re-enter the credential in Admin > vCenter connections / Cloud connections.

Sites that reference a PowerShell SecretManagement vault (`type: "SecretManagement"`) keep working (`tools/Register-PortalCredential.ps1`). If that vault is not registered on the server at start-up, the site is switched to a `Vault` reference (`vcenter-<site>`), and the credential must be entered again. Saving a credential in Admin > vCenter connections always stores it in the portal vault.

## 10. Administration (UI and API)

**Admin > Vault** (`vault.manage`: `Admin`, `VaultAdmin`):

- Status banner: key provider and location, health, number of expired and expiring entries.
- Table: id, name, type, account, scope, **Used by**, version, last use (time, request or actor, count).
- Editor: id, name, type, username, *New secret* (empty = keep), passphrase, target, expiry, *Platform use* (`system`), allowed catalog items (or *any item*), allowed teams, tags, description. Saving asks for your password (re-authentication).

| Operation | API | Notes |
|---|---|---|
| List | `GET /api/admin/vault` | `{status, entries[] (+ usedBy), teams, items}` |
| Create / update | `POST /api/admin/vault` | Re-authentication. `mode: "create"` refuses an existing id. Returns the entry view. |
| Delete | `DELETE /api/admin/vault/:id` | Re-authentication. Refused while referenced. |

**References and deletion protection.** `usedBy` and the delete check look at `sites[].credential` (type `Vault`), `clouds.*.credentialRef`, `auth.providers[].bindCredential` and `execution.credentials` of the files in `catalog/items`. Deletion fails with "Vault entry '<id>' is still used by: site:DC1, item:vm-guest-config". The check does **not** cover `credential` input values in existing requests: deleting such an entry makes queued requests that selected it fail at run time.

Platform credentials are also written by **Admin > vCenter connections** (`vcenter-<site>`) and **Admin > Cloud connections** (`cloud-aws`, `cloud-azure`). These entries have system scope and require `connections.manage` (`Admin`).

For the endpoint details, see [api.md](api.md#vault).

## 11. CLI notes

There is no dedicated vault CLI yet. On the portal server, as the **service account** and with the same environment (`SSP_PORTAL_ROOT`, `SSP_VAULT_KEYFILE` or `SSP_VAULT_KEY`), the module functions can be used directly, for example to load secrets in bulk during an initial deployment:

```powershell
$env:SSP_PORTAL_ROOT = '/opt/ssp'          # Linux example; the key path comes from SSP_VAULT_KEYFILE
'Portal.Core', 'Portal.Security', 'Portal.Vault' | ForEach-Object { Import-Module "/opt/ssp/modules/$_.psm1" }

Get-PortalVaultStatus                                     # provider, location, health (no key material)
$pw = Read-Host -AsSecureString 'Secret'
Set-PortalVaultEntry -Id 'guest-win-local' -Name 'Windows guest admin' -Type UsernamePassword `
    -Username 'Administrator' -Secret ([System.Net.NetworkCredential]::new('', $pw).Password) `
    -Scope @{ items = @('vm-guest-config'); teams = @() } -Tags 'windows-guest' -Actor "CLI\$env:USER" -New
Get-PortalVaultEntry | Format-Table id, type, username, state, version
Get-PortalVaultReference -Id 'guest-win-local'
```

Running as another account cannot open a `dpapi` key and may create a new `keyfile` key in the wrong location. The vault's key check refuses a key that does not match. These functions write the same audit entries as the UI.
