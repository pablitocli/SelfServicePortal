#!/usr/bin/env bash
# =====================================================================================================
# Self-Service Portal appliance - first boot configuration (installed as /usr/local/sbin/ssp-firstboot,
# run once by ssp-firstboot.service before ssp-portal.service).
#
# Reads the vSphere OVF environment (vmtoolsd --cmd "info-get guestinfo.ovfEnv"), applies network,
# hostname, NTP, OS / portal passwords and SSH policy, and creates the per-instance secrets that
# the OVA template deliberately does not contain (SSH host keys, machine-id, session secret, vault key,
# TLS certificate). Without an OVF environment it falls back to DHCP and defaults.
#
# Passwords are never written to the log. Usage:
#   ssp-firstboot                     normal run (skipped when /etc/ssp/.firstboot-done exists)
#   ssp-firstboot --force             run again (keeps vault key and customer certificates)
#   ssp-firstboot --env-file <xml>    use an OVF environment file instead of vmtoolsd
#   ssp-firstboot --parse-only <xml>  print the parsed properties (passwords masked) and exit
# =====================================================================================================
set -Eeuo pipefail

readonly LOG_FILE="${SSP_FIRSTBOOT_LOG:-/var/log/ssp-firstboot.log}"
readonly ETC_DIR="/etc/ssp"
readonly MARKER="$ETC_DIR/.firstboot-done"
readonly INSTALL_ROOT="/opt/ssp"
readonly SSP_USER="ssp"
readonly OS_ADMIN="sspadmin"
readonly BUILD_USER_FILE="/etc/ssp-build-user"     # written by cleanup.sh (fallback removal)
readonly CON_NAME="ssp-mgmt"

FORCE=0; ENV_FILE=""
declare -A P=()

