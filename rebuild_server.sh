#!/usr/bin/env bash

# Rebuild a clean Debian 12/13 DMIT instance with V2Ray, Nginx, Certbot,
# automatic security updates, and optional official Cloudflare WARP.

set -Eeuo pipefail

SCRIPT_VERSION="2.0.1"
DOMAIN="senyz.top"
EMAIL=""
ENABLE_WARP=1
ASSUME_YES=0
WEBROOT="/var/www/senyz-acme"
SITE_AVAILABLE="/etc/nginx/sites-available/senyz-proxy"
SITE_ENABLED="/etc/nginx/sites-enabled/senyz-proxy"
V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
CLIENT_FILE="/root/senyz-client.txt"
V2_INSTALL_COMMIT="cb39ee88249d47ed1c601dd5d3d94758d8835629"
WARP_COMMIT="da777a2d70f55c29951fe27f12e02670fc4e2577"
WARP_SHA256="d9dfe54c28e0fd73ddb70f7b3895a0b36799d1e2be1b084fe221cc84438b7772"
BACKUP_DIR=""
LOG_FILE="/root/senyz-rebuild.log"

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
  ./rebuild_server.sh --domain senyz.top --email you@example.com [options]

Options:
  --with-warp       Install official Cloudflare WARP full tunnel (default).
  --without-warp    Complete the base proxy without WARP.
  --yes             Skip the final YES confirmation.
  -h, --help        Show this help.

This script is intended for a freshly reinstalled Debian 12 or Debian 13 server.
It never asks for or stores a Cloudflare API token.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --domain)
            [[ $# -ge 2 ]] || die '--domain requires a value.'
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            [[ $# -ge 2 ]] || die '--email requires a value.'
            EMAIL="$2"
            shift 2
            ;;
        --with-warp)
            ENABLE_WARP=1
            shift
            ;;
        --without-warp)
            ENABLE_WARP=0
            shift
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
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'A valid certificate email is required.'
[[ -r /etc/os-release ]] || die '/etc/os-release is missing.'

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'debian' ]] || die 'Only Debian is supported.'
case "${VERSION_ID:-}" in
    12|13) ;;
    *) die "Debian ${VERSION_ID:-unknown} is not supported by this script." ;;
esac
[[ -d /run/systemd/system ]] || die 'systemd is required.'
[[ -s /root/.ssh/authorized_keys ]] \
    || die 'No root SSH public key was found. Select a key in DMIT before running this script.'
if [[ -x /usr/local/bin/v2ray || -f /usr/local/etc/v2ray/config.json || -f /etc/wireguard/wgcf.conf ]]; then
    die 'An existing proxy deployment was detected. Use repair_current_server.sh here, or reinstall Debian before using this rebuild script.'
fi

cat <<EOF

Clean server rebuild ${SCRIPT_VERSION}
  Debian:  ${VERSION_ID}
  Domain:  ${DOMAIN}
  Email:   ${EMAIL}
  WARP:    $([[ $ENABLE_WARP -eq 1 ]] && printf 'enabled' || printf 'disabled')

Before continuing, confirm that Cloudflare DNS for ${DOMAIN} is DNS-only
and points to this DMIT server. Keep this SSH window open until completion.
EOF

if (( ASSUME_YES == 0 )); then
    read -r -p 'Type YES to rebuild this clean server: ' answer
    [[ "$answer" == 'YES' ]] || die 'Cancelled.'
fi

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; warn "Rebuild stopped at line ${LINENO} with exit code ${rc}. Log: ${LOG_FILE}"; exit "$rc"' ERR

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/root/senyz-rebuild-backup-${timestamp}"
mkdir -p "$BACKUP_DIR"
for path in /etc/nginx/nginx.conf /etc/nginx/sites-available /etc/nginx/sites-enabled /usr/local/etc/v2ray; do
    if [[ -e "$path" ]]; then
        cp -a "$path" "$BACKUP_DIR/"
    fi
done

log 'Updating Debian and installing maintained packages.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg nginx certbot ufw unzip unattended-upgrades

log 'Allowing SSH before enabling the firewall.'
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
ufw --force enable

log 'Keeping root login key-only without changing the SSH port.'
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-senyz-key-only.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
EOF
/usr/sbin/sshd -t
systemctl reload ssh

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52senyz-no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

install -d -m 755 "${WEBROOT}/.well-known/acme-challenge"
install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > /etc/nginx/conf.d/senyz-basics.conf <<'EOF'
server_tokens off;
EOF

cat > "$SITE_AVAILABLE" <<EOF
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

ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

log 'Checking DNS before requesting a certificate.'
public_ip="$(curl -4 -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace \
    | awk -F= '$1 == "ip" {print $2; exit}')"
