# Identity and sign-in

This guide explains how users sign in to the Self-Service Portal. It covers local accounts, Active Directory and OpenLDAP (any LDAP v3 server), username routing, role and team mapping, TLS trust on Linux, and how to migrate from the former Windows-only AD login. For session, MFA and lockout behaviour, see [security.md](security.md). For directory service accounts that are stored in the vault, see [vault.md](vault.md).

## Contents

1. [Overview](#1-overview)
2. [Local accounts](#2-local-accounts)
3. [Directory providers (Active Directory / OpenLDAP)](#3-directory-providers-active-directory--openldap)
4. [Username routing and portal usernames](#4-username-routing-and-portal-usernames)
5. [Roles and teams](#5-roles-and-teams)
6. [TLS trust on Linux](#6-tls-trust-on-linux)
7. [Admin > Identity](#7-admin--identity)
8. [Step-by-step examples](#8-step-by-step-examples)
9. [Migration from the Windows AD form login](#9-migration-from-the-windows-ad-form-login)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

| Source | Where it is configured | Verified by |
|---|---|---|
| Local accounts | `config/local-users.json` (path in `auth.localUsers.file`) | PBKDF2-HMAC-SHA256 hash comparison in the portal |
| Active Directory | `auth.providers[]` with `flavor: "ad"` | LDAP bind against the domain controllers |
| OpenLDAP / other LDAP v3 | `auth.providers[]` with `flavor: "openldap"` | LDAP bind against the directory |

LDAP uses `System.DirectoryServices.Protocols`, which ships with PowerShell 7, so Windows and Linux run the same code. On Linux the library needs the OpenLDAP client library, `libldap` (see [6.4](#64-libldap-compatibility-link)).

Every provider lives in `config/portal.config.json` under `auth`. You can edit it in **Admin > Identity**, which requires the `security.manage` permission.

```mermaid
flowchart LR
  U[Login name] --> R{Routing}
  R -->|LOCAL\user, .\user,<br/>or bare name of an enabled local account| L[Local account]
  R -->|DOMAIN\user or user@domain| P[Provider listing that domain]
  R -->|bare name, no local account| D[auth.defaultProvider<br/>or first enabled provider]
  L --> C[Roles: from local-users.json<br/>Teams: from local-users.json]
  P --> G[Groups from directory]
  D --> G
  G --> M[Roles: auth.roleMapping<br/>Teams: teams[].adGroups]
```

## 2. Local accounts

Local accounts are meant for first setup, labs, and break-glass access. Their store is `config/local-users.json`, which is created from `config/local-users.default.json` on first start. The default file contains one account, `admin` (role `Admin`, `mustChangePassword: true`).

### 2.1 Account fields

| Field | Description |
|---|---|
| `username` | 3 to 32 characters: letters, digits, `.`, `_`, `-`. The portal username becomes `LOCAL\<username>`. |
| `displayName`, `email` | Shown in the UI and copied into requests. |
| `roles` | Portal roles assigned directly (see [5.1](#51-roles)). At least one is required for a new account. |
| `teams` | Team ids from `teams[]`. Unknown teams are rejected. |
| `enabled` | Disabled accounts cannot sign in, and bare-name routing ignores them. |
| `passwordHash` | `pbkdf2-sha256$<iterations>$<salt b64>$<hash b64>`: 210,000 iterations, 16-byte random salt, 32-byte hash. |
| `passwordHistory`, `passwordChangedAt` | Used by the password policy (history and maximum age). |
| `mustChangePassword` | Forces a password change at the next sign-in (API responses return `403 PASSWORD_CHANGE_REQUIRED` until it is done). |
| `breakGlass` | The account can sign in even when local accounts are disabled. |
| `createdAt`, `updatedAt` | Timestamps. |

The password policy (`security.password`) applies to local accounts only. A password set by someone else, through the admin UI, the API or the CLI, must be changed by the owner at the next sign-in, unless the caller explicitly sets `mustChangePassword: false` (CLI: `-NoPasswordChange`). See [security.md](security.md#password-policy).

An account cannot disable itself, delete itself, or remove its own `Admin` / `SecurityAdmin` role.

### 2.2 Enabling and disabling local sign-in

`auth.localUsers.enabled` controls local sign-in (default `true`). You can change it in either of two places:

- **Admin > Identity > Local accounts enabled** (`POST /api/admin/identity/options`, requires re-authentication), or
- **Admin > Customization > Policies** (`POST /api/admin/settings` with `policies.localUsersEnabled`, requires re-authentication).

When it is `false`, only accounts with `breakGlass: true` can sign in locally. The portal logs a warning at start-up while local accounts are enabled.

> A break-glass sign-in is audited as `auth.breakglass` (not `auth.success`), written to the portal log as a `WARN` line, flagged in the session list, and listed in a banner on **Admin > Security**.

### 2.3 Command-line management

`tools/Set-PortalLocalUser.ps1` uses the same functions as the admin UI. Run it on the portal server as the service account.

```powershell
pwsh -File tools/Set-PortalLocalUser.ps1 -Username admin                          # reset password (prompts)
pwsh -File tools/Set-PortalLocalUser.ps1 -Username ops1 -Roles Requester -Teams Infrastructure
pwsh -File tools/Set-PortalLocalUser.ps1 -Username breakglass -Roles Admin -BreakGlass
pwsh -File tools/Set-PortalLocalUser.ps1 -Username admin -Unlock -ResetMfa        # clear lockout + authenticator
pwsh -File tools/Set-PortalLocalUser.ps1 -Username ops1 -Disable
pwsh -File tools/Set-PortalLocalUser.ps1 -Username ops1 -Remove
```

The actor is recorded as `CLI\<OS user>` in the audit trail.

## 3. Directory providers (Active Directory / OpenLDAP)

### 3.1 Provider fields

| Field | Required | Default (`ad` / `openldap`) | Description |
|---|---|---|---|
| `id` | yes | | 2 to 32 characters: lowercase letters, digits, `-`, starting with a letter. Used in logs, as the `Provider` of a session and, upper-cased, as the fallback username prefix. |
| `name` | no | | Display name. |
| `enabled` | no | `false` | Disabled providers are ignored for routing and sign-in. |
| `flavor` | yes | | `ad` or `openldap`. Selects the defaults in this table. |
| `domains[]` | no | | Routing names: `user@<domain>` and `<DOMAIN>\user` go to this provider. The comparison is case-insensitive. `DOMAIN\user` and `user@DOMAIN` also match the provider `id`. |
| `hosts[]` | yes | | Host names or IP addresses, passed to the LDAP library as a server list. |
| `port` | no | `636` for `ldaps`, `389` otherwise | Defaults follow the security mode when the key is omitted. |
| `security` | no | `ldaps` / `ldaps` | `ldaps`, `starttls`, `negotiate` or `none`. See [3.2](#32-security-modes). |
| `allowInsecure` | no | `false` | Required for `security: "none"`. Lab only. JSON only, not shown in the UI. |
| `baseDn` | yes | | Search base for users, for example `DC=corp,DC=example,DC=com`. |
| `bindMode` | no | `direct` / `search` | See [3.3](#33-bind-modes). |
| `bindCredential` | for `search` | | Id of a vault entry with **system** scope (service account). See [vault.md](vault.md#4-scope). |
| `upnSuffix` | for AD `direct` | | Builds the bind name `<login>@<upnSuffix>`. |
| `usernamePrefix` | no | AD: the first entry in `domains` without a dot; otherwise `id` upper-cased | Portal usernames become `<usernamePrefix>\<uid>`. |
| `userFilter` | no | AD: `(&(objectCategory=person)(objectClass=user)(sAMAccountName={0}))`<br/>OpenLDAP: `(&(objectClass=inetOrgPerson)(uid={0}))` | Must be wrapped in parentheses and contain `{0}`. `{0}` is replaced by the login name, escaped according to RFC 4515. |
| `groupMode` | no | `nested` / `search` | See [3.4](#34-group-modes). |
| `groupFilter` | no | AD: `(&(objectClass=group)(member={dn}))`<br/>OpenLDAP: `(\|(&(objectClass=groupOfNames)(member={dn}))(&(objectClass=groupOfUniqueNames)(uniqueMember={dn}))(&(objectClass=posixGroup)(memberUid={uid})))` | Used only by `groupMode: "search"`. `{dn}` is the user DN and `{uid}` the user id, both escaped. |
| `groupBaseDn` | no | `baseDn` | Search base for groups. |
| `attributes` | no | AD: `username=sAMAccountName`, `displayName=displayName`, `mail=mail`<br/>OpenLDAP: `username=uid`, `displayName=cn`, `mail=mail` | Attribute names for the portal user id, display name and e-mail. |
| `tls.verify` | no | `true` | Verify the server certificate. Set it to `false` only in a lab. On Linux this setting is process-wide (see [6](#6-tls-trust-on-linux)). |
| `tls.caFile` | no | | Linux: a PEM CA bundle, exported as `LDAPTLS_CACERT`. Ignored on Windows, which uses the Windows certificate store. |
| `tls.caDirectory` | no | | Linux: a directory of trusted CA certificates, applied per connection. JSON only, not shown in the UI. |
| `timeoutSeconds` | no | `10` | LDAP operation timeout. |

When a provider is saved, the portal validates `id`, `flavor`, `hosts`, `security`, `port`, `baseDn`, `bindMode`, `groupMode`, the format of both filters, and that the `bindCredential` vault entry exists. String values cannot contain `<` or `>`. The first provider you save also becomes `auth.defaultProvider` if none is set. Saves are audited as `identity.provider.save`.

### 3.2 Security modes

| `security` | Transport | Platform | Notes |
|---|---|---|---|
| `ldaps` | TLS from the first byte (normally port 636) | Windows, Linux | Recommended. |
| `starttls` | Plain LDAP upgraded with the StartTLS extended operation (normally port 389) | Windows, Linux | On Linux, .NET opens the connection lazily. The portal therefore reads the rootDSE anonymously, unencrypted and without credentials, before it starts TLS. The directory must allow anonymous rootDSE reads. |
| `negotiate` | Kerberos/NTLM bind with LDAP signing and sealing (normally port 389) | **Windows + AD only** | Refused on Linux. The bare login name is sent with `usernamePrefix` as the domain. |
| `none` | Clear text, simple bind | Windows, Linux | Refused unless `allowInsecure: true`. Passwords cross the network in clear text. Lab only. Not offered in the UI. |

Empty passwords are always rejected before the bind, so an unauthenticated (anonymous) bind can never count as a successful sign-in.

### 3.3 Bind modes

| `bindMode` | Sequence | Group lookup runs as | Requirements |
|---|---|---|---|
| `direct` | 1. Bind as the user: `user@domain` exactly as typed, otherwise `<login>@<upnSuffix>`, or the bare login with `negotiate`. 2. Search for the user entry with `userFilter`. | The user | AD. `upnSuffix` is required unless `security` is `negotiate`. No service account. |
| `search` | 1. Bind with the service account from `bindCredential`. 2. Find the user entry with `userFilter`. 3. Bind as the user's DN with the typed password, which proves the password. | The service account | A vault entry with system scope. Works with AD and OpenLDAP. |

If the user filter matches more than one entry, sign-in fails ("More than one directory entry matches ..."). With `direct`, a user who types `user@domain` binds with that UPN, but the entry lookup still uses the part before `@` in `userFilter` (`sAMAccountName` by default). If UPN prefixes differ from `sAMAccountName` in your domain, users must sign in with `DOMAIN\user` or a bare name.

### 3.4 Group modes

| `groupMode` | How groups are found | Notes |
|---|---|---|
| `nested` | `(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=<user DN>))` under `groupBaseDn` (LDAP_MATCHING_RULE_IN_CHAIN) | AD only. Transitive (nested) membership. `groupFilter` is ignored. The primary group (for example *Domain Users*) is not returned. |
| `memberOf` | The `memberOf` values of the user entry. The CN is taken from each DN. | Direct membership only. OpenLDAP needs the `memberof` overlay. |
| `search` | `groupFilter` with `{dn}` and `{uid}` substituted, under `groupBaseDn` | Default for OpenLDAP. Covers `groupOfNames`, `groupOfUniqueNames` and `posixGroup` (`memberUid`). |

Group searches read the `cn` attribute and return at most 1,000 groups. Role and team mapping compare **group CNs** (not DNs) case-insensitively, so two groups with the same CN in different OUs are treated as the same group. Restrict `groupBaseDn` to an OU that only trusted administrators can write to (see [security.md](security.md#authorization)).

## 4. Username routing and portal usernames

`Resolve-PortalLoginTarget` decides where a login name is checked:

| User types | Routed to |
|---|---|
| `LOCAL\name` or `.\name` | Local account `name` |
| `DOMAIN\name` | The enabled provider whose `domains` contains `DOMAIN`, or whose `id` equals `DOMAIN` (both case-insensitive). If none matches, sign-in fails with the generic message. |
| `name@domain` | Same rule, applied to `domain`. With `bindMode: "direct"`, the full `name@domain` is used as the bind name. |
| `name` (bare) | The local account `name` if it exists and is enabled. Otherwise `auth.defaultProvider`, or the first enabled provider if no default is set. Without any provider, the name is checked as a local account. |

Notes:

- An enabled local account shadows a directory user with the same bare name, even when local sign-in is disabled. In that case only a break-glass account can actually sign in with it. Directory users can still use `DOMAIN\name`.
- Portal usernames are `LOCAL\<username>` for local accounts and `<usernamePrefix>\<uid>` for directory users, where `uid` is the value of `attributes.username`. This name identifies the user in requests, approvals, MFA enrolment, sessions and the audit trail. Keep `usernamePrefix` stable once users exist.
- Re-authentication for sensitive actions binds again against the provider the user signed in with (stored in the session), using the bare `uid`; it does not depend on `usernamePrefix` routing.

## 5. Roles and teams

### 5.1 Roles

| Role | Grants |
|---|---|
| `Requester` | Browse the catalog and submit requests |
| `Approver` | Approve or reject requests of their teams. Implies `Requester`. |
| `Admin` | Everything. Implies every other role. |
| `CatalogAdmin` | `catalog.manage`: catalog editor, handlers, branding, teams, VM notes |
| `SecurityAdmin` | `security.manage` and `audit.read`: identity providers, local users, role mapping, security policy, sessions |
| `VaultAdmin` | `vault.manage`: credential vault |

Directory users get roles from `auth.roleMapping`, which maps each role to a list of **group CNs**:

```json
"roleMapping": {
  "Admin":         ["SSP-Admins"],
  "Approver":      ["SSP-Approvers"],
  "Requester":     ["SSP-Requesters"],
  "CatalogAdmin":  ["SSP-CatalogAdmins"],
  "SecurityAdmin": ["SSP-SecurityAdmins"],
  "VaultAdmin":    ["SSP-VaultAdmins"]
}
```

You edit it in **Admin > Customization > Role mapping (directory groups)**. This requires `security.manage` and re-authentication. Group names returned by the directory are compared without any `DOMAIN\` prefix, so list plain CNs in the mapping. Local accounts carry their roles in `local-users.json` and ignore `roleMapping`.

An account that ends up with no role cannot sign in ("Your account is not authorised for this portal (no role assigned)"; audited as `auth.norole`). When `security.adminAllowedCidrs` is set, the administrative roles (`Admin`, `CatalogAdmin`, `SecurityAdmin`, `VaultAdmin`) are removed for clients outside those networks. See [security.md](security.md#admin-networks).

Groups (directory) and roles (local) are captured at sign-in and kept in the session. Changing a user's group membership or local roles takes effect at the next sign-in. A change to `roleMapping` itself applies on the next request. To apply a change immediately, end the user's sessions in **Admin > Security**.

### 5.2 Teams

Teams scope catalog items (`access.teams`) and approvals. Directory users join a team through `teams[].adGroups`, which uses the same CN matching as roles. Local accounts list their teams explicitly.

```json
"teams": [
  { "id": "Infrastructure", "name": "Infrastructure Operations", "adGroups": ["SSP-Team-Infrastructure"] },
  { "id": "Cloud", "name": "Cloud Operations",          "adGroups": ["SSP-Team-Cloud"] }
]
```

`Admin` sees every team. For the item side of team scoping, see [catalog-authoring.md](catalog-authoring.md).

## 6. TLS trust on Linux

### 6.1 CA file and directory

| Setting | Effect |
|---|---|
| `tls.caFile` | Exported to the process as `LDAPTLS_CACERT` the first time an LDAP connection is opened, unless the variable is already set |
| `tls.caDirectory` | Set per connection (`TrustedCertificatesDirectory`) and a new TLS context is started |
| `tls.verify: false` | Exported as `LDAPTLS_REQCERT=never` unless the variable is already set. **Lab only.** |

You can also set `LDAPTLS_CACERT` in the service environment (`/etc/ssp/portal.env`, see [installation-linux.md](installation-linux.md#6-file-locations)). Alternatively, add the directory CA to the operating system trust store.

### 6.2 Process-wide caveat

`libldap` reads `LDAPTLS_*` once per process. As a result:

- Only **one** CA bundle and **one** verification policy apply to every provider in the portal process. The first provider that sets them wins.
- `tls.verify: false` on any provider disables certificate verification for **all** LDAP connections in the process.
- Changing `caFile` or `verify` takes effect only after a service restart.

If providers are signed by different CAs, put all the CA certificates into one PEM bundle.

On Windows, trust comes from the Windows certificate store, and `tls.verify: false` affects only the provider that sets it.

### 6.3 StartTLS on Linux

StartTLS requires an anonymous, unencrypted read of the rootDSE before TLS starts ([3.2](#32-security-modes)). If the directory refuses anonymous reads, use LDAPS.

### 6.4 libldap compatibility link

PowerShell 7.4 runs on .NET 8, whose `System.DirectoryServices.Protocols` loads `libldap-2.5.so.0`. AlmaLinux/RHEL 9 and Ubuntu 24.04 ship OpenLDAP 2.6 (`libldap.so.2`). `packaging/linux/install.sh` creates the compatibility link `libldap-2.5.so.0 -> libldap.so.2`. When at least one provider is enabled, the portal warns at start-up if `libldap-2.5.so.0` cannot be loaded. See [installation-linux.md](installation-linux.md#13-troubleshooting).

## 7. Admin > Identity

The tab requires `security.manage`.

| Element | Function | API |
|---|---|---|
| Sign-in providers table | Lists the providers, with Edit, **Test** and Delete. Saving or deleting asks for your password. | `GET/POST /api/admin/identity`, `DELETE /api/admin/identity/:id` |
| **Test** | With a `bindCredential`, it binds with the service account and checks that the base DN is readable. Without one, it binds anonymously and reads the rootDSE. The API also accepts `lookupUser` to search for a user and list their groups. The UI does not send it. | `POST /api/admin/identity/:id/test` |
| Default provider | `auth.defaultProvider`: where bare names go | `POST /api/admin/identity/options` |
| Local accounts enabled | `auth.localUsers.enabled` | `POST /api/admin/identity/options` |
| **Sign-in simulation** | Checks a username and password against the routed provider and shows the groups, roles and teams the account would get, and whether MFA would be required. No session is created and lockout is not applied. Audited as `identity.simulate`. | `POST /api/admin/identity/simulate` |

The provider editor exposes the common fields. `allowInsecure`, `tls.caDirectory`, `attributes` and `timeoutSeconds` are JSON only. **Note:** saving a provider from the editor rewrites `tls` as `{ verify, caFile }`, which drops a `tls.caDirectory` set in JSON. The editor also does not send `allowInsecure`.

## 8. Step-by-step examples

### (a) Active Directory, direct bind over LDAPS

No service account. Users bind with their own UPN.

1. Make sure the domain controllers present LDAPS certificates whose names match `hosts`. On Linux, copy the issuing CA chain to the server (for example `/etc/ssp/ca/corp-ca.pem`, readable by the `ssp` account).
2. Create the groups `SSP-Admins`, `SSP-Approvers`, `SSP-Requesters` (and the optional `SSP-CatalogAdmins`, `SSP-SecurityAdmins`, `SSP-VaultAdmins`, `SSP-Team-*`).
3. In **Admin > Identity > + Add directory**, or in `auth.providers[]`:

   ```json
   {
     "id": "corp",
     "name": "Corporate AD",
     "enabled": true,
     "flavor": "ad",
     "domains": ["corp.example.com", "CORP"],
     "hosts": ["dc01.corp.example.com", "dc02.corp.example.com"],
     "port": 636,
     "security": "ldaps",
     "baseDn": "DC=corp,DC=example,DC=com",
     "bindMode": "direct",
     "upnSuffix": "corp.example.com",
     "usernamePrefix": "CORP",
     "groupMode": "nested",
     "groupBaseDn": "OU=Portal,OU=Groups,DC=corp,DC=example,DC=com",
     "tls": { "verify": true, "caFile": "/etc/ssp/ca/corp-ca.pem" },
     "timeoutSeconds": 10
   }
   ```

4. Set **Default provider** to `corp` so that `jdoe` works as well as `CORP\jdoe` and `jdoe@corp.example.com`.
5. Map the groups in **Admin > Customization > Role mapping (directory groups)**.
6. Run **Test** (with no service account, this verifies TLS and the rootDSE read), then **Sign-in simulation** with a real account.
7. Sign in. Directory admins are asked to enrol an authenticator ([security.md](security.md#multi-factor-authentication-totp)).

### (b) Active Directory, search bind with a service account

Use this mode when users sign in with names that are not `<sAMAccountName>@<upnSuffix>`, or when group lookups must not depend on user permissions.

1. Create a least-privilege, read-only AD account, for example `svc-ssp-ldap`. Disable interactive logon and exclude it from privileged groups.
2. In **Admin > Vault**, store it as `UsernamePassword` with **Platform use** checked (`scope.system = true`). The username can be a UPN or a DN:

   ```json
   { "id": "ad-bind", "type": "UsernamePassword", "username": "svc-ssp-ldap@corp.example.com",
     "scope": { "system": true, "teams": [], "items": [] } }
   ```

3. Configure the provider:

   ```json
   {
     "id": "corp",
     "name": "Corporate AD",
     "enabled": true,
     "flavor": "ad",
     "domains": ["corp.example.com", "CORP"],
     "hosts": ["dc01.corp.example.com", "dc02.corp.example.com"],
     "port": 636,
     "security": "ldaps",
     "baseDn": "OU=Users,DC=corp,DC=example,DC=com",
     "bindMode": "search",
     "bindCredential": "ad-bind",
     "usernamePrefix": "CORP",
     "groupMode": "nested",
     "groupBaseDn": "OU=Portal,OU=Groups,DC=corp,DC=example,DC=com",
     "tls": { "verify": true }
   }
   ```

4. **Test** now binds with `ad-bind` and reads the base DN. Every use of the bind credential is audited as `vault.use` with purpose `identity`.

### (c) OpenLDAP with posixGroup / groupOfNames

1. Create a read-only bind DN, for example `uid=svc-portal,ou=services,dc=example,dc=org`, with ACL read access to `ou=people` and `ou=groups`.
2. Store it in the vault as `ldap-bind` (system scope, username = the full DN).
3. Configure the provider. The flavor defaults already cover `inetOrgPerson`, `groupOfNames`, `groupOfUniqueNames` and `posixGroup`:

   ```json
   {
     "id": "lab",
     "name": "Lab OpenLDAP",
     "enabled": true,
     "flavor": "openldap",
     "domains": ["example.org", "LAB"],
     "hosts": ["ldap1.example.org", "ldap2.example.org"],
     "port": 636,
     "security": "ldaps",
     "baseDn": "ou=people,dc=example,dc=org",
     "bindMode": "search",
     "bindCredential": "ldap-bind",
     "usernamePrefix": "LAB",
     "groupMode": "search",
     "groupBaseDn": "ou=groups,dc=example,dc=org",
     "tls": { "verify": true, "caFile": "/etc/ssp/ca/ldap-ca.pem" }
   }
   ```

   For a `memberOf` overlay, use `"groupMode": "memberOf"`. For a directory without `inetOrgPerson`, override `userFilter` (for example `(&(objectClass=posixAccount)(uid={0}))`) and `attributes`.
4. Use the group `cn` values (for example `SSP-Admins`, `SSP-Team-Cloud`) in `roleMapping` and `teams[].adGroups`.
5. Users sign in as `bob`, `LAB\bob` or `bob@example.org`. Their portal username is `LAB\bob`.

## 9. Migration from the Windows AD form login

Earlier releases authenticated against AD with `auth.provider = "WindowsAD"`, `auth.fqdn`, `auth.domain` and `auth.directGroupsOnly`. At the first start of this release, `Initialize-PortalConfiguration` converts these keys if `auth.providers` does not exist yet:

| Legacy | New |
|---|---|
| `auth.fqdn` | Provider `ad`: `domains = [fqdn, NETBIOS]`, `hosts = [fqdn]`, `baseDn = DC=...` derived from the FQDN, `upnSuffix = fqdn`, `bindMode = direct` |
| `auth.domain` | `usernamePrefix` (default: the first label of the FQDN, upper-cased) |
| `auth.directGroupsOnly` | `groupMode = memberOf` when true, otherwise `nested` |
| (platform) | Windows: `security = negotiate`, `port = 389` (same behaviour as before). Linux: `security = ldaps`, `port = 636`. |
| (none) | `auth.defaultProvider = "ad"`. `tls.verify = true`. |
| `portal.sessionDurationMinutes` | `security.session.absoluteTimeoutMinutes` (only when `security` did not exist) |

The legacy keys are removed and the role mapping gains empty `CatalogAdmin`, `SecurityAdmin` and `VaultAdmin` entries. The change is audited as `config.upgrade`, and a timestamped copy of the previous configuration is kept in `config/_backup/`.

After the upgrade:

1. **Linux:** `hosts = [fqdn]` relies on DNS returning domain controllers whose LDAPS certificate is valid for the domain name. If it is not, list the DCs by name. Set up CA trust ([6](#6-tls-trust-on-linux)).
2. Review the provider in **Admin > Identity** and run **Test** and **Sign-in simulation**.
3. The `security` section is added with its defaults, so `Admin`, `SecurityAdmin` and `VaultAdmin` users must enrol an authenticator at their next sign-in.
4. Disable local accounts except break-glass ([2.2](#22-enabling-and-disabling-local-sign-in)).

## 10. Troubleshooting

The portal translates LDAP errors with `Get-PortalLdapErrorMessage`. AD sub-codes are read from the server error message (`data <code>`).

| Condition | Code | Message shown at sign-in | Counts toward lockout |
|---|---|---|---|
| AD `data 52e` (bad password), `data 525` (no such user), or any LDAP result 49 | `invalid` | "Invalid username or password." | yes |
| AD `data 775` | `locked` | "The directory account is locked." | yes |
| AD `data 532` | `expired` | "The directory password has expired. Change it in your directory first." | yes |
| AD `data 773` | `mustchange` | "The directory requires a password change before first use." | yes |
| AD `data 533` | `disabled` | "The directory account is disabled." | yes |
| AD `data 701` | `expired` | "The directory account has expired." | yes |
| LDAP 81 (server down) or 91 (connect error) | `unavailable` | "Directory server not reachable (...)." | **no** |
| `libldap` cannot be loaded | `unavailable` | "The OpenLDAP client library (libldap) is not installed on the portal server." | **no** |
| Any other LDAP error, misconfiguration, or user filter with more than one match | `error` | "Invalid username or password." (details go to the portal log as `WARN`) | yes |

| Symptom | Cause / fix |
|---|---|
| Every directory sign-in fails with "Directory server not reachable" on Linux | Usually a TLS failure: missing CA trust (`tls.caFile` / `LDAPTLS_CACERT`) or a host name that does not match the certificate. Test with `ldapsearch -H ldaps://dc01... -x -b "" -s base`. A firewall blocking 636/389 has the same symptom. |
| `Unable to load shared library 'libldap-2.5.so.0'` | Install `openldap` / `libldap2` and create the compatibility link ([6.4](#64-libldap-compatibility-link)). |
| LDAPS works, StartTLS fails | The directory refuses anonymous rootDSE reads ([6.3](#63-starttls-on-linux)). Use LDAPS. |
| "security 'negotiate' is only available on Windows" | Migrated configuration moved to Linux. Switch to `ldaps` / 636. |
| "bindMode=direct needs upnSuffix" in the portal log | Set `upnSuffix`, or use `bindMode: "search"`. |
| "Vault entry '...' is not allowed for identity" | The bind credential does not have system scope. Check **Platform use** in Admin > Vault. |
| "Vault entry '...' not found" when saving the provider | Create the vault entry first. |
| "More than one directory entry matches" in the log | `userFilter` is too broad, for example because of contacts or duplicate `uid` values. Restrict it or narrow `baseDn`. |
| User authenticates but gets "not authorised (no role assigned)" | No group CN matches `roleMapping`, or admin roles were removed by `adminAllowedCidrs`. Use **Sign-in simulation** to see the groups. |
| `user@domain` fails but `DOMAIN\user` works | The UPN prefix differs from `sAMAccountName` ([3.3](#33-bind-modes)), or `domain` is not listed in `domains`. |
| Nested group not granting a role | `groupMode` is `memberOf` (direct only), or the group is outside `groupBaseDn`. |
| Directory user cannot confirm sensitive actions ("The password or code is not correct.") | `usernamePrefix` is neither in `domains` nor equal to the provider `id` ([4](#4-username-routing-and-portal-usernames)). |
| Changed `caFile` / `verify` has no effect | `libldap` settings are process-wide. Restart the service ([6.2](#62-process-wide-caveat)). |
