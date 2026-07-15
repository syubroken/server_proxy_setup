#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
CONFIG_DIR="/etc/senyz-warp"
ROUTE_ENV="${CONFIG_DIR}/route.env"
SETTINGS_ENV="${CONFIG_DIR}/settings.env"
STATE_DIR="/var/lib/senyz-warp"
WATCHDOG_MARKER="${STATE_DIR}/managed-service-stopped"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
ROUTE_GUARD="/usr/local/sbin/senyz-warp-route-guard"
WATCHDOG="/usr/local/sbin/senyz-warp-watchdog"
ROUTE_UNIT="senyz-warp-route-guard.service"
WATCHDOG_UNIT="senyz-warp-watchdog.service"
WATCHDOG_TIMER="senyz-warp-watchdog.timer"
WARP_SERVICE="warp-svc.service"

REQUESTED_MANAGED_SERVICE="${MANAGED_SERVICE:-}"
REQUESTED_WARP_PROTOCOL="${WARP_PROTOCOL:-}"
REQUESTED_FAIL_CLOSED="${FAIL_CLOSED:-}"
ASSUME_YES=0
MANAGED_SERVICE="${MANAGED_SERVICE:-v2ray}"
WARP_PROTOCOL="${WARP_PROTOCOL:-MASQUE}"
FAIL_CLOSED="${FAIL_CLOSED:-1}"

log() {
    printf '[senyz-warp] %s\n' "$*"
}

warn() {
    printf '[senyz-warp] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[senyz-warp] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_KEY_FILE:-}" && -f "${TEMP_KEY_FILE}" ]]; then
        rm -f -- "${TEMP_KEY_FILE}"
    fi
}

trap cleanup EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行，例如：sudo ./warp.sh $*"
}

require_supported_system() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统。"
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] || die "本脚本只支持 Debian 12/13。"
    case "${VERSION_ID:-}" in
        12|13) ;;
        *) die "当前 Debian ${VERSION_ID:-unknown} 不在 Cloudflare 官方支持范围内。" ;;
    esac

    command -v systemctl >/dev/null 2>&1 || die "系统未使用 systemd。"
    command -v ip >/dev/null 2>&1 || die "缺少 iproute2，无法保护 SSH 路由。"

    local architecture
    architecture="$(dpkg --print-architecture 2>/dev/null || true)"
    case "${architecture}" in
        amd64|arm64) ;;
        *) die "Cloudflare WARP 当前仅支持 amd64/arm64；检测到 ${architecture:-unknown}。" ;;
    esac
}

confirm() {
    local prompt="$1"
    local answer

    if [[ "${ASSUME_YES}" -eq 1 ]]; then
        return 0
    fi
    [[ -t 0 ]] || die "非交互运行需要附加 --yes。"
    printf '%s\n' "${prompt}"
    read -r -p "输入 YES 继续：" answer
    [[ "${answer}" == "YES" ]] || die "操作已取消。"
}

load_settings() {
    local requested_service="${REQUESTED_MANAGED_SERVICE}"
    local requested_protocol="${REQUESTED_WARP_PROTOCOL}"
    local requested_fail_closed="${REQUESTED_FAIL_CLOSED}"

    if [[ -r "${SETTINGS_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${SETTINGS_ENV}"
    fi
    if [[ -n "${requested_service}" ]]; then
        MANAGED_SERVICE="${requested_service}"
    fi
    if [[ -n "${requested_protocol}" ]]; then
        WARP_PROTOCOL="${requested_protocol}"
    fi
    if [[ -n "${requested_fail_closed}" ]]; then
        FAIL_CLOSED="${requested_fail_closed}"
    fi
    return 0
}

validate_settings() {
    [[ "${MANAGED_SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "MANAGED_SERVICE 名称不合法。"
    case "${WARP_PROTOCOL}" in
        MASQUE|WireGuard) ;;
        *) die "WARP_PROTOCOL 只能是 MASQUE 或 WireGuard（区分大小写）。" ;;
    esac
    case "${FAIL_CLOSED}" in
        0|1) ;;
        *) die "FAIL_CLOSED 只能是 0 或 1。" ;;
    esac
}

