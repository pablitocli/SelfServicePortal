# Requirements

This document lists everything the Self-Service Portal needs before it is installed: supported platforms and sizing, software versions, network flows, certificates, service accounts with least-privilege permissions for vCenter, Active Directory / LDAP, AWS and Azure, and time synchronisation. It ends with a pre-deployment checklist. Everything here is derived from the shipped code (`Start-Portal.ps1`, `modules/`, `automation/`, `packaging/`); when the code does not support something, this document says so.

## Contents

1. [Deployment options](#1-deployment-options)
2. [Sizing](#2-sizing)
3. [Software prerequisites](#3-software-prerequisites)
4. [Browsers](#4-browsers)
5. [Network and firewall](#5-network-and-firewall)
6. [Certificates](#6-certificates)
7. [Time synchronisation](#7-time-synchronisation)
8. [Service accounts and permissions](#8-service-accounts-and-permissions)
9. [Pre-deployment checklist](#9-pre-deployment-checklist)
10. [Deployment-specific configuration (before first use)](#10-deployment-specific-configuration-before-first-use)

Related documents: [architecture.md](architecture.md), [configuration.md](configuration.md), [installation-linux.md](installation-linux.md), [ova.md](ova.md), [installation-windows.md](installation-windows.md), [identity.md](identity.md), [security.md](security.md), [vault.md](vault.md), [operations.md](operations.md).

---

## 1. Deployment options

| Option | Platform | Installer / guide | Notes |
|---|---|---|---|
| Virtual appliance (OVA) | AlmaLinux 9 (EFI, SELinux enforcing) | [ova.md](ova.md) | Pre-installed portal, per-instance secrets created at first boot from OVF properties. Recommended for vSphere environments. |
| Linux install | AlmaLinux 9, RHEL 9, Rocky Linux 9 (primary); Ubuntu 24.04 LTS (x86_64) | `packaging/linux/install.sh`, [installation-linux.md](installation-linux.md) | Runs as the `ssp` system account under systemd (`ssp-portal.service`). Other RHEL 9 rebuilds are accepted with a warning; other Ubuntu releases are untested. |
| Windows install | Windows Server 2019 or later | [installation-windows.md](installation-windows.md) | The repository ships **no** Windows service wrapper; you run the portal with NSSM or a scheduled task under a dedicated (g)MSA. |

All options run the same code. The portal is a **single-node** application: state is stored in JSON files under the portal folder and serialised with host-local named mutexes, so active/active clustering is not supported.

## 2. Sizing

| Resource | Minimum | Recommended |
|---|---|---|
| vCPU | 2 | 4 |
| Memory | 4 GB | 8 GB |
| Disk | 40 GB | 60 GB |

What drives the numbers:

- **Concurrent jobs.** Every job runs in its own `pwsh` process (`automation/Invoke-CatalogJob.ps1`) that loads PowerCLI, AWS.Tools or Az and uses roughly **150-300 MB** of memory and one CPU core while active. `jobs.maxConcurrent` (default `3`) caps how many run at the same time. Plan memory as *portal process + maxConcurrent x 300 MB*, plus the transient processes below.
- **Background processes.** Every `inventory.refreshIntervalMinutes` (default 30) the portal starts one inventory process per enabled vCenter site, and each *Test connection* in Admin starts one more. They are short-lived but use the same footprint as a job.
- **Disk.** PowerShell plus PowerCLI, AWS.Tools and Az take about 2 GB. Request documents (`data/requests`), job logs (`logs/jobs`), the audit trail (`logs/audit.jsonl`) and configuration backups (`config/_backup`) grow over time and are not pruned by the portal (see [operations.md](operations.md#3-logs)).

Raise `jobs.maxConcurrent` only together with vCPU and memory.

## 3. Software prerequisites

### 3.1 Runtime

| Component | Required version | Notes |
|---|---|---|
| PowerShell | **7.4 or later** (runs on .NET 8) | The modules declare `#Requires -Version 7.2`, but the installers and the LDAP compatibility handling target 7.4 (`PWSH_MIN_VERSION=7.4.0` in `install.sh`). Windows PowerShell 5.1 is not supported; `Start-Portal.ps1` relaunches itself in `pwsh` if started from 5.1. |
| Pode | **2.14.x** (2.14.1 is pinned by `install.sh`) | `Start-Portal.ps1` refuses versions older than 2.10.0, but only 2.14.x is tested. `tools/Install-PortalPrerequisites.ps1` (Windows) installs the latest Pode from the Gallery when none is present; pin 2.14.1 yourself (see [installation-windows.md](installation-windows.md#4-powershell-modules)). |
| VMware PowerCLI | 13.x (`VMware.PowerCLI`) or the renamed `VCF.PowerCLI` | Required for vSphere items, inventory and vCenter connection tests. The runner checks for the `VMware.VimAutomation.Core` module. |
| AWS Tools for PowerShell | `AWS.Tools.Common`, `AWS.Tools.EC2`, `AWS.Tools.SecurityToken`, `AWS.Tools.SimpleSystemsManagement` | Optional: only for the AWS Cloud Ops items. `install.sh` also installs `AWS.Tools.Installer`. |
| Az PowerShell | `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources`, `Az.KeyVault`, `Az.MarketplaceOrdering` | Optional: only for the Azure Cloud Ops items. |
| Microsoft.PowerShell.SecretManagement | any | Optional, legacy: only for sites whose credential type is `SecretManagement` (see [configuration.md](configuration.md#311-sites)). |

Module installation:

- **Linux / OVA:** `install.sh` installs the modules machine-wide in `/usr/local/share/powershell/Modules` (`--no-cloud-modules` skips AWS and Az; `--powercli-module VCF.PowerCLI` selects the new name; `--modules-dir` installs offline).
- **Windows:** `tools/Install-PortalPrerequisites.ps1` (elevated `pwsh`) installs Pode, `VMware.PowerCLI`, the four AWS.Tools modules and the six Az modules for all users. `-Skip Aws,Azure,VSphere` leaves a provider out. Already installed modules are skipped, not upgraded.

### 3.2 Linux libraries

| Library | Package | Why |
|---|---|---|
| OpenLDAP client library (`libldap`) | AlmaLinux/RHEL/Rocky: `openldap`; Ubuntu 24.04: `libldap2` | .NET `System.DirectoryServices.Protocols` uses it for every AD / LDAP sign-in on Linux. |
| `libldap-2.5.so.0` compatibility link | created by `install.sh` | .NET 8 loads `libldap-2.5.so.0`; the supported distributions ship OpenLDAP 2.6 (`libldap.so.2`). `install.sh` creates `libldap-2.5.so.0 -> libldap.so.2` in the system library directory and runs `ldconfig`. Without it, directory sign-in fails ("Unable to load shared library 'libldap-2.5.so.0'") while local accounts keep working. `Start-Portal.ps1` prints a warning at start-up when an LDAP provider is enabled and the library cannot be loaded. |
| `openldap-clients` / `ldap-utils` | installed by `install.sh` | `ldapsearch` for troubleshooting only. |
| `chrony` | installed and enabled by `install.sh` | Time synchronisation (section 7). |
| `openssl` | installed by `install.sh` | Self-signed certificate, vault key and session secret generation. |

Windows needs no extra library: `System.DirectoryServices.Protocols` uses the native Windows LDAP client.

## 4. Browsers

The front-end is a vanilla JavaScript single-page application (no build step, no external CDN). It uses modern JavaScript (`fetch`, `async`/`await`, optional chaining, `BroadcastChannel` when available) and needs:

- Current versions of Chromium-based browsers (Google Chrome, Microsoft Edge), Mozilla Firefox or Apple Safari.
- Cookies enabled for the portal host (the session cookie is `HttpOnly` and, on HTTPS, `Secure`).
- `sessionStorage` is used only for the sign-out reason message; private browsing works.

Internet Explorer and legacy (non-Chromium) Edge are not supported.

## 5. Network and firewall

### 5.1 Inbound (to the portal server)

| Port | Protocol | Source | Purpose | Notes |
|---|---|---|---|---|
| 443/tcp (Linux/OVA default), 8443/tcp (Windows default, `portal.port`) | HTTPS | User networks | Portal UI and API | One listener; HTTP is only available with the lab switch `Start-Portal.ps1 -Http` or `portal.protocol` other than `Https`. |
| 22/tcp | SSH | Admin networks | Linux/OVA administration | Optional. Opened by `install.sh`; disabled on the OVA when no OS password is supplied. |
| 3389/tcp | RDP | Admin networks | Windows administration | Optional, your standard. |

Administrative roles can additionally be restricted to management networks with `security.adminAllowedCidrs` (see [configuration.md](configuration.md#36-security)). When a reverse proxy or load balancer sits in front of the portal, list it in `security.trustedProxies` so that `X-Forwarded-For` is honoured.

### 5.2 Outbound (from the portal server)

| Destination | Port | Used by | Notes |
|---|---|---|---|
| vCenter Server(s) | 443/tcp | Job runners, inventory refresh, *Test connection* (PowerCLI) | All vSphere work goes through vCenter. PowerCLI is forced to **NoProxy** unless the site sets `useSystemProxy: true`. |
| ESXi hosts | 443/tcp, 902/tcp | **Not used** by the shipped handlers | No handler uses guest operations (`Invoke-VMScript`, `Copy-VMGuestFile`), consoles, datastore file transfers or OVF import. Open them only if you add a custom handler that needs them. |
| New VM addresses (static IP requests) | ICMP echo | `New-VsphereVM.ps1` pre-flight | Before cloning, the handler pings the requested static IP and refuses to continue if it answers. If ICMP is blocked, this duplicate-address check silently passes. |
| Domain controllers / LDAP servers | 636/tcp (LDAPS), 389/tcp (StartTLS; `negotiate` on Windows) | Sign-in, group resolution, Admin > Identity tests | 3268/3269 only if you point a provider at the Global Catalog. Unencrypted LDAP (`security: none`) is refused unless `allowInsecure` is set (lab only). |
| DNS servers | 53/udp+tcp | Everything | vCenter, LDAP and cloud endpoint names must resolve. |
| NTP servers | 123/udp | chrony / Windows Time | Required for MFA (section 7). |
| AWS: `ec2.<region>.amazonaws.com`, `ssm.<region>.amazonaws.com`, `sts.amazonaws.com` and/or `sts.<region>.amazonaws.com` | 443/tcp | AWS items and *Test connection* | Optional. With `authMode: DefaultChain` on an EC2 instance, also the instance metadata service (169.254.169.254). |
| Azure: `login.microsoftonline.com`, `management.azure.com`, `<keyVaultName>.vault.azure.net` | 443/tcp | Azure items and *Test connection* | Optional. With `authMode: ManagedIdentity`, also the Azure instance metadata service (169.254.169.254). |
| OS repositories, `packages.microsoft.com`, `www.powershellgallery.com` (and its CDN) | 443/tcp | Installation, upgrades, patching | Not needed at run time or for offline installs. |

The portal sends no e-mail and calls no webhooks; there is no SMTP flow. Outbound proxies: AWS.Tools and Az use the .NET default proxy (on Linux, set `HTTPS_PROXY` / `NO_PROXY` in a systemd drop-in, see [installation-linux.md](installation-linux.md#7-service-management)).

## 6. Certificates

| Certificate | Where | Requirement |
|---|---|---|
| **Portal TLS** (Linux/OVA) | `portal.certificateFile` + `portal.certificateKeyFile` (PEM). `install.sh` and the OVA use `/etc/ssp/tls/portal.crt` and `/etc/ssp/tls/portal.key` | Leaf first, then intermediates. Unencrypted PEM key readable by the service account (`ssp:ssp 0400`). SAN must contain every name users type. A self-signed certificate (RSA 3072, 825 days, SAN = FQDN, short name, IP) is generated at install; replace it ([installation-linux.md section 8](installation-linux.md#8-tls-certificate-replacement)). |
| **Portal TLS** (Windows) | `portal.certificateThumbprint` (certificate in `Cert:\LocalMachine\My`, store location configurable with `portal.certificateStoreLocation`) **or** `portal.certificateFile` (PFX with its password in the environment variable named by `portal.certificatePasswordEnvVar`, or PEM + key) | The service account needs read access to the private key. `certificateFile` takes precedence over the thumbprint. If neither is valid, Pode generates a **self-signed** certificate and the console warns (lab only). Configure with `tools/Set-PortalEndpoint.ps1`. |
| **Directory CA** (LDAPS / StartTLS) | Linux: OS trust store, or the provider's `tls.caFile` / `tls.caDirectory`, or `LDAPTLS_CACERT`; Windows: `LocalMachine\Root` / `CA` stores | The domain controller / LDAP server certificates must chain to a trusted CA and match the host names in `hosts[]`. `tls.verify: false` disables verification (lab only). On Linux libldap reads the CA settings once per process, so one CA bundle applies to all providers. |
| **vCenter** | Portal OS trust store | Each site has `invalidCertificateAction` (`Ignore` by default, `Warn`, `Fail`). Trust the VMCA / enterprise root on the portal server and set `Fail` for production. Note that the one-time configuration migration `cert-ignore-2026-09` sets every existing site to `Ignore`. |
| AWS / Azure endpoints | Public CAs in the OS trust store | TLS-intercepting proxies must have their CA in the OS trust store. |

## 7. Time synchronisation

- **MFA (TOTP)** codes are verified against the server clock with a window of one 30-second step before and after the current step (`Test-PortalTotp`). Keep the portal server **within +/- 30 seconds** of true time (and users' phones on automatic time); beyond that, valid codes are rejected and users get *The verification code is not valid*.
- Session idle / absolute timeouts, lockout windows, sign-in ticket expiry (60 s), vault entry expiry and request timestamps all use the server clock (UTC).
- Kerberos (`negotiate` on Windows) tolerates at most 5 minutes of skew by default; TLS validation fails for certificates that appear not yet valid.

Linux and the OVA run `chrony` (`ssp.ntp` OVF property on the appliance); on Windows, a domain member synchronises with the domain hierarchy; otherwise configure `w32time` with your NTP servers.

## 8. Service accounts and permissions

| Account | Where it is stored | Used for |
|---|---|---|
| Portal service account | OS | Runs the web server and every job / inventory / test process. Linux: `ssp` (created by `install.sh`). Windows: a gMSA or dedicated domain account (see [installation-windows.md](installation-windows.md)). |
| vCenter service account (one per site) | Portal vault, entry `vcenter-<site>`, system scope | All vSphere handlers, inventory, *Test connection* |
| Directory bind account (optional) | Portal vault, system scope; referenced by the provider's `bindCredential` | Only `bindMode: search` providers (and the *Test connection* user lookup) |
| AWS identity | Portal vault entry `cloud-aws` (access key) or the default credential chain | AWS items |
| Azure identity | Portal vault entry `cloud-azure` (service principal secret) or managed identity | Azure items |

Credentials are entered in Admin > vCenter connections / Cloud connections / Vault and stored encrypted in the portal vault ([vault.md](vault.md)).

### 8.1 vCenter role

The shipped handlers connect to vCenter through PowerCLI with the site's service account. The privileges below are derived from the cmdlets each handler calls. Privilege IDs are given with their vSphere Client names; verify them against your vSphere version before creating the role.

**Read-only access (every handler, inventory and connection test).** The inventory collector (`Update-VsphereInventory.ps1`) reads clusters, hosts, datastores, datastore clusters, distributed and standard port groups, VMs, templates, datacenters and folders with `Get-View`. `System.Anonymous`, `System.View` and `System.Read` are part of every role and cover this, provided the role is assigned on the objects the portal must see.

**Per-handler privileges**

| Handler (catalog items) | Cmdlets that change state | Privileges (vSphere Client name) |
|---|---|---|
| `New-VsphereVM.ps1` (`vm-windows-2025`, `vm-almalinux`) | `Get-OSCustomizationSpec`, `New-OSCustomizationSpec -Type NonPersistent` (client-side copy), `New-VM -Template -ResourcePool -Datastore -Location -OSCustomizationSpec -Notes`, `Set-VM -NumCpu -MemoryGB`, `Set-NetworkAdapter`, `New-HardDisk`, `New-CustomAttribute`, `Set-Annotation`, `Start-VM`, `Get-VIEvent`, `Wait-Tools`; rollback: `Stop-VM -Kill`, `Remove-VM -DeletePermanently` | `VirtualMachine.Provisioning.ReadCustSpecs` (Read customization specifications, on the vCenter root) · `VirtualMachine.Provisioning.DeployTemplate` (Deploy template, on the template) · `VirtualMachine.Provisioning.Customize` (Customize guest) · `VirtualMachine.Inventory.CreateFromExisting` (Create from existing, on the target folder) · `Resource.AssignVMToPool` (Assign virtual machine to resource pool, on the cluster) · `Datastore.AllocateSpace` (Allocate space) · `Network.Assign` (Assign network) · `VirtualMachine.Config.CPUCount` (Change CPU count) · `VirtualMachine.Config.Memory` (Change Memory) · `VirtualMachine.Config.EditDevice` (Modify device settings) · `VirtualMachine.Config.AddNewDisk` (Add new disk) · `VirtualMachine.Config.Annotation` (Set annotation - VM notes) · `VirtualMachine.Interact.PowerOn` (Power on) · rollback: `VirtualMachine.Interact.PowerOff` (Power off), `VirtualMachine.Inventory.Delete` (Remove) · governance attributes (optional, failures are only logged as warnings): `Global.ManageCustomFields` (Manage custom attributes, vCenter root), `Global.SetCustomField` (Set custom attribute) |
| `Set-VsphereVmSize.ps1` (`vm-resize`) | `Set-VM -NumCpu -MemoryGB`; with *Allow power cycle*: `Stop-VMGuest`, `Start-VM` | `VirtualMachine.Config.CPUCount` · `VirtualMachine.Config.Memory` · `VirtualMachine.Interact.PowerOff` (guest shutdown) · `VirtualMachine.Interact.PowerOn` |
| `Add-VsphereVmDisk.ps1` (`vm-add-disk`) | `New-HardDisk -Datastore` (on the VM's first datastore) | `VirtualMachine.Config.AddNewDisk` · `Datastore.AllocateSpace` |
| `Invoke-VsphereVmPower.ps1` (`vm-power`) | `Start-VM`, `Stop-VMGuest`, `Restart-VMGuest`, `Restart-VM` | `VirtualMachine.Interact.PowerOn` · `VirtualMachine.Interact.PowerOff` (guest shutdown) · `VirtualMachine.Interact.Reset` (guest restart and hard reset) |
| `New-VsphereSnapshot.ps1` (`vm-snapshot`) | `New-Snapshot` (optional memory / quiesce) | `VirtualMachine.State.CreateSnapshot` (Create snapshot) |
| Inventory, *Test connection* | `Get-View`, `Get-Cluster`, `Get-Datacenter`, `Get-VirtualPortGroup` | Read-only |

**Items added in 1.1.0.** Grant only what the items you enable need; a separate vCenter role (and a separate vault credential bound to those items with `execution.credentials`) for the infrastructure items is recommended.

| Item(s) | Additional privileges |
|---|---|
| Distributed port group | `DVPortgroup.Create`, `DVPortgroup.PolicyOp`, `DVPortgroup.Modify` (on the VDS); rollback `DVPortgroup.Delete` |
| DRS rules | `Host.Inventory.EditCluster` (Modify cluster, on the cluster) |
| vMotion | `Resource.HotMigrate`, `Resource.ColdMigrate`, `Resource.AssignVMToPool`, `Datastore.AllocateSpace` (target), `Network.Assign` |
| Host maintenance | `Host.Config.Maintenance` |
| Decommission, purge | `VirtualMachine.Interact.PowerOff`, `VirtualMachine.Config.Rename`, `VirtualMachine.Config.EditDevice`, `VirtualMachine.Inventory.Move`, `Folder.Create`, `VirtualMachine.Config.Annotation`, `Global.SetCustomField`, `InventoryService.Tagging.ObjectAttachable`; purge `VirtualMachine.Inventory.Delete` |
| Snapshot clean-up | `VirtualMachine.State.RemoveSnapshot` (removal and disk consolidation) |
| Test clone | `VirtualMachine.Provisioning.Clone`, `VirtualMachine.Inventory.CreateFromExisting`, `Datastore.AllocateSpace`, `Network.Assign`, `VirtualMachine.Config.EditDevice`, `Folder.Create`, `VirtualMachine.Config.Annotation` |
| SQL Server, Windows roles, agent baseline, AlmaLinux baseline | `VirtualMachine.GuestOperations.Execute`, `.Modify`, `.Query` — plus a guest account in the vault (tags `guest-windows`, `guest-linux`, `ad-join`, `sql-service`). Windows guests need access to the software / SQL media share. |
| Backup policy, decommission (tag removal) | `InventoryService.Tagging.CreateCategory`, `.CreateTag`, `.ObjectAttachable` |
| Reports (health, versions, hardening, certificates, right-sizing) | Read-only. Health with orphaned-VMDK search needs `Datastore.Browse`. Certificates: the portal server opens TLS (443) to vCenter and every ESXi host. |
| New datastore | `Host.Config.Storage` (rescan, create / mount VMFS / NFS), `Datastore.Config`, `StoragePod.Config` (datastore cluster), `Datastore.Move`, rollback `Datastore.Delete`. NFS: the portal server must reach the NFS server on TCP 2049 for the pre-check. |
| Three-tier blueprint | Union of *Windows Server 2025 VM*, DRS rules, guest items and backup policy. |
| Cloud cost / power (AWS) | `ec2:DescribeVolumes`, `ec2:DescribeAddresses`, `ec2:DescribeInstances`, `ec2:DescribeSnapshots`, `ec2:StartInstances`, `ec2:StopInstances` (restrict with a tag condition on `PowerSchedule`) |
| Cloud cost / power (Azure) | `Microsoft.Compute/disks/read`, `snapshots/read`, `virtualMachines/read`, `virtualMachines/instanceView/read`, `Microsoft.Network/publicIPAddresses/read`, `virtualMachines/start/action`, `virtualMachines/deallocate/action` |

Not used by any shipped handler: content library, snapshot revert, console interaction, creating persistent customization specifications.

**Combined role "SSP-Portal"** (VM build and day-2 items of 1.0):

| Category | Privileges |
|---|---|
| Datastore | Allocate space |
| Global | Manage custom attributes, Set custom attribute *(optional)* |
| Network | Assign network |
| Resource | Assign virtual machine to resource pool |
| Virtual machine > Change configuration | Add new disk, Change CPU count, Change Memory, Modify device settings, Set annotation |
| Virtual machine > Edit inventory | Create from existing, Remove |
| Virtual machine > Interaction | Power off, Power on, Reset |
| Virtual machine > Provisioning | Customize guest, Deploy template, Read customization specifications |
| Virtual machine > Snapshot management | Create snapshot |

Assignment: assign the role to the service account on the vCenter root (propagate) for simplicity, or, for least privilege, on the datacenters/clusters/datastores/networks/folders listed in the site (`workloadClusters`, the folders and port groups offered to requesters) plus the templates, and grant *Read customization specifications* and the *Global* privileges on the vCenter root object. Use an SSO account (`svc-portal@vsphere.local`) or a directory account (`DOMAIN\svc-portal`); the connection error message suggests both formats.

### 8.2 Active Directory / LDAP

**Bind account.** Required only for providers with `bindMode: search` (the default for `flavor: openldap`) and for the user lookup in Admin > Identity > *Test connection*. With `bindMode: direct` (the default for `flavor: ad`) the portal binds as the signing-in user (UPN = `login@upnSuffix`) and reads the user's own entry and groups with that connection; no service account is needed.

The bind account needs:

- Read access to user entries under `baseDn`: the attributes in `attributes` (`sAMAccountName`/`uid`, `displayName`/`cn`, `mail`), `memberOf` and `distinguishedName`.
- Read access to group entries under `groupBaseDn` (default `baseDn`): `cn` and the membership attribute used by the group filter (`member`, `uniqueMember` or `memberUid`).
- No write permission. In AD any ordinary domain user account is sufficient; use a dedicated, non-interactive account whose password does not expire, or rotate it in the vault.

Group resolution per `groupMode`: `nested` (AD, transitive via `LDAP_MATCHING_RULE_IN_CHAIN`), `memberOf` (direct groups from the user entry), `search` (group filter). Groups are matched by **CN**, case-insensitive. Details: [identity.md](identity.md).

**Groups to create.** Names are the defaults from `config/portal.config.default.json`; you can map any existing groups instead in Admin > Customization (role mapping) and Admin > Customization > Teams.

| Group | Grants | Notes |
|---|---|---|
| `SSP-Admins` | Role **Admin** (implies every other role) | MFA required by default |
| `SSP-Approvers` | Role **Approver** (implies Requester) | Approves requests of the teams the user belongs to |
| `SSP-Requesters` | Role **Requester** | Submits requests |
| `SSP-CatalogAdmins` | Role **CatalogAdmin** | Catalog editor, branding, teams, VM notes |
| `SSP-SecurityAdmins` | Role **SecurityAdmin** | Identity providers, local users, security policy, sessions, audit. MFA required by default |
| `SSP-VaultAdmins` | Role **VaultAdmin** | Credential vault. MFA required by default; cannot approve jobs that use vault credentials unless `separationOfDuties.vaultAdminCanApprove` is `true` |
| `SSP-Team-Infrastructure` | Team **Infrastructure** | Sees the vSphere items; Approvers decide Infrastructure requests |
| `SSP-Team-Cloud` | Team **Cloud** | Sees the AWS / Azure items; Approvers decide Cloud requests |

A user needs at least one role group, otherwise sign-in is refused (*not authorised for this portal*). Group membership is read at sign-in; changes take effect at the next sign-in.

### 8.3 AWS IAM

Derived from `automation/lib/Portal.CloudConnect.psm1`, `automation/Test-CloudConnection.ps1` and `automation/handlers/New-AwsEc2Instance.ps1`.

| API call (cmdlet) | Used by | IAM action |
|---|---|---|
| `Use-STSRole` | Connect, when `roleArn` is set | `sts:AssumeRole` (granted to the base identity on the role; the role's trust policy must trust that identity) |
| `Get-STSCallerIdentity` | Test connection | `sts:GetCallerIdentity` (always allowed; no policy needed) |
| `Get-EC2Vpc`, `Get-EC2Subnet`, `Get-EC2SecurityGroup`, `Get-EC2KeyPair` | Test connection (`Get-EC2Subnet` also in the handler) | `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `ec2:DescribeKeyPairs` |
| `Get-EC2Instance` | Handler pre-flight (name unique) and result | `ec2:DescribeInstances` |
| `Get-SSMParameterValue` | Handler, image from SSM parameter | `ssm:GetParameters` (this cmdlet calls the *GetParameters* API, not *GetParameter*) |
| `Get-EC2Image` | Handler, AMI lookup | `ec2:DescribeImages` |
| `New-EC2Instance` with tag specifications | Handler, launch | `ec2:RunInstances`, `ec2:CreateTags` (tagging on launch) |
| `Get-EC2InstanceStatus` | Handler, wait | `ec2:DescribeInstanceStatus` |
| `Remove-EC2Instance` | Handler, rollback on failure | `ec2:TerminateInstances` |

Not required: `iam:PassRole` (the handler attaches no instance profile), `ec2:CreateKeyPair`, `ec2:CreateSecurityGroup`, `ec2:AllocateAddress` (public IPs come from `AssociatePublicIp` on the subnet's network interface).

Minimal policy for the identity the portal uses (the base identity, or the assumed role when `roleArn` is set):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SspDescribe",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SspLaunch",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "*"
    },
    {
      "Sid": "SspTagOnLaunch",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*"
      ],
      "Condition": { "StringEquals": { "ec2:CreateAction": "RunInstances" } }
    },
    {
      "Sid": "SspRollback",
      "Effect": "Allow",
      "Action": "ec2:TerminateInstances",
      "Resource": "*"
    },
    {
      "Sid": "SspPublicAmiParameters",
      "Effect": "Allow",
      "Action": "ssm:GetParameters",
      "Resource": "arn:aws:ssm:*::parameter/aws/service/*"
    }
  ]
}
```

If `roleArn` is set, add to the **base** identity:

```json
{ "Effect": "Allow", "Action": "sts:AssumeRole", "Resource": "arn:aws:iam::<account-id>:role/<portal-role>" }
```

Tightening options: restrict `ec2:RunInstances` with conditions on the subnet, security group and image resources of your landing zone; restrict `ec2:TerminateInstances` with `"Condition": { "StringEquals": { "aws:ResourceTag/ManagedBy": "SelfService-Portal" } }` (this relies on `clouds.aws.defaultTags.ManagedBy` staying in place). If you point `images.*.ssmParameter` at your own parameters, add their ARNs to `ssm:GetParameters`. The handler creates **encrypted** gp3 volumes; if your account's default EBS encryption key is a customer-managed KMS key, also grant the KMS permissions EBS needs for that key (see the AWS EBS encryption documentation).

`authMode: AccessKey` uses the access key stored in the vault (`cloud-aws`); `authMode: DefaultChain` uses the AWS SDK default chain of the portal service account (environment, shared profile, EC2 instance profile).

### 8.4 Azure RBAC

Derived from `Portal.CloudConnect.psm1`, `Test-CloudConnection.ps1` and `automation/handlers/New-AzureVm.ps1`. Authentication is a service principal (`authMode: ServicePrincipal`, secret in the vault entry `cloud-azure`) or a managed identity (`authMode: ManagedIdentity`, only when the portal runs on an Azure VM or Arc-enabled server).

| Scope | Operations performed | Recommended role |
|---|---|---|
| `resourceGroup` (where VMs are created) | Read the resource group; `Get-AzVM` / `New-AzVM` / `Remove-AzVM`; managed OS and data disks (`Remove-AzDisk` on rollback); `New-AzNetworkInterface` and its removal; `New-AzPublicIpAddress` when *Public IP* is requested; boot diagnostics (managed storage) | **Virtual Machine Contributor** (VMs, disks, NICs) **plus** `Microsoft.Network/publicIPAddresses/write` and `/delete` if public IPs are allowed (for example **Network Contributor** on this resource group, or a custom role). Virtual Machine Contributor alone cannot create public IP addresses. |
| `vnetResourceGroup` / the VNet | `Get-AzVirtualNetwork`; attach the NIC to the subnet | Custom role or built-in role with `Microsoft.Network/virtualNetworks/read` and `Microsoft.Network/virtualNetworks/subnets/join/action` (Virtual Machine Contributor on the VNet resource group also contains both). |
| NSG `nsgName` (looked up in `vnetResourceGroup`, then `resourceGroup`) | Read; associate with the NIC | `Microsoft.Network/networkSecurityGroups/read` and `/join/action` (included in Virtual Machine Contributor). |
| Key Vault `keyVaultName` | `Set-AzKeyVaultSecret` (Windows local admin password `<vm>-localadmin`); `Get-AzKeyVault` in *Test connection* | RBAC vaults: **Key Vault Secrets Officer** (Key Vault Secrets User is read-only and **not** sufficient) plus **Reader** on the vault for the control-plane check. Access-policy vaults: secret permission *Set*. Required for Windows VMs only. |
| Subscription | `Get-AzMarketplaceTerms` / `Set-AzMarketplaceTerms -Accept` for images with `plan: true` (AlmaLinux) | Read and write on `Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements`. Alternatively accept the image terms once beforehand as a subscription owner; the handler then only reads them. |

Linux VMs are created with SSH key authentication only (`sshPublicKey` is required); no Key Vault access is needed for them.

## 9. Pre-deployment checklist

**Platform**

- [ ] Deployment option chosen (OVA, Linux, Windows) and sized for `jobs.maxConcurrent` (section 2).
- [ ] DNS A (and preferably PTR) record for the portal FQDN.
- [ ] NTP reachable; server clock within +/- 30 s (section 7).
- [ ] Online install: outbound HTTPS to the OS repositories, `packages.microsoft.com`, PowerShell Gallery. Offline install: module bundle prepared ([installation-linux.md section 5.2](installation-linux.md#52-offline-air-gapped-install)).

**Network**

- [ ] Inbound portal port (443 / 8443) from user networks; SSH/RDP from admin networks only.
- [ ] Outbound 443 to every vCenter; 636 (or 389 for StartTLS) to the directory servers; DNS; NTP.
- [ ] Optional: ICMP to the server subnets (duplicate-IP pre-check); AWS / Azure endpoints; proxy settings.
- [ ] Admin networks for `security.adminAllowedCidrs` and reverse proxies for `security.trustedProxies` identified.

**Certificates**

- [ ] Portal certificate (CSR with every user-facing name in the SAN) requested from your CA.
- [ ] Internal root / intermediate CAs available for vCenter and LDAPS trust.

**Accounts and permissions**

- [ ] Portal service account decided (Linux: `ssp`, created by the installer; Windows: gMSA or domain account).
- [ ] vCenter role `SSP-Portal` created and assigned to one service account per vCenter (section 8.1).
- [ ] Directory groups created (section 8.2); bind account created if `bindMode: search` is used.
- [ ] Optional: AWS IAM policy and access key or role (section 8.3).
- [ ] Optional: Azure service principal or managed identity with the role assignments of section 8.4; marketplace terms accepted.

**vSphere content**

- [ ] Windows Server 2025 and AlmaLinux templates per site, the guest customization specifications and the SQL Server media share; their names go into each site's **catalog values** (section 10), not into the catalog items.
- [ ] App and DB clusters per site (`workloadClusters`), VM folders and port groups that requesters may use.

**Security and operations**

- [ ] Vault key provider decided and the key backup location agreed ([vault.md](vault.md), [operations.md](operations.md#1-backup-and-restore)).
- [ ] Break-glass procedure: a local account flagged `breakGlass`, stored in your password safe.
- [ ] Backup, log retention and monitoring in place ([operations.md](operations.md)).

## 10. Deployment-specific configuration (before first use)

The repository contains **no organisation-specific data**: no site codes, vCenter names, clusters, templates, domains, groups or team names of any real environment. Everything that depends on your environment is a configuration segment, created at first start from `config/*.default.json` with neutral examples (`DC1`, `DC2`, `corp.example.com`) and `TBD-` placeholders. Complete the segments below before you offer the portal to users. Items whose values are still `TBD-` (or empty) are refused by the job runner with a message that names the missing value.

| # | Segment (configuration key) | Where to set it | What to provide | Needed by |
|---|---|---|---|---|
| 1 | `portal` (address, port, certificate) | `tools/Set-PortalEndpoint.ps1`, OVA properties | Listening address and port, certificate file or thumbprint | Everything |
| 2 | `branding` | Admin > Customization | Product name, organisation, logo, colours, login message, footer | UI |
| 3 | `auth.providers[]`, `auth.defaultProvider` | Admin > Identity | Directory type, domains (UPN suffix and NetBIOS), hosts, port and security mode, base DN, bind mode / bind credential (vault), CA certificate | Sign-in with AD / LDAP |
| 4 | `auth.roleMapping` | Admin > Customization > Role mapping | Directory groups for Requester, Approver, Admin, CatalogAdmin, SecurityAdmin, VaultAdmin | Authorisation |
| 5 | `teams[]` | Admin > Customization > Teams | Your team ids, names and directory groups (defaults: `Infrastructure`, `Cloud`) | Item visibility, approvals |
| 6 | `catalog.teamRoles` | Admin > Customization > Teams | Which of your teams owns the shipped datacenter items (`@datacenter`) and cloud items (`@cloud`) | All shipped items |
| 7 | `sites[]` | Admin > vCenter connections | Site code and name, vCenter FQDN, certificate policy, App / DB workload clusters, VM folder, DNS domain and servers, port-group filter | All vSphere items |
| 8 | `sites[].catalogValues` (keys declared in `catalog.siteValues`) | Admin > vCenter connections > Catalog values | Per site: `windowsTemplate`, `windowsCustomizationSpec`, `linuxTemplate`, `linuxCustomizationSpec`, `sqlServerMediaPath` | Windows / AlmaLinux VM, SQL Server, three-tier blueprint |
| 9 | Vault entries | Admin > Vault, Admin > vCenter connections | `vcenter-<site>` service accounts; guest credentials tagged `guest-windows`, `guest-linux`, `ad-join`, `sql-service`; LDAP bind; cloud keys | Jobs, guest installs, identity |
| 10 | `clouds.aws`, `clouds.azure` | Admin > Cloud connections | Account / subscription, region, network, images, tags; leave disabled until defined | Cloud items |
| 11 | `operations` | `config/portal.config.json` | Quarantine folder and days, rename prefix, snapshot and test-clone policies, report thresholds, power-schedule tag | Operational items |
| 12 | Data files: `software.json`, `version-baseline.json`, `hardening-baseline.json`, `backup.json` | Admin > Data files | Agent installers and checks (set to *Approved*), approved builds and advisories, hardening checks of your security standard, backup policies / tag category | Agent baseline, compliance reports, backup policy |
| 13 | `security` | Admin > Security | Session timeouts, password policy, MFA, admin networks, trusted proxies | Security |
| 14 | `vmNotes` | Admin > Customization > VM notes | Fields written into the VM notes of new builds (owner, cost centre, ticket...) | Build items |

**Adding your own per-site value.** Declare it once in `catalog.siteValues` (`key`, `label`, `help`, `usedBy`, `default`), reference it from an item as `"@site:<key>"` in `execution.fixedParameters`, and fill it per site in Admin > vCenter connections. The catalog validator rejects references to undeclared keys.

**Private editions.** Keep organisation-specific catalog items, configuration defaults and branding outside this repository (for example a private overlay applied at build time), so the public repository stays neutral.
