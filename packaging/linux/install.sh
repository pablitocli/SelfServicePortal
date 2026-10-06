#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal - Linux installer
#
# Supported: AlmaLinux / RHEL / Rocky Linux 9 (primary, used for the OVA) and Ubuntu 24.04 LTS.
# Idempotent: safe to re-run. Existing configuration, data, logs, catalog items, custom handlers,
# /etc/ssp secrets and the credential-vault key are never overwritten.
#
# Run as root from an extracted release tree (packaging/linux/install.sh) or with --source <dir|zip>.
# See --help and docs/installation-linux.md.
# =====================================================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------------------------------
# Constants (paths are part of the portal <-> packaging contract; the SSP_* overrides exist only for
# testing the installer against a scratch directory and must not be used in production).
# ----------------------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly INSTALL_ROOT="${SSP_INSTALL_ROOT:-/opt/ssp}"
readonly ETC_DIR="${SSP_ETC_DIR:-/etc/ssp}"
readonly SSP_USER="${SSP_USER:-ssp}"
readonly SSP_GROUP="${SSP_GROUP:-ssp}"
readonly SSP_HOME="${SSP_HOME:-/var/lib/ssp}"
readonly OS_RELEASE_FILE="${SSP_OS_RELEASE:-/etc/os-release}"
readonly SYSTEMD_DIR="${SSP_SYSTEMD_DIR:-/etc/systemd/system}"
readonly SBIN_DIR="${SSP_SBIN_DIR:-/usr/local/sbin}"
readonly BACKUP_DIR="${SSP_BACKUP_DIR:-/var/backups/ssp}"
readonly MODULES_TARGET="/usr/local/share/powershell/Modules"
readonly SERVICE_NAME="ssp-portal.service"
readonly PODE_VERSION="2.14.1"
readonly PWSH_MIN_VERSION="7.4.0"
LOG_FILE="${SSP_INSTALL_LOG:-/var/log/ssp-install.log}"

# Directories excluded from the copy into INSTALL_ROOT (build/test material, not runtime).
readonly TREE_EXCLUDES=(packaging tests .git .github .vscode build output)
readonly ALL_STEPS=(packages pwsh modules user tree etc endpoint admin service firewall)

# ----------------------------------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------------------------------
SOURCE=""
MODULES_DIR=""
CLOUD_MODULES=1
PORT=443
PORT_SET=0
CERT_HOSTNAME=""
ADMIN_PASSWORD="${SSP_ADMIN_PASSWORD:-}"   # env var preferred: not visible in the process list
SKIP_FIREWALL=0
UPGRADE=0
APPLIANCE=0
DRY_RUN=0
NO_START=0
PWSH_PACKAGE=""
POWERCLI_MODULE="${SSP_POWERCLI_MODULE:-VMware.PowerCLI}"   # newer releases: VCF.PowerCLI
ONLY_STEPS=""

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

  --source <dir|zip|tar.gz>  Portal release tree or archive (default: the tree containing this script)
  --modules-dir <dir>        OFFLINE mode: pre-saved PowerShell modules (Save-PSResource output,
                             <Module>/<Version>/...) copied to /usr/local/share/powershell/Modules
  --pwsh-package <file>      OFFLINE mode: local PowerShell .rpm/.deb instead of the Microsoft repo
  --no-cloud-modules         Do not install AWS.Tools / Az modules (Cloud Ops items unavailable)
  --powercli-module <name>   VMware.PowerCLI (default) or VCF.PowerCLI
  --port <n>                 HTTPS port of the portal (default 443)
  --hostname-cert <fqdn>     FQDN for the self-signed certificate (default: hostname -f)
  --admin-password <pw>      Initial password of the portal 'admin' account. Prefer the environment
                             variable SSP_ADMIN_PASSWORD (not visible in the process list / history)
  --skip-firewall            Do not touch firewalld / ufw
  --upgrade                  Upgrade an existing installation: pre-upgrade backup, code replaced,
                             config/data/logs/catalog items/custom handlers and /etc/ssp preserved
  --appliance                OVA build mode: install everything but do NOT create per-instance
                             secrets (vault key, session secret, TLS cert) and do not start the service
  --no-start                 Enable but do not start the service
  --only <step,...>          Run only these steps: packages,pwsh,modules,user,tree,etc,endpoint,admin,
                             service,firewall
  --dry-run                  Print the actions without changing the system
  -h, --help                 This help

Log file: /var/log/ssp-install.log
EOF
}

