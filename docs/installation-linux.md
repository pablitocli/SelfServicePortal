# Self-Service Portal - Linux installation guide

This guide covers installing the Self-Service Portal on a Linux server with `packaging/linux/install.sh`. For the pre-built virtual appliance, see [ova.md](ova.md).

## 1. Supported platforms

| Operating system | Status |
|---|---|
| AlmaLinux 9, Red Hat Enterprise Linux 9, Rocky Linux 9 (x86_64) | Primary. Also the base of the OVA appliance. |
| Ubuntu 24.04 LTS (x86_64) | Supported |

Other RHEL 9 rebuilds are accepted with a warning. Other Ubuntu releases are not supported.

## 2. Sizing

| | Minimum | Recommended |
|---|---|---|
| vCPU | 2 | 4 |
| Memory | 4 GB | 8 GB |
| Disk | 40 GB | 60 GB |

PowerShell plus the PowerCLI, AWS.Tools and Az modules take about 2 GB under `/usr/local/share/powershell/Modules`. Request data and job logs grow under `/opt/ssp/data` and `/opt/ssp/logs`. Every running job is a separate `pwsh` process that uses about 150 to 300 MB, so plan memory for the number of jobs you expect to run at the same time.

## 3. Prerequisites

- Root access (`sudo`).
- A DNS A record, and preferably a PTR record, for the portal FQDN.
- Time synchronisation (chrony is installed and enabled). Kerberos/LDAP and TLS fail when the clock drifts.
- **Online install:** outbound HTTPS to the OS repositories, `packages.microsoft.com` (PowerShell) and the PowerShell Gallery.
- **Offline install:** see section 5.2.
- Service accounts: vCenter, AD/LDAP bind and cloud credentials. These are configured in the portal after installation.

## 4. Quick start (online)

```bash
# Copy the release archive to the server, then:
sudo mkdir -p /tmp/ssp && sudo tar -xzf SelfServicePortal-<version>.tar.gz -C /tmp/ssp   # or unzip the .zip
cd /tmp/ssp/SelfServicePortal
sudo SSP_ADMIN_PASSWORD='<initial portal admin password>' \
     ./packaging/linux/install.sh --hostname-cert ssp01.corp.example.com
```

You can also pass `--source` with a zip or tar.gz instead of extracting the release yourself:
`sudo ./install.sh --source /root/SelfServicePortal-<version>.zip`.

When the installer finishes, open `https://<fqdn>/` and sign in as `admin`. The default password `ChangeMe-2026!` applies only when you did not set one, and the portal makes you change it at first login.

### Options

| Option | Meaning |
|---|---|
| `--source <dir\|zip\|tar.gz>` | Release tree or archive. Default: the tree that contains the script. |
| `--modules-dir <dir>` | **Offline mode**: PowerShell modules saved with `Save-PSResource`. |
| `--pwsh-package <file>` | **Offline mode**: local PowerShell `.rpm` or `.deb` file. |
| `--no-cloud-modules` | Skip AWS.Tools and Az. The Cloud Ops items will not work. |
| `--powercli-module <name>` | `VMware.PowerCLI` (default) or `VCF.PowerCLI` (name used by newer releases). |
| `--port <n>` | HTTPS port. Default 443. |
| `--hostname-cert <fqdn>` | Name used for the self-signed certificate. Default: `hostname -f`. |
| `--admin-password <pw>` | Initial password for the portal `admin` account. Prefer the `SSP_ADMIN_PASSWORD` environment variable, because a command-line argument shows up in the process list and in shell history. |
| `--skip-firewall` | Leave firewalld/ufw unchanged. |
| `--upgrade` | Upgrade an existing installation (section 10). |
| `--no-start` | Enable the service without starting it. |
| `--only <steps>` | Run only the listed steps (`packages,pwsh,modules,user,tree,etc,endpoint,admin,service,firewall`). Useful for repairs. |
| `--dry-run` | Print every action without changing anything. |
| `--appliance` | Used only by the OVA build. Per-instance secrets are created at first boot instead. |

