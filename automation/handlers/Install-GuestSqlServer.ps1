#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - installs a SQL Server 2022 Database Engine instance inside an existing Windows Server VM.
.DESCRIPTION
    Everything runs inside the guest through VMware Tools guest operations (Invoke-VMScript, module
    automation/lib/Portal.Guest.psm1); no WinRM is needed. Also called directly by the three-tier blueprint, so the
    parameter names are a contract.

    Flow: pre-checks (Windows Server, VMware Tools, setup.exe reachable, instance not present, disks)
          -> disk preparation (optional): the first four RAW disks by disk number become
             D: data, E: logs, F: backup, T: tempdb (GPT, NTFS, 64 KB allocation unit); a CD-ROM holding one of
             these letters is moved to a free letter
          -> unattended setup with a generated ConfigurationFile.ini (written to a guest temp folder that is
             removed in a finally block, it may hold the service account password)
          -> post-configuration (max server memory, MAXDOP, cost threshold 50, backup compression) via sqlcmd,
             or .NET SqlClient when sqlcmd is not present
          -> verification (service running, SELECT @@VERSION).
    If the instance already exists, disk preparation and setup are skipped and only the post-configuration is
    re-applied (idempotent re-run).

    Media: InstallerPath (fixed per site) is a folder with the extracted ISO content (setup.exe). Setup runs from
    that path INSIDE the guest as the guest credential user, so that account must be able to read the share
    (domain account with read access; a local account cannot authenticate to a UNC share).
    The guest credential account is added to SQLSYSADMINACCOUNTS (needed for the post-configuration); remove it
    after handover if your policy requires.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [string] $InstanceName = 'MSSQLSERVER',
    [string] $Collation = 'SQL_Latin1_General_CP1_CI_AS',
    [Parameter(Mandatory)] [string] $SysAdminGroup,
    [pscredential] $SqlServiceCredential,
    [int] $MaxDop = 0,
    [int] $MaxServerMemoryMB = 0,
    [bool] $PrepareDisks = $true,
    [int] $TempDbFiles = 0,
    [Parameter(Mandatory)] [string] $InstallerPath,
    [string] $ProductKey,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
function Q([string] $v) { ConvertTo-PortalGuestLiteral -Value $v }