# ----------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------
log()  { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
step() { printf '\n==== %s ====\n' "$*"; }

# Executes a command (or only prints it in dry-run mode). Never pass secrets as arguments.
run() {
    printf '  + %s\n' "$*"
    if (( DRY_RUN )); then return 0; fi
    "$@"
}

# Runs a command as the portal service account from a directory it can read.
as_ssp() {
    local wd="/"
    [[ -d "$INSTALL_ROOT" ]] && wd="$INSTALL_ROOT"
    printf '  + (as %s) %s\n' "$SSP_USER" "$*"
    if (( DRY_RUN )); then return 0; fi
    (cd "$wd" && runuser -u "$SSP_USER" -- env SSP_PORTAL_ROOT="$INSTALL_ROOT" \
        SSP_VAULT_KEYFILE="$ETC_DIR/vault.key" POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off "$@")
}

want_step() {
    [[ -z "$ONLY_STEPS" ]] && return 0
    [[ ",$ONLY_STEPS," == *",$1,"* ]]
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

systemd_available() { [[ -d /run/systemd/system ]] && have systemctl; }

# ----------------------------------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case "$1" in
            --source)           SOURCE="${2:?--source needs a value}"; shift 2 ;;
            --modules-dir)      MODULES_DIR="${2:?--modules-dir needs a value}"; shift 2 ;;
            --pwsh-package)     PWSH_PACKAGE="${2:?--pwsh-package needs a value}"; shift 2 ;;
            --no-cloud-modules) CLOUD_MODULES=0; shift ;;
            --powercli-module)  POWERCLI_MODULE="${2:?--powercli-module needs a value}"; shift 2 ;;
            --port)             PORT="${2:?--port needs a value}"; PORT_SET=1; shift 2 ;;
            --hostname-cert)    CERT_HOSTNAME="${2:?--hostname-cert needs a value}"; shift 2 ;;
            --admin-password)   ADMIN_PASSWORD="${2:?--admin-password needs a value}"; shift 2
                                warn "--admin-password is visible in the process list and shell history; prefer SSP_ADMIN_PASSWORD." ;;
            --skip-firewall)    SKIP_FIREWALL=1; shift ;;
            --upgrade)          UPGRADE=1; shift ;;
            --appliance)        APPLIANCE=1; shift ;;
            --no-start)         NO_START=1; shift ;;
            --only)             ONLY_STEPS="${2:?--only needs a value}"; shift 2 ;;
            --dry-run)          DRY_RUN=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)                  usage >&2; die "Unknown option: $1" ;;
        esac
    done
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then die "Invalid --port: $PORT"; fi
    [[ "$POWERCLI_MODULE" =~ ^(VMware|VCF)\.PowerCLI$ ]] || die "--powercli-module must be VMware.PowerCLI or VCF.PowerCLI"
    if [[ -n "$ONLY_STEPS" ]]; then
        local s
        for s in ${ONLY_STEPS//,/ }; do
            [[ " ${ALL_STEPS[*]} " == *" $s "* ]] || die "Unknown step in --only: $s"
        done
    fi
    if [[ -n "$CERT_HOSTNAME" && ! "$CERT_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
        die "Invalid --hostname-cert: $CERT_HOSTNAME"
    fi
    if (( APPLIANCE )) && [[ -n "$ADMIN_PASSWORD" ]]; then
        warn "--appliance: the portal admin password is set at first boot (OVF property); ignoring it here."
        ADMIN_PASSWORD=""
    fi
}

# ----------------------------------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------------------------------
OS_FAMILY=""; OS_ID=""; OS_VERSION=""
detect_os() {
    [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read $OS_RELEASE_FILE"
    # Read only the fields we need instead of sourcing the file.
    OS_ID="$(sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE_FILE")"
    OS_VERSION="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE_FILE")"
    local like
    like="$(sed -n 's/^ID_LIKE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE_FILE")"
    case "$OS_ID" in
        almalinux|rhel|rocky) OS_FAMILY=rhel ;;
        ubuntu)               OS_FAMILY=debian ;;
        *)
            if [[ " $like " == *" rhel "* ]]; then OS_FAMILY=rhel; warn "Untested RHEL-like distribution: $OS_ID"
            else die "Unsupported OS: $OS_ID $OS_VERSION (supported: AlmaLinux/RHEL/Rocky 9, Ubuntu 24.04)"; fi ;;
    esac
    if [[ "$OS_FAMILY" == rhel && "${OS_VERSION%%.*}" != 9 ]]; then die "Unsupported version: $OS_ID $OS_VERSION (need 9.x)"; fi
    if [[ "$OS_FAMILY" == debian && "$OS_VERSION" != 24.04 ]]; then warn "Untested Ubuntu version $OS_VERSION (supported: 24.04)"; fi
    log "Detected OS: $OS_ID $OS_VERSION (family: $OS_FAMILY)"
}

SRC_DIR=""; TMP_EXTRACT=""
cleanup_tmp() { if [[ -n "$TMP_EXTRACT" && -d "$TMP_EXTRACT" ]]; then rm -rf "$TMP_EXTRACT"; fi; }
trap cleanup_tmp EXIT

is_release_tree() { [[ -f "$1/Start-Portal.ps1" && -d "$1/modules" && -d "$1/web" ]]; }

