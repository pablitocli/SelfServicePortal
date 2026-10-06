#Requires -Version 7.2
<#
.SYNOPSIS
    Cloud Ops handler - launches an EC2 instance (Windows Server 2025 or AlmaLinux) in the configured VPC.
.DESCRIPTION
    Uses Admin > Cloud connections > AWS (region, VPC, subnets, security groups, key pair, images).
    Image resolution:
      Windows2025 : AWS public SSM parameter (always the latest patched AMI) or a pinned amiId.
      AlmaLinux   : pinned amiId, an SSM parameter, or the newest image from the AlmaLinux owner account matching namePattern.
    Flow: pre-flight (name unique, subnet in VPC) -> resolve AMI -> launch with encrypted gp3 volumes + tags ->
          wait for running + status checks -> result. Terminated automatically on failure (rollbackOnFailure).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{2,62}$')] [string] $InstanceName,
    [string] $Description,
    [Parameter(Mandatory)] [ValidateSet('Windows2025', 'AlmaLinux')] [string] $OsFlavor,
    [Parameter(Mandatory)] [string] $InstanceType,
    [Parameter(Mandatory)] [string] $SubnetId,
    [int] $RootVolumeGB = 0,
    [int] $DataDiskGB = 0,
    [bool] $AssociatePublicIp = $false,
    [string] $Owner,
    [string] $CostCenter,
    [string] $ChangeTicket,
    [System.Collections.IDictionary] $VmNotes,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) { function Write-JobLog { param([string] $Message, [string] $Level = 'INFO') Write-Host "[$Level] $Message" } }
Import-Module AWS.Tools.EC2, AWS.Tools.SimpleSystemsManagement -ErrorAction Stop

$aws    = $Context.Cloud
$s      = $aws.Settings
$common = @{ Region = $aws.Region }
if ($aws.Credential) { $common['Credential'] = $aws.Credential }
$instanceId = $null

