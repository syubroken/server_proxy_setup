# 历史设计与恢复

2026-10-01，根据用户决定收敛为 Nginx + acme.sh + V2Ray + 官方个人 WARP，一个安装入口。

- 整理前 main：`d0551ec97d1d70919ea018e2d7804ef8a73ffa4d`。
- 旧 rc3 草稿：`2e701793291cffcdd2b626f58da9a9a6b20cd3c3`，位于 `codex/clean-rebuild-v3`，旧 PR #1 为历史设计。
- 原始恢复脚本继续保存在 `legacy/setup_script_legacy.sh`，没有改动。

根目录旧 `rebuild_server.sh`、`repair_current_server.sh`、`warp.sh`、`warp_proxy_probe.sh` 以及旧 CLIENTS/REBUILD/WARP 说明从当前树移除，以免出现多个互相冲突的入口。它们仍在 Git 历史中可恢复；未重写历史，也未删除旧分支。

本地曾有 Zero Trust + Caddy 候选、rc3 指南和过期 PDF，归入项目历史资料。它们的检查结果只适用于当时版本，不能作为精简版的实机证据。

日常入口以仓库首页为准，不执行历史文档中的安装命令。没有对当前 VPS、DNS、Cloudflare 或客户端作迁移。