#region 1. Input validation (no guest access yet) -------------------------------------------------------------
Write-JobLog -Level STEP 'Validating parameters'
if ($InstanceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$') { throw "Instance name '$InstanceName' is not valid: 1-16 characters, start with a letter; letters, digits and underscore." }
if ($InstanceName -ne 'MSSQLSERVER' -and @('DEFAULT', 'MSSQLSERVERADHELPER', 'MSSQLSERVERADHELPER100', 'SQLSERVER') -contains $InstanceName.ToUpperInvariant()) { throw "Instance name '$InstanceName' is reserved." }
if ($Collation -notmatch '^[A-Za-z0-9_]+$') { throw "Collation '$Collation' is not valid." }
if ($SysAdminGroup -notmatch '^[A-Za-z0-9._-]+\\[A-Za-z0-9 ._$-]+$') { throw "SQL sysadmin group '$SysAdminGroup' must be DOMAIN\Group (letters, digits, space, dot, underscore, hyphen)." }
if ($MaxDop -lt 0 -or $MaxDop -gt 64) { throw 'MaxDop must be between 0 (auto) and 64.' }
if ($TempDbFiles -lt 0 -or $TempDbFiles -gt 32) { throw 'TempDbFiles must be between 0 (auto) and 32.' }
if ($MaxServerMemoryMB -lt 0) { throw 'MaxServerMemoryMB must be 0 (auto) or a positive number of MB.' }
if (-not $InstallerPath -or $InstallerPath -like 'TBD-*') { throw "SQL Server installation media is not configured for site $Site (fixed parameter InstallerPath = '$InstallerPath'). Set the UNC folder with the extracted SQL Server 2022 media in the catalog item." }
if ($InstallerPath -match '["\r\n]') { throw 'InstallerPath contains invalid characters.' }
if ($ProductKey -and $ProductKey -notmatch '^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$') { throw 'ProductKey must have the form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (empty = edition of the media: Developer / Evaluation).' }
$secrets = @()
$svcUser = $null
if ($SqlServiceCredential) {
    $svcUser = $SqlServiceCredential.UserName
    $svcPw = $SqlServiceCredential.GetNetworkCredential().Password
    if ($svcUser -notmatch '^[A-Za-z0-9._-]+\\[A-Za-z0-9._$-]+$|^[A-Za-z0-9._$-]+@[A-Za-z0-9.-]+$') { throw "SQL service account '$svcUser' must be DOMAIN\user, DOMAIN\gMSA$ or user@domain." }
    if ($svcPw -match '["\r\n]') { throw 'The SQL service account password contains a double quote or line break, which the SQL Server configuration file cannot carry. Change the password in the vault entry.' }
    $secrets += $svcPw
}
$isDefault = $InstanceName -ieq 'MSSQLSERVER'
$svcName   = if ($isDefault) { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
$agentSvc  = if ($isDefault) { 'SQLSERVERAGENT' } else { "SQLAgent`$$InstanceName" }
$sqlTarget = if ($isDefault) { 'localhost' } else { "localhost\$InstanceName" }
#endregion

#region 2. Guest pre-checks -----------------------------------------------------------------------------------
Write-JobLog -Level STEP "Pre-checks on $VMName"
$g = Resolve-PortalGuestVM -Name $VMName -Server $vi -ExpectedFamily windows
$vm = $g.VM
Write-JobLog "Guest OS (VMware Tools): $($g.OSFullName)"

$factsScript = @"
`$os = Get-CimInstance Win32_OperatingSystem
`$cs = Get-CimInstance Win32_ComputerSystem
`$raw = @(Get-Disk | Where-Object { `$_.PartitionStyle -eq 'RAW' } | Sort-Object Number | ForEach-Object { [ordered]@{ Number = [int]`$_.Number; SizeGB = [math]::Round(`$_.Size / 1GB, 1); Offline = [bool]`$_.IsOffline } })
`$vols = @(Get-Volume | Where-Object { `$_.DriveLetter } | ForEach-Object { [ordered]@{ Letter = [string]`$_.DriveLetter; Type = [string]`$_.DriveType; FileSystem = [string]`$_.FileSystem } })
`$setup = Join-Path $(Q $InstallerPath) 'setup.exe'
`$facts = [ordered]@{
    Caption     = [string]`$os.Caption
    ProductType = [int]`$os.ProductType
    Cores       = [int]`$cs.NumberOfLogicalProcessors
    TotalMB     = [int][math]::Floor(`$cs.TotalPhysicalMemory / 1MB)
    RawDisks    = `$raw
    Volumes     = `$vols
    SetupFound  = [bool](Test-Path -LiteralPath `$setup)
    InstanceExists = [bool](Get-Service -Name $(Q $svcName) -ErrorAction SilentlyContinue)
    Account     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
}
Write-Output ('__SSP_JSON=' + (ConvertTo-Json -InputObject `$facts -Compress -Depth 5))
"@
$facts = Get-PortalGuestData -Output (Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $factsScript -Type PowerShell -TimeoutSeconds 300 -Description 'collect facts')

if ([int]$facts.ProductType -eq 1 -or [string]$facts.Caption -notmatch 'Windows Server') { throw "$VMName runs '$($facts.Caption)'. SQL Server is installed on Windows Server only." }
$cores = [int]$facts.Cores; $totalMB = [int]$facts.TotalMB
Write-JobLog "Guest: $($facts.Caption), $cores logical processors, $totalMB MB RAM; running as $($facts.Account)"
$instanceExists = [bool]$facts.InstanceExists
if (-not $instanceExists -and -not $facts.SetupFound) {
    throw "setup.exe was not found in '$InstallerPath' from inside $VMName. Check that the folder holds the extracted SQL Server 2022 media and that $($facts.Account) can read the share."
}