The installer is idempotent, so you can run it again at any time. Existing configuration, data, the vault key and certificates are never overwritten. Each run is appended to `/var/log/ssp-install.log` (mode 0600). Passwords are never written to the log.

## 5. What install.sh does

1. **Pre-flight.** Checks that it runs as root, detects the OS from `/etc/os-release`, validates the release tree and checks free disk space.
2. **OS packages.**
   - AlmaLinux/RHEL: `openssl openldap openldap-clients chrony firewalld curl unzip tar jq python3 policycoreutils-python-utils`, plus `open-vm-tools` on VMware.
   - Ubuntu: `openssl libldap2 ldap-utils chrony ufw curl unzip tar jq ca-certificates python3`, plus `open-vm-tools` on VMware.
   - `libldap` is the OpenLDAP client library that .NET `System.DirectoryServices.Protocols` loads on Linux. The client tools (`ldapsearch`) are installed for troubleshooting.
   - **libldap compatibility link.** PowerShell 7.4 runs on .NET 8, which loads `libldap-2.5.so.0`. AlmaLinux/RHEL 9 and Ubuntu 24.04 ship OpenLDAP 2.6 (`libldap.so.2`), so the installer creates `libldap-2.5.so.0 -> libldap.so.2` in the system library directory and runs `ldconfig`. Without it, LDAP / Active Directory sign-in fails (local accounts keep working).
3. **PowerShell 7.4+.** Installed from the Microsoft repository (`packages-microsoft-prod`), or from `--pwsh-package`.
4. **PowerShell modules**, installed machine-wide (`Install-PSResource -Scope AllUsers` into `/usr/local/share/powershell/Modules`):
   - Pode **2.14.1**: required. The installation fails without it.
   - VMware.PowerCLI or VCF.PowerCLI: needed for the vSphere items. Either module satisfies the check.
   - AWS.Tools.Installer, then AWS.Tools.Common, EC2, SimpleSystemsManagement and SecurityToken (optional).
   - Az.Accounts, Compute, Network, Resources, KeyVault and MarketplaceOrdering (optional).
   - If an optional module fails to install, the installer prints a warning and continues.
5. **Service account.** Creates the system user and group `ssp`, with no login shell and home directory `/var/lib/ssp`.
6. **Portal tree.** Copies the code to `/opt/ssp`, owned by `ssp:ssp`, with directories at 0750 and files at 0640. `packaging/` and `tests/` are not copied. From `config/`, only `*.default.json` is copied. From `data/` and `logs/`, only the directory structure is copied. Installs the helpers `/usr/local/sbin/ssp-backup` and `/usr/local/sbin/ssp-uninstall`.
7. **/etc/ssp.** Creates `portal.env` with a 64-character session secret, the vault key (only if it does not exist) and a self-signed TLS certificate (only if none exists).
8. **Endpoint.** Runs `tools/Set-PortalEndpoint.ps1 -Port <port> -CertificateFile ... -CertificateKeyFile ...` as `ssp`.
9. **Admin password** (optional). Runs `tools/Set-PortalLocalUser.ps1 -Username admin` as `ssp`. The password is passed through an environment variable, never as an argument.
10. **systemd.** Installs `ssp-portal.service`, then enables and (re)starts it.
11. **Firewall.** Opens the portal port and 22/tcp in firewalld or ufw. ufw is not enabled automatically when it is inactive.

## 5.1 Online install

This is the quick start above. The server needs outbound HTTPS to the OS repositories, `packages.microsoft.com` and the PowerShell Gallery.

## 5.2 Offline (air-gapped) install

On a machine with internet access and PowerShell 7.4 or later:

