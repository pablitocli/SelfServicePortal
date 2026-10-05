# Roadmap

This document is the agreed development plan for the Self-Service Portal. Phase 1 is complete and is released as version 1.0.0 (see [CHANGELOG.md](../CHANGELOG.md)). **Everything in Phases 2, 3 and 4 is planned work and does not exist in the current release.** Scope and order can change. Phase 4 lists candidates, not commitments.

## Contents

1. [Status overview](#1-status-overview)
2. [Phase 1: Foundation and security (released)](#2-phase-1-foundation-and-security-released)
3. [Phase 2: Platform enablers (planned)](#3-phase-2-platform-enablers-planned)
4. [Phase 3: New catalog items (planned)](#4-phase-3-new-catalog-items-planned)
5. [Phase 4: Ideas (candidates)](#5-phase-4-ideas-candidates)
6. [Cross-cutting: re-authentication for sensitive items](#6-cross-cutting-re-authentication-for-sensitive-items)
7. [Proposing an item or feature](#7-proposing-an-item-or-feature)

---

## 1. Status overview

| Phase | Theme | Status |
|---|---|---|
| 1 | Credential vault, identity providers, user security, Linux/OVA, documentation | **Done** (1.0.0) |
| 2 | Platform enablers: scheduling, reports, software repository, dry-run, orchestration, connectors | Planned |
| 3 | 21 new catalog items | Planned. Most items depend on Phase 2 enablers. |
| 4 | API tokens, notifications, HA, key rotation, external vaults | Candidates |

## 2. Phase 1: Foundation and security (released)

| Area | Delivered |
|---|---|
| Credential vault | AES-256-GCM vault for automation credentials. Secrets are write-only through the UI and API, scoped to teams, items or system use, and every use is audited. See [vault.md](vault.md). |
| Identity providers | Local accounts, Active Directory and OpenLDAP. See [identity.md](identity.md). |
| User security | Password policy, forced password change, account lockout, TOTP MFA with recovery codes, break-glass accounts, active sessions view and revocation, admin networks (CIDR restriction for administrative roles), 30-minute idle timeout with warning, re-authentication for sensitive actions, and separation of duties with the `CatalogAdmin`, `SecurityAdmin` and `VaultAdmin` roles. See [security.md](security.md). |
| Linux and appliance | Linux support and an OVA appliance (AlmaLinux 9, built with Packer). See [installation-linux.md](installation-linux.md) and [ova.md](ova.md). |
| Documentation | Technical documentation set under `docs/`. |

## 3. Phase 2: Platform enablers (planned)

These capabilities are prerequisites for many Phase 3 items.

| # | Enabler | Description |
|---|---|---|
| E1 | Scheduled catalog items | Run catalog items on a schedule, typically reports. |
| E2 | Report viewer with history | Store each report run and show it in the portal as HTML or CSV, with history. |
| E3 | Software repository | Packages defined in JSON: name, version, installer, silent parameters, post-install check and status (*Approved* / *Pending*). Managed in **Admin > Software repository**. |
| E4 | Dry-run mode | A platform-level dry run for items that delete or change things: run every check and report the planned actions without applying them. |
| E5 | Step orchestrator | A simple orchestrator for multi-step items, with rollback of the steps already completed. |
| E6 | Pluggable connectors | Connector interface for external systems, starting with backup products and storage arrays. |

## 4. Phase 3: New catalog items (planned)

Legend: **Approval** shows whether the plan requires approval for the item. **Depends on** lists the Phase 2 enablers or other items the item is expected to need. Dependencies are indicative.

### 4.1 Network and placement (Infrastructure)

| # | Item | Scope | Approval | Depends on |
|---|---|---|---|---|
| 1 | Create Distributed Port Group | VDS, VLAN, teaming and security policy, naming convention. Checks that the VLAN and the name are not already in use. | Yes | none |
| 2 | DRS affinity / anti-affinity rule | VM-VM rules and VM-Host groups, with a conflict check against existing rules. | Yes | none |
| 3 | vMotion across clusters or sites | Pre-checks for CPU/EVC compatibility, network, datastore and capacity. Optional scheduled window. | Yes | E1 (scheduled window) |
| 4 | Host maintenance mode | N+1 capacity check, DRS evacuation, evidence recorded in the audit log. | Admin only | none |

### 4.2 VM lifecycle

| # | Item | Scope | Approval | Depends on |
|---|---|---|---|---|
| 5 | Decommission with quarantine | Power off, rename with the `DECOM-` prefix, remove from backup through the backup connector, then delete after N days unless the decommission is cancelled. | Yes | E1, E6, item 18 |
| 6 | Snapshot clean-up | Selection by age and size, consolidation. Runs as a dry run by default. | Not specified | E4 |
| 7 | Isolated test clone | Clone with a new name and MAC address, connected to an isolated port group. | Yes | none |
| 8 | Right-sizing advisor | Analyses 30 days of CPU and memory metrics. One-click apply through the existing *Resize VM* item. | Via the Resize item | E2 |

### 4.3 Unattended installs

These items run through guest operations, WinRM or SSH, with credentials taken from the vault.

| # | Item | Scope | Approval | Depends on |
|---|---|---|---|---|
| 9 | SQL Server 2022 unattended | Configuration file, instance name, collation, D/E/F/T disks formatted with a 64K allocation unit, service accounts, MaxDOP and memory settings. | Yes | E3 |
| 10 | Windows roles and features | IIS, .NET, Failover Clustering, MSDTC including its configuration. | Yes | none |
| 11 | Agent baseline | Installs agents from the software repository. Only *Approved* packages are offered (monitoring, EDR, patching). The backup agent is pre-registered as *Pending approval* and hidden until the organisation approves a backup product. No backup vendor is assumed. | Not specified | E3 |
| 12 | AlmaLinux baseline | AD join (realmd/sssd), chrony, basic CIS hardening, standard packages, sudoers by group. | Not specified | E3 |

### 4.4 Health and version reports

On demand or scheduled, published as HTML or CSV in the portal.

| # | Item | Scope | Depends on |
|---|---|---|---|
| 13 | vSphere health per site | Hosts, alarms, HA/DRS status, datastore free space, snapshots, orphaned VMDKs, outdated VMware Tools. | E1, E2 |
| 14 | Version compliance | vCenter, ESXi, VMware Tools and VM hardware versions compared with target builds defined in JSON. Flags pending VMSA advisories. | E1, E2 |
| 15 | Hardening compliance | Read-only check against the vSphere Security Configuration Guide. Remediation will be a separate item that requires approval. | E1, E2 |
| 16 | Certificate expiry | vCenter, ESXi and additional endpoints, with an email warning. | E1, E2, notifications |
| 17 | Capacity forecast | Trend from the portal's inventory history, with days remaining until the threshold. | E1, E2 |

### 4.5 Backup

| # | Item | Scope | Depends on |
|---|---|---|---|
| 18 | Add VM to a backup policy | See below. | E6 |

Item 18 is designed to be **vendor-agnostic**:

- The item assigns a policy (`Gold`, `Silver`, `Bronze` or `None`), and a connector translates the policy into the backup product's terms.
- The **default connector** writes the vSphere tag `Backup-Policy` (on AWS and Azure, the tag `BackupPolicy`). Most backup products can use this tag to select VMs for jobs dynamically, so the item works with no approved backup product.
- Connector templates are planned for Veeam, Commvault, Rubrik, Cohesity, NetBackup and PowerProtect. Each one is activated only when the organisation approves that product.
- For Cloud Ops, AWS Backup and Azure Recovery Services are planned.
- Policies are defined in Admin.
- The *Backup policy* VM notes field feeds this item.
- An on-demand backup action is shown only when the active connector supports it.

### 4.6 Cloud Ops

| # | Item | Scope | Depends on |
|---|---|---|---|
| 19 | Cloud cost and idle resources report | Unattached disks, unused IP addresses, stopped instances that still incur cost. Start/stop schedules by tag. | E1, E2 |

### 4.7 Composite blueprint

| # | Item | Scope | Depends on |
|---|---|---|---|
| 20 | Three-tier application blueprint | One request creates web, app and DB VMs, the port group if needed, an anti-affinity rule, VM notes, the agent baseline, the backup policy and SQL Server on the DB VM. It orchestrates items 1, 2, 9, 11 and 18 with rollback. | E5, items 1, 2, 9, 11, 18 |

### 4.8 Storage: new datastore

| # | Item | Depends on |
|---|---|---|
| 21 | New datastore (VMFS or NFS), optionally added to a datastore cluster | Re-authentication (available), change windows, optional storage-array connectors (E6) |

Creates a VMFS datastore on an already-presented FC or iSCSI LUN, or mounts an NFS v3 or v4.1 export. The datastore can optionally be added to an existing datastore cluster, or to a new one created with SDRS in *Manual* mode.

**Form**

- Site and cluster
- Datastore type (VMFS or NFS)
- For VMFS: a device list of unclaimed LUNs that are visible to **all** hosts of the cluster after a rescan
- For NFS: server and export
- Datastore name, validated against a per-site naming convention defined in JSON
- VMFS6
- Datastore cluster (existing or new)
- Change ticket

**Pre-checks**

- The LUN is visible on every host.
- The device is free.
- For NFS: the server is reachable and the permissions are correct.
- The datastore is compatible with the datastore cluster.

**Execution**

1. Rescan HBAs and VMFS on all hosts.
2. Create and mount the datastore.
3. Add it to the datastore cluster.
4. Apply tags.
5. Refresh the portal inventory.
6. Verify.

**Security controls**

- Every storage rescan requires a valid, recent authentication in the portal. The *Find new LUNs* lookup and the approval both require password re-confirmation, and the re-authentication is valid for 5 minutes. These use the existing input-level and item-level re-authentication (see [section 6](#6-cross-cutting-re-authentication-for-sensitive-items)).
- The job runs with the vCenter service account, but records who authorised it, when and from which IP address.
- Only one rescan runs at a time per cluster. A 10-minute cool-down (configurable) applies, and the form shows the last result with its timestamp.
- Optional change window per site. Outside the window, the Approver role is required.

**Companion items** (planned)

- Expand datastore.
- Retire datastore: check that it is empty, remove it from the datastore cluster, unmount it, and detach the device on all hosts.

**Future work**: storage-array connectors (Pure Storage, PowerStore, NetApp and others) to create and present the LUN before this item runs.

## 5. Phase 4: Ideas (candidates)

These are candidates for later releases. They are not committed and have no schedule.

| Idea | Description |
|---|---|
| API tokens | Tokens for machine-to-machine use of the API. |
| Notifications | Email, Microsoft Teams and Slack notifications for request events and reports. |
| Multi-node / HA deployment | More than one portal node, for availability. |
| Master-key rotation | Rotate the vault master key and re-encrypt the entries. |
| External vault backends | HashiCorp Vault, Azure Key Vault, AWS Secrets Manager, CyberArk, Delinea. |

## 6. Cross-cutting: re-authentication for sensitive items

Re-authentication is **already available in Phase 1**. Any catalog item, existing or new, can opt in:

- **Item level**: `"security": { "requireReauth": true }` requires the user to re-confirm their password (and OTP, if enrolled) before **submitting** a request and before **approving** it.
- **Input level**: `"requireReauth": true` on an input requires re-confirmation before that input's **lookup** runs. This is the mechanism item 21 uses for *Find new LUNs*.

The re-authentication window is set in Admin > Security (`security.session.reauthWindowMinutes`, default 5 minutes). See [catalog-authoring.md](catalog-authoring.md) and [security.md](security.md).

## 7. Proposing an item or feature

Read [CONTRIBUTING.md](../CONTRIBUTING.md) before opening an issue or pull request. A proposal for a new catalog item should describe:

- the operation and the team that will use it
- the inputs and the lookups they need
- the approval and re-authentication requirements
- the pre-checks, the rollback behaviour, and the vCenter, cloud or guest privileges it needs

To build an item yourself, follow [catalog-authoring.md](catalog-authoring.md).
