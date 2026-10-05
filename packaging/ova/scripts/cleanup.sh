#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal appliance - template cleanup (last Packer provisioner, runs as root).
#
# Removes everything that must be unique per deployed VM or must not ship in the OVA: per-instance
# portal secrets, SSH host keys, machine-id, DHCP leases, logs, shell history, kickstart copies
# (contain the build password), build files. Optional zero-fill of free space for a smaller OVA.
#
# The build user, its sudo rule, SSH host keys and machine-id are still needed by Packer until it
# powers the VM off, so they are removed by a one-shot finalizer that runs at shutdown (ExecStop).
#
# Environment: SSP_BUILD_USER (default: $SUDO_USER), SSP_ZERO_FREE_SPACE (true|false, default false)
# =====================================================================================================
set -Eeuo pipefail

BUILD_USER="${SSP_BUILD_USER:-${SUDO_USER:-}}"
ZERO="${SSP_ZERO_FREE_SPACE:-false}"
log() { printf '%s [cleanup] %s\n' "$(date '+%F %T')" "$*"; }
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -n "$BUILD_USER" && "$BUILD_USER" != root ]] || { echo "SSP_BUILD_USER not set." >&2; exit 1; }

log "Package caches"
dnf clean all >/dev/null
rm -rf /var/cache/dnf/*

log "Per-instance portal state (re-created by ssp-firstboot)"
rm -f /etc/ssp/portal.env /etc/ssp/vault.key /etc/ssp/tls/portal.crt /etc/ssp/tls/portal.key /etc/ssp/.firstboot-done
find /opt/ssp/config -maxdepth 1 -type f -name '*.json' ! -name '*.default.json' -delete
rm -rf /opt/ssp/data/secrets
find /opt/ssp/logs -type f -delete
rm -rf /var/lib/ssp/upgrades /var/lib/ssp/.cache /var/lib/ssp/.local/share/powershell/PSReadLine

log "Network leases and cloud-init state"
rm -f /var/lib/NetworkManager/*.lease /var/lib/NetworkManager/internal-* /var/lib/dhclient/* 2>/dev/null || true
rm -rf /var/lib/cloud

log "Kickstart copies (they contain the build password) and installer logs"
rm -f /root/anaconda-ks.cfg /root/original-ks.cfg /root/ks-post.log
rm -rf /var/log/anaconda

log "Logs and shell history"
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*-[0-9]*' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} +
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -f /root/.bash_history /home/*/.bash_history /var/lib/ssp/.bash_history
unset HISTFILE

# Fallback for ssp-firstboot in case the finalizer could not delete the build user.
printf '%s\n' "$BUILD_USER" >/etc/ssp-build-user
chmod 0600 /etc/ssp-build-user

log "Installing the shutdown finalizer"
cat >/usr/local/sbin/ssp-build-finalize <<EOF
#!/bin/bash
# Runs once when Packer powers the build VM off; deletes itself.
userdel -r -f '$BUILD_USER' 2>/dev/null || true
rm -f /etc/sudoers.d/90-packer-build /etc/ssp-build-user
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then rm -f /var/lib/dbus/machine-id; fi
rm -rf /var/tmp/* /tmp/* 2>/dev/null
rm -f /root/.bash_history
systemctl disable ssp-build-finalize.service
rm -f /etc/systemd/system/ssp-build-finalize.service /usr/local/sbin/ssp-build-finalize
sync
EOF
chmod 0700 /usr/local/sbin/ssp-build-finalize
cat >/etc/systemd/system/ssp-build-finalize.service <<'EOF'
[Unit]
Description=Self-Service Portal template finalizer (runs at build shutdown)
DefaultDependencies=no
After=local-fs.target
Before=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/ssp-build-finalize
TimeoutStopSec=120
[Install]
WantedBy=multi-user.target
EOF
restorecon -F /usr/local/sbin/ssp-build-finalize /etc/systemd/system/ssp-build-finalize.service 2>/dev/null || true
systemctl daemon-reload
systemctl start ssp-build-finalize.service

if [[ "$ZERO" == true ]]; then
    log "Zero-filling free space (smaller OVA; takes a while)"
    # /var/log/audit is skipped on purpose: filling it can trigger auditd's disk-full action.
    for mp in / /boot /var /var/log /home /tmp; do
        mountpoint -q "$mp" || [[ "$mp" == / ]] || continue
        dd if=/dev/zero of="$mp/.zero.fill" bs=1M status=none 2>/dev/null || true
        rm -f "$mp/.zero.fill"
    done
    swapdev="$(swapon --noheadings --show=NAME | head -n1 || true)"
    if [[ -n "$swapdev" ]]; then
        swapuuid="$(blkid -s UUID -o value "$swapdev" || true)"   # keep the UUID: fstab may use it
        if swapoff "$swapdev"; then
            dd if=/dev/zero of="$swapdev" bs=1M status=none 2>/dev/null || true
            mkswap ${swapuuid:+-U "$swapuuid"} "$swapdev" >/dev/null
            swapon "$swapdev" || true
        fi
    fi
fi
fstrim -av >/dev/null 2>&1 || true
sync
log "Cleanup finished - the finalizer completes the template at power-off."
