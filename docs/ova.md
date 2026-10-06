# Self-Service Portal - virtual appliance (OVA)

The appliance is an AlmaLinux 9 VM (EFI, virtual hardware version 19 by default) with the portal pre-installed by `packaging/linux/install.sh`. Per-instance settings come from OVF properties when the VM is deployed, and the `ssp-firstboot` service applies them at first boot. For a manual installation, see [installation-linux.md](installation-linux.md).

| | Default |
|---|---|
| vCPU / memory / disk | 4 / 8 GB / 60 GB thin (LVM, about 10 GB unallocated in `vg_ssp` for growth) |
| Guest OS | AlmaLinux 9 minimal, SELinux enforcing, firewalld, chrony, auditd, open-vm-tools |
| Portal | `/opt/ssp`, service `ssp-portal`, HTTPS 443 |
| OS administrator | `sspadmin` (wheel/sudo). Root login is disabled. |

---

## 1. Building the OVA

### 1.1 Requirements

| Tool | Version | Notes |
|---|---|---|
| HashiCorp Packer | >= 1.10 | `packer init` installs the `vsphere` and `qemu` plugins declared in `almalinux9.pkr.hcl` |
| packer-plugin-vsphere | >= 1.3 (written against 1.4.x) | Options marked *verify* in the template should be checked against the plugin documentation for your version |
| VMware OVF Tool | >= 4.6 | Packs the exported OVF into the OVA (`--shaAlgorithm=SHA256`) |
| python3 | >= 3.9 | `tools/add-ovf-properties.py` (standard library only) |
| AlmaLinux 9 ISO | DVD (recommended) or boot ISO | Either on a datastore, or as a URL that Packer downloads |

**Network.** The build VM gets an address from DHCP on the build port group. It must reach the Packer host over HTTP to fetch the kickstart (port 8000-9000; set `http_ip` when the host has several NICs). The Packer host must reach the VM over SSH. The VM needs internet access, or local mirrors, for the OS updates, PowerShell and the PowerShell Gallery. For an offline build, pass `--modules-dir`.

**vCenter permissions for the build account.** Create a role and assign it on the target cluster, datastore, network and folder. Verify the list against the vsphere plugin documentation for your version.

- Datastore: Allocate space, Browse datastore, Low level file operations
- Network: Assign network
- Resource: Assign virtual machine to resource pool
- Virtual machine > Edit inventory: Create new, Remove
- Virtual machine > Change configuration: Add new disk, Add or remove device, Advanced configuration, Change CPU count, Change memory, Change settings, Set annotation, Modify device settings
- Virtual machine > Interaction: Power on, Power off, Configure CD media, Connect devices, Console interaction
- Virtual machine > Provisioning: Allow read-only disk access, Allow virtual machine download
- vApp: Export
- Content library or datastore ISO access, if the ISO is uploaded by Packer (`iso_url`)

### 1.2 Build

```bash
cd packaging/ova
cp variables.pkrvars.hcl.example my-site.pkrvars.hcl      # fill in; keep it out of version control
export PKR_VAR_vcenter_password='...' PKR_VAR_build_password='...'      # optional: secrets via env
./build-ova.sh --version 1.0.0 --var-file my-site.pkrvars.hcl
# offline module bundle (Save-PSResource output, see installation-linux.md 5.2):
./build-ova.sh --version 1.0.0 --var-file my-site.pkrvars.hcl --modules-dir /srv/ssp-offline/modules
```

The wrapper runs these steps:

1. Packs the repository into `build/stage/ssp-release-<v>.tar.gz`. Instance state such as `config/*.json`, `data/` and logs is excluded. It also packs the module bundle, which is empty for an online build.
2. Runs `packer init`, `packer validate` and `packer build -only=vsphere-iso.almalinux9`:
   - Boots the ISO with the kickstart from `http/ks.cfg`, rendered with `templatefile`: minimal install, LVM with separate `/var`, `/var/log`, `/var/log/audit`, `/tmp` (`nodev,nosuid,noexec`) and `/home`, SELinux enforcing, root locked, and a temporary build user.
   - Uploads the release and the module bundle, then runs `scripts/provision.sh`. This runs `install.sh --appliance`, installs `ssp-firstboot`, applies the hardening and creates `sspadmin`.
   - Runs `scripts/cleanup.sh`, which removes secrets, logs, leases, history and the kickstart copies. A shutdown finalizer removes the build user, the SSH host keys and the machine-id at power-off.
   - Exports `<vm_name>.ovf` with a SHA256 manifest to `build/output/vsphere/`.