legacy_wgcf_present() {
    [[ -e /etc/wireguard/wgcf.conf ]] || \
        systemctl is-active --quiet wg-quick@wgcf.service 2>/dev/null || \
        systemctl is-enabled --quiet wg-quick@wgcf.service 2>/dev/null
}

refuse_legacy_install() {
    if legacy_wgcf_present; then
        die "检测到旧 wgcf/WireGuard 配置。为避免 SSH 断开，本脚本不会覆盖迁移；请在下一次干净重装后使用。"
    fi
}

install_dependencies() {
    log "安装基础依赖。"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release util-linux iproute2
}

rule_priority_in_use() {
    local priority="$1"
    ip -4 rule show | awk -v key="${priority}:" '$1 == key { found=1 } END { exit !found }' || \
        ip -6 rule show | awk -v key="${priority}:" '$1 == key { found=1 } END { exit !found }'
}

choose_rule_priority() {
    local priority
    for priority in {18..27}; do
        if ! rule_priority_in_use "${priority}"; then
            printf '%s\n' "${priority}"
            return 0
        fi
    done
    die "策略路由优先级 18-27 均被占用，无法安全安装。"
}

route_field() {
    local route_line="$1"
    local field="$2"
    awk -v wanted="${field}" '{ for (i=1; i<=NF; i++) if ($i == wanted && i < NF) { print $(i+1); exit } }' <<<"${route_line}"
}

capture_management_route() {
    local route4 route6 src4 src6 dev4 dev6 gateway4 gateway6 priority

    route4="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)"
    src4="$(route_field "${route4}" src)"
    dev4="$(route_field "${route4}" dev)"
    gateway4="$(route_field "${route4}" via)"
    [[ -n "${src4}" && -n "${dev4}" ]] || die "无法读取服务器原始 IPv4 路由，未启用 WARP。"

    route6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1 || true)"
    src6="$(route_field "${route6}" src)"
    dev6="$(route_field "${route6}" dev)"
    gateway6="$(route_field "${route6}" via)"
    priority="$(choose_rule_priority)"

    install -d -m 0700 "${CONFIG_DIR}"
    {
        printf 'RULE_PRIORITY=%q\n' "${priority}"
        printf 'IPV4_SOURCE=%q\n' "${src4}"
        printf 'IPV4_DEVICE=%q\n' "${dev4}"
        printf 'IPV4_GATEWAY=%q\n' "${gateway4}"
        printf 'IPV6_SOURCE=%q\n' "${src6}"
        printf 'IPV6_DEVICE=%q\n' "${dev6}"
        printf 'IPV6_GATEWAY=%q\n' "${gateway6}"
    } >"${ROUTE_ENV}"
    chmod 0600 "${ROUTE_ENV}"

    log "已记录管理路由：IPv4 ${src4} / ${dev4}；规则优先级 ${priority}。"
    if [[ -n "${src6}" ]]; then
        log "已记录 IPv6 管理路由：${src6} / ${dev6}。"
    else
        warn "没有检测到原始 IPv6 默认路由；继续使用 IPv4 管理通道。"
    fi
}

write_settings() {
    install -d -m 0700 "${CONFIG_DIR}" "${STATE_DIR}"
    {
        printf 'MANAGED_SERVICE=%q\n' "${MANAGED_SERVICE}"
        printf 'WARP_PROTOCOL=%q\n' "${WARP_PROTOCOL}"
        printf 'FAIL_CLOSED=%q\n' "${FAIL_CLOSED}"
    } >"${SETTINGS_ENV}"
    chmod 0600 "${SETTINGS_ENV}"
}

