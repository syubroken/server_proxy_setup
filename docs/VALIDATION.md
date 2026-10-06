# 精简版验证边界

当前版本 4.0.0-alpha6-dev，2026-10-07（北京时间）。专用测试机进入客户端试用；仍不等于可推荐正式服务器重装。


## alpha6-dev 专用 Vultr 实机记录

脚本 SHA-256：`b510d7fe17d7b1b7c51ea26cd6c3504f317cfd89db9db7fe490a19c8906b3b1d`。Debian 13 amd64，官方 WARP 2026.7.1377.0 / MASQUE，V2Ray 5.53.0。使用测试子域名；现用服务器、正式域名记录和用户客户端未修改。测试时间跨 UTC 10 月 6 日与北京时间 10 月 7 日。

| 验证项目 | 结果与边界 |
| --- | --- |
| WARP 注册和连接 | 官方客户端成功注册一次；没有删除注册重试。IPv4、IPv6 业务 trace 均为 WARP on |
| 管理入口 | 原配置现场复现新 SSH 超时；独立定时救援成功恢复，无需重装。官方全地址分流排除 + 业务 UID 路由修正后，新 SSH 多次通过 |
| VMess/WSS/TLS + DNS | 服务器完整链通过 IPv4、IPv6 和域名请求；临时探针保留证书验证 |
| Windows 公网探针 | 独立 V2Ray core 5.53.0，域名/IPv4/IPv6 均 WARP on、当时地区 US；Google 和 YouTube generate_204 返回 204。未改 v2rayN，也不等同于完整网站/视频/AI 使用 |
| 真实 WARP 断开 | 业务 IPv4、IPv6、显式绑定原生源地址的请求均失败；root 原生联网仍成功，没有原生业务回退 |
| 重新连接 | 首次发现业务路由随隧道接口消失。修正后由真实健康定时器在 28.9 秒内恢复完整链，没有手动补路由；持续失败三次仍停止代理、进入 needs-repair |
| 正常重启 | 首次暴露 DHCP 就绪时序问题；加入有时限的地址/默认路由等待后，第二次实际重启通过。新 boot ID、新 SSH、服务、双栈及完整链均核对；无需人工恢复 |
| 证书 | 测试 CA、正式签发通过；测试子域名仅做一次主动正式续期，序列号发生变化，Nginx 实际提供新证书，正常续期动作也通过。没有靠重复强制签发试错 |
| 防火墙 | 保留 Vultr 镜像自带 UFW；只添加 80/443。最终脚本识别此种配置，未知防火墙继续拒绝 |
| 最终脚本全新安装 | **尚未完成**。初始干净镜像使用了经审核的 UFW 预检夹具，后续为现场迁移和真实 repair 流程；不得写成最终 alpha6 原样一键安装成功 |
| 用户实际客户端/长期运行 | **尚未完成**。v2rayN 界面、Shadowrocket、AI 登录/流式响应、空闲恢复和长期自然续期仍需验证 |

本机自动测试：Windows 87 项中 67 项执行通过、20 项 Linux 专用检查跳过。测试 VPS 上 5 项新回归与隔离网络命名空间路由检查通过；后者重现 WARP 选择更早规则优先级及原生/业务分离。完整干净 Debian 13 检查由本次 PR 的 CI 执行，结果以具体 run 为准。已装 WARP 的 VPS 不适合直接运行要求干净文件系统的旧安装器测试；未为测试删除实际 WARP 文件。

每次普通安装/repair 仍将真实断线、重启、续期和客户端字段初始化为 false。此专用测试机依据实际记录单独标记前三项 true，`real_clients` 保持 false；不会由自动安装器普遍宣称已完成这些演练。

尚需补充最终脚本原样干净安装、未提交/安全停止状态重启、IPv6 单独故障和既有长连接实测。此前模拟检查不是这些场景的实机证据。

alpha1 已在用户真实 VPS 上暴露首次终端输入失败；此前 35 项测试没有覆盖真实控制终端，不能用当时 CI 通过否认该缺陷。alpha2 修复 `/dev/tty` 读写方式，增加 6 项 Linux PTY 测试（包括实际 Bash/内嵌 Python 入口）。

