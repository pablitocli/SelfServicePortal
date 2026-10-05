# Catalog item contract (Phase 3 items)

Working rules for anyone (person or agent) adding a catalog item + handler to this repository.

## Files per item

| File | Purpose |
|---|---|
| `catalog/items/<item-id>.json` | Item definition. Follow `catalog/schema/catalog-item.schema.json`; copy the shape of `catalog/items/vm-snapshot.json` (simple) or `vm-windows-2025.json` (rich). |
| `automation/handlers/<Verb-Noun>.ps1` | Handler. Copy the header and the `Write-JobLog` fallback from `automation/handlers/New-VsphereSnapshot.ps1`. |
| `tests/handlers/<Group>.Tests.ps1` | Offline tests with stubs (see below). |

Validate with `pwsh -File tools/Test-CatalogItem.ps1 -Path catalog/items/<id>.json` and run
`pwsh -File tests/Invoke-HandlerTests.ps1 -Filter <Group>` (0 failures required).

## Item JSON rules

- `id` lowercase with hyphens; `version` "1.0.0"; `enabled` true; `owner` "Infrastructure Operations" (Infrastructure) or "Cloud Operations" (Cloud).
- `category`: one of `Datacenter (vSphere)`, `Datacenter operations`, `Network`, `Storage`, `Software installation`, `Reports`, `Backup`, `Cloud Ops`, `Blueprints`.
- `icon`: one of vm, windows, linux, snapshot, network, storage, backup, security, database, cloud, generic.
- `access`: `{ "roles": [...], "teams": ["Infrastructure"] }` (Cloud for cloud items). Roles: Requester, Approver, Admin.
- `approval`: `{ "required": true, "approverRoles": ["Approver", "Admin"] }` or `{ "required": false }`.
- `sites`: `["DC1", "DC2"]` for vSphere items. Per-site values in `execution.fixedParameters` are maps `{ "DC1": "...", "DC2": "..." }`; placeholders start with `TBD-`.
- `execution`: `handler` (file name only), `requiresVCenter` (true for vSphere), `siteInput` "Site", `timeoutMinutes`, `fixedParameters`.
  Cloud items: `"requiresVCenter": false, "cloud": "aws"|"azure"` (see `catalog/items/cloud-aws-almalinux.json`).
- Sensitive items: `"security": { "requireReauth": true }` (re-confirm password on submit and approve). An input can carry `"requireReauth": true` (its lookup requires re-auth).
- Every input that is not a VM note MUST be a parameter of the handler (validator rule). Input names are PascalCase.
- Input types: text, textarea, number, select, boolean, ipv4, credential. Selects use `options` (static `[{value,label}]`) or `source`.
- Lookup `source.type` values:
  - `sites`
  - inventory (must list the site input in `dependsOn`): `clusters`, `datastores` (uses `Cluster` or `Workload` value), `datastoreClusters`, `portgroups`, `templates`, `folders`, `vms` (+ optional `powerState`: PoweredOn/PoweredOff, `byCluster`: true uses the `Cluster` input), `hosts` (filtered by the `Cluster` input when set; optional `state`: connected | maintenance), `vdSwitches`, `storageDevices` (dependsOn Site + Cluster; cached LUN scan with a "Rescan storage" button; put `"requireReauth": true` on that input).
  - data files: `softwareSets` (+ optional `os`: windows | linux), `backupPolicies`.
  - cloud: `awsSubnets`, `awsInstanceTypes`, `azureSubnets`, `azureVmSizes`.
  - optional `filter` (regex on value), `dependsOn` must reference inputs declared earlier.
- `credential` input: the user picks a vault entry; the handler receives a `[pscredential]`. Optional `"vaultTags": ["guest-windows"]` narrows the list.
- `visibleWhen`: `{ "field": "Mode", "equals": "NFS" }`. `validation`: `pattern`, `patternMessage`, `min`, `max`, `maxLength`. `transform`: "upper" | "lower".
- Text in English. `help` texts short and useful.

## Handler rules

