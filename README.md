# server_proxy_setup

个人 Debian VPS 代理部署、维护和灾难恢复文件。

## 当前入口

- `下一次纯净重装操作清单.md`：面向实际操作的唯一重装主线，适用于常见 VPS；DMIT 只是示例。
- `setup_script.sh`：用户只运行这一个引导入口；自动下载并校验内部组件，连续完成基础部署、WARP 和最终验收。
- `rebuild_server.sh`：内部基础部署组件。配置 SSH、UFW、Nginx、Certbot 和 V2Ray；本机测试后保持 V2Ray 停止，等待 WARP。
- `warp.sh`：基于 Cloudflare 官方 Linux 客户端的 WARP 管理器；包含有限注册退避、管理路由、定时回退、watchdog 和 fail-closed。
- `verify_rebuild.sh`：只读验收，不打印 VMess UUID、WebSocket 路径、客户端链接或私钥。
- `REBUILD.md`：当前服务器的日常使用与下一次重装入口。
- `CLIENTS.md`：Windows、macOS 和 iPhone 客户端参考。
- `repair_current_server.sh`：曾用于旧部署的一次性修复，不是 rc3 新装流程的一部分。
- `legacy/setup_script_legacy.sh`：保留原内容和原执行行为的旧脚本，仅作灾难恢复备份。

## Clean Rebuild 3.0.0-rc3

rc3 把 WARP 作为客户端交付的必要条件：

1. 基础部署会生成并测试 V2Ray，但随后立即停止服务并安装启动门禁。
2. WARP 注册在 V2Ray 已停止的状态下进行，最多三次并采用递增等待，不做无限循环。
3. 路由切换前保存 VPS 原始管理路由，并启动四分钟本机回退计时器。
4. 只有 IPv4、IPv6 均验证为 WARP，才取消回退、恢复 V2Ray 并显示客户端链接。
5. WARP 未完成、脚本异常或路由验收失败时，V2Ray 保持停止，不静默降级到 VPS 原始出口。

正常流程不要求第二个 SSH 会话，也不依赖 Serial/VNC Console。供应商控制台仍可作为可选的最后救援入口。

## 通用前提

- 全新 Debian 12 或 13，使用 systemd；
- root 权限和用户自己控制的 root SSH 公钥；
- 独立公网 IPv4，至少 2 GiB 可用磁盘；
- TCP 22、80、443 可入站；
- 一个 DNS-only A 记录直接指向该 IPv4，且不发布同名 AAAA。

脚本不请求 Cloudflare Global API Key、API Token 或 DNS 凭据。证书使用 Certbot Webroot；WARP 使用 Cloudflare 官方 consumer registration，两者互不依赖。

## 状态边界

rc3 仍是 Draft，尚未在新的干净 VPS 上完成端到端实测。当前正在使用的稳定服务器、DNS、VPS 控制面板、`main` 和 `legacy/` 不因这份草稿自动改变。完成实测前不要仅为了测试而替换稳定服务器。

WARP 只能改变服务器出站路径，不能保证账号不受限制、出口 IP 固定或所谓“IP 纯净度”，也不能解决 VPS 入站 IP、供应商或域名故障。

不要再执行已经停止维护的 `bash <(curl -fsSL git.io/warp.sh)`。