```powershell
$dest = 'C:\ssp-offline\modules'
New-Item -ItemType Directory -Force $dest | Out-Null
Save-PSResource -Name Pode -Version 2.14.1 -Path $dest -TrustRepository
Save-PSResource -Name VMware.PowerCLI -Path $dest -TrustRepository        # or VCF.PowerCLI
'AWS.Tools.Common','AWS.Tools.EC2','AWS.Tools.SimpleSystemsManagement','AWS.Tools.SecurityToken',
'Az.Accounts','Az.Compute','Az.Network','Az.Resources','Az.KeyVault','Az.MarketplaceOrdering' |
    ForEach-Object { Save-PSResource -Name $_ -Path $dest -TrustRepository }   # dependencies are saved too
```

Also download the PowerShell package for the target OS from the PowerShell GitHub releases page:
`powershell-7.4.x-1.rh.x86_64.rpm` for RHEL 9, or `powershell_7.4.x-1.deb_amd64.deb` for Ubuntu.

Copy both to the server and run:

```bash
sudo ./packaging/linux/install.sh --pwsh-package /root/offline/powershell-7.4.x-1.rh.x86_64.rpm \
     --modules-dir /root/offline/modules
```

The OS packages listed in section 5 must still come from a reachable repository, such as a local mirror, Satellite or an ISO repository. PowerShell's own dependencies are resolved from the same source.

## 6. File locations

| Path | Owner / mode | Content |
|---|---|---|
| `/opt/ssp` | `ssp:ssp` 0750 | Portal tree: `Start-Portal.ps1`, `modules/`, `web/`, `tools/`, `automation/`, `catalog/` |
| `/opt/ssp/config` | `ssp:ssp` | `portal.config.json`, `local-users.json` (created at first start) and the shipped `*.default.json` |
| `/opt/ssp/data` | `ssp:ssp` | Requests, inventory cache, branding, portal-managed state |
| `/opt/ssp/logs` | `ssp:ssp` | Pode error and request logs, `jobs/` job logs |
| `/etc/ssp` | `root:ssp` 0750 | Configuration and secrets directory |
| `/etc/ssp/portal.env` | `root:ssp` 0640 | `SSP_PORTAL_ROOT`, `SSP_SESSION_SECRET`, `SSP_VAULT_KEYFILE` (systemd EnvironmentFile) |
| `/etc/ssp/vault.key` | `ssp:ssp` 0400 | **Master key of the credential vault.** 32 random bytes, base64 encoded |
| `/etc/ssp/tls/portal.crt` | `root:ssp` 0644 | Server certificate (PEM, leaf first, then intermediates) |
| `/etc/ssp/tls/portal.key` | `ssp:ssp` 0400 | Private key (PEM, unencrypted) |
| `/etc/systemd/system/ssp-portal.service` | root 0644 | Service unit |
| `/var/lib/ssp` | `ssp:ssp` 0750 | Home of the service account (pwsh caches, PowerCLI user settings), `upgrades/` review folders |
| `/usr/local/share/powershell/Modules` | root 0755 | Machine-wide PowerShell modules |
| `/var/log/ssp-install.log` | root 0600 | Installer log |
| `/var/backups/ssp` | root 0700 | Pre-upgrade and `ssp-backup` archives |

## 7. Service management

```bash
systemctl status ssp-portal
systemctl restart ssp-portal            # also terminates jobs that are running
journalctl -u ssp-portal -f             # console output of the portal
journalctl -u ssp-portal --since "1 hour ago"
tail -f /opt/ssp/logs/*.log             # Pode error and request logs
```

The unit runs as `ssp` with `CAP_NET_BIND_SERVICE` as its only capability, which is how a non-root process binds port 443. It also has the following hardening: `NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`, `ProtectSystem=full`, `ProtectHome`, kernel/cgroup/clock protection, `RestrictNamespaces`, `RestrictSUIDSGID` and `LockPersonality`.

`MemoryDenyWriteExecute` and system-call filters are deliberately left out, because the .NET JIT and the child `pwsh` job processes need them.

Put local changes in a drop-in, which upgrades do not overwrite:

```bash
sudo systemctl edit ssp-portal          # e.g. [Service] Environment=HTTPS_PROXY=http://proxy.corp.example.com:3128
```

