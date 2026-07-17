# 最简登录、修复与重装指南

更新日期：2026-07-18  
当前系统：DMIT Debian 13、V2Ray + WebSocket + TLS、Nginx、旧 `wgcf` WARP 全隧道

这份文件是日常使用入口。复杂背景请看本地《服务器与客户端完整指南》。

## 一、现在应该做什么

当前服务器可以正常使用，不需要再次重装。旧部署脚本把以下三个问题重新带了回来：

- 证书仍用 standalone 方式续期，以后可能被占用 80 端口的 Nginx 阻断。
- Nginx 仍允许 TLS 1.0/1.1。
- WebSocket 没有显式的一小时长连接超时。

使用下面的一次性修复脚本即可。它不修改 V2Ray UUID、客户端参数、SSH、UFW 或 WARP 路由。

2026-07-17 首次运行 1.1.0 时，本机 Webroot 探针在 Nginx reload 后立即得到一次 404，脚本因此在签发证书前安全停止。只读复查确认新 ACME 站点已加载、请求路由正确、目录权限正常；TLS 1.2/1.3 和 WebSocket 超时配置也已生效。1.1.1 增加了有上限的 reload 等待重试和失败诊断，请只按下面的固定版本再运行一次。

### 1. 保持两个 SSH 入口

先确认 DMIT 网页控制台可用，并保留当前 SSH 窗口。另开第二个 PowerShell 窗口，确认下面命令仍可登录：

```powershell
ssh -i "C:\Users\senyz\ssh_passwd\id_rsa.pem" root@154.26.183.116
```

### 2. 下载、校验并运行修复脚本

在服务器中执行：

```bash
REPAIR_COMMIT="bed7fc2feae85311a169b222a061fa463c10c705"
RAW="https://raw.githubusercontent.com/syubroken/server_proxy_setup"
curl -fsSLo repair_current_server.sh \
  "${RAW}/${REPAIR_COMMIT}/repair_current_server.sh"
echo "dd3c6ec23703fd71c87fad54615c7e99625118b2a0d20bec6a41ab0f1c89842e  repair_current_server.sh" \
  | sha256sum -c -
chmod 700 repair_current_server.sh
./repair_current_server.sh --domain senyz.top
```

校验必须显示：

```text
repair_current_server.sh: OK
```

脚本显示计划后输入大写 `YES`。成功时最后显示 `Repair complete`。

出现 `The local challenge passed on attempt 1`（或稍后的 attempt）都是正常结果。1.1.1 最多等待约 15 秒；如果仍失败，它会在退出前给出更有用的 Nginx 路由、Webroot 权限和响应头。

默认不会开启无人值守系统更新。如以后明确决定启用，再单独加入 `--enable-security-updates`；这次不要加，避免把证书修复和系统更新混在一起。

### 3. 把完整输出发回当前任务

失败时不要反复运行，也不要重装。保留 SSH 窗口，并查看：

```bash
cat /root/senyz-current-repair.log
```

脚本会在 `/root/senyz-current-repair-时间/` 自动备份旧配置。

## 二、修复后怎样确认

执行：

```bash
nginx -t
systemctl is-active nginx v2ray wg-quick@wgcf
/root/.acme.sh/acme.sh --info -d senyz.top --ecc
crontab -l | grep acme.sh
```

预期结果：

- `nginx -t` 成功。
- 三个服务均为 `active`。
- acme.sh 显示 Webroot 为 `/var/www/senyz-acme`，不再是 standalone。
- root 的 crontab 中有 acme.sh 定时检查。

证书不会每天重新签发。acme.sh 会定时检查，只有临近续期窗口才申请新证书，然后自动 reload Nginx。

## 三、Windows v2rayN 是否需要修改

**这次修复不需要修改 v2rayN。** 继续使用当前能正常访问外网的节点即可：

| 参数 | 值 |
|---|---|
| 地址 | `senyz.top` |
| 端口 | `443` |
| UUID | 当前服务器生成并已填入 v2rayN 的值 |
| 传输 | WebSocket |
| 路径 | `/ray` |
| Host | `senyz.top` |
| TLS | 开启 |
| SNI | `senyz.top` |
| 跳过证书验证 | 关闭 |

