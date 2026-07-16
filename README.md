# server_proxy_setup

个人服务器代理配置与维护文件。

## 文件

- `setup_script.sh`：原有的 V2Ray、Nginx 和证书部署脚本。
- `repair_current_server.sh`：当前旧服务器的一次性安全修复，不改变 V2Ray/WARP 路由。
- `rebuild_server.sh`：用于干净 Debian 12/13 的简化自动重建脚本。
- `REBUILD.md`：日常登录、当前修复和以后重装的一页式中文指南。
- `warp.sh`：基于 Cloudflare 官方 Linux 客户端的 WARP 出站管理脚本。
- `WARP.md`：`warp.sh` 的适用范围、安装步骤、故障处理和风险边界。
- `warp_proxy_probe.sh`：只读检查已经存在的 WARP 本地 SOCKS5 代理，不负责安装或切换模式。

日常操作先阅读 [REBUILD.md](REBUILD.md)。首次使用 WARP 前再阅读 [WARP.md](WARP.md)。不要再执行旧的 `git.io/warp.sh` 短链接命令。

`repair_current_server.sh` 1.0.3 已于 2026-07-16 在当前 DMIT Debian 12 服务器完整执行成功。

`warp.sh` 2.0.0 已完成静态校验，尚未在真实 Debian 服务器上执行。第一次使用应保留第二个 SSH 会话，并确认 DMIT 网页控制台可用。