resolve_source() {
    local candidate
    if [[ -z "$SOURCE" ]]; then
        candidate="$(cd "$SCRIPT_DIR/../.." && pwd)"
        is_release_tree "$candidate" || die "No --source given and $candidate is not a portal release tree."
        SRC_DIR="$candidate"
    elif [[ -d "$SOURCE" ]]; then
        is_release_tree "$SOURCE" || die "$SOURCE is not a portal release tree (Start-Portal.ps1, modules/, web/ expected)."
        SRC_DIR="$(cd "$SOURCE" && pwd)"
    elif [[ -f "$SOURCE" ]]; then
        TMP_EXTRACT="$(mktemp -d /var/tmp/ssp-src.XXXXXX)"
        case "$SOURCE" in
            *.zip)            have unzip || die "unzip is required to extract $SOURCE"; unzip -q "$SOURCE" -d "$TMP_EXTRACT" ;;
            *.tar.gz|*.tgz)   tar -xzf "$SOURCE" -C "$TMP_EXTRACT" ;;
            *)                die "Unsupported archive type: $SOURCE (zip, tar.gz)" ;;
        esac
        candidate="$(find "$TMP_EXTRACT" -maxdepth 3 -name Start-Portal.ps1 -type f -printf '%h\n' | head -n1)"
        if [[ -z "$candidate" ]] || ! is_release_tree "$candidate"; then die "No portal release tree found inside $SOURCE"; fi
        SRC_DIR="$candidate"
    else
        die "--source not found: $SOURCE"
    fi
    log "Release tree: $SRC_DIR"
}

preflight() {
    if (( ! DRY_RUN )) && [[ $EUID -ne 0 ]]; then die "Run as root (sudo)."; fi
    detect_os
    resolve_source
    if [[ -n "$MODULES_DIR" && ! -d "$MODULES_DIR" ]]; then die "--modules-dir not found: $MODULES_DIR"; fi
    if [[ -n "$PWSH_PACKAGE" && ! -f "$PWSH_PACKAGE" ]]; then die "--pwsh-package not found: $PWSH_PACKAGE"; fi
    if (( UPGRADE )) && [[ ! -f "$INSTALL_ROOT/Start-Portal.ps1" ]]; then die "--upgrade: no installation found in $INSTALL_ROOT"; fi
    if (( ! UPGRADE )) && [[ -f "$INSTALL_ROOT/Start-Portal.ps1" ]]; then
        log "Existing installation found in $INSTALL_ROOT - re-running in place (data is preserved; use --upgrade for a pre-upgrade backup)."
    fi
    local free_kb parent
    parent="$(dirname "$INSTALL_ROOT")"
    while [[ ! -d "$parent" ]]; do parent="$(dirname "$parent")"; done
    free_kb="$(df -Pk "$parent" | awk 'NR==2 {print $4}')"
    if [[ -n "$free_kb" ]] && (( free_kb < 3 * 1024 * 1024 )); then
        warn "Less than 3 GB free under $parent (PowerShell modules alone need about 2 GB)."
    fi
}

# ----------------------------------------------------------------------------------------------------
# Step: OS packages
# ----------------------------------------------------------------------------------------------------
is_vmware_guest() { have systemd-detect-virt && [[ "$(systemd-detect-virt 2>/dev/null || true)" == vmware ]]; }

step_packages() {
    step "OS packages"
    local pkgs
    if [[ "$OS_FAMILY" == rhel ]]; then
        # openldap = libldap (System.DirectoryServices.Protocols / LDAP auth), openldap-clients = ldapsearch.
        pkgs=(openssl openldap openldap-clients chrony firewalld curl unzip tar jq python3 policycoreutils-python-utils)
        if (( APPLIANCE )) || is_vmware_guest; then pkgs+=(open-vm-tools); fi
        run dnf -y install "${pkgs[@]}"
    else
        local libldap=""
        local cand
        for cand in libldap2 libldap-2.5-0; do   # 24.04 ships libldap2 (2.6); 22.04 shipped libldap-2.5-0
            if apt-cache show "$cand" >/dev/null 2>&1; then libldap="$cand"; break; fi
        done
        [[ -n "$libldap" ]] || warn "No libldap package candidate found (run apt-get update?)."
        pkgs=(openssl ldap-utils chrony ufw curl unzip tar jq ca-certificates python3 ${libldap:+"$libldap"})
        if (( APPLIANCE )) || is_vmware_guest; then pkgs+=(open-vm-tools); fi
        run apt-get update -q
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}"
    fi
    if systemd_available; then
        if [[ "$OS_FAMILY" == rhel ]]; then run systemctl enable --now chronyd.service; else run systemctl enable --now chrony.service; fi
    fi
    ldap_compat_link
}

