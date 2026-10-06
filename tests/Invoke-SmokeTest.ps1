#Requires -Version 7.2
<#
.SYNOPSIS
    Offline smoke test of the portal engine (no Pode, no vCenter).
.DESCRIPTION
    Copies the portal into a temporary root, injects a fake inventory and a test catalog item whose
    handler does not need vCenter, then exercises: catalog load/validation, role filtering, lookups,
    input validation, request creation, approval rules, dispatcher, out-of-process runner and audit.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$src  = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ("ssportal-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Copy-Item -Path $src -Destination $temp -Recurse
$env:SSP_PORTAL_ROOT = $temp
foreach ($d in 'data/requests', 'data/inventory', 'logs/jobs') { $null = New-Item -ItemType Directory -Path (Join-Path $temp $d) -Force }   # not in a fresh clone
Get-ChildItem (Join-Path $temp 'data/requests') -Filter 'REQ-*' | Remove-Item -Force

'Portal.Core', 'Portal.Security', 'Portal.Vault', 'Portal.Identity', 'Portal.Auth', 'Portal.Data', 'Portal.Catalog', 'Portal.Jobs', 'Portal.Storage', 'Portal.Sites', 'Portal.Cloud', 'Portal.Settings', 'Portal.Web' |
    ForEach-Object { Import-Module (Join-Path $temp "modules/$_.psm1") -Force }
Import-Module (Join-Path $temp "automation/lib/Portal.Vsphere.psm1") -Force
Initialize-PortalConfiguration | Out-Null   # creates config/*.json from *.default.json (first run)

$pass = 0; $fail = 0
function Check([string] $Name, [bool] $Condition) {
    if ($Condition) { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else            { $script:fail++; Write-Host "  [FAIL] $Name" -ForegroundColor Red }
}

Write-Host "`nFirst start" -ForegroundColor Cyan
$vs = Get-PortalVaultStatus
Check 'Vault status works on a new, empty vault (first start)' ($vs.healthy -and $vs.entries -eq 0)

Write-Host "`nWeb pages" -ForegroundColor Cyan
$pages = Get-ChildItem (Join-Path $temp 'web') -Filter '*.html'
Check 'No inline <script> blocks (pages must work under a strict Content-Security-Policy)' (-not ($pages | Where-Object { (Get-Content $_.FullName -Raw) -match '<script(?![^>]*\ssrc=)[^>]*>' }))
Check 'Every <form> uses POST (credentials never in a URL)' (-not ($pages | Where-Object { [regex]::Matches((Get-Content $_.FullName -Raw), '<form[^>]*>') | Where-Object { $_.Value -notmatch 'method="post"' } }))

# --- Fixtures ----------------------------------------------------------------------------------------------
$cfgPath = Join-Path $temp 'config/portal.config.json'
$cfg = Read-PortalJson -Path $cfgPath
$cfg.auth.roleMapping = @{ Admin = @('PortalAdmins'); Approver = @('PortalApprovers'); Requester = @('PortalUsers') }
foreach ($s in $cfg.sites) { $s.enabled = $true }
($cfg.sites | Where-Object code -eq 'DC1').defaults.portgroupFilter = '^dvpg_'
$cfg.jobs.pwshPath = (Get-Process -Id $PID).Path
Write-PortalJson -Path $cfgPath -Value $cfg

Write-PortalJson -Path (Join-Path $temp 'data/inventory/DC1.json') -Value ([ordered]@{
    site = 'DC1'; collectedAt = (Get-PortalTimestamp)
    clusters   = @(@{ name = 'CL-APP-01'; hosts = 8 }, @{ name = 'CL-DB-01'; hosts = 7 }, @{ name = 'LAB-CLUSTER'; hosts = 1 })
    datastores = @(
        @{ name = 'DC1-AP-DS01'; freeGB = 4200; capacityGB = 8192; clusters = @('CL-APP-01'); maintenance = $false; accessible = $true },
        @{ name = 'DC1-AP-DS02'; freeGB = 50;   capacityGB = 8192; clusters = @('CL-APP-01'); maintenance = $false; accessible = $true },
        @{ name = 'DC1-DB-DS01'; freeGB = 3000; capacityGB = 8192; clusters = @('CL-DB-01'); maintenance = $false; accessible = $true })
    datastoreClusters = @()
    portgroups = @(@{ name = 'dvpg_prod_server_trust_504'; vlanId = 504 }, @{ name = 'VM Network'; vlanId = 0 })
    templates  = @(@{ name = 'TPL-WIN2022-STD' }, @{ name = 'TPL-RHEL9' })
    folders    = @(@{ name = 'DC1'; path = 'DC1' }, @{ name = 'Portal-Provisioned'; path = 'DC1/Portal-Provisioned' })
    vms        = @(@{ name = 'APPWEB01'; cluster = 'CL-APP-01' })
})

Set-Content -Path (Join-Path $temp 'automation/handlers/Test-Echo.ps1') -Value @'
param([string] $Site, [string] $Message, [int] $Count, $Context)
Write-JobLog -Level STEP "Echo test for $($Context.RequestId)"
Write-Host "host output captured"
Write-Warning "warning captured"
1..$Count | ForEach-Object { Write-JobLog "iteration $_" }
return @{ Echo = $Message; Count = $Count; Requester = $Context.Requester.username }
'@
Write-PortalJson -Path (Join-Path $temp 'catalog/items/test-echo.json') -Value ([ordered]@{
    id = 'test-echo'; version = '1.0.0'; enabled = $true; name = 'Echo test'; category = 'Test'; summary = 'Test item'
    access = @{ roles = @('Requester') }; approval = @{ required = $true; approverRoles = @('Approver') }
    execution = @{ handler = 'Test-Echo.ps1'; requiresVCenter = $false; timeoutMinutes = 5 }
    inputs = @(
        @{ name = 'Site'; label = 'Site'; type = 'select'; required = $true; source = @{ type = 'sites' } },
        @{ name = 'Message'; label = 'Message'; type = 'text'; required = $true; validation = @{ pattern = '^[a-z ]+$' } },
        @{ name = 'Count'; label = 'Count'; type = 'number'; default = 2; validation = @{ min = 1; max = 5 } })
})
Set-Content -Path (Join-Path $temp 'catalog/items/broken.json') -Value '{ "id": "Broken Item", "version": "1", "name": "x" }'

$requester = Get-PortalUserContext -AuthUser @{ Username = 'jdoe'; Name = 'John Doe'; Domain = 'CORP'; Groups = @('PortalUsers', 'SSP-Team-Infrastructure') }
$approver  = Get-PortalUserContext -AuthUser @{ Username = 'asmith'; Name = 'Ann Smith'; Domain = 'CORP'; Groups = @('PortalApprovers', 'SSP-Team-Infrastructure') }
$admin     = Get-PortalUserContext -AuthUser @{ Username = 'padmin'; Name = 'Portal Admin'; Domain = 'CORP'; Groups = @('CORP\PortalAdmins') }

# --- Tests -------------------------------------------------------------------------------------------------
Write-Host "`nSecurity" -ForegroundColor Cyan
Check 'Requester has only Requester role' (($requester.roles -join ',') -eq 'Requester')
Check 'Admin inherits every role' (($admin.roles -join ',') -eq 'Admin,Approver,CatalogAdmin,Requester,SecurityAdmin,VaultAdmin')

Write-Host "`nLocal accounts" -ForegroundColor Cyan
$loc = Test-PortalLocalCredential -Username 'admin' -Password 'ChangeMe-2026!'
Check 'Shipped local admin authenticates' ([bool]$loc)
Check 'Local admin maps to Admin role set' (((Get-PortalUserContext -AuthUser $loc).roles -join ',') -eq 'Admin,Approver,CatalogAdmin,Requester,SecurityAdmin,VaultAdmin')
Check 'Wrong password rejected' (-not (Test-PortalLocalCredential -Username 'admin' -Password 'nope-nope'))
Check 'Unknown user falls through (no local match)' (-not (Test-PortalLocalCredential -Username 'jdoe' -Password 'x'))
$lc = Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json'); $lc.auth.localUsers.enabled = $false
Write-PortalJson -Path (Join-Path $temp 'config/portal.config.json') -Value $lc
Check 'Disabled provider rejects local admin' (-not (Test-PortalLocalCredential -Username 'admin' -Password 'ChangeMe-2026!'))
$lc.auth.localUsers.enabled = $true; Write-PortalJson -Path (Join-Path $temp 'config/portal.config.json') -Value $lc
Check 'Local users file has no clear-text password' (-not ((Get-Content (Join-Path $temp 'config/local-users.json') -Raw) -match 'ChangeMe-2026'))

Write-Host "`nCatalog" -ForegroundColor Cyan
$cat = Get-PortalCatalog
$shippedFiles = @(Get-ChildItem (Get-PortalPath -Name CatalogItems) -Filter *.json)
Check "Valid items loaded (all shipped items + test item; broken.json rejected)" (@($cat.items).Count -eq ($shippedFiles.Count - 1) -and @($cat.errors).Count -eq 1)
Check 'Broken item reported, not loaded' ((@($cat.errors).file -contains 'broken.json'))
$reqCat = Get-PortalCatalogForUser -User $requester
Check 'Snapshot item hidden from Requester' ((@($reqCat).id -notcontains 'vm-snapshot'))
Check 'Snapshot item visible to Approver' ((@(Get-PortalCatalogForUser -User $approver).id -contains 'vm-snapshot'))
Check 'Public projection hides handler' (-not ($reqCat[0].Contains('execution')))

Write-Host "`nLookups" -ForegroundColor Cyan
$win = Get-PortalCatalogItem -Id 'vm-windows-2025'
$ds = Get-PortalLookupOptions -Item $win -InputName 'Datastore' -Values @{ Site = 'DC1'; Workload = 'App' }
Check 'Datastores follow Workload=App -> APP cluster (+minFreeGB)' ((@($ds).value -join ',') -eq 'DC1-AP-DS01')
$dsDb = Get-PortalLookupOptions -Item $win -InputName 'Datastore' -Values @{ Site = 'DC1'; Workload = 'DB' }
Check 'Datastores follow Workload=DB -> DB cluster' ((@($dsDb).value -join ',') -eq 'DC1-DB-DS01')
Check 'Template is not a requester input' (@($win.inputs.name) -notcontains 'Template' -and @($win.inputs.name) -notcontains 'Cluster')
Check 'Shipped items reference per-site values and team roles, not deployment names' ($win.execution.fixedParameters.Template -eq '@site:windowsTemplate' -and -not (Read-PortalJson -Path (Join-Path $temp 'catalog/items/vm-windows-2025.json')).Contains('sites'))
Set-PortalSiteSettings -Code 'DC2' -Settings @{ catalogValues = @{ windowsTemplate = 'TPL-WIN2025-B' } } -Actor 'test'
Check 'Template resolved per site from sites[].catalogValues' ((Resolve-PortalSiteValue -Value $win.execution.fixedParameters.Template -Site 'DC2') -eq 'TPL-WIN2025-B')
$badCv = try { Set-PortalSiteSettings -Code 'DC2' -Settings @{ catalogValues = @{ notDeclared = 'x' } } -Actor 'test'; $false } catch { $_.Exception.Message -match 'catalog.siteValues' }
Check 'Undeclared catalog value rejected' $badCv
Check 'Team roles resolve to configured team ids' (@($win.access.teams) -join ',' -eq 'Infrastructure')
Check 'Workload DB maps to DC2 DB cluster' ((Get-PortalWorkloadCluster -Site 'DC2' -Workload 'DB') -eq 'CL-DB-02')
$pgs = Get-PortalLookupOptions -Item $win -InputName 'PortGroup' -Values @{ Site = 'DC1' }
Check 'Port groups filtered by site portgroupFilter' ((@($pgs).value -join ',') -eq 'dvpg_prod_server_trust_504')
Check 'Dependent lookup empty without parent' (@(Get-PortalLookupOptions -Item $win -InputName 'Datastore' -Values @{}).Count -eq 0)

Write-Host "`nInput validation" -ForegroundColor Cyan
$good = @{ Site = 'DC1'; VMName = 'apptst01'; Description = 'Test'; Workload = 'App'
           Datastore = 'DC1-AP-DS01'; Folder = 'DC1/Portal-Provisioned'; CpuCount = '4'; MemoryGB = '8'; PortGroup = 'dvpg_prod_server_trust_504'
           IpMode = 'Static'; IPAddress = '10.76.4.50'; SubnetMask = '255.255.254.0'; Gateway = '10.76.4.1'; Owner = 'owner@example.com'; CostCenter = 'CC100'
           NoteApplication = 'CRM'; NoteEnvironment = 'Production' }
$v = Test-PortalRequestInput -Item $win -Submitted $good
Check 'Valid Windows request accepted' $v.valid
Check 'VM name upper-cased by transform' ($v.values.VMName -eq 'APPTST01')
Check 'Default applied (AdditionalDiskGB=0)' ($v.values.AdditionalDiskGB -eq 0)
Check 'Boolean default applied (PowerOn=true)' ($v.values.PowerOn -eq $true)
$bad = $good.Clone(); $bad.Datastore = 'DC1-AP-DS02'; $bad.IPAddress = '10.76.4.999'; $bad.VMName = '1bad_name'; $bad.CpuCount = '64'
$v2 = Test-PortalRequestInput -Item $win -Submitted $bad
Check 'Injected datastore (below minFreeGB) rejected' ($v2.errors.Contains('Datastore'))
Check 'Invalid IP rejected' ($v2.errors.Contains('IPAddress'))
Check 'Invalid VM name rejected' ($v2.errors.Contains('VMName'))
Check 'Out-of-list CPU rejected' ($v2.errors.Contains('CpuCount'))
$dhcp = $good.Clone(); $dhcp.IpMode = 'DHCP'; $dhcp.Remove('IPAddress'); $dhcp.Remove('Gateway')
$v3 = Test-PortalRequestInput -Item $win -Submitted $dhcp
Check 'Hidden fields (visibleWhen) skipped for DHCP' ($v3.valid -and -not $v3.values.Contains('SubnetMask'))

Write-Host "`nWorkflow + execution" -ForegroundColor Cyan
$echo = Get-PortalCatalogItem -Id 'test-echo'
$chk = Test-PortalRequestInput -Item $echo -Submitted @{ Site = 'DC1'; Message = 'hello portal'; Count = '3' }
$req = New-PortalRequest -Item $echo -Values $chk.values -User $requester
Check 'Request requires approval' ($req.status -eq 'PendingApproval')
$selfFail = $false; try { Approve-PortalRequest -Id $req.id -User $requester } catch { $selfFail = $true }
Check 'Requester cannot approve' $selfFail
$null = Approve-PortalRequest -Id $req.id -User $approver -Comment 'ok'
Check 'Approved -> Queued' ((Get-PortalRequest -Id $req.id).status -eq 'Queued')
$badTransition = $false; try { Update-PortalRequest -Id $req.id -Status 'Succeeded' } catch { $badTransition = $true }
Check 'Illegal transition blocked' $badTransition

Invoke-PortalJobDispatcher
Check 'Dispatcher started runner' ((Get-PortalRequest -Id $req.id).status -in 'Dispatched', 'Running', 'Succeeded')
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep -Seconds 1; $st = (Get-PortalRequest -Id $req.id).status } while ($st -notin 'Succeeded', 'Failed' -and (Get-Date) -lt $deadline)
$final = Get-PortalRequest -Id $req.id
Check "Runner completed (status=$($final.status))" ($final.status -eq 'Succeeded')
Check 'Handler result stored' ($final.result.Echo -eq 'hello portal' -and $final.result.Count -eq 3)
$log = Get-PortalRequestLog -Id $req.id
Check 'Job log captures Write-JobLog/Host/Warning' ($log -match 'iteration 3' -and $log -match 'host output captured' -and $log -match 'WARN')
if ($final.status -ne 'Succeeded') { Write-Host $log; Write-Host $final.error }

$req2 = New-PortalRequest -Item $echo -Values $chk.values -User $requester
$null = Stop-PortalRequest -Id $req2.id -User $requester
Check 'Requester can cancel pending request' ((Get-PortalRequest -Id $req2.id).status -eq 'Cancelled')
$view = Get-PortalRequestView -Request (Get-PortalRequest -Id $req.id) -User $requester
Check 'Request view hides execution contract' (-not $view.execution.Contains('handler'))

$audit = Get-Content (Get-PortalPath -Name Audit) | ConvertFrom-Json
Check 'Audit trail recorded (create/approve/dispatch/succeeded/cancel)' ((@('request.create', 'request.approve', 'job.dispatch', 'job.succeeded', 'request.cancel') | Where-Object { $audit.action -notcontains $_ }).Count -eq 0)

Write-Host "`nAdmin: local users" -ForegroundColor Cyan
Set-PortalLocalUserEntry -Username 'ops1' -Roles Requester -Password 'OpsUser-12345-ok' -DisplayName 'Ops One' -New -Actor 'LOCAL\admin'
Check 'Create local user' ((@(Get-PortalLocalUserList).username) -contains 'ops1')
Check 'New user can log in' ([bool](Test-PortalLocalCredential -Username 'ops1' -Password 'OpsUser-12345-ok'))
Set-PortalLocalUserEntry -Username 'ops1' -Enabled $false -Actor 'LOCAL\admin'
Check 'Disabled user cannot log in' (-not (Test-PortalLocalCredential -Username 'ops1' -Password 'OpsUser-12345-ok'))
$selfLock = $false; try { Set-PortalLocalUserEntry -Username 'admin' -Enabled $false -Actor 'LOCAL\admin' } catch { $selfLock = $true }
Check 'Admin cannot disable own account' $selfLock
$shortPw = $false; try { Set-PortalLocalUserEntry -Username 'ops2' -Roles Requester -Password 'short' -Actor 'LOCAL\admin' } catch { $shortPw = $true }
Check 'Short password rejected' $shortPw
Remove-PortalLocalUserEntry -Username 'ops1' -Actor 'LOCAL\admin'
Check 'Delete local user' ((@(Get-PortalLocalUserList).username) -notcontains 'ops1')
Check 'User list exposes no hashes' (-not ((Get-PortalLocalUserList | ConvertTo-Json -Depth 5) -match 'pbkdf2'))

Write-Host "`nAdmin: vCenter connections" -ForegroundColor Cyan
Set-PortalSiteSettings -Code 'DC1' -Settings @{ vcenter = 'vcenter01.corp.example.com'; workloadClusters = @{ App = 'CL-APP-01'; DB = 'CL-DB-01' }; enabled = $true } -Actor 'LOCAL\admin'
Set-PortalSiteCredential -Code 'DC1' -Username 'svc-portal@vsphere.local' -Password 'Secret-123456' -Actor 'LOCAL\admin'
$view = @(Get-PortalSiteView) | Where-Object code -eq 'DC1'
Check 'Site credential stored and reported as configured' ($view.credential.configured -and $view.credential.type -eq 'Vault' -and $view.credential.username -eq 'svc-portal@vsphere.local')
Check 'Site view exposes no password' (-not (($view | ConvertTo-Json -Depth 8) -match 'Secret-123456'))
Check 'Credential readable by runner (Get-PortalCredential)' ((Get-PortalCredential -Site (Get-PortalSite -Code 'DC1')).UserName -eq 'svc-portal@vsphere.local')
Set-PortalSiteSettings -Code 'DC3' -New -Settings @{ vcenter = 'vcenter03.corp.example.com'; name = 'Third Datacenter'; workloadClusters = @{ App = 'G10'; DB = '' } } -Actor 'LOCAL\admin'
Check 'New site added (disabled by default)' ((Get-PortalSite -Code 'DC3') -and -not (Get-PortalSite -Code 'DC3').enabled)
Check 'Config backup written' (@(Get-ChildItem (Join-Path $temp 'config/_backup') -Filter *.json).Count -ge 1)

Write-Host "`nAdmin: catalog editor" -ForegroundColor Cyan
$newItem = [ordered]@{ id = 'test-new-service'; version = '0.1.0'; enabled = $true; name = 'New service'; category = 'Test'; summary = 'Created from the editor'
    access = @{ roles = @('Requester') }; approval = @{ required = $false }
    execution = [ordered]@{ handler = 'Test-NewService.ps1'; requiresVCenter = $false; fixedParameters = @{} }
    inputs = @(@{ name = 'Site'; label = 'Site'; type = 'select'; required = $true; source = @{ type = 'sites' } }, @{ name = 'Target'; label = 'Target'; type = 'text'; required = $true }) }
$v1 = Save-PortalCatalogItem -Item $newItem -Actor 'LOCAL\admin' -New -ValidateOnly
Check 'Validation reports missing handler' ((@($v1.errors) -join ' ') -match 'not found')
$stub = New-PortalHandlerStub -Handler 'Test-NewService.ps1' -Parameters @('Site', 'Target') -RequiresVCenter $false -Actor 'LOCAL\admin'
Check 'Handler stub created' (Test-Path $stub)
$info = @(Get-PortalHandlerInfo -Path $stub)
Check 'Handler inspection lists parameters' ((($info.name) -join ',') -eq 'Site,Target,Context')
$sv = Save-PortalCatalogItem -Item $newItem -Actor 'LOCAL\admin' -New
Check 'New catalog item saved and published' ($sv.saved -and (Get-PortalCatalogItem -Id 'test-new-service'))
$dup = Save-PortalCatalogItem -Item $newItem -Actor 'LOCAL\admin' -New
Check 'Duplicate id rejected in create mode' (-not $dup.saved)
$bad = Read-PortalJson -Path (Join-Path $temp 'catalog/items/vm-windows-2025.json'); $bad.execution.fixedParameters.Remove('Template')
$bs = Save-PortalCatalogItem -Item $bad -Actor 'LOCAL\admin' -ValidateOnly
Check 'Missing mandatory handler param detected (Template)' ((@($bs.errors) -join ' ') -match "Mandatory handler parameter 'Template'")
$outside = $false; try { Resolve-PortalHandlerPath -Handler '/etc/evil.ps1' } catch { $outside = $true }
Check 'Handler outside allowed roots refused' $outside
Remove-PortalCatalogItem -Id 'test-new-service' -Actor 'LOCAL\admin'
Check 'Deleted item archived, not published' (-not (Get-PortalCatalogItem -Id 'test-new-service') -and @(Get-ChildItem (Join-Path $temp 'catalog/_archive') -Filter 'test-new-service*').Count -ge 1)

Write-Host "`nConfig bootstrap / upgrade" -ForegroundColor Cyan
Check 'First run created config from defaults' ((Test-Path (Join-Path $temp 'config/portal.config.json')) -and (Test-Path (Join-Path $temp 'config/local-users.json')))
$old = Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json')
$old.Remove('automation'); foreach ($s in $old.sites) { $s.defaults.Remove('workloadClusters') }
($old.sites | Where-Object code -eq 'DC2').credential = [ordered]@{ type = 'SecretManagement'; vault = 'SspPortalVault'; secret = 'svc-portal-vc-dc2' }
Write-PortalJson -Path (Join-Path $temp 'config/portal.config.json') -Value $old
Initialize-PortalConfiguration | Out-Null
$up = Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json')
$dc2 = $up.sites | Where-Object code -eq 'DC2'
Check 'Upgrade adds automation section' ($up.Contains('automation'))
Check 'Upgrade derives App/DB clusters from allowedClusters' ($dc2.defaults.workloadClusters.App -eq 'CL-APP-02' -and $dc2.defaults.workloadClusters.DB -eq 'CL-DB-02')
Check 'Unregistered vault migrated to portal-managed credential' ($dc2.credential.type -eq 'Vault' -and $dc2.credential.id -eq 'vcenter-dc2')
$noCred = $null; try { Get-PortalCredential -Site (Get-PortalSite -Code 'DC2') } catch { $noCred = $_.Exception.Message }
Check 'Missing credential gives actionable message' ($noCred -match 'Admin > vCenter connections')
Check 'Existing settings preserved on upgrade' ($up.auth.roleMapping.Admin[0] -eq 'PortalAdmins')

Write-Host "`nCloud Ops" -ForegroundColor Cyan
$aws = Get-PortalCatalogItem -Id 'cloud-aws-windows-2025'
$lkErr = $null; try { Get-PortalLookupOptions -Item $aws -InputName 'SubnetId' -Values @{} } catch { $lkErr = $_.Exception.Message }
Check 'Cloud lookup explains disabled connection' ($lkErr -match 'Cloud connections')
Set-PortalCloudSettings -Provider aws -Actor 'LOCAL\admin' -Secret 'AwsSecret-1234567890' -Settings @{
    enabled = $true; accessKeyId = 'AKIAEXAMPLE000000000'; region = 'us-east-1'; vpcId = 'vpc-0a1b2c3d4e5f60718'
    subnets = @(@{ id = 'subnet-0a1b2c3d4e5f60718'; label = 'private-a' }); securityGroupIds = @('sg-0a1b2c3d4e5f60718'); instanceTypes = @('t3.large', 'm6i.large') }
$badVpc = $false; try { Set-PortalCloudSettings -Provider aws -Actor 'LOCAL\admin' -Settings @{ vpcId = 'myvpc' } } catch { $badVpc = $true }
Check 'Invalid VPC id rejected' $badVpc
$cv = @(Get-PortalCloudView) | Where-Object provider -eq 'aws'
Check 'AWS secret stored, not exposed' ($cv.secretConfigured -and -not (($cv | ConvertTo-Json -Depth 10) -match 'AwsSecret'))
$subs = @(Get-PortalLookupOptions -Item $aws -InputName 'SubnetId' -Values @{})
Check 'AWS subnets offered from VPC config' ((@($subs).value -join ',') -eq 'subnet-0a1b2c3d4e5f60718')
$awsReq = Test-PortalRequestInput -Item $aws -Submitted @{ InstanceName = 'awsweb01'; Description = 'x'; InstanceType = 't3.large'; SubnetId = 'subnet-0a1b2c3d4e5f60718'; Owner = 'a@b.com'; CostCenter = 'CC1'; NoteApplication = 'Web'; NoteEnvironment = 'QA' }
Check 'AWS request validates (name upper-cased)' ($awsReq.valid -and $awsReq.values.InstanceName -eq 'AWSWEB01')
$awsBad = Test-PortalRequestInput -Item $aws -Submitted @{ InstanceName = 'awsweb01'; Description = 'x'; InstanceType = 'p5.48xlarge'; SubnetId = 'subnet-ffff'; Owner = 'a@b.com'; CostCenter = 'CC1' }
Check 'Non-allowed instance type / subnet rejected' ($awsBad.errors.Contains('InstanceType') -and $awsBad.errors.Contains('SubnetId'))
$areq = New-PortalRequest -Item $aws -Values $awsReq.values -User $requester
Check 'Cloud request snapshot carries provider and site label' ($areq.execution.cloud -eq 'aws' -and $areq.site -eq 'AWS' -and $areq.target -eq 'AWSWEB01')
$azBad = $false; try { Set-PortalCloudSettings -Provider azure -Actor 'LOCAL\admin' -Settings @{ tenantId = 'not-a-guid' } } catch { $azBad = $true }
Check 'Invalid Azure tenant id rejected' $azBad

Write-Host "`nMigrations" -ForegroundColor Cyan
Copy-Item (Join-Path $temp 'catalog/items/vm-almalinux.json') (Join-Path $temp 'catalog/items/vm-rhel-9.json')
$m = Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json'); $m.Remove('_migrations'); $m.Remove('clouds')
($m.sites | Where-Object code -eq 'DC1').invalidCertificateAction = 'Fail'
Write-PortalJson -Path (Join-Path $temp 'config/portal.config.json') -Value $m
Initialize-PortalConfiguration | Out-Null
$m2 = Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json')
Check 'Certificate policy migrated to Ignore' (($m2.sites | Where-Object code -eq 'DC1').invalidCertificateAction -eq 'Ignore')
Check 'Clouds section added on upgrade' ($m2.Contains('clouds') -and $m2.clouds.Contains('azure'))
Check 'Retired example item archived' (-not (Test-Path (Join-Path $temp 'catalog/items/vm-rhel-9.json')))
Initialize-PortalConfiguration | Out-Null
$migList = @((Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json'))._migrations)
Check 'Migrations run once (idempotent)' ($migList.Count -eq 6 -and @($migList | Select-Object -Unique).Count -eq 6)
Check 'Error detail flattens inner exceptions' ((Get-PortalErrorDetail -ErrorRecord ([Exception]::new('outer', [Exception]::new('inner cause')))) -eq 'outer -> inner cause')

Write-Host "`nTeams" -ForegroundColor Cyan
$cloudUser = Get-PortalUserContext -AuthUser @{ Username = 'cops'; Name = 'Cloud Op'; Domain = 'CORP'; Groups = @('PortalUsers', 'SSP-Team-Cloud') }
Check 'AD team mapping (Infrastructure / Cloud)' ((($requester.teams) -join ',') -eq 'Infrastructure' -and (($cloudUser.teams) -join ',') -eq 'Cloud')
$infraIds = @(Get-PortalCatalogForUser -User $requester).id; $cloudIds = @(Get-PortalCatalogForUser -User $cloudUser).id
Check 'Infrastructure user sees infra items only' (($infraIds -contains 'vm-windows-2025') -and -not ($infraIds | Where-Object { $_ -like 'cloud-*' }))
Check 'Cloud user sees cloud items only' (($cloudIds -contains 'cloud-aws-windows-2025') -and -not ($cloudIds | Where-Object { $_ -like 'vm-*' }))
$teamItems = @(Get-PortalCatalog).items | Where-Object { $_.enabled -and $_.Contains('access') -and $_.access.Contains('teams') -and @($_.access.teams).Count }
Check 'Admin sees every team item' (@(Get-PortalCatalogForUser -User $admin).Count -ge @($teamItems).Count -and @($teamItems).Count -ge 30)
$cloudApprover = Get-PortalUserContext -AuthUser @{ Username = 'capp'; Name = 'Cloud Approver'; Domain = 'CORP'; Groups = @('PortalApprovers', 'SSP-Team-Cloud') }
$winItem = Get-PortalCatalogItem -Id 'vm-windows-2025'
$infraReq = New-PortalRequest -Item $winItem -Values (Test-PortalRequestInput -Item $winItem -Submitted $good).values -User $requester
Check 'Request carries item teams' ((@($infraReq.teams) -join ',') -eq 'Infrastructure')
Check 'Cloud approver cannot approve Infrastructure request' (-not (Test-PortalCanApprove -Request $infraReq -User $cloudApprover))
Check 'Infrastructure approver can approve Infrastructure request' (Test-PortalCanApprove -Request $infraReq -User $approver)
Set-PortalLocalUserEntry -Username 'cloud1' -Roles Requester -Teams Cloud -Password 'CloudUser-12345-ok' -New -Actor 'LOCAL\admin'
$lu = Get-PortalUserContext -AuthUser (Test-PortalLocalCredential -Username 'cloud1' -Password 'CloudUser-12345-ok')
Check 'Local user teams applied' ((($lu.teams) -join ',') -eq 'Cloud')
$badTeam = $false; try { Set-PortalLocalUserEntry -Username 'x1x' -Roles Requester -Teams Nope -Password 'Whatever-12345-ok' -Actor 'LOCAL\admin' } catch { $badTeam = $true }
Check 'Unknown team rejected' $badTeam

Write-Host "`nVM notes" -ForegroundColor Cyan
$noteInputs = @($winItem.inputs | Where-Object { $_.Contains('isNote') })
Check 'Build item gets VM notes section from config' ($noteInputs.Count -ge 4 -and $noteInputs[0].name -eq 'NoteApplication')
$noNote = $good.Clone(); $noNote.Remove('NoteApplication')
$nv = Test-PortalRequestInput -Item $winItem -Submitted $noNote
Check 'Required note enforced' ($nv.errors.Contains('NoteApplication'))
Check 'Request snapshot has note labels' (@($infraReq.execution.vmNotes).Count -ge 4 -and $infraReq.inputs.NoteEnvironment -eq 'Production')
Check 'Day-2 items have no notes section' (-not (@((Get-PortalCatalogItem -Id 'vm-resize').inputs) | Where-Object { $_.Contains('isNote') }))

Write-Host "`nCustomization" -ForegroundColor Cyan
Set-PortalSettings -Actor 'LOCAL\admin' -Settings @{ branding = @{ productName = 'Acme Cloud Portal'; organization = 'Acme'; primaryColor = '#112233'; accentColor = '#445566' } }
$br = Get-PortalBranding
Check 'Branding saved and exposed' ($br.productName -eq 'Acme Cloud Portal' -and $br.primaryColor -eq '#112233' -and -not $br.Contains('logoFile'))
$badColor = $false; try { Set-PortalSettings -Actor 'LOCAL\admin' -Settings @{ branding = @{ primaryColor = 'red' } } } catch { $badColor = $true }
Check 'Invalid color rejected' $badColor
$inUse = $false; try { Set-PortalSettings -Actor 'LOCAL\admin' -Settings @{ teams = @(@{ id = 'Infrastructure'; name = 'Infra'; adGroups = @() }) } } catch { $inUse = $_.Exception.Message -match 'Cloud' }
Check 'Cannot delete a team used by catalog items' $inUse
Set-PortalSettings -Actor 'LOCAL\admin' -Settings @{ vmNotes = @{ enabled = $true; title = 'Build notes'; fields = @(@{ key = 'Project'; label = 'Project code'; type = 'text'; required = $true }) } }
$w2 = Get-PortalCatalogItem -Id 'vm-windows-2025'
Check 'VM notes fields editable live' (@($w2.inputs | Where-Object { $_.Contains('isNote') }).name -join ',' -eq 'NoteProject')
$png = 'data:image/png;base64,' + [Convert]::ToBase64String([byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0,0))
Set-PortalBrandLogo -DataUrl $png -Actor 'LOCAL\admin'
Check 'Logo stored and served' ((Get-PortalLogoPath) -and (Get-PortalBranding).logoUrl -like '/brand/logo*')
$svg = $false; try { Set-PortalBrandLogo -DataUrl 'data:image/svg+xml;base64,PHN2Zy8+' -Actor 'LOCAL\admin' } catch { $svg = $true }
Check 'SVG logo refused' $svg
Set-PortalSettings -Actor 'LOCAL\admin' -Settings @{ policies = @{ allowSelfApproval = $true; localUsersEnabled = $true; sessionDurationMinutes = 240 } }
$selfReq = New-PortalRequest -Item $echo -Values $chk.values -User $approver
Check 'Self-approval policy applied live' (Test-PortalCanApprove -Request $selfReq -User $approver)

Write-Host "`nUpgrade from pre-teams release" -ForegroundColor Cyan
$legacy = Read-PortalJson -Path (Join-Path $temp 'catalog/items/cloud-aws-almalinux.json'); $legacy.access.Remove('teams'); $legacy.Remove('vmNotes'); $legacy.id = 'legacy-aws'
Write-PortalJson -Path (Join-Path $temp 'catalog/items/legacy-aws.json') -Value $legacy
$lu = Read-PortalJson -Path (Join-Path $temp 'config/local-users.json'); foreach ($u in $lu.users) { $u.Remove('teams') }
Write-PortalJson -Path (Join-Path $temp 'config/local-users.json') -Value $lu
Update-PortalConfig -Mutate { param($c) $c['_migrations'] = @($c._migrations | Where-Object { $_ -ne 'team-scopes-2026-10' }) }
Initialize-PortalTeamScopes
$la = Read-PortalJson -Path (Join-Path $temp 'catalog/items/legacy-aws.json')
Check 'Existing cloud item scoped to the cloud team role with notes' ((@($la.access.teams) -join ',') -eq '@cloud' -and $la.vmNotes -eq $true)
$lu2 = Read-PortalJson -Path (Join-Path $temp 'config/local-users.json')
Check 'Existing local users keep full visibility' (@($lu2.users | Where-Object { -not $_.Contains('teams') -or @($_.teams).Count -lt 2 }).Count -eq 0)
Initialize-PortalTeamScopes
Check 'Team scope migration runs once' (@(@((Read-PortalJson -Path (Join-Path $temp 'config/portal.config.json'))._migrations) | Where-Object { $_ -eq 'team-scopes-2026-10' }).Count -eq 1)

Write-Host "`nVault" -ForegroundColor Cyan
Set-PortalVaultEntry -Id 'guest-win' -Name 'Windows guest admin' -Type UsernamePassword -Username 'Administrator' -Secret 'Gu3st-Secret-Value!' `
    -Scope @{ items = @('test-cred'); teams = @() } -Actor 'LOCAL\admin' -New
$rawVault = Get-Content (Join-Path $temp 'data/vault/vault.json') -Raw
Check 'Vault file never contains clear-text secrets' (-not ($rawVault -match 'Gu3st-Secret-Value|Secret-123456'))
Check 'Site credential lives in the vault' ((Get-PortalVaultEntry -Id 'vcenter-dc1').username -eq 'svc-portal@vsphere.local')
Set-PortalVaultEntry -Id 'guest-win' -Secret 'Gu3st-Secret-Value-2!' -Actor 'LOCAL\admin'
$gv = Get-PortalVaultEntry -Id 'guest-win'
Check 'Secret rotation keeps version history' ($gv.version -eq 2 -and $gv.versions -eq 1)
Check 'Entry view exposes no secret' (-not (($gv | ConvertTo-Json -Depth 5) -match 'Gu3st|"data"'))
$scopeDenied = $false; try { $null = Get-PortalVaultCredential -Id 'guest-win' -Purpose item -ItemId 'test-echo' } catch { $scopeDenied = $true }
Check 'Vault scope: item not in scope is refused' $scopeDenied
$sysDenied = $false; try { $null = Get-PortalVaultCredential -Id 'guest-win' -Purpose site } catch { $sysDenied = $true }
Check 'Vault scope: non-system entry refused for platform use' $sysDenied
Check 'Vault scope: system entry usable for the site connection' ((Get-PortalVaultCredential -Id 'vcenter-dc1' -Purpose site).GetNetworkCredential().Password -eq 'Secret-123456')
$inUse = $false; try { Remove-PortalVaultEntry -Id 'vcenter-dc1' -Actor 'LOCAL\admin' } catch { $inUse = $_.Exception.Message -match 'site:DC1' }
Check 'Referenced vault entry cannot be deleted' $inUse
$badId = $false; try { Set-PortalVaultEntry -Id 'Bad Id' -Type ApiToken -Secret 'x' -Actor 'LOCAL\admin' -New } catch { $badId = $true }
Check 'Invalid vault id rejected' $badId

Set-Content -Path (Join-Path $temp 'automation/handlers/Test-Cred.ps1') -Value @'
param([string] $Site, [pscredential] $GuestCredential, $Context)
Write-JobLog "user=$($GuestCredential.UserName) secret=$($GuestCredential.GetNetworkCredential().Password)"
return @{ User = $GuestCredential.UserName; Length = $GuestCredential.GetNetworkCredential().Password.Length }
'@
Write-PortalJson -Path (Join-Path $temp 'catalog/items/test-cred.json') -Value ([ordered]@{
    id = 'test-cred'; version = '1.0.0'; enabled = $true; name = 'Credential test'; category = 'Test'; summary = 'Test item'
    access = @{ roles = @('Requester') }; approval = @{ required = $true; approverRoles = @('Approver') }
    execution = @{ handler = 'Test-Cred.ps1'; requiresVCenter = $false; timeoutMinutes = 5 }
    inputs = @(
        @{ name = 'Site'; label = 'Site'; type = 'select'; required = $true; source = @{ type = 'sites' } },
        @{ name = 'GuestCredential'; label = 'Guest account'; type = 'credential'; required = $true })
})
$credItem = Get-PortalCatalogItem -Id 'test-cred'
Check 'Credential input item is valid' ([bool]$credItem)
$credOpts = @(Get-PortalLookupOptions -Item $credItem -InputName 'GuestCredential')
Check 'Credential input lists only in-scope vault entries' ((@($credOpts.value) -join ',') -eq 'guest-win')
$badCred = Test-PortalRequestInput -Item $credItem -Submitted @{ Site = 'DC1'; GuestCredential = 'vcenter-dc1' }
Check 'Out-of-scope vault id rejected at submission' ($badCred.errors.Contains('GuestCredential'))
$credChk = Test-PortalRequestInput -Item $credItem -Submitted @{ Site = 'DC1'; GuestCredential = 'guest-win' }
$credReq = New-PortalRequest -Item $credItem -Values $credChk.values -User $requester
$vaultApprover = Get-PortalUserContext -AuthUser @{ Username = 'vkeeper'; Name = 'Vault Keeper'; Domain = 'CORP'; PortalRoles = @('Approver', 'VaultAdmin'); PortalTeams = @() }
Check 'SoD: VaultAdmin cannot approve a job that uses vault credentials' (-not (Test-PortalCanApprove -Request $credReq -User $vaultApprover))
Check 'SoD: regular approver can' (Test-PortalCanApprove -Request $credReq -User $approver)
$null = Approve-PortalRequest -Id $credReq.id -User $approver -Comment 'ok'
Invoke-PortalJobDispatcher
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep -Seconds 1; $st = (Get-PortalRequest -Id $credReq.id).status } while ($st -notin 'Succeeded', 'Failed' -and (Get-Date) -lt $deadline)
$credFinal = Get-PortalRequest -Id $credReq.id
$credLog = Get-PortalRequestLog -Id $credReq.id
Check "Runner hands the vault credential to the handler (status=$($credFinal.status))" ($credFinal.status -eq 'Succeeded' -and $credFinal.result.User -eq 'Administrator' -and $credFinal.result.Length -eq 21)
Check 'Job log masks the secret' (-not ($credLog -match 'Gu3st-Secret') -and $credLog -match 'secret=\*{8}')
if ($credFinal.status -ne 'Succeeded') { Write-Host $credLog; Write-Host $credFinal.error }
Check 'Vault use audited with request id' (@(Get-Content (Get-PortalPath -Name Audit) | ConvertFrom-Json | Where-Object { $_.action -eq 'vault.use' -and $_.details.request -eq $credReq.id }).Count -ge 1)

Write-Host "`nPassword policy" -ForegroundColor Cyan
$weak = $false; try { Set-PortalLocalUserEntry -Username 'pol1' -Roles Requester -Password 'alllowercase-long' -New -Actor 'LOCAL\admin' } catch { $weak = $_.Exception.Message -match 'of: lowercase' }
Check 'Complexity enforced' $weak
$hasName = $false; try { Set-PortalLocalUserEntry -Username 'pol1' -Roles Requester -Password 'Pol1-Passw0rd-xyz' -New -Actor 'LOCAL\admin' } catch { $hasName = $_.Exception.Message -match 'username' }
Check 'Password containing the username refused' $hasName
Set-PortalLocalUserEntry -Username 'pol1' -Roles Requester -Password 'First-Passw0rd-xyz' -New -Actor 'LOCAL\admin'
Check 'Password set by an admin must be changed at sign-in' ((Test-PortalLocalCredential -Username 'pol1' -Password 'First-Passw0rd-xyz').MustChangePassword)
$reuse = $false; try { Set-PortalOwnPassword -Username 'LOCAL\pol1' -CurrentPassword 'First-Passw0rd-xyz' -NewPassword 'First-Passw0rd-xyz' } catch { $reuse = $true }
Check 'Same password refused' $reuse
Set-PortalOwnPassword -Username 'LOCAL\pol1' -CurrentPassword 'First-Passw0rd-xyz' -NewPassword 'Second-Passw0rd-xyz'
Check 'Self-service change clears the flag' (-not (Test-PortalLocalCredential -Username 'pol1' -Password 'Second-Passw0rd-xyz').MustChangePassword)
Set-PortalOwnPassword -Username 'LOCAL\pol1' -CurrentPassword 'Second-Passw0rd-xyz' -NewPassword 'Third-Passw0rd-xyz'
$hist = $false; try { Set-PortalOwnPassword -Username 'LOCAL\pol1' -CurrentPassword 'Third-Passw0rd-xyz' -NewPassword 'First-Passw0rd-xyz' } catch { $hist = $_.Exception.Message -match 'last' }
Check 'Password history enforced' $hist
$wrongCur = $false; try { Set-PortalOwnPassword -Username 'LOCAL\pol1' -CurrentPassword 'nope' -NewPassword 'Fourth-Passw0rd-xyz' } catch { $wrongCur = $true }
Check 'Current password required' $wrongCur

Write-Host "`nSign-in, lockout and sessions" -ForegroundColor Cyan
$ok = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.10'
Check 'Local sign-in returns a one-time ticket' ($ok.ok -and $ok.ticket)
Check 'Ticket bound to client IP' (-not (Use-PortalLoginTicket -Ticket $ok.ticket -Ip '10.9.9.9'))
$ok2 = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.10'
$au = Use-PortalLoginTicket -Ticket $ok2.ticket -Ip '10.1.1.10'
Check 'Ticket redeems to the auth user with a session id' ($au -and $au.Sid -and $au.Username -eq 'pol1')
Check 'Ticket is single-use' (-not (Use-PortalLoginTicket -Ticket $ok2.ticket -Ip '10.1.1.10'))
$fake = @{ RemoteIp = '10.1.1.10'; Headers = @{}; Auth = @{ User = $au } }
$api = Invoke-PortalApi -WebEvent $fake -Action { param($u) $u.username }
Check 'API call with a live session succeeds' ($api.Status -eq 200 -and $api.Body -eq 'LOCAL\pol1')
$re = Invoke-PortalApi -WebEvent $fake -RequireReauth -Action { 'x' }
Check 'Fresh sign-in counts as recent authentication' ($re.Status -eq 200)
$sessFile = Join-Path $temp 'data/security/sessions.json'
$ss = Read-PortalJson -Path $sessFile; $ss[$au.Sid].reauthAt = [datetime]::UtcNow.AddMinutes(-30).ToString('o'); Write-PortalJson -Path $sessFile -Value $ss
$re2 = Invoke-PortalApi -WebEvent $fake -RequireReauth -Action { 'x' }
Check 'Sensitive action asks for re-authentication' ($re2.Status -eq 401 -and $re2.Body.fields.code -eq 'REAUTH_REQUIRED')
$null = Confirm-PortalReauthentication -User (Get-PortalUserContext -AuthUser $au) -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.10'
Check 'Re-authentication re-opens the window' ((Invoke-PortalApi -WebEvent $fake -RequireReauth -Action { 'x' }).Status -eq 200)
$ss = Read-PortalJson -Path $sessFile; $before = $ss[$au.Sid].lastActivity
$ss[$au.Sid].lastActivity = [datetime]::UtcNow.AddMinutes(-20).ToString('o'); Write-PortalJson -Path $sessFile -Value $ss
$bg = @{ RemoteIp = '10.1.1.10'; Headers = @{ 'X-Portal-Background' = '1' }; Auth = @{ User = $au } }
$null = Invoke-PortalApi -WebEvent $bg -Action { 'x' }
Check 'Background polling does not count as activity' ((Read-PortalJson -Path $sessFile)[$au.Sid].lastActivity -eq $ss[$au.Sid].lastActivity)
$ss = Read-PortalJson -Path $sessFile; $ss[$au.Sid].lastActivity = [datetime]::UtcNow.AddMinutes(-31).ToString('o'); Write-PortalJson -Path $sessFile -Value $ss
$idle = Invoke-PortalApi -WebEvent $fake -Action { 'x' }
Check 'Idle timeout (30 min) ends the session' ($idle.Status -eq 401 -and $idle.Body.fields.code -eq 'SESSION_IDLE')
Check 'Ended session stays ended' ((Invoke-PortalApi -WebEvent $fake -Action { 'x' }).Body.fields.code -eq 'SESSION_EXPIRED')
$noSid = Invoke-PortalApi -WebEvent @{ RemoteIp = '1.1.1.1'; Headers = @{}; Auth = @{ User = @{ Username = 'x'; Domain = 'LOCAL'; PortalRoles = @('Requester') } } } -Action { 'x' }
Check 'Session without a server record is rejected' ($noSid.Status -eq 401)

Set-PortalLocalUserEntry -Username 'pol2' -Roles Requester -Password 'Temp-Passw0rd-abc' -New -Actor 'LOCAL\admin'
$t2 = Invoke-PortalLogin -Username 'pol2' -Password 'Temp-Passw0rd-abc' -Ip '10.1.1.11'
$au2 = Use-PortalLoginTicket -Ticket $t2.ticket -Ip '10.1.1.11'
$f2 = @{ RemoteIp = '10.1.1.11'; Headers = @{}; Auth = @{ User = $au2 } }
$blocked = Invoke-PortalApi -WebEvent $f2 -Action { 'x' }
Check 'Pending password change blocks the API' ($blocked.Status -eq 403 -and $blocked.Body.fields.code -eq 'PASSWORD_CHANGE_REQUIRED')
Check '...but account self-service stays available' ((Invoke-PortalApi -WebEvent $f2 -AllowRestricted -Action { 'x' }).Status -eq 200)
Revoke-PortalSession -Username 'LOCAL\pol2' -Actor 'LOCAL\admin'
Check 'Revoked session is refused' ((Invoke-PortalApi -WebEvent $f2 -AllowRestricted -Action { 'x' }).Body.fields.code -eq 'SESSION_REVOKED')

1..5 | ForEach-Object { $null = Invoke-PortalLogin -Username 'pol1' -Password 'wrong-password' -Ip '10.1.1.12' }
$locked = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.12'
Check 'Lockout after 5 failures (even with the right password)' (-not $locked.ok -and $locked.message -match 'Too many')
Check 'Lockout listed for administrators' (@(Get-PortalLockoutList | Where-Object { $_.name -eq 'pol1' }).Count -eq 1)
Clear-PortalLockout -Key 'u:pol1' -Actor 'LOCAL\admin'
Check 'Unlock restores sign-in' ((Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.12').ok)
$unknown = Invoke-PortalLogin -Username 'nobody' -Password 'whatever-123' -Ip '10.1.1.13'
Check 'Unknown and wrong-password users get the same message' ($unknown.message -eq 'Invalid username or password.')

Write-Host "`nMFA (TOTP)" -ForegroundColor Cyan
Check 'RFC 6238 test vector (SHA1, T=59)' ((Get-PortalTotpCode -Secret ([Text.Encoding]::ASCII.GetBytes('12345678901234567890')) -Step 1) -eq '287082')
Check 'Base32 round trip' ((ConvertTo-Base32 ([Text.Encoding]::ASCII.GetBytes('foobar'))) -eq 'MZXW6YTBOI' -and [Text.Encoding]::ASCII.GetString((ConvertFrom-Base32 'MZXW6YTBOI')) -eq 'foobar')
$en = Start-PortalMfaEnrollment -Username 'LOCAL\pol1'
Check 'Enrolment returns an otpauth URI' ($en.uri -like 'otpauth://totp/*secret=*')
$sec = ConvertFrom-Base32 $en.secret
$badEnroll = $false; try { $null = Complete-PortalMfaEnrollment -Username 'LOCAL\pol1' -Code '000000' } catch { $badEnroll = $true }
Check 'Wrong code does not enrol' $badEnroll
$rc = @(Complete-PortalMfaEnrollment -Username 'LOCAL\pol1' -Code (Get-PortalTotpCode -Secret $sec -Step ((Get-TotpStep) - 1)))
Check 'Enrolment issues 10 recovery codes' ($rc.Count -eq 10)
Check 'MFA seed stored encrypted' (-not ((Get-Content (Join-Path $temp 'data/security/mfa.json') -Raw) -match $en.secret))
$m1 = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Ip '10.1.1.14'
Check 'Password alone is not enough once enrolled' (-not $m1.ok -and $m1.next -eq 'mfa')
$code = Get-PortalTotpCode -Secret $sec -Step (Get-TotpStep)
$m2 = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Otp $code -Ip '10.1.1.14'
Check 'Password + TOTP signs in' ($m2.ok)
$m3 = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Otp $code -Ip '10.1.1.14'
Check 'A TOTP code cannot be replayed' (-not $m3.ok)
$m4 = Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Otp $rc[0] -Ip '10.1.1.14'
Check 'Recovery code signs in' ($m4.ok)
Check 'Recovery code is single-use' (-not (Invoke-PortalLogin -Username 'pol1' -Password 'Third-Passw0rd-xyz' -Otp $rc[0] -Ip '10.1.1.14').ok)
Clear-PortalLockout -Key 'u:pol1' -Actor 'LOCAL\admin'
$tA = Invoke-PortalLogin -Username 'admin' -Password 'ChangeMe-2026!' -Ip '10.1.1.15'
$auA = Use-PortalLoginTicket -Ticket $tA.ticket -Ip '10.1.1.15'
$gate = Invoke-PortalApi -WebEvent @{ RemoteIp = '10.1.1.15'; Headers = @{}; Auth = @{ User = $auA } } -Action { 'x' }
Check 'Admin without authenticator is sent to MFA enrolment (after password change)' ($gate.Status -eq 403 -and $gate.Body.fields.code -in 'PASSWORD_CHANGE_REQUIRED', 'MFA_ENROLLMENT_REQUIRED')
Check 'MFA required for administrative roles' (Test-PortalMfaRequired -User $admin)
Check 'MFA optional for requesters' (-not (Test-PortalMfaRequired -User $requester))

Write-Host "`nPermissions and networks" -ForegroundColor Cyan
$catAdmin = Get-PortalUserContext -AuthUser @{ Username = 'cadm'; Domain = 'CORP'; PortalRoles = @('CatalogAdmin', 'Requester') }
Check 'CatalogAdmin manages the catalog' (Test-PortalPermission -User $catAdmin -Permission 'catalog.manage')
Check 'CatalogAdmin cannot open the vault' (-not (Test-PortalPermission -User $catAdmin -Permission 'vault.manage'))
Check 'VaultAdmin cannot manage security' (-not (Test-PortalPermission -User $vaultApprover -Permission 'security.manage'))
Check 'CIDR matching (IPv4/IPv6)' ((Test-PortalIpInCidr -Ip '10.20.30.40' -Cidr '10.20.0.0/16') -and -not (Test-PortalIpInCidr -Ip '10.21.0.1' -Cidr '10.20.0.0/16') -and (Test-PortalIpInCidr -Ip 'fd00::5' -Cidr 'fd00::/64'))
$lockMe = $false; try { Set-PortalSecurityPolicy -Policy @{ adminAllowedCidrs = @('192.168.50.0/24') } -Actor 'LOCAL\admin' -ActorIp '10.1.1.1' } catch { $lockMe = $_.Exception.Message -match 'lock you out' }
Check 'Admin network that excludes the caller is refused' $lockMe
Set-PortalSecurityPolicy -Policy @{ adminAllowedCidrs = @('10.1.0.0/16') } -Actor 'LOCAL\admin' -ActorIp '10.1.1.1'
$adm2 = Get-PortalUserContext -AuthUser @{ Username = 'padmin'; Domain = 'CORP'; Groups = @('PortalAdmins') } -ClientIp '172.16.0.9'
Check 'Admin roles dropped outside the admin networks' (-not ($adm2.roles -contains 'Admin') -and $adm2.networkRestricted)
$adm3 = Get-PortalUserContext -AuthUser @{ Username = 'padmin'; Domain = 'CORP'; Groups = @('PortalAdmins') } -ClientIp '10.1.200.3'
Check '...and kept inside them' ($adm3.roles -contains 'Admin')
Set-PortalSecurityPolicy -Policy @{ adminAllowedCidrs = @() } -Actor 'LOCAL\admin'
$badPol = $false; try { Set-PortalSecurityPolicy -Policy @{ session = @{ idleTimeoutMinutes = 1 } } -Actor 'LOCAL\admin' } catch { $badPol = $true }
Check 'Idle timeout range validated' $badPol

Write-Host "`nIdentity providers" -ForegroundColor Cyan
Set-PortalVaultEntry -Id 'ldap-bind' -Type UsernamePassword -Username 'uid=svc-portal,ou=people,dc=example,dc=org' -Secret 'Svc-Passw0rd!' -Scope @{ system = $true } -Actor 'LOCAL\admin' -New
$ldapHost = if ($env:SSP_TEST_LDAP_HOST) { $env:SSP_TEST_LDAP_HOST } else { '127.0.0.1' }
Set-PortalIdentityProvider -Provider ([ordered]@{ id = 'lab'; name = 'Lab OpenLDAP'; enabled = $true; flavor = 'openldap'; domains = @('example.org', 'LAB')
    hosts = @($ldapHost); port = [int]$(if ($env:SSP_TEST_LDAP_PORT) { $env:SSP_TEST_LDAP_PORT } else { 3636 }); security = 'ldaps'; baseDn = 'dc=example,dc=org'
    bindMode = 'search'; bindCredential = 'ldap-bind'; usernamePrefix = 'LAB'; tls = @{ verify = $true } }) -New -Actor 'LOCAL\admin'
$badProv = $false; try { Set-PortalIdentityProvider -Provider @{ id = 'x'; flavor = 'ad'; hosts = @('dc'); baseDn = 'DC=x'; security = 'none' } -Actor 'LOCAL\admin' } catch { $badProv = $true }
Check 'Unencrypted LDAP refused without allowInsecure' $badProv
Check 'Routing: DOMAIN\user -> provider' ((Resolve-PortalLoginTarget -Username 'LAB\alice').provider.id -eq 'lab')
Check 'Routing: user@domain -> provider' ((Resolve-PortalLoginTarget -Username 'alice@example.org').provider.id -eq 'lab')
Check 'Routing: existing local account stays local' ((Resolve-PortalLoginTarget -Username 'admin').kind -eq 'local')
Check 'Routing: unknown domain is rejected' (-not (Resolve-PortalLoginTarget -Username 'alice@unknown.test'))
Check 'LDAP filter escaping (RFC 4515)' ((ConvertTo-PortalLdapFilterValue 'a*(b)\c') -eq 'a\2a\28b\29\5cc')
if ($env:SSP_TEST_LDAP_CA -or $env:LDAPTLS_CACERT) {
    $cfgT = Read-PortalJson -Path $cfgPath
    $cfgT.auth.roleMapping['Admin'] = @(@($cfgT.auth.roleMapping['Admin']) + 'SSP-Admins'); $cfgT.auth.roleMapping['Requester'] = @(@($cfgT.auth.roleMapping['Requester']) + 'SSP-Requesters')
    $cloudTeam = $cfgT.teams | Where-Object { $_.id -eq 'Cloud' }; $cloudTeam.adGroups = @(@($cloudTeam.adGroups) + 'SSP-Team-Cloud')
    Write-PortalJson -Path $cfgPath -Value $cfgT
    $lt = Test-PortalIdentityProvider -Id 'lab' -LookupUser 'bob'
    Check 'LDAP test connection (service bind + user lookup)' ($lt.ok -and (@($lt.steps)[-1].groups -contains 'SSP-Team-Cloud'))
    $lb = Invoke-PortalLogin -Username 'LAB\bob' -Password 'Bob-Passw0rd!' -Ip '10.2.0.1'
    $lbu = Use-PortalLoginTicket -Ticket $lb.ticket -Ip '10.2.0.1'
    $lctx = Get-PortalUserContext -AuthUser $lbu
    Check 'OpenLDAP sign-in maps groups to role and team' ($lb.ok -and $lctx.username -eq 'LAB\bob' -and $lctx.roles -contains 'Requester' -and $lctx.teams -contains 'Cloud')
    Check 'OpenLDAP wrong password refused' (-not (Invoke-PortalLogin -Username 'bob@example.org' -Password 'nope-nope-nope' -Ip '10.2.0.1').ok)
    $la = Invoke-PortalLogin -Username 'alice@example.org' -Password 'Alice-Passw0rd!' -Ip '10.2.0.2'
    $lau = Use-PortalLoginTicket -Ticket $la.ticket -Ip '10.2.0.2'
    $lag = Invoke-PortalApi -WebEvent @{ RemoteIp = '10.2.0.2'; Headers = @{}; Auth = @{ User = $lau } } -Action { 'x' }
    Check 'Directory admin must enrol MFA before using the portal' ($la.ok -and $lag.Body.fields.code -eq 'MFA_ENROLLMENT_REQUIRED')
}
else { Write-Host '  [SKIP] live LDAP tests (set LDAPTLS_CACERT / SSP_TEST_LDAP_* to a test directory)' -ForegroundColor DarkYellow }

Write-Host "`nReview fixes" -ForegroundColor Cyan
Check 'SoD also applies to Admin (implies VaultAdmin)' (-not (Test-PortalCanApprove -Request (New-PortalRequest -Item $credItem -Values $credChk.values -User $requester) -User $admin))
Check 'Lockout key is canonical (DOMAIN\u, u@d, u)' ((& (Get-Module Portal.Auth) { Get-LockKey 'CORP\JDoe' }) -eq (& (Get-Module Portal.Auth) { Get-LockKey 'jdoe@corp.example.com' }))
$riItem = [ordered]@{ id = 'x'; inputs = @(@{ name = 'A'; type = 'text'; requireReauth = $true }) }
Check 'Input-level requireReauth applies to submission' (Test-PortalItemRequiresReauth -Item $riItem)
$sw = [Diagnostics.Stopwatch]::StartNew(); $null = Test-PortalLocalCredential -Username 'no-such-user' -Password 'x'; $t1 = $sw.ElapsedMilliseconds
Check 'Unknown local user costs as much as a wrong password' ($t1 -ge 700)
if ($env:SSP_TEST_LDAP_CA -or $env:LDAPTLS_CACERT) {
    $lb2 = Invoke-PortalLogin -Username 'bob@example.org' -Password 'Bob-Passw0rd!' -Ip '10.2.0.9'
    $bobCtx = Get-PortalUserContext -AuthUser (Use-PortalLoginTicket -Ticket $lb2.ticket -Ip '10.2.0.9')
    Check 'Directory user can re-authenticate against own provider' ((Confirm-PortalReauthentication -User $bobCtx -Password 'Bob-Passw0rd!' -Ip '10.2.0.9').ok)
}

Write-Host "`nPhase 3 platform: data files, lookups, storage rescan, reports" -ForegroundColor Cyan
Check 'Data files created at first start (software, baselines, backup)' (@('software', 'version-baseline', 'hardening-baseline', 'backup' | Where-Object { Test-Path (Join-Path $temp "config/$_.json") }).Count -eq 4)
Check 'Shipped data files are valid' (-not @(Get-PortalDataFileList | Where-Object { @(Test-PortalDataFile -Name $_.name -Content $_.content).Count }).Count)
$cfgNow = Get-PortalConfig -Force
Check 'Operations settings present (storage cooldown 10 min)' ($cfgNow.Contains('operations') -and $cfgNow.operations.storage.rescanCooldownMinutes -eq 10)
$swJson = Get-Content (Join-Path $temp 'config/software.json') -Raw
$bad = $swJson | ConvertFrom-Json -AsHashtable; $bad.packages += $bad.packages[0]
$dfErr = try { Set-PortalDataFile -Name software -Json ($bad | ConvertTo-Json -Depth 20) -Actor 'admin'; $null } catch { @($_.Exception.Data['errors']) }
Check 'Invalid data file rejected with reasons (duplicate package)' ($dfErr -and ($dfErr -join ' ') -match 'Duplicate package')
$ok = $swJson | ConvertFrom-Json -AsHashtable; ($ok.packages | Where-Object id -eq 'monitoring-agent-win').status = 'Approved'
Set-PortalDataFile -Name software -Json ($ok | ConvertTo-Json -Depth 20) -Actor 'admin'
Check 'Data file saved with backup copy' (@(Get-ChildItem (Join-Path $temp 'config/_backup') -Filter 'software.*.json' -ErrorAction SilentlyContinue).Count -ge 1)
$set = @(Get-PortalSoftwareSet -Os windows) | Select-Object -First 1
Check 'Software set: only Approved packages installable, others listed as skipped' ($set -and @($set.packages).id -contains 'monitoring-agent-win' -and @($set.skipped).Count -ge 1)
Check 'Backup agent stays pending (not installable)' (-not (@(Get-PortalSoftwareSet) | ForEach-Object { @($_.packages).id } | Where-Object { $_ -match 'backup' }))

$abItem = Get-PortalCatalogItem -Id 'agent-baseline'
Check 'Lookup softwareSets' (@(Get-PortalLookupOptions -Item $abItem -InputName 'BaselineSet' -Values @{ Site = 'DC1' }).Count -ge 1)
$bpItem = Get-PortalCatalogItem -Id 'backup-policy'
Check 'Lookup backupPolicies (vendor-agnostic)' (@(Get-PortalLookupOptions -Item $bpItem -InputName 'Policy' -Values @{ Site = 'DC1' }).value -contains 'Gold')

$invPath = Join-Path $temp 'data/inventory/DC1.json'
$inv = Read-PortalJson -Path $invPath
$inv['hosts'] = @(
    [ordered]@{ name = 'esx01.test'; cluster = 'CL-APP-01'; connectionState = 'Connected'; maintenance = $false; version = '8.0.3'; build = 24022510 },
    [ordered]@{ name = 'esx02.test'; cluster = 'CL-APP-01'; connectionState = 'Connected'; maintenance = $true; version = '8.0.3'; build = 24022510 },
    [ordered]@{ name = 'esx09.test'; cluster = 'CL-DB-01'; connectionState = 'Connected'; maintenance = $false; version = '8.0.3'; build = 24022510 })
$inv['vdSwitches'] = @([ordered]@{ name = 'DVS-PROD'; version = '8.0.0'; hosts = 3 })
Write-PortalJson -Path $invPath -Value $inv
$hmItem = Get-PortalCatalogItem -Id 'host-maintenance'
$hostOpts = @(Get-PortalLookupOptions -Item $hmItem -InputName 'HostName' -Values @{ Site = 'DC1'; Cluster = 'CL-APP-01' })
Check 'Lookup hosts filtered by cluster' ($hostOpts.Count -eq 2 -and $hostOpts.value -notcontains 'esx09.test')
Check 'Host maintenance is Admin-only with re-authentication' (-not (Test-PortalItemAccess -Item $hmItem -User $requester) -and (Test-PortalItemRequiresReauth -Item $hmItem))

$dsItem = Get-PortalCatalogItem -Id 'datastore-create'
Check 'New datastore requires re-authentication' (Test-PortalItemRequiresReauth -Item $dsItem)
$noScan = try { $null = Get-PortalLookupOptions -Item $dsItem -InputName 'Lun' -Values @{ Site = 'DC1'; Cluster = 'CL-APP-01' }; '' } catch { $_.Exception.Message }
Check 'LUN lookup never rescans by itself (asks for an explicit rescan)' ($noScan -match 'Rescan storage')
$st1 = Start-PortalStorageRescan -Site 'DC1' -Cluster 'CL-APP-01' -User $requester -Ip '10.9.9.9' -Rescan -ItemId 'datastore-create'
Check 'Rescan starts (out of process) and locks the cluster' ($st1.running -and $st1.lockedBy -eq $requester.username)
$e409 = try { $null = Start-PortalStorageRescan -Site 'DC1' -Cluster 'CL-APP-01' -User $admin -Ip '10.9.9.8' -Rescan; 0 } catch { [int]$_.Exception.Data['status'] }
Check 'Second rescan while running is refused (409)' ($e409 -eq 409)
for ($i = 0; $i -lt 60 -and (Get-PortalStorageView -Site 'DC1' -Cluster 'CL-APP-01').running; $i++) { Start-Sleep -Milliseconds 500 }
$v2 = Get-PortalStorageView -Site 'DC1' -Cluster 'CL-APP-01'
Check 'Scan without vCenter ends Failed and releases the lock' (-not $v2.running -and $v2.state -eq 'Failed')
$e429 = try { $null = Start-PortalStorageRescan -Site 'DC1' -Cluster 'CL-APP-01' -User $admin -Ip '10.9.9.8' -Rescan; 0 } catch { [int]$_.Exception.Data['status'] }
Check 'Rescan inside the 10-minute cooldown is refused (429)' ($e429 -eq 429 -and $v2.cooldownSeconds -gt 500)
$aud = @(Get-Content (Get-PortalPath -Name Audit) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object action -eq 'storage.rescan')
Check 'Rescan audited with user, time and IP' ($aud.Count -eq 1 -and $aud[0].actor -eq $requester.username -and $aud[0].details.ip -eq '10.9.9.9')
Complete-PortalStorageScan -Site 'DC1' -Cluster 'CL-APP-01' -Devices @(
    [ordered]@{ canonicalName = 'naa.600a0b80001'; sizeGB = 2048; vendor = 'PURE'; model = 'FlashArray'; allHosts = $true },
    [ordered]@{ canonicalName = 'naa.600a0b80002'; sizeGB = 1024; vendor = 'PURE'; model = 'FlashArray'; allHosts = $false }) -Hosts @('esx01.test')
$lunOpts = @(Get-PortalLookupOptions -Item $dsItem -InputName 'Lun' -Values @{ Site = 'DC1'; Cluster = 'CL-APP-01' })
Check 'LUN lookup lists only devices visible to every host (with scan timestamp)' ($lunOpts.Count -eq 1 -and $lunOpts[0].value -eq 'naa.600a0b80001' -and $lunOpts[0].label -match 'scanned')
Enter-PortalStorageLock -Site 'DC1' -Cluster 'CL-APP-01' -By 'job-1'
$lockErr = try { Enter-PortalStorageLock -Site 'DC1' -Cluster 'CL-APP-01' -By 'job-2'; '' } catch { $_.Exception.Message }
Exit-PortalStorageLock -Site 'DC1' -Cluster 'CL-APP-01'
Check 'Job handlers share the per-cluster lock' ($lockErr -match 'already running' -and -not (Get-PortalStorageView -Site 'DC1' -Cluster 'CL-APP-01').running)

$authz = [ordered]@{ by = $requester.username; at = (Get-PortalTimestamp); ip = '10.9.9.9'; reauthenticated = $true }
$tItem = (Get-PortalCatalog).items | Where-Object { $_.id -eq 'vm-snapshot' } | Select-Object -First 1
$rq = New-PortalRequest -Item $tItem -Values ([ordered]@{ Site = 'DC1'; VMName = 'APPWEB01'; ChangeTicket = 'CHG1'; RetentionDays = 3 }) -User $requester -Authorization $authz
Check 'Request keeps re-authentication evidence (who / when / IP)' ((Get-PortalRequest -Id $rq.id).authorization.ip -eq '10.9.9.9')
Import-Module (Join-Path $temp 'automation/lib/Portal.Report.psm1') -Force
$rctx = [pscustomobject]@{ RequestId = $rq.id; ReportDir = (Get-PortalReportDir -Id $rq.id) }
$files = New-PortalReport -Title 'Test report' -Context $rctx -Sections @(New-PortalReportSection -Title 'Rows' -Rows @([ordered]@{ Name = '<script>alert(1)</script>'; Status = 'FAIL' }))
$html = Get-Content (Join-Path $rctx.ReportDir 'test-report.html') -Raw
Check 'Report written as HTML + CSV, values encoded' (@($files).Count -eq 2 -and $html -notmatch '<script>alert' -and $html -match 's-fail')
Check 'Request lists its reports; path traversal rejected' (@(Get-PortalRequestReport -Id $rq.id).Count -eq 2 -and -not (Get-PortalRequestReport -Id $rq.id -Name '../x.html'))
Check 'Request view exposes reports' (@((Get-PortalRequestView -Request (Get-PortalRequest -Id $rq.id) -User $requester).reports).Count -eq 2)

Write-Host "`nUpgrade: legacy Windows-AD configuration" -ForegroundColor Cyan
$legacy = Read-PortalJson -Path $cfgPath
$legacy.auth.Remove('providers'); $legacy.auth.Remove('defaultProvider'); $legacy.Remove('security'); $legacy.Remove('vault')
$legacy.auth['provider'] = 'WindowsAD'; $legacy.auth['fqdn'] = 'corp.example.com'; $legacy.auth['domain'] = 'CORP'
$legacy.portal['sessionDurationMinutes'] = 600
Write-PortalJson -Path $cfgPath -Value $legacy
Initialize-PortalConfiguration | Out-Null
$up2 = Read-PortalJson -Path $cfgPath
$adp = @($up2.auth.providers)[0]
Check 'Legacy AD login becomes an LDAP provider' ($adp.id -eq 'ad' -and $adp.baseDn -eq 'DC=corp,DC=example,DC=com' -and $adp.usernamePrefix -eq 'CORP' -and $adp.security -eq $(if ($IsWindows) { 'negotiate' } else { 'ldaps' }))
Check 'Session duration carried into security.session' ($up2.security.session.absoluteTimeoutMinutes -eq 600 -and -not $up2.portal.Contains('sessionDurationMinutes'))
Check 'New admin roles added to role mapping' ($up2.auth.roleMapping.Contains('VaultAdmin') -and $up2.vault.keyProvider -eq 'auto')

Write-Host "`nUpgrade: deployment without catalog team roles / site values" -ForegroundColor Cyan
$oldCat = Read-PortalJson -Path $cfgPath
$oldCat.Remove('catalog'); foreach ($s in $oldCat.sites) { $s.Remove('catalogValues') }
$oldCat.teams = @([ordered]@{ id = 'OpsTeamA'; name = 'Ops A'; adGroups = @() }, [ordered]@{ id = 'CloudTeamB'; name = 'Cloud B'; adGroups = @() })
Write-PortalJson -Path $cfgPath -Value $oldCat
Initialize-PortalConfiguration | Out-Null
$upCat = Read-PortalJson -Path $cfgPath
Check 'Team roles mapped to the existing teams' ($upCat.catalog.teamRoles.datacenter -eq 'OpsTeamA' -and $upCat.catalog.teamRoles.cloud -eq 'CloudTeamB')
Check 'Every site receives the declared catalog values (TBD placeholders)' (@($upCat.sites | Where-Object { $_.catalogValues.windowsTemplate -like 'TBD-*' }).Count -eq @($upCat.sites).Count)

Write-Host ("`nResult: {0} passed, {1} failed  (temp root: {2})" -f $pass, $fail, $temp) -ForegroundColor ($fail ? 'Red' : 'Green')
exit $fail
