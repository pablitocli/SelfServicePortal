#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal appliance - OVA build wrapper.
#
#   packer init/validate/build (vsphere-iso) -> tools/add-ovf-properties.py -> ovftool -> .ova + .sha256
#
# Requirements on the build host: Packer >= 1.10 (vsphere plugin installed by 'packer init'),
# VMware OVF Tool >= 4.6, python3 >= 3.9, tar. The qemu builder additionally needs qemu-system-x86_64,
# qemu-img and OVMF.
#
# Usage:
#   ./build-ova.sh --version 1.0.0 --var-file my-site.pkrvars.hcl [--modules-dir <dir>] [--out <dir>]
#   ./build-ova.sh --version 1.0.0 --var-file my.pkrvars.hcl --builder qemu      # qcow2 + vmdk only
# =====================================================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly PACKER_MIN="1.10.0"
readonly OVFTOOL_MIN="4.6.0"

VERSION=""; VAR_FILE=""; MODULES_DIR=""; OUT_DIR="$SCRIPT_DIR/build"; BUILDER="vsphere"; SKIP_BUILD=0
EXTRA_VARS=()

usage() {
    cat <<'EOF'
Usage: build-ova.sh --version <x.y.z> --var-file <file.pkrvars.hcl> [options]

  --version <v>        Appliance version (OVF Version / file names)
  --var-file <file>    Packer variables (see variables.pkrvars.hcl.example)
  --modules-dir <dir>  Pre-saved PowerShell modules (Save-PSResource output) for an offline build
  --out <dir>          Output directory (default: packaging/ova/build)
  --builder <b>        vsphere (default, produces the OVA) or qemu (qcow2 -> vmdk, no OVA)
  --var k=v            Extra Packer variable (repeatable)
  --skip-build         Only post-process an existing export in <out>/output/vsphere
EOF
}
log() { printf '%s [build-ova] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '%s [build-ova] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

while (( $# )); do
    case "$1" in
        --version)     VERSION="${2:?}"; shift 2 ;;
        --var-file)    VAR_FILE="${2:?}"; shift 2 ;;
        --modules-dir) MODULES_DIR="${2:?}"; shift 2 ;;
        --out)         OUT_DIR="${2:?}"; shift 2 ;;
        --builder)     BUILDER="${2:?}"; shift 2 ;;
        --var)         EXTRA_VARS+=(-var "${2:?}"); shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "Unknown option: $1" ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.]+)?$ ]] || die "--version must look like 1.2.3"
[[ "$BUILDER" == vsphere || "$BUILDER" == qemu ]] || die "--builder must be vsphere or qemu"
[[ -z "$MODULES_DIR" || -d "$MODULES_DIR" ]] || die "--modules-dir not found: $MODULES_DIR"
if (( ! SKIP_BUILD )); then
    [[ -f "$VAR_FILE" ]] || die "--var-file not found: $VAR_FILE"
    VAR_FILE="$(cd "$(dirname "$VAR_FILE")" && pwd)/$(basename "$VAR_FILE")"
fi
if [[ -n "$MODULES_DIR" ]]; then MODULES_DIR="$(cd "$MODULES_DIR" && pwd)"; fi

# ----------------------------------------------------------------------------------------------------
# Tool checks
# ----------------------------------------------------------------------------------------------------
have python3 || die "python3 is required."
if (( ! SKIP_BUILD )); then
    have packer || die "packer >= $PACKER_MIN is required (https://developer.hashicorp.com/packer/install)."
    pv="$(packer version | sed -n 's/^Packer v\([0-9.]*\).*/\1/p' | head -n1)"
    version_ge "${pv:-0}" "$PACKER_MIN" || die "packer $pv found, >= $PACKER_MIN required."
fi
if [[ "$BUILDER" == vsphere ]]; then
    have ovftool || die "VMware OVF Tool >= $OVFTOOL_MIN is required (Broadcom developer portal)."
    ov="$(ovftool --version | sed -n 's/.*ovftool \([0-9.]*\).*/\1/p' | head -n1)"
    version_ge "${ov:-0}" "$OVFTOOL_MIN" || die "ovftool $ov found, >= $OVFTOOL_MIN required."
