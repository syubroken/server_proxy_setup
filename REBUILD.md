# 日常使用与重装入口

更新日期：2026-07-21

## 一、当前服务器

当前能稳定使用的服务器不需要因为 rc3 草稿而改动，也不要在现有旧部署上运行 `rebuild_server.sh` 或 `warp.sh install`。这两个脚本只用于下一次全新安装的 Debian 12/13。

曾经成功运行过的 `repair_current_server.sh` 是一次性修复，不要在没有新故障证据时重复执行。当前服务器是否继续使用、何时重装，仍由实际稳定性和你的安排决定。

## 二、平时怎样 SSH 登录

Windows 使用原来的私钥时：

```powershell
ssh -i "C:\Users\senyz\ssh_passwd\id_rsa.pem" root@<服务器IPv4>
```

以后改用自己生成的通用密钥时：

```powershell
ssh -i "$HOME\.ssh\vps_senyz_ed25519" root@<服务器IPv4>
```

macOS：

```bash
ssh -i ~/.ssh/vps_senyz_ed25519 root@<服务器IPv4>
```

正常 SSH 登录不需要先输入 `codex`，也不需要服务器密码。同一个 IPv4 重装后出现主机指纹变化时，只删除该 IPv4 的旧记录：

```bash
ssh-keygen -R <服务器IPv4>
```

不要清空整个 `known_hosts`。

## 三、当前服务器平时要做什么

网络正常时无需每天登录或主动重装。证书、WARP 或服务出现明确异常时，先保存只读检查输出，再决定修复或重装；不要因为一次 App 重连就直接改服务器。

当前旧部署可使用仓库中的 `服务器健康检查_只读.sh` 检查，不要把包含 UUID、客户端链接、私钥或账户令牌的内容发送到聊天或 GitHub。

## 四、下一次全新重装

完整操作只看 [`下一次纯净重装操作清单.md`](下一次纯净重装操作清单.md)。它已经包括：

- 通用 VPS 条件和自有 SSH 密钥；
- DNS、供应商防火墙和首次登录；
- 一条安装入口；
- WARP 未完成时停止 V2Ray；
- 路由切换自动回退；
- macOS/iPhone Shadowrocket 导入；
- 一条继续命令和一条只读验收命令。

不需要学习 GitHub 提交、分支或 SHA256，也不要求准备两个 SSH 窗口或提前学会供应商 Console 排错。

## 五、新流程失败时

只要末尾没有显示 `Result: PASS`，就不要导入或使用该节点。等待后重新 SSH 登录并执行：

```bash
senyz-finish-rebuild
```

WARP 切换时 SSH 断开，先等待至少 5 分钟让本机自动回退，再重新连接。仍不通时在供应商面板普通重启一次；控制台只作为最后的可选救援入口，屏幕内容可以交给 Codex 分析。

只有继续入口、自动回退和供应商重启都不能恢复时，才评估再次重装或使用 `legacy/setup_script_legacy.sh`。

## 六、新流程完成后的检查

rc3 成功安装后，每月或感觉异常时执行：

```bash
senyz-verify-rebuild --require-warp
```

最后显示 `Result: PASS` 即可。证书由 Certbot Webroot 与 systemd timer 自动续期；Debian 安全更新自动安装，但不会自动重启。

需要再次显示客户端信息时：

```bash
senyz-show-client
```

该命令只应在最终验收成功后使用。客户端信息属于凭据，不放入 GitHub、普通笔记或公开截图。

## 七、边界

新流程能做到的是：WARP 未验证时不让这套 V2Ray 节点悄悄使用 VPS 原始出口。它不能保证 WARP 出口 IP 固定、所谓“IP 纯净度”或任何第三方账号状态，也不能消除供应商、入站 IP、域名和本地网络故障。
