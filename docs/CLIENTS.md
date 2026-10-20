# Windows 客户端迁移

更新：2026-10-20。用户已反馈正在使用 Clash Verge、TUN 已开启，目前没有问题，并自行修改/添加了几条规则。属于实际使用反馈，尚未独立核验当前配置和应用路径。下文保留迁移步骤供参考，用户无需重复迁移；后续以用户当前规则为准，不重新导入旧 YAML 覆盖改动。分项记录见 [VALIDATION.md](VALIDATION.md)。

现有服务器的 VMess + WebSocket + TLS 可由 Mihomo 使用，因此迁移到 Clash Verge Rev 不需要改 VPS、DNS 或证书。服务器 WARP、出口地区和网站账号限制不会因更换本地客户端自动改变。

## 准备配置中的规则来源

本项目提供的本地导入配置由维护者组合 Mihomo 规则，不是 Clash Verge Rev 无需配置就默认采用的分流策略。局域网部分显式列出常见私有、本地和链路地址范围；国内部分使用 `GEOSITE,cn,DIRECT` 引用 GeoSite 的 cn 域名集合，再用 `GEOIP,CN,DIRECT` 匹配 GeoIP 的中国 IP 数据。具体域名/IP 名单来自规则数据库，并非维护者逐个编写，也不能仅按网站语言判断。

规则按顺序匹配，最后 `MATCH,PROXY` 将其余请求送到所选代理。`DIRECT` 表示客户端直接通过本地网络访问，不经过 VPS/WARP。客户端负责执行这些规则，数据库版本和分类准确性影响结果；不保证所有国内网站、游戏或特殊域名都分类正确。这次仅解释已有配置，没有改变分流行为。

## 建议流程

1. 保留 v2rayN 和可用节点，不卸载。先通过现有网络下载 [Clash Verge Rev 官方稳定版](https://github.com/clash-verge-rev/clash-verge-rev/releases/latest)。本次核对为 v2.5.8；普通 Windows x64 电脑选择正常 x64 安装包，按安装器默认目录安装。仅在 WebView2 确有问题时考虑内置版本，不单独替换旧内核。
2. 准备本地 Clash/Mihomo YAML：复制现用节点的地址、端口、UUID、`alterId`、WS 路径和 Host、TLS/SNI。保留证书验证。不要将私人节点交给在线转换网站；`vmess://` 链接不应直接当作 Clash 订阅地址。
3. 正式切换时，关闭 v2rayN 的 TUN、清除系统代理，再从托盘退出 v2rayN。不要同时启用两个客户端的 TUN、代理接管或开机启动。
4. 在 Clash Verge Rev 的“订阅”页导入本地 YAML（新建本地配置或拖入文件），选中该配置；在“代理”页选择主节点和“规则”模式。先开启系统代理、暂不开 TUN，访问一个常用国外页面确认节点和 TLS/WS 参数可用。
5. 节点可用后，确认“设置 → 服务模式”已安装/运行，再开启 TUN；需要时按提示允许 Windows 管理员授权。配置采用局域网/国内直连、其余走选中代理，海外代理组不设置 `DIRECT` 失败回退。TUN 负责接管流量，规则决定直连还是代理，两者不同。
6. 确认浏览器访问、Scoop 实际下载、Git 访问和一个国内站点；在“连接”中检查目标请求命中的规则。确认正常后再开启 Clash Verge Rev 自启动，关闭 v2rayN 自启动。游戏或局域网异常时只针对实际进程/地址调整规则，不先改服务器。

系统代理与同一客户端的 TUN 可以并用；已设置显式代理的应用仍先访问本地端口。Clash Verge Rev 的混合端口以设置界面实际值为准，不能假设沿用 v2rayN 的 `10808`。若应用硬编码旧端口，需要同步调整；TUN 不能挽救一个已经无人监听的 localhost 代理端口。

本机 Scoop 已为 `proxy=none`，适合通过 TUN 使用。只有系统代理、TUN 尚未开启时，Scoop 仍按系统路由联网，不能拿这时的 Scoop 失败认定节点失败。不要为迁移盲目删除所有应用的代理设置。

## 最小核验与回退

启用 TUN 后，可在本机 PowerShell 做一个无显式 HTTP 代理的初步检查：

```powershell
curl.exe --noproxy "*" --connect-timeout 10 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace
```

预期代理路径下返回 `warp=on`。该结果需要结合客户端“连接”记录/实际 TUN 路由；单次 trace 不等于全机、IPv6/DNS 或所有应用验收。不要公开含公网 IP 的完整输出。

若迁移后无法联网，关闭 Clash Verge Rev 的 TUN和系统代理，从托盘退出，再启动 v2rayN，选择已验证的 sing-box 节点并恢复 TUN和系统代理。Scoop 保持 `none`，重新依靠已验证的 TUN。无需重装 VPS。

若两个客户端均退出后连国内网站也异常，检查 Windows“网络和 Internet → 代理”中是否残留指向已关闭程序的手动代理。只在确认残留时关闭；不要清空防火墙、批量删除网卡或重置整个系统网络。

## 仍可能遇到的问题

Mihomo 不使用此前 Xray 26.3.27 那组不兼容的 TUN 字段，但仍可能遇到服务权限、网卡/路由冲突、DNS、IPv6、休眠恢复或软件版本问题。VMess 能连接不代表所有 UDP 游戏和复杂网络场景都已验证。Clash Verge Rev 也不提供服务器 WARP 出口的固定 IP、住宅属性或 AI 账号可用性保证。

安装后看到绿色测速，只说明所测请求成功，不能代替实际应用和 TUN 验收。客户端升级、核心或规则变化后，应复核相关路径，并同步记录结果；不要把本次迁移指南写成已完成验收。

## 官方资料

- [v2.5.8 发布说明](https://github.com/clash-verge-rev/clash-verge-rev/releases/tag/v2.5.8)
- [下载与安装](https://www.clashverge.dev/install.html)
- [本地配置导入](https://www.clashverge.dev/guide/profile.html)
- [快速入门](https://www.clashverge.dev/guide/quickstart.html)
- [Windows 常见问题与服务模式](https://www.clashverge.dev/faq/windows.html)
- [Mihomo VMess](https://wiki.metacubex.one/config/proxies/vmess/) / [WebSocket 参数](https://wiki.metacubex.one/config/proxies/transport/)