else
    have qemu-img || die "qemu-img is required for the qemu builder."
fi

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
STAGE="$OUT_DIR/stage"
RELEASE_ARCHIVE="$STAGE/ssp-release-$VERSION.tar.gz"
MODULES_ARCHIVE="$STAGE/ssp-modules-$VERSION.tar.gz"
NAME="SelfServicePortal-$VERSION"

# ----------------------------------------------------------------------------------------------------
# Stage the release tree and module bundle uploaded into the build VM
# ----------------------------------------------------------------------------------------------------
if (( ! SKIP_BUILD )); then
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    log "Packing release tree from $REPO_ROOT"
    # Instance state and build output never go into the appliance.
    tar -czf "$RELEASE_ARCHIVE" -C "$REPO_ROOT" \
        --exclude='./.git' --exclude='./packaging/ova/build' --exclude='./output' \
        --exclude='./config/portal.config.json' --exclude='./config/local-users.json' \
        --exclude='./data/secrets' --exclude='./data/requests/*' --exclude='./data/inventory/*' \
        --exclude='./logs/*.log' --exclude='./logs/jobs/*' --exclude='*.pkrvars.hcl' \
        --transform 's,^\.,SelfServicePortal,' .
    if [[ -n "$MODULES_DIR" ]]; then
        log "Packing offline PowerShell modules from $MODULES_DIR"
        tar -czf "$MODULES_ARCHIVE" -C "$MODULES_DIR" .
    else
        tar -czf "$MODULES_ARCHIVE" -T /dev/null    # empty bundle = online install from PSGallery
    fi

    log "packer init / validate / build ($BUILDER)"
    cd "$SCRIPT_DIR"
    packer_vars=(-var-file="$VAR_FILE" -var "ssp_version=$VERSION" -var "release_archive=$RELEASE_ARCHIVE"
                 -var "modules_archive=$MODULES_ARCHIVE" -var "output_directory=$OUT_DIR/output" "${EXTRA_VARS[@]}")
    source_name="vsphere-iso.almalinux9"; [[ "$BUILDER" == qemu ]] && source_name="qemu.almalinux9"
    packer init .
    packer validate -only="$source_name" "${packer_vars[@]}" .
    packer build -force -only="$source_name" "${packer_vars[@]}" .
fi

# ----------------------------------------------------------------------------------------------------
# Post-processing
# ----------------------------------------------------------------------------------------------------
if [[ "$BUILDER" == qemu ]]; then
    qcow="$(find "$OUT_DIR/output/qemu" -maxdepth 1 -name '*.qcow2' | head -n1)"
    [[ -n "$qcow" ]] || die "No qcow2 image in $OUT_DIR/output/qemu"
    log "Converting $qcow to a stream-optimized VMDK"
    qemu-img convert -p -O vmdk -o subformat=streamOptimized,adapter_type=lsilogic "$qcow" "$OUT_DIR/$NAME.vmdk"
    (cd "$OUT_DIR" && sha256sum "$NAME.vmdk" >"$NAME.vmdk.sha256")
    log "Done: $OUT_DIR/$NAME.vmdk (no OVF descriptor - see docs/ova.md 'Building without vCenter')."
    exit 0
fi

ovf="$(find "$OUT_DIR/output/vsphere" -maxdepth 2 -name '*.ovf' | head -n1)"
[[ -n "$ovf" ]] || die "No exported .ovf found under $OUT_DIR/output/vsphere"
log "Adding OVF properties to $ovf"
python3 "$SCRIPT_DIR/tools/add-ovf-properties.py" "$ovf" --version "$VERSION"

log "Packaging $NAME.ova"
rm -f "$OUT_DIR/$NAME.ova"
ovftool --shaAlgorithm=SHA256 "$ovf" "$OUT_DIR/$NAME.ova"
(cd "$OUT_DIR" && sha256sum "$NAME.ova" >"$NAME.ova.sha256")
log "Done: $OUT_DIR/$NAME.ova"
log "      $OUT_DIR/$NAME.ova.sha256"