# PowerShell 7.4 runs on .NET 8, whose System.DirectoryServices.Protocols loads "libldap-2.5.so.0".
# AlmaLinux/RHEL 9 and Ubuntu 24.04 ship OpenLDAP 2.6 (libldap.so.2, ABI-compatible for the calls .NET makes),
# so LDAP sign-in fails with "Unable to load shared library 'libldap-2.5.so.0'" unless this link exists.
ldap_compat_link() {
    local libdir lib26 cand
    for libdir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
        [[ -d "$libdir" ]] || continue
        if [[ -e "$libdir/libldap-2.5.so.0" ]]; then log "libldap-2.5.so.0 present in $libdir."; return 0; fi
        lib26=""
        for cand in "$libdir/libldap.so.2" "$libdir/libldap-2.6.so.0"; do [[ -e "$cand" ]] && { lib26="$cand"; break; }; done
        if [[ -n "$lib26" ]]; then
            log "Creating compatibility link $libdir/libldap-2.5.so.0 -> $(basename "$lib26") (.NET 8 LDAP)."
            run ln -s "$(basename "$lib26")" "$libdir/libldap-2.5.so.0"
            run ldconfig
            return 0
        fi
    done
    warn "libldap not found: LDAP / Active Directory sign-in will not work until the OpenLDAP client library is installed."
}