平时保持 v2rayN 的系统代理模式开启、TUN 关闭。只有确认某个原生 App 不遵守系统代理时，才单独评估 TUN；不要同时运行多个接管系统网络的软件。

本次任务中还出现过当前 V2Ray UUID 和 WARP 私钥。任务本身不是公开网页，这不等于凭据已被他人使用；但它们已经离开了原本只应存在的位置，稳妥做法仍是轮换。Cloudflare Global API 的轮换不会自动轮换这两项。

- 先完成并验收证书修复，不在同一次操作里换凭据。
- 再单独轮换 VMess UUID，并在 Windows、macOS 和 iPhone 的节点中只更新 UUID。
- 最后在独立维护窗口轮换旧 `wgcf` WARP 身份，或在下一次干净重建时生成新身份。不要只手工替换 `/etc/wireguard/wgcf.conf` 的 `PrivateKey`，否则 Cloudflare 端记录不匹配，会直接断开 WARP。新身份验证正常后还要注销旧注册。只生成新配置并不能证明旧私钥已经失效。

完整客户端步骤见 [`CLIENTS.md`](CLIENTS.md)。

## 四、“正在重新连接”与服务器重装

以前在 Windows 本地做的 Codex/ChatGPT App 传输设置保存在本机。只重装远程 Debian 不会删除这项本地设置，因此它可能继续有效。

但此前在 Debian 12 上做过的 Nginx 长连接修复属于服务器配置，已经被这次旧脚本重装覆盖。上面的修复脚本会重新补上。

本次任务没有出现重连是积极信号，但一次成功不能证明以后绝不会发生。再次出现时：

1. 等待 30 至 60 秒，看任务是否自动恢复。
2. 查看 <https://status.openai.com/>。
3. 完全退出并重新打开 App，创建一个真正的新任务。
4. 确认 v2rayN 当前节点和系统代理仍已开启。
5. 只有多个网站也同时失败时，才检查服务器；不要因为一次重连直接重装。

## 五、平时登录服务器

Windows PowerShell：

```powershell
ssh -i "C:\Users\senyz\ssh_passwd\id_rsa.pem" root@154.26.183.116
```

正常登录不需要先输入 `codex`，也不需要服务器密码。

只有在确认刚刚重装服务器后，遇到主机指纹变化才执行：

```powershell
ssh-keygen -R 154.26.183.116
```

然后重新登录。不要清空整个 `known_hosts`。

## 六、以后重装的简化入口

旧 `setup_script.sh` 已被安全兼容入口替代，原版只保存在 `legacy/` 中且已禁用。以后重装为干净 Debian 12/13 后，可以运行：

```bash
SETUP_COMMIT="4746450281322a9447e4dab73d7aa1313d378f19"
RAW="https://raw.githubusercontent.com/syubroken/server_proxy_setup"
curl -fsSLo setup_script.sh \
  "${RAW}/${SETUP_COMMIT}/setup_script.sh"
echo "ea068cd5837fea5eac87bd18898be01b5c21c49acba258abeac5a8ae983a841d  setup_script.sh" \
  | sha256sum -c -
chmod 700 setup_script.sh
./setup_script.sh
```

它会询问域名和证书通知邮箱，不再询问 Cloudflare API。随后下载并校验固定版本的 `rebuild_server.sh`，自动配置 Webroot、TLS 1.2/1.3、WebSocket 超时、V2Ray 和 WARP。

重要边界：完整重建脚本和仓库内官方 WARP 管理脚本仍未在真实 DMIT 干净实例上完整验收。当前稳定服务器不要为了测试它们而迁移 WARP；未来第一次使用时保留两个 SSH 窗口和 DMIT 控制台。

## 七、最少维护事项

每月或出现异常时执行一次：

```bash
systemctl --failed
systemctl is-active nginx v2ray wg-quick@wgcf ssh
nginx -t
df -h
/root/.acme.sh/acme.sh --info -d senyz.top --ecc
crontab -l | grep acme.sh
```

不要把以下内容放进 GitHub、普通 Markdown、截图或聊天：Cloudflare 密钥、SSH 私钥、VMess UUID/分享链接、WireGuard PrivateKey、账号 Cookie 或登录令牌。
