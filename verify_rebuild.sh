#!/usr/bin/env bash

# Read-only verification for the clean base rebuild and optional WARP phase.
# It never prints a VMess UUID, WebSocket path, client URL, or private key.

set -uo pipefail
umask 077
export LC_ALL=C

SCRIPT_VERSION="3.0.0-rc2"
STATE_ENV="/etc/senyz-proxy/deployment.env"
SITE_FILE="/etc/nginx/sites-available/senyz-proxy"
CLIENT_FILE="/root/senyz-client.txt"
REQUIRE_WARP=0
RESUME_WARP=0
WARP_STAGED_MARKER="/var/lib/senyz-warp/install-staged"
WARP_COMPLETE_MARKER="/var/lib/senyz-warp/install-complete"
WARP_STOP_MARKER="/var/lib/senyz-warp/managed-service-stopped"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '[WARN] %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$*"
}

service_active() {
    local service="$1"
    local label="$2"
    if systemctl is-active --quiet "${service}"; then
        pass "${label} is active."
    else
        fail "${label} is not active."
    fi
}

private_mode() {
    local file="$1"
    local label="$2"
    local mode
    if [[ ! -f "${file}" ]]; then
        fail "${label} is missing."
        return
    fi
    mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
    case "${mode}" in
        400|600) pass "${label} has private permissions (${mode})." ;;
        *) fail "${label} permissions are ${mode:-unknown}; expected 400 or 600." ;;
    esac
}

usage() {
    cat <<'EOF'
Usage:
  senyz-verify-rebuild [--require-warp] [--resume-warp]

The default accepts a healthy base deployment without WARP. Add --require-warp
after the WARP phase to require official WARP, its watchdog, and dual-stack
Cloudflare trace verification.
The guided installer uses --resume-warp only while continuing an incomplete,
recorded WARP stage.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --require-warp) REQUIRE_WARP=1 ;;
        --resume-warp) RESUME_WARP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ ${EUID} -eq 0 ]] || { printf '[ERROR] Run this read-only check as root.\n' >&2; exit 2; }

printf 'senyz clean rebuild verification %s\n' "${SCRIPT_VERSION}"
printf 'No client credential or private key will be displayed.\n\n'

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == 'debian' && "${VERSION_ID:-}" =~ ^(12|13)$ ]]; then
        pass "Operating system is Debian ${VERSION_ID}."
    else
        fail "Unsupported operating system: ${PRETTY_NAME:-unknown}."
    fi
else
    fail '/etc/os-release is missing.'
fi

DOMAIN=""
WEBROOT=""
if [[ -r "${STATE_ENV}" ]]; then
    # shellcheck disable=SC1090
    . "${STATE_ENV}"
    if [[ -n "${DOMAIN:-}" && -n "${WEBROOT:-}" ]]; then
        pass 'Deployment metadata is present.'
    else
        fail 'Deployment metadata is incomplete.'
    fi
else
    fail "Deployment metadata is missing: ${STATE_ENV}"
fi

for required_command in curl grep ip nginx openssl ss ssh-keygen stat systemctl ufw; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        fail "Required verification command is missing: ${required_command}"
    fi
done

service_active ssh 'SSH'
service_active nginx 'Nginx'
protected_resume=0
if (( RESUME_WARP == 1 )) \
    && [[ -f "${WARP_STAGED_MARKER}" ]] \
    && [[ -f "${WARP_STOP_MARKER}" ]] \
    && [[ ! -f "${WARP_COMPLETE_MARKER}" ]]; then
    protected_resume=1
fi
if (( protected_resume == 1 )) && systemctl is-active --quiet v2ray; then
    fail 'V2Ray is active despite a recorded WARP fail-closed stop marker.'
elif (( protected_resume == 1 )); then
    warn 'V2Ray is stopped by the recorded WARP fail-closed stage; the installer may resume it.'
else
    service_active v2ray 'V2Ray'
fi

if nginx -t >/dev/null 2>&1; then
    pass 'Nginx configuration syntax is valid.'
