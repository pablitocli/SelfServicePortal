#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal appliance - provisioning (runs as root inside the Packer build VM).
#
#  1. OS update, then packaging/linux/install.sh --appliance (everything except per-instance secrets)
#  2. first boot service (ssp-firstboot) that applies the OVF properties on each deployed copy
#  3. light CIS-style hardening (sysctl, sshd, banner, auditd, dnf-automatic notify-only)
#  4. OS administrator account 'sspadmin' (wheel), password expired until first boot / first login
#
# Environment (set by almalinux9.pkr.hcl):
#   SSP_VERSION, SSP_RELEASE_ARCHIVE, SSP_MODULES_ARCHIVE, SSP_CLOUD_MODULES (true|false),
#   SSP_POWERCLI_MODULE, SSP_OS_UPDATE (true|false), SSP_SSPADMIN_INITIAL_PASSWORD (sensitive)
# =====================================================================================================
set -Eeuo pipefail

: "${SSP_VERSION:?SSP_VERSION is required}"
: "${SSP_RELEASE_ARCHIVE:=/var/tmp/ssp-release.tar.gz}"
: "${SSP_MODULES_ARCHIVE:=/var/tmp/ssp-modules.tar.gz}"
: "${SSP_CLOUD_MODULES:=true}"
: "${SSP_POWERCLI_MODULE:=VMware.PowerCLI}"
: "${SSP_OS_UPDATE:=true}"
: "${SSP_SSPADMIN_INITIAL_PASSWORD:=}"

readonly WORK=/var/tmp/ssp-build
readonly OS_ADMIN=sspadmin

log() { printf '%s [provision] %s\n' "$(date '+%F %T')" "$*"; }
trap 'log "FAILED at line $LINENO"' ERR
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

# ----------------------------------------------------------------------------------------------------
log "Extracting release $SSP_RELEASE_ARCHIVE"
rm -rf "$WORK"; install -d -m 0700 "$WORK/release" "$WORK/modules"
tar -xzf "$SSP_RELEASE_ARCHIVE" -C "$WORK/release"
TREE="$(find "$WORK/release" -maxdepth 3 -name Start-Portal.ps1 -type f -printf '%h\n' | head -n1)"
[[ -n "$TREE" ]] || { echo "No portal tree in $SSP_RELEASE_ARCHIVE" >&2; exit 1; }
OVA_DIR="$TREE/packaging/ova"

install_args=(--appliance --source "$TREE" --powercli-module "$SSP_POWERCLI_MODULE")
if [[ -s "$SSP_MODULES_ARCHIVE" ]] && tar -tzf "$SSP_MODULES_ARCHIVE" | grep -q .; then
    tar -xzf "$SSP_MODULES_ARCHIVE" -C "$WORK/modules"
    install_args+=(--modules-dir "$WORK/modules")
    log "Offline PowerShell modules supplied."
fi
[[ "$SSP_CLOUD_MODULES" == true ]] || install_args+=(--no-cloud-modules)

# ----------------------------------------------------------------------------------------------------
if [[ "$SSP_OS_UPDATE" == true ]]; then
    log "Applying OS updates"
    dnf -y upgrade --refresh
fi

log "Running install.sh ${install_args[*]}"
bash "$TREE/packaging/linux/install.sh" "${install_args[@]}"

# ----------------------------------------------------------------------------------------------------
log "Installing the first boot service"
install -m 0750 "$OVA_DIR/firstboot/ssp-firstboot.sh" /usr/local/sbin/ssp-firstboot
install -m 0644 "$OVA_DIR/firstboot/ssp-firstboot.service" /etc/systemd/system/ssp-firstboot.service
restorecon -F /usr/local/sbin/ssp-firstboot /etc/systemd/system/ssp-firstboot.service || true
systemctl daemon-reload
systemctl enable ssp-firstboot.service

printf 'SSP_APPLIANCE_VERSION=%s\nSSP_BUILD_DATE=%s\n' "$SSP_VERSION" "$(date -u +%FT%TZ)" >/etc/ssp-appliance-release
chmod 0644 /etc/ssp-appliance-release

# ----------------------------------------------------------------------------------------------------
log "Hardening: sysctl"
cat >/etc/sysctl.d/60-ssp-hardening.conf <<'EOF'
# Self-Service Portal appliance - network / kernel hardening (CIS-style, host is not a router).
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1
fs.suid_dumpable = 0
EOF
sysctl --system >/dev/null

log "Hardening: sshd"
cat >/etc/ssh/sshd_config.d/10-ssp-hardening.conf <<'EOF'
# Self-Service Portal appliance - sshd hardening (loaded before 50-redhat.conf; first value wins).
PermitRootLogin no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 3
LoginGraceTime 60
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
Banner /etc/issue.net
EOF
chmod 0600 /etc/ssh/sshd_config.d/10-ssp-hardening.conf
sshd -t

log "Hardening: login banner"
banner='Authorized use only. All activity on this system is logged and audited.
Disconnect immediately if you are not an authorized user.'
printf '%s\n\n' "$banner" >/etc/issue.net
printf '%s\n\n' "$banner" >/etc/issue
printf 'Self-Service Portal appliance %s - portal service: systemctl status ssp-portal\n' "$SSP_VERSION" >/etc/motd

log "Hardening: auditd, Ctrl-Alt-Del, core dumps"
dnf -y install audit dnf-automatic
systemctl enable auditd.service
systemctl mask ctrl-alt-del.target
install -d /etc/security/limits.d
printf '* hard core 0\n' >/etc/security/limits.d/60-ssp-nocore.conf

log "Automatic security updates: notify only"
conf=/etc/dnf/automatic.conf
sed -i -E 's/^upgrade_type\s*=.*/upgrade_type = security/' "$conf"
sed -i -E 's/^apply_updates\s*=.*/apply_updates = no/' "$conf"
sed -i -E 's/^download_updates\s*=.*/download_updates = no/' "$conf"
sed -i -E 's/^emit_via\s*=.*/emit_via = motd,stdio/' "$conf"
systemctl enable dnf-automatic-notifyonly.timer

# ----------------------------------------------------------------------------------------------------
log "OS administrator account $OS_ADMIN"
if ! id "$OS_ADMIN" >/dev/null 2>&1; then
    useradd --create-home --groups wheel --comment "Self-Service Portal appliance administrator" "$OS_ADMIN"
fi
if [[ -n "$SSP_SSPADMIN_INITIAL_PASSWORD" ]]; then
    printf '%s:%s\n' "$OS_ADMIN" "$SSP_SSPADMIN_INITIAL_PASSWORD" | chpasswd
    chage -d 0 "$OS_ADMIN"    # expired: must be changed at first login unless set by the OVF property
else
    passwd -l "$OS_ADMIN" >/dev/null   # locked until ssp.os_password is applied at first boot
fi

# A disk built on another hypervisor (qemu builder) must boot on VMware PVSCSI/vmxnet3:
# build a generic (not host-only) initramfs that contains all storage drivers.
if [[ "$(systemd-detect-virt 2>/dev/null || true)" != vmware ]]; then
    log "Non-VMware build host: generic initramfs"
    printf 'hostonly="no"\n' >/etc/dracut.conf.d/90-ssp-generic.conf
    dracut -f --regenerate-all
fi

getenforce | grep -qx Enforcing || log "WARNING: SELinux is not enforcing"
log "Provisioning finished (appliance $SSP_VERSION)."
