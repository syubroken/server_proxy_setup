#!/usr/bin/env bash

# Manage a fail-closed Cloudflare WARP egress on Debian 12/13.
# This script uses only Cloudflare's official Linux package and warp-cli.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc2"
CONFIG_DIR="/etc/senyz-warp"
ROUTE_ENV="${CONFIG_DIR}/route.env"
SETTINGS_ENV="${CONFIG_DIR}/settings.env"
STATE_DIR="/var/lib/senyz-warp"
INSTALL_STAGED_MARKER="${STATE_DIR}/install-staged"
INSTALL_COMPLETE_MARKER="${STATE_DIR}/install-complete"
STOP_MARKER="${STATE_DIR}/managed-service-stopped"
DESIRED_MARKER="${STATE_DIR}/managed-service-should-run"
FAILURE_COUNT_FILE="${STATE_DIR}/transient-failures"
ROUTE_GUARD="/usr/local/sbin/senyz-warp-route-guard"
HEALTH_PROBE="/usr/local/sbin/senyz-warp-health"
WATCHDOG="/usr/local/sbin/senyz-warp-watchdog"
ROUTE_UNIT="senyz-warp-route-guard.service"
WATCHDOG_UNIT="senyz-warp-watchdog.service"
WATCHDOG_TIMER="senyz-warp-watchdog.timer"
WARP_SERVICE="warp-svc.service"
CLOUDFLARE_REPO_KEY_FINGERPRINT="C068A2B5771775193CBE1F2F6E2DD2174FA1C3BA"

REQUESTED_SERVICE="${WARP_MANAGED_SERVICE:-${MANAGED_SERVICE:-}}"
REQUESTED_PROTOCOL="${WARP_PROTOCOL:-}"
REQUESTED_LIMIT="${WARP_TRANSIENT_LIMIT:-}"
WARP_MANAGED_SERVICE="${REQUESTED_SERVICE:-v2ray}"
WARP_PROTOCOL="${REQUESTED_PROTOCOL:-MASQUE}"
WARP_TRANSIENT_LIMIT="${REQUESTED_LIMIT:-3}"
CLOUDFLARE_WARP_VERSION="${CLOUDFLARE_WARP_VERSION:-}"
ASSUME_YES=0
TEMP_FILES=()

log() {
    printf '[senyz-warp] %s\n' "$*"
}

warn() {
    printf '[senyz-warp] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[senyz-warp] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local file
    for file in "${TEMP_FILES[@]:-}"; do
        if [[ -n "${file}" ]]; then
            rm -f -- "${file}" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Run this command as root: $*"
}

require_supported_system() {
    local architecture

    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == 'debian' ]] || die 'Only Debian is supported.'
    case "${VERSION_ID:-}" in
        12|13) ;;
        *) die "Debian ${VERSION_ID:-unknown} is not supported." ;;
    esac
    [[ -d /run/systemd/system ]] || die 'systemd is required.'

    architecture="$(dpkg --print-architecture 2>/dev/null || true)"
    case "${architecture}" in
        amd64|arm64) ;;
        *) die "Cloudflare WARP does not support architecture ${architecture:-unknown}." ;;
    esac
}

confirm() {
    local prompt="$1"
    local answer

    if (( ASSUME_YES == 1 )); then
        return 0
    fi
    [[ -t 0 ]] || die 'Non-interactive use requires --yes.'
    printf '%s\n' "${prompt}"
    read -r -p 'Type YES to continue: ' answer
    [[ "${answer}" == 'YES' ]] || die 'Cancelled.'
}

load_settings() {
    local requested_service="${REQUESTED_SERVICE}"
    local requested_protocol="${REQUESTED_PROTOCOL}"
    local requested_limit="${REQUESTED_LIMIT}"

    if [[ -r "${SETTINGS_ENV}" ]]; then
        # shellcheck disable=SC1090
        . "${SETTINGS_ENV}"
        if [[ -n "${requested_service}" && "${requested_service}" != "${WARP_MANAGED_SERVICE}" ]]; then
            die 'WARP_MANAGED_SERVICE cannot be changed after installation.'
        fi
        if [[ -n "${requested_protocol}" && "${requested_protocol}" != "${WARP_PROTOCOL}" ]]; then
            die 'WARP_PROTOCOL cannot be changed implicitly after installation.'
        fi
        if [[ -n "${requested_limit}" && "${requested_limit}" != "${WARP_TRANSIENT_LIMIT}" ]]; then
            die 'WARP_TRANSIENT_LIMIT cannot be changed implicitly after installation.'
        fi
        return 0
    fi
}