3. Runs `tools/add-ovf-properties.py`, which adds the product information, the `ssp.*` properties and the `com.vmware.guestInfo` transport, then rewrites the manifest.
4. Runs `ovftool --shaAlgorithm=SHA256 <ovf> build/SelfServicePortal-<version>.ova` and writes `SelfServicePortal-<version>.ova.sha256`.

`--skip-build` re-runs only steps 3 and 4 on an existing export.

The build VM is left in vCenter, powered off. Delete it once the OVA has been verified.

### 1.3 Building without vCenter (qemu)

```bash
./build-ova.sh --version 1.0.0 --var-file my.pkrvars.hcl --builder qemu    # needs KVM, qemu-img, OVMF
```

This produces `build/output/qemu/ssp-appliance.qcow2` and `build/SelfServicePortal-<v>.vmdk` (stream-optimized). Because `provision.sh` detects a non-VMware build, it creates a generic initramfs, so the disk also boots on VMware PVSCSI. Interface names differ between hypervisors, but `ssp-firstboot` always configures the first Ethernet device it finds.

To turn the disk into an OVA:
1. Create a VM in vSphere: EFI firmware, guest OS *Red Hat Enterprise Linux 9 (64-bit)*, vmxnet3, PVSCSI.
2. Import the VMDK as its disk. Upload it to a datastore and clone it with `vmkfstools -i <src>.vmdk -d thin <vm>.vmdk`. Check which source sub-formats your ESXi version accepts; regenerate with `qemu-img convert -o subformat=monolithicSparse` if needed.
3. Export the VM as an OVF template (vSphere Client, or `ovftool vi://...`) into `build/output/vsphere/`.
4. Run `./build-ova.sh --version 1.0.0 --skip-build`.

Do **not** power the VM on before exporting it, because that would run the first boot.

---

## 2. Deploying the OVA

### 2.1 vSphere Client

1. *Deploy OVF Template*, then select `SelfServicePortal-<version>.ova` (check the `.sha256` first).
2. Choose the name, folder, compute resource and storage (thin provisioning is recommended), and the network.
3. **Customize template:** fill in the properties (section 3). Password fields ask for confirmation.
4. Finish and power on. The first boot takes 1-3 minutes, then the console shows the portal URL.

### 2.2 ovftool (CLI)

Inspect the OVA first. This shows the network names and properties:

```bash
ovftool SelfServicePortal-1.0.0.ova
```

Deploy to vCenter (the OVF environment is delivered by vCenter):

```bash
ovftool --acceptAllEulas --name=ssp01 --datastore=datastore01 --diskMode=thin \
  --net:"<source network name>"="VLAN200-Servers" \
  --prop:ssp.hostname=ssp01 \
  --prop:ssp.domain=corp.example.com \
  --prop:ssp.ip=10.20.30.40 --prop:ssp.prefix=24 --prop:ssp.gateway=10.20.30.1 \
  --prop:ssp.dns=10.20.0.10,10.20.0.11 \
  --prop:ssp.ntp=ntp1.corp.example.com,ntp2.corp.example.com \
  --prop:ssp.os_password='<OS admin password>' \
  --prop:ssp.portal_admin_password='<portal admin password>' \
  --prop:ssp.ssh_enabled=true --prop:ssp.portal_port=443 \
  --powerOn \
  SelfServicePortal-1.0.0.ova \
  'vi://administrator%40vsphere.local@vcenter.corp.example.com/DC1/host/Cluster01/'
```

When deploying **directly to an ESXi host** (without vCenter), add `--X:injectOvfEnv --powerOn`. Otherwise the properties are not delivered to the guest.

Passwords on a command line end up in shell history. Use a protected script, or omit the password properties and set the passwords after deployment (section 5).

---

## 3. OVF properties

All properties are optional. Empty values use the default.

| Property | Category | Type | Default | Description |
|---|---|---|---|---|
| `ssp.hostname` | Network | string | `ssp-appliance` | Short host name (an FQDN is also accepted) |
| `ssp.domain` | Network | string | (empty) | DNS domain. The FQDN is `hostname.domain`, also used as the DNS search domain |
| `ssp.ip` | Network | string | (empty = DHCP) | Static IPv4 address |
| `ssp.prefix` | Network | uint8 | `24` | Prefix length (static IP only) |
| `ssp.gateway` | Network | string | (empty) | Default gateway (static IP only) |
| `ssp.dns` | Network | string | (empty) | Comma-separated DNS servers. With DHCP they replace the DHCP-provided servers |
| `ssp.ntp` | Network | string | (empty = chrony defaults) | Comma-separated NTP servers (names or IPs) |
| `ssp.os_password` | Appliance | password | (empty) | Password of `sspadmin`. Without it the build-time password stays in place (expired), or the account stays locked, and SSH remains disabled |
| `ssp.ssh_enabled` | Appliance | boolean | `true` | Enable sshd and open 22/tcp. Effective only when `ssp.os_password` is set |
| `ssp.portal_admin_password` | Portal | password | (empty) | Initial password of the portal `admin`. Empty means the default `ChangeMe-2026!` stays, and a change is forced at first login |
| `ssp.portal_port` | Portal | uint16 | `443` | Portal HTTPS port. The firewall is adjusted to match |