log()  { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------------------------------
# OVF environment parser (python3 is part of minimal AlmaLinux 9). Prints one "key<TAB>base64(value)"
# line per known, valid property; invalid values are reported on stderr (never password values).
# ----------------------------------------------------------------------------------------------------
parse_ovf_env() {
    python3 - "$1" <<'PY'
import base64, ipaddress, re, sys
import xml.etree.ElementTree as ET

OE = "http://schemas.dmtf.org/ovf/environment/1"
LABEL = r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
FQDN = re.compile(rf"^{LABEL}(\.{LABEL})*$")
HOST = re.compile(rf"^{LABEL}$")
SECRET = {"ssp.os_password", "ssp.portal_admin_password"}

def ipv4(v):
    ipaddress.IPv4Address(v)
    return v

def ip_list(v):
    items = [x.strip() for x in v.split(",") if x.strip()]
    for x in items:
        ipaddress.ip_address(x)
    return ",".join(items)

def host_list(v):
    items = [x.strip() for x in v.split(",") if x.strip()]
    for x in items:
        try:
            ipaddress.ip_address(x)
        except ValueError:
            if not FQDN.match(x):
                raise ValueError("invalid host name")
    return ",".join(items)

def hostname(v):
    if not FQDN.match(v) or len(v) > 253:
        raise ValueError("invalid host name")
    return v.lower()

def domain(v):
    if not FQDN.match(v) or len(v) > 253:
        raise ValueError("invalid domain")
    return v.lower()

def prefix(v):
    n = int(v)
    if not 1 <= n <= 32:
        raise ValueError("prefix out of range")
    return str(n)

def port(v):
    n = int(v)
    if not 1 <= n <= 65535:
        raise ValueError("port out of range")
    return str(n)

def boolean(v):
    if v.lower() in ("true", "1", "yes"):
        return "true"
    if v.lower() in ("false", "0", "no"):
        return "false"
    raise ValueError("not a boolean")

def password(v):
    if "\n" in v or "\r" in v or "\0" in v:
        raise ValueError("control characters")
    return v

CHECKS = {
    "ssp.hostname": hostname, "ssp.domain": domain, "ssp.ip": ipv4, "ssp.prefix": prefix,
    "ssp.gateway": ipv4, "ssp.dns": ip_list, "ssp.ntp": host_list,
    "ssp.os_password": password, "ssp.portal_admin_password": password,
    "ssp.ssh_enabled": boolean, "ssp.portal_port": port,
}

try:
    root = ET.parse(sys.argv[1]).getroot()
except (ET.ParseError, OSError) as exc:
    print(f"OVF environment could not be parsed: {exc}", file=sys.stderr)
    sys.exit(2)

for prop in root.iter(f"{{{OE}}}Property"):
    key = prop.get(f"{{{OE}}}key", "")
    raw = prop.get(f"{{{OE}}}value", "")
    if key not in CHECKS:
        continue
    value = raw if key in SECRET else raw.strip()
    if value == "":
        continue
    try:
        value = CHECKS[key](value)
    except ValueError as exc:
        shown = "<hidden>" if key in SECRET else repr(value)
        print(f"Ignoring invalid {key} = {shown}: {exc}", file=sys.stderr)
        continue
    print(f"{key}\t{base64.b64encode(value.encode()).decode()}")
PY
}

load_properties() {
    local file="$1" key b64
    while IFS=$'\t' read -r key b64; do
        [[ -n "$key" ]] || continue
        P["$key"]="$(printf '%s' "$b64" | base64 -d)"
    done < <(parse_ovf_env "$file")
}

prop() { printf '%s' "${P[$1]:-${2:-}}"; }

print_properties() {
    local k
    for k in $(printf '%s\n' "${!P[@]}" | sort); do
        if [[ "$k" == *password* ]]; then printf '%s=********\n' "$k"; else printf '%s=%s\n' "$k" "${P[$k]}"; fi
    done
}

# ----------------------------------------------------------------------------------------------------
# Configuration steps
# ----------------------------------------------------------------------------------------------------
read_ovf_environment() {
    local raw
    raw="$(umask 077; mktemp /run/ssp-ovfenv.XXXXXX)"
    if [[ -n "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$raw"
    elif have vmtoolsd && vmtoolsd --cmd "info-get guestinfo.ovfEnv" >"$raw" 2>/dev/null && [[ -s "$raw" ]]; then
        :
    else
        : >"$raw"
    fi
    if [[ -s "$raw" ]]; then
        load_properties "$raw" || warn "OVF environment present but unreadable - using defaults."
        log "OVF environment read: ${#P[@]} propert(ies) applied: $(printf '%s ' "${!P[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')"
    else
        log "No OVF environment (not deployed from OVF on vSphere?) - DHCP and defaults."
    fi
    rm -f "$raw"   # contains passwords
}

remove_build_user() {
    local u=""
    if [[ -f "$BUILD_USER_FILE" ]]; then u="$(head -n1 "$BUILD_USER_FILE")"; fi
    if [[ -n "$u" ]] && id "$u" >/dev/null 2>&1; then
        userdel -r -f "$u" 2>/dev/null || userdel -f "$u"
        log "Removed leftover build user '$u'."
    fi
    rm -f "$BUILD_USER_FILE" /etc/sudoers.d/90-packer-build
}

ensure_machine_id() {
    if [[ ! -s /etc/machine-id ]] || grep -qx 'uninitialized' /etc/machine-id; then
        rm -f /etc/machine-id
        systemd-machine-id-setup
        log "Generated machine-id."
    fi
}

regenerate_ssh_host_keys() {
    if (( FORCE )) || ! compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null; then
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A
        if have restorecon; then restorecon -R /etc/ssh; fi
        log "Generated SSH host keys."
    fi
}

FQDN=""; SHORT=""; IPV4=""
configure_hostname() {
    local host domain
    host="$(prop ssp.hostname)"; domain="$(prop ssp.domain)"
    if [[ -n "$host" ]]; then
        if [[ "$host" == *.* ]]; then FQDN="$host"
        else FQDN="$host${domain:+.$domain}"; fi
        hostnamectl set-hostname "$FQDN"
        log "Hostname set to $FQDN."
    else
        FQDN="$(hostnamectl --static 2>/dev/null || hostname)"
        log "No ssp.hostname - keeping $FQDN."
    fi
    SHORT="${FQDN%%.*}"
}

first_ethernet() { nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" { print $1; exit }'; }

configure_network() {
    if ! have nmcli; then warn "nmcli not found - network left unchanged."; return 0; fi
    local dev ip pfx gw dns domain uuid type
    dev="$(first_ethernet)"
    if [[ -z "$dev" ]]; then warn "No Ethernet device found - network left unchanged."; return 0; fi
    ip="$(prop ssp.ip)"; pfx="$(prop ssp.prefix 24)"; gw="$(prop ssp.gateway)"
    dns="$(prop ssp.dns)"; domain="$(prop ssp.domain)"

    # Replace every Ethernet profile (the template only has the build-time DHCP profile).
    while IFS=: read -r uuid type; do
        if [[ "$type" == 802-3-ethernet ]]; then nmcli connection delete uuid "$uuid" >/dev/null; fi
    done < <(nmcli -t -f UUID,TYPE connection show)

    local args=(connection add type ethernet con-name "$CON_NAME" ifname "$dev" connection.autoconnect yes)
    if [[ -n "$ip" ]]; then
        args+=(ipv4.method manual ipv4.addresses "$ip/$pfx")
        if [[ -n "$gw" ]]; then args+=(ipv4.gateway "$gw"); else warn "Static IP without ssp.gateway."; fi
        log "Network: $dev static $ip/$pfx gw ${gw:-none}."
    else
        args+=(ipv4.method auto)
        log "Network: $dev DHCP."
    fi
    if [[ -n "$dns" ]]; then
        args+=(ipv4.dns "$dns")
        if [[ -z "$ip" ]]; then args+=(ipv4.ignore-auto-dns yes); fi
    fi
    if [[ -n "$domain" ]]; then args+=(ipv4.dns-search "$domain"); fi
    nmcli "${args[@]}" >/dev/null
    nmcli connection up "$CON_NAME" >/dev/null || warn "Could not activate $CON_NAME (check cabling / port group)."
    nm-online -s -q -t 60 || warn "Network not online after 60 s."

    IPV4="${ip:-$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')}"
    # /etc/hosts entry for the static address so that hostname -f works without DNS.
    sed -i '/# ssp-firstboot$/d' /etc/hosts
    if [[ -n "$ip" ]]; then printf '%s %s %s # ssp-firstboot\n' "$ip" "$FQDN" "$SHORT" >>/etc/hosts; fi
}

configure_ntp() {
    local ntp server conf=/etc/chrony.conf
    ntp="$(prop ssp.ntp)"
    if [[ -z "$ntp" || ! -f "$conf" ]]; then log "NTP: default chrony sources."; return 0; fi
    sed -i -E 's/^(pool|server)[[:space:]]/# disabled by ssp-firstboot: &/' "$conf"
    sed -i '/^# BEGIN ssp-firstboot/,/^# END ssp-firstboot/d' "$conf"
    {
        echo "# BEGIN ssp-firstboot"
        for server in ${ntp//,/ }; do echo "server $server iburst"; done
        echo "# END ssp-firstboot"
    } >>"$conf"
    systemctl restart --no-block chronyd.service || warn "chronyd restart failed."
    log "NTP: $ntp"
}

# Same certificate profile as packaging/linux/install.sh (SAN = FQDN, short name, IP).
generate_cert() {
    local fqdn="$1" short="$2" ip="$3" crt="$4" key="$5" cnf
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

is_own_selfsigned() {
    local subj iss
    subj="$(openssl x509 -in "$1" -noout -subject 2>/dev/null)" || return 1
    iss="$(openssl x509 -in "$1" -noout -issuer 2>/dev/null)" || return 1
    [[ "${subj#subject=}" == "${iss#issuer=}" && "$subj" == *"O = Self-Service Portal"* ]]
}

create_portal_secrets() {
    install -d -m 0750 -o root -g "$SSP_USER" "$ETC_DIR" "$ETC_DIR/tls"
    local env="$ETC_DIR/portal.env" vault="$ETC_DIR/vault.key" crt="$ETC_DIR/tls/portal.crt" key="$ETC_DIR/tls/portal.key"

    # New session secret for this instance (written directly, never logged).
    (umask 027
     printf 'SSP_PORTAL_ROOT=%s\nSSP_SESSION_SECRET=%s\nSSP_VAULT_KEYFILE=%s\n' \
         "$INSTALL_ROOT" "$(openssl rand -hex 32)" "$vault" >"$env.new")
    chown "root:$SSP_USER" "$env.new"; chmod 0640 "$env.new"; mv -f "$env.new" "$env"
    log "Session secret generated."

    # Vault key: ONLY when missing (regenerating it would destroy every stored credential).
    if [[ -s "$vault" ]]; then
        log "Vault key exists - kept."
    else
        (umask 077; openssl rand -base64 32 >"$vault")
        log "Vault key generated - back it up (ssp-backup)."
    fi
    chown "$SSP_USER:$SSP_USER" "$vault"; chmod 0400 "$vault"

    # TLS: create when missing; on --force replace only our own self-signed certificate.
    if [[ ! -s "$crt" || ! -s "$key" ]] || { (( FORCE )) && is_own_selfsigned "$crt"; }; then
        generate_cert "$FQDN" "$SHORT" "$IPV4" "$crt" "$key"
        log "Self-signed certificate generated for $FQDN${IPV4:+ / $IPV4}."
    else
        log "TLS certificate exists - kept."
    fi
    chown "root:$SSP_USER" "$crt"; chmod 0644 "$crt"
    chown "$SSP_USER:$SSP_USER" "$key"; chmod 0400 "$key"
    if have restorecon; then restorecon -R "$ETC_DIR"; fi
}

as_ssp() {
    (cd "$INSTALL_ROOT" && runuser -u "$SSP_USER" -- env SSP_PORTAL_ROOT="$INSTALL_ROOT" \
        SSP_VAULT_KEYFILE="$ETC_DIR/vault.key" POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off "$@")
}

configure_portal() {
    local port helper="$INSTALL_ROOT/tools/Set-PortalEndpoint.ps1"
    port="$(prop ssp.portal_port 443)"
    if [[ -f "$helper" ]]; then
        as_ssp pwsh -NoProfile -NonInteractive -File "$helper" -Port "$port" \
            -CertificateFile "$ETC_DIR/tls/portal.crt" -CertificateKeyFile "$ETC_DIR/tls/portal.key" \
            || warn "Set-PortalEndpoint.ps1 failed."
        log "Portal endpoint: port $port."
    else
        warn "$helper not found - portal endpoint not configured."
    fi

    local pw; pw="$(prop ssp.portal_admin_password)"
    if [[ -n "$pw" ]]; then
        export SSP_INIT_ADMIN_PASSWORD="$pw"
        # shellcheck disable=SC2016  # PowerShell expression, expanded by pwsh
        if as_ssp pwsh -NoProfile -NonInteractive -Command \
            '& "$env:SSP_PORTAL_ROOT/tools/Set-PortalLocalUser.ps1" -Username admin -NoPasswordChange -Password (ConvertTo-SecureString -String $env:SSP_INIT_ADMIN_PASSWORD -AsPlainText -Force)' >/dev/null; then
            log "Portal admin password set from ssp.portal_admin_password."
        else
            warn "Setting the portal admin password failed - default credentials remain."
        fi
        unset SSP_INIT_ADMIN_PASSWORD
    else
        log "No ssp.portal_admin_password - default portal admin password remains (change forced at first login)."
    fi
}

OS_PASSWORD_SET=0
configure_os_password() {
    local pw; pw="$(prop ssp.os_password)"
    if [[ -n "$pw" ]]; then
        printf '%s:%s\n' "$OS_ADMIN" "$pw" | chpasswd    # printf is a builtin: not visible in ps
        chage -d "$(date +%F)" "$OS_ADMIN"               # clears the build-time expiry
        OS_PASSWORD_SET=1
        log "$OS_ADMIN password set from ssp.os_password."
    else
        warn "No ssp.os_password - $OS_ADMIN keeps the build-time password (expired: change at first console login)."
    fi
}

firewall() {
    if systemctl is-active --quiet firewalld; then firewall-cmd --permanent "$@" >/dev/null
    elif have firewall-offline-cmd; then firewall-offline-cmd "$@" >/dev/null; fi
}

configure_ssh_and_firewall() {
    local want port
    want="$(prop ssp.ssh_enabled true)"
    port="$(prop ssp.portal_port 443)"
    if [[ "$want" == true && $OS_PASSWORD_SET -eq 1 ]]; then
        systemctl enable sshd.service >/dev/null 2>&1
        firewall --add-service=ssh || true
        log "SSH enabled."
    else
        systemctl disable sshd.service >/dev/null 2>&1 || true
        systemctl stop --no-block sshd.service || true
        firewall --remove-service=ssh || true
        if [[ "$want" == true ]]; then log "SSH disabled: no ssp.os_password supplied (enable later: systemctl enable --now sshd; firewall-cmd --permanent --add-service=ssh)."
        else log "SSH disabled (ssp.ssh_enabled=false)."; fi
    fi
    firewall --add-port="$port/tcp" || true
    if [[ "$port" != 443 ]]; then firewall --remove-port=443/tcp || true; fi
    if systemctl is-active --quiet firewalld; then firewall-cmd --reload >/dev/null || true; fi
}

write_console_banner() {
    local url="https://$FQDN"
    if [[ "$(prop ssp.portal_port 443)" != 443 ]]; then url+=":$(prop ssp.portal_port)"; fi
    install -d /etc/issue.d
    # agetty expands \4 to the current IPv4 address.
    printf 'Self-Service Portal appliance - %s\nPortal: %s/   (IPv4: \\4)\n\n' "$FQDN" "$url" >/etc/issue.d/50-ssp.issue
}

# ----------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------
main() {
    while (( $# )); do
        case "$1" in
            --parse-only)
                [[ -f "${2:-}" ]] || die "--parse-only needs an OVF environment file"
                load_properties "$2"; print_properties; exit 0 ;;
            --env-file) ENV_FILE="${2:?--env-file needs a file}"; shift 2 ;;
            --force)    FORCE=1; shift ;;
            -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
            *)          die "Unknown option: $1" ;;
        esac
    done
    [[ $EUID -eq 0 ]] || die "Run as root."
    if [[ -f "$MARKER" ]] && (( ! FORCE )); then echo "First boot already completed ($MARKER)."; exit 0; fi

    touch "$LOG_FILE"; chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'warn "Failed at line $LINENO - first boot will be retried at next boot. Log: $LOG_FILE"' ERR
    log "==== Self-Service Portal first boot ($(tr '\n' ' ' </etc/ssp-appliance-release 2>/dev/null || true)) ===="

    read_ovf_environment
    remove_build_user
    ensure_machine_id
    regenerate_ssh_host_keys
    configure_hostname
    configure_network
    configure_ntp
    create_portal_secrets
    configure_portal
    configure_os_password
    configure_ssh_and_firewall
    write_console_banner

    install -m 0640 -o root -g "$SSP_USER" /dev/null "$MARKER"
    date '+%F %T' >"$MARKER"
    log "First boot completed."
}

main "$@"