validate_settings() {
    [[ "${WARP_MANAGED_SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]] \
        || die 'WARP_MANAGED_SERVICE contains unsupported characters.'
    case "${WARP_MANAGED_SERVICE}" in
        ssh|sshd|nginx|warp-svc|senyz-warp-*)
            die "Refusing unsafe managed service: ${WARP_MANAGED_SERVICE}"
            ;;
    esac
    case "${WARP_PROTOCOL}" in
        MASQUE|WireGuard) ;;
        *) die 'WARP_PROTOCOL must be MASQUE or WireGuard.' ;;
    esac
    [[ "${WARP_TRANSIENT_LIMIT}" =~ ^[0-9]+$ ]] \
        || die 'WARP_TRANSIENT_LIMIT must be an integer.'
    (( WARP_TRANSIENT_LIMIT >= 2 && WARP_TRANSIENT_LIMIT <= 10 )) \
        || die 'WARP_TRANSIENT_LIMIT must be between 2 and 10.'
    if [[ -n "${CLOUDFLARE_WARP_VERSION}" ]]; then
        [[ "${CLOUDFLARE_WARP_VERSION}" =~ ^[A-Za-z0-9.+:~_-]+$ ]] \
            || die 'CLOUDFLARE_WARP_VERSION contains unsupported characters.'
    fi
}

service_exists() {
    [[ "$(systemctl show -p LoadState --value "${WARP_MANAGED_SERVICE}.service" 2>/dev/null || true)" == 'loaded' ]]
}

legacy_wgcf_present() {
    [[ -e /etc/wireguard/wgcf.conf ]] \
        || systemctl is-active --quiet wg-quick@wgcf.service 2>/dev/null \
        || systemctl is-enabled --quiet wg-quick@wgcf.service 2>/dev/null
}

write_settings() {
    install -d -m 0700 "${CONFIG_DIR}" "${STATE_DIR}"
    {
        printf 'WARP_MANAGED_SERVICE=%q\n' "${WARP_MANAGED_SERVICE}"
        printf 'WARP_PROTOCOL=%q\n' "${WARP_PROTOCOL}"
        printf 'WARP_TRANSIENT_LIMIT=%q\n' "${WARP_TRANSIENT_LIMIT}"
    } > "${SETTINGS_ENV}"
    chmod 0600 "${SETTINGS_ENV}"
}

mark_install_staged() {
    install -d -m 0700 "${STATE_DIR}"
    touch "${INSTALL_STAGED_MARKER}"
    chmod 0600 "${INSTALL_STAGED_MARKER}"
}

mark_install_complete() {
    install -d -m 0700 "${STATE_DIR}"
    touch "${INSTALL_COMPLETE_MARKER}"
    chmod 0600 "${INSTALL_COMPLETE_MARKER}"
    rm -f "${INSTALL_STAGED_MARKER}"
}

install_dependencies() {
    log 'Installing required Debian packages.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg util-linux iproute2
}

rule_priority_in_use() {
    local priority="$1"
    ip -4 rule show | awk -v key="${priority}:" '$1 == key {found=1} END {exit !found}' \
        || ip -6 rule show | awk -v key="${priority}:" '$1 == key {found=1} END {exit !found}'
}

choose_rule_priority() {
    local priority
    for priority in {18..27}; do
        if ! rule_priority_in_use "${priority}"; then
            printf '%s\n' "${priority}"
            return 0
        fi
    done
    die 'Policy-routing priorities 18 through 27 are already in use.'
}

route_field() {
    local route_line="$1"
    local field="$2"
    awk -v wanted="${field}" \
        '{for (i=1; i<=NF; i++) if ($i == wanted && i < NF) {print $(i+1); exit}}' \
        <<<"${route_line}"
}