else
    fail 'Nginx configuration syntax is invalid.'
fi

if [[ -s /root/.ssh/authorized_keys ]] \
    && ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null 2>&1; then
    pass 'The root SSH public key is readable.'
else
    fail 'The root SSH public key is missing or invalid.'
fi
private_mode /root/.ssh/authorized_keys 'root authorized_keys'

sshd_effective="$(/usr/sbin/sshd -T 2>/dev/null || true)"
if grep -qx 'passwordauthentication no' <<<"${sshd_effective}" \
    && grep -qx 'kbdinteractiveauthentication no' <<<"${sshd_effective}" \
    && grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"${sshd_effective}"; then
    pass 'SSH is root-key-only.'
else
    fail 'Effective SSH settings are not root-key-only.'
fi

ufw_output="$(ufw status 2>/dev/null || true)"
if grep -qx 'Status: active' <<<"${ufw_output}"; then
    pass 'UFW is active.'
else
    fail 'UFW is not active.'
fi
for required_port in 80 443; do
    if grep -Eq "^${required_port}/tcp[[:space:]]+ALLOW" <<<"${ufw_output}"; then
        pass "UFW allows TCP ${required_port}."
    else
        fail "UFW does not show an allow rule for TCP ${required_port}."
    fi
done
mapfile -t ssh_ports < <(awk '$1 == "port" {print $2}' <<<"${sshd_effective}" | sort -u)
for ssh_port in "${ssh_ports[@]:-22}"; do
    if grep -Eq "^${ssh_port}/tcp[[:space:]]+ALLOW" <<<"${ufw_output}"; then
        pass "UFW allows the effective SSH port ${ssh_port}."
    else
        fail "UFW does not show an allow rule for SSH port ${ssh_port}."
    fi
done

listeners="$(ss -H -lnt 2>/dev/null || true)"
v2ray_listeners="$(awk '$4 ~ /:10001$/ {print $4}' <<<"${listeners}")"
if [[ "${v2ray_listeners}" == '127.0.0.1:10001' ]]; then
    pass 'V2Ray listens only on 127.0.0.1:10001.'
elif (( protected_resume == 1 )) && [[ -z "${v2ray_listeners}" ]]; then
    warn 'V2Ray port 10001 is absent while the recorded WARP fail-closed stage is active.'
else
    fail 'V2Ray port 10001 is missing or exposed on an unexpected address.'
fi
for public_port in 80 443; do
    if awk -v suffix=":${public_port}" '$4 ~ (suffix "$") {found=1} END {exit !found}' <<<"${listeners}"; then
        pass "A listener exists on TCP ${public_port}."
    else
        fail "No listener exists on TCP ${public_port}."
    fi
done

if [[ -n "${DOMAIN:-}" ]]; then
    certificate="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    renewal_file="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    if [[ -r "${certificate}" ]]; then
        if openssl x509 -in "${certificate}" -noout -ext subjectAltName 2>/dev/null \
            | grep -Fq "DNS:${DOMAIN}"; then
            pass 'The certificate contains the configured domain.'
        else
            fail 'The certificate does not contain the configured domain.'
        fi
        if openssl x509 -in "${certificate}" -noout -checkend 1814400 >/dev/null 2>&1; then
            pass 'The certificate remains valid for more than 21 days.'
        else
            fail 'The certificate expires within 21 days.'
        fi
    else
        fail 'The live TLS certificate is missing.'
    fi
    if [[ -r "${renewal_file}" ]] \
        && grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*webroot[[:space:]]*$' "${renewal_file}"; then
        pass 'Certbot renewal uses Webroot.'
    else
        fail 'Certbot Webroot renewal is not configured.'
    fi
    if systemctl is-enabled --quiet certbot.timer \
        && systemctl is-active --quiet certbot.timer; then
        pass 'The Certbot renewal timer is enabled and active.'
    else
        fail 'The Certbot renewal timer is not enabled and active.'
    fi
    https_code="$(curl --noproxy '*' -sS --max-time 15 \
        --resolve "${DOMAIN}:443:127.0.0.1" \
        --output /dev/null --write-out '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || true)"
    if [[ "${https_code}" == '404' ]]; then
        pass 'Local HTTPS responds with the expected 404 cover response.'
    else
        fail "Local HTTPS returned ${https_code:-no response}; expected 404."
    fi
