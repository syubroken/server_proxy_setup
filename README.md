# server_proxy_setup

个人服务器代理配置与维护文件。

## 文件

- `setup_script.sh`：兼容原来操作习惯的安全入口；下载并校验固定版本的 `rebuild_server.sh`。
- `legacy/setup_script_legacy.sh`：已禁用的旧脚本历史副本，只供查看，不能执行。
- `repair_current_server.sh`：当前 Debian 12/13 服务器的一次性修复，不改变 V2Ray/WARP 路由或 UUID。
- `rebuild_server.sh`：用于干净 Debian 12/13 的简化自动重建脚本。
- `REBUILD.md`：日常登录、当前修复和以后重装的一页式中文指南。
- `CLIENTS.md`：Windows、macOS 和 iPhone 客户端参数与重连处理。
- `warp.sh`：基于 Cloudflare 官方 Linux 客户端的 WARP 出站管理脚本。
- `WARP.md`：`warp.sh` 的适用范围、安装步骤、故障处理和风险边界。
- `warp_proxy_probe.sh`：只读检查已经存在的 WARP 本地 SOCKS5 代理，不负责安装或切换模式。

日常操作先阅读 [REBUILD.md](REBUILD.md)。首次使用 WARP 前再阅读 [WARP.md](WARP.md)。不要再执行旧的 `git.io/warp.sh` 短链接命令。

`repair_current_server.sh` 1.1.1 已针对 2026-07-18 的 Debian 13 重装结果更新，并分别通过本地 Bash 与该服务器 Debian Bash 的只读 `bash -n` 语法检查。1.1.1 会在 Nginx reload 后重试 Webroot 探针，避免新 worker 尚未接管时出现一次性 404；检测仍不通过时会打印路由和目录权限，但不会替换证书。默认只修 Webroot、TLS 和 WebSocket 超时；只有显式加入 `--enable-security-updates` 才会开启无人值守安全更新。

该脚本已于 2026-07-18 在当前 Debian 13 服务器上成功完成实机修复和只读终验。当前服务器不要重复运行；固定提交与校验值保留在 `REBUILD.md` 中，仅供审计或相同旧部署的恢复参考。

当前 Debian 13 服务器继续使用已经运行正常的旧 `wgcf` WARP；不要为了换脚本在现有服务器上运行仓库内 `warp.sh install`。

`warp.sh` 2.0.0 已完成静态校验，尚未在真实 Debian 服务器上执行。第一次使用应保留第二个 SSH 会话，并确认 DMIT 网页控制台可用。
