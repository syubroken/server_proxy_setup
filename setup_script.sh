#!/usr/bin/env bash

# Compatibility entry point for the old one-command workflow.
# The unsafe legacy implementation is preserved under legacy/ for reference.

set -Eeuo pipefail

REBUILD_COMMIT="9866347e62262caafbeb1a7d54582b6208b872b4"
REBUILD_SHA256="5dc4122aa98822006f0a6e9c2ccf732f12dd79634e3e291b6ebe35cadb170224"
REBUILD_URL="https://raw.githubusercontent.com/syubroken/server_proxy_setup/${REBUILD_COMMIT}/rebuild_server.sh"
REBUILD_FILE="/root/rebuild_server.sh"
DEFAULT_DOMAIN="senyz.top"

[[ ${EUID} -eq 0 ]] || {
    printf '[ERROR] Run this script as root.\n' >&2
    exit 1
}

printf '\nThis compatibility launcher replaces the old setup_script.sh.\n'
printf 'It does not request or store a Cloudflare API key.\n'
printf 'It downloads a reviewed, checksum-pinned rebuild script for clean Debian 12/13.\n\n'

read -r -p "Domain [${DEFAULT_DOMAIN}]: " domain
domain="${domain:-$DEFAULT_DOMAIN}"
read -r -p 'Certificate notification email: ' email

[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || {
    printf '[ERROR] Invalid domain.\n' >&2
    exit 1
}
[[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || {
    printf '[ERROR] Invalid email address.\n' >&2
    exit 1
}

curl -fsSLo "$REBUILD_FILE" "$REBUILD_URL"
printf '%s  %s\n' "$REBUILD_SHA256" "$REBUILD_FILE" | sha256sum -c -
chmod 700 "$REBUILD_FILE"

exec "$REBUILD_FILE" --domain "$domain" --email "$email" --with-warp

