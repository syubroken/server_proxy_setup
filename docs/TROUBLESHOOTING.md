# 安装或使用失败时，先做什么

适用于当前精简试装版，也说明旧 legacy 方案的已知风险。先保留还能登录的 SSH 窗口。已经恢复联网的机器先保持原状，不执行整套重装脚本，不追加旧 WARP 安装命令，不因为一个错误就重新申请证书。

## 2026-10-05：WARP 安装提示和 ip 退出码 255

`Setting up cloudflare-warp ...` 表示包进入配置阶段。公钥 may require updating 是软件包提醒，不是已确认公钥失效；安装器已用校验后的官方公钥写入自己的 sps-cloudflare.gpg，软件源通过 signed-by 指向它。不要仅因提醒再执行另一套导入命令。

`warp-svc.service is masked` 和 `policy-rc.d returned 101` 是安装器暂时阻止包自启动的预期结果，避免管理路由和业务阻断规则准备好之前 WARP 改动网络。脚本在这些检查通过后才解除 mask 并启动 WARP。

真正失败的是 `检查/操作失败：ip，退出码 255`。旧输出没有具体子命令与 stderr，不能仅凭它断定哪条 ip 操作失败，更不能认定是用户按 Enter 的位置造成。

已在 Debian 13 隔离网络重现一个吻合的缺陷：alpha3 把 `ip route show` 文本拆词回填给 `ip route replace`；IPv6 RA 显示为 `expires 599sec`，设置命令却要求纯整数，因而返回 255。alpha4 改用 JSON 构造管理副本，并保留网关/onlink/指标及连接路由顺序；未知扩展在预检停止，ip 失败显示操作和脱敏详情。[复现与修复检查](https://github.com/syubroken/server_proxy_setup/actions/runs/37291093348) 已通过。尚未取得故障 VPS 原路由快照，不能把这一吻合的复现当成其唯一根因。

安全停止后新的 SSH 成功登录，说明该次管理入口仍可达，不能把它当作代理/WARP 成功。用户已重装并一次运行旧修正版成功，当前保持使用；不用为了 alpha4 又重装，也不用在其上叠加新版。

## 测试子域名和粘贴命令

一个 Cloudflare 区域可以管理多个不同名字。现有 `senyz.top` 保持原 A 记录，新服务器可另加 `warp-test.senyz.top`：类型 A、名称 warp-test、内容为测试 VPS IPv4、仅 DNS/灰云、TTL 自动。测试名称不配置其他 A/AAAA。它与原节点独立，不需要另买域名；不是给现用同名记录加第二个 IP。用户未决定测试服务器时，无需现在改 DNS。[Cloudflare 子域名说明](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-subdomain/)。

在正常 Bash SSH 终端里，Enter 提交整条已输入命令，不会只执行光标前面的文字。完整粘贴后光标在末尾 `)` 前也可以回车，先按右箭头或 End 到末尾再回车同样正确。外层括号是在子 shell 执行命令块，避免其中退出影响整个 SSH 会话，不表示试用次数或其他用户输入。

若终端只有 `>` 等续行提示而尚未开始执行，说明 Bash 还在等待完整命令；此时可 Ctrl+C 取消当前未执行输入，重新复制完整代码块，不复制 Markdown 的三反引号。不要把这个 Ctrl+C 建议用于正在运行的 apt、安装器或证书申请。

## 2026-10-05：安装锁与官方公钥下载

旧修正版的 `Could not get lock /var/lib/dpkg/lock-frontend ... held by process ... (apt-get)` 表示另一个软件安装任务正在运行。不同供应商镜像可能通过 cloud-init 或自动更新在首次启动时更新软件；日志只能确认 apt-get 占锁，不能确认由哪一种后台服务启动。用户后来手动 apt 操作后安装成功，并不能证明额外安装 gpg 或 dos2unix 才能修复；等待期间锁已释放是合理解释。

当前入口和两份安装器均自动等待锁，最多 10 分钟；`apt-get update` 的列表锁也单独涵盖，不只依赖对 update 未必生效的 DPkg 锁选项。软件包缺失、软件源故障或 dpkg 中断等其他问题不按锁问题循环重试。不要删除锁文件、强杀健康的安装进程或仅因占锁重装。

`warp-key` 是 Cloudflare 软件仓库的公开签名公钥，不是用户的 Global API Key。alpha2 下载失败时捕获了所有异常却只给出统一提示，因此无法从历史日志区分 DNS、网络超时、TLS 或 HTTP 错误。尚未到 WARP 注册/连接或证书签发阶段；不能归因于 WARP 账号、域名或 API Key。

2026-10-05 官方软件源页面仍列明 Debian 13/Trixie，仍提供相同公钥地址。维护电脑直连复查得到 TLS 主机名校验失败，而网页读取渠道能访问该公开公钥；这是不同来源的当前结果，不能据此认定用户此前 VPS 也遭遇相同 TLS 错误。保持证书验证，不采用 `curl -k`、HTTP 或第三方镜像。

alpha3 对公开 GET 使用有超时限制的 curl：网络临时错误最多三次，必要时尝试 IPv4；HTTP 403/404/429、TLS 校验、摘要不符立即停止。错误显示文件名、类别、curl 状态与尝试次数，不输出密钥。下载安排在屏蔽服务和安装整套依赖之前；失败仍可能留下本项目准备状态，但无需因此重装。软件包安装锁同样自动等待。

这不能保证外部网站永远可达。旧 alpha2 半成品不可直接用 alpha3 `resume`，跨版本迁移需核对状态；用户此次已重装为成功的旧修正版，应保留现状。alpha3 面向下一台干净测试机；其自身下载失败时，网络恢复后重跑同一固定版本可继续。

可短期使用另一台 Debian 13 amd64 完整虚拟机验证主方案，使用独立测试子域名。测试供应商不限定；一次仅测试下载与安装、WARP/SSH、代理与证书、恢复等阶段，操作交由维护者完成。新机器不保证绕过 Cloudflare 的限流或访问限制。

来源：[Cloudflare 官方软件源](https://pkg.cloudflareclient.com/)、[Debian dpkg FAQ](https://wiki.debian.org/Teams/Dpkg/FAQ)、[cloud-init 软件安装模块](https://cloudinit.readthedocs.io/en/latest/topics/modules.html#package-update-upgrade-install)。

## 2026-10-01 的终端报错

alpha1 在第一次询问域名前报告“需要交互 SSH 终端”，是脚本缺陷：Python 用 `r+` 打开不能定位的 `/dev/tty`，真实终端也会失败；异常又被错误归因为没有 SSH 终端。不是用户粘贴命令的错误。

alpha2 分别打开终端读、写通道；不能使用 Python 的标准输入读答案，因为该输入正在承载 Bash 内嵌的 Python 程序。新增 Linux PTY 测试覆盖旧问题重现、实际 Bash 入口、连续输入、EOF、Ctrl+C 和无终端的错误提示。

根据该次输出与代码顺序，失败发生在域名/邮箱/TRIAL 确认前，尚未创建部署状态或安装 WARP、证书和代理；外层命令已经更新了 curl 及相关库。这次错误本身无需重装。若后来已经安装旧代理，不能在同一系统叠加新版；新测试应另用干净机器。

## 最少需要保留的信息

1. 出错前后约 10 行，以及最后输入的命令。隐藏 Token、API Key、UUID、节点链接和私钥。
2. 失败发生在输入域名前、软件准备时、WARP 连接时还是证书签发时。
3. 当前是否还能通过新的 SSH 连接登录，以及是否已经运行过其他修复命令。

不要公开整个 V2Ray 配置、acme.sh `account.conf`、域名配置文件、Cloudflare 凭据或服务的完整环境变量。排障者需要更具体的日志时，先限定范围并检查内容。

仓库的 `tools/diagnose.sh` 只生成简短诊断：服务状态、配置校验结果、监听端口、证书过期日期和主机 WARP trace。它不安装、不重启、不申请证书、不修改防火墙，不输出 IP、域名、UUID、配置内容或私钥。它会发起两次有超时限制的 Cloudflare HTTPS 请求；主机 trace 不是完整代理链验收。固定下载与校验命令见仓库首页。

## 按情况处理

| 现象 | 下一步 |
| --- | --- |
| 下载失败或 SHA-256 校验失败 | 停止，不跳过校验；确认网络与仓库首页的固定版本命令 |
| alpha1 报“需要交互 SSH 终端” | 使用修复后的版本；该报错本身不要求重装。已装旧代理则另选干净测试机 |
| 新版检测到旧代理、防火墙或符号链接 resolv.conf | 保留输出，先审核冲突；不要删除文件绕过检查 |
| WARP 注册出现 429 | 停止，不删注册、不反复重试、不以重装绕过限流 |
| 新 SSH 确认失败或超时 | 保留原会话，等待/核对恢复结果；必要时从供应商控制台进入。不要先关闭 SSH |
| 证书签发失败 | 先查具体错误、DNS-only A/AAAA、TCP 80、系统时间和 CA 限流；不要盲目加 `--force` |
| Nginx/V2Ray 失败 | 先检查配置与证书文件的存在、权限、有效期，再决定是否重载或重启；不要全量重装 |
| 重启 V2Ray 后能联网 | 只证明代理链在当时可用，继续检查证书续期、WARP 出口与重启后的状态 |

## 旧脚本的已知问题

`legacy/setup_script_legacy.sh` 是历史文件，不是维护过的自动恢复工具。当前已发现：

- `ufw enable` 在显式放行 SSH 之前执行，脚本只添加 80/443，可能影响新 SSH 登录。
- 缺少失败即停止及关键步骤结果检查；证书申请或配置失败后仍可能输出 Setup Complete。
- `--installcert` 的 reload 命令在 V2Ray 安装前尝试 `restart v2ray`，存在服务尚不存在的执行顺序问题。
- 使用 `--standalone` 申请证书，签发时手动停 Nginx；自动续期却没有相应的停启处理，Nginx 占用 80 时可能冲突。这是续期风险，不能在没有日志时断言就是过去每次断联的根因。
- 询问 `CF_Key`，但使用的是 HTTP standalone 验证，没有调用 Cloudflare DNS API。Global API Key 与 API Token 不可混用；此流程及新版 Webroot 都不需要提交这些凭据。
- 直接执行远程最新安装脚本，未固定摘要；重复运行可能覆盖 UUID、追加重复的 Nginx 配置。
- 旧 TLS 模板仍包含 TLS 1.0/1.1；不应视为当前推荐配置。

因此不建议再次独立运行原始 legacy 文件碰运气。按用户原先要求保留其历史执行内容，本次不在该文件里暗中加入修复。需要旧方案恢复时，先根据具体机器状态准备最小修复；不要在已有配置上重跑安装器。

新版通过 Webroot 续期，不停止 Nginx 腾出 80；WARP 未通过不输出节点。但 alpha2 仍须在真实干净 VPS 验证注册、路由共存、掉线、重启、续期和客户端，并不因终端修复就成为生产验收版本。

## Cloudflare 凭据与当前恢复状态

本次用户提供的 ACME 日志先显示 `Standalone mode server`，持续 `Pending`，最后报告 `retryafter=86400 ... too large (> 600)`。这是 CA 要求等待 24 小时，而客户端不继续长时间等待；本次调用没有显示签发成功。不能仅凭这些行判断 CA 品牌、是否限流或 DNS/端口具体哪里有问题，也不能把“域名私钥文件已生成”当作证书成功。

后续 `--installcert`、Nginx 重载和 V2Ray 重启可能使已有证书/配置开始工作，但仍应检查证书有效期、签发者、实际服务的证书和续期验证方式。文件存在或非空不足以证明其是本次新签发且有效的证书。未启用日志时没有 `acme.sh.log` 本身不能说明成功或失败。

用户贴出的第三方建议中，把 `CF_Key`/`CF_Email` 追加到 `account.conf` 不能修复 HTTP standalone 的 CA 等待问题或续期时的 80 端口冲突。不建议照做或公开该文件；也不应在尚不清楚实际验证方式时自动删除其中内容。

已经更换 Token，不需要把新值发到聊天、脚本或 GitHub。如果此前暴露的是 Global API Key，仅轮换 API Token 不会撤销 Global API Key；应在 Cloudflare 中核对实际暴露的凭据类型，分别处理。

旧脚本本身不安装 WARP；没有运行旧 WARP 命令，且没有其他 WARP 安装证据时，不能把恢复联网当作 WARP 验收。国内直连是客户端分流问题，与这里的服务器出口不同。

## 已有 dns_cf 配置更换 Global API Key 后

若实际域名配置为 `Le_Webroot='dns_cf'`，说明已使用 Cloudflare DNS 验证；这种模式不需要为验证停止 Nginx 腾出 80 端口，但确实需要有效的 Cloudflare 凭据。不能继续套用原始 standalone 流程的结论。

现有证书不会因为 Cloudflare 凭据轮换立即失效。但如果续期仍使用已撤销的 Global API Key，以后 DNS 验证就会失败。Token 与 Global API Key 不可互相替代，也不要把新凭据贴到聊天、命令参数或公开配置中。

维护工具 `tools/refresh_cf_global_key.py` 仅适用于 root 默认的 `/root/.acme.sh`、现有 ECC 证书及 `dns_cf` 配置。它在终端隐藏读取新 Global API Key，先向 `https://api.cloudflare.com` 发起一次只读 GET 认证并确认区域可见，再保存权限受限的备份并同步配置。不执行 ACME、不写 DNS 记录、不重启服务；发现 Token、自定义配置路径、并发配置改动或正在运行的 acme.sh 时会停止。认证失败时不更新凭据。

固定工具已通过 [Linux 检查](https://github.com/syubroken/server_proxy_setup/actions/runs/36868132186)：9 项行为检查和 1 项真实 PTY 隐藏输入检查，以及现有安装器检查。测试未使用真实凭据或调用真实 Cloudflare API。

下面的修复命令需要替换最后两个参数为“证书域名”和“Cloudflare 区域名”；例如证书域名 `proxy.example.com` 属于区域 `example.com`。它会**修改服务器保存的续期凭据**，不是只读诊断；只在确认需要同步 Global API Key 时执行：

```bash
curl --proto '=https' --tlsv1.2 -fsSLo /root/refresh-cf-key.py https://raw.githubusercontent.com/syubroken/server_proxy_setup/16a526cd5f7657504bdc084fe91f06773bca59e1/tools/refresh_cf_global_key.py && \
printf '%s  %s\n' '48e63fb798eb092d9a53b9be1c7a412945239299d65e78ce4b91d4a715dc5859' '/root/refresh-cf-key.py' | sha256sum -c - && \
python3 /root/refresh-cf-key.py proxy.example.com example.com
```

邮箱留空会沿用已有值；只有确定之前保存正确时才留空。新 Key 输入不会回显，不会进入命令参数。工具不收集私钥或节点链接。只需保留最终 PASS/停止提示，不要上传保密备份。

PASS 仅确认凭据读取、文件更新和 Cloudflare 只读访问，不证明 DNS 编辑权限、证书部署 hook 或真实续期已通过。当前代理仍可使用时，不应为了核对凭据强制重签证书。
