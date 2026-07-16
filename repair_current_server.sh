#!/usr/bin/env bash

# One-time repair for the currently running legacy deployment.
# It does not change the V2Ray configuration or WARP routing.

set -Eeuo pipefail

SCRIPT_VERSION="1.0.3"
DOMAIN="senyz.top"
ASSUME_YES=0
WEBROOT="/var/www/senyz-acme"
ACME_BIN="/root/.acme.sh/acme.sh"
ACME_HTTP_CONF="/etc/nginx/conf.d/senyz-acme-http.conf"
TIMEOUT_CONF="/etc/nginx/conf.d/senyz-proxy-timeouts.conf"
LOG_FILE="/root/senyz-current-repair.log"
BACKUP_DIR=""

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./repair_current_server.sh [--domain senyz.top] [--yes]

This script:
  - changes acme.sh renewal from standalone mode to Nginx webroot mode;
  - disables TLS 1.0/1.1 in the existing Nginx configuration;
  - adds long proxy timeouts for WebSocket sessions;
  - enables automatic Debian security updates without automatic reboot.

It does not change V2Ray, SSH keys, firewall rules, or WARP routing.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --domain)
            [[ $# -ge 2 ]] || die '--domain requires a value.'
            DOMAIN="$2"
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die 'Run this script as root.'
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die 'The domain name contains unsupported characters.'
[[ -x "$ACME_BIN" ]] || die "acme.sh was not found at ${ACME_BIN}."
[[ -f /etc/nginx/nginx.conf ]] || die 'Nginx configuration was not found.'
grep -Eq 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf \
    || die 'The Nginx configuration does not include /etc/nginx/conf.d/*.conf.'

for command_name in apt-get awk curl grep nginx openssl sed systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
done

nginx_dump="$(nginx -T 2>&1)" || die 'The existing Nginx configuration is already invalid.'
CERT_FILE="$(printf '%s\n' "$nginx_dump" | awk '$1 == "ssl_certificate" {gsub(/;/, "", $2); print $2; exit}')"
KEY_FILE="$(printf '%s\n' "$nginx_dump" | awk '$1 == "ssl_certificate_key" {gsub(/;/, "", $2); print $2; exit}')"
[[ "$CERT_FILE" == /* ]] || die 'Could not determine the current certificate path from Nginx.'
[[ "$KEY_FILE" == /* ]] || die 'Could not determine the current private-key path from Nginx.'
[[ -f "$CERT_FILE" ]] || die "The current certificate file does not exist: ${CERT_FILE}"
[[ -f "$KEY_FILE" ]] || die "The current private-key file does not exist: ${KEY_FILE}"
openssl x509 -in "$CERT_FILE" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 \
    || die "The certificate selected from Nginx does not belong to ${DOMAIN}."

cat <<EOF

One-time repair ${SCRIPT_VERSION}
  Domain:       ${DOMAIN}
  Certificate:  ${CERT_FILE}
  Private key:  ${KEY_FILE}

The script will create a backup under /root, reload Nginx, and issue one
replacement certificate to prove that future renewal works without stopping Nginx.
V2Ray and WARP routing will not be changed.
EOF

if (( ASSUME_YES == 0 )); then
    read -r -p 'Type YES to continue: ' answer
    [[ "$answer" == 'YES' ]] || die 'Cancelled.'
fi

exec > >(tee -a "$LOG_FILE") 2>&1
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/root/senyz-current-repair-${timestamp}"
mkdir -p "$BACKUP_DIR"
cp -a /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf"

ACME_HTTP_EXISTED=0
TIMEOUT_EXISTED=0
if [[ -e "$ACME_HTTP_CONF" ]]; then
    ACME_HTTP_EXISTED=1
    cp -a "$ACME_HTTP_CONF" "$BACKUP_DIR/senyz-acme-http.conf"
fi
if [[ -e "$TIMEOUT_CONF" ]]; then
    TIMEOUT_EXISTED=1
    cp -a "$TIMEOUT_CONF" "$BACKUP_DIR/senyz-proxy-timeouts.conf"
fi
if [[ -d "/root/.acme.sh/${DOMAIN}_ecc" ]]; then
    cp -a "/root/.acme.sh/${DOMAIN}_ecc" "$BACKUP_DIR/"
fi

restore_nginx() {
    warn "Restoring the Nginx files from ${BACKUP_DIR}."
    cp -a "$BACKUP_DIR/nginx.conf" /etc/nginx/nginx.conf
    if (( ACME_HTTP_EXISTED == 1 )); then
        cp -a "$BACKUP_DIR/senyz-acme-http.conf" "$ACME_HTTP_CONF"
    else
        rm -f "$ACME_HTTP_CONF"
    fi
    if (( TIMEOUT_EXISTED == 1 )); then
        cp -a "$BACKUP_DIR/senyz-proxy-timeouts.conf" "$TIMEOUT_CONF"
    else
        rm -f "$TIMEOUT_CONF"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}

trap 'rc=$?; warn "Repair stopped at line ${LINENO} with exit code ${rc}. Backup: ${BACKUP_DIR}. Log: ${LOG_FILE}"; exit "$rc"' ERR

log 'Installing the small set of maintenance packages.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cron unattended-upgrades
systemctl enable --now cron

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52senyz-no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

install -d -m 755 "${WEBROOT}/.well-known/acme-challenge"

cat > "$ACME_HTTP_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEBROOT};

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

cat > "$TIMEOUT_CONF" <<'EOF'
proxy_connect_timeout 15s;
proxy_send_timeout 3600s;
proxy_read_timeout 3600s;
send_timeout 3600s;
EOF

sed -E -i \
    's/^([[:space:]]*)ssl_protocols[[:space:]]+[^;]+;/\1ssl_protocols TLSv1.2 TLSv1.3;/' \
    /etc/nginx/nginx.conf

if ! nginx -t; then
    restore_nginx
    die 'The proposed Nginx configuration was rejected and has been rolled back.'
fi
systemctl reload nginx

log 'Checking that the public HTTP challenge path reaches this server.'
challenge_name="senyz-${timestamp}"
challenge_file="${WEBROOT}/.well-known/acme-challenge/${challenge_name}"
printf '%s' "$challenge_name" > "$challenge_file"
chmod 644 "$challenge_file"

local_challenge_result="$(curl --noproxy '*' -fsS --max-time 10 \
    --resolve "${DOMAIN}:80:127.0.0.1" \
    "http://${DOMAIN}/.well-known/acme-challenge/${challenge_name}" || true)"
if [[ "$local_challenge_result" != "$challenge_name" ]]; then
    tail -n 20 /var/log/nginx/error.log >&2 || true
    rm -f "$challenge_file"
    die 'The local Nginx challenge path failed. The certificate was not changed.'
fi

public_challenge_result="$(curl --noproxy '*' -4 -fsS --max-time 20 \
    "http://${DOMAIN}/.well-known/acme-challenge/${challenge_name}" || true)"
rm -f "$challenge_file"
if [[ "$public_challenge_result" == "$challenge_name" ]]; then
    log 'The public HTTP challenge path is reachable.'
else
    warn 'The local challenge passed, but the server could not read itself through the public WARP route. Continuing with the certificate authority as the authoritative external test.'
fi

log 'Issuing a replacement certificate through the webroot method.'
"$ACME_BIN" --issue --domain "$DOMAIN" --webroot "$WEBROOT" --ecc --force
install -d -m 755 "$(dirname "$CERT_FILE")" "$(dirname "$KEY_FILE")"
"$ACME_BIN" --install-cert --domain "$DOMAIN" --ecc \
    --fullchain-file "$CERT_FILE" \
    --key-file "$KEY_FILE" \
    --reloadcmd 'nginx -t && systemctl reload nginx'
"$ACME_BIN" --install-cronjob

nginx -t
systemctl reload nginx

log 'Verifying the live certificate and services.'
certificate_info="$(openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -dates)"
printf '%s\n' "$certificate_info"

systemctl is-active --quiet nginx || die 'Nginx is not active after the repair.'
systemctl is-active --quiet v2ray || die 'V2Ray is not active after the repair.'

cat > /root/senyz-current-repair-result.txt <<EOF
Repair version: ${SCRIPT_VERSION}
Completed UTC: ${timestamp}
Domain: ${DOMAIN}
Certificate file: ${CERT_FILE}
Private key file: ${KEY_FILE}
Backup: ${BACKUP_DIR}
Log: ${LOG_FILE}

${certificate_info}

Future certificate renewals use:
  acme.sh + Nginx webroot ${WEBROOT}

No automatic reboot is enabled.
V2Ray configuration and WARP routing were not changed.
EOF
chmod 600 /root/senyz-current-repair-result.txt

printf '\nRepair complete.\n'
printf 'Backup: %s\n' "$BACKUP_DIR"
printf 'Log: %s\n' "$LOG_FILE"
printf 'Result: /root/senyz-current-repair-result.txt\n'