fi

if [[ -r "${SITE_FILE}" ]]; then
    if grep -Eq '^[[:space:]]*ssl_protocols[[:space:]]+TLSv1\.2[[:space:]]+TLSv1\.3;' "${SITE_FILE}" \
        && ! grep -Eq 'ssl_protocols.*TLSv1([[:space:];]|\.1)' "${SITE_FILE}"; then
        pass 'Nginx permits only TLS 1.2 and TLS 1.3.'
    else
        fail 'Nginx TLS protocol policy is unexpected.'
    fi
    if grep -Eq '^[[:space:]]*proxy_read_timeout[[:space:]]+3600s;' "${SITE_FILE}" \
        && grep -Eq '^[[:space:]]*proxy_send_timeout[[:space:]]+3600s;' "${SITE_FILE}" \
        && grep -Eq '^[[:space:]]*proxy_socket_keepalive[[:space:]]+on;' "${SITE_FILE}"; then
        pass 'WebSocket timeout and TCP keepalive settings are present.'
    else
        fail 'WebSocket timeout or TCP keepalive settings are missing.'
    fi
else
    fail "Nginx site configuration is missing: ${SITE_FILE}"
fi

private_mode "${STATE_ENV}" 'deployment metadata'
private_mode "${CLIENT_FILE}" 'client details'
private_mode /root/senyz-base-rebuild.log 'base rebuild log'
if [[ -x /usr/local/sbin/senyz-show-client ]]; then
    pass 'The simple client-display command is installed.'
else
    fail 'The simple client-display command is missing.'
fi

