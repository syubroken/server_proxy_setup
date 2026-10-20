# server_proxy_setup

个人 Debian VPS 代理脚本：V2Ray + VMess/WebSocket/TLS + Nginx 和官方 WARP。

**验收记录更新于 2026-10-20。** Vultr 测试机的官方 WARP 双栈出口、独立 SSH、完整代理链、真实断线阻断/恢复、正常重启和一次实际证书续期已独立实测通过。10 月 7 日用户还确认：v2rayN 已导入并使用测试节点，Google、YouTube 可访问且速度符合预期；随后主服务器安装完成，并通过新节点继续对话。这两项用户反馈此前漏记在 GitHub，现已补齐。

当前 `setup_script.sh` 仍为 **4.0.0-alpha6-dev 维护候选**。主服务器全新安装及实际使用已有用户报告，但安装日志和脚本摘要未在该主机独立复核；主服务器自己的重启、WARP 断线及续期演练仍待验证，不能沿用 Vultr 的结果。现有主节点继续使用，Vultr 保留备用；补记录不要求重装，也不代表所有环境或长期运行均已验收。

10 月 20 日本机独立验证了 v2rayN 7.25.4 + sing-box 1.14.2 下 Scoop 经 TUN 下载：实际连接使用 TUN 地址、`warp=on`、下载文件摘要及 Git 访问通过。此结果只覆盖当时节点和测试路径；Shadowrocket、Clash Verge Rev、各 AI 站点登录/流式响应及完整 IPv6/DNS 检查仍未分别验收。详见[按主机和客户端区分的记录](docs/VALIDATION.md)及 [Windows 客户端迁移说明](docs/CLIENTS.md)。

这次确认并修正了 WARP 路由/防火墙影响管理入口、V2Ray 域名解析失败、重连后业务路由丢失，以及开机 DHCP 尚未就绪的问题。Vultr 自带的已识别 UFW 规则予以保留，只补充 TCP 80/443。详见[验证记录](docs/VALIDATION.md)和[故障处理](docs/TROUBLESHOOTING.md)。之前原故障机已重装，不能把此次发现当作其全部故障的唯一结论。

原始 legacy 和旧修正版脚本均未改变。确实需要干净重装恢复无 WARP 代理时，仍使用[旧方案修正版入口](legacy/FIXED.md)。它是独立备用，不叠加到新版系统。

## 自动完成什么

- 从官方来源安装固定版本 WARP 和 V2Ray；Nginx 使用 Debian 软件源。
- 普通个人模式 WARP 注册，无限重试已移除。遇到 429 停止，不自动删注册重建。
- 使用官方 WARP 分流允许系统管理原生联网，再按专用进程身份将代理业务送入 WARP；国内直连在客户端设置。WARP 未通过时不输出节点、不静默回退到 VPS 原始出口。
- Nginx 提供证书验证目录，acme.sh 自动续期，不靠停止 Nginx 腾出 80 端口；续期后核对 Nginx 实际提供的新证书。
- 保留当前 SSH 设置、准备超时恢复与重启保护。先保护业务出站再启动服务。

当前仅适配 Debian 13 amd64 的 systemd 完整虚拟机、原生公网 IPv4 SSH、单一 IPv4 默认路由、普通文件形式的 `/etc/resolv.conf`。可识别空防火墙或受支持的独立 UFW/nft 规则；保留原 SSH 放行范围，不清空未知防火墙。供应商面板防火墙仍需允许现用 SSH 端口和 TCP 80/443，服务器脚本不能替代面板设置。其他环境会停止，需另行审核。

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
- **暂不自动升级后退回旧版本**：目前没有“自动安装新版、失败再自动降级”的功能。这与已有的安装期间网络超时恢复是两回事；本次专用测试机已验证部分网络恢复场景，完整边界见验证记录。

用户已选择主节点日常使用、Vultr 节点备用。后续版本维护和主服务器的中断性验证另行安排；正常使用不需要每天登录管理。

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