# Effective settings.
$effMaxDop  = if ($MaxDop -gt 0) { $MaxDop } else { [math]::Max(1, [math]::Min(8, $cores)) }
$effTempDb  = if ($TempDbFiles -gt 0) { $TempDbFiles } else { [math]::Max(1, [math]::Min(8, $cores)) }
if ($MaxServerMemoryMB -gt 0) {
    if ($MaxServerMemoryMB -ge $totalMB) { throw "MaxServerMemoryMB ($MaxServerMemoryMB) must be lower than the VM memory ($totalMB MB)." }
    $effMem = $MaxServerMemoryMB
}
else {
    $effMem = $totalMB - [math]::Max(4096, [int][math]::Ceiling($totalMB * 0.10))
    if ($effMem -lt 1024) { Write-JobLog -Level WARN "VM memory ($totalMB MB) leaves less than 1 GB for SQL Server after the OS reserve; max server memory set to 1024 MB. Add memory to the VM."; $effMem = 1024 }
}
Write-JobLog "Settings: MAXDOP $effMaxDop, max server memory $effMem MB, tempdb files $effTempDb, collation $Collation"

$plan = @(
    [ordered]@{ Letter = 'D'; Label = 'SQLData';   Folder = 'D:\MSSQL\Data' }
    [ordered]@{ Letter = 'E'; Label = 'SQLLogs';   Folder = 'E:\MSSQL\Logs' }
    [ordered]@{ Letter = 'F'; Label = 'SQLBackup'; Folder = 'F:\MSSQL\Backup' }
    [ordered]@{ Letter = 'T'; Label = 'SQLTempDB'; Folder = 'T:\MSSQL\TempDB' }
)
$diskSummary = @()
if ($instanceExists) {
    Write-JobLog -Level WARN "Instance $InstanceName already exists on ${VMName}: disk preparation and setup are skipped, the post-configuration is re-applied."
}
elseif ($PrepareDisks) {
    $raw = @($facts.RawDisks)
    if ($raw.Count -lt 4) {
        $found = if ($raw.Count) { ($raw | ForEach-Object { "disk $($_.Number) ($($_.SizeGB) GB)" }) -join ', ' } else { 'none' }
        throw "PrepareDisks needs 4 RAW (uninitialized) disks, used in disk-number order for D: data, E: logs, F: backup, T: tempdb. Found $($raw.Count): $found. Add the missing disks to $VMName (e.g. with the 'Add disk' item) or set PrepareDisks = false when D:, E:, F: and T: already exist."
    }
    foreach ($l in $plan.Letter) {
        $used = @($facts.Volumes) | Where-Object { $_.Letter -eq $l } | Select-Object -First 1
        if ($used -and $used.Type -ne 'CD-ROM') { throw "Drive letter ${l}: is already used by a $($used.Type) volume on $VMName; free it or set PrepareDisks = false." }
    }
}
else {
    $missing = @($plan.Letter | Where-Object { $l = $_; -not (@($facts.Volumes) | Where-Object { $_.Letter -eq $l -and $_.Type -eq 'Fixed' }) })
    if ($missing) { throw "PrepareDisks is false but drive(s) $(($missing | ForEach-Object { "${_}:" }) -join ', ') do not exist on $VMName. Create them (NTFS, 64 KB allocation unit) or set PrepareDisks = true." }
    $diskSummary = @($plan | ForEach-Object { "$($_.Letter): existing volume" })
}
#endregion