[[ -n "$public_ip" ]] || die 'Could not determine the server public IPv4 address.'
mapfile -t domain_ips < <(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
(( ${#domain_ips[@]} > 0 )) || die "DNS does not resolve ${DOMAIN}."
dns_matches=0
for domain_ip in "${domain_ips[@]}"; do
    if [[ "$domain_ip" == "$public_ip" ]]; then
        dns_matches=1
        break
    fi
done
if (( dns_matches == 0 )); then
    printf 'Server IPv4: %s\n' "$public_ip"
    printf 'DNS IPv4:    %s\n' "${domain_ips[*]}"
    die 'Cloudflare DNS does not point directly to this server. Update the DNS-only A record and run the script again.'
fi

challenge_name="senyz-${timestamp}"
printf '%s' "$challenge_name" > "${WEBROOT}/.well-known/acme-challenge/${challenge_name}"
challenge_result="$(curl -4 -fsS --max-time 20 "http://${DOMAIN}/.well-known/acme-challenge/${challenge_name}" || true)"
rm -f "${WEBROOT}/.well-known/acme-challenge/${challenge_name}"
[[ "$challenge_result" == "$challenge_name" ]] \
    || die 'Port 80 or the HTTP challenge path is not reachable from the Internet.'

log 'Obtaining a Let's Encrypt certificate with automatic webroot renewal.'
certbot certonly --non-interactive --agree-tos \
    --email "$EMAIL" \
    --webroot --webroot-path "$WEBROOT" \
    --cert-name "$DOMAIN" \
    --key-type ecdsa \
    --domain "$DOMAIN"

log 'Installing V2Ray with the pinned official V2Fly installer.'
v2_installer="$(mktemp)"
curl -fsSLo "$v2_installer" \
    "https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/${V2_INSTALL_COMMIT}/install-release.sh"
bash "$v2_installer"
rm -f "$v2_installer"

uuid="$(cat /proc/sys/kernel/random/uuid)"
install -d -m 755 "$(dirname "$V2RAY_CONFIG")"
cat > "$V2RAY_CONFIG" <<EOF
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
          "path": "/ray"
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
chmod 644 "$V2RAY_CONFIG"

if /usr/local/bin/v2ray test -config "$V2RAY_CONFIG" >/dev/null 2>&1; then
    log 'V2Ray configuration test passed.'
elif /usr/local/bin/v2ray -test -config "$V2RAY_CONFIG" >/dev/null 2>&1; then
    log 'V2Ray configuration test passed.'
else
    die 'V2Ray rejected the generated configuration.'
fi

cat > "$SITE_AVAILABLE" <<EOF
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

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location = /ray {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF

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

log 'Testing certificate renewal against the Let's Encrypt staging service.'
certbot renew --cert-name "$DOMAIN" --dry-run

vmess_json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/ray","tls":"tls","sni":"%s"}' \
    "$DOMAIN" "$DOMAIN" "$uuid" "$DOMAIN" "$DOMAIN")"
vmess_url="vmess://$(printf '%s' "$vmess_json" | base64 -w 0)"

cat > "$CLIENT_FILE" <<EOF
V2Ray client settings
=====================
Name: ${DOMAIN}
Address: ${DOMAIN}
Port: 443
UUID: ${uuid}
AlterId: 0
Encryption: auto
Transport: WebSocket
WebSocket path: /ray
Host: ${DOMAIN}
TLS: enabled
SNI: ${DOMAIN}

One-click import link for v2rayN / Shadowrocket:
${vmess_url}
EOF
chmod 600 "$CLIENT_FILE"

if (( ENABLE_WARP == 1 )); then
    log 'Installing the reviewed official WARP full-tunnel manager.'
    curl -fsSLo /root/senyz-warp.sh \
        "https://raw.githubusercontent.com/syubroken/server_proxy_setup/${WARP_COMMIT}/warp.sh"
    printf '%s  %s\n' "$WARP_SHA256" /root/senyz-warp.sh | sha256sum -c -
    chmod 700 /root/senyz-warp.sh
    WARP_MANAGED_SERVICE=v2ray /root/senyz-warp.sh install --yes
fi

log 'Running final checks.'
nginx -t
systemctl is-active --quiet nginx || die 'Nginx is not active.'
systemctl is-active --quiet v2ray || die 'V2Ray is not active.'
ss -lnt | grep -Eq '127\.0\.0\.1:10001[[:space:]]' || die 'V2Ray is not listening on 127.0.0.1:10001.'
https_code="$(curl -sS --resolve "${DOMAIN}:443:127.0.0.1" \
    --output /dev/null --write-out '%{http_code}' "https://${DOMAIN}/")"
[[ "$https_code" == '404' ]] || die "Unexpected local HTTPS response: ${https_code}"

printf '\n============================================================\n'
printf 'Rebuild complete. Client details are saved in:\n  %s\n\n' "$CLIENT_FILE"
cat "$CLIENT_FILE"
printf '\nLog: %s\n' "$LOG_FILE"
printf 'Backup: %s\n' "$BACKUP_DIR"
if [[ -e /var/run/reboot-required ]]; then
    printf '\nDebian requests a reboot. Reboot from the DMIT panel after saving the client link.\n'
fi