if dpkg-query -W unattended-upgrades >/dev/null 2>&1 \
    && [[ -r /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    pass 'Automatic security-update support is installed and configured.'
else
    fail 'Automatic security-update support is incomplete.'
fi

if [[ -e /etc/wireguard/wgcf.conf ]] \
    || systemctl is-active --quiet wg-quick@wgcf.service 2>/dev/null; then
    fail 'Legacy wgcf/WireGuard was detected on a clean rebuild.'
fi

warp_staged=0
warp_complete=0
[[ -f "${WARP_STAGED_MARKER}" ]] && warp_staged=1
[[ -f "${WARP_COMPLETE_MARKER}" ]] && warp_complete=1

if (( RESUME_WARP == 1 && warp_staged == 1 && warp_complete == 0 )); then
    private_mode "${WARP_STAGED_MARKER}" 'WARP staged-state marker'
    if dpkg-query -W cloudflare-warp >/dev/null 2>&1; then
        pass 'The official cloudflare-warp package is staged for continuation.'
    else
        warn 'The WARP package is not installed yet; the guided installer may continue the staged step.'
    fi
    if [[ -f "${WARP_STOP_MARKER}" ]]; then
        warn 'The managed proxy is in recorded fail-closed protection until WARP continuation succeeds.'
    else
        pass 'No WARP fail-closed stop marker is present.'
    fi
    warn 'Final WARP route, watchdog, and dual-stack checks are deferred until continuation completes.'
else
warp_present=0
if [[ -r /etc/senyz-warp/settings.env ]] \
    || dpkg-query -W cloudflare-warp >/dev/null 2>&1; then
    warp_present=1
fi

if (( warp_present == 0 )); then
    if (( REQUIRE_WARP == 1 )); then
        fail 'WARP is required but is not installed.'
    else
        warn 'WARP is not installed; this is valid only for the base phase.'
    fi
else
    if dpkg-query -W cloudflare-warp >/dev/null 2>&1; then
        pass 'The official cloudflare-warp package is installed.'
    else
        fail 'WARP settings exist but the official package is missing.'
    fi
    if [[ -f "${WARP_COMPLETE_MARKER}" ]]; then
        private_mode "${WARP_COMPLETE_MARKER}" 'WARP completion marker'
    elif (( REQUIRE_WARP == 1 )); then
        fail 'The WARP installation has not recorded successful completion.'
    else
        warn 'The WARP installation has not recorded successful completion.'
    fi
    service_active warp-svc 'Cloudflare WARP service'
    service_active senyz-warp-route-guard 'WARP management-route guard'
    warp_status="$(LC_ALL=C warp-cli --accept-tos status 2>&1 || LC_ALL=C warp-cli status 2>&1 || true)"
    if grep -Eiq '(^|[^[:alpha:]])Connected([^[:alpha:]]|$)' <<<"${warp_status}"; then
        pass 'warp-cli reports Connected.'
    else
        fail 'warp-cli does not report Connected.'
    fi
    if systemctl is-enabled --quiet senyz-warp-watchdog.timer \
        && systemctl is-active --quiet senyz-warp-watchdog.timer; then
        pass 'The WARP watchdog timer is enabled and active.'
    else
        fail 'The WARP watchdog timer is not enabled and active.'
    fi
    if [[ -x /usr/local/sbin/senyz-warp-health ]] \
        && /usr/local/sbin/senyz-warp-health --quiet; then
        pass 'WARP IPv4 and IPv6 traces are both active.'
    else
        fail 'WARP dual-stack trace verification failed.'
    fi
    if [[ -r /etc/senyz-warp/settings.env ]]; then
        WARP_MANAGED_SERVICE=""
        # shellcheck disable=SC1091
        . /etc/senyz-warp/settings.env
        if [[ -n "${WARP_MANAGED_SERVICE:-}" ]]; then
            guard_file="/etc/systemd/system/${WARP_MANAGED_SERVICE}.service.d/90-senyz-warp.conf"
        else
            guard_file=""
            fail 'WARP_MANAGED_SERVICE is missing from WARP settings.'
        fi
        if [[ -n "${guard_file}" && -r "${guard_file}" ]] \
            && grep -Fq 'ExecStartPre=/usr/local/sbin/senyz-warp-health --quiet' "${guard_file}" \
            && grep -Fq 'BindsTo=warp-svc.service' "${guard_file}"; then
            pass 'The managed service has a fail-closed startup guard.'
        else
            fail 'The managed service startup guard is missing.'
        fi
        private_mode /etc/senyz-warp/settings.env 'WARP settings'
        private_mode /etc/senyz-warp/route.env 'WARP route metadata'
        if [[ -r /etc/senyz-warp/route.env ]]; then
            RULE_PRIORITY=""
            IPV4_SOURCE=""
            # shellcheck disable=SC1091
            . /etc/senyz-warp/route.env
            if [[ -n "${RULE_PRIORITY:-}" && -n "${IPV4_SOURCE:-}" ]] \
                && ip -4 rule show | grep -Eq \
                    "^${RULE_PRIORITY}:[[:space:]]+from[[:space:]]+${IPV4_SOURCE}([/][0-9]+)?[[:space:]].*lookup[[:space:]]+(main|254)"; then
                pass 'The direct IPv4 management-route rule is present.'
            else
                fail 'The direct IPv4 management-route rule is missing.'
            fi
        else
            fail 'WARP route metadata cannot be read.'
        fi
        if [[ -f /var/lib/senyz-warp/managed-service-should-run ]]; then
            pass 'The managed-service recovery intent is recorded.'
        else
            fail 'The managed-service recovery intent is missing.'
        fi
    else
        fail 'WARP settings are missing.'
    fi
fi
fi

printf '\nSummary: PASS=%s WARN=%s FAIL=%s\n' \
    "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
if (( FAIL_COUNT > 0 )); then
    printf 'Result: FAIL. No settings were changed.\n'
    exit 1
fi
printf 'Result: PASS. No settings were changed.\n'
