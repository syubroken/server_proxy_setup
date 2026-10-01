# server_proxy_setup

个人 Debian VPS 代理脚本。当前方向：**保留 V2Ray + VMess/WebSocket/TLS + Nginx，使用官方 WARP，修好证书自动续期。** 不需要 Zero Trust、Cloudflare API Key 或复杂菜单。

**当前精简版 4.0.0-alpha1 是试装候选，还没有在真实干净 VPS 上完成验收。不要在正在使用的代理服务器上叠加执行。** 原始脚本原样保存在 [`legacy/`](legacy/README.md)。

## 从哪里开始

本仓库只有一个新版入口：[`setup_script.sh`](setup_script.sh)。脚本从 GitHub 下载到 VPS 后用 Bash 执行，内含 Python 标准库逻辑，不需要 pip。

首次测试使用独立的新 VPS 和测试子域名，保留现有代理继续使用。先确认供应商控制台可以进入服务器、自己的 SSH 公钥可以登录，再开始安装。下载命令在新 VPS 的 root SSH 会话中运行，不是在本地 Windows 中运行。

下面是**选定干净测试 VPS 后**使用的试装入口，不是在当前已经运行代理的系统上执行。整段复制即可，固定版本与文件校验自动处理；没有通过校验就不会执行：

```bash
apt-get update && apt-get install -y ca-certificates curl && \
curl --proto '=https' --tlsv1.2 -fsSLo /root/setup_script.sh https://raw.githubusercontent.com/syubroken/server_proxy_setup/12dbb25fd0f640a6c49d35a7b4ac3b8f63629fb2/setup_script.sh && \
printf '%s  %s\n' '088fd756cf612733d0a704b522a29202dfa71481ea9428dc8dbd762dfa04155f' '/root/setup_script.sh' | sha256sum -c - && \
bash /root/setup_script.sh
```

这份固定脚本通过了[Debian 13 自动检查](https://github.com/syubroken/server_proxy_setup/actions/runs/36750337606)，仍不等于真实 VPS 已经通过。域名、邮箱和 `TRIAL` 确认在脚本运行后输入。它不要求你操作 Git 或理解版本号。

首次试装先选定测试机器和时间；你只需：

1. 在供应商面板装干净 Debian 13 amd64，使用自己的 SSH 公钥登录；私钥留在本地。
2. 为新 VPS 准备独立测试子域名：一个 DNS-only A 记录指向新机器，同名没有 AAAA；不要改现用节点的域名记录。供应商防火墙需允许 SSH 以及 TCP 80/443，TCP 80 后续也要保留用于续期。脚本不改 DNS 或供应商防火墙。
3. 运行本页的固定下载入口，输入域名、证书联系邮箱，并确认试装。安装器会声明 WARP/证书服务条款的使用。
4. 脚本提示时，从本地另开一次 SSH 登录确认仍能进服务器。这是一次额外连接检查，不要求始终保持窗口在前台。
5. 服务器检查通过才显示测试节点；随后用 v2rayN 或 Shadowrocket 导入验证。

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

## 当前不能承诺什么

自动检查不代替真实 WARP、SSH 断联回退、重启、续期和客户端测试。Cloudflare trace 通过也不保证 AI 网站地区或账号可用。官方客户端不能保证消除限流，WARP 不提供任选国家或固定出口保证。

原脚本和新版都只能在干净系统上选择其一。新装生成新 UUID，需要重新导入节点；不要分享节点、二维码或私钥。

维护者查看 [`docs/VALIDATION.md`](docs/VALIDATION.md)；旧设计的恢复位置见 [`docs/HISTORY.md`](docs/HISTORY.md)。普通使用只需阅读本页。
