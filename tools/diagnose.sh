#!/usr/bin/env bash
# Read-only summary for legacy and simple installations. Never repair or renew.
set -uo pipefail
set +x
export LC_ALL=C

printf '%s\n' 'Proxy diagnostic summary (no installation, restart, renewal or firewall changes)'
if (( EUID != 0 )); then
    printf '%s\n' 'WARN: run as root for complete permission/service checks.'
fi
if [[ -r /etc/os-release ]]; then
    awk -F= '/^(ID|VERSION_ID)=/ {print}' /etc/os-release
fi
printf 'UTC: '
date -u '+%Y-%m-%d %H:%M:%S'

if command -v systemctl >/dev/null 2>&1; then
    for unit in nginx v2ray warp-svc sps-nginx sps-proxy sps-renew.timer; do
        printf 'service %s: ' "$unit"
        systemctl is-active "$unit" 2>/dev/null || true
    done
fi

# Validation output can contain configuration values; only report the result.
if command -v nginx >/dev/null 2>&1; then
    if [[ -f /etc/senyz-proxy-simple/nginx.conf ]]; then
        nginx -t -c /etc/senyz-proxy-simple/nginx.conf >/dev/null 2>&1
    else
        nginx -t >/dev/null 2>&1
    fi
    printf 'nginx config validation exit code: %s\n' "$?"
fi
if [[ -x /opt/senyz-proxy-simple/bin/v2ray && -f /etc/senyz-proxy-simple/v2ray.json ]]; then
    /opt/senyz-proxy-simple/bin/v2ray test -config /etc/senyz-proxy-simple/v2ray.json >/dev/null 2>&1
    printf 'simple v2ray config validation exit code: %s\n' "$?"
elif [[ -x /usr/local/bin/v2ray && -f /usr/local/etc/v2ray/config.json ]]; then
    /usr/local/bin/v2ray test -config /usr/local/etc/v2ray/config.json >/dev/null 2>&1
    printf 'legacy v2ray config validation exit code: %s\n' "$?"
fi

if command -v ss >/dev/null 2>&1; then
    printf '%s\n' 'TCP listening ports (addresses hidden):'
    ss -H -lnt 2>/dev/null | awk '{p=$4; sub(/^.*:/,"",p); if(p ~ /^[0-9]+$/) print p}' | sort -nu
fi

for cert in /etc/v2ray/v2ray.crt /etc/senyz-proxy-simple/fullchain.pem; do
    if [[ -r "$cert" ]] && command -v openssl >/dev/null 2>&1; then
        printf 'certificate %s: ' "$cert"
        openssl x509 -in "$cert" -noout -enddate 2>/dev/null || true
        if openssl x509 -in "$cert" -noout -checkend 1209600 >/dev/null 2>&1; then
            printf '%s\n' 'certificate valid for more than 14 days: yes'
        else
            printf '%s\n' 'certificate valid for more than 14 days: NO (or unreadable)'
        fi
    fi
done
if command -v crontab >/dev/null 2>&1; then
    if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
        printf '%s\n' 'root acme cron entry: present (does not prove renewal works)'
    else
        printf '%s\n' 'root acme cron entry: absent'
    fi
fi
if command -v nft >/dev/null 2>&1; then
    if nft list table inet sps >/dev/null 2>&1; then
        printf '%s\n' 'simple business firewall table: present (not an acceptance test)'
    else
        printf '%s\n' 'simple business firewall table: absent or unreadable'
    fi
fi

# Two bounded HTTPS requests from the host; no origin IP, cookies or keys printed.
if command -v curl >/dev/null 2>&1; then
    for family in 4 6; do
        trace=$(curl --noproxy '*' --proto '=https' --tlsv1.2 -"$family" -fsS \
            --connect-timeout 5 --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        if [[ $? == 0 ]]; then
            warp=$(printf '%s\n' "$trace" | awk -F= '$1=="warp" && $2 ~ /^(on|off|plus)$/ {print $2}')
            printf 'host IPv%s WARP trace: %s\n' "$family" "${warp:-unknown}"
        else
            printf 'host IPv%s WARP trace: unavailable\n' "$family"
        fi
    done
fi
printf '%s\n' 'Host trace is not a full proxy/WARP acceptance test. off means native host egress.'
printf '%s\n' 'Do not reinstall, force certificate issuance, or publish keys/configs based on this summary alone.'
