#!/usr/bin/env bash
# Export the known working legacy layout. This is NOT a restore/install script.
set -euo pipefail
set +x
umask 077

stop() { printf '停止：%s\n' "$1" >&2; exit 1; }
[[ $EUID == 0 && $(uname -s) == Linux ]] || stop '只在现有 Linux VPS 的 root 终端运行。'
[[ $# == 1 && $1 =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || stop '需要一个证书域名参数。'
domain=$1
[[ ${#domain} -le 253 && $domain == *.* && $domain != *..* ]] || stop '域名格式不正确。'
for command in tar gzip sha256sum openssl timeout systemctl dpkg-query dpkg flock nginx; do
    command -v "$command" >/dev/null || stop "缺少 $command；不自动安装。"
done
[[ $(dpkg --print-architecture) == amd64 ]] || stop '只审核了 Debian 13 amd64 的原方案。'
[[ -f /etc/os-release ]] || stop '缺少系统信息。'
grep -qx 'ID=debian' /etc/os-release || stop '仅支持 Debian。'
grep -Eq '^VERSION_ID="?13"?$' /etc/os-release || stop '仅支持 Debian 13。'
for path in /opt/senyz-proxy-simple /var/lib/senyz-proxy-simple /etc/senyz-proxy-simple; do
    [[ ! -e $path && ! -L $path ]] || stop '发现新版部署；此工具仅备份目前可用的旧方案。'
done
output=/root/legacy-proxy-recovery.tar.gz
[[ ! -e $output && ! -L $output && ! -e $output.sha256 && ! -L $output.sha256 ]] || stop '已有同名恢复包；不覆盖。请先下载核对旧包。'
exec 9>/run/lock/legacy-proxy-export.lock
flock -n 9 || stop '另一个备份正在运行。'

paths=(etc/nginx etc/v2ray usr/local/etc/v2ray usr/local/bin/v2ray root/.acme.sh)
for path in "${paths[@]}"; do
    [[ -e /$path && ! -L /$path ]] || stop '必需的原方案目录/程序缺失或使用链接，需要单独审核。'
done
[[ -x /usr/local/bin/v2ray ]] || stop 'V2Ray 程序不可执行。'
[[ -d /root/.acme.sh && -f /root/.acme.sh/account.conf ]] || stop '缺少原 acme.sh 配置。'
if [[ -e /usr/local/share/v2ray ]]; then
    [[ ! -L /usr/local/share/v2ray ]] || stop 'V2Ray 数据目录使用链接，需要单独审核。'
    paths+=(usr/local/share/v2ray)
fi
systemctl is-active --quiet nginx || stop 'Nginx 当前未运行；不能把故障状态标成可用备份。'
systemctl is-active --quiet v2ray || stop 'V2Ray 当前未运行；不能把故障状态标成可用备份。'
nginx -t >/dev/null 2>&1 || stop 'Nginx 配置检查失败。'
/usr/local/bin/v2ray test -config /usr/local/etc/v2ray/config.json >/dev/null 2>&1 || stop 'V2Ray 配置检查失败。'
openssl verify -purpose sslserver -verify_hostname "$domain" \
    -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted /etc/v2ray/v2ray.crt \
    /etc/v2ray/v2ray.crt >/dev/null 2>&1 || stop '现有证书链、域名或有效期检查失败。'
openssl x509 -in /etc/v2ray/v2ray.crt -checkend 1209600 -noout >/dev/null || stop '现有证书剩余不足 14 天，需先审核。'
disk_fingerprint=$(openssl x509 -in /etc/v2ray/v2ray.crt -noout -sha256 -fingerprint)
served_fingerprint=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$domain" </dev/null 2>/dev/null |
    openssl x509 -noout -sha256 -fingerprint) || stop '无法核对 Nginx 实际证书。'
[[ $disk_fingerprint == "$served_fingerprint" ]] || stop '磁盘证书与 Nginx 实际证书不一致。'

# Capture actual units and drop-ins, rather than assuming the installer paths.
for service in nginx v2ray; do
    fragment=$(systemctl show "$service" -p FragmentPath --value)
    dropins=$(systemctl show "$service" -p DropInPaths --value)
    read -r -a unit_paths <<< "$fragment $dropins"
    [[ ${#unit_paths[@]} -gt 0 ]] || stop '无法定位服务文件。'
    for path in "${unit_paths[@]}"; do
        case "$path" in
            /etc/systemd/system/*|/usr/lib/systemd/system/*|/lib/systemd/system/*) ;;
            *) stop '服务文件使用非标准路径，需要单独审核。' ;;
        esac
        [[ -f $path && ! -L $path ]] || stop '服务文件缺失或使用符号链接，需要单独审核。'
        paths+=("${path#/}")
    done
done

stage=$(mktemp -d /root/legacy-proxy-export.XXXXXXXX)
trap 'printf "停止：备份未完成；原服务未作更改。私密中间文件位于 %s，不能上传。\n" "$stage" >&2' ERR
mkdir "$stage/metadata"
cp /etc/os-release "$stage/metadata/os-release"
dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$stage/metadata/packages.tsv"
systemctl cat nginx v2ray > "$stage/metadata/service-definitions.txt"
systemctl show nginx v2ray -p Id -p User -p Group -p FragmentPath -p DropInPaths > "$stage/metadata/service-layout.txt"
if command -v crontab >/dev/null; then
    if ! crontab -l > "$stage/metadata/root-crontab.txt" 2> "$stage/metadata/cron-status.txt"; then
        [[ ! -s $stage/metadata/root-crontab.txt ]] || stop '读取 cron 失败，不能给出完整备份结果。'
    fi
fi
printf '%s\n' "$domain" > "$stage/metadata/domain.txt"
printf '%s\n' "$disk_fingerprint" > "$stage/metadata/certificate-fingerprint.txt"
printf '%s\n' "${paths[@]}" > "$stage/metadata/archive-paths.txt"
tar --create --gzip --acls --xattrs --numeric-owner --file "$stage/files.tar.gz" --directory=/ -- "${paths[@]}"
# Compare the archive to the current files. Concurrent edits must not pass silently.
tar --compare --gzip --file "$stage/files.tar.gz" --directory=/ > "$stage/metadata/compare.txt" 2>&1
cat > "$stage/metadata/README.txt" <<'NOTE'
PRIVATE: contains certificate private keys, proxy identities and Cloudflare credentials.
Not a full system image. No SSH private keys, host networking or firewall are restored.
Archive creation and file comparison are not a proven restore procedure.
Do not extract over a live/new-WARP system. Review paths, units, users and packages first.
Do not blindly restore the complete root crontab or overwrite network/SSH settings.
The saved DNS credentials may already be stale after Cloudflare key rotation.
NOTE
tar --create --gzip --file "$stage/package.tar.gz" --directory="$stage" files.tar.gz metadata
gzip -t "$stage/package.tar.gz"
tar --list --gzip --file "$stage/package.tar.gz" >/dev/null
# Hard link publishes without replacing an existing path. /root is the same filesystem.
ln "$stage/package.tar.gz" "$output"
sha256sum "$output" > "$output.sha256"
chmod 600 "$output" "$output.sha256"
trap - ERR
printf '%s\n' 'BACKUP_CREATED：文件已打包并与源文件比对；尚未验证恢复，不要据此立即重装。'
printf '%s\n' '包含私钥和凭据，只下载到你自己的电脑；不要上传 GitHub 或发到聊天。'
printf '恢复包：%s\n' "$output"
printf 'SHA-256：%s\n' "$(cut -d ' ' -f 1 "$output.sha256")"
printf '恢复审核信息（可反馈这些字段）：\n'
cat "$stage/metadata/service-layout.txt"
openssl x509 -in /etc/v2ray/v2ray.crt -noout -enddate
printf '%s\n' '原 Nginx、V2Ray、DNS、防火墙和证书均未修改；没有安装软件或调用证书机构。'
