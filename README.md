# server_proxy_setup

个人 Debian VPS 代理脚本。当前方向：**保留 V2Ray + VMess/WebSocket/TLS + Nginx，使用官方 WARP，修好证书自动续期。** 不需要 Zero Trust、Cloudflare API Key 或复杂菜单。

**当前精简版 4.0.0-alpha3 是试装候选，还没有在真实干净 VPS 上完成完整验收。不要在正在使用的代理服务器上叠加执行。** 历史脚本及其已知问题保留在 [`legacy/`](legacy/README.md)。

alpha1 已因终端输入缺陷撤回：正常 SSH 会话也可能报“需要交互 SSH 终端”。不要再使用旧提交 `12dbb25` 的安装命令；alpha2 修复此问题。它发生在域名输入前，本身不要求重装系统。已经装回旧方案的服务器先保持现状。详见[故障处理](docs/TROUBLESHOOTING.md)。

如果你选择主方案失败后再次重装 Debian，临时恢复原来的代理，使用[旧方案修正版](legacy/FIXED.md)。这是单独的无 WARP 备选；不要求先做快照或导出备份，不叠加到新版半成品上。

## 从哪里开始

本仓库只有一个新版入口：[`setup_script.sh`](setup_script.sh)。脚本从 GitHub 下载到 VPS 后用 Bash 执行，内含 Python 标准库逻辑，不需要 pip。

可以使用新的 VPS，也可以按你的选择在供应商面板重装原 VPS 为干净 Debian。先确认供应商控制台可以进入服务器、自己的 SSH 公钥可以登录，再开始安装。下载命令在干净 VPS 的 root SSH 会话中运行，不是在本地 Windows 中运行。

下面的命令只在**已选定的干净 Debian 13 amd64 测试 VPS** 中运行。整段复制到 root SSH 会话即可；先核对文件摘要并预检，通过后才进入安装：

```bash
(
set -euo pipefail
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
apt_wait update
apt_wait install -y ca-certificates curl python3
curl --proto '=https' --tlsv1.2 -fsSLo /root/setup_script.sh https://raw.githubusercontent.com/syubroken/server_proxy_setup/4f4932de45709d7c4375aa33508f6a65d4841a6e/setup_script.sh
printf '%s  %s\n' 'a5921a8bf67018634120301b08441351cafe5883faaaa324483c64ec98159fa8' '/root/setup_script.sh' | sha256sum -c -
bash /root/setup_script.sh check
bash /root/setup_script.sh
)
```

alpha3 修复安装锁等待与官方下载诊断：入口准备和脚本内部都自动等待 apt/dpkg 锁，最多 10 分钟；仅在锁竞争时重试，不删除锁或杀进程。命令较长是为了把等待逻辑一并带上，整段复制即可，不需要先执行旧方案的几条 apt 命令。

官方公开文件最多下载三次，传输故障会尝试 IPv4；TLS、403/404/429 或摘要错误立即停止并报告具体类别。先校验文件，再屏蔽服务、安装整套依赖。基础准备会安装/更新 python3、curl 和 ca-certificates；不需要 Cloudflare API 凭据。离线检查和真实 Debian 锁检查见 [验证记录](docs/VALIDATION.md)，不等于真实 VPS 全流程通过。

正常流程会依次询问代理域名、证书联系邮箱和 `TRIAL` 确认（按提示输入大写 TRIAL 并回车，表示继续试装）。切换 WARP 后按提示另开一次新的 SSH 登录，执行屏幕显示的 `confirm-ssh` 命令，原窗口会自动继续。不要关闭原窗口或复用原连接冒充新连接。服务器检查通过后才显示测试节点。

首次试装先选定测试机器和时间；你只需：

1. 在供应商面板装干净 Debian 13 amd64，使用自己的 SSH 公钥登录；私钥留在本地。
2. 为新 VPS 准备独立测试子域名：一个 DNS-only A 记录指向新机器，同名没有 AAAA；不要改现用节点的域名记录。供应商防火墙需允许 SSH 以及 TCP 80/443，TCP 80 后续也要保留用于续期。脚本不改 DNS 或供应商防火墙。
3. 运行本页的固定下载入口，输入域名、证书联系邮箱，并确认试装。安装器会声明 WARP/证书服务条款的使用。
4. 脚本提示时，从本地另开一次 SSH 登录确认仍能进服务器。这是一次额外连接检查，不要求始终保持窗口在前台。
5. 服务器检查通过才显示测试节点；随后用 v2rayN 或 Shadowrocket 导入验证。

## 自动完成什么

