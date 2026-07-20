#!/usr/bin/env bash

# Build the base proxy on a freshly reinstalled Debian 12/13 server.
# WARP is deliberately staged and must be installed separately afterwards.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc2"
DOMAIN="senyz.top"
EMAIL=""
ASSUME_YES=0
WEBROOT="/var/www/senyz-acme"
SITE_AVAILABLE="/etc/nginx/sites-available/senyz-proxy"
SITE_ENABLED="/etc/nginx/sites-enabled/senyz-proxy"
V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
V2RAY_VERSION="v5.51.2"
V2_INSTALL_COMMIT="cb39ee88249d47ed1c601dd5d3d94758d8835629"
V2_INSTALL_SHA256="e82217ce0db9e68f41ca34521ecd4ac98018d22d9ddd83e1316c74fb805603ae"
STATE_DIR="/etc/senyz-proxy"
DEPLOYMENT_ENV="${STATE_DIR}/deployment.env"
CLIENT_FILE="/root/senyz-client.txt"
CLIENT_HELPER="/usr/local/sbin/senyz-show-client"
RESULT_FILE="/root/senyz-base-result.txt"
LOG_FILE="/root/senyz-base-rebuild.log"
WARP_FILE="/root/senyz-warp.sh"
VERIFY_SOURCE="/root/senyz-verify-rebuild.sh"
VERIFY_TARGET="/usr/local/sbin/senyz-verify-rebuild"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-senyz-key-only.conf"
BACKUP_DIR=""
TEMP_FILES=()

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

cleanup() {
    local file
    for file in "${TEMP_FILES[@]:-}"; do
        if [[ -n "${file}" ]]; then
            rm -f -- "${file}" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    trap - ERR
    warn "Base rebuild stopped at line ${line} with exit code ${rc}. Log: ${LOG_FILE}"
    exit "${rc}"
}

usage() {
    cat <<'EOF'
Usage:
  ./rebuild_server.sh --domain senyz.top --email you@example.com [--yes]

This script is intended only for a freshly reinstalled Debian 12 or Debian 13
server with a root SSH public key already injected by DMIT. It installs the
base VMess + WebSocket + TLS proxy. It does not install or connect WARP.
EOF
}

