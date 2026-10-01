#!/usr/bin/env python3
"""Refresh an existing acme.sh dns_cf Global API Key; never issue or renew.

Only for the default /root/.acme.sh home and an explicitly selected domain.
Credentials are entered on the VPS terminal, never supplied in arguments.
"""
import getpass
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


class Stop(Exception):
    pass


ASSIGNMENT = re.compile(r'^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$')
FIELDS = {'CF_Key', 'SAVED_CF_Key', 'CF_Token', 'SAVED_CF_Token',
          'CF_Email', 'SAVED_CF_Email', 'ACCOUNT_CONF_PATH', 'LE_CONFIG_HOME', 'Le_Webroot'}


def settings(text):
    result = {}
    for line in text.splitlines():
        match = ASSIGNMENT.fullmatch(line.strip())
        if not match or match[1] not in FIELDS:
            continue
        # Never source/eval a shell configuration, or expand command substitution.
        if '$' in match[2] or '`' in match[2]:
            raise Stop('发现动态凭据或自定义路径，停止；需要单独核对，不执行配置内容。')
        try:
            words = shlex.split(match[2], comments=True)
        except ValueError:
            raise Stop('相关配置项的引号不完整，停止；不会输出内容。') from None
        if len(words) > 1:
            raise Stop('相关配置项不是单个静态值，停止；不会执行或覆盖。')
        result[match[1]] = words[0] if words else ''
    return result


