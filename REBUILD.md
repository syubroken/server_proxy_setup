# 最简登录、修复与重装指南

这份文件是日常使用入口。较长的维护笔记只作为排查资料，不需要平时阅读。

## 一、现在只做两件事

### 1. 作废旧笔记里的 Cloudflare 令牌

旧的 `服务器配置脚本.md` 中仍保存着一段 Cloudflare API 令牌形式的字符串。无论它现在是否有效，都在 Cloudflare 后台将它撤销，并从笔记中删除。

新脚本不使用 Cloudflare API 令牌。DNS 仍在网页上手动修改，避免把长期凭据放进脚本或笔记。

### 2. 修复当前服务器的证书续期

先保持 DMIT 控制台可用，并另外打开第二个 SSH 窗口。然后在服务器中执行：

```bash
REPAIR_COMMIT="2265511e101091d9adcabf85cef3fb7db0fbf2cc"
curl -fsSLo repair_current_server.sh "https://raw.githubusercontent.com/syubroken/server_proxy_setup/${REPAIR_COMMIT}/repair_current_server.sh"
echo "b3e9215bae7ae34ec7924067e91e17d3459fed159a347657704b946d57509017  repair_current_server.sh" | sha256sum -c -
chmod 700 repair_current_server.sh
./repair_current_server.sh --domain senyz.top
```

校验必须显示 `repair_current_server.sh: OK`。脚本显示计划后，输入大写 `YES`。

它只做以下事情：

- 把证书续期改为不需要停止 Nginx 的 Webroot 方式，并立即签发一次证书验证流程。
- 停用 TLS 1.0/1.1。
- 把 WebSocket 代理超时延长到一小时。
- 开启 Debian 安全更新，但不自动重启。
- 自动备份旧配置并保存日志。

它不修改 V2Ray 配置、SSH 密钥、防火墙规则或当前 WARP 路由。成功时最后会显示 `Repair complete`。失败时保留当前 SSH 窗口，不要反复执行，把 `/root/senyz-current-repair.log` 的内容用于排查。

如果曾运行 `1.0.2` 并在 HTTP challenge 的 `404` 处停止，可以直接下载上面的新版重新执行。已经完成的软件安装和 Nginx 安全设置是可重复的，新版会继续完成证书步骤。

实机记录：`1.0.3` 已于 **2026-07-16** 在当前 DMIT Debian 12 服务器完整执行成功。HTTP 公网验证、ZeroSSL 签发、证书部署、Nginx 重载和 cron 安装均通过；当前证书有效期到 **2026-10-14 23:59:59 UTC**，acme.sh 根据 CA 的 ARI 信息选定下一次续期时间为 **2026-09-30 11:53:18 UTC**。

## 二、平时登录服务器

在 Windows PowerShell 中执行：

```powershell
ssh -i "C:\Users\senyz\ssh_passwd\id_rsa.pem" root@154.26.183.116
```

正常登录不需要先输入 `codex`，也不需要服务器密码。

只有在**确认刚刚重装了这台服务器**之后，遇到主机指纹变化才先执行：

```powershell
ssh-keygen -R 154.26.183.116
```

然后重新执行 SSH 登录命令。不要清空整个 `known_hosts`。

## 三、DMIT 重装时的密钥顺序

你的理解是正确的：先在 DMIT 选择 SSH 公钥，系统把公钥放进新服务器，然后才用本地对应的私钥登录。

最简单的做法：

1. 在 DMIT 的 `Services` -> `SSH Keys` 中保留与你的 `id_rsa.pem` 对应的公钥。
2. 重装时选择这个密钥和 Debian 13；如果当时没有 Debian 13，可以继续选 Debian 12。
3. 重装完成后，先在 PowerShell 删除该 IP 的旧主机指纹，再使用上面的 SSH 命令登录。
4. DMIT 默认禁止 root 密码远程登录；继续使用密钥即可，不要为了方便重新开放密码登录。

如果以后更换公钥，DMIT 的 `Access` -> `Change Key` 可以选择新密钥；必须从 DMIT 面板重启实例后才会应用。

## 四、重装后的完整自动部署

重装前确认 Cloudflare 中 `senyz.top` 的 A 记录指向服务器 IP，并保持“仅 DNS”，不要开启橙色云代理。DMIT 重装通常不改变 IP；IP 没变就不需要修改 DNS。

登录全新的 Debian 后执行：

```bash
REBUILD_COMMIT="9866347e62262caafbeb1a7d54582b6208b872b4"
curl -fsSLo rebuild_server.sh "https://raw.githubusercontent.com/syubroken/server_proxy_setup/${REBUILD_COMMIT}/rebuild_server.sh"
echo "5dc4122aa98822006f0a6e9c2ccf732f12dd79634e3e291b6ebe35cadb170224  rebuild_server.sh" | sha256sum -c -
chmod 700 rebuild_server.sh
./rebuild_server.sh --domain senyz.top --email "你的证书通知邮箱" --with-warp
```

把最后一行中的中文替换成真实邮箱。脚本显示计划后输入大写 `YES`，随后自动完成：

- 先放行当前 SSH 端口，再启用 UFW。
- 关闭 SSH 密码登录，保留 root 密钥登录。
- 安装 Nginx、Certbot、V2Ray 和安全更新。
- 检查 DNS 与 80 端口，签发证书并实际测试自动续期。
- 配置 VMess + WebSocket + TLS 和一小时长连接。
- 生成新的 UUID 和 `vmess://` 一键导入链接。
- 安装仓库中经过复核的官方 WARP 全隧道管理脚本。
- 在最终 WARP 出口下只读检查 ChatGPT、Claude 和 Google AI Studio 入口页的基本 HTTPS 可达性，不登录账号。

完成后客户端资料保存在：

```bash
cat /root/senyz-client.txt
```

复制其中的 `vmess://` 链接，可导入 v2rayN 或 Shadowrocket。日志保存在 `/root/senyz-rebuild.log`。

三项 AI 服务的网络检查结果保存在 `/root/senyz-ai-reachability.txt`。`2xx`、`3xx`、`401`、`403` 或 `429` 只表示已经到达服务端，不等于账号、地区或登录一定可用。

新脚本只允许在干净系统上运行。如果中途失败并且你不想排查，直接再次重装 Debian，然后从本节开头重新执行；不要在旧系统上强制覆盖。

## 五、当前已知边界

- 旧 `setup_script.sh` 保持不变，仅作为历史备份，不再作为推荐安装入口。
- 当前稳定服务器暂不迁移旧 `wgcf` WARP；只运行第一节的一次性修复。
- 当前修复脚本 `1.0.3` 已通过真实 DMIT Debian 12 验收。完整重建脚本 `2.0.3` 和新版 WARP 安装流程仍只完成静态检查；第一次重装使用时必须保留第二个 SSH 窗口和 DMIT 控制台。
- WARP、VPS 或代理协议都不能保证 AI 账号地区合规或绝对安全；本方案解决的是服务器安全、续期和网络可靠性。
