# REST API reference

This reference covers every HTTP route that `Start-Portal.ps1` registers. The API exists to serve the bundled single-page UI (`web/assets/app.js`, `admin.js`). It uses cookie sessions, an anti-forgery header and interactive re-authentication. **Machine-to-machine access (API tokens, service accounts, OAuth) is not supported yet.** Do not script against it with stored user passwords.

See [security.md](security.md) for the session, MFA and re-authentication model.

## Contents

1. [Conventions](#1-conventions)
2. [Errors](#2-errors)
3. [Endpoint index](#3-endpoint-index)
4. [Pages and sign-in](#4-pages-and-sign-in)
5. [Session and account](#5-session-and-account)
6. [Catalog](#6-catalog)
7. [Requests](#7-requests)
8. [Administration](#8-administration)
   - [Catalog editor and handlers](#catalog-editor-and-handlers)
   - [vCenter connections and inventory](#vcenter-connections-and-inventory)
   - [Cloud connections](#cloud-connections)
   - [Customization](#customization)
   - [Local users](#local-users)
   - [Identity providers](#identity-providers)
   - [Security](#security)
   - [Vault](#vault)
   - [Audit](#audit)

---

## 1. Conventions

| Topic | Rule |
|---|---|
| Base URL | `https://<portal>[:port]`. All API paths start with `/api/`. |
| Format | JSON request and response bodies (`Content-Type: application/json`). Responses to `/api/*` carry `Cache-Control: no-store`. |
| Authentication | Pode session cookie (HttpOnly), obtained through the [two-step sign-in](#4-pages-and-sign-in). Routes marked *public* need no session. |
| Anti-forgery | Every non-GET request to `/api/*` must send `X-Portal-Request: 1`, otherwise it gets `403 {"error":"Missing anti-forgery header."}`. This includes `POST /api/auth/login`. |
| Background polls | Send `X-Portal-Background: 1` on automatic refreshes. Such calls do not count as user activity for the idle timeout. |
| Session gate | Every authenticated `/api/*` route except `POST /api/session/logout` checks the server-side session (idle and absolute timeout, revocation), forced password change and forced MFA enrolment. *Restricted-OK* routes stay available while a password change or MFA enrolment is pending. |
| Re-authentication | Routes marked *re-auth* require a password confirmation within `security.session.reauthWindowMinutes`. Otherwise they return `401 REAUTH_REQUIRED`: call [`POST /api/session/reauth`](#post-apisessionreauth) and retry. |
| Authorization | *signed-in* = any portal role. Otherwise a role or a permission is named (see [security.md](security.md#authorization)). Admin routes outside `security.adminAllowedCidrs` answer 403. |
| Unauthenticated access | A request without a valid Pode session to a route that requires one is redirected by Pode (`302`) to `/login?error=1`. The UI treats a redirect to `/login`, or a non-JSON 401, as "session expired". |
| Ids | Request ids: `REQ-yyyyMMdd-XXXXXX`. Catalog ids: `^[a-z0-9][a-z0-9-]{2,62}$`. Vault ids: `^[a-z0-9][a-z0-9._-]{1,62}$`. Provider ids: `^[a-z][a-z0-9-]{1,31}$`. |

Example call from a signed-in browser context:

```http
POST /api/requests HTTP/1.1
Content-Type: application/json
X-Portal-Request: 1
Cookie: <pode session cookie>

{"itemId":"vm-snapshot","inputs":{"Site":"DC1","VMName":"app01","SnapshotName":"pre-change"}}
```

## 2. Errors

Errors from authenticated API routes use this body:

```json
{ "error": "Human-readable message", "fields": { } }
```

| Status | `fields` | Meaning |
|---|---|---|
| `401` | `{ "code": "SESSION_EXPIRED" }` | No session record, ended session, or absolute timeout reached ("Your session has expired. Please sign in again."). Also returned when no authenticated user is present. |
| `401` | `{ "code": "SESSION_IDLE" }` | Idle timeout ("Signed out after N minutes of inactivity.") |
| `401` | `{ "code": "SESSION_REVOKED" }` | Ended by an administrator |
| `401` | `{ "code": "REAUTH_REQUIRED" }` | Sensitive action: "Confirm your password to continue." |
| `403` | `{ "code": "PASSWORD_CHANGE_REQUIRED" }` | Local password must be changed first |
| `403` | `{ "code": "MFA_ENROLLMENT_REQUIRED" }` | The role requires MFA. Enrol first. |
| `403` | none | "Insufficient permissions." (with " Administrative roles are only available from the management network." when admin networks removed the role), "Insufficient permissions for '<section>'.", "Your account is not mapped to any portal role.", or the anti-forgery error |
| `404` | none | Item or request not found or not visible to the caller |
| `409` | none | Workflow or state conflict (approve, reject, cancel), option lookup failure, directory password change attempted |
| `422` | optional | Validation error. `POST /api/requests` returns `fields: { "<InputName>": "<message>" }`. `POST /api/admin/catalog` returns `fields: { "errors": ["..."] }`. Other routes return only `error`. |
| `500` | none | "Unexpected server error (ref xxxxxxxx)." The same reference is written, with the stack trace, to the portal log. |

`POST /api/auth/login` uses its own body format ([4](#post-apiauthlogin)).

## 3. Endpoint index

Legend: **P** = public, **S** = signed-in (any role), **S\*** = signed-in and *restricted-OK*, **R** = re-auth always, **(R)** = re-auth under a condition.

| Method | Path | Access | Re-auth |
|---|---|---|---|
| GET | `/login` | P | |
| POST | `/login` | P (ticket) | |
| POST | `/logout` | session | |
| GET | `/` | session | |
| GET | `/assets/*` | P | |
| GET | `/api/branding` | P | |
| GET | `/brand/logo` | P | |
| POST | `/api/auth/login` | P | |
| GET | `/api/session` | S\* | |
| POST | `/api/session/keepalive` | S\* | |
| POST | `/api/session/logout` | session | |
| POST | `/api/session/reauth` | S\* | |
| GET | `/api/me` | S\* | |
| POST | `/api/me/password` | S\* (local accounts) | |
| POST | `/api/me/mfa/begin` | S\* | (R) when already enrolled |
| POST | `/api/me/mfa/confirm` | S\* | |
| GET | `/api/catalog` | S | |
| GET | `/api/catalog/:id` | S | |
| POST | `/api/catalog/:id/options/:input` | S | (R) input `requireReauth` |
| POST | `/api/requests` | S | (R) item `security.requireReauth` |
| GET | `/api/requests?scope=mine\|all\|approvals` | S (`all`: Approver/Admin) | |
| GET | `/api/requests/:id` | S (visibility rules) | |
| GET | `/api/requests/:id/log` | S (visibility rules) | |
| POST | `/api/requests/:id/approve` | S (approver rules) | (R) request snapshot `requireReauth` |
| POST | `/api/requests/:id/reject` | S (approver rules) | |
| POST | `/api/requests/:id/cancel` | S (requester or Admin) | |
| GET | `/api/admin/catalog` | `catalog.manage` | |
| GET | `/api/admin/catalog/:id` | `catalog.manage` | |
| POST | `/api/admin/catalog` | `catalog.manage` | |
| DELETE | `/api/admin/catalog/:id` | `catalog.manage` | |
| GET | `/api/admin/handlers` | `catalog.manage` | |
| POST | `/api/admin/handlers/inspect` | `catalog.manage` | |
| POST | `/api/admin/handlers/stub` | `catalog.manage` | |
| GET | `/api/admin/inventory` | `connections.manage` | |
| POST | `/api/admin/inventory/refresh` | `connections.manage` | |
| GET | `/api/admin/sites` | `connections.manage` | |
| POST | `/api/admin/sites` | `connections.manage` | |
| POST | `/api/admin/sites/:code/test` | `connections.manage` | |
| GET | `/api/admin/clouds` | `connections.manage` | |
| POST | `/api/admin/clouds` | `connections.manage` | |
| POST | `/api/admin/clouds/:provider/test` | `connections.manage` | |
| GET | `/api/admin/settings` | `catalog.manage` or `security.manage` | |
| POST | `/api/admin/settings` | per section | (R) `roleMapping` / `policies` |
| POST | `/api/admin/settings/logo` | `catalog.manage` | |
| GET | `/api/admin/users` | `security.manage` | |
| POST | `/api/admin/users` | `security.manage` | R |
| DELETE | `/api/admin/users/:username` | `security.manage` | R |
| GET | `/api/admin/identity` | `security.manage` | |
| POST | `/api/admin/identity` | `security.manage` | R |
| DELETE | `/api/admin/identity/:id` | `security.manage` | R |
| POST | `/api/admin/identity/:id/test` | `security.manage` | |
| POST | `/api/admin/identity/simulate` | `security.manage` | |
| POST | `/api/admin/identity/options` | `security.manage` | R |
| GET | `/api/admin/security` | `security.manage` | |
| POST | `/api/admin/security/policy` | `security.manage` | R |
| POST | `/api/admin/security/sessions/revoke` | `security.manage` | |
| POST | `/api/admin/security/lockouts/clear` | `security.manage` | |
| POST | `/api/admin/security/mfa/reset` | `security.manage` | R |
| GET | `/api/admin/vault` | `vault.manage` | |
| POST | `/api/admin/vault` | `vault.manage` | R |
| DELETE | `/api/admin/vault/:id` | `vault.manage` | R |
| GET | `/api/admin/audit` | `audit.read` | |

## 4. Pages and sign-in

### `GET /login`, `GET /`, `GET /assets/*`

`/login` serves `web/login.html` (already signed-in users are redirected to `/`). `/` serves `web/index.html` and requires a session. `/assets/*` are the static files.

### `GET /api/branding`

Public. Returns `{productName, organization, tagline, primaryColor, accentColor, loginMessage, footerText, supportContact, logoUrl}`.

### `GET /brand/logo`

Public. Returns the uploaded logo (`Cache-Control: public, max-age=86400`), or `404` if there is none.

### `POST /api/auth/login`

Public, step 1 of sign-in. Requires `X-Portal-Request: 1`.

Request: `{ "username": "CORP\\jdoe", "password": "...", "otp": "123456" }`. `otp` is optional: a TOTP code or a recovery code (`xxxx-xxxx`).

| Status | Body |
|---|---|
| `200` | `{ "ok": true, "ticket": "<opaque>" }`: single use, valid for 60 s, bound to the client IP |
| `200` | `{ "ok": false, "next": "mfa", "message": "..." }`: send the same request again with `otp` |
| `401` | `{ "ok": false, "message": "..." }`: generic failure, lockout, directory account state, or no role ([security.md](security.md#generic-error-messages)) |
| `500` | `{ "ok": false, "message": "Sign-in is temporarily unavailable. Contact your administrator." }` |

### `POST /login`

Step 2 (Pode form authentication), sent as `application/x-www-form-urlencoded` with `username=<anything>&password=<ticket>`. A valid ticket creates the session cookie and redirects `302` to `/`. Otherwise Pode redirects to `/login?error=1`.

### `POST /logout`

Ends the Pode session and redirects to `/login?error=1`. The UI calls [`POST /api/session/logout`](#post-apisessionlogout) first, so that the server-side record is closed too.

## 5. Session and account

### `GET /api/session`, `POST /api/session/keepalive`

S\*. Both return the session timers. `keepalive` counts as activity unless it is sent with `X-Portal-Background: 1`.

```json
{ "idleTimeoutMinutes": 30, "warningSeconds": 120, "lastActivity": "2026-10-05T09:12:03.1Z",
  "expiresAt": "2026-10-05T17:01:00.0Z", "mustChangePassword": false, "mfaEnrollRequired": false,
  "reauthValidUntil": "2026-10-05T09:06:00.0Z" }
```

### `POST /api/session/logout`

Requires a Pode session but skips the session gate. Marks the server-side session as ended (audited as `session.logout`). Returns `{ "ok": true }`.

### `POST /api/session/reauth`

S\*. Request: `{ "password": "...", "otp": "123456" }`.

| Status | Body |
|---|---|
| `200` | `{ "ok": true }`: the re-authentication window is open again |
| `200` | `{ "ok": false, "next": "mfa" }`: the user has MFA enrolled. Send the request again with `otp`. |
| `422` | `{ "error": "The password or code is not correct." }`, or a lockout message. Failures count toward lockout. |

### `GET /api/me`

S\*. Returns the current user and the UI context:

```json
{
  "user": { "username": "CORP\\jdoe", "name": "Jane Doe", "email": "jdoe@corp.example.com",
            "roles": ["Approver", "Requester"], "assignedRoles": ["Approver"], "teams": ["Infrastructure"],
            "provider": "corp", "local": false, "sid": "...", "networkRestricted": false },
  "permissions": [],
  "mfa": { "enrolled": true, "enrolledAt": "...", "recoveryLeft": 9 },
  "session": { "...": "as GET /api/session" },
  "portal": { "name": "...", "organization": "..." },
  "sites": [{ "code": "DC1", "name": "Primary Datacenter" }],
  "teams": [{ "id": "Infrastructure", "name": "Infrastructure Operations" }]
}
```

### `POST /api/me/password`

S\*, local accounts only. Request: `{ "currentPassword": "...", "newPassword": "..." }`. Returns `{ "changed": true }` and clears the forced-change flag. Errors: `409` for directory users ("Directory passwords are changed in your directory (AD / LDAP), not in the portal."), `422` for a wrong current password, an unchanged password or a policy violation ("Password policy: ...").

### `POST /api/me/mfa/begin`

S\*. No body. Returns `{ "secret": "<base32>", "uri": "otpauth://totp/...?secret=...&issuer=...&algorithm=SHA1&digits=6&period=30" }`. The pending secret expires after 15 minutes. Requires re-auth when an authenticator is already enrolled.

### `POST /api/me/mfa/confirm`

S\*. Request: `{ "code": "123456" }`. Returns `{ "enrolled": true, "recoveryCodes": ["abcd-efgh", "..."] }` (10 codes, shown once). `422` if the code is wrong or the enrolment expired.

## 6. Catalog

### `GET /api/catalog`

S. Returns `{ "items": [<public item>] }`: the items that are enabled and visible to the caller (roles and teams).

Public item: `{id, version, name, category, icon, summary, description, owner, tags[], estimatedDuration, approvalRequired, teams[], inputs[]}`. Handler and execution details are never included.

### `GET /api/catalog/:id`

S. Returns one public item, or `404`.

### `POST /api/catalog/:id/options/:input`

S. Resolves the options of a `select` or `credential` input. Request: `{ "values": { "Site": "DC1", "Cluster": "CL-APP-01" } }` (the current form values, used by `dependsOn`).

Returns `{ "options": [{ "value": "...", "label": "..." }] }`. For `credential` inputs the values are vault ids, and the labels are `name (username)`. Errors: `404` (item not visible), `409` (for example, "Inventory for site DC1 is not available yet..."). Requires re-auth if the input has `requireReauth: true`.

## 7. Requests

### `POST /api/requests`

S. Request: `{ "itemId": "vm-snapshot", "inputs": { "<InputName>": <value> } }`.

Returns `{ "id": "REQ-20261005-1A2B3C", "status": "PendingApproval" | "Queued" }`.

Errors: `404` (item not visible), `422` (`"Please correct the highlighted fields."` with `fields` keyed by input name). Requires re-auth if the item has `security.requireReauth: true`. Every value is re-validated on the server.

### `GET /api/requests?scope=`

S. `scope=mine` (default): the caller's requests. `scope=all`: every request of the caller's teams, for `Approver` / `Admin` only (otherwise `403`). `scope=approvals`: pending requests the caller can approve now.

Returns `{ "requests": [{id, itemId, itemName, category, status, site, target, requester{username,name,email}, createdAt, updatedAt, approvalRequired}] }`, newest first, up to 500.

### `GET /api/requests/:id`

S. Requesters see their own requests. Approvers and Admins also see their teams' requests. Otherwise `404`.

Returns the request document (`id, itemId, itemName, itemVersion, category, status, site, target, requester, teams, createdAt, updatedAt, inputs, approval{required, approverRoles, decision, decidedBy, decidedAt, comment}, job{pid, host, queuedAt, dispatchedAt, startedAt, finishedAt}, result, error, history[{ts, status, actor, note}]`). It adds `execution: {timeoutMinutes}` (the rest of the execution snapshot is withheld) and the flags `canApprove`, `requiresReauth` and `canCancel`. `inputs` contains vault **ids** for credential inputs, never secrets.

Statuses: `PendingApproval`, `Queued`, `Dispatched`, `Running`, `Succeeded`, `Failed`, `Rejected`, `Cancelled`.

### `GET /api/requests/:id/log`

S (same visibility). Returns `{ "status": "Running", "log": "<last 2000 lines of logs/jobs/<id>.log>" }`.

### `POST /api/requests/:id/approve` · `/reject` · `/cancel`

S. Request: `{ "comment": "..." }`. A comment is optional for `approve` and **required** for `reject` (`422` without one). `cancel` takes no body.

Returns `{ "id": "...", "status": "Queued" | "Rejected" | "Cancelled" }`.

- `approve` / `reject`: the caller must pass the approver rules: one of `approval.approverRoles`, a shared team, not the requester (unless self-approval is allowed), and [separation of duties](security.md#separation-of-duties). `approve` requires re-auth when the request snapshot has `requireReauth`.
- `cancel`: the requester or an Admin, while the request is `PendingApproval` or `Queued`.
- Not allowed, not found or wrong state: `409` with the reason.

### `GET /api/requests/:id/reports/:file`

S (same visibility). Serves an HTML or CSV report produced by the job (`data/reports/<id>/`). File names must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,150}\.(html|csv)$`. HTML is served with `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` and `nosniff`; CSV as an attachment. `GET /api/requests/:id` lists the files in `reports: [{name, type, sizeKB}]`.

### `GET /api/storage/scan?itemId=&site=&cluster=`

S, for an item the caller can access that has a `storageDevices` input. Returns `{ state, running, scannedAt, lastRescanAt, lastRescanBy, cooldownSeconds, cooldownMinutes, lockedBy, devices, error }`.

### `POST /api/storage/rescan`

S + **re-auth**. Request: `{ "itemId": "datastore-create", "site": "DC1", "cluster": "CL-APP-01" }`. Starts an out-of-process HBA + VMFS rescan of every connected host of the cluster and refreshes the device list. Returns the scan state. `409` while a scan or a storage job runs on that cluster; `429` during the cool-down (`operations.storage.rescanCooldownMinutes`). Audited as `storage.rescan` with the client IP.

## 8. Administration

### Data files

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/datafiles` | | `catalog.manage`. `{ files: [{name, title, file, updated, content}] }` for `software`, `versionBaseline`, `hardeningBaseline`, `backup`. |
| `POST /api/admin/datafiles/:name` | `{ json: "<file content>", validateOnly?: true }` | `catalog.manage`. `validateOnly`: `{ valid, errors[] }`. Save (re-auth): `{ saved, file }`; invalid: `422` with `fields.errors`. The previous version is kept in `config/_backup/`. |

### Catalog editor and handlers

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/catalog` | | `{ items: [{id, name, version, category, enabled, file, updated, handler, approval, roles[]}], errors: [{file, id, errors[]}] }`. `errors` lists the item files that failed validation. |
| `GET /api/admin/catalog/:id` | | `{ item: <raw definition>, file }` (including disabled or invalid items). `404` if not found. |
| `POST /api/admin/catalog` | `{ item: {...}, mode: "create" \| "update" \| "validate" }` | `{ saved, errors: [], file }`. Invalid: `422` with `fields.errors`. `validate` saves nothing. An update archives the previous file in `catalog/_archive/`. |
| `DELETE /api/admin/catalog/:id` | | `{ deleted }`. The file is moved to `catalog/_archive/<id>.deleted.<timestamp>.json`. `422` if not found. |
| `GET /api/admin/handlers` | | `{ handlers: [{handler, path, updated}], roots: [...] }`. Files starting with `_` are excluded. |
| `POST /api/admin/handlers/inspect` | `{ handler }` | `{ path, parameters: [{name, type, mandatory, validateSet[], default}] }`. The script is parsed, not executed. `422` if it is outside the allowed roots, missing, or has syntax errors. |
| `POST /api/admin/handlers/stub` | `{ handler, parameters: [], requiresVCenter }` | `{ created: <path> }`: a skeleton script. `422` if it exists or is outside the allowed roots. |

### vCenter connections and inventory

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/sites` | | `{ sites: [{code, name, enabled, vcenter, invalidCertificateAction, credential{type, configured, username, vaultId, updatedAt, vault, secret}, workloadClusters, vmFolder, dnsDomain, dnsServers, lastTest}] }`. `credential.secret` is the *name* of a SecretManagement secret, not a value. |
| `POST /api/admin/sites` | `{ code, new?, name?, vcenter?, enabled?, invalidCertificateAction?, workloadClusters?{App,DB}, vmFolder?, dnsDomain?, dnsServers?[], username?, password? }` | `{ saved: true, sites }`. With `username` and `password`, the credential is stored in the vault as `vcenter-<code>` (system scope). `422` on validation errors. |
| `POST /api/admin/sites/:code/test` | | Result of `automation/Test-VCenterConnection.ps1` (`{ok, testedAt, durationMs, ...}` or `{ok:false, error}`). On success, an inventory refresh of the site starts. |
| `GET /api/admin/inventory` | | `{ sites: [{site, vcenter, enabled, collectedAt, ageMinutes, stale, running, lastState, lastError, counts{clusters, datastores, portgroups, templates, folders, vms}}] }` |
| `POST /api/admin/inventory/refresh` | `{ site? }` | `{ started: ["DC1", ...] }`. Sites that are already refreshing are skipped. |

### Cloud connections

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/clouds` | | `{ clouds: [<settings without credentialPath>, provider, secretConfigured, lastTest] }` |
| `POST /api/admin/clouds` | `{ provider: "aws" \| "azure", settings: {...}, secret? }` | `{ saved: true, clouds }`. `secret` is stored in the vault as `cloud-<provider>` (system scope). `422` on validation errors. |
| `POST /api/admin/clouds/:provider/test` | | Result of `automation/Test-CloudConnection.ps1` |

### Customization

| Route | Access | Body | Response |
|---|---|---|---|
| `GET /api/admin/settings` | `catalog.manage` or `security.manage` | | `{ branding, teams, roleMapping, roles, vmNotes, policies{allowSelfApproval, localUsersEnabled}, teamUsage }` |
| `POST /api/admin/settings` | per section: `roleMapping`, `policies` → `security.manage` + re-auth. `branding`, `teams`, `vmNotes` → `catalog.manage`. | Any subset of `{ branding, teams, roleMapping, vmNotes, policies }` | The updated settings view. `403 "Insufficient permissions for '<section>'."`, `422` on validation errors (for example, a team still used by items). |
| `POST /api/admin/settings/logo` | `catalog.manage` | `{ dataUrl: "data:image/png;base64,..." }` (empty = remove) | Branding (as `GET /api/branding`). PNG, JPEG or WebP, 512 KB maximum. |

### Local users

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/users` | | `{ users: [{username, displayName, email, roles, teams, enabled, mustChangePassword, breakGlass, passwordChangedAt, createdAt, updatedAt, mfaEnrolled}], me, roles }`. Never includes hashes. |
| `POST /api/admin/users` (re-auth) | `{ username, new?, displayName?, email?, roles?[], teams?[], enabled?, password?, mustChangePassword?, breakGlass? }` | `{ saved: true, users }`. A password set here forces a change at the next sign-in unless `mustChangePassword: false`. `422`: policy, unknown role or team, self-lockout. |
| `DELETE /api/admin/users/:username` (re-auth) | | `{ deleted, users }`. Also ends the user's sessions. `422` when deleting yourself or an unknown user. |

### Identity providers

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/identity` | | `{ providers: [<as configured>], defaultProvider, localUsersEnabled, bindCredentials: [{id, name, username}], platform: "windows" \| "linux" }`. `bindCredentials` lists the vault entries with system scope. |
| `POST /api/admin/identity` (re-auth) | `{ provider: {...}, mode: "create" \| "update" }` | `{ saved: true }`. `422` on validation errors ([identity.md](identity.md#31-provider-fields)). |
| `DELETE /api/admin/identity/:id` (re-auth) | | `{ deleted }`. If it was the default provider, the first remaining provider becomes the default (or none). |
| `POST /api/admin/identity/:id/test` | `{ lookupUser? }` | `{ ok, elapsedMs, steps: [{step, ok, groups?}] }` |
| `POST /api/admin/identity/simulate` | `{ username, password }` | `{ ok: true, provider, username, groups[], roles[], teams[], mfaRequired }` or `{ ok: false, provider, message }`. `422` if no provider handles the domain. No session is created. Audited. |
| `POST /api/admin/identity/options` (re-auth) | `{ defaultProvider?, localUsersEnabled? }` | `{ saved: true }` |

### Security

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/security` | | `{ policy, roles, sessions: [{id (short), username, name, provider, ip, userAgent, loginAt, lastActivity, breakGlass}], lockouts: [{key, kind, name, lockedUntil}], breakGlass: [<last 5 auth.breakglass audit events>], clientIp, vault: {provider, location} }` |
| `POST /api/admin/security/policy` (re-auth) | Any subset of `{ session{}, password{}, lockout{}, mfa{requiredRoles[], issuer}, adminAllowedCidrs[], trustedProxies[], separationOfDuties{vaultAdminCanApprove} }` | `{ saved: true, policy }`. `422`: value out of range, invalid CIDR, unknown role, or an admin network that excludes the caller. |
| `POST /api/admin/security/sessions/revoke` | `{ id? (short id), username? }` | `{ sessions }`. `422` if both are missing. Every active session whose id starts with `id`, or that belongs to `username`, is ended. |
| `POST /api/admin/security/lockouts/clear` | `{ key }` (`u:<name>` or `ip:<address>`) | `{ lockouts }` |
| `POST /api/admin/security/mfa/reset` (re-auth) | `{ username }` (`DOMAIN\user` or `LOCAL\user`) | `{ reset }`. Also ends the user's sessions. |

The policy ranges are listed in [security.md](security.md).

### Vault

| Route | Body | Response |
|---|---|---|
| `GET /api/admin/vault` | | `{ status: {keyProvider, keyLocation, healthy, error, entries, expired, expiring, types[]}, entries: [<entry view> + usedBy[]], teams, items }` |
| `POST /api/admin/vault` (re-auth) | `{ mode: "create" \| "update", id, name?, type?, description?, username?, target?, secret?, passphrase?, fields?{}, scope?{system, teams[], items[]}, tags?[], expiresAt? }` | The entry view (never the secret). `type` and `secret` are required on create. `passphrase` is applied only together with `secret`. `422` on validation errors. |
| `DELETE /api/admin/vault/:id` (re-auth) | | `{ deleted }`. `422` while the entry is referenced ("still used by: ..."). |

Entry view: `{id, name, type, description, username, target, fields, scope, tags, expiresAt, createdAt, createdBy, updatedAt, updatedBy, lastUsedAt, lastUsedBy, useCount, version, hasPassphrase, versions, state}`. See [vault.md](vault.md#52-fields).

### Audit

| Route | Response |
|---|---|
| `GET /api/admin/audit` | `{ entries: [{ts, actor, action, target, details}] }`: the last 200 lines of `logs/audit.jsonl`, newest first |