capture_management_route() {
    local route4 route6 src4 src6 dev4 dev6 gateway4 gateway6 priority

    route4="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)"
    src4="$(route_field "${route4}" src)"
    dev4="$(route_field "${route4}" dev)"
    gateway4="$(route_field "${route4}" via)"
    [[ -n "${src4}" && -n "${dev4}" ]] \
        || die 'Could not capture the original IPv4 management route.'

    route6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1 || true)"
    src6="$(route_field "${route6}" src)"
    dev6="$(route_field "${route6}" dev)"
    gateway6="$(route_field "${route6}" via)"
    priority="$(choose_rule_priority)"

    install -d -m 0700 "${CONFIG_DIR}"
    {
        printf 'RULE_PRIORITY=%q\n' "${priority}"
        printf 'IPV4_SOURCE=%q\n' "${src4}"
        printf 'IPV4_DEVICE=%q\n' "${dev4}"
        printf 'IPV4_GATEWAY=%q\n' "${gateway4}"
        printf 'IPV6_SOURCE=%q\n' "${src6}"
        printf 'IPV6_DEVICE=%q\n' "${dev6}"
        printf 'IPV6_GATEWAY=%q\n' "${gateway6}"
    } > "${ROUTE_ENV}"
    chmod 0600 "${ROUTE_ENV}"

    log "Captured the direct IPv4 management route on ${dev4}."
    if [[ -n "${src6}" ]]; then
        log "Captured the direct IPv6 management route on ${dev6}."
    else
        warn 'No native IPv6 management route was found; SSH protection uses IPv4.'
    fi
}

install_route_guard() {
    [[ -s "${ROUTE_ENV}" ]] || die "Missing ${ROUTE_ENV}."

    cat > "${ROUTE_GUARD}" <<'ROUTE_GUARD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROUTE_ENV="/etc/senyz-warp/route.env"
[[ -r "${ROUTE_ENV}" ]] || { echo "Missing ${ROUTE_ENV}" >&2; exit 1; }
# shellcheck disable=SC1090
. "${ROUTE_ENV}"

ensure_rule() {
    local family="$1"
    local source_address="$2"
    local prefix="$3"
    local existing

    [[ -n "${source_address}" ]] || return 0
    existing="$(ip "-${family}" rule show | awk -v key="${RULE_PRIORITY}:" '$1 == key')"
    if [[ -n "${existing}" ]]; then
        if grep -Fq "from ${source_address}" <<<"${existing}" \
            && grep -Eq 'lookup (main|254)' <<<"${existing}"; then
            return 0
        fi
        echo "Rule priority ${RULE_PRIORITY} is already used: ${existing}" >&2
        exit 1
    fi
    ip "-${family}" rule add pref "${RULE_PRIORITY}" \
        from "${source_address}${prefix}" lookup main
}

ensure_rule 4 "${IPV4_SOURCE:-}" /32
ensure_rule 6 "${IPV6_SOURCE:-}" /128
ROUTE_GUARD_EOF
    chmod 0755 "${ROUTE_GUARD}"

    cat > "/etc/systemd/system/${ROUTE_UNIT}" <<EOF
[Unit]
Description=Preserve direct management routes before Cloudflare WARP
Wants=network-online.target
After=network-online.target
Before=${WARP_SERVICE}

[Service]
Type=oneshot
ExecStart=${ROUTE_GUARD}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${ROUTE_UNIT}"
}

install_cloudflare_client() {
    local codename key_file downloaded_fingerprints

    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
    case "${codename}" in
        bookworm|trixie) ;;
        *) die "Cloudflare's repository does not support Debian codename ${codename:-unknown}." ;;
    esac

    log "Configuring Cloudflare's official APT repository."
    key_file="$(mktemp)"
    TEMP_FILES+=("${key_file}")
    curl --proto '=https' --tlsv1.2 -fsSLo "${key_file}" \
        https://pkg.cloudflareclient.com/pubkey.gpg
    downloaded_fingerprints="$(gpg --batch --show-keys --with-colons --fingerprint \
        "${key_file}" 2>/dev/null | awk -F: '$1 == "fpr" {print $10}')"
    grep -qx "${CLOUDFLARE_REPO_KEY_FINGERPRINT}" <<<"${downloaded_fingerprints}" \
        || die 'The downloaded Cloudflare signing key fingerprint is unexpected.'
    install -d -m 0755 /usr/share/keyrings
    gpg --batch --yes --dearmor \
        --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        "${key_file}"
    chmod 0644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [[ -n "${CLOUDFLARE_WARP_VERSION}" ]]; then
        apt-get install -y "cloudflare-warp=${CLOUDFLARE_WARP_VERSION}"
    else
        apt-get install -y cloudflare-warp
    fi
    command -v warp-cli >/dev/null 2>&1 || die 'warp-cli was not installed.'
    systemctl enable --now "${WARP_SERVICE}"
}

