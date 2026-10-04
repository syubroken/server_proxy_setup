# 旧方案修正版：仅作临时备选

主方案仍是仓库首页的官方 WARP 安装器。如果主方案失败，而你选择在供应商面板重新安装干净 Debian 后恢复旧代理，可以使用 `setup_script_fixed.sh`。

不要求先做快照、导出备份或逐项手动测试。原 `setup_script_legacy.sh` 保留原样；此修正版不安装 WARP、不增加菜单、管理面板或新的代理协议。

## 只修这些问题

- 采用你上次恢复成功后使用的 Cloudflare DNS 验证，并明确选择 Let's Encrypt，替换原 HTTP standalone 签发，避免继续依赖 HTTP 验证端口。会自动添加/删除证书验证 TXT，不修改 A/AAAA。
- 把 V2Ray 安装放在证书部署之前；证书更新只检查/重载 Nginx，安装最后启动 V2Ray，避免服务不存在或配置尚未完成时提前重启。
- 保存输入的 Global API Key 和邮箱用于 DNS 自动续期，确保 cron 运行；不再要求手工追加 account.conf。
- 失败立即停止，不在证书或服务失败后输出 Setup Complete。相同修正版重试保留 UUID，Nginx 使用一个配置文件，避免重复追加。
- 原 UFW 流程改为先放行当前 SSH，再启用防火墙，同时保留 80/443 规则。

协议仍为 VMess、WebSocket、路径 `/ray`、TLS 443、alterId 0，原生 VPS 出口。固定官方依赖下载并校验摘要，不需要你管理版本。

## 使用条件与操作

1. 在供应商面板重装干净 Debian 13 amd64。不能叠加在新版半成品或当前工作的旧代理上。
2. 原域名在你的 Cloudflare 账号管理下，DNS A 指向该 VPS；建议保持仅 DNS/灰云，清除不正确的同名 AAAA。供应商防火墙放行 SSH 与 TCP 443，正常也保留 80。DNS 签发本身不需要公网 80。
3. 在重装后的 root SSH 终端复制下面整段。它先下载并校验固定版本，再用 Bash 执行：

```bash
apt-get update && apt-get install -y ca-certificates curl && \
curl --proto '=https' --tlsv1.2 -fsSLo /root/setup_script_fixed.sh https://raw.githubusercontent.com/syubroken/server_proxy_setup/3b8f10d88eb14775b99a74e6e576493e609daaa8/legacy/setup_script_fixed.sh && \
printf '%s  %s\n' '904b00f34bdbeb68e84ba05497c3e0a4c6a94e46af39d77e881b6f0ff56bef3b' '/root/setup_script_fixed.sh' | sha256sum -c - && \
bash /root/setup_script_fixed.sh
```

4. 按提示输入 Cloudflare 注册邮箱、域名、**最新 Global API Key**。Key 输入不显示字符，不是 API Token，不要发给别人。
5. 等待 Setup Complete，使用脚本最后给出的域名、UUID、443、WebSocket、`/ray` 和 TLS 参数配置客户端。新装 UUID 与以前不同，需要更新客户端。

DNS 验证可能等待几分钟。错误时只看最后的“停止：某步骤未完成”及其前几行。Key/邮箱填错、临时下载失败等原因修正后，可以在**本修正版留下的系统上**重新执行同一脚本；它保留自己生成的 UUID，不需要为了重试再装系统。CA 明确限流时按提示等待，不加 `--force` 连续申请。

重新执行只需 `bash /root/setup_script_fixed.sh`；不要在同一系统中交替运行原始旧脚本、新版 WARP 和这份修正版。

以后如果再次更换 Cloudflare Global API Key，服务器保存的续期凭据也需更新；不能只在 Cloudflare 更换后放任旧值。

## 验证边界

本地检查语法；Debian CI 用真实 Bash/PTY、真实 OpenSSL 证书验证及 Nginx 配置解析，模拟外部签发和服务，检查成功、重复执行、隐藏 Key、CA 失败、证书部署失败、V2Ray 未运行及损坏下载。没有使用你的 Key、没有连接你的 VPS，也不声称已完成真实 DNS 签发/续期验收。脚本把配置、证书和服务检查放在安装流程中自动执行，不要求你另外跑测试清单。