def replacement(text, values):
    lines = []
    for line in text.splitlines():
        match = ASSIGNMENT.fullmatch(line.strip())
        if not match or match[1] not in values:
            lines.append(line)
    # shlex.quote prevents both shell injection and broken email/key quoting.
    lines.extend(name + '=' + shlex.quote(value) for name, value in values.items())
    return '\n'.join(lines) + '\n'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def verify_cloudflare(email, key, zone):
    url = 'https://api.cloudflare.com/client/v4/zones?' + urllib.parse.urlencode({'name': zone})
    request = urllib.request.Request(url, method='GET', headers={
        'X-Auth-Email': email, 'X-Auth-Key': key, 'Accept': 'application/json'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=15) as response:
            payload = json.loads(response.read(2_000_000))
    except (OSError, ValueError, urllib.error.URLError):
        raise Stop('Cloudflare 只读认证失败或网络不可达；配置未改。核对 Global API Key、邮箱和网络。') from None
    if not isinstance(payload, dict) or payload.get('success') is not True:
        raise Stop('Cloudflare 未接受这组凭据；配置未改。')
    zones = payload.get('result')
    if not isinstance(zones, list) or not any(isinstance(x, dict) and x.get('name') == zone for x in zones):
        raise Stop('认证后未找到指定 Cloudflare 区域；配置未改。请确认区域名称和账号。')
    # This GET does not test DNS write permission or ACME renewal.


def private_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix='.cf-refresh-', dir=path.parent)
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_config(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise Stop('配置不是普通文件，停止；不跟随符号链接。')
    if hasattr(os, 'geteuid') and info.st_uid != os.geteuid():
        raise Stop('配置文件所有者不是当前 root，停止。')
    return path.read_bytes()


def inspect(home, domain):
    account = home / 'account.conf'
    domain_config = home / (domain + '_ecc') / (domain + '.conf')
    if home.is_symlink() or domain_config.parent.is_symlink():
        raise Stop('acme.sh 目录使用符号链接，需另行核对。')
    originals = {path: read_config(path) for path in (account, domain_config)}
    parsed = {path: settings(raw.decode('utf-8')) for path, raw in originals.items()}
    if parsed[domain_config].get('Le_Webroot') != 'dns_cf':
        raise Stop('当前域名不是 dns_cf 验证，不修改任何凭据。')
    for values in parsed.values():
        if any(values.get(name) for name in ('CF_Token', 'SAVED_CF_Token')):
            raise Stop('发现 API Token 配置，不能认定续期依赖旧 Global API Key；停止，不混用两种凭据。')
        if values.get('ACCOUNT_CONF_PATH') not in (None, '', str(account)):
            raise Stop('发现自定义 account.conf 路径，停止。')
        if values.get('LE_CONFIG_HOME') not in (None, '', str(home)):
            raise Stop('发现自定义 acme.sh 配置目录，停止。')
    email = (parsed[domain_config].get('CF_Email') or parsed[account].get('CF_Email')
             or parsed[account].get('SAVED_CF_Email') or '')
    return originals, parsed, account, domain_config, email


def commit_changes(home, originals, updates, writer=private_write):
    for path, original in originals.items():
        if read_config(path) != original:
            raise Stop('检查期间配置被其他进程修改，停止；未写入新凭据。')
    backups = home / ('.cf-key-backup-' + time.strftime('%Y%m%d-%H%M%S', time.gmtime())
                      + '-' + secrets.token_hex(4))
    backups.mkdir(mode=0o700)
    for number, (path, raw) in enumerate(originals.items()):
        backup = backups / (str(number) + '-' + path.name)
        private_write(backup, raw)
        if backup.read_bytes() != raw:
            raise Stop('保密备份校验失败，原配置未改。')
    changed = []
    try:
        for path, data in updates.items():
            changed.append(path)
            writer(path, data)
        for path, data in updates.items():
            if read_config(path) != data:
                raise OSError('Verification failed')
    except BaseException:
        rollback_failed = False
        for path in reversed(changed):
            try:
                private_write(path, originals[path])
            except Exception:
                rollback_failed = True
        if rollback_failed:
            raise Stop('写入失败且恢复未完整完成；保留 SSH 窗口，保密备份在 ' + str(backups)) from None
        raise Stop('写入失败，已恢复本次改动；没有重启任何服务。') from None
    return backups


def main(args):
    if not sys.platform.startswith('linux') or os.geteuid() != 0:
        raise Stop('仅在目标 Linux VPS 的 root 终端运行。')
    if not sys.stdin.isatty():
        raise Stop('需要交互终端，不能通过管道传入凭据。')
    if len(args) != 2:
        raise Stop('用法：python3 refresh_cf_global_key.py 证书域名 Cloudflare区域名')
    domain, zone = args
    for name in (domain, zone):
        if len(name) > 253 or not re.fullmatch(r'[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?', name) or '.' not in name:
            raise Stop('域名格式不正确。')
    if domain != zone and not domain.endswith('.' + zone):
        raise Stop('证书域名不属于指定区域。')
    home = Path('/root/.acme.sh')
    originals, parsed, account, domain_config, saved_email = inspect(home, domain)
    print('只同步现有 dns_cf 续期凭据；不重签、不重启、不修改 DNS 记录。', flush=True)
    email = input('Cloudflare 注册邮箱（留空沿用已保存的邮箱）：').strip() or saved_email
    if not re.fullmatch(r'[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+', email):
        raise Stop('邮箱格式不正确，配置未改。')
    key = getpass.getpass('新的 Global API Key（输入不显示，勿粘贴 API Token）：').strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{20,128}', key):
        raise Stop('凭据格式不正确，配置未改。')
    verify_cloudflare(email, key, zone)
    values = {'CF_Key': key, 'SAVED_CF_Key': key, 'CF_Email': email, 'SAVED_CF_Email': email}
    updates = {account: replacement(originals[account].decode('utf-8'), values).encode('utf-8')}
    overrides = {name: value for name, value in values.items() if name in parsed[domain_config]}
    if overrides:
        updates[domain_config] = replacement(originals[domain_config].decode('utf-8'), overrides).encode('utf-8')
    # Refuse concurrent renewal; do not stop cron or an ACME process.
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                arguments = (entry / 'cmdline').read_bytes().split(b'\0')
            except OSError:
                continue
            if any(argument.endswith(b'/acme.sh') or argument == b'acme.sh' for argument in arguments):
                raise Stop('acme.sh 正在运行，停止；等待它结束后再同步凭据。')
    backups = commit_changes(home, originals, updates)
    print('PASS：新凭据通过 Cloudflare 只读认证，已同步并核对文件；未修改 DNS 记录。')
    print('保密备份：' + str(backups) + '（不要上传或公开其中内容）')
    print('当前证书和代理服务保持原状；此结果不等于实际续期或 DNS 写入权限已通过验证。')


if __name__ == '__main__':
    try:
        def cancelled(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, cancelled)
        main(sys.argv[1:])
    except (KeyboardInterrupt, EOFError):
        print('已取消；没有重启服务。若已有保密备份，请保留以备核对。')
        sys.exit(1)
    except Stop as exc:
        print('停止：' + str(exc))
        sys.exit(1)
    except Exception as exc:
        print('停止：' + type(exc).__name__ + '；不显示配置或凭据，请保留此提示。')
        sys.exit(1)