warp_cli() {
    if warp-cli --help 2>&1 | grep -q -- '--accept-tos'; then
        LC_ALL=C warp-cli --accept-tos "$@"
    else
        LC_ALL=C warp-cli "$@"
    fi
}

warp_cli_connected() {
    local status
    command -v warp-cli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "${WARP_SERVICE}" || return 1
    status="$(warp_cli status 2>&1 || true)"
    grep -Eiq '(^|[^[:alpha:]])Connected([^[:alpha:]]|$)' <<<"${status}"
}

ensure_registration() {
    local registration registration_output registration_rc
    if registration="$(warp_cli registration show 2>&1)" \
        && ! grep -Eiq '(not registered|no registration|registration missing)' <<<"${registration}"; then
        log 'Using the existing WARP consumer registration.'
        return 0
    fi

    log 'Creating a new WARP consumer registration (one attempt only).'
    if registration_output="$(warp_cli registration new 2>&1)"; then
        log 'The WARP consumer registration was created.'
        return 0
    else
        registration_rc=$?
    fi

    if grep -Eiq '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit' \
        <<<"${registration_output}"; then
        warn 'Cloudflare temporarily rate-limited new WARP registrations (HTTP 429).'
        warn 'No WARP route switch was attempted; the managed proxy service was left unchanged.'
        warn 'Do not retry repeatedly. Wait and run the same guided installer again later.'
        return 75
    fi

    [[ -z "${registration_output}" ]] || printf '%s\n' "${registration_output}" >&2
    warn 'Cloudflare WARP registration failed before any route switch.'
    return "${registration_rc}"
}

configure_warp() {
    "${ROUTE_GUARD}"
    systemctl start "${ROUTE_UNIT}"
    systemctl enable --now "${WARP_SERVICE}"
    warp_cli mode warp+doh
    warp_cli tunnel protocol set "${WARP_PROTOCOL}"
}

install_health_probe() {
    cat > "${HEALTH_PROBE}" <<'HEALTH_EOF'
#!/usr/bin/env bash
set -uo pipefail

TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
QUIET=0
[[ "${1:-}" == '--quiet' ]] && QUIET=1

probe_family() {
    local family="$1"
    local trace value
    trace="$(curl --noproxy '*' "-${family}" -fsS --connect-timeout 8 \
        --max-time 15 "${TRACE_URL}" 2>/dev/null || true)"
    value="$(awk -F= '$1 == "warp" {print $2; exit}' <<<"${trace}")"
    case "${value}" in
        on|plus) printf 'on\n' ;;
        off) printf 'off\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

v4="$(probe_family 4)"
v6="$(probe_family 6)"
if (( QUIET == 0 )); then
    printf 'IPv4=%s IPv6=%s\n' "${v4}" "${v6}"
fi
if [[ "${v4}" == 'on' && "${v6}" == 'on' ]]; then
    exit 0
fi
if [[ "${v4}" == 'off' || "${v6}" == 'off' ]]; then
    exit 2
fi
exit 3
HEALTH_EOF
    chmod 0755 "${HEALTH_PROBE}"
}

install_managed_service_guard() {
    local dropin_dir
    dropin_dir="/etc/systemd/system/${WARP_MANAGED_SERVICE}.service.d"
    install -d -m 0755 "${dropin_dir}"
    cat > "${dropin_dir}/90-senyz-warp.conf" <<EOF
[Unit]
Wants=${ROUTE_UNIT} ${WARP_SERVICE}
After=${ROUTE_UNIT} ${WARP_SERVICE}
BindsTo=${WARP_SERVICE}

[Service]
ExecStartPre=${HEALTH_PROBE} --quiet
EOF
    systemctl daemon-reload
}

health_probe_status() {
    if "${HEALTH_PROBE}" --quiet; then
        return 0
    else
        return $?
    fi
}

wait_for_warp() {
    for _ in {1..18}; do
        if warp_cli_connected && health_probe_status; then
            return 0
        fi
        sleep 5
    done
    return 1
}

protect_managed_service() {
    install -d -m 0700 "${STATE_DIR}"
    if service_exists && systemctl is-active --quiet "${WARP_MANAGED_SERVICE}.service"; then
        systemctl stop "${WARP_MANAGED_SERVICE}.service"
        touch "${STOP_MARKER}"
        touch "${DESIRED_MARKER}"
        chmod 0600 "${STOP_MARKER}" "${DESIRED_MARKER}"
        warn "Stopped ${WARP_MANAGED_SERVICE} to prevent direct egress while WARP is unverified."
    fi
}

