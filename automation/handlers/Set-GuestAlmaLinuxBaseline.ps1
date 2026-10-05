#Requires -Version 7.2
<#
.SYNOPSIS
    Catalog handler - applies the AlmaLinux server baseline inside a VM: packages, NTP, AD join, sudo groups, CIS basics.
.DESCRIPTION
    Runs inside the guest through VMware Tools guest operations (Bash, automation/lib/Portal.Guest.psm1); no SSH.
    The guest credential must be root, or a user with passwordless sudo (the wrapper uses sudo -n when not root).

    Sections (each idempotent; files are rewritten with the same content on a re-run):
      packages   dnf install -y chrony (+ realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools when joining)
                 + ExtraPackages
      ntp        managed block in /etc/chrony.conf (existing pool/server lines commented out), chronyd enabled
      domain     realm join (password through stdin, never on the command line or in the log); skipped when already
                 joined; authselect with-mkhomedir + oddjobd enabled
      sudo       realm permit -g <groups>; /etc/sudoers.d/90-portal-groups (%group ALL=(ALL) ALL) checked with
                 visudo -cf before it is installed. Group names are written as group@domain when SSSD uses fully
                 qualified names (realm join default), plain otherwise.
      cis        /etc/sysctl.d/90-portal-cis.conf (no forwarding / redirects / source routing, syncookies...),
                 /etc/ssh/sshd_config.d/00-portal-cis.conf (PermitRootLogin no; 00- because sshd keeps the FIRST
                 value and AlmaLinux 9 ships 01-permitrootlogin.conf when root SSH was allowed at install), checked
                 with sshd -t before reload and verified with sshd -T, /etc/security/pwquality.conf.d/90-portal.conf
                 (minlen 14), auditd and firewalld enabled (ssh service kept open).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [pscredential] $GuestCredential,
    [bool] $JoinDomain = $true,
    [string] $DomainName,
    [pscredential] $DomainJoinCredential,
    [string] $ComputerOU,
    [string] $SudoGroups,
    [string] $NtpServers,
    [string] $ExtraPackages,
    [bool] $ApplyCisBasics = $true,
    [string] $ChangeTicket,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
    function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" }
}
Import-Module (Join-Path $Context.PortalRoot 'automation/lib/Portal.Guest.psm1') -Force -DisableNameChecking

