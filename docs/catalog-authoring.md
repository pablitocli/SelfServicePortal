# Catalog authoring guide

This guide explains how to add a service to the Self-Service Portal catalog. A service is one JSON **catalog item**, which defines the request form, access rules, approval and execution contract, plus one PowerShell **handler** script that does the work. The portal renders the form, validates the request, runs the approval workflow and starts the handler in a separate `pwsh` process. You do not change any web code and you do not restart the portal.

The audience is automation engineers and catalog administrators (`Admin` or `CatalogAdmin` role). For the platform, see [architecture.md](architecture.md). For portal settings (sites, teams, VM notes, jobs), see [configuration.md](configuration.md). For credentials, see [vault.md](vault.md).

## Contents

1. [How a request flows](#1-how-a-request-flows)
2. [Anatomy of a catalog item](#2-anatomy-of-a-catalog-item)
3. [Inputs](#3-inputs)
4. [Lookup sources](#4-lookup-sources)
5. [Validation rules enforced by the portal](#5-validation-rules-enforced-by-the-portal)
6. [Writing a handler](#6-writing-a-handler)
7. [Handler location rules](#7-handler-location-rules)
8. [The Admin catalog editor](#8-the-admin-catalog-editor)
9. [Hot reload and versioning](#9-hot-reload-and-versioning)
10. [Testing](#10-testing)
11. [Team scoping and approvals](#11-team-scoping-and-approvals)
12. [Minimal example: Hello world](#12-minimal-example-hello-world)
13. [Worked example: restart a Windows service on a VM](#13-worked-example-restart-a-windows-service-on-a-vm)
14. [Best practices and security notes](#14-best-practices-and-security-notes)

---

## 1. How a request flows

```
catalog/items/<id>.json ──► marketplace card + request form (rendered from the JSON)
                                   │  submit
                                   ▼
               server-side validation (Test-PortalRequestInput)
                                   │
            ┌──────────────────────┴──────────────────────┐
   approval.required = true                     approval.required = false
            │                                             │
     PendingApproval ──approve──► Queued ◄────────────────┘
            │  └─reject──► Rejected            │ dispatcher (jobs.maxConcurrent)
            └─cancel──► Cancelled              ▼
                                  Dispatched ─► Running ─► Succeeded | Failed
                                                   │
                     pwsh automation/Invoke-CatalogJob.ps1 -RequestId REQ-...
                     (vCenter / cloud session, vault credentials, VM notes)
                                                   │
                                     & automation/handlers/<handler>.ps1 @params
```

When a request is submitted, the portal stores a **snapshot of the execution contract** with it (handler name, fixed parameters, credential bindings, timeout, VM notes labels, re-authentication flag). If you edit the item later, queued requests still use the contract they were submitted with. The handler *script* itself is read when the job starts, so changes to the script do apply to queued requests.

## 2. Anatomy of a catalog item

Items are JSON files in `catalog/items/`. Start from `catalog/_templates/new-item.template.json`, or use the editor in **Admin > Catalog**. The file name does not matter. The editor saves new items as `<id>.json`. The `$schema` property (`../schema/catalog-item.schema.json`) enables completion in editors such as VS Code.

### 2.1 Top-level properties

| Property | Required | Type | Description |
|---|---|---|---|
| `id` | yes | string | Unique, immutable identifier. Regex `^[a-z0-9][a-z0-9-]{2,62}$`. Stored in every request and used for vault scoping. |
| `version` | yes | string | Semantic version `x.y.z`. Stored in every request (`itemVersion`). |
| `enabled` | no | bool | Default `true`. `false` hides the item from **everyone**, including Admins, but keeps it in the Admin catalog list. |
| `name` | yes | string | Card and form title (schema: max 80 characters). |
| `category` | yes | string | Marketplace section and filter chip, for example `Datacenter operations` or `Cloud Ops` (schema: max 40). |
| `icon` | no | string | Card icon. Valid keys: `vm`, `windows`, `linux`, `snapshot`, `network`, `storage`, `backup`, `security`, `database`, `cloud`, `generic` (default). |
| `summary` | yes | string | One line on the card (schema: max 200). |
| `description` | no | string | Shown in the "About this service" panel of the form (schema: max 2000). |
| `owner` | no | string | Owning team, shown on the form. |
| `tags` | no | string[] | Search terms. The first two are shown on the card. |
| `estimatedDuration` | no | string | Free text, for example `5-10 min`. |
| `sites` | no | string[] | Site codes (from `portal.config.json` → `sites[]`) where the item is offered. This restricts the `sites` lookup. Omit it to offer the item at every enabled site. |
| `access` | no | object | Who sees the item. See [2.2](#22-access). |
| `approval` | no | object | Approval workflow. See [2.3](#23-approval). |
| `execution` | yes | object | Handler and run-time contract. See [2.4](#24-execution). |
| `vmNotes` | no | bool | Appends the **VM notes** section (Admin > Customization > VM notes) to the form. The handler must declare `-VmNotes`. See [6.4](#64-vm-notes). |
| `security` | no | object | `{ "requireReauth": true }` asks the user to confirm their password within the re-authentication window (`security.session.reauthWindowMinutes`, default 5 min) before they can **submit** or **approve** a request for this item. |
| `inputs` | yes | array | Form fields, in display order. See [3](#3-inputs). |

### 2.2 `access`

| Property | Description |
|---|---|
| `roles` | Roles that see the item. Default when omitted: `Requester`, `Approver`, `Admin`. Valid roles: `Requester`, `Approver`, `Admin`, `CatalogAdmin`, `SecurityAdmin`, `VaultAdmin`. The `Admin` role implicitly holds every role. |
| `teams` | Team ids from Admin > Customization > Teams (`portal.config.json` → `teams[].id`), or **team roles** `@datacenter` / `@cloud`, which the portal maps to team ids with `catalog.teamRoles` (Admin > Customization > Teams). Shipped items use team roles so they carry no organisation-specific team names. Empty or omitted means every team. Admins see every item. See [11](#11-team-scoping-and-approvals). |

### 2.3 `approval`

| Property | Description |
|---|---|
| `required` | `true`: the request waits in `PendingApproval`. `false`: it goes straight to `Queued`. |
| `approverRoles` | Roles allowed to decide. Default: `Approver`, `Admin`. The approver must also belong to one of the item's teams. |

### 2.4 `execution`

| Property | Default | Description |
|---|---|---|
| `handler` | (required) | Script file name in `automation/handlers` (`New-VsphereVM.ps1`), or a path inside a folder listed in `automation.allowedHandlerRoots`. See [7](#7-handler-location-rules). |
| `requiresVCenter` | `true` | When `true`, the runner connects to the vCenter of the site selected in `siteInput` and passes the session as `Context.VIServer`. The site input must exist. |
| `siteInput` | `Site` | Name of the input that selects the site/vCenter. Inventory lookups depend on it. |
| `cloud` | none | `aws` or `azure`. The runner authenticates with Admin > Cloud connections and passes the session as `Context.Cloud`. Cloud items must set `requiresVCenter: false`. |
| `timeoutMinutes` | `jobs.defaultTimeoutMinutes` (60) | The dispatcher kills the runner process after this time and marks the request `Failed`. Schema range: 1-1440. |
| `fixedParameters` | `{}` | Handler parameters that the requester never sees, for example template or customization spec. A value can be a scalar, a **per-site value** `"@site:<key>"` (read from `sites[].catalogValues.<key>` of the selected site; the key must be declared in `catalog.siteValues`, see [configuration.md](configuration.md#316-catalog)), or a per-site map `{ "DC1": "TPL-A", "*": "TPL-DEFAULT" }` (`*` is the fallback). Prefer `@site:` for anything shared or published: the item then contains no site codes or names. The runner refuses to start a job while a resolved value is empty or starts with `TBD-`. Fixed parameters also count as form values in lookups, so a fixed `Workload` filters the `datastores` lookup. |
| `credentials` | `{}` | Fixed vault bindings: `{ "HandlerParameter": "vault-entry-id" }`. At run time the runner decrypts the entry and passes a `[pscredential]`. The vault id must match `^[a-z0-9][a-z0-9._-]{1,62}$`, and the entry's scope must allow this item. See [vault.md](vault.md). |

Example (from `vm-windows-2025.json`):

```json
"execution": {
  "handler": "New-VsphereVM.ps1",
  "requiresVCenter": true,
  "siteInput": "Site",
  "timeoutMinutes": 60,
  "fixedParameters": {
    "GuestFamily": "Windows",
    "Template":          "@site:windowsTemplate",
    "CustomizationSpec": "@site:windowsCustomizationSpec"
  }
}
```

## 3. Inputs

Every input becomes a form field and is passed to the handler as the parameter with the **same name**.

### 3.1 Input types

| Type | Form control | Server-side handling | Typical handler parameter |
|---|---|---|---|
| `text` | Single-line text | Trimmed. `transform`, `minLength`, `maxLength`, `pattern` applied. | `[string]` |
| `textarea` | Multi-line text | Same as `text`. | `[string]` |
| `number` | Number box | Must parse as a number (invariant culture). `min`/`max` applied. Integral values are passed as `[int64]`. | `[int]`, `[double]` |
| `select` | Drop-down | Value must be one of the options (static `options` or a `source` lookup), compared **case-sensitively**. | `[string]` |
| `boolean` | Checkbox | Converted to `$true`/`$false`. An empty value is `$false`. | `[bool]` (preferred over `[switch]`) |
| `ipv4` | Text | Dotted-quad regex plus `IPAddress.TryParse`. | `[string]` |
| `credential` | Vault entry selector | The value is a **vault entry id**. It must be one of the entries this item may use (scope by item and team, optionally narrowed by `vaultTags`). The runner replaces it with a decrypted `[pscredential]`. | `[pscredential]` |

For `credential` inputs, `vaultTags` (string array) limits the offered vault entries to those carrying at least one of the tags, for example `"vaultTags": ["windows-guest"]`. The browser never receives a secret: the options endpoint returns only entry id and display name.

### 3.2 Input attributes

| Attribute | Applies to | Description |
|---|---|---|
| `name` | all | Required. Regex `^[A-Za-z][A-Za-z0-9]{0,40}$`. Unique within the item (case-insensitive). Must match a handler parameter. |
| `label` | all | Required. Field label and the name used in error messages. |
| `type` | all | Required. One of the types above. |
| `group` | all | Form section title. Fields with the same group are rendered together in the order of first appearance. Default: `Details`. |
| `required` | all | The field must have a value. Has no effect on `boolean`. |
| `default` | all | Pre-filled value. Also applied server-side when the submitted value is empty. |
| `placeholder` | text | Hint shown in an empty text box. |
| `help` | all | Help text under the field. |
| `transform` | text, textarea | `upper`, `lower` or `trim` (values are always trimmed). Applied **before** validation. |
| `validation.pattern` | text, textarea | .NET regular expression the value must match. Anchor it (`^...$`). |
| `validation.patternMessage` | text, textarea | Error shown when the pattern does not match. |
| `validation.minLength` / `maxLength` | text, textarea | Length limits. `maxLength` is also enforced in the browser. |
| `validation.min` / `max` | number | Inclusive numeric range. |
| `options` | select | Static list: `[ { "value": "App", "label": "Application" } ]`. |
| `source` | select | Dynamic list. See [4](#4-lookup-sources). |
| `source.type` | select | Lookup source type. |
| `source.dependsOn` | select | Inputs that must have a value before the lookup runs. The form reloads the list when they change. Each one must be declared **earlier** in `inputs`. |
| `source.filter` | select | .NET regex applied to the option **value**. |
| `source.minFreeGB` | select (`datastores`) | Hide datastores with less free space. |
| `visibleWhen` | all | `{ "field": "IpMode", "equals": "Static" }`. The field is shown, validated and passed only when the referenced earlier input has that value (compared as strings). Hidden fields are **not** passed to the handler. |
| `requireReauth` | any | The user must confirm their password before this input's lookup runs (options endpoint), and again (if the window expired) when submitting; approvals of the request also require it. Use it for lookups that touch infrastructure (for example a storage rescan). |
| `vaultTags` | credential | See [3.1](#31-input-types). |

## 4. Lookup sources

Inventory sources read the **inventory cache** (`data/inventory/<SITE>.json`), which `automation/Update-VsphereInventory.ps1` collects every `inventory.refreshIntervalMinutes` (default 30). An Admin can also refresh it from Admin > vCenter connections. Objects created in vCenter appear in forms only after the next refresh. If a site has no cache yet, the lookup fails with *"Inventory for site X is not available yet"*.

| `source.type` | Data source | Value / label | Filters and behaviour | `dependsOn` |
|---|---|---|---|---|
| `sites` | `portal.config.json` → `sites[]` | `DC1` / `DC1 - Primary Datacenter` | Enabled sites only, restricted to the item's `sites` list when it is set. | none |
| `clusters` | inventory | name / `name (N hosts)` | Restricted to `sites[].defaults.allowedClusters` when that list is set. | site input (mandatory) |
| `datastores` | inventory | name / `name - X GB free (Y%)` | Excludes datastores in maintenance or not accessible. Scoped to the value of an input or fixed parameter named **`Cluster`**. When there is none, scoped to the cluster that `sites[].defaults.workloadClusters` maps from **`Workload`**. `minFreeGB` applies. | site input (mandatory), plus `Cluster` or `Workload` when used |
| `datastoreClusters` | inventory | name / `name - X GB free` | No cluster scoping. | site input (mandatory) |
| `portgroups` | inventory | name / `name (VLAN n)` | Restricted by the regex in `sites[].defaults.portgroupFilter`. | site input (mandatory) |
| `templates` | inventory | name / name | None. | site input (mandatory) |
| `folders` | inventory | path / path (`Datacenter/Folder/Sub`) | None. The handler receives the path (see `Resolve-PortalFolder` in `New-VsphereVM.ps1`). | site input (mandatory) |
| `vms` | inventory | name / `name (cluster)` | `source.powerState` (`PoweredOn`, `PoweredOff`, `Suspended`); `source.byCluster: true` keeps VMs of the selected `Cluster`. Use `filter` to restrict, for example `^(?!DECOM-)`. | site input (mandatory) |
| `hosts` | inventory | name / `name - cluster - ESXi version build - state` | Scoped to the value of the input named `Cluster` (or `source.clusterInput`) and to `allowedClusters`. `source.state`: `connected` or `maintenance`. Needs an inventory collected by 1.1.0 or later. | site input (mandatory) |
| `vdSwitches` | inventory | name / `name (vX, N hosts)` | Distributed switches. | site input (mandatory) |
| `storageDevices` | storage scan cache (`data/inventory/storage/<SITE>__<cluster>.json`) | canonical name / `naa... - size - vendor model (scanned <time> UTC)` | Unused LUNs that every connected host of the cluster sees. The lookup **never rescans**: the form shows a **Rescan storage** button (see [4.1](#41-storage-devices-and-rescans)). Put `"requireReauth": true` on the input. | site input and the cluster input |
| `softwareSets` | `config/software.json` (Admin > Data files) | set id / `name (N approved package(s), M not approved yet)` | `source.os`: `windows` or `linux`. | none |
| `backupPolicies` | `config/backup.json` (Admin > Data files) | policy id / `id - description` | Policies with `enabled: false` are hidden. | none |
| `awsSubnets` | Admin > Cloud connections → AWS subnets | subnet id / `label (id)` | AWS connection must be enabled. | none |
| `awsInstanceTypes` | AWS allowed instance types | type / type | AWS connection must be enabled. | none |
| `azureSubnets` | Azure subnets | name / `name (vnet)` | Azure connection must be enabled. | none |
| `azureVmSizes` | Azure allowed VM sizes | size / size | Azure connection must be enabled. | none |

Common rules:

- `source.filter` is applied to the option value of every source type.
- Results are sorted by label.
- The **same lookup runs again server-side** when the request is submitted. A value that is not in the list at that moment is rejected, so a crafted request cannot reference an object outside the allowed set.
- Cloud lookups read the lists configured in Admin > Cloud connections. They do not query the cloud API.

### 4.1 Storage devices and rescans

A storage rescan touches every host of a cluster, so the portal controls it:

- Rescans start only from the **Rescan storage** button (`POST /api/storage/rescan`). Every rescan requires a valid, recent authentication: the user must have signed in or confirmed the password (and OTP) within the re-authentication window (`security.session.reauthWindowMinutes`, default 5 minutes).
- One scan or rescan per cluster at a time (lock), and a cool-down between rescans (`operations.storage.rescanCooldownMinutes`, default 10). The form shows the last rescan, who started it and when the next one is allowed.
- The scan runs out of process (`automation/Get-PortalStorageDevices.ps1`). The audit log records `storage.rescan` with the user, time and client IP, and the scan state keeps the last 50 rescans.
- Job handlers take the same per-cluster lock with `Enter-PortalStorageLock` / `Exit-PortalStorageLock` (module `Portal.Storage`).

## 5. Validation rules enforced by the portal

`Test-PortalCatalogDefinition` (module `Portal.Catalog`) runs when items are loaded, when they are saved in the editor, and in `tools/Test-CatalogItem.ps1`. An item that fails is **not published**. Admin > Catalog lists it with the exact reasons.

1. `id`, `version`, `name`, `category`, `summary`, `execution` and `inputs` are present and not empty.
2. `id` matches `^[a-z0-9][a-z0-9-]{2,62}$`. `version` matches `x.y.z`.
3. `access.roles` and `approval.approverRoles` contain only known roles.
4. `access.teams` contains only team ids defined in the configuration.
5. `sites` contains only site codes defined in the configuration.
6. `execution.handler` is set, resolves inside an allowed handler folder, exists, and parses without syntax errors.
7. Every `execution.fixedParameters` key is a parameter of the handler.
8. `execution.credentials` is an object. Every key is a handler parameter, and every value is a syntactically valid vault id.
9. Every input has a valid, unique `name`, a `label` and a known `type`.
10. Every input (except VM notes fields) matches a handler parameter.
11. A `select` input has `options` or a `source`.
12. `source.type` is known. Every `dependsOn` entry references an input declared earlier. Inventory sources (`clusters`, `datastores`, `datastoreClusters`, `portgroups`, `templates`, `folders`, `vms`, `hosts`, `vdSwitches`, `storageDevices`) depend on the site input.
13. `source.filter` and `validation.pattern` are valid regular expressions.
14. `visibleWhen.field` references an input declared earlier.
15. Every **mandatory** handler parameter (except `Context`) is provided by an input, a fixed parameter or a credential binding.
16. `vmNotes: true` requires a `-VmNotes` handler parameter.
17. `execution.cloud` is `aws` or `azure`, and cloud items set `requiresVCenter: false`.
18. When `requiresVCenter` is `true` (the default), the input named in `siteInput` exists.
19. At load time, the file is valid JSON and the `id` is not used by another file.

The JSON schema adds editor-time constraints, such as maximum lengths, the `icon` list and the timeout range, that the loader does not check. Keep items schema-valid anyway.

## 6. Writing a handler

A handler is a PowerShell 7 script. The runner (`automation/Invoke-CatalogJob.ps1`) starts it in a fresh `pwsh` process per request, under the portal service account.

### 6.1 The `param()` block is the contract

- Declare **one parameter per input name** and per `fixedParameters` / `credentials` key. The runner passes only parameters the script declares, so any extra value is ignored.
- Mark a parameter `[Parameter(Mandatory)]` only if the item always provides it. A mandatory parameter fed by a `visibleWhen` input that can be hidden makes the job fail. Give such parameters a default and check them in code (see `IPAddress` in `New-VsphereVM.ps1`).
- Use `[ValidateSet()]`, `[ValidateRange()]` and `[ValidatePattern()]` as a second line of defence. The editor's *Inspect* button turns a `ValidateSet` into select options.
- Type credential parameters as `[pscredential]`.
- Declare `[System.Collections.IDictionary] $VmNotes` when the item has `vmNotes: true`.
- Declare `[Parameter(Mandatory)] $Context` to receive the run context.

### 6.2 `-Context`

| Property | Content |
|---|---|
| `RequestId` | `REQ-yyyyMMdd-XXXXXX` |
| `Requester` | `@{ username; name; email }` |
| `Site` | Site configuration (`code`, `name`, `vcenter`, `defaults` with `dnsDomain`, `dnsServers`, `minDatastoreFreePercent`, `workloadClusters`, ...). `$null` for items without vCenter. |
| `VIServer` | Open PowerCLI session to the site's vCenter (`requiresVCenter: true`). The session is private to this job. Always pass `-Server $Context.VIServer`. |
| `Cloud` | Cloud session (`execution.cloud`). AWS: `@{ Provider='aws'; Region; Credential; Settings }`. Pass `-Region` and `-Credential` to AWS.Tools cmdlets. Azure: `@{ Provider='azure'; Location; SubscriptionId; Account; Settings }`. The Az context is process-scoped and already selected. `Settings` never contains secrets. |
| `RollbackOnFailure` | Value of `jobs.rollbackOnFailure` (default `true`). |
| `PortalRoot` | Portal installation folder. |
| `ReportDir` | Folder for reports of this request (`data/reports/<REQ-ID>`). Use `New-PortalReport`. |
| `Teams` | Teams of the item. |
| `ItemId` | Catalog item id. |
| `Approval` | `@{ required; decision; decidedBy; decidedAt; comment }`. |
| `Authorization` | Re-authentication evidence when the item requires it: `@{ by; at; ip; reauthenticated }`. `$null` otherwise. |
| `Operations` | The `operations` section of the configuration (storage, decommission, snapshots, test clones, right-sizing, certificates, capacity, power schedules, reports). |

#### Libraries available to handlers

| Module | Imported by the runner | Functions |
|---|---|---|
| `automation/lib/Portal.Report.psm1` | yes | `New-PortalReport -Title -Subtitle -Context -Sections -Summary`, `New-PortalReportSection -Title -Rows -Columns -Note`. Writes a self-contained HTML file and one CSV per section into `Context.ReportDir`. Columns named `Status`, `Result` or `Compliance` are coloured by keyword (OK / PASS / COMPLIANT, WARN / EXPIRING / NOT SET, FAIL / CRITICAL / ERROR / EXPIRED / NON-COMPLIANT). The request page lists the files; they are served with a CSP that forbids scripts. |
| `modules/Portal.Data.psm1` | yes | `Get-PortalDataFile -Name software\|versionBaseline\|hardeningBaseline\|backup`, `Get-PortalSoftwareSet -Id [-Os]` (approved packages + skipped ones). |
| `modules/Portal.Storage.psm1` | yes | `Enter-PortalStorageLock`, `Exit-PortalStorageLock`, `Get-PortalStorageState`. |
| `automation/lib/Portal.Guest.psm1` | no (import it from `Context.PortalRoot`) | `Invoke-PortalGuestScript` (VMware Tools guest operations with a reliable exit code and secret masking), `Wait-PortalGuestReady`, `Resolve-PortalGuestVM`, `ConvertTo-PortalGuestLiteral`, `ConvertTo-PortalBashLiteral`. |

The runner disconnects the vCenter and cloud sessions after the handler finishes, whether it succeeded or failed.

### 6.3 Logging

```powershell
Write-JobLog -Level STEP 'Cloning template'      # STEP | OK | INFO (default) | WARN | ERROR
```

- The log is written to `logs/jobs/<RequestId>.log` and shown live on the request page.
- `Write-Host`/`Write-Information` output is captured as `INFO`, and `Write-Warning` as `WARN`. `Write-Verbose` and `Write-Debug` are not captured.
- Any decrypted vault secret that appears in a log line is replaced with `********`.
- The runner already logs the requester, approver, connection, every parameter (credentials as `<credential user>`) and the final outcome.

To make a handler runnable outside the portal, add this shim (used by the shipped handlers):

```powershell
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
```

### 6.4 VM notes

When the item has `vmNotes: true`, the form gets the VM notes section configured in Admin > Customization (fields `Note<key>`). The runner passes them as one ordered dictionary, `-VmNotes`, keyed by **label** (`Application / service = Payroll`). Empty values are skipped. Shipped handlers append the notes to the vSphere VM *Notes* and write them as `Note-<Label>` tags on AWS and Azure.

### 6.5 Result, failure and rollback

- **Success**: `return` an `[ordered]@{}` hashtable. The last hashtable or object that the script writes becomes the request **Result**, shown as a key/value list. Arrays are shown as bullet lists, so `NextSteps = @('...')` is a useful convention. Suppress other pipeline output (`$null = New-VM ...`) so a stray object does not become the result.
- **Failure**: `throw`. The request becomes `Failed`, and the exception message is stored as the request error and shown to the requester.
- **Rollback**: wrap the change in `try`/`catch`. In `catch`, undo what this run created, but only when `$Context.RollbackOnFailure` is set, log each step, and re-throw the original error:

```powershell
$created = $null
try {
    $created = New-Thing ...
    # further steps
}
catch {
    $err = $_
    if ($created -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: removing $($created.Name)"
        try { Remove-Thing $created -Confirm:$false; Write-JobLog -Level WARN 'Rollback completed.' }
        catch { Write-JobLog -Level ERROR "Rollback failed - manual cleanup required: $($_.Exception.Message)" }
    }
    throw $err
}
```

A **timeout** kills the process, so `catch` and `finally` blocks do not run. Set `timeoutMinutes` well above the worst case, and use internal deadlines inside long waits (see `Invoke-VsphereVmPower.ps1`).

### 6.6 Idempotency and safety

- **Validate before changing anything**: check that the object exists, that the name is free, the capacity floor, power state and VMware Tools status. See the pre-flight section of `New-VsphereVM.ps1`.
- **Make re-runs safe**: if the target state already holds, log a `WARN` and succeed. Do not fail. If a name is already taken, refuse instead of overwriting.
- Never act on objects that the request did not name or that the handler did not create.
- Do not prompt. The runner is non-interactive, so pass `-Confirm:$false` explicitly.
- Set `$ErrorActionPreference = 'Stop'` at the top of the script.

## 7. Handler location rules

| `execution.handler` value | Resolves to | Allowed when |
|---|---|---|
| `My-Handler.ps1` (file name only) | `automation/handlers/My-Handler.ps1` | always |
| `D:\Automation\Invoke-X.ps1` or `/srv/automation/x.ps1` (absolute) | that path | the path is inside a folder listed in `automation.allowedHandlerRoots` |
| `custom/handlers/x.ps1` (relative) | relative to the portal root | inside an allowed root |

- Only `.ps1` files are accepted. A path outside every allowed root is rejected at validation time **and** again by the runner.
- `automation.allowedHandlerRoots` (in `portal.config.json`) takes absolute paths or paths relative to the portal root. See [configuration.md](configuration.md).
- Files whose names start with `_` (such as `_Handler.template.ps1`) are hidden from the editor's handler list.
- Every allowed root is a code-execution boundary. Restrict write access to these folders as tightly as you restrict access to the portal service account. See [security.md](security.md).

## 8. The Admin catalog editor

**Admin > Catalog** requires the `catalog.manage` permission (`Admin` or `CatalogAdmin`).

| Function | Description |
|---|---|
| Item list | Every item with version, handler, approval and roles. Items that fail validation are listed separately with their errors. |
| **+ New catalog item** / Edit | Form for general properties, access (roles, teams), VM notes switch, approval, sites, automation (handler, timeout, site input, cloud provider, vCenter session), fixed parameters (scalar or **per site**) and inputs (type, section, default, help, options or source, dependsOn, filter, regex, max length, transform, min/max, visibleWhen). |
| **Inspect script parameters** | Parses the handler without running it. It lists each parameter's type, whether it is mandatory, the `ValidateSet` values, and whether an input or fixed parameter covers it. From the list you can add a missing parameter as an input or a fixed parameter, or add all missing ones at once. `ValidateSet` becomes a select, numeric types become `number`, and `bool`/`switch` become `boolean`. |
| **Create script skeleton** | Writes a new handler in the resolved location. Its `param()` block contains the current inputs and fixed parameters plus `-Context`. The skeleton throws "not implemented" until you write the logic. Existing files are never overwritten. |
| **Advanced: JSON definition** | Raw JSON, with *Refresh from form* and *Apply JSON to form*. Use it for attributes that the form does not expose: `execution.credentials`, `security.requireReauth`, input `requireReauth`, `vaultTags`, `placeholder`, `minLength`, `minFreeGB`, and the `*` default in per-site maps. |
| **Validate** / **Save** | Runs the same validator as the loader. Saving an existing item first copies the previous file to `catalog/_archive/<id>.<timestamp>.json`. |
| Delete | Moves the file to `catalog/_archive/<id>.deleted.<timestamp>.json`. Items are never hard-deleted. |

Every create, update, delete and skeleton creation is written to the audit log.

## 9. Hot reload and versioning

- The catalog is read from disk on every catalog call. A new, changed or removed JSON file takes effect immediately, with no restart. Copying files into `catalog/items/` (for example from source control) works the same way as saving in the editor.
- Each job runs in a new `pwsh` process, so a changed handler script applies to the next job that starts.
- Changes to teams, sites and VM notes fields in the configuration are also applied live.
- Bump `version` on every functional change. Requests record the version they were submitted with.

## 10. Testing

### 10.1 Static validation

```powershell
pwsh -File ./tools/Test-CatalogItem.ps1 -Path ./catalog/items/my-item.json
pwsh -File ./tools/Test-CatalogItem.ps1            # every item in catalog/items
```

The tool runs the same validator as the portal, including handler parsing and parameter matching. Its exit code is the number of failing items, which makes it usable in CI. Run it on the portal server or against a copy of its `config/`, because sites and teams are checked against the configuration.

Run the offline smoke test after changes to shared code: `pwsh -File ./tests/Invoke-SmokeTest.ps1`.

### 10.1b Offline handler tests

`tests/Invoke-HandlerTests.ps1` validates every item and runs `tests/handlers/*.Tests.ps1`. Each test file defines PowerCLI / AWS / Azure **stub functions** with the names of the cmdlets the handler calls and runs the real handler against them (`Invoke-TestHandler`), so no vCenter or cloud account is needed. Copy an existing test file as a starting point. The working contract for new items is in [dev/ITEM-CONTRACT.md](dev/ITEM-CONTRACT.md).

### 10.2 Dry run outside the portal

Handlers are plain scripts, so you can run them interactively against a lab vCenter with a hand-made context:

```powershell
Import-Module VMware.VimAutomation.Core
$vi  = Connect-VIServer lab-vcenter.corp.example.com -Credential (Get-Credential)
$ctx = [pscustomobject]@{
    RequestId = 'REQ-20260101-000000'; Requester = @{ username = 'me'; name = 'Me'; email = '' }
    Site = @{ code = 'LAB'; defaults = @{ dnsDomain = 'lab.example.com'; minDatastoreFreePercent = 15 } }
    VIServer = $vi; Cloud = $null; RollbackOnFailure = $true; PortalRoot = (Get-Location).Path
}
./automation/handlers/My-Handler.ps1 -Site LAB -VMName TEST01 -Context $ctx
```

For items that change or delete things, add an optional `[bool] $DryRun` parameter. With it set, the handler runs every pre-check and logs the actions it *would* take, without changing anything. Expose it as a `boolean` input during the pilot, or set it in `fixedParameters` on a test copy of the item. (A platform-level dry-run mode is planned. See [roadmap.md](roadmap.md).)

### 10.3 Pilot in the portal

`enabled: false` hides the item from everyone, so it cannot be used for a pilot. Publish the item with `access.roles: ["Admin"]`, or with a dedicated test team in `access.teams`, and with `approval.required: true`. Run it against lab objects, review the job log and the result, then widen access.

## 11. Team scoping and approvals

- **Visibility**: a user sees an item when the item is enabled, the user holds one of `access.roles`, and, if `access.teams` is set, the user belongs to one of those teams. Admins see every item.
- **Request scope**: a request inherits the item's teams when it is submitted. Approvers see and decide only requests of their own teams, in *All requests*, *Approvals* and the request detail page.
- **Who can approve**: a user who holds one of `approval.approverRoles` and belongs to the request's team. Self-approval is refused unless `auth.allowSelfApproval` is `true`. Separation of duties: a user holding `VaultAdmin` (directly or through `Admin`) cannot approve requests that use vault credentials (fixed `credentials` or `credential` inputs), unless `security.separationOfDuties.vaultAdminCanApprove` is `true`.
- **Reject** requires a comment. The requester or an Admin can **cancel** a request while it is `PendingApproval` or `Queued`.
- **Re-authentication**: with `security.requireReauth`, both submitting and approving ask for the password (and OTP, if enrolled) when the last confirmation is older than the re-authentication window.
- **Vault scope**: a vault entry is usable by an item only when the entry's scope lists the item id (or `*`) and, if the entry is team-scoped, one of the item's teams. See [vault.md](vault.md).
- A team cannot be deleted while items reference it.

## 12. Minimal example: Hello world

`catalog/items/hello-world.json`:

```json
{
  "$schema": "../schema/catalog-item.schema.json",
  "id": "hello-world",
  "version": "0.1.0",
  "enabled": true,
  "name": "Hello world",
  "category": "Examples",
  "icon": "generic",
  "summary": "Writes a message to the job log and returns it.",
  "access": { "roles": ["Admin"] },
  "approval": { "required": false },
  "execution": { "handler": "Invoke-HelloWorld.ps1", "requiresVCenter": false, "timeoutMinutes": 5 },
  "inputs": [
    { "name": "Message", "label": "Message", "type": "text", "required": true, "default": "Hello",
      "validation": { "maxLength": 100 } }
  ]
}
```

`automation/handlers/Invoke-HelloWorld.ps1`:

```powershell
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Message,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
Write-JobLog -Level STEP "Request $($Context.RequestId) from $($Context.Requester.username)"
Write-JobLog -Level OK "Message: $Message"
return [ordered]@{ Message = $Message; RunAt = (Get-Date).ToString('u'); Host = [Environment]::MachineName }
```

Run `tools/Test-CatalogItem.ps1 -Path ./catalog/items/hello-world.json`. Then open the marketplace as an Admin and submit the request.

## 13. Worked example: restart a Windows service on a VM

> **This item is an example to adapt. It is not shipped with the portal.** Review it against your change process, vCenter permissions and guest hardening before you use it.

The example shows:

- a `credential` input bound to the vault
- inventory lookups that depend on the site
- defensive input validation
- two execution methods: VMware Tools guest operations (no network path to the guest needed) or WinRM over HTTPS

### 13.1 Prerequisites

1. **Vault entry** (Admin > Vault, `vault.manage`): id `guest-windows-ops`, type *UsernamePassword*, user `CORP\svc-guestops` (least privilege: rights to restart services only). Scope: items `vm-restart-windows-service`, team `Infrastructure`. Tag: `windows-guest`.
2. **vCenter service account** (guest operations method): privileges *Virtual machine > Guest operations > Guest operation program execution* and *Guest operation queries* on the target VMs.
3. **WinRM method**: HTTPS listener (5986) on the guests, DNS name `<VMName>.<site dnsDomain>`, and firewall access from the portal server. On Linux portal servers, PowerShell remoting to Windows needs an additional WSMan client (for example the `PSWSMan` module). Prefer guest operations there.

### 13.2 Item: `catalog/items/vm-restart-windows-service.json`

```json
{
  "$schema": "../schema/catalog-item.schema.json",
  "id": "vm-restart-windows-service",
  "version": "1.0.0",
  "enabled": true,
  "name": "Restart a Windows service",
  "category": "Datacenter operations",
  "icon": "windows",
  "summary": "Restart a Windows service inside an existing VM.",
  "description": "Restarts the named service with VMware Tools guest operations or WinRM, using a vault credential. The service must exist; the job waits up to 2 minutes for it to reach Running.",
  "owner": "Infrastructure Operations",
  "tags": ["vSphere", "Day 2", "Windows"],
  "estimatedDuration": "1-3 min",
  "access": { "roles": ["Requester", "Approver", "Admin"], "teams": ["Infrastructure"] },
  "approval": { "required": true, "approverRoles": ["Approver", "Admin"] },
  "sites": ["DC1", "DC2"],
  "execution": {
    "handler": "Restart-VsphereGuestService.ps1",
    "requiresVCenter": true,
    "siteInput": "Site",
    "timeoutMinutes": 15,
    "fixedParameters": {}
  },
  "inputs": [
    { "name": "Site", "label": "Datacenter", "type": "select", "group": "Target", "required": true,
      "source": { "type": "sites" } },
    { "name": "VMName", "label": "Virtual machine", "type": "select", "group": "Target", "required": true,
      "source": { "type": "vms", "dependsOn": ["Site"], "filter": "^(?!DECOM-)" } },
    { "name": "ServiceName", "label": "Service name", "type": "text", "group": "Target", "required": true,
      "placeholder": "Spooler",
      "help": "Service name (not display name), as shown by Get-Service.",
      "validation": { "pattern": "^[A-Za-z0-9_.$-]{1,80}$", "patternMessage": "Letters, digits, _ . $ - only (max 80)." } },
    { "name": "GuestCredential", "label": "Guest credential", "type": "credential", "group": "Target", "required": true,
      "vaultTags": ["windows-guest"] },
    { "name": "Method", "label": "Method", "type": "select", "group": "Target", "required": true, "default": "GuestOperations",
      "options": [
        { "value": "GuestOperations", "label": "VMware Tools guest operations" },
        { "value": "WinRM", "label": "WinRM (HTTPS)" } ] },
    { "name": "ChangeTicket", "label": "Change ticket", "type": "text", "group": "Change", "required": true,
      "validation": { "pattern": "^[A-Z]{2,5}-?\\d{3,10}$", "patternMessage": "Ticket id, e.g. CHG0012345." },
      "transform": "upper" }
  ]
}
```

To always use one fixed account instead of letting the requester choose, remove the `GuestCredential` input and bind the credential in `execution`: `"credentials": { "GuestCredential": "guest-windows-ops" }`. To require password re-confirmation at submission and approval, add `"security": { "requireReauth": true }`.

### 13.3 Handler: `automation/handlers/Restart-VsphereGuestService.ps1`

```powershell
#Requires -Version 7.2
<#
.SYNOPSIS
    EXAMPLE (not shipped) - restarts a Windows service inside a VM via guest operations or WinRM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.$-]{1,80}$')] [string] $ServiceName,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [ValidateSet('GuestOperations', 'WinRM')] [string] $Method = 'GuestOperations',
    [Parameter(Mandatory)] [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}

$vi = $Context.VIServer

# 1. Pre-checks - nothing is changed before they pass.
$vm = Get-VM -Name $VMName -Server $vi
if ($vm.PowerState -ne 'PoweredOn')               { throw "$VMName is not powered on." }
if ([string]$vm.Guest.OSFullName -notmatch 'Windows') { throw "$VMName does not report a Windows guest OS ('$($vm.Guest.OSFullName)')." }

# 2. Guest script. ServiceName is constrained by the input pattern and ValidatePattern
#    (no quotes, spaces or separators), so embedding it in single quotes is safe.
$guestScript = @'
$ErrorActionPreference = 'Stop'
$s = Get-Service -Name '{0}'
$before = $s.Status
Restart-Service -InputObject $s -Force
$s.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
$after = (Get-Service -Name '{0}').Status
"RESULT|$before|$after"
'@ -f $ServiceName

# 3. Execute.
switch ($Method) {
    'GuestOperations' {
        if ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw 'VMware Tools is not running - guest operations are not possible.' }
        Write-JobLog -Level STEP "Restarting '$ServiceName' on $VMName (guest operations, user $($GuestCredential.UserName))"
        $r = Invoke-VMScript -VM $vm -ScriptText $guestScript -ScriptType Powershell -GuestCredential $GuestCredential -Server $vi
        if ($r.ExitCode -ne 0) { throw "Guest script failed (exit code $($r.ExitCode)): $(([string]$r.ScriptOutput).Trim())" }
        $out = [string]$r.ScriptOutput
    }
    'WinRM' {
        $domain = $Context.Site.defaults.dnsDomain
        $target = if ($domain) { "$VMName.$domain" } else { $VMName }
        Write-JobLog -Level STEP "Restarting '$ServiceName' on $target (WinRM HTTPS, user $($GuestCredential.UserName))"
        $out = (Invoke-Command -ComputerName $target -UseSSL -Credential $GuestCredential `
                               -ScriptBlock ([scriptblock]::Create($guestScript))) -join "`n"
    }
}

# 4. Parse and report.
$line = ($out -split "`r?`n" | Where-Object { $_ -like 'RESULT|*' } | Select-Object -Last 1)
if (-not $line) { throw "Unexpected guest output: $($out.Trim())" }
$null, $before, $after = $line.Trim().Split('|')
Write-JobLog -Level OK "Service '$ServiceName': $before -> $after"

return [ordered]@{
    VMName       = $VMName
    Service      = $ServiceName
    Method       = $Method
    StatusBefore = $before
    StatusAfter  = $after
    ChangeTicket = $ChangeTicket
    NextSteps    = @('Verify the application behind the service and close the change ticket.')
}
```

Notes on the example:

- **Rollback**: none is needed. The handler creates nothing, and a restart can be repeated, so the item is naturally idempotent.
- The service name is validated three times: by the input pattern, by the server-side request validation, and by the handler's `ValidatePattern`. This prevents command injection into the guest script.
- The credential never appears in the request, the job log or the result. Only the user name is logged.
- Validate and pilot it as described in [10](#10-testing) before publishing it to the team.

## 14. Best practices and security notes

**Secrets**

- Never put passwords, keys or tokens in catalog items, fixed parameters, handler scripts or text inputs. Item files are readable by catalog administrators. Every input value is stored in the request, shown to requesters and approvers, and written to the job log.
- Use the vault: `execution.credentials` for a fixed account, and `credential` inputs when the requester chooses among approved accounts. Scope each entry to specific items and teams, never to `*` unless you must. See [vault.md](vault.md).
- Exception messages are stored with the request and shown to the requester. Never include secret material in a `throw`.

**Inputs**

- Constrain every free-text input with an anchored `validation.pattern` and a `maxLength`. Prefer `select` with a lookup or static options to free text.
- Assume the browser is hostile. The server re-validates every value, and the handler should validate again with `Validate*` attributes.
- Never build commands by string concatenation from unconstrained input. When you must embed a value in a script, restrict it to a safe character set first, as in the example above.

**Privilege**

- Grant the vCenter, cloud and guest service accounts only the privileges their items need. Use separate accounts for read-only reports and for change items.
- Require approval for anything that changes or deletes production objects. Add `security.requireReauth` for destructive or high-impact items, and input `requireReauth` for sensitive lookups.
- Keep handler folders writable only by administrators. Every file in an allowed handler root can be executed as the portal service account.

**Operability**

- Pre-check, then change, then verify. Log a `STEP` before each change and an `OK` after it.
- Return useful identifiers (VM id, instance id, file names) and `NextSteps` for manual follow-up.
- Keep items small and focused. Use one handler per action, and reuse helper functions through a module in an allowed root.
- Keep items and handlers in source control, and run `tools/Test-CatalogItem.ps1` in CI before deployment.

See also: [configuration.md](configuration.md), [security.md](security.md), [vault.md](vault.md), [api.md](api.md), [operations.md](operations.md), [roadmap.md](roadmap.md).