recover_managed_service() {
    [[ -f "${DESIRED_MARKER}" ]] || return 0
    warp_cli_connected || die 'WARP CLI is not connected; the managed service remains stopped.'
    health_probe_status || die 'WARP dual-stack trace is not healthy; the managed service remains stopped.'
    systemctl start "${WARP_MANAGED_SERVICE}.service"
    rm -f "${STOP_MARKER}" "${FAILURE_COUNT_FILE}"
    log "WARP is verified; started ${WARP_MANAGED_SERVICE}."
}

install_watchdog() {
    cat > "${WATCHDOG}" <<'WATCHDOG_EOF'
#!/usr/bin/env bash
set -uo pipefail

SETTINGS_ENV="/etc/senyz-warp/settings.env"
STATE_DIR="/var/lib/senyz-warp"
STOP_MARKER="${STATE_DIR}/managed-service-stopped"
DESIRED_MARKER="${STATE_DIR}/managed-service-should-run"
FAILURE_COUNT_FILE="${STATE_DIR}/transient-failures"
ROUTE_GUARD="/usr/local/sbin/senyz-warp-route-guard"
HEALTH_PROBE="/usr/local/sbin/senyz-warp-health"
WARP_SERVICE="warp-svc.service"

[[ -r "${SETTINGS_ENV}" ]] || exit 0
# shellcheck disable=SC1090
. "${SETTINGS_ENV}"
install -d -m 0700 "${STATE_DIR}"
install -d -m 0755 /run/lock
exec 9>/run/lock/senyz-warp-watchdog.lock
flock -n 9 || exit 0

warp_cli() {
    if warp-cli --help 2>&1 | grep -q -- '--accept-tos'; then
        LC_ALL=C warp-cli --accept-tos "$@"
    else
        LC_ALL=C warp-cli "$@"
    fi
}

cli_connected() {
    local status
    command -v warp-cli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "${WARP_SERVICE}" || return 1
    status="$(warp_cli status 2>&1 || true)"
    grep -Eiq '(^|[^[:alpha:]])Connected([^[:alpha:]]|$)' <<<"${status}"
}

service_exists() {
    [[ "$(systemctl show -p LoadState --value "${WARP_MANAGED_SERVICE}.service" 2>/dev/null || true)" == 'loaded' ]]
}

protect() {
    if service_exists && systemctl is-active --quiet "${WARP_MANAGED_SERVICE}.service"; then
        systemctl stop "${WARP_MANAGED_SERVICE}.service"
        touch "${STOP_MARKER}"
        touch "${DESIRED_MARKER}"
        chmod 0600 "${STOP_MARKER}" "${DESIRED_MARKER}"
    fi
}

recover() {
    local started=0
    if [[ -f "${DESIRED_MARKER}" ]] && service_exists \
        && cli_connected && "${HEALTH_PROBE}" --quiet; then
        if ! systemctl is-active --quiet "${WARP_MANAGED_SERVICE}.service"; then
            systemctl start "${WARP_MANAGED_SERVICE}.service" || return 1
            started=1
        fi
        rm -f "${STOP_MARKER}" "${FAILURE_COUNT_FILE}"
        if (( started == 1 )); then
            logger -t senyz-warp "WARP recovered; started ${WARP_MANAGED_SERVICE}."
        fi
    fi
}

transient_count() {
    local count=0
    [[ -r "${FAILURE_COUNT_FILE}" ]] && read -r count < "${FAILURE_COUNT_FILE}"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    printf '%s\n' "${count}" > "${FAILURE_COUNT_FILE}"
    chmod 0600 "${FAILURE_COUNT_FILE}"
    printf '%s\n' "${count}"
}

if cli_connected; then
    if "${HEALTH_PROBE}" --quiet; then
        rm -f "${FAILURE_COUNT_FILE}"
        recover
        exit 0
    else
        probe_rc=$?
    fi

    if (( probe_rc == 3 )); then
        count="$(transient_count)"
        if (( count < WARP_TRANSIENT_LIMIT )); then
            logger -t senyz-warp \
                "WARP trace unavailable (${count}/${WARP_TRANSIENT_LIMIT}); service left unchanged."
            exit 0
        fi
        logger -t senyz-warp 'WARP trace remained unavailable; entering fail-closed protection.'
    else
        logger -t senyz-warp 'WARP trace explicitly reported direct egress; entering fail-closed protection.'
    fi
else
    logger -t senyz-warp 'WARP CLI is disconnected; entering fail-closed protection.'
fi

protect
"${ROUTE_GUARD}" >/dev/null 2>&1 || true
systemctl restart "${WARP_SERVICE}" >/dev/null 2>&1 || true
sleep 5
warp_cli connect >/dev/null 2>&1 || true
sleep 15

if cli_connected && "${HEALTH_PROBE}" --quiet; then
    rm -f "${FAILURE_COUNT_FILE}"
    recover
    exit 0
fi
logger -t senyz-warp "WARP recovery failed; ${WARP_MANAGED_SERVICE} remains stopped."
exit 1
WATCHDOG_EOF
    chmod 0755 "${WATCHDOG}"

    cat > "/etc/systemd/system/${WATCHDOG_UNIT}" <<EOF
[Unit]
Description=Verify Cloudflare WARP and protect proxy egress
After=network-online.target ${WARP_SERVICE} ${ROUTE_UNIT}
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG}
EOF

    cat > "/etc/systemd/system/${WATCHDOG_TIMER}" <<EOF
