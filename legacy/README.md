# 旧版 setup_script.sh 说明

`setup_script_legacy.sh` 保留旧脚本原有的执行行为，不再含有后来添加的强制退出逻辑。它可以被下载并执行，但不代表推荐使用。

下载命令：

```bash
curl -fsSL -o setup_script.sh \
  https://raw.githubusercontent.com/syubroken/server_proxy_setup/main/legacy/setup_script_legacy.sh
bash setup_script.sh
```

## 已知问题

- 在放行 SSH 前启用 UFW，存在把当前 SSH 会话锁在服务器外的风险。
- 使用 acme.sh standalone 签发和续期，可能与占用 80 端口的 Nginx 冲突。
- Nginx 配置仍允许 TLS 1.0 和 TLS 1.1。
- 远程安装脚本没有固定提交版本或校验 SHA-256。
- 要求输入权限范围较大的 Cloudflare API 凭据。
- 缺少严格错误处理和完整的部署后验证，某一步失败后仍可能继续执行。
- 不包含当前讨论中的 WARP 配置；旧流程还依赖另一个已停止维护的外部脚本。

不要在当前稳定服务器上运行。若出于复现旧环境而使用，只应针对刚重装的服务器，并先确认 DMIT 控制台可用、SSH 端口已放行、Cloudflare 凭据已准备轮换。

当前建议入口仍是仓库根目录的 `setup_script.sh` 或固定版本的 `rebuild_server.sh`。
