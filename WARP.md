# WARP 出站管理脚本

本仓库的 `warp.sh` 用于在 Debian 12/13 服务器上安装和管理 Cloudflare 官方 WARP Linux 客户端。它替代以前的：

```bash
bash <(curl -fsSL git.io/warp.sh) d
```

新版不再执行短链接或第三方仓库中的脚本，也不会下载 `wgcf.sh`、`wireguard-go.sh` 等嵌套脚本。唯一的软件来源是 Cloudflare 官方 APT 仓库。

## 适用范围

- Debian 12（Bookworm）或 Debian 13（Trixie）
- amd64 或 arm64
- 使用 systemd 的服务器
- 服务器通过 V2Ray 提供代理服务，默认服务名为 `v2ray`
- 建议在下一次干净重装、完成 V2Ray 与 Nginx 基础配置后使用

如果脚本发现 `/etc/wireguard/wgcf.conf` 或 `wg-quick@wgcf`，会主动停止安装。这样做是为了避免在当前 SSH 会话里同时切换两套全局路由。当前运行稳定的旧服务器不必为了换脚本立即迁移。

## 它解决了什么

1. 使用 Cloudflare 仍在维护的官方 Linux 客户端，默认采用 MASQUE 全隧道。
2. 在连接 WARP 前记录服务器原始 IPv4/IPv6 管理地址，并建立源地址策略路由，降低 SSH 和入站 HTTPS 回包被送入 WARP 的风险。
3. 每两分钟检查一次 Cloudflare trace；失败时尝试重连。
4. 连续检查失败后默认停止 `v2ray`。这是一种尽力而为的 fail-closed 保护，目的是避免 WARP 断开后代理流量悄悄改走 DMIT 原始出口。
5. 提供安装、状态、修复、连接、断开、更新、日志和卸载命令。

## 为什么不用 WARP 本地代理模式

Cloudflare 文档记录了本地代理模式的请求超时限制。ChatGPT、Codex 和其他实时应用会使用长连接，因此本脚本使用全隧道模式，不把 V2Ray 接到 WARP 的本地 HTTP/SOCKS 代理端口。

## 首次安装

当前 `2.0.0` 版本已经通过 Bash 语法检查和代码复核，但还没有在真实 Debian 服务器上执行过。第一次实机使用时，请同时保留两个 SSH 窗口，并事先确认可以从 DMIT 网页控制台进入服务器。

先确认服务器是刚重装并已完成基础代理配置，然后下载已经核验的固定提交，而不是会继续变化的 `main`：

```bash
WARP_COMMIT="da777a2d70f55c29951fe27f12e02670fc4e2577"
curl -fsSLo warp.sh "https://raw.githubusercontent.com/syubroken/server_proxy_setup/${WARP_COMMIT}/warp.sh"
echo "d9dfe54c28e0fd73ddb70f7b3895a0b36799d1e2be1b084fe221cc84438b7772  warp.sh" | sha256sum -c -
chmod 700 warp.sh
./warp.sh install
```

校验结果必须显示 `warp.sh: OK`。脚本随后会显示即将发生的变化，输入大写 `YES` 后才会连接 WARP。安装结束前不要关闭原来的 SSH 窗口。

自动部署时可以使用：

```bash
./warp.sh install --yes
```

不要在不知道含义时使用 `--yes`。

## 日常命令

查看状态：

```bash
./warp.sh status
```

正常时重点看：

```text
IPv4: warp=on
IPv6: warp=on
route-guard: active
watchdog: active
v2ray: active
```

IPv6 显示 `unavailable` 不一定意味着 IPv4 代理不可用，但说明双栈没有完整建立，应先运行修复。

修复 WARP：

```bash
./warp.sh repair
```

查看最近日志：

```bash
./warp.sh logs
```

手动断开和恢复：

```bash
./warp.sh disconnect
./warp.sh connect
```

断开时，默认会同时停止 V2Ray，防止直接使用服务器出口。重新连接成功后，只有被本脚本保护性停止的 V2Ray 才会自动恢复；它不会擅自启动原本由你手动停止的服务。

更新官方客户端：

```bash
./warp.sh update
```

卸载：

```bash
./warp.sh uninstall
```

卸载完成后 V2Ray 保持停止。脚本不会自动把代理切回 DMIT 原始出口。

## 出现故障时

按下面顺序处理：

```bash
./warp.sh status
./warp.sh repair
./warp.sh status
```

仍未恢复时，保存以下输出，再决定是否重装：

```bash
./warp.sh logs > warp-logs.txt
systemctl status nginx v2ray warp-svc --no-pager > service-status.txt
```

日志可能包含服务器 IP、Cloudflare 出口 IP 和网络环境信息，不要直接公开发布。

## 重要边界

- WARP 不是匿名工具，也不保证固定国家、固定出口 IP 或 AI 账号绝对安全。
- AI 服务可能综合账号注册地区、付款资料、登录历史、设备、出口信誉和位置变化等信号。WARP 只能改变其中一部分网络出口特征。
- 健康检查每两分钟运行一次，因此 fail-closed 不是内核级、瞬时且绝对无泄漏的开关。它比旧脚本只有“服务 active”检查更可靠，但不能作绝对保证。
- SSH 路由保护依赖安装时记录的公网地址和网卡。更换服务器 IP、网卡或网络结构后，应在干净环境重新安装，而不是复制 `/etc/senyz-warp`。
- MASQUE 是默认协议。只有在确认 MASQUE 无法连接时，才临时尝试：

```bash
WARP_PROTOCOL=WireGuard ./warp.sh repair
```

成功后设置会保存到 `/etc/senyz-warp/settings.env`。

## 官方参考

- Cloudflare WARP Linux：<https://developers.cloudflare.com/warp-client/get-started/linux/>
- Cloudflare WARP 模式：<https://developers.cloudflare.com/warp-client/warp-modes/>
- Cloudflare 客户端模式与本地代理限制：<https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/>
- Cloudflare Linux 软件源：<https://pkg.cloudflareclient.com/>

脚本版本：`2.0.0`（2026-07-15）