[Unit]
Description=Run the senyz WARP health check periodically

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
RandomizedDelaySec=10s
Persistent=true
Unit=${WATCHDOG_UNIT}

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable "${WATCHDOG_TIMER}"
}

enable_watchdog() {
    systemctl enable --now "${WATCHDOG_TIMER}"
}

show_health() {
    local probe_output probe_rc
    if [[ ! -x "${HEALTH_PROBE}" ]]; then
        printf 'dual-stack trace: not installed\n'
        return 0
    fi
    if probe_output="$("${HEALTH_PROBE}" 2>&1)"; then
        probe_rc=0
    else
        probe_rc=$?
    fi
    printf 'dual-stack trace: %s (class=%s)\n' "${probe_output:-unavailable}" "${probe_rc}"
}

do_status() {
    local package_version
    require_root status
    load_settings
    validate_settings

    printf 'senyz-warp script: %s\n' "${SCRIPT_VERSION}"
    package_version="$(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null || true)"
    printf 'cloudflare-warp: %s\n' "${package_version:-not installed}"
    printf 'managed service: %s\n' "${WARP_MANAGED_SERVICE}"
    printf 'protocol: %s\n' "${WARP_PROTOCOL}"
    printf 'transient limit: %s\n' "${WARP_TRANSIENT_LIMIT}"
    printf '\n=== warp-cli ===\n'
    if command -v warp-cli >/dev/null 2>&1; then
        warp_cli status 2>&1 || true
    else
        printf 'not installed\n'
    fi
    printf '\n=== egress ===\n'
    show_health
    printf '\n=== protection ===\n'
    printf 'route guard: %s\n' "$(systemctl is-active "${ROUTE_UNIT}" 2>/dev/null || true)"
    printf 'watchdog:    %s\n' "$(systemctl is-active "${WATCHDOG_TIMER}" 2>/dev/null || true)"
    printf '%-12s %s\n' "${WARP_MANAGED_SERVICE}:" \
        "$(systemctl is-active "${WARP_MANAGED_SERVICE}.service" 2>/dev/null || true)"
    if [[ -f "${STOP_MARKER}" ]]; then
        printf 'fail-closed marker: present\n'
    else
        printf 'fail-closed marker: absent\n'
    fi
    if [[ -f "${DESIRED_MARKER}" ]]; then
        printf 'managed-service intent: running\n'
    else
        printf 'managed-service intent: unchanged\n'
    fi
    if [[ -f "${INSTALL_COMPLETE_MARKER}" ]]; then
        printf 'installation state: complete\n'
    elif [[ -f "${INSTALL_STAGED_MARKER}" ]]; then
        printf 'installation state: staged; rerun install to continue\n'
    else
        printf 'installation state: not recorded\n'
    fi
}

prepare_existing_install() {
    require_supported_system
    load_settings
    validate_settings
    service_exists || die "Service ${WARP_MANAGED_SERVICE}.service does not exist."
    [[ -r "${SETTINGS_ENV}" && -r "${ROUTE_ENV}" ]] \
        || die 'This server does not contain a managed senyz WARP installation.'
}