install_route_guard() {
    [[ -s "${ROUTE_ENV}" ]] || die "缺少 ${ROUTE_ENV}。"

    cat >"${ROUTE_GUARD}" <<'ROUTE_GUARD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROUTE_ENV="/etc/senyz-warp/route.env"
[[ -r "${ROUTE_ENV}" ]] || { echo "Missing ${ROUTE_ENV}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${ROUTE_ENV}"

ensure_rule() {
    local family="$1"
    local source_address="$2"
    local prefix="$3"
    local existing

    [[ -n "${source_address}" ]] || return 0
    existing="$(ip "-${family}" rule show | awk -v key="${RULE_PRIORITY}:" '$1 == key')"
    if [[ -n "${existing}" ]]; then
        if grep -Fq "from ${source_address}" <<<"${existing}" && grep -Eq 'lookup (main|254)' <<<"${existing}"; then
            return 0
        fi
        echo "Rule priority ${RULE_PRIORITY} is already used: ${existing}" >&2
        exit 1
    fi

    ip "-${family}" rule add pref "${RULE_PRIORITY}" from "${source_address}${prefix}" lookup main
}

ensure_rule 4 "${IPV4_SOURCE:-}" /32
ensure_rule 6 "${IPV6_SOURCE:-}" /128
ROUTE_GUARD_EOF
    chmod 0755 "${ROUTE_GUARD}"

    cat >"/etc/systemd/system/${ROUTE_UNIT}" <<EOF
[Unit]
Description=Preserve direct management routes before Cloudflare WARP
Wants=network-online.target
After=network-online.target
Before=${WARP_SERVICE}

[Service]
Type=oneshot
ExecStart=${ROUTE_GUARD}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${ROUTE_UNIT}"
}

install_cloudflare_client() {
    local codename
    codename="$(lsb_release -cs)"
    case "${codename}" in
        bookworm|trixie) ;;
        *) die "Cloudflare 官方软件源不支持 Debian 代号 ${codename}。" ;;
    esac

    log "配置 Cloudflare 官方 APT 软件源。"
    TEMP_KEY_FILE="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -fsSL \
        https://pkg.cloudflareclient.com/pubkey.gpg \
        -o "${TEMP_KEY_FILE}"
    install -d -m 0755 /usr/share/keyrings
    gpg --batch --yes --dearmor \
        --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        "${TEMP_KEY_FILE}"
    chmod 0644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [[ -n "${CLOUDFLARE_WARP_VERSION:-}" ]]; then
        apt-get install -y "cloudflare-warp=${CLOUDFLARE_WARP_VERSION}"
    else
        apt-get install -y cloudflare-warp
    fi
    systemctl enable --now "${WARP_SERVICE}"
}

warp_cli() {
    if warp-cli --help 2>&1 | grep -q -- '--accept-tos'; then
        warp-cli --accept-tos "$@"
    else
        warp-cli "$@"
    fi
}

ensure_registration() {
    if warp_cli registration show >/dev/null 2>&1; then
        log "沿用现有 WARP 注册。"
    else
        log "创建新的 WARP consumer 注册。"
        warp_cli registration new
    fi
}

configure_warp() {
    "${ROUTE_GUARD}"
    systemctl start "${ROUTE_UNIT}"
    systemctl enable --now "${WARP_SERVICE}"
    ensure_registration
    warp_cli mode warp+doh
    warp_cli tunnel protocol set "${WARP_PROTOCOL}"
}

trace_for_family() {
    local family="$1"
    curl "-${family}" -fsS --connect-timeout 8 --max-time 15 "${TRACE_URL}"
}

trace_is_warp() {
    grep -Eq '^warp=(on|plus)$'
}

warp_is_healthy() {
    local trace
    trace="$(trace_for_family 4 2>/dev/null || true)"
    [[ -n "${trace}" ]] && trace_is_warp <<<"${trace}"
}

wait_for_warp() {
    local attempt
    for attempt in {1..12}; do
        if warp_is_healthy; then
            return 0
        fi
        sleep 5
    done
    return 1
}

service_exists() {
    systemctl list-unit-files "${MANAGED_SERVICE}.service" --no-legend 2>/dev/null | grep -q .
}

protect_managed_service() {
    [[ "${FAIL_CLOSED}" == "1" ]] || return 0
    if service_exists && systemctl is-active --quiet "${MANAGED_SERVICE}.service"; then
        systemctl stop "${MANAGED_SERVICE}.service"
        install -d -m 0700 "${STATE_DIR}"
        touch "${WATCHDOG_MARKER}"
        warn "WARP 未通过检查，已停止 ${MANAGED_SERVICE}，避免代理流量直接使用服务器出口。"
    fi
}

