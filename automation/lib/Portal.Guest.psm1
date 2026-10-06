#Requires -Version 7.2
<#
.SYNOPSIS
    Portal.Guest - run scripts INSIDE a VM through VMware Tools guest operations (Invoke-VMScript).
.DESCRIPTION
    Used by the "Software installation" handlers. No WinRM / SSH dependency: the vCenter session opens the guest
    operation with a guest credential chosen from the portal vault.

    Reliable exit codes: Invoke-VMScript only reports the exit code of the interpreter it launched, which is not
    always the exit code of the script (PowerShell swallows errors, Bash returns the last command). Every script is
    therefore wrapped so that it prints a sentinel line "__SSP_EXIT=<code>" as its last output line; the code is parsed
    and a non-zero (or missing) code throws with the last 20 output lines.

    PowerShell scripts run in Windows PowerShell 5.1 inside the guest (write 5.1 compatible code). The wrapper runs the
    script in a background job (Start-Job, local child process, no WinRM) so -TimeoutSeconds can be enforced.
    Bash scripts are written to a 0600 temp file, run with `timeout`, through `sudo -n` when the guest user is not
    root and passwordless sudo is available, and the file is removed afterwards.

    Secrets: Invoke-VMScript has no channel other than the script text, so a secret (service account password) has
    to be embedded in the script. Such calls MUST use -Sensitive (the script text is never logged) and pass the
    secret in -Secrets so it is redacted from error messages. PowerCLI stores the script in a guest temp file for the
    duration of the call and deletes it; handlers delete any file they write in the guest in a finally block.

    Structured data: scripts print "__SSP_JSON=<compressed json>" or "__SSP_KV:key=value" lines; read them with
    Get-PortalGuestData.
#>

Set-StrictMode -Version Latest

$script:Sentinel = '__SSP_EXIT='

function ConvertTo-PortalGuestLiteral {
    <# Single-quoted PowerShell literal (quotes doubled, including the typographic single quotes PowerShell honours). #>
    [CmdletBinding()] [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + ($Value -replace "['‘’‚‛]", '$0$0') + "'"
}

function ConvertTo-PortalBashLiteral {
    <# Single-quoted Bash literal: 'it'\''s'. NUL characters are rejected. #>
    [CmdletBinding()] [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [AllowNull()] [string] $Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Contains([char]0)) { throw 'Value contains a NUL character and cannot be passed to Bash.' }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Protect-PortalGuestText {
    <# Replaces every secret (length >= 4) in the text with ********. #>
    param([string] $Text, [string[]] $Secrets)
    if (-not $Text) { return $Text }
    foreach ($s in @($Secrets)) { if ($s -and $s.Length -ge 4) { $Text = $Text.Replace($s, '********') } }
    return $Text
}

function New-PortalGuestWrapper {
    <# Builds the script actually sent to the guest (sentinel + timeout). Exposed for tests. #>
    [CmdletBinding()] [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ScriptText,
        [ValidateSet('PowerShell', 'Bash')] [string] $Type = 'PowerShell',
        [int] $TimeoutSeconds = 1800
    )
    if ($Type -eq 'PowerShell') {
        $body = "`$ErrorActionPreference = 'Stop'`r`n`$ProgressPreference = 'SilentlyContinue'`r`n" + $ScriptText
        $b64  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        return @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$__ssp = 1
try {
    `$__sb = [scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64')))
    `$__j = Start-Job -ScriptBlock `$__sb
    if (-not (Wait-Job -Job `$__j -Timeout $TimeoutSeconds)) {
        Stop-Job -Job `$__j
        Receive-Job -Job `$__j -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ([string]`$_) }
        Write-Output 'ERROR: guest script timed out after $TimeoutSeconds seconds.'
        `$__ssp = 124
    }
    else {
        `$__errs = `$null
        Receive-Job -Job `$__j -ErrorAction SilentlyContinue -ErrorVariable __errs | ForEach-Object { Write-Output ([string]`$_) }
        `$__reason = `$__j.ChildJobs[0].JobStateInfo.Reason
        if (`$__j.State -eq 'Failed' -or `$__reason) { Write-Output ('ERROR: ' + `$(if (`$__reason) { `$__reason.Message } else { 'job failed' })); `$__ssp = 1 }
        elseif (`$__errs) { Write-Output ('ERROR: ' + [string]`$__errs[0]); `$__ssp = 1 }
        else { `$__ssp = 0 }
    }
    Remove-Job -Job `$__j -Force -ErrorAction SilentlyContinue
}
catch { Write-Output ('ERROR: ' + `$_.Exception.Message); `$__ssp = 1 }
Write-Output ('$($script:Sentinel)' + `$__ssp)
"@
    }
    $eof = '__SSP_EOF_' + [guid]::NewGuid().ToString('N') + '__'
    $bashBody = "set -eo pipefail`n" + ($ScriptText -replace "`r`n", "`n")
    # This file may be checked out with CRLF (Windows, git archive): Bash needs LF everywhere (heredoc terminator).
    $wrapper = @"