connect_warp() {
    require_root connect
    prepare_existing_install
    confirm "This stops ${WARP_MANAGED_SERVICE} until WARP IPv4 and IPv6 are verified."
    protect_managed_service
    write_settings
    ensure_registration
    configure_warp
    warp_cli connect
    enable_watchdog
    if wait_for_warp; then
        recover_managed_service
        mark_install_complete
        log 'WARP is connected and dual-stack egress is verified.'
        do_status
    else
        die "WARP did not pass verification; ${WARP_MANAGED_SERVICE} remains protected."
    fi
}

repair_warp() {
    require_root repair
    prepare_existing_install
    confirm "This stops ${WARP_MANAGED_SERVICE}, repairs WARP, and restores it only after verification."
    protect_managed_service
    install_dependencies
    install_route_guard
    install_cloudflare_client
    ensure_registration
    install_health_probe
    install_managed_service_guard
    install_watchdog
    configure_warp
    systemctl restart "${WARP_SERVICE}"
    sleep 3
    warp_cli connect
    enable_watchdog
    if wait_for_warp; then
        recover_managed_service
        mark_install_complete
        log 'WARP repair passed.'
        do_status
    else
        die "WARP repair did not pass verification; ${WARP_MANAGED_SERVICE} remains protected."
    fi
}

disconnect_warp() {
    require_root disconnect
    prepare_existing_install
    confirm "This disconnects WARP and stops ${WARP_MANAGED_SERVICE} to prevent direct egress."
    systemctl disable --now "${WATCHDOG_TIMER}" 2>/dev/null || true
    protect_managed_service
    warp_cli disconnect || true
    log "WARP is disconnected; ${WARP_MANAGED_SERVICE} remains stopped."
}

update_warp() {
    require_root update
    prepare_existing_install
    confirm "This stops ${WARP_MANAGED_SERVICE}, updates Cloudflare WARP, and verifies egress."
    protect_managed_service
    install_dependencies
    install_cloudflare_client
    ensure_registration
    configure_warp
    warp_cli connect
    enable_watchdog
    if wait_for_warp; then
        recover_managed_service
        mark_install_complete
        log 'WARP update passed.'
        do_status
    else
        die "WARP update did not pass verification; ${WARP_MANAGED_SERVICE} remains protected."
    fi
}

remove_route_rules() {
    [[ -r "${ROUTE_ENV}" ]] || return 0
    # shellcheck disable=SC1090
    . "${ROUTE_ENV}"
    if [[ -n "${IPV4_SOURCE:-}" ]]; then
        ip -4 rule del pref "${RULE_PRIORITY}" from "${IPV4_SOURCE}/32" lookup main \
            2>/dev/null || true
    fi
    if [[ -n "${IPV6_SOURCE:-}" ]]; then
        ip -6 rule del pref "${RULE_PRIORITY}" from "${IPV6_SOURCE}/128" lookup main \
            2>/dev/null || true
    fi
}

uninstall_warp() {
    local dropin_dir
    require_root uninstall
    prepare_existing_install
    confirm "This removes WARP and leaves ${WARP_MANAGED_SERVICE} disabled and stopped."

    protect_managed_service
    systemctl disable --now "${WARP_MANAGED_SERVICE}.service" 2>/dev/null || true
    systemctl disable --now "${WATCHDOG_TIMER}" 2>/dev/null || true
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli registration delete >/dev/null 2>&1 || true
    systemctl disable --now "${ROUTE_UNIT}" 2>/dev/null || true
    remove_route_rules

    dropin_dir="/etc/systemd/system/${WARP_MANAGED_SERVICE}.service.d"
    rm -f "${dropin_dir}/90-senyz-warp.conf" \
        "/etc/systemd/system/${WATCHDOG_TIMER}" \
        "/etc/systemd/system/${WATCHDOG_UNIT}" \
        "/etc/systemd/system/${ROUTE_UNIT}" \
        "${WATCHDOG}" "${HEALTH_PROBE}" "${ROUTE_GUARD}"
    rmdir "${dropin_dir}" 2>/dev/null || true
    rm -rf "${CONFIG_DIR}" "${STATE_DIR}"
    systemctl daemon-reload

    export DEBIAN_FRONTEND=noninteractive
    apt-get remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list \
        /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    log "WARP was removed. ${WARP_MANAGED_SERVICE} remains disabled and stopped."
}