Invalid values, such as a malformed IP or a port out of range, are ignored and logged in `/var/log/ssp-firstboot.log`. The default is used instead.

> The OVF environment, **including password properties**, stays readable to vCenter administrators. Inside the guest it can be read with `vmtoolsd --cmd "info-get guestinfo.ovfEnv"`. Treat the passwords given at deployment as initial passwords and change them after the first login.

---

## 4. First boot behaviour

`ssp-firstboot.service` runs once, before `ssp-portal` and `sshd`, and only while `/etc/ssp/.firstboot-done` is absent. It performs these steps:

1. Reads the OVF environment. If none is present (for example a qemu/KVM import, or an ESXi deployment without `--X:injectOvfEnv`), it uses DHCP and the defaults.
2. Removes any leftover build user, makes sure a machine-id exists, and regenerates the SSH host keys.
3. Sets the hostname and creates the NetworkManager profile `ssp-mgmt` on the first Ethernet NIC, either static or DHCP, with DNS and the search domain. For a static IP it adds an `/etc/hosts` entry.
4. Applies the NTP servers to `/etc/chrony.conf`.
5. Creates `/etc/ssp/portal.env` with a new session secret, creates `/etc/ssp/vault.key` **only when it does not exist**, and creates a self-signed certificate with SAN = FQDN, short name and IP.
6. Runs `Set-PortalEndpoint.ps1` (port and certificate files), then sets the portal admin password if one was given.
7. Sets the `sspadmin` password. Enables or disables sshd and adjusts firewalld (portal port, ssh).
8. Writes the console banner with the portal URL, then writes `/etc/ssp/.firstboot-done`.

The log is `/var/log/ssp-firstboot.log` (mode 0600), which is also in the journal. Passwords are never logged. If a step fails, the marker is not written and the first boot runs again at the next boot.

To re-run it after changing the vApp properties, run `sudo ssp-firstboot --force`. This keeps the vault key and any certificate that is not the appliance's own self-signed one. Alternatively, run `sudo rm /etc/ssp/.firstboot-done && sudo reboot`.

---

## 5. First login

1. **Console / SSH:** `sspadmin` with `ssp.os_password`. Without the property, use the build-time password (it is expired, so you must set a new one). If no build-time password was set, the account is locked; set `ssp.os_password` and run the first boot again.
2. **Portal:** `https://<fqdn>/` (the URL is also on the VM console). Sign in as `admin` with `ssp.portal_admin_password`, or `ChangeMe-2026!`, then change the password.
3. Without SSH: enable it from the console with `sudo systemctl enable --now sshd && sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload`.

## 6. Post-deployment checklist