## 8. TLS certificate replacement

The installer creates a self-signed certificate: RSA 3072, valid for 825 days, with SAN = FQDN, short name and IP. Replace it with a certificate issued by your CA.

```bash
FQDN=ssp01.corp.example.com
cd /root

# 1. Key + CSR (SAN is mandatory for browsers)
openssl req -new -newkey rsa:3072 -nodes -keyout portal.key -out portal.csr \
  -subj "/CN=$FQDN/O=Your Organization" \
  -addext "subjectAltName=DNS:$FQDN,DNS:${FQDN%%.*}" \
  -addext "extendedKeyUsage=serverAuth"

# 2. Submit portal.csr to your CA (Web Server template). You receive portal-signed.crt + the chain.

# 3. Verify the chain and that certificate and key match
openssl verify -CAfile root-ca.crt -untrusted intermediate-ca.crt portal-signed.crt
openssl x509 -in portal-signed.crt -noout -pubkey | openssl sha256
openssl pkey -in portal.key -pubout | openssl sha256          # must print the same hash

# 4. Install: leaf first, then the intermediate(s); never the private key in the .crt
cat portal-signed.crt intermediate-ca.crt > /etc/ssp/tls/portal.crt
chown root:ssp /etc/ssp/tls/portal.crt && chmod 0644 /etc/ssp/tls/portal.crt
install -o ssp -g ssp -m 0400 portal.key /etc/ssp/tls/portal.key
restorecon -R /etc/ssp 2>/dev/null || true
systemctl restart ssp-portal

# 5. Check from a client
openssl s_client -connect $FQDN:443 -servername $FQDN -showcerts </dev/null | openssl x509 -noout -subject -issuer -dates
```

If the CA delivered a PFX/PKCS#12 file, convert it:

```bash
openssl pkcs12 -in portal.pfx -nocerts -nodes -out portal.key            # private key (unencrypted)
openssl pkcs12 -in portal.pfx -clcerts -nokeys -out portal-signed.crt    # leaf
openssl pkcs12 -in portal.pfx -cacerts -nokeys -out chain.crt            # intermediates
cat portal-signed.crt chain.crt > /etc/ssp/tls/portal.crt
```

The key must be an unencrypted PEM. Protect it through its file permissions. The certificate paths are fixed, so the endpoint configuration does not change. Only rerun `Set-PortalEndpoint.ps1` when you change the port.

If clients report an incomplete chain, also add the intermediate certificate to the OS trust store, so that .NET can build the chain:
- AlmaLinux/RHEL: copy it to `/etc/pki/ca-trust/source/anchors/`, then run `update-ca-trust`.
- Ubuntu: copy it to `/usr/local/share/ca-certificates/*.crt`, then run `update-ca-certificates`.

Do the same with your **internal root CA** when vCenter or LDAPS use certificates from that CA.

## 9. Firewall and port matrix

**Inbound**

| Port | Purpose | Notes |
|---|---|---|
| 443/tcp (or `--port`) | Portal HTTPS | Opened by the installer |
| 22/tcp | SSH administration | Opened by the installer. Restrict it to admin networks or disable it. |

**Outbound** (from the portal server)

| Destination | Port | Purpose |
|---|---|---|
| vCenter Server(s) | 443/tcp | PowerCLI (vSphere items, inventory, connection tests) |
| Domain controllers / LDAP | 636/tcp (LDAPS), 389/tcp (LDAP / StartTLS), 3268-3269/tcp if the Global Catalog is used | Portal authentication and group resolution |
| DNS servers | 53/udp+tcp | Name resolution |
| NTP servers | 123/udp | Time synchronisation |
| AWS endpoints (`ec2`, `ssm`, `sts` `.<region>.amazonaws.com`) | 443/tcp | Cloud Ops AWS (optional) |
| Azure (`login.microsoftonline.com`, `management.azure.com`, `*.vault.azure.net`) | 443/tcp | Cloud Ops Azure (optional) |
| OS repositories, `packages.microsoft.com`, PowerShell Gallery | 443/tcp | Install, upgrade and patching only (not needed offline) |

