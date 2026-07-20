# Windows、macOS 与 iPhone 客户端设置

更新日期：2026-07-21

## 先分清当前节点和新节点

当前旧服务器的客户端可以继续使用原配置。rc3 全新重装会生成新的 VMess UUID 和随机 WebSocket 路径，因此即使域名仍是 `senyz.top`，也必须导入脚本最后生成的新链接，不能沿用旧 `/ray` 路径或只改服务器 IP。

WARP 完全属于服务器端。Shadowrocket 和 v2rayN 不需要填写 WARP 参数；只有服务器最终显示 `Result: PASS` 后才导入节点。

## 推荐方式：直接导入

成功安装后，终端会显示一行 `vmess://...` 和二维码。以后需要重新显示：

```bash
senyz-show-client link
senyz-show-client qr
```

完整链接、二维码、UUID 和随机路径都是凭据，不发送到聊天、GitHub 或公开截图。

导入后的共同特征应为：

| 项目 | rc3 新节点 |
|---|---|
| 协议 | VMess |
| 地址 | 安装时输入的域名 |
| 端口 | `443` |
| UUID | 本次安装随机生成 |
| AlterId | `0` |
| 加密 | `auto` |
| 传输 | WebSocket |
| WebSocket 路径 | 本次安装随机生成，不是固定 `/ray` |
| Host | 与域名相同 |
| TLS | 开启 |
| SNI/Server Name | 与域名相同 |
| 跳过证书验证 | 关闭 |

## macOS Shadowrocket

1. 复制终端显示的完整 `vmess://...` 链接。
2. 在 Shadowrocket 中选择从剪贴板导入。
3. 选中新节点，路由选择“代理/Proxy”。
4. 开启连接并允许 macOS 添加系统 VPN 配置。
5. 先访问普通网站，再使用重要账号。

不要同时让 Shadowrocket、v2rayN、其他 VPN 或网络加速工具接管 macOS 网络。Shadowrocket 使用系统网络扩展是正常现象，不需要另行开启类似 Windows v2rayN 的 TUN 开关。

## iPhone Shadowrocket

1. 扫描终端二维码，或复制 `vmess://...` 后从剪贴板导入。
2. 选中新节点，路由选择“代理/Proxy”。
3. 允许 iOS 添加 VPN 配置并开启连接。
4. iOS 顶部出现 VPN 图标是正常现象。

macOS 和 iPhone 尽量使用同一节点，不在同一个账号会话中频繁切换线路。

## Windows v2rayN

Windows 暂时不使用时无需改动。以后恢复使用：

1. 复制完整 `vmess://...`。
2. 在 v2rayN 中选择“从剪贴板导入批量 URL”。
3. 选中新节点并开启系统代理。
4. 日常先保持 TUN 关闭。

只有明确确认某个 Windows 原生 App 不遵守系统代理时，才单独测试 TUN。开启前退出其他 VPN、代理或网络加速软件，避免多个虚拟网卡同时接管路由。TUN 不能修复服务器端 WARP、证书或账号问题。

## 什么时候需要重新导入

需要重新导入：

- 重新安装服务器，因为 UUID 和随机路径会变化；
- 更换域名、端口、协议或 TLS 名称；
- 主动轮换 VMess UUID。

通常不需要改客户端：

- 证书自动续期；
- Nginx、V2Ray 或服务器正常重启；
- 服务器 IPv4 改变，但域名、UUID、路径和其他配置均保持不变且 DNS 已更新。

## App 出现重连

1. 等待 30 至 60 秒观察是否自动恢复。
2. 确认 Shadowrocket/v2rayN 仍连接到预期节点。
3. 用浏览器测试多个普通网站，区分单个 App 与整个网络。
4. 查看对应服务的官方状态页。
5. 完全退出并重新打开 App。
6. 只有多个网站同时失败时，再运行服务器只读验收。

一次 App 重连通常不需要重装服务器，也不应同时切换 VPS、域名、WARP 和客户端模式。
