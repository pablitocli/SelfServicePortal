#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal - backup (installed as /usr/local/sbin/ssp-backup).
#
# Archives /opt/ssp/{config,data,catalog,automation/handlers} and /etc/ssp into a tar.gz.
#
# !! The archive contains /etc/ssp/vault.key (master key of the credential vault) and the TLS private
# !! key. Anyone holding the archive can decrypt the stored vCenter / cloud credentials. Protect it like
# !! a password store, or use --exclude-key to write the vault key to a separate file kept elsewhere.
#
# Restore (see docs/installation-linux.md):
#   systemctl stop ssp-portal
#   tar -xzpf ssp-backup-<host>-<ts>.tar.gz -C /
#   [install -o ssp -g ssp -m 0400 <key-file> /etc/ssp/vault.key]     # when taken with --exclude-key
#   systemctl start ssp-portal
# =====================================================================================================
set -Eeuo pipefail

readonly INSTALL_ROOT="/opt/ssp"
readonly ETC_DIR="/etc/ssp"
readonly SERVICE_NAME="ssp-portal.service"

OUT_DIR="/var/backups/ssp"; EXCLUDE_KEY=0; STOP_SERVICE=0; KEEP=0

usage() {
    cat <<'EOF'
Usage: sudo ssp-backup [-o <dir>] [--exclude-key] [--stop-service] [--keep <n>]

  -o, --output <dir>  Target directory (default /var/backups/ssp, created 0700)
  --exclude-key       Do not put vault.key in the archive; write it to <archive>.vault.key instead
                      (move that file to a different, protected location)
  --stop-service      Stop the portal during the backup for a fully consistent copy
  --keep <n>          Keep only the newest <n> archives in the target directory
EOF
}
log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        -o|--output)    OUT_DIR="${2:?--output needs a value}"; shift 2 ;;
        --exclude-key)  EXCLUDE_KEY=1; shift ;;
        --stop-service) STOP_SERVICE=1; shift ;;
        --keep)         KEEP="${2:?--keep needs a value}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "Unknown option: $1" ;;
    esac
done
[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a number"
[[ $EUID -eq 0 ]] || die "Run as root (the vault key is readable only by root and ssp)."
[[ -d "$INSTALL_ROOT" ]] || die "$INSTALL_ROOT not found."

umask 077
install -d -m 0700 "$OUT_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
archive="$OUT_DIR/ssp-backup-$(hostname -s)-$ts.tar.gz"

# Paths relative to / so the archive restores in place with: tar -xzpf <archive> -C /
paths=()
for p in config data catalog automation/handlers; do
    [[ -e "$INSTALL_ROOT/$p" ]] && paths+=("${INSTALL_ROOT#/}/$p")
done
[[ -d "$ETC_DIR" ]] && paths+=("${ETC_DIR#/}")
tar_opts=(--create --gzip --preserve-permissions --numeric-owner --file "$archive" -C /)
(( EXCLUDE_KEY )) && tar_opts+=(--exclude "${ETC_DIR#/}/vault.key")

restart=0
if (( STOP_SERVICE )) && systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Stopping $SERVICE_NAME"; systemctl stop "$SERVICE_NAME"; restart=1
fi
restart_on_exit() { if (( restart )); then systemctl start "$SERVICE_NAME"; fi; }
trap restart_on_exit EXIT

tar "${tar_opts[@]}" "${paths[@]}"
sha256sum "$archive" >"$archive.sha256"
log "Archive: $archive"

if (( EXCLUDE_KEY )); then
    if [[ -f "$ETC_DIR/vault.key" ]]; then
        install -m 0400 "$ETC_DIR/vault.key" "$archive.vault.key"
        warn "Vault key written separately to $archive.vault.key - move it to a DIFFERENT protected location."
    else
        warn "$ETC_DIR/vault.key not found - no key file written."
    fi
else
    warn "The archive contains the vault key and the TLS private key: store it encrypted / access-controlled."
fi

if (( KEEP > 0 )); then
    mapfile -t old < <(find "$OUT_DIR" -maxdepth 1 -type f -name 'ssp-backup-*.tar.gz' -printf '%T@ %p\n' \
                       | sort -rn | cut -d' ' -f2- | tail -n +"$((KEEP + 1))")
    for f in "${old[@]}"; do
        rm -f "$f" "$f.sha256" "$f.vault.key"; log "Removed old backup $f"
    done
fi
