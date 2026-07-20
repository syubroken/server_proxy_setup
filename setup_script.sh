#!/usr/bin/env bash

# Checksum-pinned entry point for a clean Debian 12/13 rebuild.
# One guided flow runs the base and WARP phases with a safety checkpoint.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc1"
DOWNLOAD_COMMIT="34b419ce92788cfb9c73fb7e0c0d7a20a7d46805"
REBUILD_SHA256="9617441e4521b70dab81db2a46cec4e06038f5dde8c31a6892966d4facb378ac"
WARP_SHA256="b99cc3c22091baa79579cef8c5a9e441e6dbe5df3c8f68bb112c8299eac7e3fb"
VERIFY_SHA256="30d87d38429363f7dbfe6ed82de9991d92546e8702f83fdf8d03e0edf72a685f"
RAW_BASE="https://raw.githubusercontent.com/syubroken/server_proxy_setup/${DOWNLOAD_COMMIT}"
DEFAULT_DOMAIN="senyz.top"
BASE_ONLY=0
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
for command_name in curl install mktemp sha256sum; do
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

read -r -p "Domain [${DEFAULT_DOMAIN}]: " domain
domain="${domain:-$DEFAULT_DOMAIN}"
read -r -p 'Certificate notification email: ' email

valid_domain "${domain}" || die 'Invalid domain name.'
[[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die 'Invalid email address.'

download_pinned_file rebuild_server.sh /root/rebuild_server.sh "${REBUILD_SHA256}"
download_pinned_file warp.sh /root/senyz-warp.sh "${WARP_SHA256}"
download_pinned_file verify_rebuild.sh /root/senyz-verify-rebuild.sh "${VERIFY_SHA256}"

printf 'Pinned files downloaded and verified from commit %s.\n' "${DOWNLOAD_COMMIT}"
/root/rebuild_server.sh --domain "${domain}" --email "${email}"
/usr/local/sbin/senyz-verify-rebuild

if (( BASE_ONLY == 1 )); then
    printf '\nBase-only deployment complete. WARP was not installed.\n'
    printf 'Your client settings follow. Keep them private.\n\n'
    /usr/local/sbin/senyz-show-client
    exit 0
fi

printf '\n============================================================\n'
printf 'One safety checkpoint remains before WARP changes server routing.\n'
printf '1. Keep this SSH window open.\n'
printf '2. Open a second SSH window and confirm that your own key logs in.\n'
printf '3. Set a console-only root password now; SSH password login stays disabled.\n\n'
passwd root
printf '\nOpen the DMIT Serial Console and confirm that root plus the new password works.\n'
read -r -p 'After the second SSH window and Serial Console both work, type READY: ' ready
[[ "${ready}" == 'READY' ]] \
    || die 'Stopped safely after the base phase. WARP was not installed.'

WARP_MANAGED_SERVICE=v2ray /root/senyz-warp.sh install --yes
/usr/local/sbin/senyz-verify-rebuild --require-warp

printf '\n============================================================\n'
printf 'Clean rebuild complete. Base proxy and WARP both passed verification.\n'
printf 'Your Shadowrocket/v2rayN settings follow. Keep them private.\n\n'
/usr/local/sbin/senyz-show-client
printf '\nScan this terminal QR code with Shadowrocket on iPhone:\n\n'
/usr/local/sbin/senyz-show-client qr
printf '\nLater, the only command needed to display them again is:\n'
printf '  senyz-show-client\n'