If outbound traffic goes through a proxy, set `HTTPS_PROXY`/`NO_PROXY` in a systemd drop-in (section 7). Make sure vCenter and the domain controllers are listed in `NO_PROXY`.

Manual firewall commands:

```bash
# AlmaLinux/RHEL
firewall-cmd --permanent --add-port=443/tcp && firewall-cmd --reload
firewall-cmd --permanent --remove-service=ssh && firewall-cmd --reload   # disable SSH access
# Ubuntu
ufw allow 443/tcp && ufw allow 22/tcp && ufw enable
```

## 10. Upgrade

```bash
sudo tar -xzf SelfServicePortal-<new>.tar.gz -C /tmp/ssp-new
cd /tmp/ssp-new/SelfServicePortal
sudo ./packaging/linux/install.sh --upgrade
```

What the upgrade does:
- It writes a pre-upgrade backup (code, configuration and data, without logs) to `/var/backups/ssp/pre-upgrade-<timestamp>.tar.gz`, then stops the service.
- **Replaced:** `Start-Portal.ps1`, `modules/`, `web/`, `tools/`, `automation/` (except `handlers/`), `catalog/_templates`, `catalog/schema`, `docs/` and `config/*.default.json`.
- **Preserved:** `config/*.json`, `data/`, `logs/` and `/etc/ssp` (vault key, session secret, certificate).
- **`catalog/items/`:** new items are added. An item you have edited is **kept**, and the new shipped version is saved to `/var/lib/ssp/upgrades/<timestamp>/` so you can merge it by hand.
- **`automation/handlers/`:** custom handlers are kept. Shipped handlers are updated, and the previous version is saved as `<name>.previous` in the same review folder.
- The endpoint configuration is kept unless you pass `--port`. Modules are checked again, so Pode is upgraded to the version the release requires.
- New configuration settings are added by the portal at start-up.

**Rollback:** run `systemctl stop ssp-portal`, then `tar -xzpf /var/backups/ssp/pre-upgrade-<ts>.tar.gz -C /`, then `systemctl start ssp-portal`.

## 11. Backup and restore

> **The vault key is the only way to decrypt the stored vCenter and cloud credentials.** If `/etc/ssp/vault.key` is lost, every stored credential has to be entered again. Anyone who holds the key together with `/opt/ssp/data` can decrypt them. Store backups encrypted, or keep the key separately (`--exclude-key`).

```bash
sudo ssp-backup                                  # /var/backups/ssp/ssp-backup-<host>-<ts>.tar.gz (+ .sha256)
sudo ssp-backup --exclude-key -o /mnt/backup     # key written to <archive>.vault.key - move it elsewhere
sudo ssp-backup --stop-service --keep 14         # consistent copy, keep 14 archives
```

The archive contains `/opt/ssp/{config,data,catalog,automation/handlers}` and `/etc/ssp` (env file, vault key, TLS key). It does not contain the code, which you can reinstall from the release, or the logs.

Schedule it with cron or a systemd timer, for example in `/etc/cron.d/ssp-backup`: `30 1 * * * root /usr/local/sbin/ssp-backup --keep 14`. Copy the archives off the server.

**Restore** on the same server, or on a new server after running `install.sh` with the **same** release:

```bash
sudo systemctl stop ssp-portal
sha256sum -c ssp-backup-<host>-<ts>.tar.gz.sha256
sudo tar -xzpf ssp-backup-<host>-<ts>.tar.gz -C /
# only for archives taken with --exclude-key:
sudo install -o ssp -g ssp -m 0400 <archive>.vault.key /etc/ssp/vault.key
sudo chown -R ssp:ssp /opt/ssp && sudo restorecon -R /opt/ssp /etc/ssp 2>/dev/null || true
sudo systemctl start ssp-portal
```

