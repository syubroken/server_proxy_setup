# 旧方案修正版：仅作临时备选

主方案仍是仓库首页的官方 WARP 安装器。如果主方案失败，而你选择在供应商面板重新安装干净 Debian 后恢复旧代理，可以使用 `setup_script_fixed.sh`。

不要求先做快照、导出备份或逐项手动测试。原 `setup_script_legacy.sh` 保留原样；此修正版不安装 WARP、不增加菜单、管理面板或新的代理协议。

2026-10-05 更新：安装入口和脚本内部已增加软件锁等待。当前成功运行的服务器无需重跑安装；新版本用于下次干净安装或本修正版未完成时重试。

## 只修这些问题

- 采用你上次恢复成功后使用的 Cloudflare DNS 验证，并明确选择 Let's Encrypt，替换原 HTTP standalone 签发，避免继续依赖 HTTP 验证端口。会自动添加/删除证书验证 TXT，不修改 A/AAAA。
- 把 V2Ray 安装放在证书部署之前；证书更新只检查/重载 Nginx，安装最后启动 V2Ray，避免服务不存在或配置尚未完成时提前重启。
- 保存输入的 Global API Key 和邮箱用于 DNS 自动续期，确保 cron 运行；不再要求手工追加 account.conf。
- 失败立即停止，不在证书或服务失败后输出 Setup Complete。相同修正版重试保留 UUID，Nginx 使用一个配置文件，避免重复追加。
- 新装 Debian 如后台 apt/dpkg 正在运行，自动等待最多 10 分钟，释放后继续。涵盖软件索引锁与 dpkg 安装锁；其他错误立即保留原文并停止。保留已有软件包配置，避免升级询问覆盖 SSH 配置。
- 原 UFW 流程改为先放行当前 SSH，再启用防火墙，同时保留 80/443 规则。

协议仍为 VMess、WebSocket、路径 `/ray`、TLS 443、alterId 0，原生 VPS 出口。固定官方依赖下载并校验摘要，不需要你管理版本。

## 使用条件与操作

1. 在供应商面板重装干净 Debian 13 amd64。不能叠加在新版半成品或当前工作的旧代理上。
2. 原域名在你的 Cloudflare 账号管理下，DNS A 指向该 VPS；建议保持仅 DNS/灰云，清除不正确的同名 AAAA。供应商防火墙放行 SSH 与 TCP 443，正常也保留 80。DNS 签发本身不需要公网 80。
3. 不需要先运行旧脚本的 apt 命令，也不需要安装 dos2unix。在重装后的 root SSH 终端复制下面整段（开头的自动等待逻辑只需一起复制）。它先下载并校验固定版本，再用 Bash 执行：

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
apt_wait install -y ca-certificates curl
curl --proto '=https' --tlsv1.2 -fsSLo /root/setup_script_fixed.sh https://raw.githubusercontent.com/syubroken/server_proxy_setup/4f4932de45709d7c4375aa33508f6a65d4841a6e/legacy/setup_script_fixed.sh
printf '%s  %s\n' 'f62520b703449d0ac16e2a2fe4877e74a5142f88729aa155d1fd3be412e4ccae' '/root/setup_script_fixed.sh' | sha256sum -c -
bash /root/setup_script_fixed.sh
)
```

4. 按提示输入 Cloudflare 注册邮箱、域名、**最新 Global API Key**。Key 输入不显示字符，不是 API Token，不要发给别人。
5. 等待 Setup Complete，使用脚本最后给出的域名、UUID、443、WebSocket、`/ray` 和 TLS 参数配置客户端。新装 UUID 与以前不同，需要更新客户端。

系统软件准备和 DNS 验证可能等待几分钟。看到“后台正在使用 apt/dpkg，自动等待”时，保持窗口即可；不要另开窗口运行 apt。超过 10 分钟仍占锁时停止，不删除锁、杀进程或因此重装，稍后重跑同一脚本。

错误时只看最后的“停止：某步骤未完成”及其前几行。Key/邮箱填错、临时下载失败等原因修正后，可以在**本修正版留下的系统上**重新执行同一脚本；它保留自己生成的 UUID，不需要为了重试再装系统。CA 明确限流时按提示等待，不加 `--force` 连续申请。

重新执行只需 `bash /root/setup_script_fixed.sh`；不要在同一系统中交替运行原始旧脚本、新版 WARP 和这份修正版。

以后如果再次更换 Cloudflare Global API Key，服务器保存的续期凭据也需更新；不能只在 Cloudflare 更换后放任旧值。

## 验证边界

本地检查语法；Debian CI 用真实 Bash/PTY、真实 OpenSSL 证书验证及 Nginx 配置解析，模拟外部签发和服务，检查成功、重复执行、隐藏 Key、CA 失败、证书部署失败、V2Ray 未运行及损坏下载。2026-10-05 用户报告前版在等待后台任务结束后安装完成；本次增加等待逻辑，真实 Debian APT 锁在隔离目录验证。维护过程未使用用户 Key、未连接用户 VPS，自动续期仍未经过实际周期验收。脚本把配置、证书和服务检查放在安装流程中自动执行，不要求你另外跑测试清单。

[本次 Debian 13 检查结果](https://github.com/syubroken/server_proxy_setup/actions/runs/37284812420)：旧修正版流程和新增的真实软件安装锁检查均通过。
