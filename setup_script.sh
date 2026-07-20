#!/usr/bin/env bash

# Checksum-pinned entry point for a clean Debian 12/13 VPS rebuild.
# One guided flow runs the fail-closed base and verified WARP phases.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc3"
DOWNLOAD_COMMIT="cf1d7626c40aee5517695ee85062ac3a6e1be6e1"
REBUILD_SHA256="d722199703082c5f68ea7b49705a05f60877057bdd5e1cf4e862e3cda6ce431b"
WARP_SHA256="4751383611f4101706c2ee99269322167cecb19ec55b1f1455d2e56935ed5d6b"
VERIFY_SHA256="b2970a574cf60c40032ee62d2c38050f620651d3a5173bb17076e889f4006324"
RAW_BASE="https://raw.githubusercontent.com/syubroken/server_proxy_setup/${DOWNLOAD_COMMIT}"
DEFAULT_DOMAIN="senyz.top"
BASE_STATE="/etc/senyz-proxy/deployment.env"
WARP_COMPLETE_MARKER="/var/lib/senyz-warp/install-complete"
RESUME_HELPER="/usr/local/sbin/senyz-finish-rebuild"
BASE_ONLY=0
RESUME_BASE=0
TEMP_FILES=()

cleanup() {
    local file
    for file in "${TEMP_FILES[@]:-}"; do
        if [[ -n "${file}" ]]; then
            rm -f -- "${file}" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

valid_domain() {
    local value="$1"
    [[ ${#value} -le 253 ]] || return 1
    [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_pin() {
    local label="$1"
    local value="$2"
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die "Invalid ${label} checksum."
}

download_pinned_file() {
    local source_name="$1"
    local destination="$2"
    local expected_sha256="$3"
    local temporary_file

    temporary_file="$(mktemp)"
    TEMP_FILES+=("${temporary_file}")
    curl --proto '=https' --tlsv1.2 -fsSLo "${temporary_file}" \
        "${RAW_BASE}/${source_name}"
    printf '%s  %s\n' "${expected_sha256}" "${temporary_file}" | sha256sum -c -
    install -m 700 "${temporary_file}" "${destination}"
    rm -f -- "${temporary_file}"
}

[[ ${EUID} -eq 0 ]] || die 'Run this script as root.'
for command_name in curl install ln mktemp readlink sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || die "Required command is missing: ${command_name}"
done
[[ "${DOWNLOAD_COMMIT}" =~ ^[0-9a-f]{40}$ ]] \
    || die 'This launcher has not been pinned to a reviewed commit.'
validate_pin rebuild_server.sh "${REBUILD_SHA256}"
validate_pin warp.sh "${WARP_SHA256}"
validate_pin verify_rebuild.sh "${VERIFY_SHA256}"

while (( $# > 0 )); do
    case "$1" in
        --base-only) BASE_ONLY=1 ;;
        -h|--help)
            printf 'Usage: ./setup_script.sh [--base-only]\n'
            printf 'Without options, the guided flow installs and verifies both base proxy and WARP.\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

printf '\nClean rebuild launcher %s\n' "${SCRIPT_VERSION}"
printf 'The guided flow builds the base proxy, keeps it stopped, then installs\n'
printf 'and verifies WARP with a timed route rollback. No second SSH or provider\n'
printf 'console is required. Use --base-only only for diagnosis.\n'
printf 'No Cloudflare API key, Global API key, or DNS API token is requested.\n\n'

if [[ -r "${BASE_STATE}" ]]; then
    DOMAIN=""
    # shellcheck disable=SC1090
    . "${BASE_STATE}"
    domain="${DOMAIN:-}"
    email=""
    RESUME_BASE=1
    printf 'A previous clean base phase was detected for %s.\n' "${domain:-unknown}"
    printf 'The installer will verify it and continue; the base will not be rebuilt.\n\n'
else
    read -r -p "Domain [${DEFAULT_DOMAIN}]: " domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -r -p 'Certificate notification email: ' email
fi

valid_domain "${domain}" || die 'Invalid domain name.'
if (( RESUME_BASE == 0 )); then
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || die 'Invalid email address.'
fi

download_pinned_file rebuild_server.sh /root/rebuild_server.sh "${REBUILD_SHA256}"
download_pinned_file warp.sh /root/senyz-warp.sh "${WARP_SHA256}"
download_pinned_file verify_rebuild.sh /root/senyz-verify-rebuild.sh "${VERIFY_SHA256}"

printf 'Required deployment components were downloaded and verified.\n'
launcher_path="$(readlink -f -- "$0" 2>/dev/null || true)"
if [[ -f "${launcher_path}" && "${launcher_path}" != "${RESUME_HELPER}" ]]; then
    install -m 700 "${launcher_path}" "${RESUME_HELPER}"
fi
if [[ -x "${RESUME_HELPER}" ]]; then
    ln -sfn "${RESUME_HELPER}" /root/senyz-finish-rebuild
fi
if (( RESUME_BASE == 0 )); then
    /root/rebuild_server.sh --domain "${domain}" --email "${email}"
else
    install -m 700 /root/senyz-verify-rebuild.sh /usr/local/sbin/senyz-verify-rebuild
fi
if [[ -f /var/lib/senyz-warp/install-staged \
    && ! -f "${WARP_COMPLETE_MARKER}" ]]; then
    /usr/local/sbin/senyz-verify-rebuild --resume-warp
else
    /usr/local/sbin/senyz-verify-rebuild
fi

if (( BASE_ONLY == 1 )); then
    printf '\nBase-only diagnostic deployment complete.\n'
    printf 'WARP was not installed, so V2Ray remains stopped and no client settings are delivered.\n'
    printf 'Continue later with: senyz-finish-rebuild\n'
    exit 0
fi

printf '\n============================================================\n'
printf 'Starting the protected WARP phase. V2Ray stays stopped until both IPv4\n'
printf 'and IPv6 report WARP. An unverified route change rolls back locally.\n'

if [[ -f "${WARP_COMPLETE_MARKER}" ]]; then
    printf 'A completed WARP phase was detected; running final verification.\n'
else
    warp_rc=0
    if WARP_MANAGED_SERVICE=v2ray /root/senyz-warp.sh install --yes; then
        :
    else
        warp_rc=$?
    fi
    if (( warp_rc != 0 )); then
        systemctl stop v2ray >/dev/null 2>&1 || true
        printf '\n============================================================\n'
        if (( warp_rc == 75 )); then
            printf 'Cloudflare still limited WARP registration after controlled retries.\n'
            printf 'This is unrelated to Cloudflare DNS or a Global API Key.\n'
        else
            printf 'The WARP phase paused with exit code %s.\n' "${warp_rc}"
        fi
        printf 'The node has not been delivered, and V2Ray remains stopped.\n'
        printf 'Any unverified WARP route transition is rolled back automatically.\n'
        printf '\nThere is no need to reinstall Debian. Wait, then run this one command:\n'
        printf '  senyz-finish-rebuild\n'
        exit "${warp_rc}"
    fi
fi
/usr/local/sbin/senyz-verify-rebuild --require-warp

printf '\n============================================================\n'
printf 'Clean rebuild complete. Base proxy and WARP both passed verification.\n'
printf 'Your Shadowrocket/v2rayN settings follow. Keep them private.\n\n'
/usr/local/sbin/senyz-show-client
printf '\nScan this terminal QR code with Shadowrocket on iPhone:\n\n'
/usr/local/sbin/senyz-show-client qr
printf '\nLater, the only command needed to display them again is:\n'
printf '  senyz-show-client\n'