[alpha2 固定代码提交 4ed2ba2 的 CI](https://github.com/syubroken/server_proxy_setup/actions/runs/36864449181) 已全部通过：35 项回归、6 项 Linux PTY 测试、Bash/ShellCheck、Nginx/systemd 配置与隔离内核网络检查。PTY 中确实重现旧版 r+ 异常，并验证新入口、连续输入、取消和中断。没有执行真实 WARP 注册或真实 VPS 安装。

历史 alpha4 安装脚本 SHA-256：`72f97b6c6fb82e128e652ccc326d3777616a9adb67f4d8167d47164f61c8e28a`。只读诊断脚本 SHA-256：`bb852732274cdce93e22017ff8eff3732936cf57a6700b1ccec03c0048b38941`。诊断脚本已过 Bash/ShellCheck，不能代替真实服务器上的故障诊断结果。

## 历史 alpha5-dev 启动等待与诊断

历史 alpha5 脚本 SHA-256：`6e9dca6e309930705f7c8de5996586a26f726b0f958e5a0527b4f1cee6554342`。不提供新的普通用户安装入口。

新增 `tests/test_startup.py`，覆盖：真实子进程命令超时、失败阶段保存、进程更换后读取记录、诊断字段过滤、写日志失败、SSH 输出关闭，以及 Linux 真实跨进程锁竞争。锁测试对比旧阻塞 flock 与有限等待、锁释放后继续、异常后释放，以及 deadline 检查遇占锁退出后可重试。

代码提交 `616a7c8973d86e0b6d78fabca2a8cffc6808aa7d` 的 [Debian 13 CI](https://github.com/syubroken/server_proxy_setup/actions/runs/37342320101) 已通过：11 项新检查全部执行成功，包含 3 项真实 Linux 跨进程锁测试；既有 39 项安装器、凭据/旧修正版/安装锁/路由/PTY 检查，以及配置解析和隔离内核网络检查继续通过。官方公钥只读下载步骤也单独核对为成功。

systemd 检查解析服务与 drop-in，不运行真实服务管理器。没有注册 WARP、操作 VPS 或修改 DNS；不能用这些测试证明此次半小时无输出的根因已修复。

本轮未改动旧修正版和原始 legacy 脚本。旧修正版安装成功来自用户实际反馈；未来证书续期与长期稳定性仍不能由一次安装成功替代。

## alpha4 路由兼容性修复

固定代码提交：`df845c6b1c7cedcf75192808125b04259e69d51f`。主脚本摘要见上；旧修正版与原始 legacy 均未更改。

[Debian 13 CI](https://github.com/syubroken/server_proxy_setup/actions/runs/37291093348) 通过。真实独立网络命名空间先创建带有效期的 IPv6 RA 路由，按 alpha3 的方式回放显示文本，确实得到退出码 255 和 expires 参数解析错误。再调用新版实际 management_routes，验证 IPv4 DHCP、IPv6 RA、/32 onlink 网关、root 原生路由选择、重复执行、清理和保留 main 路由。新增 6 项单元测试，既有全部检查继续通过。

管理副本使用 JSON 构造，不回放 expires Nsec、linkdown 等显示字段。副本不设 RA 倒计时，开机/启动时按当前原生路由重建；原 main 表仍由内核/供应商管理。未知多路径或扩展属性在预检拒绝。此设计仍不保证运行过程中任意 DHCP/RA 网关变化可自动追踪；公网地址或供应商网络结构改变需另行审核。

这确认了一个能产生相同退出码的脚本缺陷，不能唯一归因用户已重装的故障机器；其旧输出未保留具体 ip 命令及 stderr。新报错显示操作和脱敏原因。用户已确认安全停止后新 SSH 登录成功；这只证明当时 SSH 可达，主方案尚未完整实机通过。

## alpha3 历史变更

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

## 完整验收清单（部分已由上述实机记录覆盖）

1. 选定干净测试 VPS，核对供应商控制台、公钥登录、系统时间和 DNS；不修改正在使用的机器。
2. 软件安装先于 WARP 连接；验证官方守护进程的首次启动行为、注册、MASQUE、双栈出口及新的 SSH 登录。
3. 分别测试 WARP 中断、新请求与已有长连接、IPv6 单独故障；代理不能通过原生出口成功。SSH 应仍可恢复。
4. 测试未提交、正常运行和安全停止三种状态下重启；失败状态不能自动变成成功。
5. 实际走一次测试 CA 签发，再做正式证书检查；之后在测试环境演练续期和部署 hook，确认新证书被提供，不能只看磁盘文件日期。
6. v2rayN、iPhone Shadowrocket 分别测试导入、国内直连、AI 流式响应和空闲恢复；Apple Silicon Mac 到手后补测。

脚本只把服务器侧检查通过标为 `client-trial`。普通安装不自动把真实掉线、重启、续期或客户端字段勾为通过；专用测试机的人工验收记录见上。

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

- [Cloudflare 客户端路由与防火墙架构](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/client-architecture/)
- [Cloudflare 客户端模式：本地代理请求时限](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/)
- [V2Ray 5.53.0 DNS 实际代码](https://github.com/v2fly/v2ray-core/blob/v5.53.0/app/dns/dns.go)
- [官方 WARP Linux 使用](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [官方 WARP Debian 软件源](https://pkg.cloudflareclient.com/)
- [acme.sh 3.1.6](https://github.com/acmesh-official/acme.sh/releases/tag/3.1.6)
- [acme.sh 官方 Webroot 与证书部署说明](https://github.com/acmesh-official/acme.sh)
- [V2Ray 5.53.0](https://github.com/v2fly/v2ray-core/releases/tag/v5.53.0)

普通个人 WARP 的官方 Linux 使用路径不等于对这套第三方代理组合的可用性保证。其服务条款、供应商和目标网站规则仍适用；WARP 不能保证固定地区、固定 IP 或 AI 网站解锁。