#region 3. Disk preparation -----------------------------------------------------------------------------------
if (-not $instanceExists -and $PrepareDisks) {
    Write-JobLog -Level STEP 'Preparing data disks (GPT, NTFS 64 KB)'
    $planLiteral = ($plan | ForEach-Object { "@{ L = $(Q $_.Letter); Label = $(Q $_.Label) }" }) -join ', '
    $diskScript = @"
`$plan = @($planLiteral)
`$raw = @(Get-Disk | Where-Object { `$_.PartitionStyle -eq 'RAW' } | Sort-Object Number)
if (`$raw.Count -lt 4) { throw "Only `$(`$raw.Count) RAW disks found; 4 are needed (D, E, F, T)." }
`$reserved = @(`$plan | ForEach-Object { `$_.L })
foreach (`$l in `$reserved) {
    `$v = Get-Volume -DriveLetter `$l -ErrorAction SilentlyContinue
    if (-not `$v) { continue }
    if ([string]`$v.DriveType -ne 'CD-ROM') { throw "Drive letter `${l}: is used by a `$(`$v.DriveType) volume." }
    `$free = @(90..71 | ForEach-Object { [string][char]`$_ } | Where-Object { `$reserved -notcontains `$_ -and -not (Get-Volume -DriveLetter `$_ -ErrorAction SilentlyContinue) }) | Select-Object -First 1
    Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='`${l}:'" | Set-CimInstance -Property @{ DriveLetter = "`${free}:" }
    Write-Output "CD-ROM moved from `${l}: to `${free}:"
}
for (`$i = 0; `$i -lt 4; `$i++) {
    `$d = `$raw[`$i]
    if (`$d.IsOffline)  { Set-Disk -Number `$d.Number -IsOffline `$false }
    if (`$d.IsReadOnly) { Set-Disk -Number `$d.Number -IsReadOnly `$false }
    Initialize-Disk -Number `$d.Number -PartitionStyle GPT
    `$p = New-Partition -DiskNumber `$d.Number -UseMaximumSize -DriveLetter `$plan[`$i].L
    `$null = Format-Volume -Partition `$p -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel `$plan[`$i].Label -Confirm:`$false
    Write-Output ('__SSP_KV:Disk' + `$i + '=' + `$plan[`$i].L + ': disk ' + `$d.Number + ' ' + [math]::Round(`$d.Size / 1GB, 1) + ' GB NTFS 64K ' + `$plan[`$i].Label)
}
"@
    $out = Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $diskScript -Type PowerShell -TimeoutSeconds 900 -Description 'prepare disks D/E/F/T'
    $kv = Get-PortalGuestData -Output $out
    $diskSummary = @(0..3 | ForEach-Object { [string]$kv["Disk$_"] } | Where-Object { $_ })
    $diskSummary | ForEach-Object { Write-JobLog -Level OK $_ }
}
#endregion

#region 4. Setup ----------------------------------------------------------------------------------------------
$sysAdmins = @($SysAdminGroup)
if ($facts.Account -and $facts.Account -ine $SysAdminGroup) { $sysAdmins += [string]$facts.Account }
$rebootRequired = $false
if (-not $instanceExists) {
    Write-JobLog -Level STEP "Installing SQL Server instance $InstanceName from $InstallerPath"
    $svcAccount = if ($svcUser) { $svcUser } else { "NT Service\$svcName" }
    $agtAccount = if ($svcUser) { $svcUser } else { "NT Service\$agentSvc" }
    $ini = [System.Collections.Generic.List[string]]::new()
    $ini.Add('; SQL Server 2022 configuration file generated by the self-service portal')
    $ini.Add("; Request $($Context.RequestId)")
    $ini.Add('[OPTIONS]')
    $ini.Add('ACTION="Install"')
    $ini.Add('FEATURES=SQLENGINE')
    $ini.Add("INSTANCENAME=`"$InstanceName`"")
    $ini.Add("INSTANCEID=`"$InstanceName`"")
    $ini.Add("SQLCOLLATION=`"$Collation`"")
    $ini.Add('SQLSYSADMINACCOUNTS=' + (($sysAdmins | ForEach-Object { "`"$_`"" }) -join ' '))
    $ini.Add("SQLSVCACCOUNT=`"$svcAccount`"")
    if ($svcUser) { $ini.Add("SQLSVCPASSWORD=`"$svcPw`"") }
    $ini.Add('SQLSVCSTARTUPTYPE="Automatic"')
    $ini.Add('SQLSVCINSTANTFILEINIT="True"')
    $ini.Add("AGTSVCACCOUNT=`"$agtAccount`"")
    if ($svcUser) { $ini.Add("AGTSVCPASSWORD=`"$svcPw`"") }
    $ini.Add('AGTSVCSTARTUPTYPE="Automatic"')
    $ini.Add('INSTALLSQLDATADIR="D:\"')
    $ini.Add('SQLUSERDBDIR="D:\MSSQL\Data"')
    $ini.Add('SQLUSERDBLOGDIR="E:\MSSQL\Logs"')
    $ini.Add('SQLBACKUPDIR="F:\MSSQL\Backup"')
    $ini.Add('SQLTEMPDBDIR="T:\MSSQL\TempDB"')
    $ini.Add('SQLTEMPDBLOGDIR="T:\MSSQL\TempDB"')
    $ini.Add("SQLTEMPDBFILECOUNT=`"$effTempDb`"")
    $ini.Add('TCPENABLED="1"')
    $ini.Add('NPENABLED="0"')
    $ini.Add('UpdateEnabled="False"')
    $ini.Add('IACCEPTSQLSERVERLICENSETERMS="True"')
    $ini.Add('SUPPRESSPRIVACYSTATEMENTNOTICE="True"')
    $ini.Add('QUIET="True"')
    if ($ProductKey) { $ini.Add("PID=`"$ProductKey`"") }
    $iniText = $ini -join "`r`n"
    if ($ProductKey) { $secrets += $ProductKey }

    $folders = ($plan | ForEach-Object { Q $_.Folder }) -join ', '
    $installScript = @"
`$dir = Join-Path `$env:TEMP ('ssp-sql-' + [guid]::NewGuid().ToString('N'))
`$null = New-Item -ItemType Directory -Path `$dir -Force
try {
    foreach (`$f in @($folders)) { `$null = New-Item -ItemType Directory -Path `$f -Force }
    `$ini = Join-Path `$dir 'ConfigurationFile.ini'
    Set-Content -LiteralPath `$ini -Value $(Q $iniText) -Encoding Unicode
    `$setup = Join-Path $(Q $InstallerPath) 'setup.exe'
    if (-not (Test-Path -LiteralPath `$setup)) { throw "setup.exe not found at `$setup" }
    `$p = Start-Process -FilePath `$setup -ArgumentList ('/ConfigurationFile="' + `$ini + '"') -Wait -PassThru -NoNewWindow
    Write-Output ('__SSP_KV:SetupExit=' + `$p.ExitCode)
    if (`$p.ExitCode -ne 0 -and `$p.ExitCode -ne 3010) {
        `$sum = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if (`$sum) { Get-Content -LiteralPath `$sum.FullName -Tail 25 | ForEach-Object { Write-Output `$_ } }
        throw "SQL Server setup failed with exit code `$(`$p.ExitCode). See Setup Bootstrap\Log\Summary.txt in the guest."
    }
}
finally { Remove-Item -LiteralPath `$dir -Recurse -Force -ErrorAction SilentlyContinue }
"@
    $out = Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $installScript -Type PowerShell -TimeoutSeconds 5400 `
        -Description "SQL Server setup ($InstanceName)" -Sensitive:([bool]($svcUser -or $ProductKey)) -Secrets $secrets
    $exit = [string](Get-PortalGuestData -Output $out)['SetupExit']
    if ($exit -eq '3010') { $rebootRequired = $true; Write-JobLog -Level WARN 'Setup completed; a guest restart is required to finish (exit 3010).' }
    Write-JobLog -Level OK "SQL Server setup completed (exit $exit)"
}
#endregion

#region 5. Post-configuration and verification ----------------------------------------------------------------
Write-JobLog -Level STEP 'Applying instance configuration'
$tsql = @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', $effMem;
EXEC sp_configure 'max degree of parallelism', $effMaxDop;
EXEC sp_configure 'cost threshold for parallelism', 50;
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;
SELECT '__SSP_KV:Version=' + REPLACE(REPLACE(CAST(@@VERSION AS nvarchar(4000)), CHAR(13), ' '), CHAR(10), ' ');
SELECT '__SSP_KV:ProductVersion=' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) + ' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128));
"@
$postScript = @"
`$svc = Get-Service -Name $(Q $svcName) -ErrorAction SilentlyContinue
if (-not `$svc) { throw 'Service $svcName was not found after setup.' }
if (`$svc.Status -ne 'Running') { Start-Service -Name $(Q $svcName); `$svc.WaitForStatus('Running', [TimeSpan]::FromMinutes(3)) }
`$server = $(Q $sqlTarget)
`$tsql = $(Q $tsql)
`$sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (`$sqlcmd) {
    `$out = & `$sqlcmd.Source -S `$server -E -b -h -1 -W -C -Q (`$tsql -replace '\r?\n', ' ') 2>&1
    `$code = `$LASTEXITCODE
    `$out | ForEach-Object { Write-Output ([string]`$_) }
    if (`$code -ne 0) { throw "sqlcmd failed with exit code `$code" }
    Write-Output '__SSP_KV:Client=sqlcmd'
}
else {
    `$cn = New-Object System.Data.SqlClient.SqlConnection ('Server=' + `$server + ';Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=30')
    `$cn.Open()
    try {
        foreach (`$stmt in (`$tsql -split "\r?\n" | Where-Object { `$_.Trim() })) {
            `$cmd = `$cn.CreateCommand(); `$cmd.CommandText = `$stmt; `$cmd.CommandTimeout = 120
            `$r = `$cmd.ExecuteReader()
            try { while (`$r.Read()) { Write-Output ([string]`$r.GetValue(0)) } } finally { `$r.Close() }
        }
    }
    finally { `$cn.Close() }
    Write-Output '__SSP_KV:Client=SqlClient'
}
Write-Output ('__SSP_KV:ServiceStatus=' + (Get-Service -Name $(Q $svcName)).Status)
"@
$out  = Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $postScript -Type PowerShell -TimeoutSeconds 600 -Description 'post-configuration and verification'
$post = Get-PortalGuestData -Output $out
if ([string]$post['ServiceStatus'] -ne 'Running') { throw "SQL Server service $svcName is '$($post['ServiceStatus'])' after configuration." }
$version = [string]$post['Version']
if (-not $version) { throw 'SELECT @@VERSION returned nothing; the instance is not answering.' }
Write-JobLog -Level OK "Instance answering ($($post['Client'])): $($post['ProductVersion'])"
#endregion

$next = [System.Collections.Generic.List[string]]::new()
$next.Add("Install account $($facts.Account) is sysadmin (needed for the post-configuration); remove its login after handover if your policy requires.")
if ($rebootRequired) { $next.Add('Restart the VM to complete the SQL Server installation (setup returned 3010).') }
$next.Add('Apply the latest SQL Server 2022 cumulative update (UpdateEnabled=False during setup).')

return [ordered]@{
    VMName            = $VMName
    Instance          = $(if ($isDefault) { $VMName } else { "$VMName\$InstanceName" })
    Version           = [string]$post['ProductVersion']
    VersionDetail     = $version
    AlreadyInstalled  = $instanceExists
    Disks             = @($diskSummary)
    Collation         = $Collation
    ServiceAccount    = $(if ($svcUser) { $svcUser } else { "NT Service\$svcName (virtual account)" })
    SysAdmins         = @($sysAdmins)
    MaxDop            = $effMaxDop
    MaxServerMemoryMB = $effMem
    TempDbFiles       = $effTempDb
    CostThreshold     = 50
    BackupCompression = 'On'
    RebootRequired    = $rebootRequired
    NextSteps         = @($next)
}