# ----------------------------------------------------------------------------------------------------
# Step: PowerShell 7.4+
# ----------------------------------------------------------------------------------------------------
# shellcheck disable=SC2016  # PowerShell expression, expanded by pwsh
pwsh_version() { pwsh -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r' | sed 's/-.*//'; }

step_pwsh() {
    step "PowerShell"
    if have pwsh; then
        local v; v="$(pwsh_version || true)"
        if [[ -n "$v" ]] && version_ge "$v" "$PWSH_MIN_VERSION"; then log "PowerShell $v already installed."; return 0; fi
        log "PowerShell ${v:-unknown} found - upgrading to >= $PWSH_MIN_VERSION."
    fi
    if [[ -n "$PWSH_PACKAGE" ]]; then
        local pkg; pkg="$(readlink -f "$PWSH_PACKAGE")"
        if [[ "$OS_FAMILY" == rhel ]]; then run dnf -y install "$pkg"
        else run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg"; fi
    elif [[ "$OS_FAMILY" == rhel ]]; then
        if ! rpm -q packages-microsoft-prod >/dev/null 2>&1; then
            run dnf -y install "https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm"
        fi
        run dnf -y install powershell
    else
        if ! dpkg -s packages-microsoft-prod >/dev/null 2>&1; then
            local deb; deb="$(mktemp /var/tmp/packages-microsoft-prod.XXXXXX.deb)"
            run curl -fsSL -o "$deb" "https://packages.microsoft.com/config/ubuntu/${OS_VERSION}/packages-microsoft-prod.deb"
            run dpkg -i "$deb"
            rm -f "$deb"
            run apt-get update -q
        fi
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q powershell
    fi
    if (( ! DRY_RUN )); then
        local v; v="$(pwsh_version || true)"
        if [[ -z "$v" ]] || ! version_ge "$v" "$PWSH_MIN_VERSION"; then
            die "PowerShell >= $PWSH_MIN_VERSION not available after install (found: ${v:-none})."
        fi
        log "PowerShell $v ready."
    fi
}

# ----------------------------------------------------------------------------------------------------
# Step: PowerShell modules (machine-wide: /usr/local/share/powershell/Modules)
# ----------------------------------------------------------------------------------------------------
write_modules_script() {
    # The PowerShell part is kept in a temp file so it can take proper parameters.
    cat >"$1" <<'PS1'
param([string] $PodeVersion, [string] $PowerCliModule, [switch] $Cloud, [switch] $Offline)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:failed = @()

function Test-Mod([string] $Name, [string] $Version) {
    $m = @(Get-Module -ListAvailable -Name $Name)
    if ($Version) { $m = @($m | Where-Object { $_.Version -eq [version]$Version }) }
    return $m.Count -gt 0
}
function Install-Mod([string] $Name, [string] $Version, [switch] $Required) {
    if (Test-Mod $Name $Version) { Write-Host "[ok]      $Name $Version"; return }
    try {
        if ($Offline) { throw "not present in the offline modules directory" }
        Write-Host "[install] $Name $Version"
        $p = @{ Name = $Name; Scope = 'AllUsers'; TrustRepository = $true; AcceptLicense = $true; Quiet = $true }
        if ($Version) { $p['Version'] = $Version }
        Install-PSResource @p
    }
    catch {
        if ($Required) { throw "Required module $Name $Version could not be installed: $($_.Exception.Message)" }
        Write-Warning "Optional module $Name could not be installed: $($_.Exception.Message)"
        $script:failed += $Name
    }
}

Install-Mod -Name 'Pode' -Version $PodeVersion -Required

# vSphere items: legacy VMware.PowerCLI or the renamed VCF.PowerCLI - either satisfies the portal.
if ((Test-Mod 'VMware.PowerCLI') -or (Test-Mod 'VCF.PowerCLI')) { Write-Host '[ok]      PowerCLI' }
else { Install-Mod -Name $PowerCliModule }

if ($Cloud) {
    $aws = 'AWS.Tools.Common', 'AWS.Tools.EC2', 'AWS.Tools.SimpleSystemsManagement', 'AWS.Tools.SecurityToken'
    if (@($aws | Where-Object { -not (Test-Mod $_) }).Count -eq 0) { Write-Host '[ok]      AWS.Tools' }
    elseif ($Offline) { $aws | ForEach-Object { Install-Mod -Name $_ } }
    else {
        try {
            Install-Mod -Name 'AWS.Tools.Installer'
            Import-Module AWS.Tools.Installer
            Install-AWSToolsModule -Name AWS.Tools.EC2, AWS.Tools.SimpleSystemsManagement, AWS.Tools.SecurityToken -Scope AllUsers -Force
        }
        catch {
            Write-Warning "AWS.Tools.Installer failed ($($_.Exception.Message)); installing the modules directly."
            $aws | ForEach-Object { Install-Mod -Name $_ }
        }
    }
    'Az.Accounts', 'Az.Compute', 'Az.Network', 'Az.Resources', 'Az.KeyVault', 'Az.MarketplaceOrdering' |
        ForEach-Object { Install-Mod -Name $_ }
}
if ($script:failed.Count) { Write-Warning ("Missing optional modules: " + ($script:failed -join ', ')) }
Write-Host 'PowerShell modules done.'
PS1
}

step_modules() {
    step "PowerShell modules"
    run install -d -m 0755 "$MODULES_TARGET"
    if [[ -n "$MODULES_DIR" ]]; then
        log "Offline mode: copying modules from $MODULES_DIR"
        local d
        for d in "$MODULES_DIR"/*/; do
            [[ -d "$d" ]] || continue
            run cp -a "${d%/}" "$MODULES_TARGET/"
        done
        run chmod -R u=rwX,go=rX "$MODULES_TARGET"
    fi
    local ps1 args=()
    ps1="$(mktemp /var/tmp/ssp-modules.XXXXXX.ps1)"
    write_modules_script "$ps1"
    chmod 0644 "$ps1"
    args=(-PodeVersion "$PODE_VERSION" -PowerCliModule "$POWERCLI_MODULE")
    (( CLOUD_MODULES )) && args+=(-Cloud)
    [[ -n "$MODULES_DIR" ]] && args+=(-Offline)
    # umask 022 so the modules are readable by the ssp account.
    if ! (umask 022; run pwsh -NoProfile -NonInteractive -File "$ps1" "${args[@]}"); then
        rm -f "$ps1"; die "Module installation failed (Pode $PODE_VERSION is required)."
    fi
    rm -f "$ps1"
}

# ----------------------------------------------------------------------------------------------------
# Step: service account
# ----------------------------------------------------------------------------------------------------
step_user() {
    step "Service account $SSP_USER"
    local nologin; nologin="$(command -v nologin || echo /usr/sbin/nologin)"
    getent group "$SSP_GROUP" >/dev/null || run groupadd --system "$SSP_GROUP"
    if ! id "$SSP_USER" >/dev/null 2>&1; then
        run useradd --system --gid "$SSP_GROUP" --home-dir "$SSP_HOME" --no-create-home \
            --shell "$nologin" --comment "Self-Service Portal service" "$SSP_USER"
    else
        log "User $SSP_USER exists."
    fi
    # HOME of the service: pwsh caches, PowerCLI user configuration. Outside /home (ProtectHome=yes).
    run install -d -m 0750 -o "$SSP_USER" -g "$SSP_GROUP" "$SSP_HOME"
}

# ----------------------------------------------------------------------------------------------------
# Step: portal tree
# ----------------------------------------------------------------------------------------------------
REVIEW_DIR=""
review_dir() {
    if [[ -z "$REVIEW_DIR" ]]; then
        REVIEW_DIR="$SSP_HOME/upgrades/$(date +%Y%m%d-%H%M%S)"
        run install -d -m 0750 "$REVIEW_DIR"
    fi
}

# Replace a code file/dir in the destination with the release version.
replace_entry() {
    local src="$1" dst="$2"
    run rm -rf "$dst"
    run cp -a "$src" "$dst"
}

# Catalog items are configuration (admins edit them): keep existing files, add new ones and put a
# changed shipped version aside for manual review.
merge_keep_existing() {
    local src="$1" dst="$2" rel
    run install -d "$dst"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        if [[ ! -e "$dst/$rel" ]]; then
            run install -D -m 0640 "$src/$rel" "$dst/$rel"
        elif ! cmp -s "$src/$rel" "$dst/$rel"; then
            review_dir
            log "Kept customized $dst/$rel - new shipped version saved to $REVIEW_DIR/${dst#"$INSTALL_ROOT"/}/$rel"
            run install -D -m 0640 "$src/$rel" "$REVIEW_DIR/${dst#"$INSTALL_ROOT"/}/$rel"
        fi
    done < <(cd "$src" && find . -type f -print0)
}

# Shipped handlers are code: update them (previous version saved aside), never touch custom files.
merge_update_shipped() {
    local src="$1" dst="$2" rel
    run install -d "$dst"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        if [[ -e "$dst/$rel" ]] && ! cmp -s "$src/$rel" "$dst/$rel"; then
            review_dir
            log "Updating shipped $dst/$rel - previous version saved to $REVIEW_DIR/${dst#"$INSTALL_ROOT"/}/$rel.previous"
            run install -D -m 0640 "$dst/$rel" "$REVIEW_DIR/${dst#"$INSTALL_ROOT"/}/$rel.previous"
        fi
        run install -D -m 0640 "$src/$rel" "$dst/$rel"
    done < <(cd "$src" && find . -type f -print0)
}

# Copy only the directory skeleton (data/ and logs/ contents are runtime state).
copy_skeleton() {
    local src="$1" dst="$2" rel
    run install -d "$dst"
    while IFS= read -r -d '' rel; do
        run install -d "$dst/${rel#./}"
    done < <(cd "$src" && find . -mindepth 1 -type d -print0)
}

step_tree() {
    step "Portal tree -> $INSTALL_ROOT"
    if (( UPGRADE )) && (( ! DRY_RUN )); then
        run install -d -m 0700 "$BACKUP_DIR"
        local bk; bk="$BACKUP_DIR/pre-upgrade-$(date +%Y%m%d-%H%M%S).tar.gz"
        log "Pre-upgrade backup (code, config, data; logs excluded): $bk"
        (umask 077; tar -czf "$bk" --exclude="${INSTALL_ROOT#/}/logs" -C / "${INSTALL_ROOT#/}")
    fi
    if (( UPGRADE )) && systemd_available && systemctl is-active --quiet "$SERVICE_NAME"; then
        run systemctl stop "$SERVICE_NAME"
    fi
    run install -d -m 0750 "$INSTALL_ROOT"

    local entry name sub subname
    for entry in "$SRC_DIR"/*; do
        name="$(basename "$entry")"
        if [[ " ${TREE_EXCLUDES[*]} " == *" $name "* ]]; then continue; fi
        case "$name" in
            config)
                # Only the shipped defaults; config/*.json (live config, users) belongs to the instance.
                run install -d "$INSTALL_ROOT/config"
                while IFS= read -r -d '' sub; do
                    run install -m 0640 "$sub" "$INSTALL_ROOT/config/"
                done < <(find "$entry" -maxdepth 1 -type f -name '*.default.*' -print0)
                ;;
            data|logs)
                copy_skeleton "$entry" "$INSTALL_ROOT/$name" ;;
            catalog|automation)
                run install -d "$INSTALL_ROOT/$name"
                for sub in "$entry"/*; do
                    subname="$(basename "$sub")"
                    if [[ "$name/$subname" == catalog/items ]]; then merge_keep_existing "$sub" "$INSTALL_ROOT/$name/$subname"
                    elif [[ "$name/$subname" == automation/handlers ]]; then merge_update_shipped "$sub" "$INSTALL_ROOT/$name/$subname"
                    else replace_entry "$sub" "$INSTALL_ROOT/$name/$subname"; fi
                done ;;
            *)
                replace_entry "$entry" "$INSTALL_ROOT/$name" ;;
        esac
    done
    # Directories the portal creates/writes at runtime.
    for sub in config data logs logs/jobs catalog/items automation/handlers; do
        run install -d "$INSTALL_ROOT/$sub"
    done

    # Ownership and modes: the portal writes into config/, data/, logs/, catalog/, automation/handlers.
    run chown -R "$SSP_USER:$SSP_GROUP" "$INSTALL_ROOT"
    run find "$INSTALL_ROOT" -type d -exec chmod 0750 {} +
    run find "$INSTALL_ROOT" -type f -exec chmod 0640 {} +
    if have restorecon; then run restorecon -R "$INSTALL_ROOT"; fi

    # Operator helpers.
    run install -m 0750 "$SCRIPT_DIR/ssp-backup.sh" "$SBIN_DIR/ssp-backup"
    run install -m 0750 "$SCRIPT_DIR/uninstall.sh" "$SBIN_DIR/ssp-uninstall"
    if [[ -n "$REVIEW_DIR" ]]; then warn "Review the files in $REVIEW_DIR (customized catalog items / replaced handlers)."; fi
}

# ----------------------------------------------------------------------------------------------------
# Step: /etc/ssp (environment file, vault key, TLS certificate)
# ----------------------------------------------------------------------------------------------------
primary_ipv4() {
    local ip
    ip="$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true)"
    if [[ -z "$ip" ]]; then ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; fi
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s\n' "$ip"; fi
}

# Self-signed certificate with SAN = FQDN, short name and IP (replaceable by the customer's cert).
generate_cert() {
    local fqdn="$1" ip="$2" crt="$3" key="$4" short cnf
    short="${fqdn%%.*}"
    cnf="$(mktemp)"
    {
        printf '[req]\ndistinguished_name = dn\nprompt = no\nx509_extensions = v3\n'
        printf '[dn]\nCN = %s\nO = Self-Service Portal\n' "$fqdn"
        printf '[v3]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature,keyEncipherment\n'
        printf 'extendedKeyUsage = serverAuth\nsubjectKeyIdentifier = hash\nsubjectAltName = @alt\n[alt]\nDNS.1 = %s\n' "$fqdn"
        if [[ "$short" != "$fqdn" ]]; then printf 'DNS.2 = %s\n' "$short"; fi
        if [[ -n "$ip" ]]; then printf 'IP.1 = %s\n' "$ip"; fi
    } >"$cnf"
    (umask 077; openssl req -x509 -config "$cnf" -newkey rsa:3072 -sha256 -days 825 -nodes \
        -keyout "$key" -out "$crt" 2>/dev/null)
    rm -f "$cnf"
}

# Adds KEY=VALUE to the env file when the key is missing or empty (existing values are kept).
ensure_env_var() {
    local file="$1" key="$2" value="$3"
    if grep -Eq "^${key}=.+" "$file"; then return 0; fi
    if grep -Eq "^${key}=" "$file"; then sed -i "/^${key}=/d" "$file"; fi
    printf '%s=%s\n' "$key" "$value" >>"$file"
    log "  $file: set $key"
}

step_etc() {
    step "Configuration and secrets -> $ETC_DIR"
    run install -d -m 0750 -o root -g "$SSP_GROUP" "$ETC_DIR"
    run install -d -m 0750 -o root -g "$SSP_GROUP" "$ETC_DIR/tls"
    if (( APPLIANCE )); then
        log "Appliance mode: vault key, session secret and TLS certificate are created at first boot."
        return 0
    fi
    local env="$ETC_DIR/portal.env" vault="$ETC_DIR/vault.key" crt="$ETC_DIR/tls/portal.crt" key="$ETC_DIR/tls/portal.key"
    if (( DRY_RUN )); then
        log "  would ensure $env (SSP_PORTAL_ROOT, SSP_SESSION_SECRET, SSP_VAULT_KEYFILE), root:$SSP_GROUP 0640"
        if [[ -s "$vault" ]]; then log "  vault key exists - kept"; else log "  would generate $vault (openssl rand -base64 32), $SSP_USER 0400"; fi
        if [[ -s "$crt" && -s "$key" ]]; then log "  TLS certificate exists - kept"; else log "  would generate self-signed $crt / $key (CN ${CERT_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)})"; fi
        return 0
    fi

    # Environment file (systemd EnvironmentFile). Secrets are written directly, never logged.
    (umask 027; touch "$env")
    ensure_env_var "$env" SSP_PORTAL_ROOT "$INSTALL_ROOT"
    ensure_env_var "$env" SSP_SESSION_SECRET "$(openssl rand -hex 32)"   # 64 characters
    ensure_env_var "$env" SSP_VAULT_KEYFILE "$vault"
    chown "root:$SSP_GROUP" "$env"; chmod 0640 "$env"

    # Vault master key: generated ONCE. Regenerating it makes every stored credential unreadable.
    if [[ -s "$vault" ]]; then
        log "  Vault key exists - kept ($vault)."
    else
        (umask 077; openssl rand -base64 32 >"$vault")
        log "  Generated vault key $vault - include it in your backups (ssp-backup)."
    fi
    chown "$SSP_USER:$SSP_GROUP" "$vault"; chmod 0400 "$vault"

    # TLS certificate (only when missing - a customer certificate is never replaced).
    if [[ -s "$crt" && -s "$key" ]]; then
        log "  TLS certificate exists - kept ($crt)."
    else
        local fqdn ip
        fqdn="${CERT_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
        ip="$(primary_ipv4 || true)"
        generate_cert "$fqdn" "$ip" "$crt" "$key"
        log "  Generated self-signed certificate for $fqdn${ip:+ / $ip} (replace with a CA-signed one)."
    fi
    chown "root:$SSP_GROUP" "$crt"; chmod 0644 "$crt"
    chown "$SSP_USER:$SSP_GROUP" "$key"; chmod 0400 "$key"
    if have restorecon; then restorecon -R "$ETC_DIR"; fi
}

# ----------------------------------------------------------------------------------------------------
# Step: portal endpoint (port + certificate files) via the portal helper
# ----------------------------------------------------------------------------------------------------
step_endpoint() {
    step "Portal endpoint"
    if (( APPLIANCE )); then log "Appliance mode: endpoint configured at first boot."; return 0; fi
    if (( UPGRADE && ! PORT_SET )); then log "Upgrade: endpoint configuration kept (pass --port to change it)."; return 0; fi
    local helper="$INSTALL_ROOT/tools/Set-PortalEndpoint.ps1"
    if [[ ! -f "$helper" ]] && (( ! DRY_RUN )); then
        warn "$helper not found in this release - set portal.port / certificate files in config/portal.config.json manually."
        return 0
    fi
    as_ssp pwsh -NoProfile -NonInteractive -File "$helper" -Port "$PORT" \
        -CertificateFile "$ETC_DIR/tls/portal.crt" -CertificateKeyFile "$ETC_DIR/tls/portal.key"
}

# ----------------------------------------------------------------------------------------------------
# Step: initial portal admin password (optional)
# ----------------------------------------------------------------------------------------------------
step_admin() {
    step "Portal admin account"
    if (( APPLIANCE )); then log "Appliance mode: optional admin password comes from the OVF property at first boot."; return 0; fi
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        log "No admin password given: default admin / ChangeMe-2026! remains (a change is forced at first login)."
        return 0
    fi
    # Set-PortalLocalUser.ps1 takes -Password as [securestring]; the value travels in an environment
    # variable so it never appears in a command line or in this log.
    export SSP_INIT_ADMIN_PASSWORD="$ADMIN_PASSWORD"
    # shellcheck disable=SC2016  # $env:... is PowerShell syntax, expanded by pwsh
    as_ssp pwsh -NoProfile -NonInteractive -Command \
        '& "$env:SSP_PORTAL_ROOT/tools/Set-PortalLocalUser.ps1" -Username admin -NoPasswordChange -Password (ConvertTo-SecureString -String $env:SSP_INIT_ADMIN_PASSWORD -AsPlainText -Force)'
    unset SSP_INIT_ADMIN_PASSWORD
}

# ----------------------------------------------------------------------------------------------------
# Step: systemd service
# ----------------------------------------------------------------------------------------------------
step_service() {
    step "systemd service $SERVICE_NAME"
    run install -m 0644 "$SCRIPT_DIR/ssp-portal.service" "$SYSTEMD_DIR/$SERVICE_NAME"
    if ! systemd_available; then warn "systemd is not running (container?) - service installed but not enabled."; return 0; fi
    run systemctl daemon-reload
    run systemctl enable "$SERVICE_NAME"
    if (( APPLIANCE || NO_START )); then log "Service enabled, not started."; return 0; fi
    run systemctl restart "$SERVICE_NAME"
    if (( ! DRY_RUN )); then
        sleep 5
        systemctl is-active --quiet "$SERVICE_NAME" || warn "Service not active yet - check: journalctl -u $SERVICE_NAME -n 100"
    fi
}

# ----------------------------------------------------------------------------------------------------
# Step: firewall (portal port + SSH)
# ----------------------------------------------------------------------------------------------------
step_firewall() {
    step "Firewall"
    if (( SKIP_FIREWALL )); then log "--skip-firewall: not changed."; return 0; fi
    if [[ "$OS_FAMILY" == rhel ]]; then
        if systemd_available && systemctl is-active --quiet firewalld; then
            run firewall-cmd --permanent --add-port="$PORT/tcp"
            run firewall-cmd --permanent --add-service=ssh
            run firewall-cmd --reload
        elif have firewall-offline-cmd; then
            run firewall-offline-cmd --add-port="$PORT/tcp"
            run firewall-offline-cmd --add-service=ssh
            warn "firewalld is not running - rules written offline; start it with: systemctl enable --now firewalld"
        else
            warn "firewalld not available - open $PORT/tcp manually."
        fi
    else
        if have ufw; then
            run ufw allow "$PORT/tcp"
            run ufw allow 22/tcp
            if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
                warn "ufw is inactive - rules added but not enforced. Enable with: ufw enable"
            fi
        else
            warn "ufw not available - open $PORT/tcp manually."
        fi
    fi
}

# ----------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------
summary() {
    local fqdn url
    fqdn="${CERT_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
    url="https://$fqdn"; (( PORT != 443 )) && url+=":$PORT"
    cat <<EOF

=====================================================================================
 Self-Service Portal installation finished$( (( DRY_RUN )) && echo ' (DRY RUN - nothing changed)')
=====================================================================================
 Portal URL     : $url/
 Service        : systemctl status $SERVICE_NAME   |   journalctl -u $SERVICE_NAME -f
 Install log    : $LOG_FILE
 Next steps:
  1. Sign in as 'admin' (default password ChangeMe-2026! unless set) and change it.
  2. Replace the self-signed certificate in $ETC_DIR/tls/ (docs/installation-linux.md).
  3. Back up $ETC_DIR/vault.key now (ssp-backup) - without it stored credentials are lost.
  4. Configure identity providers, vCenter / cloud connections in Admin.
EOF
    if (( APPLIANCE )); then echo " Appliance mode: per-instance secrets are created by ssp-firstboot.service."; fi
}

main() {
    parse_args "$@"
    if (( DRY_RUN )); then
        LOG_FILE="${SSP_INSTALL_LOG:-/dev/null}"
    else
        install -d -m 0755 "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"; chmod 0600 "$LOG_FILE"
        exec > >(tee -a "$LOG_FILE") 2>&1
        exec 9>/run/ssp-install.lock
        flock -n 9 || die "Another install.sh is running."
    fi
    trap 'warn "Failed at line $LINENO (exit $?). See $LOG_FILE"' ERR
    log "Self-Service Portal installer started (options are not logged: they may contain a password)."
    preflight

    local s
    for s in "${ALL_STEPS[@]}"; do
        want_step "$s" || continue
        "step_$s"
    done
    summary
}

main "$@"