valid_domain() {
    local value="$1"
    [[ ${#value} -le 253 ]] || return 1
    [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

while (( $# > 0 )); do
    case "$1" in
        --domain)
            [[ $# -ge 2 ]] || die '--domain requires a value.'
            DOMAIN="${2,,}"
            shift 2
            ;;
        --email)
            [[ $# -ge 2 ]] || die '--email requires a value.'
            EMAIL="$2"
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
valid_domain "${DOMAIN}" || die 'The domain name is invalid.'
[[ "${EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die 'A valid certificate email is required.'
[[ -r /etc/os-release ]] || die '/etc/os-release is missing.'

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'debian' ]] || die 'Only Debian is supported.'
case "${VERSION_ID:-}" in
    12|13) ;;
    *) die "Debian ${VERSION_ID:-unknown} is not supported." ;;
esac
[[ -d /run/systemd/system ]] || die 'systemd is required.'
for command_name in apt-get awk base64 curl grep install mapfile sed sort ssh-keygen systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
done
[[ -s /root/.ssh/authorized_keys ]] \
    || die 'No root SSH public key was found. Select your own public key in DMIT before rebuilding.'
ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null 2>&1 \
    || die 'The root authorized_keys file does not contain a readable SSH public key.'

available_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
[[ "${available_kb}" =~ ^[0-9]+$ ]] || die 'Could not determine free disk space.'
(( available_kb >= 2097152 )) || die 'At least 2 GiB of free disk space is required.'

if [[ -x /usr/local/bin/v2ray || -f "${V2RAY_CONFIG}" || -e "${STATE_DIR}" \
    || -f /etc/wireguard/wgcf.conf || -e /etc/senyz-warp \
    || -x /usr/bin/warp-cli ]]; then
    die 'An existing proxy or WARP deployment was detected. Reinstall Debian before using this clean-build script.'
fi

if ! command -v dig >/dev/null 2>&1; then
    log 'Installing the standard DNS lookup tool used by the preflight check.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends dnsutils
fi

log 'Checking the DNS-only A record before changing the server.'
public_ip="$(curl -4 -fsS --connect-timeout 8 --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace \
    | awk -F= '$1 == "ip" {print $2; exit}')"
[[ -n "${public_ip}" ]] || die 'Could not determine the server public IPv4 address.'
mapfile -t domain_ips < <(dig +time=5 +tries=2 +short A "${DOMAIN}" \
    | awk '/^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ {print}' | sort -u)
(( ${#domain_ips[@]} > 0 )) || die "DNS does not resolve ${DOMAIN}."
mapfile -t domain_ipv6 < <(dig +time=5 +tries=2 +short AAAA "${DOMAIN}" \
    | awk '/^[0-9A-Fa-f:]+$/ && /:/ {print tolower($0)}' | sort -u)
if (( ${#domain_ipv6[@]} > 0 )); then
    printf 'DNS IPv6:    %s\n' "${domain_ipv6[*]}"
    die 'Remove the AAAA record before using this IPv4-only certificate playbook.'
fi
dns_matches=0
for domain_ip in "${domain_ips[@]}"; do
    if [[ "${domain_ip}" == "${public_ip}" ]]; then
        dns_matches=1
        break
    fi
done
if (( dns_matches == 0 )); then
    printf 'Server IPv4: %s\n' "${public_ip}"
    printf 'DNS IPv4:    %s\n' "${domain_ips[*]}"
    die 'The DNS-only A record does not point directly to this server.'
fi

cat <<EOF

Clean base rebuild ${SCRIPT_VERSION}
  Debian:       ${VERSION_ID}
  Domain:       ${DOMAIN}
  V2Ray:        ${V2RAY_VERSION}
  WARP:         not installed in this phase
  SSH:          root public-key login only

Keep this SSH window open. The guided launcher continues after a second SSH
window and the DMIT Serial Console have been verified.
EOF

if (( ASSUME_YES == 0 )); then
    read -r -p 'Type YES to build the clean base server: ' answer
    [[ "${answer}" == 'YES' ]] || die 'Cancelled.'
fi

touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
trap on_error ERR

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/root/senyz-base-backup-${timestamp}"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
for path in /etc/nginx/nginx.conf /etc/nginx/sites-available /etc/nginx/sites-enabled /usr/local/etc/v2ray /etc/ssh/sshd_config.d; do
    if [[ -e "${path}" ]]; then
        cp -a "${path}" "${BACKUP_DIR}/"
    fi
done

log 'Updating Debian and installing maintained base packages.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg nginx certbot ufw unzip openssl \
    unattended-upgrades iproute2 qrencode

log 'Preserving the injected public key and enabling the firewall safely.'
install -d -m 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
mapfile -t SSH_PORTS < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u)
if (( ${#SSH_PORTS[@]} == 0 )); then
    SSH_PORTS=(22)
fi
for ssh_port in "${SSH_PORTS[@]}"; do
    ufw allow "${ssh_port}/tcp" comment 'SSH'
done
ufw allow 80/tcp comment 'HTTP certificate renewal'
ufw allow 443/tcp comment 'HTTPS proxy'
ufw default deny incoming
ufw default allow outgoing
ufw logging low
ufw --force enable

log 'Enforcing root public-key-only SSH without changing the SSH port.'
install -d -m 755 /etc/ssh/sshd_config.d
cat > "${SSH_DROPIN}" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
LoginGraceTime 30
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
EOF
chmod 644 "${SSH_DROPIN}"
/usr/sbin/sshd -t
sshd_effective="$(/usr/sbin/sshd -T)"
grep -qx 'passwordauthentication no' <<<"${sshd_effective}" \
    || die 'Effective SSH configuration still permits password authentication.'
grep -qx 'kbdinteractiveauthentication no' <<<"${sshd_effective}" \
    || die 'Effective SSH configuration still permits keyboard-interactive authentication.'
grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"${sshd_effective}" \
    || die 'Effective SSH root-login policy is not key-only.'
systemctl reload ssh

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52senyz-no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades

install -d -m 755 "${WEBROOT}/.well-known/acme-challenge"
install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/conf.d/senyz-basics.conf <<'EOF'
server_tokens off;
EOF
chmod 644 /etc/nginx/conf.d/senyz-basics.conf

cat > "${SITE_AVAILABLE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEBROOT};

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        default_type text/plain;
        return 200 'certificate setup in progress\n';
    }
}
EOF
chmod 644 "${SITE_AVAILABLE}"
ln -sfn "${SITE_AVAILABLE}" "${SITE_ENABLED}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

challenge_name="senyz-${timestamp}"
challenge_file="${WEBROOT}/.well-known/acme-challenge/${challenge_name}"
printf '%s' "${challenge_name}" > "${challenge_file}"
chmod 644 "${challenge_file}"
local_challenge_result="$(curl --noproxy '*' -fsS --max-time 10 \
    --resolve "${DOMAIN}:80:127.0.0.1" \
    "http://${DOMAIN}/.well-known/acme-challenge/${challenge_name}" || true)"
if [[ "${local_challenge_result}" != "${challenge_name}" ]]; then
    tail -n 20 /var/log/nginx/error.log >&2 || true
    rm -f "${challenge_file}"
    die 'The local Nginx HTTP challenge path failed.'
fi
public_challenge_result="$(curl -4 -fsS --max-time 20 \
    "http://${DOMAIN}/.well-known/acme-challenge/${challenge_name}" || true)"
rm -f "${challenge_file}"
[[ "${public_challenge_result}" == "${challenge_name}" ]] \
    || die 'Port 80 or the public HTTP challenge path is not reachable.'

log "Obtaining a Let's Encrypt certificate with Webroot renewal."
certbot certonly --non-interactive --agree-tos \
    --email "${EMAIL}" \
    --webroot --webroot-path "${WEBROOT}" \
    --cert-name "${DOMAIN}" \
    --key-type ecdsa \
    --domain "${DOMAIN}"

log "Installing the pinned V2Ray release ${V2RAY_VERSION}."
v2_installer="$(mktemp)"
TEMP_FILES+=("${v2_installer}")
curl --proto '=https' --tlsv1.2 -fsSLo "${v2_installer}" \
    "https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/${V2_INSTALL_COMMIT}/install-release.sh"
printf '%s  %s\n' "${V2_INSTALL_SHA256}" "${v2_installer}" | sha256sum -c -
bash "${v2_installer}" --version "${V2RAY_VERSION}"
rm -f "${v2_installer}"

installed_v2ray_version="$(/usr/local/bin/v2ray version 2>/dev/null | awk 'NR == 1 {print $2}')"
[[ "v${installed_v2ray_version#v}" == "${V2RAY_VERSION}" ]] \
    || die "Unexpected V2Ray version: ${installed_v2ray_version:-unknown}"

uuid="$(cat /proc/sys/kernel/random/uuid)"
path_token="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
ws_path="/ws-${path_token}"

install -d -m 700 "${STATE_DIR}"
{
    printf 'DOMAIN=%q\n' "${DOMAIN}"
    printf 'WEBROOT=%q\n' "${WEBROOT}"
    printf 'WS_PATH=%q\n' "${ws_path}"
    printf 'V2RAY_VERSION=%q\n' "${V2RAY_VERSION}"
    printf 'DEPLOYED_UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DEPLOYMENT_ENV}"
chmod 600 "${DEPLOYMENT_ENV}"

install -d -m 755 "$(dirname "${V2RAY_CONFIG}")"
cat > "${V2RAY_CONFIG}" <<EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
chmod 644 "${V2RAY_CONFIG}"

if /usr/local/bin/v2ray test -config "${V2RAY_CONFIG}" >/dev/null 2>&1; then
    log 'V2Ray configuration test passed.'
elif /usr/local/bin/v2ray -test -config "${V2RAY_CONFIG}" >/dev/null 2>&1; then
    log 'V2Ray configuration test passed.'
else
    die 'V2Ray rejected the generated configuration.'
fi

cat > "${SITE_AVAILABLE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEBROOT};

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location = ${ws_path} {
        access_log off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_socket_keepalive on;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF
chmod 644 "${SITE_AVAILABLE}"

install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx

nginx -t
systemctl daemon-reload
systemctl enable --now v2ray nginx
systemctl reload nginx
if systemctl list-unit-files --type=timer | grep -q '^certbot\.timer'; then
    systemctl enable --now certbot.timer
fi

log "Testing certificate renewal against the Let's Encrypt staging service."
certbot renew --cert-name "${DOMAIN}" --dry-run

vmess_json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' \
    "${DOMAIN}" "${DOMAIN}" "${uuid}" "${DOMAIN}" "${ws_path}" "${DOMAIN}")"
vmess_url="vmess://$(printf '%s' "${vmess_json}" | base64 -w 0)"
cat > "${CLIENT_FILE}" <<EOF
V2Ray client settings
=====================
Name: ${DOMAIN}
Address: ${DOMAIN}
Port: 443
UUID: ${uuid}
AlterId: 0
Encryption: auto
Transport: WebSocket
WebSocket path: ${ws_path}
Host: ${DOMAIN}
TLS: enabled
SNI: ${DOMAIN}
Skip certificate verification: no

One-click import link for Shadowrocket / v2rayN:
${vmess_url}
EOF
chmod 600 "${CLIENT_FILE}"

cat > "${CLIENT_HELPER}" <<'CLIENT_HELPER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_FILE="/root/senyz-client.txt"
[[ ${EUID} -eq 0 ]] || { printf '[ERROR] Run senyz-show-client as root.\n' >&2; exit 1; }
[[ -r "${CLIENT_FILE}" ]] || { printf '[ERROR] Client details are missing.\n' >&2; exit 1; }

case "${1:-details}" in
    details)
        cat "${CLIENT_FILE}"
        ;;
    link)
        awk '/^vmess:\/\// {print; found=1} END {exit !found}' "${CLIENT_FILE}"
        ;;
    qr)
        link="$(awk '/^vmess:\/\// {print; exit}' "${CLIENT_FILE}")"
        [[ -n "${link}" ]] || { printf '[ERROR] Import link is missing.\n' >&2; exit 1; }
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 "${link}"
        else
            printf '%s\n' "${link}"
        fi
        ;;
    *)
        printf 'Usage: senyz-show-client [details|link|qr]\n' >&2
        exit 2
        ;;
esac
CLIENT_HELPER_EOF
chmod 755 "${CLIENT_HELPER}"

if [[ -s "${VERIFY_SOURCE}" ]]; then
    install -m 700 "${VERIFY_SOURCE}" "${VERIFY_TARGET}"
else
    warn "The verification helper was not supplied at ${VERIFY_SOURCE}."
fi

log 'Running final base checks.'
nginx -t
systemctl is-active --quiet ssh || die 'SSH is not active.'
systemctl is-active --quiet nginx || die 'Nginx is not active.'
systemctl is-active --quiet v2ray || die 'V2Ray is not active.'
ss -lnt | grep -Eq '127\.0\.0\.1:10001[[:space:]]' \
    || die 'V2Ray is not listening on 127.0.0.1:10001.'
if ss -lnt | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\[::\]|\*):10001[[:space:]]'; then
    die 'V2Ray port 10001 is unexpectedly exposed publicly.'
fi
https_code="$(curl -sS --resolve "${DOMAIN}:443:127.0.0.1" \
    --output /dev/null --write-out '%{http_code}' "https://${DOMAIN}/")"
[[ "${https_code}" == '404' ]] || die "Unexpected local HTTPS response: ${https_code}"

{
    printf 'Base rebuild: PASS\n'
    printf 'Completed UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Debian: %s\n' "${VERSION_ID}"
    printf 'Domain: %s\n' "${DOMAIN}"
    printf 'V2Ray: %s\n' "${V2RAY_VERSION}"
    printf 'WARP: not installed by the base phase\n'
    printf 'Client details: %s (mode 600)\n' "${CLIENT_FILE}"
} > "${RESULT_FILE}"
chmod 600 "${RESULT_FILE}"

printf '\n============================================================\n'
printf 'Base rebuild complete. WARP has not been installed or connected.\n'
printf 'Client details are protected in %s.\n' "${CLIENT_FILE}"
printf 'Use this simple command whenever you need them:\n  senyz-show-client\n'
printf '\nLog:    %s\n' "${LOG_FILE}"
printf 'Result: %s\n' "${RESULT_FILE}"
printf 'Backup: %s\n' "${BACKUP_DIR}"
if [[ -x "${VERIFY_TARGET}" ]]; then
    printf 'Verify: %s\n' "${VERIFY_TARGET}"
fi
if [[ -x "${WARP_FILE}" ]]; then
    printf '\nReturn to the guided launcher for the safety checkpoint and WARP phase.\n'
    printf 'If that launcher was closed, use the single continuation command it installed:\n'
    printf '  /root/senyz-finish-rebuild\n'
else
    printf '\nWARP manager is missing; do not use an unpinned replacement.\n'
fi
if [[ -e /var/run/reboot-required ]]; then
    printf '\nDebian requests a reboot. Finish the base checks before rebooting.\n'
fi
