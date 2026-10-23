# Configuration reference

This document describes every setting of the Self-Service Portal: each section and key of `config/portal.config.json` with its type, default and effect, the format of `config/local-users.json`, the environment variables the portal reads, and which settings apply live and which need a restart. Defaults are those of `config/portal.config.default.json` and of the code that reads each key. Most settings are edited in the Admin pages; this reference is for review, automation and troubleshooting.

## Contents

1. [How configuration is stored](#1-how-configuration-is-stored)
2. [Top-level structure](#2-top-level-structure)
3. [Reference](#3-reference) - [portal](#31-portal) · [branding](#32-branding) · [auth](#33-auth) · [teams](#34-teams) · [vmNotes](#35-vmnotes) · [security](#36-security) · [vault](#37-vault) · [jobs](#38-jobs) · [automation](#39-automation) · [inventory](#310-inventory) · [sites](#311-sites) · [clouds](#312-clouds) · [_migrations](#313-_migrations)
4. [local-users.json](#4-local-usersjson)
5. [Live settings and settings that need a restart](#5-live-settings-and-settings-that-need-a-restart)
6. [Environment variables](#6-environment-variables)
7. [Pode server settings (server.psd1)](#7-pode-server-settings-serverpsd1)

---

## 1. How configuration is stored

| File | Purpose |
|---|---|
| `config/portal.config.default.json` | Shipped defaults. Never edited; replaced on upgrade. |
| `config/portal.config.json` | Live configuration. Created from the default file at first start (or by `tools/Set-PortalEndpoint.ps1`); never overwritten by an upgrade. |
| `config/local-users.default.json` / `config/local-users.json` | Shipped / live local accounts (section 4). |
| `config/_backup/portal.config.<yyyyMMddHHmmss>.json` | Copy of the configuration taken before every change made through the portal or the tools. Not pruned automatically. |

Editing rules:

- Prefer the Admin pages: they validate input (ranges, formats, references), take the lock, back up the file and write an audit event.
- Hand edits are possible: the file is re-read automatically when its modification time changes. Keep valid JSON (UTF-8, no comments; keys starting with `_comment` are ignored). Ranges and formats are **not** validated for hand edits; an invalid value can break sign-in or the dispatcher.
- On every start, `Initialize-PortalConfiguration` adds settings introduced by newer releases without changing existing values (see [architecture.md](architecture.md#10-configuration-bootstrap-and-migrations)).

## 2. Top-level structure

| Key | Type | Edited in | Section |
|---|---|---|---|
| `portal` | object | `tools/Set-PortalEndpoint.ps1`, file | [3.1](#31-portal) |
| `branding` | object | Admin > Customization | [3.2](#32-branding) |
| `auth` | object | Admin > Identity, Admin > Customization | [3.3](#33-auth) |
| `security` | object | Admin > Security | [3.6](#36-security) |
| `vault` | object | file | [3.7](#37-vault) |
| `teams` | array | Admin > Customization > Teams | [3.4](#34-teams) |
| `catalog` | object | Admin > Customization > Teams (team roles), file (site value declarations) | [3.16](#316-catalog) |
| `vmNotes` | object | Admin > Customization > VM notes | [3.5](#35-vmnotes) |
| `jobs` | object | file | [3.8](#38-jobs) |
| `automation` | object | file | [3.9](#39-automation) |
| `inventory` | object | file | [3.10](#310-inventory) |
| `sites` | array | Admin > vCenter connections | [3.11](#311-sites) |
| `clouds` | object | Admin > Cloud connections | [3.12](#312-clouds) |
| `operations` | object | file | [3.14](#314-operations) |
| `_migrations` | array | managed by the portal | [3.13](#313-_migrations) |

---

## 3. Reference

The *Live* column states whether a change applies without restarting the portal (section 5 has the summary).

### 3.1 `portal`

| Key | Type | Default | Live | Meaning |
|---|---|---|---|---|
| `name` | string | `Self-Service Portal` | yes | Portal name returned by `/api/me` and used as MFA issuer when `security.mfa.issuer` is empty. Overwritten with `branding.productName` whenever branding is saved. |
| `organization` | string | `Your Organization` | yes | Organization name; overwritten with `branding.organization` when branding is saved. |
| `address` | string | `*` | restart | Listen address (`*` = all interfaces). |
| `port` | integer | `8443` (Linux/OVA installers set `443`) | restart | Listen port. |
| `protocol` | string | `Https` | restart | `Https`; any other value listens on plain HTTP. The `-Http` switch of `Start-Portal.ps1` forces HTTP (lab only). |
| `certificateFile` | string | `""` | restart | Path of the TLS certificate: PEM (with `certificateKeyFile`) or PFX. Takes precedence over `certificateThumbprint`. The portal refuses to start if the file does not exist. Linux/OVA: `/etc/ssp/tls/portal.crt`. |
| `certificateKeyFile` | string | `""` | restart | PEM private key for `certificateFile`. Linux/OVA: `/etc/ssp/tls/portal.key`. |
| `certificatePasswordEnvVar` | string | `""` | restart | **Name** of an environment variable that holds the PFX (or encrypted key) password. The password itself is never stored in the file. |
| `certificateThumbprint` | string | `TBD-CERT-THUMBPRINT` | restart | Windows: SHA-1 thumbprint of a certificate in the `My` store. Non-hex characters are stripped; anything that is not 40 hex digits counts as not configured. |
| `certificateStoreLocation` | string | `LocalMachine` | restart | Store location for `certificateThumbprint` (`LocalMachine` or `CurrentUser`). |
| `sessionSecretEnvVar` | string | `SSP_SESSION_SECRET` | restart | **Name** of the environment variable holding the session cookie signing secret (section 6). |
| `sessionCookieName` | string | not set (`ssp_sid_<port>`) | restart | Session cookie name. The default includes the port so two instances on one host keep separate sessions. |

With `protocol: Https` and neither a valid `certificateFile` nor a 40-digit thumbprint, the portal starts with a Pode **self-signed** certificate and logs a warning (lab only). Use `tools/Set-PortalEndpoint.ps1 [-Port <n>] [-Address <a>] [-CertificateFile <f> [-CertificateKeyFile <k>] [-CertificatePasswordEnvVar <v>] | -CertificateThumbprint <t>]` to change the endpoint; it also creates the configuration from the defaults when needed.

Legacy key `sessionDurationMinutes` is moved to `security.session.absoluteTimeoutMinutes` by the configuration upgrade.

### 3.2 `branding`

Public settings (served to the login page by `GET /api/branding`). Text values cannot contain `<` or `>`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `productName` | string (min 2 chars) | `Self-Service Portal` | Product name in the header, login page and browser title |
| `organization` | string (min 2 chars) | `Your Organization` | Organization name |
| `tagline` | string | `Infrastructure services on demand` | Login page tagline |
| `primaryColor` | `#RRGGBB` | `#0a1f3c` | Header / primary colour |
| `accentColor` | `#RRGGBB` | `#2f6fb8` | Accent colour |
| `logoFile` | string | `""` | Managed by the logo upload: `logo.png`, `logo.jpg` or `logo.webp` in `data/brand/`. PNG, JPEG or WebP only (no SVG), max 512 KB. Served at `/brand/logo`. |
| `loginMessage` | string | `Sign in with your corporate account.` | Text on the login page |
| `footerText` | string | `Confidential - Internal Use. Access is logged and audited.` | Footer text |
| `supportContact` | string | `""` | Support contact shown to users |

All branding settings apply live.

### 3.3 `auth`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `providers` | array | one disabled AD example (`corp`) | Directory identity providers (below). |
| `defaultProvider` | string | `corp` | Provider used for a bare user name that is not a local account. Empty = first enabled provider. Filled in with the first provider saved while it is empty. |
| `roleMapping` | object `{ Role: [group, ...] }` | `Admin`: `SSP-Admins`, `Approver`: `SSP-Approvers`, `Requester`: `SSP-Requesters`, `CatalogAdmin`: `SSP-CatalogAdmins`, `SecurityAdmin`: `SSP-SecurityAdmins`, `VaultAdmin`: `SSP-VaultAdmins` | Directory groups (CN, case-insensitive; a `DOMAIN\` prefix is ignored) that grant each role. Roles: `Requester`, `Approver` (implies Requester), `Admin` (implies every role), `CatalogAdmin`, `SecurityAdmin`, `VaultAdmin`. Local accounts carry their roles in `local-users.json` instead. Changing it requires `security.manage` and a recent re-authentication. |
| `allowSelfApproval` | boolean | `false` | When `true`, an approver may approve his own requests. |
| `localUsers.enabled` | boolean | `true` | Local accounts can sign in. When `false`, only accounts flagged `breakGlass` can. The portal logs a warning at start-up while it is `true`. |
| `localUsers.file` | string | `config/local-users.json` | Path of the local account store (relative to the portal root or absolute). |

Legacy keys `provider`, `fqdn`, `domain` and `directGroupsOnly` are converted into a provider with id `ad` and removed by the configuration upgrade.

#### `auth.providers[]`

Each entry is merged with the defaults of its `flavor`. A short reference follows; the full guide (routing, bind modes, group modes, TLS, troubleshooting) is [identity.md](identity.md).

| Key | Type | Default (`ad` / `openldap`) | Meaning |
|---|---|---|---|
| `id` | string | - | 2-32 lowercase letters, digits or `-`, starting with a letter. Also accepted as a login domain (`id\user`). |
| `name` | string | - | Display name |
| `enabled` | boolean | `false` | Provider used for sign-in |
| `flavor` | string | - | `ad` or `openldap` (any RFC 4511 LDAP v3 server) |
| `domains` | string[] | `[]` | Login domains routed to this provider: `DOMAIN\user` and `user@domain` |
| `hosts` | string[] | - | Directory servers (tried in order by the LDAP client) |
| `port` | integer | `636` (ldaps) or `389` | TCP port; defaults follow `security` when omitted |
| `security` | string | `ldaps` / `ldaps` | `ldaps`, `starttls`, `negotiate` (Kerberos/NTLM sign and seal, Windows + AD only) or `none` (requires `allowInsecure`) |
| `allowInsecure` | boolean | `false` | Permits `security: none` (lab only) |
| `baseDn` | string | - | Search base for users (required) |
| `bindMode` | string | `direct` / `search` | `direct`: bind as the user; `search`: service account finds the user DN, then binds as the user |
| `bindCredential` | string | - | Vault entry id (system scope) of the service account; required for `search` |
| `upnSuffix` | string | - | AD direct bind: bind name `login@upnSuffix` (required for `direct` unless the user typed `user@domain`) |
| `usernamePrefix` | string | AD: first domain without a dot; otherwise upper-case `id` | Prefix of the portal user name (`PREFIX\uid`) |
| `userFilter` | string | AD: `(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))`; OpenLDAP: `(&(objectClass=inetOrgPerson)(uid={0}))` | Must contain `{0}` (escaped login name) |
| `groupMode` | string | `nested` / `search` | `nested` (AD transitive), `memberOf`, `search` |
| `groupFilter` | string | AD: `(&(objectClass=group)(member={dn}))`; OpenLDAP: groupOfNames / groupOfUniqueNames / posixGroup filter | Placeholders `{dn}` and `{uid}` |
| `groupBaseDn` | string | `baseDn` | Search base for groups |
| `attributes` | object | AD: `sAMAccountName`, `displayName`, `mail`; OpenLDAP: `uid`, `cn`, `mail` | Keys `username`, `displayName`, `mail` |
| `tls.verify` | boolean | `true` | Verify the server certificate (`false` = lab only; on Linux sets `LDAPTLS_REQCERT=never` for the process) |
| `tls.caFile` | string | - | Linux: CA bundle (sets `LDAPTLS_CACERT` for the process if not already set) |
| `tls.caDirectory` | string | - | Linux: directory of trusted CA certificates |
| `timeoutSeconds` | integer | `10` | LDAP operation timeout |

### 3.4 `teams`

Teams decide which catalog items a user sees and which requests an approver can decide on.

| Key | Type | Meaning |
|---|---|---|
| `teams[].id` | string | 2-32 letters, digits, `_` or `-`, starting with a letter. Referenced by catalog items (`access.teams`), local users and vault scopes. A team cannot be removed while a catalog item references it. |
| `teams[].name` | string | Display name (required) |
| `teams[].adGroups` | string[] | Directory groups (CN) whose members belong to the team |

Default: `Infrastructure` (`SSP-Team-Infrastructure`) and `Cloud` (`SSP-Team-Cloud`). Live.

### 3.5 `vmNotes`

Fields of the *VM notes* section added to every build item with `"vmNotes": true`. Values are passed to the handler as `-VmNotes` (Label = value): vSphere appends them to the VM notes, AWS and Azure create `Note-<Label>` tags.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `true` | Show the section |
| `title` | string | `VM notes` | Section title in the form |
| `fields[].key` | string | - | Alphanumeric, starts with a letter, max 31 chars. The form input is named `Note<key>`. |
| `fields[].label` | string | key | Label (also the note / tag name) |
| `fields[].type` | string | `text` | `text`, `textarea` or `select` |
| `fields[].required` | boolean | `false` | Required field |
| `fields[].options` | string[] | - | Values for `select` (required for `select`) |
| `fields[].help` | string | - | Help text |
| `fields[].pattern` | string | - | Regular expression the value must match |

Every value is limited to 250 characters. Defaults: Application (required), Environment (required select), Business owner, Support group, Backup policy, Patch window, Expiration / review date. Live.

### 3.6 `security`

Edited in Admin > Security (requires `security.manage` and re-authentication). The ranges below are enforced when saving through the portal; hand edits are not range-checked.

| Key | Type | Default | Range | Meaning |
|---|---|---|---|---|
| `session.idleTimeoutMinutes` | integer | `30` | 5-120 | Session ends after this much inactivity (background polling does not count) |
| `session.absoluteTimeoutMinutes` | integer | `480` | 30-1440 | Maximum session length. The server check is live; the **cookie** lifetime is read at start-up (section 5). |
| `session.warningSeconds` | integer | `120` | 30-600 | The browser warns this long before the idle timeout |
| `session.reauthWindowMinutes` | integer | `5` | 1-60 | How long a password confirmation counts for sensitive actions |
| `password.minLength` | integer | `14` | 8-128 | Local accounts: minimum length |
| `password.requireClasses` | integer | `3` | 1-4 | Local accounts: number of character classes (lower, upper, digit, symbol) |
| `password.history` | integer | `5` | 0-24 | Local accounts: previous passwords that cannot be reused |
| `password.maxAgeDays` | integer | `0` | 0-3650 | Local accounts: forced change after N days (`0` = never) |
| `lockout.threshold` | integer | `5` | 3-50 | Failed sign-ins per user within the window before a lock. Per client IP the threshold is 4 times this value. |
| `lockout.windowMinutes` | integer | `15` | 1-1440 | Counting window |
| `lockout.durationMinutes` | integer | `15` | 1-1440 | Lock duration |
| `mfa.requiredRoles` | string[] | `Admin`, `SecurityAdmin`, `VaultAdmin` | known roles | Users holding any of these (effective) roles must enrol a TOTP authenticator before using the portal. Because Admin implies every role, an Admin always matches. |
| `mfa.issuer` | string | `""` (= `portal.name`) | no `<`, `>`, `:` | Issuer shown in the authenticator app |
| `adminAllowedCidrs` | string[] | `[]` | IPs / CIDRs, IPv4 or IPv6 | When set, the administrative roles (Admin, CatalogAdmin, SecurityAdmin, VaultAdmin) only apply to clients inside these networks; elsewhere the user keeps only the non-administrative roles. A list that excludes the caller's own address is refused. |
| `trustedProxies` | string[] | `[]` | IPs / CIDRs | Reverse proxies whose `X-Forwarded-For` header is trusted for the client IP (lockout, ticket binding, admin networks, audit) |
| `separationOfDuties.vaultAdminCanApprove` | boolean | `false` | - | Allow a VaultAdmin to approve requests that use vault credentials |

All `security` settings apply live except the cookie lifetime. Details: [security.md](security.md).

### 3.7 `vault`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `keyProvider` | string | `auto` | Source of the 256-bit master key: `keyfile`, `dpapi` (Windows only), `env` or `auto`. `auto` resolves, in this order, to `keyfile` when `SSP_VAULT_KEYFILE` is set, `env` when `SSP_VAULT_KEY` is set, `dpapi` on Windows, otherwise `keyfile`. |
| `keyFile` | string | not set (`data/vault/master.key`) | Path of the key file for the `keyfile` provider when `SSP_VAULT_KEYFILE` is not set; relative to the portal root or absolute. Not present in the default file. |
| `maxVersions` | integer | `5` | Previous secret versions kept per entry |

The `keyfile` and `dpapi` providers create the key on first use (`dpapi`: `data/vault/master.key.dpapi`, protected for the **Windows account that runs the portal**). The key is cached per process: changing the provider needs a restart. The same key also encrypts the MFA seeds in `data/security/mfa.json`. Read [vault.md](vault.md) before changing anything here.

### 3.8 `jobs`

| Key | Type | Default | Live | Meaning |
|---|---|---|---|---|
| `maxConcurrent` | integer | `3` | yes | Maximum jobs in `Dispatched` + `Running` at the same time. Each job is a `pwsh` process (150-300 MB). |
| `dispatcherIntervalSeconds` | integer | `10` | restart | Interval of the dispatcher timer |
| `pwshPath` | string | `pwsh` | yes | Executable used for jobs, inventory refreshes and connection tests. Use a full path when `pwsh` is not on the service's `PATH` (for example `C:\Program Files\PowerShell\7\pwsh.exe`). |
| `defaultTimeoutMinutes` | integer | `60` | yes (new requests) | Timeout for items without `execution.timeoutMinutes`. Copied into the request at submission. `0` disables the timeout. A timed-out runner is killed and the request set to `Failed`. |
| `rollbackOnFailure` | boolean | `true` | yes | Passed to handlers as `Context.RollbackOnFailure`; the shipped build handlers remove partially created VMs / instances / resources when `true`. |

### 3.9 `automation`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `allowedHandlerRoots` | string[] | `[]` | Extra folders (absolute or relative to the portal root) from which catalog handlers may run, in addition to `automation/handlers`. A handler outside every root is refused at validation and at run time. Live. |

### 3.10 `inventory`

| Key | Type | Default | Live | Meaning |
|---|---|---|---|---|
| `refreshIntervalMinutes` | integer | `30` | restart | Interval of the automatic inventory refresh of every enabled site |
| `staleAfterMinutes` | integer | `120` | yes | Age after which Admin > vCenter connections flags a site's inventory as stale |

### 3.11 `sites`

One entry per vCenter. Managed in Admin > vCenter connections (requires `connections.manage`, i.e. Admin). Live.

| Key | Type | Default (new site) | Meaning |
|---|---|---|---|
| `code` | string | - | 2-8 upper-case letters/digits; the value of the `Site` input |
| `name` | string | code | Display name |
| `enabled` | boolean | `false` | Offered in forms, refreshed by the inventory timer, usable by jobs |
| `vcenter` | string | - | vCenter host name or IP |
| `credential.type` | string | `Vault` | `Vault` (portal vault); legacy `SecretManagement` (`vault`, `secret` keys; Microsoft.PowerShell.SecretManagement vault registered for the service account, see `tools/Register-PortalCredential.ps1`) or `CliXml` (`path`; DPAPI file, Windows only, migrated to the vault at start-up). |
| `credential.id` | string | `vcenter-<code>` | Vault entry id (`UsernamePassword`, system scope). Saving a service account in Admin creates / updates it. |
| `invalidCertificateAction` | string | `Ignore` | PowerCLI certificate policy: `Ignore`, `Warn`, `Fail` (the API also accepts `Prompt`, which is not useful in unattended jobs). |
| `useSystemProxy` | boolean | not set (`false`) | PowerCLI uses `NoProxy` unless `true`. Not exposed in the Admin page. |
| `defaults.workloadClusters` | object | `{ App: "", DB: "" }` | Workload to cluster mapping used by the build items (the requester picks App / DB, never a cluster). Saving it also rewrites `allowedClusters`. |
| `defaults.allowedClusters` | string[] | derived | Clusters offered by `clusters` lookups |
| `defaults.vmFolder` | string | `Portal-Provisioned` | Stored and shown in Admin; **not used** by the shipped handlers or lookups (requesters pick the folder from the inventory). |
| `defaults.dnsDomain` | string | `""` | DNS domain for Linux guest customization |
| `defaults.dnsServers` | string[] | `[]` | DNS servers used when the request does not specify any |
| `defaults.minDatastoreFreePercent` | number | `15` (handlers fall back to 10 when unset) | Free-space floor checked before cloning or adding a disk |
| `defaults.portgroupFilter` | string (regex) | `.*` | Port groups offered by `portgroups` lookups |
| `catalogValues` | object | declared keys with their `TBD-` defaults | Per-site values that catalog items read as `@site:<key>` (templates, customization specs, media paths). Only keys declared in `catalog.siteValues` are accepted. Edited in Admin > vCenter connections > Catalog values. |
| `aria.enabled` | boolean | `false` | Use the Aria Operations / VCF Operations instance of this site (troubleshooting, evidence, reports). Needs `aria.endpoint`. |
| `aria.endpoint` | string | `""` | Host name (FQDN or IP, optional `:port`) of Aria Operations; `https://` and paths are stripped. |
| `aria.authSource` | string | `local` | `local` or the name of the authentication source configured in Aria (AD, vIDM). |
| `aria.credential` | object | `{ type: Vault, id: aria-<code> }` | Vault entry (UsernamePassword, system scope) created when the account is saved in Admin. |
| `aria.invalidCertificateAction` | string | `Ignore` | `Ignore` (accept self-signed) or `Fail` (require a trusted CA). |
| `aria.useSystemProxy` | boolean | `false` | Reach Aria through the system proxy instead of directly. |
| `aria.objectUrlTemplate` | string | `""` | Optional `https://...` link to an object in the Aria UI; `{endpoint}` and `{id}` (resource id) are replaced. Empty = Aria home page. |
| `aria.reports[]` | array of `{ id, name, subject[] }` | `[]` | Report definitions offered in request forms (lookup `ariaReports`). Filled from *Test Aria and sync reports* in Admin. |

### 3.12 `clouds`

Managed in Admin > Cloud connections (requires `connections.manage`). Only the keys listed in the tables can be changed through the API. Secrets are stored in the vault (`cloud-aws`, `cloud-azure`, system scope) and referenced by `credentialRef`. Live.

#### `clouds.aws`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Connection active (lookups and jobs refuse a disabled connection) |
| `displayName` | string | `AWS` | Name in the UI |
| `authMode` | string | `AccessKey` | `AccessKey` (key id + secret from the vault) or `DefaultChain` (AWS SDK default credentials of the service account: environment, profile, instance profile) |
| `accessKeyId` | string | `""` | Access key id (stored as the vault entry user name) |
| `roleArn` | string | `""` | Optional role assumed after authentication (`sts:AssumeRole`) |
| `region` | string | `us-east-1` | Region (validated format) |
| `vpcId` | string | `""` | VPC; subnets outside it are refused |
| `subnets` | array of `{ id, label }` | `[]` | Subnets offered to requesters |
| `securityGroupIds` | string[] | `[]` | Security groups attached to every instance |
| `keyPairName` | string | `""` | EC2 key pair attached to every instance |
| `instanceTypes` | string[] | 5 types | Allowed instance types |
| `images.Windows2025` | object | `ssmParameter: /aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base` | `amiId` (pinned) or `ssmParameter` |
| `images.AlmaLinux` | object | `ownerId: 764336703387`, `namePattern: AlmaLinux OS 9*x86_64*` | `amiId`, `ssmParameter`, or newest image of `ownerId` matching `namePattern` |
| `defaultTags` | object | `{ ManagedBy: SelfService-Portal }` | Tags added to every instance and volume |
| `credentialRef` | string | `""` | Vault entry id; set automatically when the secret is saved |
| `credentialPath` | string | not set | Legacy DPAPI secret file, migrated to the vault on Windows |

#### `clouds.azure`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Connection active |
| `displayName` | string | `Azure` | Name in the UI |
| `authMode` | string | `ServicePrincipal` | `ServicePrincipal` (client id + secret from the vault) or `ManagedIdentity` (portal running on Azure / Arc) |
| `tenantId`, `subscriptionId`, `clientId` | GUID strings | `""` | Tenant, subscription, service principal application id |
| `location` | string | `eastus` | Region of new resources |
| `resourceGroup` | string | `""` | Resource group of new VMs, NICs, disks, public IPs |
| `vnetResourceGroup` | string | `""` (= `resourceGroup`) | Resource group of the VNet (and first place where the NSG is looked up) |
| `vnetName` | string | `""` | VNet |
| `subnets` | string[] | `[]` | Subnet names offered to requesters |
| `nsgName` | string | `""` | NSG associated with every NIC (optional) |
| `vmSizes` | string[] | 4 sizes | Allowed VM sizes |
| `adminUsername` | string | `sspadmin` | Local administrator user name |
| `sshPublicKey` | string | `""` | Public key for Linux VMs (required for AlmaLinux) |
| `keyVaultName` | string | `""` | Key Vault that receives the Windows local admin password (`<vm>-localadmin`); required for Windows |
| `images.Windows2025` | object | `urn: MicrosoftWindowsServer:WindowsServer:2025-datacenter-azure-edition:latest`, `plan: false` | `publisher:offer:sku:version` and whether the image has a purchase plan |
| `images.AlmaLinux` | object | `urn: almalinux:almalinux-x86_64:9-gen2:latest`, `plan: true` | Marketplace terms are accepted automatically when `plan` is `true` |
| `defaultTags` | object | `{ ManagedBy: SelfService-Portal }` | Tags on every resource |
| `credentialRef` | string | `""` | Vault entry id; the entry also stores `tenantId` as a field |

Required cloud permissions: [requirements.md](requirements.md#83-aws-iam), [requirements.md](requirements.md#84-azure-rbac).

### 3.13 `_migrations`

List of one-time upgrade steps already applied. Managed by the portal; do not edit.

| Id | Effect when it runs |
|---|---|
| `cert-ignore-2026-09` | Sets `invalidCertificateAction: Ignore` on **every** site |
| `clouds-2026-09` | Adds the `clouds` section |
| `examples-2025` | Archives the retired example items `vm-windows-2022.json` and `vm-rhel-9.json` |
| `teams-2026-10` | Adds `teams` |
| `vmnotes-2026-10` | Adds `vmNotes` |
| `team-scopes-2026-10` | Scopes catalog items without `access.teams` (cloud handlers to Cloud, others to Infrastructure), enables VM notes on build items, gives local users without teams every team |
| `identity-2026-10` | Converts the legacy AD sign-in into `auth.providers`, adds `security` and `vault` |

A fresh configuration already contains every id. Removing an id makes the step run again at the next start; in particular, removing `cert-ignore-2026-09` resets every site to `Ignore`.

---

## 4. `local-users.json`

Local accounts are meant for first setup and break-glass access. Manage them in Admin > Local users or with `tools/Set-PortalLocalUser.ps1`; do not write password hashes by hand.

```json
{
  "users": [
    {
      "username": "admin",
      "displayName": "Portal Administrator",
      "email": "",
      "roles": [ "Admin" ],
      "teams": [ "Infrastructure", "Cloud" ],
      "enabled": true,
      "passwordHash": "pbkdf2-sha256$210000$<salt base64>$<hash base64>",
      "passwordHistory": [ "pbkdf2-sha256$..." ],
      "passwordChangedAt": "2026-10-01T08:00:00.0000000Z",
      "createdAt": "2026-09-30T21:24:55.5509424Z",
      "updatedAt": "2026-10-01T08:00:00.0000000Z",
      "mustChangePassword": true,
      "breakGlass": false
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `username` | 3-32 characters: letters, digits, `.`, `_`, `-`. Signs in as `username`, `LOCAL\username` or `.\username`; the portal user name is `LOCAL\username`. |
| `displayName`, `email` | Display data |
| `roles` | Portal roles (same names as `auth.roleMapping`) |
| `teams` | Team ids |
| `enabled` | Disabled accounts cannot sign in |
| `passwordHash` | PBKDF2-HMAC-SHA256, 210,000 iterations, 16-byte salt, 32-byte hash |
| `passwordHistory` | Previous hashes (up to `security.password.history`) |
| `passwordChangedAt` | Used by `security.password.maxAgeDays` |
| `mustChangePassword` | Forces a change at the next sign-in. Set automatically when someone other than the owner sets the password. |
| `breakGlass` | Can sign in even when `auth.localUsers.enabled` is `false`; every sign-in is audited as `auth.breakglass` and logged as a warning |

The shipped account is `admin` / `ChangeMe-2026!` with `mustChangePassword: true`. Because Admin requires MFA by default, the first sign-in also asks for authenticator enrolment.

## 5. Live settings and settings that need a restart

The configuration file is re-read whenever its modification time changes, by the web server and by every new job process. The following are read **only at start-up** of `Start-Portal.ps1`:

| Setting | Why |
|---|---|
| `portal.address`, `portal.port`, `portal.protocol`, `portal.certificate*` | The Pode endpoint is created at start-up |
| `portal.sessionSecretEnvVar` and the secret itself | Session middleware configured at start-up |
| `security.session.absoluteTimeoutMinutes` (cookie lifetime only) | The Pode cookie duration is set at start-up; the server-side absolute timeout check is live. After increasing it, restart so the cookie does not expire earlier than the policy. |
| `jobs.dispatcherIntervalSeconds`, `inventory.refreshIntervalMinutes` | Pode timers are created at start-up |
| `vault.keyProvider`, `vault.keyFile`, `SSP_VAULT_KEYFILE`, `SSP_VAULT_KEY` | The master key is cached by the web server process (job processes read it fresh) |
| Linux: `tls.caFile` / `tls.verify` of LDAP providers | libldap reads `LDAPTLS_CACERT` / `LDAPTLS_REQCERT` once per process |
| `server.psd1` | Read by Pode at start-up |
| Pode thread count (8) | Fixed in `Start-PodeServer -Threads 8` |

Everything else (branding, teams, role mapping, VM notes, policies, security policy, identity providers, sites, clouds, jobs limits and timeouts, catalog items, handlers) applies live.

## 6. Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `SSP_PORTAL_ROOT` | Modules, runners, tools | Portal root folder. `Start-Portal.ps1` always sets it to its own folder and passes it to child processes; set it yourself only when running tools from elsewhere. Linux: in `/etc/ssp/portal.env`. |
| `SSP_SESSION_SECRET` (name configurable in `portal.sessionSecretEnvVar`) | Web server | Secret that signs the session cookie. Without it, sessions do not survive a restart. Linux/OVA: 64 hex characters generated into `/etc/ssp/portal.env`. Windows: machine environment variable or service environment (see [installation-windows.md](installation-windows.md#8-session-secret)). |
| `SSP_VAULT_KEYFILE` | Vault (all processes) | Path of the base64 vault key file; selects the `keyfile` provider under `auto`. Linux/OVA: `/etc/ssp/vault.key` (`ssp:ssp 0400`). |
| `SSP_VAULT_KEY` | Vault | Base64 32-byte key in the environment (`env` provider; selected by `auto` when `SSP_VAULT_KEYFILE` is not set) |
| variable named by `portal.certificatePasswordEnvVar` | Web server | PFX / key password |
| `LDAPTLS_CACERT`, `LDAPTLS_REQCERT` | libldap (Linux) | CA bundle and certificate requirement for LDAPS/StartTLS. The portal sets them from a provider's `tls.caFile` / `tls.verify: false` only when they are not already set; setting them in the service environment applies them to every provider. |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | .NET (AWS.Tools, Az) | Outbound proxy. PowerCLI ignores it unless the site sets `useSystemProxy`. |
| `SSP_ADMIN_PASSWORD` | `packaging/linux/install.sh` | Initial password of the portal `admin` account (install time only) |
| `SSP_POWERCLI_MODULE` | `install.sh` | `VMware.PowerCLI` or `VCF.PowerCLI` |
| `SSP_TEST_LDAP_HOST`, `SSP_TEST_LDAP_PORT`, `SSP_TEST_LDAP_CA` | `tests/Invoke-SmokeTest.ps1` | Live LDAP tests ([operations.md](operations.md#7-running-the-test-suite)) |

## 7. Pode server settings (`server.psd1`)

`server.psd1` in the portal root is read by Pode at start-up:

| Setting | Value | Meaning |
|---|---|---|
| `Server.Request.Timeout` | `180` | Seconds Pode waits for a request before answering 408 (vCenter connection tests can take up to 60 s; cloud tests up to 90 s) |
| `Server.Request.BodySize` | `10MB` | Maximum request body (logo uploads are limited to 512 KB by the portal itself) |

### 3.14 `operations`

Settings used by the operational catalog items (added in 1.1.0; upgrades add the section with these defaults). Handlers receive it as `Context.Operations`. Live.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `storage.rescanCooldownMinutes` | `10` | New datastore | Minimum time between two storage rescans of the same cluster |
| `storage.lockTimeoutMinutes` | `30` | New datastore | A cluster storage lock older than this is considered stale |
| `storage.minLunSizeGB` | `1` | New datastore | Smaller devices are not offered |
| `storage.datastoreNamePattern` | `^[A-Za-z0-9][A-Za-z0-9_-]{2,41}$` | New datastore | Datastore naming convention (the item input carries the same pattern) |
| `decommission.quarantineFolder` | `Portal-Quarantine` | Decommission, Purge | VM folder for quarantined VMs |
| `decommission.quarantineDays` | `14` | Decommission | Days before a quarantined VM can be purged |
| `decommission.renamePrefix` | `DECOM-` | Decommission, Purge | Prefix added to quarantined VMs |
| `decommission.protectedNamePattern` | `^(vCLS\|vcsa\|vcenter\|nsx)` | Decommission | VMs that can never be decommissioned |
| `snapshots.defaultMaxAgeDays` | `7` | Snapshot cleanup | Default age limit |
| `snapshots.protectedDescriptionPattern` | `(?i)keep\|do not delete\|backup` | Snapshot cleanup | Snapshots that are never removed |
| `testClones.folder` / `isolatedPortgroup` / `maxDays` / `namePrefix` | `Portal-TestClones` / `""` / `7` / `TST-` | Isolated test clone | Where clones go; when `isolatedPortgroup` is set (name or regex), clones can only connect to it |
| `rightSizing.lookbackDays`, `cpuLowPercent`, `cpuHighPercent`, `memoryLowPercent`, `memoryHighPercent` | `30`, `20`, `80`, `30`, `85` | Right-sizing report | Thresholds on the 95th percentile |
| `certificates.warningDays` / `criticalDays` | `60` / `30` | Certificate report | Expiry thresholds |
| `capacity.forecastDays` / `thresholdPercent` | `90` / `85` | Capacity forecast | Forecast horizon and threshold |
| `powerSchedules.tagKey` / `timeZone` | `PowerSchedule` / `UTC` | Cloud power action, cost report | Tag that selects instances |
| `reports.retentionDays` | `180` | Reports | Retention of `data/reports` (informational; clean-up is an operations task) |
| `troubleshooting.timeZone` | `UTC` | VM troubleshooting, incident evidence, change metrics | Time zone of the incident / change times typed in forms (Windows or IANA id, e.g. `America/Chicago`). Reports show UTC. |
| `troubleshooting.cpuReadyWarnPercent` / `cpuReadyCriticalPercent` / `coStopWarnPercent` | `5` / `10` / `3` | VM troubleshooting | CPU contention thresholds (per vCPU, at the sample peak) |
| `troubleshooting.diskLatencyWarnMs` / `diskLatencyCriticalMs` | `20` / `30` | VM troubleshooting | Disk latency thresholds |
| `troubleshooting.guestDiskFreeWarnPercent` / `guestDiskFreeCriticalPercent` / `guestMemoryWarnPercent` | `20` / `10` / `90` | VM troubleshooting | Guest thresholds |
| `troubleshooting.maxEvents` | `2000` | VM troubleshooting, incident evidence | vCenter events read per object |
| `orphanedDisks.pathExcludePattern` | Content Library, FCD, vSphere Replication, system folders | Orphaned VMDK | Regex of paths never reported |
| `orphanedDisks.topItems` | `20` | Orphaned VMDK | Size of the "largest items" table |
| `batchBuild.maxVms` / `pollSeconds` / `stuckMinutes` / `customizationMinutes` | `20` / `30` / `45` / `40` | Windows VM build (batch) | VMs per request, polling interval, no-progress limit per step, guest customization limit |
| `batchBuild.updateRounds` / `updateRoundMinutes` / `domainJoinAttempts` / `maxBootstrapMinutes` | `3` / `120` / `3` / `300` | Windows VM build (batch) | Windows Update rounds and limit per round, join retries, overall bootstrap limit (keep the item `timeoutMinutes` above it) |

Upgrades add any `operations.*` section that is missing, with these defaults, without touching the existing ones.

### 3.15 Data files

Some items read editable JSON files in `config/` instead of the main configuration. They are created from `config/<name>.default.json` at first start, never overwritten by upgrades, and edited in **Admin > Data files** (`catalog.manage`; saving asks for the password and keeps the previous version in `config/_backup`).

| File | Used by | Content |
|---|---|---|
| `software.json` | Agent baseline, Three-tier blueprint | Software repository: `repository.windowsBase` / `linuxBase`, `packages[]` (`id`, `name`, `os`, `version`, `installer`, `installArgs`, `verify { type: service\|file\|command\|package, value }`, `status: Approved\|Pending\|Retired`) and `sets[]` (`id`, `name`, `os`, `packages`). Only **Approved** packages are installed. The backup agent ships as *Pending* until a backup product is approved. |
| `version-baseline.json` | Version compliance | `targets` (vCenter / ESXi `minBuild`, VMware Tools `minVersion`, VM hardware `minVersion`) and `advisories[]` (`id`, `product`, `fixedBuild`, optional `appliesToVersion`). 0 / empty = not set. |
| `hardening-baseline.json` | Hardening compliance | `esxiAdvancedSettings[]`, `esxiServices[]`, `vmAdvancedSettings[]` with `operator` `eq\|ne\|le\|ge\|range\|nonEmpty`, `expected`, `defaultCompliant`. Read-only checks. |
| `backup.json` | Backup policy, Decommission | `connector` (`vsphereTag`; other connectors are templates in `catalog/_connectors/backup/`), `tagCategory` (`Backup-Policy`), `cloudTagName`, `policies[]`. |
| `drs-rules.json` | DRS rule compliance | `largeVmGB` / `mediumVmGB` (large VMs highlighted per host), `vmNamePattern` (VM detail table, e.g. `(?i)sql`), `clusters[]` (`site`, `cluster`, `rules[]` with `name`, `type` `Separate\|Together`, `vms[]`, `note`, and `decommission[]` VM names that should be gone). Every rule found in the cluster is checked anyway; listed rules are also checked for existence, type and exact members. |

### 3.16 `catalog`

Maps the shipped catalog items to your deployment, so the items themselves contain no organisation-specific names. Added by the 1.1.1 upgrade (an existing installation keeps its teams: the first team becomes `@datacenter`, a team whose id contains *cloud* becomes `@cloud`). Live.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `teamRoles` | object | `{ datacenter: "Infrastructure", cloud: "Cloud" }` | Team id for each team role used in `access.teams` of the items (`@datacenter`, `@cloud`). Must reference ids in `teams[]`. Edited in Admin > Customization > Teams. |
| `siteValues[]` | array of `{ key, label, help, usedBy[], default }` | 5 keys | Declares the per-site values items may reference as `@site:<key>`. `default` (normally `TBD-...`) is written into every site that lacks the key. |

Shipped keys:

| Key | Used by | Example |
|---|---|---|
| `windowsTemplate` | `vm-windows-2025`, `blueprint-three-tier`, `vm-windows-batch` | `TPL-WIN2025` |
| `windowsCustomizationSpec` | `vm-windows-2025`, `blueprint-three-tier`, `vm-windows-batch` | `WIN2025-BASE` |
| `linuxTemplate` | `vm-almalinux` | `TPL-ALMALINUX9` |
| `linuxCustomizationSpec` | `vm-almalinux` | `ALMALINUX-BASE` |
| `sqlServerMediaPath` | `sql-server-2022`, `blueprint-three-tier` | `\\fileserver\software\SQL2022` |