__ssp_f=`$(mktemp /tmp/ssp-XXXXXXXX.sh) || { echo 'ERROR: mktemp failed'; echo '$($script:Sentinel)1'; exit 1; }
chmod 600 "`$__ssp_f"
cat > "`$__ssp_f" <<'$eof'
$bashBody
$eof
if [ "`$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then __ssp_run="sudo -n"; else __ssp_run=""; fi
`$__ssp_run timeout --kill-after=30 $TimeoutSeconds bash "`$__ssp_f" 2>&1
__ssp_rc=`$?
rm -f "`$__ssp_f"
[ `$__ssp_rc -eq 124 ] && echo 'ERROR: guest script timed out after $TimeoutSeconds seconds.'
echo "$($script:Sentinel)`$__ssp_rc"
"@
    return ($wrapper -replace "`r`n", "`n")
}

function ConvertFrom-PortalGuestOutput {
    <# Splits raw ScriptOutput into @{ ExitCode; Output } (sentinel removed). ExitCode = -1 when the sentinel is missing. #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Text)
    $lines = @(([string]$Text) -split "\r?\n")
    $code = -1; $idx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($script:Sentinel) + '(-?\d+)\s*$')) { $code = [int]$Matches[1]; $idx = $i; break }
    }
    $keep = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -ne $idx) { $lines[$i] } })
    $out = ($keep -join "`n").TrimEnd()
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Invoke-PortalGuestScript {
    <#
    .SYNOPSIS Runs a script in the guest via Invoke-VMScript; throws on non-zero exit; returns the output (no sentinel).
    .PARAMETER Sensitive  The script contains a secret: never log it.
    .PARAMETER Secrets    Strings redacted from error messages (the guest credential password is always added).
    #>
    [CmdletBinding()] [OutputType([string])]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $ScriptText,
        [ValidateSet('PowerShell', 'Bash')] [string] $Type = 'PowerShell',
        [Parameter(Mandatory)] $Server,
        [ValidateRange(30, 86400)] [int] $TimeoutSeconds = 1800,
        [string] $Description = 'guest script',
        [switch] $Sensitive,
        [string[]] $Secrets = @()
    )
    $secretList = @($Secrets) + @($Credential.GetNetworkCredential().Password)
    $vmName = if ($VM.PSObject.Properties['Name']) { $VM.Name } else { [string]$VM }
    $hasLog = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
    if ($hasLog) { Write-JobLog "Guest ($Type) on ${vmName}: $Description$(if ($Sensitive) { ' [sensitive: script not logged]' })" }
    if (-not $Sensitive) { Write-Verbose "Guest script ($Description):`n$ScriptText" }

    $wrapped = New-PortalGuestWrapper -ScriptText $ScriptText -Type $Type -TimeoutSeconds $TimeoutSeconds
    $scriptType = if ($Type -eq 'PowerShell') { 'Powershell' } else { 'Bash' }
    try {
        $res = Invoke-VMScript -VM $VM -Server $Server -GuestCredential $Credential -ScriptText $wrapped -ScriptType $scriptType -ToolsWaitSecs 120 -ErrorAction Stop
    }
    catch {
        throw (Protect-PortalGuestText -Text "Guest operation '$Description' on $vmName could not run: $($_.Exception.Message) (check the guest credential and that VMware Tools is running)." -Secrets $secretList)
    }
    $raw = if ($null -eq $res) { '' } elseif ($res.PSObject.Properties['ScriptOutput']) { [string]$res.ScriptOutput } else { [string]$res }
    $parsed = ConvertFrom-PortalGuestOutput -Text $raw
    if ($parsed.ExitCode -ne 0) {
        $tail = @(($parsed.Output -split "\n") | Where-Object { $_.Trim() } | Select-Object -Last 20) -join "`n"
        $why = if ($parsed.ExitCode -lt 0) { "no exit status returned (interpreter exit $(if ($res -and $res.PSObject.Properties['ExitCode']) { $res.ExitCode } else { '?' }); script interrupted?)" } else { "exit code $($parsed.ExitCode)" }
        throw (Protect-PortalGuestText -Text "Guest script '$Description' on $vmName failed: $why. Last output:`n$tail" -Secrets $secretList)
    }
    return $parsed.Output
}

