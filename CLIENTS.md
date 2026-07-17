# Windows、macOS 与 iPhone 客户端设置

更新日期：2026-07-18

## 共同参数

所有设备使用同一组服务器参数，但各自保存节点配置：

| 项目 | 值 |
|---|---|
| 协议 | VMess |
| 地址 | `senyz.top` |
| 端口 | `443` |
| UUID | 当前服务器生成的私密值 |
| AlterId | `0` |
| 加密 | `auto` |
| 传输 | WebSocket |
| WebSocket 路径 | `/ray` |
| Host | `senyz.top` |
| TLS | 开启 |
| SNI/Server Name | `senyz.top` |
| 跳过证书验证 | 关闭 |

Webroot 续期、TLS 版本和 Nginx 超时都属于服务器端设置，不会改变这些客户端参数。

## Windows v2rayN

### 导入链接

全新重建脚本完成后，服务器会把链接保存在：

```bash
cat /root/senyz-client.txt
```

在 v2rayN 中使用“从剪贴板导入批量 URL”，然后选择新节点。不要把完整 `vmess://` 链接发送到聊天或公开保存，因为其中包含 UUID。

### 手工检查

打开节点编辑窗口，逐项核对共同参数。保存后：

1. 选择该节点。
2. 打开“设置系统代理”。
3. 保持 TUN 关闭作为日常默认。
4. 用浏览器打开普通外网和 AI 服务入口测试。

只有某个 Windows 原生 App 明确不走系统代理时，才测试 TUN。开启 TUN 前先退出其他 VPN、代理或网络加速软件，避免多个虚拟网卡同时接管路由。

## macOS

可以使用 macOS 版 v2rayN，也可以使用 Shadowrocket，二选一。

### Shadowrocket

1. 新增节点，类型选 VMess。
2. 填写共同参数。
3. 传输方式选 WebSocket，路径填 `/ray`，Host 填 `senyz.top`。
4. 开启 TLS，Server Name 填 `senyz.top`，关闭“跳过证书验证”。
5. 启动 Shadowrocket 的系统 VPN 后测试网页和 App。

不要同时让 v2rayN 和 Shadowrocket 接管 macOS 网络。首次切换客户端时应先完全退出另一个客户端。

## iPhone Shadowrocket

1. 点右上角 `+`，类型选择 VMess。
2. 填写地址、端口、UUID、AlterId 和加密方式。
3. 传输选择 WebSocket，路径 `/ray`，Host `senyz.top`。
4. 开启 TLS，SNI 填 `senyz.top`，关闭跳过证书验证。
5. 保存并选择节点，打开顶部连接开关。

iOS 显示 VPN 图标是正常现象；它表示 Shadowrocket 使用系统网络扩展，服务端仍然是 V2Ray 代理。

## 什么时候需要改客户端

以下服务器操作不需要改客户端：

- standalone 改成 Webroot 续期。
- TLS 只保留 1.2/1.3。
- WebSocket 超时改成 3600 秒。
- Nginx、V2Ray 或服务器正常重启。

以下情况需要改客户端：

- 轮换 VMess UUID：所有设备只更新 UUID。
- 域名、端口、路径或协议发生变化：更新对应参数。
- 服务器 IP 改变但仍使用同一域名：先更新 DNS，客户端通常仍使用域名，不需要改 IP。

如果 VMess UUID 曾出现在聊天、截图或分享链接中，建议在服务器端生成新 UUID 后，再把所有设备的节点 UUID 一次更新完成。只改客户端而不改服务器，或只改服务器而漏掉某台设备，都会使对应客户端无法连接。域名、端口、WebSocket 路径、Host、TLS 和 SNI 不需要随 UUID 一起改变。

## ChatGPT/Codex 出现重连

1. 先等待自动恢复。
2. 查看 <https://status.openai.com/>。
3. 确认代理客户端仍在运行且当前节点已选中。
4. 完全退出 App，再创建新任务。
5. 用浏览器访问同一服务，区分 App 问题与整个代理问题。
6. 多个网站都失败时，再登录服务器检查 Nginx、V2Ray、WARP 和证书。

一次重连不能证明服务器 IP、账号或模型发生变化。回答速度也不能单独验证后台实际推理强度。
