# WARP 出站管理说明

版本：3.0.0-rc3 草稿  
更新：2026-07-21

`warp.sh` 用于全新 Debian 12/13 VPS，基于 Cloudflare 官方 Linux 客户端建立全隧道 WARP。正常用户流程由 `setup_script.sh` 自动调用，不需要单独运行或维护本文件中的内部命令。

当前仍稳定运行旧 `wgcf` 的服务器不在 rc3 范围内。脚本检测到 `/etc/wireguard/wgcf.conf` 或 `wg-quick@wgcf` 时会停止，避免两套全局路由互相覆盖。

## 为什么使用全隧道

旧命令：

```bash
bash <(curl -fsSL git.io/warp.sh) s5
```

会建立本地 SOCKS5 代理，但 V2Ray 还需要单独配置出站和域名分流。长连接、认证资源和不断变化的域名容易遗漏；Cloudflare 文档也记录了本地代理模式的长请求限制。因此 rc3 不使用 SOCKS5 模式，而让该 V2Ray 节点的服务器出站统一经过 WARP。

仓库中的 `warp_proxy_probe.sh` 只检查已经存在的 `127.0.0.1:40000`，不会安装或切换 WARP。当前全隧道没有这个端口时报告不可用是正常结果。

## rc3 的保护顺序

1. 基础脚本完成 V2Ray 本机测试后立即停止 V2Ray，并安装启动门禁。
2. WARP 注册开始前再次确认 V2Ray 已停止。注册最多尝试三次，等待时间递增，不做无限循环。
3. 注册成功后记录 VPS 原始 IPv4/IPv6 管理路由，保护 SSH 和 HTTPS 回包。
4. 切换 WARP 路由前启动四分钟本机回退计时器。
5. 只有 Cloudflare trace 的 IPv4、IPv6 均为 `warp=on`，才取消回退、恢复 V2Ray 并记录完成状态。
6. WARP 后续失效时，watchdog 会先停止 V2Ray，再尝试恢复；恢复失败则继续保持停止。

这套逻辑不要求第二个 SSH 窗口或供应商 Console。Console 仍可作为自动回退和供应商普通重启都无效时的可选救援入口。

## 注册限流

Cloudflare 官方 `warp-cli registration new` 也可能返回 HTTP 429。它属于消费者 WARP 注册接口，与 Cloudflare DNS、Global API Key 或 API Token 无关。

rc3 在一次运行中最多做三次受控尝试。仍受限时：

- 不切换 WARP 路由；
- V2Ray 保持停止；
- 不显示客户端链接；
- 以后运行 `senyz-finish-rebuild` 从原位置继续。

脚本不能绕过 Cloudflare 限流，也不承诺固定等待时长。

## 路由切换回退

路由切换前会启动 `senyz-warp-safety-rollback.timer`。四分钟内没有完成双栈验收时，本机自动执行：

- 停止 V2Ray；
- 停止 watchdog；
- 断开并停止 `warp-svc`；
- 保留待恢复标记；
- 让下一次引导入口可以继续。

正常验收成功后该计时器会被取消。最终只读检查会同时验证回退器已安装且计时器已解除。

## 长期 fail-closed

安装完成后，V2Ray 的 systemd 启动前检查会验证 WARP 双栈状态，并与 `warp-svc` 绑定。watchdog 每约 30 秒检查一次；网络探针暂时无响应时采用有限容忍，明确检测到直连或持续失败时停止 V2Ray。

这是应用服务级的尽力而为保护，不是内核级、瞬时、可证明零泄漏的安全设备。它的目标是避免长时间静默降级，不应被描述成绝对保证。

## 内部维护命令

通常只需要用户运行：

```bash
senyz-finish-rebuild
senyz-verify-rebuild --require-warp
```

下面命令保留给 Codex 排错或明确维护窗口：

```bash
/root/senyz-warp.sh status
/root/senyz-warp.sh logs
/root/senyz-warp.sh repair
/root/senyz-warp.sh update
/root/senyz-warp.sh disconnect
/root/senyz-warp.sh connect
```

`disconnect`、`repair` 和 `update` 都会先停止 V2Ray。不要为了临时可用而删除启动门禁或关闭 fail-closed。

## 重要边界

- WARP 使用共享出口，不保证固定国家、固定 IP 或所谓“IP 纯净度”。
- WARP 不能保证任何账号不受限制，也不能改变第三方服务地区政策、付款资料、设备或登录历史。
- 管理路由依据安装时的公网地址和网卡生成。更换 VPS、IP 或网络结构后应在全新系统重新部署，不复制 `/etc/senyz-warp`。
- 默认协议是 MASQUE。只有在明确排查证实 MASQUE 不可用时，才由 Codex 单独评估 WireGuard；不要把切换协议与其他故障修复同时进行。
- 不再执行已停止维护的 `git.io/warp.sh`。`legacy/` 只保留旧流程的灾难恢复副本。

## 官方参考

- Cloudflare WARP Linux：<https://developers.cloudflare.com/warp-client/get-started/linux/>
- Cloudflare WARP 模式：<https://developers.cloudflare.com/warp-client/warp-modes/>
- Cloudflare Linux 软件源：<https://pkg.cloudflareclient.com/>
- Cloudflare 客户端模式：<https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/>