show_logs() {
    require_root logs
    journalctl -u "${WARP_SERVICE}" -u "${WATCHDOG_UNIT}" \
        --since '24 hours ago' --no-pager -n 250
}

do_install() {
    local registration_rc

    require_root install
    require_supported_system
    load_settings
    validate_settings
    service_exists || die "Service ${WARP_MANAGED_SERVICE}.service does not exist."
    legacy_wgcf_present \
        && die 'A legacy wgcf/WireGuard deployment is present. Use this only after a clean reinstall.'
    [[ ! -f "${INSTALL_COMPLETE_MARKER}" ]] \
        || die 'The managed WARP installation is already complete; use status or repair.'
    if [[ -r "${SETTINGS_ENV}" && ! -r "${ROUTE_ENV}" ]]; then
        die 'WARP settings exist without route metadata; stop and review this incomplete state.'
    fi
    if dpkg-query -W cloudflare-warp >/dev/null 2>&1 \
        && [[ ! -f "${INSTALL_STAGED_MARKER}" ]] \
        && [[ ! -r "${SETTINGS_ENV}" ]] \
        && [[ ! -r "${ROUTE_ENV}" ]]; then
        die 'An unmanaged Cloudflare WARP package is already installed.'
    fi
    confirm "This prepares official Cloudflare WARP while ${WARP_MANAGED_SERVICE} keeps its current state. The service is stopped only immediately before WARP connects, then restored after dual-stack verification. Keep a second SSH session and the DMIT console open."

    install_dependencies
    mark_install_staged
    install_cloudflare_client
    if ensure_registration; then
        :
    else
        registration_rc=$?
        return "${registration_rc}"
    fi
    if [[ ! -r "${ROUTE_ENV}" ]]; then
        capture_management_route
    fi
    if [[ ! -r "${SETTINGS_ENV}" ]]; then
        write_settings
    fi
    install_route_guard
    install_health_probe
    install_managed_service_guard
    install_watchdog
    configure_warp
    protect_managed_service
    warp_cli connect
    enable_watchdog

    if wait_for_warp; then
        recover_managed_service
        mark_install_complete
        log 'WARP installation passed; dual-stack egress is active.'
        do_status
    else
        die "WARP did not pass dual-stack verification; ${WARP_MANAGED_SERVICE} remains protected."
    fi
}

show_help() {
    cat <<EOF
senyz warp.sh ${SCRIPT_VERSION}

Usage:
  ./warp.sh install [--yes]     Install or safely resume official WARP setup
  ./warp.sh status              Read-only service and dual-stack egress status
  ./warp.sh repair [--yes]      Repair WARP with fail-closed service protection
  ./warp.sh connect [--yes]     Connect and restore the managed service after checks
  ./warp.sh disconnect [--yes]  Disconnect and keep the managed service stopped
  ./warp.sh update [--yes]      Update from Cloudflare's official repository
  ./warp.sh logs                Show the latest WARP and watchdog logs
  ./warp.sh uninstall [--yes]   Remove WARP; leave the managed service disabled
  ./warp.sh version             Print the script version

Optional environment variables:
  WARP_MANAGED_SERVICE=v2ray    Service protected from direct egress (default: v2ray)
  WARP_PROTOCOL=MASQUE          MASQUE (default) or WireGuard
  WARP_TRANSIENT_LIMIT=3        Consecutive trace timeouts before fail-closed (2-10)
  CLOUDFLARE_WARP_VERSION=...   Exact package version available in the official repo

No Cloudflare API token, account key, or DNS credential is used.
If Cloudflare temporarily returns HTTP 429 during registration, do not loop.
Wait and run the same install command again; the pre-route stage is resumable.
EOF
}

main() {
    local command="${1:-help}"
    shift || true

    while (( $# > 0 )); do
        case "$1" in
            --yes) ASSUME_YES=1 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    case "${command}" in
        install) do_install ;;
        status) do_status ;;
        repair) repair_warp ;;
        connect) connect_warp ;;
        disconnect) disconnect_warp ;;
        update) update_warp ;;
        logs) show_logs ;;
        uninstall) uninstall_warp ;;
        version) printf '%s\n' "${SCRIPT_VERSION}" ;;
        help|-h|--help) show_help ;;
        *) show_help; die "Unknown command: ${command}" ;;
    esac
}

main "$@"