recover_managed_service() {
    if [[ -f "${WATCHDOG_MARKER}" ]] && service_exists; then
        systemctl start "${MANAGED_SERVICE}.service"
        rm -f "${WATCHDOG_MARKER}"
        log "WARP 已恢复，重新启动 ${MANAGED_SERVICE}。"
    fi
}

install_watchdog() {
    cat >"${WATCHDOG}" <<'WATCHDOG_EOF'
#!/usr/bin/env bash
set -uo pipefail

SETTINGS_ENV="/etc/senyz-warp/settings.env"
ROUTE_GUARD="/usr/local/sbin/senyz-warp-route-guard"
STATE_DIR="/var/lib/senyz-warp"
MARKER="${STATE_DIR}/managed-service-stopped"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

[[ -r "${SETTINGS_ENV}" ]] || exit 0
# shellcheck disable=SC1090
source "${SETTINGS_ENV}"
mkdir -p "${STATE_DIR}" /run/lock
exec 9>/run/lock/senyz-warp-watchdog.lock
flock -n 9 || exit 0

warp_cli() {
    if warp-cli --help 2>&1 | grep -q -- '--accept-tos'; then
        warp-cli --accept-tos "$@"
    else
        warp-cli "$@"
    fi
}

healthy() {
    local trace
    trace="$(curl -4 -fsS --connect-timeout 8 --max-time 15 "${TRACE_URL}" 2>/dev/null || true)"
    grep -Eq '^warp=(on|plus)$' <<<"${trace}"
}

service_exists() {
    systemctl list-unit-files "${MANAGED_SERVICE}.service" --no-legend 2>/dev/null | grep -q .
}

if healthy; then
    if [[ -f "${MARKER}" ]] && service_exists && systemctl start "${MANAGED_SERVICE}.service"; then
        rm -f "${MARKER}"
        logger -t senyz-warp "WARP recovered; started ${MANAGED_SERVICE}."
    fi
    exit 0
fi

"${ROUTE_GUARD}" >/dev/null 2>&1 || true
systemctl restart warp-svc.service >/dev/null 2>&1 || true
sleep 5
warp_cli connect >/dev/null 2>&1 || true
sleep 10

if healthy; then
    if [[ -f "${MARKER}" ]] && service_exists && systemctl start "${MANAGED_SERVICE}.service"; then
        rm -f "${MARKER}"
    fi
    logger -t senyz-warp "WARP recovered after reconnect."
    exit 0
fi

if [[ "${FAIL_CLOSED:-1}" == "1" ]] && service_exists; then
    if systemctl is-active --quiet "${MANAGED_SERVICE}.service"; then
        systemctl stop "${MANAGED_SERVICE}.service"
        touch "${MARKER}"
    fi
    logger -t senyz-warp "WARP health check failed; ${MANAGED_SERVICE} is stopped (fail-closed)."
fi
exit 1
WATCHDOG_EOF
    chmod 0755 "${WATCHDOG}"

    cat >"/etc/systemd/system/${WATCHDOG_UNIT}" <<EOF
[Unit]
Description=Check Cloudflare WARP and protect the proxy exit
After=network-online.target ${WARP_SERVICE} ${ROUTE_UNIT}
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG}
EOF

    cat >"/etc/systemd/system/${WATCHDOG_TIMER}" <<EOF
[Unit]
Description=Run the senyz WARP health check periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
RandomizedDelaySec=15s
Persistent=true
Unit=${WATCHDOG_UNIT}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable "${WATCHDOG_TIMER}"
}

enable_watchdog() {
    systemctl enable --now "${WATCHDOG_TIMER}"
}

