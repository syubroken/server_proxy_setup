#!/usr/bin/env bash

# Checksum-pinned entry point for a clean Debian 12/13 rebuild.
# One guided flow runs the base and WARP phases with a safety checkpoint.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc2"
DOWNLOAD_COMMIT="a6b7d5b46e41ed432cd8feefa19b94a7780a548f"
REBUILD_SHA256="f05b0da319eec3340ca7a92a9ffbf0b778ee0281f167533b1e7d1634df8d0a3c"
WARP_SHA256="9c2bb88b46bcb159f199f4c778c3b53ead2228ea95171379def0efc304852fbc"
VERIFY_SHA256="95e08ef3be919a280136673ff1007c7d3b70cc3924cad53fa10aedfec66f4476"
RAW_BASE="https://raw.githubusercontent.com/syubroken/server_proxy_setup/${DOWNLOAD_COMMIT}"
DEFAULT_DOMAIN="senyz.top"
BASE_STATE="/etc/senyz-proxy/deployment.env"
CONSOLE_READY_MARKER="/etc/senyz-proxy/console-ready"
WARP_COMPLETE_MARKER="/var/lib/senyz-warp/install-complete"
RESUME_HELPER="/root/senyz-finish-rebuild"
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
for command_name in curl install mktemp readlink sha256sum; do
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
printf 'The guided flow builds the base proxy, pauses at a safety checkpoint,\n'
printf 'then installs and verifies WARP. Use --base-only only for diagnosis.\n'
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

printf 'Pinned files downloaded and verified from commit %s.\n' "${DOWNLOAD_COMMIT}"
launcher_path="$(readlink -f -- "$0" 2>/dev/null || true)"
if [[ -f "${launcher_path}" && "${launcher_path}" != "${RESUME_HELPER}" ]]; then
    install -m 700 "${launcher_path}" "${RESUME_HELPER}"
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
    printf '\nBase-only deployment complete. WARP was not installed.\n'
    printf 'Your client settings follow. Keep them private.\n\n'
    /usr/local/sbin/senyz-show-client
    exit 0
fi

printf '\n============================================================\n'
printf 'One safety checkpoint remains before WARP changes server routing.\n'
if [[ -f "${CONSOLE_READY_MARKER}" ]]; then
    printf 'The second SSH and console checkpoint was completed on an earlier run.\n'
else
    printf '1. Keep this SSH window open.\n'
    printf '2. Open a second SSH window and confirm that your own key logs in.\n'
    printf '3. Return here and set a console-only root password; SSH password login stays disabled.\n\n'
    passwd root
    printf '\nNow log in to the DMIT Serial Console with root and the new password.\n'
    read -r -p 'After the second SSH window and Serial Console both work, type READY: ' ready
    [[ "${ready}" == 'READY' ]] \
        || die 'Stopped safely after the base phase. WARP was not installed.'
    touch "${CONSOLE_READY_MARKER}"
    chmod 600 "${CONSOLE_READY_MARKER}"
fi

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
        printf '\n============================================================\n'
        if (( warp_rc == 75 )); then
            printf 'Cloudflare temporarily limited new WARP registrations (HTTP 429).\n'
            printf 'This is unrelated to Cloudflare DNS or a Global API Key.\n'
        else
            printf 'The WARP phase paused with exit code %s.\n' "${warp_rc}"
        fi
        if systemctl is-active --quiet v2ray; then
            if (( warp_rc == 75 )); then
                printf 'No WARP route switch was attempted, and V2Ray is still active.\n'
            else
                printf 'V2Ray is active, but final WARP verification did not complete.\n'
            fi
            printf 'Until WARP finishes, this base proxy uses the server original egress.\n'
            printf 'Do not use it for important accounts that require WARP egress.\n'
        else
            printf 'WARP had reached the route-switch stage, so V2Ray remains stopped for protection.\n'
        fi
        printf '\nDo not reinstall Debian and do not retry in a loop.\n'
        printf 'Wait, then continue with this one command:\n  %s\n' "${RESUME_HELPER}"
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
