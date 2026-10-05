#!/usr/bin/env bash
# Minimal legacy fallback: VMess / WebSocket / TLS, native VPS egress, no WARP.
set -Eeuo pipefail
set +x
umask 022

stage='准备'
trap 'printf "\n停止：%s未完成。保留最后几行错误，不要公开 Key 或完整配置。\n" "$stage" >&2' ERR
stop() { printf '停止：%s\n' "$1" >&2; exit 1; }

download() {
    local url=$1 destination=$2 digest=$3
    curl --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 -fsSL -o "$destination" "$url"
    printf '%s  %s\n' "$digest" "$destination" | sha256sum -c -
}

# BEGIN APT WAIT
# Retry only lock contention. Never delete locks or interrupt their owner.
apt_wait() {
    local log status started=$SECONDS
    log=$(mktemp)
    while true; do
        if LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get \
            -o DPkg::Lock::Timeout=0 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold -o APT::Update::Error-Mode=any "$@" >"$log" 2>&1; then
            cat "$log"; rm -f -- "$log"; return 0
        else
            status=$?
        fi
        if ! grep -Eq '^E: (Could not get lock |Unable to acquire .*lock|Unable to lock directory )' "$log"; then
            cat "$log" >&2; rm -f -- "$log"; return "$status"
        fi
        if (( SECONDS - started >= 600 )); then
            cat "$log" >&2; rm -f -- "$log"
            printf '%s\n' '停止：等待软件安装锁超过 10 分钟。后台任务仍在运行；不要删除锁、杀进程或重装。稍后重跑同一脚本。' >&2
            return "$status"
        fi
        printf '%s\n' '系统后台正在使用 apt/dpkg，自动等待 5 秒后继续（最多 10 分钟）；无需另开窗口运行 apt。'
        sleep 5
    done
}
# END APT WAIT