print_trace() {
    local family="$1"
    local label="$2"
    local trace warp ip_address location

    trace="$(trace_for_family "${family}" 2>/dev/null || true)"
    if [[ -z "${trace}" ]]; then
        printf '%-5s unavailable\n' "${label}:"
        return 0
    fi
    warp="$(awk -F= '$1 == "warp" { print $2 }' <<<"${trace}")"
    ip_address="$(awk -F= '$1 == "ip" { print $2 }' <<<"${trace}")"
    location="$(awk -F= '$1 == "loc" { print $2 }' <<<"${trace}")"
    printf '%-5s warp=%s ip=%s loc=%s\n' "${label}:" "${warp:-unknown}" "${ip_address:-unknown}" "${location:-unknown}"
}

do_status() {
    local package_version
    require_root status
    load_settings
    printf 'senyz-warp script: %s\n' "${SCRIPT_VERSION}"
    package_version="$(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null || true)"
    printf 'cloudflare-warp: %s\n' "${package_version:-not installed}"
    printf '\n=== warp-cli ===\n'
    warp_cli status 2>&1 || true
    printf '\n=== trace ===\n'
    print_trace 4 IPv4
    print_trace 6 IPv6
    printf '\n=== protection ===\n'
    printf 'route-guard: %s\n' "$(systemctl is-active "${ROUTE_UNIT}" 2>/dev/null || true)"
    printf 'watchdog:    %s\n' "$(systemctl is-active "${WATCHDOG_TIMER}" 2>/dev/null || true)"
    printf '%s:      %s\n' "${MANAGED_SERVICE}" "$(systemctl is-active "${MANAGED_SERVICE}.service" 2>/dev/null || true)"
    if [[ -r "${ROUTE_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${ROUTE_ENV}"
        ip -4 rule show | awk -v key="${RULE_PRIORITY}:" '$1 == key'
        ip -6 rule show | awk -v key="${RULE_PRIORITY}:" '$1 == key'
    fi
}

connect_warp() {
    require_root connect
    require_supported_system
    load_settings
    validate_settings
    [[ -x "${ROUTE_GUARD}" && -r "${ROUTE_ENV}" ]] || die "尚未安装，请先运行 ./warp.sh install。"
    write_settings

    configure_warp
    warp_cli connect
    enable_watchdog
    if wait_for_warp; then
        recover_managed_service
        log "WARP 已连接。"
        do_status
    else
        protect_managed_service
        die "WARP 在 60 秒内未通过检查；定时器会继续尝试恢复。"
    fi
}

repair_warp() {
    require_root repair
    require_supported_system
    [[ -x "${ROUTE_GUARD}" && -r "${SETTINGS_ENV}" ]] || die "尚未安装，请先运行 ./warp.sh install。"
    load_settings
    validate_settings
    write_settings

    systemctl restart "${ROUTE_UNIT}"
    systemctl restart "${WARP_SERVICE}"
    sleep 3
    configure_warp
    warp_cli connect
    enable_watchdog
    if wait_for_warp; then
        recover_managed_service
        log "修复完成，WARP 已恢复。"
        do_status
    else
        protect_managed_service
        die "修复后仍未通过 WARP 检查。请运行 ./warp.sh logs 查看记录。"
    fi
}

disconnect_warp() {
    require_root disconnect
    load_settings
    validate_settings
    confirm "断开后将停止自动恢复；在 fail-closed 模式下也会停止 ${MANAGED_SERVICE}。"
    systemctl disable --now "${WATCHDOG_TIMER}" 2>/dev/null || true
    protect_managed_service
    warp_cli disconnect || true
    log "WARP 已断开。运行 ./warp.sh connect 可恢复。"
}

update_warp() {
    require_root update
    require_supported_system
    load_settings
    validate_settings
    write_settings
    install_dependencies
    install_cloudflare_client
    repair_warp
}

remove_route_rules() {
    [[ -r "${ROUTE_ENV}" ]] || return 0
    # shellcheck disable=SC1090
    source "${ROUTE_ENV}"
    if [[ -n "${IPV4_SOURCE:-}" ]]; then
        ip -4 rule del pref "${RULE_PRIORITY}" from "${IPV4_SOURCE}/32" lookup main 2>/dev/null || true
    fi
    if [[ -n "${IPV6_SOURCE:-}" ]]; then
        ip -6 rule del pref "${RULE_PRIORITY}" from "${IPV6_SOURCE}/128" lookup main 2>/dev/null || true
    fi
}

uninstall_warp() {
    require_root uninstall
    load_settings
    validate_settings
    confirm "这会移除 Cloudflare WARP 和本脚本创建的服务。${MANAGED_SERVICE} 将保持停止，不会自动改走服务器原始出口。"

    systemctl disable --now "${WATCHDOG_TIMER}" 2>/dev/null || true
    protect_managed_service
    warp_cli disconnect >/dev/null 2>&1 || true
    warp_cli registration delete >/dev/null 2>&1 || true
    systemctl disable --now "${ROUTE_UNIT}" 2>/dev/null || true
    remove_route_rules

    rm -f "/etc/systemd/system/${WATCHDOG_TIMER}" \
        "/etc/systemd/system/${WATCHDOG_UNIT}" \
        "/etc/systemd/system/${ROUTE_UNIT}" \
        "${WATCHDOG}" "${ROUTE_GUARD}"
    rm -rf "${CONFIG_DIR}" "${STATE_DIR}"
    systemctl daemon-reload

    export DEBIAN_FRONTEND=noninteractive
    apt-get remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list \
        /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    log "卸载完成。${MANAGED_SERVICE} 未自动启动。"
}

show_logs() {
    require_root logs
    journalctl -u "${WARP_SERVICE}" -u "${WATCHDOG_UNIT}" --since "24 hours ago" --no-pager -n 200
}

do_install() {
    require_root install
    require_supported_system
    validate_settings
    refuse_legacy_install
    confirm "将安装 Cloudflare 官方 WARP 客户端并切换服务器出站路由。脚本会先创建 SSH 管理路由保护。"

    install_dependencies
    [[ -s "${ROUTE_ENV}" ]] || capture_management_route
    write_settings
    install_route_guard
    install_cloudflare_client
    install_watchdog
    configure_warp
    warp_cli connect
    enable_watchdog

    if wait_for_warp; then
        recover_managed_service
        log "安装完成。"
        do_status
    else
        protect_managed_service
        die "安装完成但 WARP 未通过检查；${MANAGED_SERVICE} 已按设置保护，定时器会继续重试。"
    fi
}

show_help() {
    cat <<EOF
senyz warp.sh ${SCRIPT_VERSION}

用法：
  ./warp.sh install [--yes]     首次安装（建议仅用于干净的 Debian 12/13）
  ./warp.sh status              查看 WARP、IPv4/IPv6、路由保护和 V2Ray 状态
  ./warp.sh repair              重启服务并重新连接
  ./warp.sh connect             连接并恢复自动健康检查
  ./warp.sh disconnect [--yes]  安全断开；默认同时保护性停止 V2Ray
  ./warp.sh update              从 Cloudflare 官方源更新并修复
  ./warp.sh logs                查看最近 24 小时日志
  ./warp.sh uninstall [--yes]   移除本脚本和 Cloudflare WARP
  ./warp.sh version             显示脚本版本

可选环境变量：
  MANAGED_SERVICE=v2ray         WARP 失效时需要停止的服务
  FAIL_CLOSED=1                 1=失效保护（默认），0=不停止代理服务
  WARP_PROTOCOL=MASQUE          MASQUE（默认）或 WireGuard
  CLOUDFLARE_WARP_VERSION=...   安装官方仓库中的指定版本
EOF
}

main() {
    local command="${1:-help}"
    shift || true

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --yes) ASSUME_YES=1 ;;
            *) die "未知参数：$1" ;;
        esac
        shift
    done

    case "${command}" in
        install) do_install ;;
        status) do_status ;;
        repair) repair_warp ;;
        connect) connect_warp ;;
        disconnect) disconnect_warp ;;
        update) update_warp ;;
        logs) show_logs ;;
        uninstall) uninstall_warp ;;
        version) printf '%s\n' "${SCRIPT_VERSION}" ;;
        help|-h|--help) show_help ;;
        *) show_help; die "未知命令：${command}" ;;
    esac
}

main "$@"
