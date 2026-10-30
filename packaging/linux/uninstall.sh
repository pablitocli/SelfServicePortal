#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal - uninstaller (installed as /usr/local/sbin/ssp-uninstall).
#
# Default : stops/disables ssp-portal.service and removes the unit. /opt/ssp, /etc/ssp (vault key!),
#           the ssp account, PowerShell and its modules are KEPT, so a later install.sh resumes as-is.
# --purge : additionally deletes /opt/ssp, /etc/ssp, /var/lib/ssp, the ssp account, the firewall rule
#           and the helper scripts. Stored credentials become unrecoverable unless backed up.
# PowerShell and the modules in /usr/local/share/powershell/Modules are never removed (shared).
# =====================================================================================================
set -Eeuo pipefail

readonly INSTALL_ROOT="/opt/ssp"
readonly ETC_DIR="/etc/ssp"
readonly SSP_HOME="/var/lib/ssp"
readonly SERVICE_NAME="ssp-portal.service"
readonly FIRSTBOOT_SERVICE="ssp-firstboot.service"

PURGE=0; ASSUME_YES=0; DRY_RUN=0; PORT=""

usage() {
    cat <<'EOF'
Usage: sudo ssp-uninstall [--purge [--yes]] [--port <n>] [--dry-run]

  --purge     Also delete /opt/ssp, /etc/ssp (incl. the vault key), /var/lib/ssp and the ssp account
  --yes       Do not ask for confirmation (with --purge)
  --port <n>  Portal port to close in the firewall on --purge (default: read from config, else 443)
  --dry-run   Print the actions only
EOF
}

log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { printf '  + %s\n' "$*"; if (( DRY_RUN )); then return 0; fi; "$@"; }

while (( $# )); do
    case "$1" in
        --purge)   PURGE=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --port)    PORT="${2:?--port needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "Unknown option: $1" ;;
    esac
done
if (( ! DRY_RUN )) && [[ $EUID -ne 0 ]]; then die "Run as root (sudo)."; fi

# --- Service ----------------------------------------------------------------------------------------
units=("$SERVICE_NAME")
(( PURGE )) && units+=("$FIRSTBOOT_SERVICE")   # appliance first-boot unit: only removed on --purge
if have systemctl; then
    for unit in "${units[@]}"; do
        if systemctl list-unit-files "$unit" >/dev/null 2>&1 && systemctl cat "$unit" >/dev/null 2>&1; then
            run systemctl disable --now "$unit" || true
        fi
        run rm -f "/etc/systemd/system/$unit"
    done
    run systemctl daemon-reload || true
fi
log "Service removed."

if (( ! PURGE )); then
    log "Data kept: $INSTALL_ROOT, $ETC_DIR (vault key), $SSP_HOME, account 'ssp'. Use --purge to delete them."
    exit 0
fi

# --- Purge ------------------------------------------------------------------------------------------
cat <<EOF
WARNING: --purge permanently deletes:
  $INSTALL_ROOT (configuration, catalog, requests, logs)
  $ETC_DIR (session secret, TLS certificate and the VAULT KEY - stored credentials become unrecoverable)
  $SSP_HOME and the 'ssp' service account
Take a backup first: ssp-backup
EOF
if (( ! ASSUME_YES && ! DRY_RUN )); then
    read -r -p "Type PURGE to continue: " answer
    [[ "$answer" == "PURGE" ]] || die "Aborted."
fi

if [[ -z "$PORT" ]]; then
    PORT=443
    if have jq && [[ -f "$INSTALL_ROOT/config/portal.config.json" ]]; then
        PORT="$(jq -r '.portal.port // 443' "$INSTALL_ROOT/config/portal.config.json" 2>/dev/null || echo 443)"
    fi
fi
if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    run firewall-cmd --permanent --remove-port="$PORT/tcp" || true
    run firewall-cmd --reload || true
elif have ufw; then
    run ufw delete allow "$PORT/tcp" || true
fi

run rm -rf "$INSTALL_ROOT" "$ETC_DIR" "$SSP_HOME"
run rm -f /usr/local/sbin/ssp-backup /usr/local/sbin/ssp-firstboot
if id ssp >/dev/null 2>&1; then run userdel ssp; fi
if getent group ssp >/dev/null 2>&1; then run groupdel ssp || true; fi
log "Purged. PowerShell and modules in /usr/local/share/powershell/Modules were left in place."
# Remove this helper last (it may be the running script).
run rm -f /usr/local/sbin/ssp-uninstall
