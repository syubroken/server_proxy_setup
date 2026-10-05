# server_proxy_setup

个人 Debian VPS 代理脚本。方向仍是 V2Ray + VMess/WebSocket/TLS + Nginx 和官方 WARP。

**2026-10-06：主方案暂停普通用户重装试用。** alpha4 在真实 VPS 上出现启动 WARP 后至少半小时无新输出，尚未查明是安装进程等待，还是 SSH 输出中断。此前自动检查通过不代表实际安装可用。

当前 `setup_script.sh` 是 **4.0.0-alpha5-dev 维护候选**，增加有限锁等待、分步记录和恢复路径保护，不代表已修复这次故障。这里暂时撤下主方案的一键安装命令，避免继续拿正在使用的 VPS 反复重装验证。

已通过旧修正版恢复联网的服务器继续保持使用；无需现在购买新 VPS、改域名或执行诊断命令。下次确实需要干净重装恢复时，使用已有的[旧方案修正版入口](legacy/FIXED.md)。该备用方案不安装 WARP，不能替代主方案出口验收；本轮未修改两份 legacy 脚本。

故障证据、改动与尚未验证的内容见[故障处理](docs/TROUBLESHOOTING.md)和[验证记录](docs/VALIDATION.md)。主方案恢复推荐前，需要在可保留现场的干净环境中完成真实 WARP/SSH 共存、出口与恢复检查，不能只看 CI 绿色。

下面是候选设计和维护说明，**不表示可以开始新一轮安装**。

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
