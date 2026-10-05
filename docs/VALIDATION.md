# 精简版验证边界

版本 4.0.0-alpha3，2026-10-05。这是试装候选，不是生产通过记录。

alpha1 已在用户真实 VPS 上暴露首次终端输入失败；此前 35 项测试没有覆盖真实控制终端，不能用当时 CI 通过否认该缺陷。alpha2 修复 `/dev/tty` 读写方式，增加 6 项 Linux PTY 测试（包括实际 Bash/内嵌 Python 入口）。

[alpha2 固定代码提交 4ed2ba2 的 CI](https://github.com/syubroken/server_proxy_setup/actions/runs/36864449181) 已全部通过：35 项回归、6 项 Linux PTY 测试、Bash/ShellCheck、Nginx/systemd 配置与隔离内核网络检查。PTY 中确实重现旧版 r+ 异常，并验证新入口、连续输入、取消和中断。没有执行真实 WARP 注册或真实 VPS 安装。

当前安装脚本 SHA-256：`a5921a8bf67018634120301b08441351cafe5883faaaa324483c64ec98159fa8`。只读诊断脚本 SHA-256：`bb852732274cdce93e22017ff8eff3732936cf57a6700b1ccec03c0048b38941`。诊断脚本已过 Bash/ShellCheck，不能代替真实服务器上的故障诊断结果。

## alpha3 本次变更

代码提交：`4f4932de45709d7c4375aa33508f6a65d4841a6e`。修复新版和备用脚本的安装锁等待、官方文件下载的错误分类及有限重试。旧修正版用户报告安装完成，WARP 主方案仍未实机通过；续期尚未实际演练。

39 项主安装器回归包含临时下载故障、IPv4 重试、TLS/HTTP 拒绝与限流停止、摘要不符停止、下载失败先于服务修改。新增 5 项 Debian 锁检查，使用隔离 APT 状态目录和真实 fcntl frontend/lists 锁，验证释放后继续、超时保留锁和非锁错误停止。原有 5 项旧修正版流程、6 项 PTY、凭据工具及配置/网络检查继续执行。

额外的官方公钥下载步骤为只读网络诊断，采用 continue-on-error；工作流整体绿色不能单独证明此步骤成功，必须查看该步骤结果。它不注册 WARP、不安装包，不证明 VPS 网络可达。

[固定代码的 Debian 13 CI](https://github.com/syubroken/server_proxy_setup/actions/runs/37284812420) 已全部通过。已逐项查询确认官方公钥只读下载步骤也成功，返回文件摘要与固定值一致；这不是仅凭工作流绿色推断的结果。

## 历史已完成与自动检查

- 35 项离线回归通过，包含注册限流、未知注册错误、拒绝自动重复注册、过期 SSH 证明、失败回退、取消标记、业务 DNS、禁止输出失败节点和续期失败状态。
- Bash 语法及 ShellCheck warning 级别通过。
- 官方 V2Ray 5.53.0 Windows 二进制对本版本生成的服务器和探针配置均返回 Configuration OK；未启动代理连接。
- [提交 12dbb25 的 GitHub Actions](https://github.com/syubroken/server_proxy_setup/actions/runs/36750337606) 已通过：Debian 13 容器内的回归、Nginx HTTP/TLS 与 systemd 配置校验，以及独立网络命名空间中的 nftables IPv4/IPv6 UID/接口约束。包含原生接口阻断、模拟隧道接口放行、接口改变后新连接和已建立 IPv4 连接阻断，以及管理流量正向对照。

内核检查使用模拟接口名，不注册 WARP、不连接 VPS，也不证明官方守护进程的规则能与本项目共存。模拟/单元检查不能被写成真实 VPS、证书续期或客户端成功。

## 固定来源

| 组件 | 基线 |
| --- | --- |
| 系统 | 干净 Debian 13 amd64、systemd |
| 官方 cloudflare-warp | 2026.7.1377.0，官方 trixie APT 仓库；2026-10-01 重新读取 Packages 核对 |
| V2Ray | 5.53.0，官方 GitHub Release；2026-10-01 核对最新正式发行信息 |
| Nginx | Debian 13 官方包，接受 Debian 安全更新 |
| acme.sh | 3.1.6，固定提交 `807da6498377ee5e0cf43a78091f46f12dc59a89`，定时任务直接调用固定脚本 |

安装器中固定 URL 和 SHA-256，下载摘要不符即停止。acme.sh 固定脚本摘要为 `c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7`。原始 legacy 摘要由 CI 检查。初始脚本也使用固定提交下载，不用 `curl | bash` 或短链接。

## 尚需真实测试

1. 选定干净测试 VPS，核对供应商控制台、公钥登录、系统时间和 DNS；不修改正在使用的机器。
2. 软件安装先于 WARP 连接；验证官方守护进程的首次启动行为、注册、MASQUE、双栈出口及新的 SSH 登录。
3. 分别测试 WARP 中断、新请求与已有长连接、IPv6 单独故障；代理不能通过原生出口成功。SSH 应仍可恢复。
4. 测试未提交、正常运行和安全停止三种状态下重启；失败状态不能自动变成成功。
5. 实际走一次测试 CA 签发，再做正式证书检查；之后在测试环境演练续期和部署 hook，确认新证书被提供，不能只看磁盘文件日期。
6. v2rayN、iPhone Shadowrocket 分别测试导入、国内直连、AI 流式响应和空闲恢复；Apple Silicon Mac 到手后补测。

脚本只把服务器侧检查通过标为 `client-trial`。真实掉线、重启、续期、客户端字段仍是 `false`；不会把未实测项目勾为通过。

## 维护实现

- 业务进程专用 UID；nftables 只替换本项目表。管理 root 流量与 SSH 原生地址回复走管理路由，不给业务 UID 加直接出口豁免。
- 业务 DNS 由 V2Ray 自身通过 WARP 访问固定受验证 DoH 端点，不退回系统解析。
- 只调用一次新的注册命令；保存已尝试标志。官方进程可能内部重试，不声称只有一个 HTTP 请求。发现 429 停止，不删身份重刷。
- 新 SSH 证明必须来自本次切换后的独立会话。超时/取消后持久标记阻止旧进程提交。
- 证书使用 Webroot；测试和生产 ACME 目录分开。每日 renewal timer 调用固定 acme.sh，再核对实际服务的证书及剩余时间。不更改客户端 TLS 验证。
- 不改 SSH 端口、登录用户或私钥；不需要 Cloudflare API 凭据。
- 外部告警、核心组件自动升级、自动重启和复杂菜单暂不加入。软件仍需维护，不能称为永久免维护。

故障维护者可用同一脚本的 `status`、`diagnostics`、`rescue`、`resume` 等内部动作；不要要求用户依次试一串命令。`resume --retry-registration` 仅在判断注册错误后明确使用，不能作为定时任务。

## 核对来源

- [官方 WARP Linux 使用](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [官方 WARP Debian 软件源](https://pkg.cloudflareclient.com/)
- [acme.sh 3.1.6](https://github.com/acmesh-official/acme.sh/releases/tag/3.1.6)
- [acme.sh 官方 Webroot 与证书部署说明](https://github.com/acmesh-official/acme.sh)
- [V2Ray 5.53.0](https://github.com/v2fly/v2ray-core/releases/tag/v5.53.0)

普通个人 WARP 的官方 Linux 使用路径不等于对这套第三方代理组合的可用性保证。其服务条款、供应商和目标网站规则仍适用；WARP 不能保证固定地区、固定 IP 或 AI 网站解锁。