$vi = $Context.VIServer
function BQ([string] $v) { ConvertTo-PortalBashLiteral -Value $v }
function Split-List([string] $v) { @(([string]$v) -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

#region 1. Input validation -----------------------------------------------------------------------------------
Write-JobLog -Level STEP 'Validating parameters'
$pkgs = Split-List $ExtraPackages
$badPkg = @($pkgs | Where-Object { $_ -notmatch '^[A-Za-z0-9._+-]+$' -or $_ -notmatch '^[A-Za-z0-9]' })
if ($badPkg) { throw "Invalid package name(s): $($badPkg -join ', '). Each name must match ^[A-Za-z0-9._+-]+$ and start with a letter or digit." }
$ntp = Split-List $NtpServers
$badNtp = @($ntp | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' })
if ($badNtp) { throw "Invalid NTP server(s): $($badNtp -join ', '). Use host names or IPv4 addresses." }
$groups = Split-List $SudoGroups
$badGrp = @($groups | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' })
if ($badGrp) { throw "Invalid sudo group name(s): $($badGrp -join ', '). Letters, digits, dot, underscore and hyphen only (no spaces)." }
$secrets = @()
$joinUser = $null
if ($JoinDomain) {
    if (-not $DomainName) { throw 'DomainName is required when JoinDomain is true.' }
    $DomainName = $DomainName.Trim().ToLowerInvariant()
    if ($DomainName -notmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { throw "DomainName '$DomainName' is not a valid DNS domain name (e.g. corp.example.com)." }
    if ($ComputerOU -and ($ComputerOU -notmatch '^(OU|CN)=[^''"\r\n\\]+$')) { throw "ComputerOU '$ComputerOU' must be a distinguished name such as OU=Linux,OU=Servers,DC=corp,DC=example,DC=com." }
    if ($DomainJoinCredential) {
        $joinUser = $DomainJoinCredential.UserName
        if ($joinUser -match '^[^\\]+\\(.+)$') { $joinUser = $Matches[1] }
        if ($joinUser -match '^([^@]+)@') { $joinUser = $Matches[1] }
        if ($joinUser -notmatch '^[A-Za-z0-9._$-]+$') { throw "Domain join account '$($DomainJoinCredential.UserName)' is not a valid user name." }
        $secrets += $DomainJoinCredential.GetNetworkCredential().Password
    }
}
elseif ($ComputerOU -or $DomainJoinCredential) { Write-JobLog -Level WARN 'JoinDomain is false: ComputerOU / DomainJoinCredential are ignored.' }
#endregion

#region 2. Guest pre-checks -----------------------------------------------------------------------------------
Write-JobLog -Level STEP "Pre-checks on $VMName"
$g = Resolve-PortalGuestVM -Name $VMName -Server $vi -ExpectedFamily linux
$vm = $g.VM
$factsScript = @'
. /etc/os-release
echo "__SSP_KV:Id=${ID}"
echo "__SSP_KV:Version=${VERSION_ID}"
echo "__SSP_KV:Pretty=${PRETTY_NAME}"
echo "__SSP_KV:Uid=$(id -u)"
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then echo "__SSP_KV:Root=no"; else echo "__SSP_KV:Root=yes"; fi
if command -v realm >/dev/null 2>&1; then echo "__SSP_KV:Realms=$(realm list --name-only 2>/dev/null | tr '\n' ' ')"; else echo "__SSP_KV:Realms="; fi
'@
$facts = Get-PortalGuestData -Output (Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $factsScript -Type Bash -TimeoutSeconds 300 -Description 'collect facts')
if ($facts.Root -ne 'yes') { throw "Guest account $($GuestCredential.UserName) is not root and has no passwordless sudo on $VMName." }
switch ([string]$facts.Id) {
    'almalinux' { }
    { $_ -in 'rhel', 'rocky' } { Write-JobLog -Level WARN "$VMName runs $($facts.Pretty): not AlmaLinux, applying the baseline anyway (compatible distribution)." }
    default { throw "$VMName runs '$($facts.Pretty)' (ID=$($facts.Id)). This baseline supports AlmaLinux (RHEL / Rocky with a warning)." }
}
Write-JobLog "Guest: $($facts.Pretty)"
$joined = @(([string]$facts.Realms) -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$alreadyJoined = $JoinDomain -and ($joined -contains $DomainName)
if ($JoinDomain -and -not $alreadyJoined -and -not $DomainJoinCredential) { throw "$VMName is not joined to $DomainName and no DomainJoinCredential was selected." }
if ($JoinDomain -and $joined.Count -and -not $alreadyJoined) { throw "$VMName is already joined to $($joined -join ', '); leave that realm before joining $DomainName." }
#endregion

$applied = [System.Collections.Generic.List[string]]::new()
function Invoke-Section([string] $Name, [string] $Text, [switch] $Sensitive) {
    $out = Invoke-PortalGuestScript -VM $vm -Server $vi -Credential $GuestCredential -ScriptText $Text -Type Bash -TimeoutSeconds 1800 -Description $Name -Sensitive:$Sensitive -Secrets $secrets
    $applied.Add($Name)
    Write-JobLog -Level OK "Section '$Name' applied"
    return $out
}

#region 3. Packages and NTP -----------------------------------------------------------------------------------
$base = @('chrony')
if ($JoinDomain) { $base += 'realmd', 'sssd', 'oddjob', 'oddjob-mkhomedir', 'adcli', 'samba-common-tools' }
if ($ApplyCisBasics) { $base += 'audit', 'firewalld' }
$all = @($base + $pkgs | Select-Object -Unique)
Write-JobLog -Level STEP "Installing packages: $($all -join ' ')"
$null = Invoke-Section 'packages' "dnf install -y $(($all | ForEach-Object { BQ $_ }) -join ' ')"

if ($ntp.Count) {
    Write-JobLog -Level STEP "Configuring chrony: $($ntp -join ', ')"
    $block = "# BEGIN portal-managed`n" + (($ntp | ForEach-Object { "server $_ iburst" }) -join "`n") + "`n# END portal-managed"
    $null = Invoke-Section 'ntp' @"
f=/etc/chrony.conf
sed -i '/^# BEGIN portal-managed/,/^# END portal-managed/d' "`$f"
sed -i -E 's/^(pool|server)[[:space:]]/#portal# &/' "`$f"
printf '%s\n' $(BQ $block) >> "`$f"
systemctl enable --now chronyd
systemctl restart chronyd
"@
}
#endregion

#region 4. Domain join and sudo -------------------------------------------------------------------------------
if ($JoinDomain) {
    if ($alreadyJoined) { Write-JobLog -Level OK "$VMName is already joined to $DomainName (join skipped)"; $applied.Add('domain (already joined)') }
    else {
        Write-JobLog -Level STEP "Joining $DomainName as $joinUser$(if ($ComputerOU) { " (OU $ComputerOU)" })"
        $ouArg = if ($ComputerOU) { " --computer-ou=$(BQ $ComputerOU)" } else { '' }
        $pw = $DomainJoinCredential.GetNetworkCredential().Password
        $null = Invoke-Section 'domain' -Sensitive @"
printf '%s' $(BQ $pw) | realm join --user=$(BQ $joinUser)$ouArg $(BQ $DomainName)
realm list --name-only | grep -qix $(BQ $DomainName)
"@
    }
    $null = Invoke-Section 'mkhomedir' @'
if command -v authselect >/dev/null 2>&1; then authselect enable-feature with-mkhomedir >/dev/null 2>&1 || authselect select sssd with-mkhomedir --force; fi
systemctl enable --now oddjobd
'@
}

if ($groups.Count) {
    Write-JobLog -Level STEP "Sudo groups: $($groups -join ', ')"
    $grpList = ($groups | ForEach-Object { BQ $_ }) -join ' '
    $domLit = if ($JoinDomain) { BQ $DomainName } else { "''" }
    $null = Invoke-Section 'sudo' @"
dom=$domLit
fqn=no
if [ -n "`$dom" ] && [ -f /etc/sssd/sssd.conf ] && ! grep -Eiq '^[[:space:]]*use_fully_qualified_names[[:space:]]*=[[:space:]]*false' /etc/sssd/sssd.conf; then fqn=yes; fi
tmp=`$(mktemp /tmp/ssp-sudo-XXXXXXXX)
trap 'rm -f "`$tmp"' EXIT
echo '# Managed by the self-service portal - do not edit' > "`$tmp"
for g in $grpList; do
  name="`$g"; [ "`$fqn" = yes ] && name="`$g@`$dom"
  [ -n "`$dom" ] && realm permit -g "`$name"
  echo "%`$name ALL=(ALL) ALL" >> "`$tmp"
done
visudo -cf "`$tmp"
install -o root -g root -m 0440 "`$tmp" /etc/sudoers.d/90-portal-groups
visudo -c
"@
}
#endregion

#region 5. CIS basics -----------------------------------------------------------------------------------------
if ($ApplyCisBasics) {
    Write-JobLog -Level STEP 'Applying CIS basics (sysctl, sshd, pwquality, auditd, firewalld)'
    $null = Invoke-Section 'cis' @'
cat > /etc/sysctl.d/90-portal-cis.conf <<'EOF'
# Managed by the self-service portal (CIS basics)
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
sysctl -q -p /etc/sysctl.d/90-portal-cis.conf

mkdir -p /etc/ssh/sshd_config.d
f=/etc/ssh/sshd_config.d/00-portal-cis.conf
printf '%s\n' '# Managed by the self-service portal (CIS basics)' 'PermitRootLogin no' > "$f"
chmod 0600 "$f"
if ! sshd -t; then rm -f "$f"; echo 'sshd -t failed: drop-in removed'; exit 4; fi
if [ "$(sshd -T 2>/dev/null | awk 'tolower($1)=="permitrootlogin"{print $2}')" != "no" ]; then echo 'PermitRootLogin is not effective (another drop-in sets it first)'; exit 5; fi
systemctl reload sshd

mkdir -p /etc/security/pwquality.conf.d
printf '%s\n' '# Managed by the self-service portal (CIS basics)' 'minlen = 14' > /etc/security/pwquality.conf.d/90-portal.conf

systemctl enable --now auditd
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh >/dev/null
firewall-cmd --reload >/dev/null
'@
}
#endregion

$next = @()
if ($ApplyCisBasics) { $next += 'firewalld is enabled (default zone, ssh allowed): open the application ports (firewall-cmd --permanent --add-port / --add-service).' }
if ($JoinDomain -and $groups.Count) { $next += "Members of $($groups -join ', ') can log in and use sudo; verify with: id <user>@$DomainName" }

return [ordered]@{
    VMName         = $VMName
    OS             = [string]$facts.Pretty
    AppliedSections = @($applied)
    Domain         = $(if ($JoinDomain) { $DomainName } else { 'not joined' })
    SudoGroups     = @($groups)
    NtpServers     = @($ntp)
    ExtraPackages  = @($pkgs)
    CisBasics      = $ApplyCisBasics
    NextSteps      = @($next)
}