- [ ] DNS **A and PTR** records for the appliance FQDN.
- [ ] Replace the self-signed TLS certificate with a CA-issued one ([installation-linux.md section 8](installation-linux.md#8-tls-certificate-replacement)).
- [ ] Trust your internal root CA in the OS store if vCenter or LDAPS use it.
- [ ] Admin > Customization: branding, teams, directory and role mapping (identity providers, AD groups).
- [ ] **MFA** for portal administrators, where your identity provider supports it. Disable local portal accounts except break-glass.
- [ ] Admin > vCenter connections / Cloud connections: credentials, then *Test connection*.
- [ ] Admin > Catalog: replace the `TBD-...` template and customization-spec names.
- [ ] Back up `/etc/ssp/vault.key` and schedule `ssp-backup` ([installation-linux.md section 11](installation-linux.md#11-backup-and-restore)).
- [ ] Change the passwords that were passed as OVF properties. Restrict or disable SSH.
- [ ] Point the appliance at your internal NTP servers if `ssp.ntp` was left empty.
- [ ] VM: take a snapshot after configuration (do not keep it long-term), add the VM to your VM backup policy, and add monitoring (HTTPS check on `/login`).

## 7. Appliance hardening summary

| Area | Setting |
|---|---|
| Partitioning | Separate LVs for `/var`, `/var/log`, `/var/log/audit`, `/tmp` (`nodev,nosuid,noexec`) and `/home` (`nodev`) |
| Accounts | root locked (no password, no SSH). Admin through `sspadmin` + sudo (wheel). Build user removed. |
| SELinux | Enforcing |
| SSH | `PermitRootLogin no`, `MaxAuthTries 4`, `ClientAliveInterval 300`, `ClientAliveCountMax 3`, `LoginGraceTime 60`, no X11/TCP forwarding, login banner. Disabled when no OS password is supplied. |
| Network stack | sysctl `/etc/sysctl.d/60-ssp-hardening.conf`: no forwarding or redirects, no source routing, rp_filter, log martians, syncookies, ASLR, `dmesg_restrict` |
| Firewall | firewalld: only the portal port and (optionally) ssh |
| Audit | auditd enabled, `audit=1` on the kernel command line |
| Updates | `dnf-automatic-notifyonly.timer` reports pending **security** updates (motd/journal) without installing them |
| Other | Ctrl-Alt-Del masked, core dumps disabled, portal service sandboxed by systemd ([installation-linux.md section 7](installation-linux.md#7-service-management)) |
| Per-instance secrets | SSH host keys, machine-id, session secret, vault key and TLS key are generated on each deployed VM. None ship in the OVA. |

This is a light, CIS-style baseline, not a certified CIS benchmark. Run your own scanner (for example OpenSCAP `xccdf_org.ssgproject.content_profile_cis_server_l1`) and tailor the result.

## 8. Updating the appliance

**Portal:** copy the new release to the appliance, then run:

```bash
sudo ssp-backup
sudo tar -xzf SelfServicePortal-<new>.tar.gz -C /var/tmp
sudo /var/tmp/SelfServicePortal/packaging/linux/install.sh --upgrade
```

`/tmp` is `noexec`, so use `/var/tmp`. The details, including the review folder for customized catalog items, are in [installation-linux.md section 10](installation-linux.md#10-upgrade).

**OS:** check with `sudo dnf check-update --security` (also reported in the motd), then run `sudo dnf upgrade` and reboot if the kernel or glibc changed. Take a VM snapshot before you start.

**PowerShell modules:** run `sudo /var/tmp/SelfServicePortal/packaging/linux/install.sh --only modules`. This installs missing modules; existing ones are not upgraded. To upgrade one, run `sudo pwsh -c "Update-PSResource -Name VMware.PowerCLI -Scope AllUsers"`.

## 9. Console troubleshooting

| Problem | Check / fix |
|---|---|
| No portal URL on the console / portal down | `systemctl status ssp-firstboot ssp-portal`, `journalctl -u ssp-firstboot -b`, `less /var/log/ssp-firstboot.log` |
| Properties not applied | The VM was deployed without vApp options, or directly to ESXi without `--X:injectOvfEnv`. Check whether `sudo vmtoolsd --cmd "info-get guestinfo.ovfEnv"` returns XML (the output contains the passwords). Fix the properties in vCenter (VM > Configure > vApp Options), then run `sudo ssp-firstboot --force`. |
| Wrong IP / no network | `nmcli -f NAME,DEVICE,STATE connection`, `nmcli connection show ssp-mgmt`, `ip -br addr`. Check the port group and VLAN. To fix by hand: `sudo nmcli connection modify ssp-mgmt ipv4.addresses 10.20.30.40/24 ipv4.gateway 10.20.30.1 ipv4.method manual && sudo nmcli connection up ssp-mgmt` |
| Cannot log in as `sspadmin` | The OS password property was empty and no build-time password was set, so the account is locked. Set `ssp.os_password` in vApp options and re-run the first boot (from a rescue shell), or reset the password with the standard RHEL 9 `rd.break` procedure. |
| SSH refused | SSH is disabled when `ssp.os_password` is empty or `ssp.ssh_enabled=false`. See section 5 step 3. |
| Time wrong / LDAP or TLS errors | `chronyc sources -v`. Set `ssp.ntp`, or edit `/etc/chrony.conf` and run `systemctl restart chronyd`. |
| Certificate shows the old host name | Re-run `sudo ssp-firstboot --force`, which regenerates the appliance's own self-signed certificate, or install a CA certificate. |
| Disk full | `df -h`. Extend with the free space in `vg_ssp`: `sudo lvextend -r -L +5G /dev/vg_ssp/lv_var`. Or grow the VMDK, then grow the partition (for example `growpart` from `cloud-utils-growpart`) and run `pvresize`. |

Further portal-level troubleshooting (libldap, port 443, SELinux, certificates) is in [installation-linux.md section 13](installation-linux.md#13-troubleshooting).
