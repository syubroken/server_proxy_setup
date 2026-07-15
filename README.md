# server_proxy_setup

个人服务器代理配置与维护文件。

## 文件

- `setup_script.sh`：原有的 V2Ray、Nginx 和证书部署脚本。
- `warp.sh`：基于 Cloudflare 官方 Linux 客户端的 WARP 出站管理脚本。
- `WARP.md`：`warp.sh` 的适用范围、安装步骤、故障处理和风险边界。
- `warp_proxy_probe.sh`：只读检查已经存在的 WARP 本地 SOCKS5 代理，不负责安装或切换模式。

首次使用 WARP 前请先阅读 [WARP.md](WARP.md)。不要再执行旧的 `git.io/warp.sh` 短链接命令。

`warp.sh` 2.0.0 已完成静态校验，尚未在真实 Debian 服务器上执行。第一次使用应保留第二个 SSH 会话，并确认 DMIT 网页控制台可用。