- 从官方来源安装固定版本 WARP 和 V2Ray；Nginx 使用 Debian 软件源。
- 普通个人模式 WARP 注册，无限重试已移除。遇到 429 停止，不自动删注册重建。
- 代理业务必须经 WARP；国内直连在客户端设置。WARP 未通过时不输出节点、不静默回退到 VPS 原始出口。
- Nginx 提供证书验证目录，acme.sh 自动续期，不靠停止 Nginx 腾出 80 端口；续期后核对 Nginx 实际提供的新证书。
- 保留当前 SSH 设置、准备超时恢复与重启保护。先保护业务出站再启动服务。

当前仅适配 systemd 完整虚拟机、原生公网 IPv4 SSH、单一 IPv4 默认路由、普通文件形式的 `/etc/resolv.conf`。其他环境会停止，不尝试强行改网络。

## 日常不用记一堆命令

安装后不需要每天登录，也不需要菜单操作。异常时先保留提示交给维护者，**不要先重装**。如需查看状态，只有这一条：

```bash
bash /opt/senyz-proxy-simple/setup_script.sh status
```

日常维护分为几件不同的事：

- **证书自动续期**：定时任务申请并部署新证书；acme.sh 软件暂不升级，不影响它按计划续期。续期仍可能失败，失败会记入服务器状态，需要排查，不能保证永远免维护。
- **Debian 安全更新自动安装**：包括 Debian 软件源提供的安全修复；不自动重启整机。需要重启时另行安排。
- **WARP、V2Ray、acme.sh 暂不自动升级软件版本**：升级前由维护者检查官方变更、兼容性和恢复办法，再给出具体步骤。你可以把这项工作交给我，不需要自己研究 Linux；但这不表示我已在后台持续监控更新，也不表示这些软件可以永远不更新。当前安装脚本不是升级器，不要靠重复运行安装命令来升级。
- **暂不发送服务器故障告警**：续期或健康检查异常会记在服务器内，目前不会主动发到 Gmail、Telegram 或手机。GitHub 的自动测试通知邮件不属于服务器告警。
- **暂不自动升级后退回旧版本**：目前没有“自动安装新版、失败再自动降级”的功能。这与已有的安装期间网络超时恢复是两回事；网络恢复也仍需在真机上验证。

先完成新 VPS 的真实验收，再按使用情况安排版本维护或添加通知，正常使用不需要每天登录管理。

## 报错时怎么做

保留当前 SSH 窗口和最后约 10 行输出，先查看[故障处理](docs/TROUBLESHOOTING.md)。不要重跑旧安装器、强制重签证书或反复删掉 WARP 注册。下面是**故障诊断入口，不是安装命令**；可用于已装旧方案或新版的服务器。它不重启、不安装、不改配置，不输出凭据，只显示简短状态并进行两次有超时限制的 Cloudflare HTTPS 检查：

```bash
curl --proto '=https' --tlsv1.2 -fsSLo /root/proxy-diagnose.sh https://raw.githubusercontent.com/syubroken/server_proxy_setup/4ed2ba22f84076846fb3539427fc7b03aab114fd/tools/diagnose.sh && \
printf '%s  %s\n' 'bb852732274cdce93e22017ff8eff3732936cf57a6700b1ccec03c0048b38941' '/root/proxy-diagnose.sh' | sha256sum -c - && \
bash /root/proxy-diagnose.sh
```

首次会把诊断脚本保存在 `/root/proxy-diagnose.sh`；以后即使 GitHub 不可达，也可以执行 `bash /root/proxy-diagnose.sh`。它不会修复故障，也不能凭主机 WARP trace 证明完整代理出口合格。将摘要与报错前后约 10 行交给维护者，再决定最小修复步骤。

新版不需要 Cloudflare API Key/Token。HTTP 证书验证不依赖这些凭据；把 Global API Key 写入 acme.sh 配置不能保证续期。如果此前暴露过 Global API Key，需要轮换该 Key，仅更换 API Token 不会撤销它。

## 当前不能承诺什么

自动检查不代替真实 WARP、SSH 断联回退、重启、续期和客户端测试。Cloudflare trace 通过也不保证 AI 网站地区或账号可用。官方客户端不能保证消除限流，WARP 不提供任选国家或固定出口保证。

原脚本和新版都只能在干净系统上选择其一。新装生成新 UUID，需要重新导入节点；不要分享节点、二维码或私钥。

维护者查看 [`docs/VALIDATION.md`](docs/VALIDATION.md)；旧设计的恢复位置见 [`docs/HISTORY.md`](docs/HISTORY.md)。普通使用只需阅读本页。