On a new server with a different name, also replace the TLS certificate (section 8).

## 12. Uninstall

```bash
sudo ssp-uninstall                 # stop/disable/remove the service; data, /etc/ssp and the ssp account are kept
sudo ssp-uninstall --purge         # also delete /opt/ssp, /etc/ssp (vault key!), /var/lib/ssp and the account
```

`--purge` asks you to type `PURGE`, unless you pass `--yes`. PowerShell and the modules in `/usr/local/share/powershell/Modules` are left in place, because other tools may share them. Remove them by hand if you need to: `dnf remove powershell` or `apt remove powershell`.

## 13. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `systemctl status` shows `status=203/EXEC` | `/usr/bin/pwsh` is missing. Run `install.sh --only pwsh`. Check with `pwsh -v`. |
| `Unable to load shared library 'libldap-2.5.so.0'` or `System.DirectoryServices.Protocols` errors during AD/LDAP login | The OpenLDAP client library or its .NET 8 compatibility link is missing. AlmaLinux/RHEL: `dnf install openldap`; Ubuntu 24.04: `apt install libldap2`. Then run `install.sh --only packages` (creates `libldap-2.5.so.0 -> libldap.so.2`) or create the link by hand (`ln -s libldap.so.2 /usr/lib64/libldap-2.5.so.0 && ldconfig`). Check with `ldconfig -p \| grep libldap` and restart the service. |
| LDAPS works but StartTLS fails with "server unavailable" | The directory refuses anonymous rootDSE reads, which .NET needs on Linux to open the connection before StartTLS. Use LDAPS (636), or allow anonymous read of the rootDSE. |
| `Permission denied` / `SocketException (13)` when binding 443 | The service is not running with `AmbientCapabilities=CAP_NET_BIND_SERVICE`, for example because a drop-in overrides it (`systemctl cat ssp-portal`) or because you started the portal by hand as `ssp`. Use the service, or a port above 1024 for manual tests. |
| `Address already in use` | Another web server holds the port: `ss -ltnp 'sport = :443'`. |
| Certificate errors at start-up | The key is not readable by `ssp` (it must be `ssp:ssp 0400`), the key is encrypted (it must be an unencrypted PEM), or the key does not match the certificate (compare the public key hashes, section 8). The endpoint is not configured: run `install.sh --only endpoint`. |
| Browser: `NET::ERR_CERT_COMMON_NAME_INVALID` | The URL name is not in the SAN. Reissue the certificate with the correct names. |
| SELinux denials (AlmaLinux/RHEL) | `ausearch -m avc -ts recent`. Files moved instead of copied can keep a wrong label: run `restorecon -Rv /opt/ssp /etc/ssp`. The service runs unconfined (`unconfined_service_t`), so no port labelling is needed. |
| `Failed to load module Pode` | `pwsh -NoProfile -c "Get-Module -ListAvailable Pode"` must show version 2.14.1 under `/usr/local/share/powershell/Modules`. Run `install.sh --only modules`. |
| PowerCLI cannot connect: certificate errors | Use the per-site certificate policy in Admin > vCenter connections, or trust the vCenter CA in the OS store (section 8). |
| Service restarts in a loop | `journalctl -u ssp-portal -n 200` and `/opt/ssp/logs/`. For one interactive diagnostic run with the same identity, environment and capability as the service: `systemctl stop ssp-portal; systemd-run --pty --wait --uid=ssp --gid=ssp -p WorkingDirectory=/opt/ssp -p EnvironmentFile=/etc/ssp/portal.env -p AmbientCapabilities=CAP_NET_BIND_SERVICE /usr/bin/pwsh -NoProfile -File /opt/ssp/Start-Portal.ps1 -ShowErrors` (Ctrl+C to stop, then `systemctl start ssp-portal`). |
| `/tmp` mounted `noexec` (hardened hosts) | The portal does not execute anything from `/tmp`. If a module does, set `Environment=TMPDIR=/var/tmp` in a drop-in. |