function Get-PortalGuestData {
    <# Structured data from guest output: the last "__SSP_JSON=" line (merged) + every "__SSP_KV:key=value" line. #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Output)
    $data = [ordered]@{}
    foreach ($l in @(([string]$Output) -split "\r?\n")) {
        if ($l -match '^\s*__SSP_JSON=(.+)$') {
            $j = $Matches[1] | ConvertFrom-Json -AsHashtable
            foreach ($k in $j.Keys) { $data[$k] = $j[$k] }
        }
        elseif ($l -match '^\s*__SSP_KV:([A-Za-z0-9_]+)=(.*)$') { $data[$Matches[1]] = $Matches[2].TrimEnd() }
    }
    return $data
}

function Wait-PortalGuestReady {
    <# Waits until VMware Tools is running in the guest; returns the VMGuest object. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] $Server,
        [int] $TimeoutSeconds = 300,
        [int] $PollSeconds = 5,
        [int] $InitialDelaySeconds = 0
    )
    if ($InitialDelaySeconds -gt 0) { Start-Sleep -Seconds $InitialDelaySeconds }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $name = $VM.Name
    do {
        $v = Get-VM -Name $name -Server $Server -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($v) {
            $status = $null
            try { $status = [string]$v.ExtensionData.Guest.ToolsRunningStatus } catch { $status = $null }
            $g = Get-VMGuest -VM $v -Server $Server -ErrorAction SilentlyContinue
            if ($status -eq 'guestToolsRunning' -or (-not $status -and $g -and [string]$g.State -eq 'Running')) { return $g }
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
    throw "VMware Tools is not running in $name after $TimeoutSeconds s. Check that the VM has booted and VMware Tools is installed and started."
}

function Resolve-PortalGuestVM {
    <#
    .SYNOPSIS Gets a powered-on VM, waits for VMware Tools and checks the guest family.
    .OUTPUTS  [pscustomobject] @{ VM; Guest; Family ('windows'|'linux'|''); OSFullName }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Server,
        [ValidateSet('windows', 'linux', 'any')] [string] $ExpectedFamily = 'any',
        [int] $TimeoutSeconds = 300
    )
    $vm = @(Get-VM -Name $Name -Server $Server -ErrorAction SilentlyContinue)
    if (-not $vm.Count) { throw "VM '$Name' was not found in $($Server.Name)." }
    if ($vm.Count -gt 1) { throw "More than one VM is named '$Name' in $($Server.Name); rename one of them first." }
    $vm = $vm[0]
    if ([string]$vm.PowerState -ne 'PoweredOn') { throw "VM '$Name' is $($vm.PowerState); guest operations need a powered-on VM with VMware Tools running." }
    $g = Wait-PortalGuestReady -VM $vm -Server $Server -TimeoutSeconds $TimeoutSeconds
    $famRaw = ''
    if ($g -and $g.PSObject.Properties['GuestFamily'] -and $g.GuestFamily) { $famRaw = [string]$g.GuestFamily }
    else { try { $famRaw = [string]$vm.ExtensionData.Guest.GuestFamily } catch { $famRaw = '' } }
    $os = if ($g -and $g.PSObject.Properties['OSFullName']) { [string]$g.OSFullName } else { '' }
    $family = if ($famRaw -match 'windows' -or $os -match 'Windows') { 'windows' } elseif ($famRaw -match 'linux' -or $os -match 'Linux|Alma|Red Hat|Rocky|CentOS') { 'linux' } else { '' }
    if ($ExpectedFamily -ne 'any' -and $family -and $family -ne $ExpectedFamily) {
        throw "VM '$Name' runs $(if ($os) { $os } else { $family }); this item needs a $ExpectedFamily guest."
    }
    return [pscustomobject]@{ VM = $vm; Guest = $g; Family = $family; OSFullName = $os }
}

Export-ModuleMember -Function ConvertTo-PortalGuestLiteral, ConvertTo-PortalBashLiteral, Protect-PortalGuestText, New-PortalGuestWrapper,
    ConvertFrom-PortalGuestOutput, Invoke-PortalGuestScript, Get-PortalGuestData, Wait-PortalGuestReady, Resolve-PortalGuestVM