main() {
    [[ $EUID == 0 && -d /run/systemd/system ]] || stop '在 Debian VPS 的 root SSH 终端运行。'
    [[ -t 0 ]] || stop '请先下载到文件，再用 bash 运行，不要通过管道运行。'
    grep -qx 'ID=debian' /etc/os-release || stop '此修正版用于 Debian。'
    [[ $(dpkg --print-architecture) == amd64 ]] || stop '此下载版本用于 amd64/x86_64。'
    for path in /opt/senyz-proxy-simple /var/lib/senyz-proxy-simple /var/lib/cloudflare-warp /etc/wireguard/wgcf.conf; do
        [[ ! -e $path && ! -L $path ]] || stop '检测到新版或 WARP；先在供应商面板重装 Debian，再运行本备选。'
    done
    if [[ -e /usr/local/etc/v2ray/config.json && ! -f /etc/v2ray/legacy-fixed.uuid ]]; then
        stop '检测到其他旧部署；本备选从干净 Debian 安装，不覆盖正在使用的代理。'
    fi

    printf '%s\n' '旧方案修正版：VMess + WebSocket + TLS，不安装 WARP。'
    read -r -p 'Cloudflare 注册邮箱：' USER_EMAIL
    read -r -p '代理域名（例如 senyz.top）：' USER_DOMAIN
    [[ $USER_EMAIL =~ ^[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || stop '邮箱格式不正确。'
    [[ ${#USER_DOMAIN} -le 253 && $USER_DOMAIN =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$ && $USER_DOMAIN != *..* ]] || stop '请输入小写域名，不带 https:// 或路径。'
    if [[ -f /etc/v2ray/legacy-fixed.domain ]]; then
        [[ $(cat /etc/v2ray/legacy-fixed.domain) == "$USER_DOMAIN" ]] || stop '重复运行时请使用相同域名。'
    fi
    read -r -s -p '新的 Global API Key（输入隐藏，不是 API Token）：' CF_Key
    printf '\n'
    [[ $CF_Key =~ ^[A-Za-z0-9_-]{20,128}$ ]] || stop 'Global API Key 格式不正确。'

    stage='系统与软件安装'
    export DEBIAN_FRONTEND=noninteractive
    printf '%s\n' '准备系统软件；如后台初始化占用安装锁，将自动等待。软件安装时请耐心等待。'
    apt_wait update
    apt_wait upgrade -y
    apt_wait install -y vim ufw socat nginx ca-certificates curl openssl cron unzip
    cat > /root/.vimrc <<'VIM'
set nocompatible
set encoding=utf-8
set fileencodings=utf-8,Chinese
set tabstop=4
set shiftwidth=4
set number
set autoindent
set smartindent
set nobackup
set hlsearch
set display=lastline
syntax on
VIM

    # Permit the current SSH port BEFORE enabling the original UFW firewall.
    local ssh_port=22
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        ssh_port=${SSH_CONNECTION##* }
    fi
    [[ $ssh_port =~ ^[0-9]+$ && $ssh_port -ge 1 && $ssh_port -le 65535 ]] || stop '无法确定当前 SSH 端口。'
    ufw allow "$ssh_port/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable

    local cache
    cache=$(mktemp -d /root/legacy-fixed-download.XXXXXXXX)
    mkdir -p "$cache/dnsapi"
    download 'https://raw.githubusercontent.com/acmesh-official/acme.sh/807da6498377ee5e0cf43a78091f46f12dc59a89/acme.sh' \
        "$cache/acme.sh" 'c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7'
    download 'https://raw.githubusercontent.com/acmesh-official/acme.sh/807da6498377ee5e0cf43a78091f46f12dc59a89/dnsapi/dns_cf.sh' \
        "$cache/dnsapi/dns_cf.sh" '9628ee8238cb3f9cfa1b1a985c0e9593436a3e4f8a9d65a6f775b981be9e76c8'
    download 'https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/cb39ee88249d47ed1c601dd5d3d94758d8835629/install-release.sh' \
        "$cache/install-release.sh" 'e82217ce0db9e68f41ca34521ecd4ac98018d22d9ddd83e1316c74fb805603ae'
    download 'https://github.com/v2fly/v2ray-core/releases/download/v5.53.0/v2ray-linux-64.zip' \
        "$cache/v2ray.zip" '6bbb8aee65a57d0b12599b4b7c842b3ad0daca4436e661d94015c447cb31b4fa'

    mkdir -p /etc/v2ray
    chmod 755 /etc/v2ray
    if [[ ! -s /etc/v2ray/legacy-fixed.uuid ]]; then
        cat /proc/sys/kernel/random/uuid > /etc/v2ray/legacy-fixed.uuid
        chmod 600 /etc/v2ray/legacy-fixed.uuid
    fi
    printf '%s\n' "$USER_DOMAIN" > /etc/v2ray/legacy-fixed.domain
    local uuid
    uuid=$(cat /etc/v2ray/legacy-fixed.uuid)
    [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || stop '已保存的 UUID 格式不正确。'
    # The official installer includes its geo data; a second installer is unnecessary.
    bash "$cache/install-release.sh" --local "$cache/v2ray.zip"
    cat > /usr/local/etc/v2ray/config.json <<V2RAY
{
  "inbounds": [{
    "port": 10001, "listen": "127.0.0.1", "protocol": "vmess",
    "settings": {"clients": [{"id": "$uuid", "alterId": 0}]},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "/ray"}}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
V2RAY
    chmod 644 /usr/local/etc/v2ray/config.json
    /usr/local/bin/v2ray test -config /usr/local/etc/v2ray/config.json

    stage='证书工具与续期配置'
    (cd "$cache" && bash ./acme.sh --install --home /root/.acme.sh --accountemail "$USER_EMAIL")
    chmod 700 /root/.acme.sh
    local account=/root/.acme.sh/account.conf new_account
    new_account=$(mktemp /root/.acme.sh/account.conf.XXXXXXXX)
    # Inputs above cannot contain shell quotes/newlines. Replace stale values on retry.
    sed -E '/^[[:space:]]*(export[[:space:]]+)?(SAVED_)?CF_(Key|Email|Token|Account_ID|Zone_ID)[[:space:]]*=/d' "$account" > "$new_account"
    printf "SAVED_CF_Key='%s'\nSAVED_CF_Email='%s'\n" "$CF_Key" "$USER_EMAIL" >> "$new_account"
    chmod 600 "$new_account"
    mv -- "$new_account" "$account"
    export CF_Key CF_Email="$USER_EMAIL"
    unset CF_Token CF_Account_ID CF_Zone_ID
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --register-account --server letsencrypt -m "$USER_EMAIL"

    stage='Cloudflare DNS 证书签发'
    local issue_status=0
    /root/.acme.sh/acme.sh --issue --server letsencrypt --dns dns_cf -d "$USER_DOMAIN" --keylength ec-256 || issue_status=$?
    # acme.sh uses 2 when a valid existing certificate does not need reissuance.
    [[ $issue_status == 0 || $issue_status == 2 ]] || stop '证书签发失败，未报告安装成功；不要加 --force 反复申请。'
    openssl verify -purpose sslserver -verify_hostname "$USER_DOMAIN" \
        -CAfile /etc/ssl/certs/ca-certificates.crt \
        -untrusted "/root/.acme.sh/${USER_DOMAIN}_ecc/fullchain.cer" \
        "/root/.acme.sh/${USER_DOMAIN}_ecc/fullchain.cer"
    unset CF_Key CF_Email

    stage='证书部署与服务启动'
    /root/.acme.sh/acme.sh --install-cert -d "$USER_DOMAIN" --ecc \
        --fullchain-file /etc/v2ray/v2ray.crt --key-file /etc/v2ray/v2ray.key \
        --reloadcmd 'nginx -t && systemctl reload-or-restart nginx'
    chmod 600 /etc/v2ray/v2ray.key
    # Use one dedicated file so retrying a failed installation cannot append duplicates.
    cat > /etc/nginx/conf.d/legacy-proxy.conf <<NGINX
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate /etc/v2ray/v2ray.crt;
    ssl_certificate_key /etc/v2ray/v2ray.key;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    server_name $USER_DOMAIN;
    location /ray {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
NGINX
    nginx -t
    systemctl enable nginx v2ray cron
    systemctl reload-or-restart nginx
    systemctl restart v2ray
    systemctl start cron
    for service in nginx v2ray cron; do
        systemctl is-active --quiet "$service"
    done
    crontab -l | grep -F '/root/.acme.sh' | grep -F -- '--cron' >/dev/null
    local tls_ready=false attempt
    for ((attempt=0; attempt<10; attempt++)); do
        if timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$USER_DOMAIN" \
            -verify_hostname "$USER_DOMAIN" -verify_return_error </dev/null >/dev/null 2>&1; then
            tls_ready=true
            break
        fi
        sleep 1
    done
    [[ $tls_ready == true ]] || stop 'Nginx 的实际 TLS 握手未通过，未报告安装成功。'
    printf '\n===============================================\n'
    printf 'Setup Complete：旧方案代理配置完成（不含 WARP）。\n'
    printf '域名：%s\nUUID：%s\n端口：443\n协议：VMess\n传输：WebSocket\n路径：/ray\nTLS：开启；SNI/Host：%s\nalterId：0\n' "$USER_DOMAIN" "$uuid" "$USER_DOMAIN"
    printf '证书使用 Cloudflare DNS 自动续期；以后更换 Global API Key 时也需更新服务器凭据。\n'
    printf '请使用以上参数导入客户端；不要把 UUID 或 Key 发到聊天。\n'
}

main "$@"