try {
    #region Pre-flight
    Write-JobLog -Level STEP "Pre-flight (region $($aws.Region), VPC $($s.vpcId))"
    $dup = Get-EC2Instance -Filter @(@{ Name = 'tag:Name'; Values = $InstanceName }, @{ Name = 'instance-state-name'; Values = @('pending', 'running', 'stopping', 'stopped') }) @common
    if ($dup.Instances) { throw "An instance named '$InstanceName' already exists ($($dup.Instances[0].InstanceId))." }
    $subnet = Get-EC2Subnet -SubnetId $SubnetId @common
    if ($s.vpcId -and $subnet.VpcId -ne $s.vpcId) { throw "Subnet $SubnetId belongs to $($subnet.VpcId), not to the portal VPC $($s.vpcId)." }
    if (@($s.instanceTypes) -and @($s.instanceTypes) -notcontains $InstanceType) { throw "Instance type $InstanceType is not in the allowed list." }
    #endregion

    #region Image
    $img = $s.images[$OsFlavor]
    $amiId = [string]$img['amiId']
    if (-not $amiId -and $img['ssmParameter']) {
        $amiId = (Get-SSMParameterValue -Name $img.ssmParameter @common).Parameters[0].Value
        Write-JobLog "AMI from SSM $($img.ssmParameter): $amiId"
    }
    if (-not $amiId -and $img['ownerId']) {
        $cand = Get-EC2Image -Owner $img.ownerId -Filter @(@{ Name = 'name'; Values = $img.namePattern }, @{ Name = 'architecture'; Values = 'x86_64' }, @{ Name = 'state'; Values = 'available' }) @common |
                Sort-Object CreationDate -Descending | Select-Object -First 1
        if (-not $cand) { throw "No AMI found for owner $($img.ownerId) / '$($img.namePattern)' in $($aws.Region)." }
        $amiId = $cand.ImageId
        Write-JobLog "AMI (newest '$($img.namePattern)'): $amiId - $($cand.Name)"
    }
    if (-not $amiId) { throw "No image configured for $OsFlavor (Admin > Cloud connections > AWS > Images)." }
    $image = Get-EC2Image -ImageId $amiId @common
    #endregion

    #region Launch
    $blocks = [System.Collections.Generic.List[Amazon.EC2.Model.BlockDeviceMapping]]::new()
    $rootEbs = [Amazon.EC2.Model.EbsBlockDevice]@{ VolumeType = 'gp3'; Encrypted = $true; DeleteOnTermination = $true }
    if ($RootVolumeGB -gt 0) { $rootEbs.VolumeSize = $RootVolumeGB }
    $blocks.Add([Amazon.EC2.Model.BlockDeviceMapping]@{ DeviceName = $image.RootDeviceName; Ebs = $rootEbs })
    if ($DataDiskGB -gt 0) {
        $dev = if ($OsFlavor -eq 'Windows2025') { 'xvdf' } else { '/dev/sdf' }
        $blocks.Add([Amazon.EC2.Model.BlockDeviceMapping]@{ DeviceName = $dev; Ebs = [Amazon.EC2.Model.EbsBlockDevice]@{ VolumeSize = $DataDiskGB; VolumeType = 'gp3'; Encrypted = $true; DeleteOnTermination = $true } })
    }

    $tags = [ordered]@{ Name = $InstanceName; Owner = $Owner; CostCenter = $CostCenter; ChangeTicket = $ChangeTicket
                        PortalRequestId = $Context.RequestId; RequestedBy = $Context.Requester.username; Description = $Description; OS = $OsFlavor }
    foreach ($k in @($s.defaultTags.Keys)) { if (-not $tags.Contains($k)) { $tags[$k] = $s.defaultTags[$k] } }
    if ($VmNotes) { foreach ($k in $VmNotes.Keys) { $tags["Note-$(($k -replace '[^A-Za-z0-9 _.:/=+@-]', '').Trim())"] = $VmNotes[$k] } }
    $tagList = [System.Collections.Generic.List[Amazon.EC2.Model.Tag]]::new()
    foreach ($k in $tags.Keys) { if ($tags[$k]) { $tagList.Add([Amazon.EC2.Model.Tag]::new($k, ([string]$tags[$k]).Substring(0, [Math]::Min(255, ([string]$tags[$k]).Length)))) } }
    $specs = @(
        [Amazon.EC2.Model.TagSpecification]@{ ResourceType = 'instance'; Tags = $tagList },
        [Amazon.EC2.Model.TagSpecification]@{ ResourceType = 'volume'; Tags = $tagList }
    )

    $launch = @{
        ImageId             = $amiId
        InstanceType        = $InstanceType
        SubnetId            = $SubnetId
        MinCount            = 1
        MaxCount            = 1
        BlockDeviceMapping  = $blocks.ToArray()
        TagSpecification    = $specs
        AssociatePublicIp   = $AssociatePublicIp
    }
    if (@($s.securityGroupIds)) { $launch['SecurityGroupId'] = @($s.securityGroupIds) }
    if ($s.keyPairName)        { $launch['KeyName'] = $s.keyPairName }

    Write-JobLog -Level STEP "Launching $InstanceType from $amiId in $SubnetId ($($subnet.AvailabilityZone))"
    $res = New-EC2Instance @launch @common
    $instanceId = $res.Instances[0].InstanceId
    Write-JobLog -Level OK "Instance $instanceId created."
    #endregion

    #region Wait
    Write-JobLog 'Waiting for state running and status checks (max 20 min)...'
    $deadline = (Get-Date).AddMinutes(20)
    do {
        Start-Sleep -Seconds 15
        $st = Get-EC2InstanceStatus -InstanceId $instanceId -IncludeAllInstance $true @common
        $state = [string]$st.InstanceState.Name
        $ok = ($state -eq 'running' -and [string]$st.Status.Status -eq 'ok' -and [string]$st.SystemStatus.Status -eq 'ok')
        if ($state -in 'terminated', 'shutting-down') { throw "Instance entered state '$state'." }
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { Write-JobLog -Level WARN "Status checks not green after 20 min (state $state). Continuing." }
    $inst = (Get-EC2Instance -InstanceId $instanceId @common).Instances[0]
    Write-JobLog -Level OK "Running. Private IP $($inst.PrivateIpAddress)$(if ($inst.PublicIpAddress) { ", public IP $($inst.PublicIpAddress)" })"
    #endregion

    $next = @('Register the internal DNS record through your change process if the instance needs an internal name.')
    if ($OsFlavor -eq 'Windows2025') { $next += "Retrieve the Administrator password with the key pair '$($s.keyPairName)' (EC2 console > Connect > Get password) and join the domain per standard." }
    else { $next += "Connect with the key pair '$($s.keyPairName)' as user 'ec2-user' (AlmaLinux default)." }

    return [ordered]@{
        Cloud            = 'AWS'
        InstanceId       = $instanceId
        InstanceName     = $InstanceName
        OS               = $OsFlavor
        InstanceType     = $InstanceType
        Region           = $aws.Region
        AvailabilityZone = $inst.Placement.AvailabilityZone
        VpcId            = $inst.VpcId
        SubnetId         = $SubnetId
        PrivateIp        = $inst.PrivateIpAddress
        PublicIp         = $(if ($inst.PublicIpAddress) { $inst.PublicIpAddress } else { 'none' })
        ImageId          = $amiId
        NextSteps        = $next
    }
}
catch {
    $err = $_
    if ($instanceId -and $Context.RollbackOnFailure) {
        Write-JobLog -Level WARN "Rolling back: terminating $instanceId."
        try { $null = Remove-EC2Instance -InstanceId $instanceId -Force @common; Write-JobLog -Level WARN 'Instance terminated.' }
        catch { Write-JobLog -Level ERROR "Rollback failed - terminate $instanceId manually: $($_.Exception.Message)" }
    }
    throw $err
}