- `#Requires -Version 7.2`, comment-based help (SYNOPSIS, DESCRIPTION), `[CmdletBinding()]`, `$ErrorActionPreference = 'Stop'`.
- Parameters = item inputs + fixed parameters + `[Parameter(Mandatory)] $Context` (+ `[System.Collections.IDictionary] $VmNotes` if the item has VM notes).
- Booleans as `[bool] $X = $false` (not `[switch]`). Numbers `[int]`. Multi-value text inputs are a single string split on commas / new lines.
- Context: `VIServer` (open session — ALWAYS pass `-Server $vi`), `Site` (config: code, name, vcenter, defaults.allowedClusters, defaults.workloadClusters, defaults.vmFolder), `RequestId`, `Requester` (username, name, email), `RollbackOnFailure`, `PortalRoot`, `ReportDir`, `Teams`, `ItemId`, `Approval` (decidedBy / decidedAt), `Authorization` (by / at / ip when the item required re-auth), `Operations` (config `operations.*`: storage, decommission, snapshots, testClones, rightSizing, certificates, capacity, powerSchedules, reports), `Cloud` (cloud items: Provider aws|azure, Region / SubscriptionId).
- Log with `Write-JobLog "text" -Level STEP|INFO|OK|WARN|ERROR`. Never log secrets.
- Pre-checks first, then changes. Throw a clear message to fail. Roll back what the handler created when `$Context.RollbackOnFailure` is true.
- Respect `defaults.allowedClusters` of the site when the user picks a cluster/host.
- Destructive bulk operations default to a dry run (`[bool] $DryRun = $true` + input `DryRun` boolean default true).
- Return an `[ordered]@{}` result (strings, numbers, string arrays; `NextSteps` array for follow-up). Keep it short; details go to the log or a report.
- Reports: `New-PortalReport -Title -Subtitle -Context $Context -Sections @(New-PortalReportSection -Title -Rows -Columns -Note) -Summary ([ordered]@{...})` (module `automation/lib/Portal.Report.psm1`, already imported by the runner). Columns named Status / Result / Compliance are coloured: OK / PASS / COMPLIANT green, WARN / WARNING / EXPIRING / NOT SET amber, FAIL / CRITICAL / ERROR / EXPIRED / NON-COMPLIANT red. Return the report file names in the result (`Report = 'name.html'`).
- Data files (module `modules/Portal.Data.psm1`, imported by the runner): `Get-PortalDataFile -Name software|versionBaseline|hardeningBaseline|backup`, `Get-PortalSoftwareSet -Id <set> [-Os windows|linux]` → `@{ id; name; os; packages = @(approved); skipped = @(@{id;name;status;notes}); repository = @{windowsBase; linuxBase} }`.
- Storage (module `modules/Portal.Storage.psm1`, imported by the runner): `Enter-PortalStorageLock -Site -Cluster -By -Reason`, `Exit-PortalStorageLock -Site -Cluster [-Rescanned -By]`, `Get-PortalStorageState -Site -Cluster` (`devices` = last scan).
- Inventory snapshot (read-only): `Read-PortalJson -Path (Join-Path (Get-PortalPath -Name Inventory) "<SITE>.json")` — clusters, hosts, vdSwitches, datastores, datastoreClusters, portgroups (name, vlanId, switch), templates, folders, vms (name, cluster, powerState, numCpu, memoryGB, guestOS). History for forecasts: `data/inventory/history/<SITE>.jsonl` (one JSON per line: date, clusters[name, hosts, cpuGHz, memoryGB, vms, vcpu, vmMemoryGB], datastores[name, capacityGB, freeGB]).
- Do not edit shared modules, `Start-Portal.ps1`, the runner, existing items/handlers or other groups' files. If a shared change is needed, say so in your final report.

## Tests

`tests/handlers/<Group>.Tests.ps1`:

```powershell
. (Join-Path $PSScriptRoot '_TestHelpers.ps1')
Start-TestGroup 'Network and placement'
# PowerCLI stubs: global functions with the cmdlet names the handler uses, returning [pscustomobject] fakes.
function global:Get-VDSwitch { param($Name, $Server) [pscustomobject]@{ Name = $Name } }
...
$ctx = New-TestContext -ItemId 'dpg-create'
$r = Invoke-TestHandler -Handler 'New-VsphereDistributedPortgroup.ps1' -Parameters @{ Site = 'DC1'; ...; Context = $ctx }
Assert-Test -Name 'DPG: created' -Condition ($null -eq $r.Error -and $r.Result.PortGroup -eq 'PG-APP-100') -Detail $r.Error
...
# Remove the stubs at the end so other groups start clean.
'Get-VDSwitch', ... | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
```

Minimum per handler: one happy path and one failing pre-check (assert the error message). Reports: assert the HTML and
CSV files exist (`Get-TestReportFiles -Context $ctx`). Stubs must accept the parameters the handler passes
(use `param($Name, $Server, ...)` or `[Parameter(ValueFromRemainingArguments)] $Rest` + named params you inspect).
Stubs can record calls in `$global:` lists so tests can assert what would have been changed (and that a dry run changed nothing).
