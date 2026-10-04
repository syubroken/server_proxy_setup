"""Real Bash/PTy with isolated paths, fake network/services and real TLS/config parsing.

No Cloudflare, CA, firewall, package installation or live service is contacted.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import test_terminal

ROOT = Path(__file__).resolve().parents[1]
KEY = 'fixture-global-key-never-real-12345678'
DISPATCH = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
fixtures = pathlib.Path(os.environ['TEST_FIXTURES'])
scenario = os.environ.get('MOCK_SCENARIO', '')
name, args = sys.argv[1], sys.argv[2:]
with open(os.environ['EVENT_LOG'], 'a') as stream:
    stream.write(json.dumps([name, *args]) + '\n')
if name in ('apt-get', 'ufw'):
    pass
elif name == 'dpkg':
    print('amd64')
elif name == 'curl':
    target = pathlib.Path(args[args.index('-o') + 1])
    filename = args[-1].split('/')[-1]
    assert filename in ('acme.sh', 'dns_cf.sh', 'install-release.sh', 'v2ray-linux-64.zip')
    shutil.copyfile(fixtures / filename, target)
    if scenario == 'bad-download' and filename == 'acme.sh':
        target.write_text('corrupt download')
elif name == 'fhs':
    binary = root / 'usr/local/bin/v2ray'
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text((fixtures / 'wrapper').read_text())
    binary.chmod(0o755)
    config = root / 'usr/local/etc/v2ray/config.json'
    config.parent.mkdir(parents=True, exist_ok=True)
    if not config.exists():
        config.write_text('{}')
elif name == 'acme':
    home = root / 'root/.acme.sh'
    if '--install' in args:
        home.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixtures / 'acme.sh', home / 'acme.sh')
        (home / 'acme.sh').chmod(0o700)
        if not (home / 'account.conf').exists():
            (home / 'account.conf').write_text("SAVED_CF_Key='stale-fixture-key'\nACCOUNT_EMAIL='saved@example.com'\n")
    elif '--issue' in args:
        assert '--dns' in args and args[args.index('--dns') + 1] == 'dns_cf'
        assert '--standalone' not in args and '--force' not in args
        assert args[args.index('--server') + 1] == 'letsencrypt'
        if scenario == 'ca-failure':
            print('fixture: CA rejected validation')
            sys.exit(1)
        certdir = home / 'example.com_ecc'
        certdir.mkdir(exist_ok=True)
        shutil.copyfile(fixtures / 'fullchain.pem', certdir / 'fullchain.cer')
        shutil.copyfile(fixtures / 'leaf.key', certdir / 'example.com.key')
        if scenario == 'skip-existing':
            sys.exit(2)
    elif '--install-cert' in args:
        if scenario == 'deploy-failure':
            sys.exit(9)
        assert (root / 'usr/local/bin/v2ray').exists(), 'Install V2Ray first'
        hook = args[args.index('--reloadcmd') + 1]
        assert 'v2ray' not in hook, 'Certificate hook should only reload TLS frontend'
        shutil.copyfile(fixtures / 'fullchain.pem', args[args.index('--fullchain-file') + 1])
        shutil.copyfile(fixtures / 'leaf.key', args[args.index('--key-file') + 1])
        sys.exit(subprocess.run(['bash', '-c', hook]).returncode)
elif name == 'v2ray':
    data = json.loads(pathlib.Path(args[args.index('-config') + 1]).read_text())
    assert data['inbounds'][0]['listen'] == '127.0.0.1'
    assert data['inbounds'][0]['streamSettings']['wsSettings']['path'] == '/ray'
    assert data['outbounds'][0]['protocol'] == 'freedom'
elif name == 'nginx':
    sys.exit(subprocess.run([os.environ['REAL_NGINX'], '-t', '-c', str(root / 'etc/nginx/nginx.conf')],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode)
elif name == 'openssl':
    if args[0] != 's_client':
        sys.exit(subprocess.run([os.environ['REAL_OPENSSL'], *args]).returncode)
elif name == 'systemctl':
    if scenario == 'inactive-v2ray' and args == ['is-active', '--quiet', 'v2ray']:
        sys.exit(3)
elif name == 'crontab':
    print('0 0 * * * "' + str(root / 'root/.acme.sh') + '"/acme.sh --cron --home "' + str(root / 'root/.acme.sh') + '" > /dev/null')
else:
    sys.exit(92)
'''


@unittest.skipUnless(sys.platform.startswith('linux') and getattr(os, 'geteuid', lambda: -1)() == 0
                     and shutil.which('nginx'), 'Requires disposable Debian root validation environment')
class LegacyFixedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='legacy-fixed-')
        self.base = Path(self.temp.name)
        self.root, self.fixtures, self.bin = [self.base / p for p in ('filesystem', 'fixtures', 'commands')]
        for path in ('etc/nginx/conf.d', 'etc/ssl/certs', 'root', 'run/systemd/system', 'proc/sys/kernel/random'):
            (self.root / path).mkdir(parents=True)
        self.fixtures.mkdir()
        self.bin.mkdir()
        (self.root / 'etc/os-release').write_text('ID=debian\nVERSION_ID="13"\n')
        (self.root / 'proc/sys/kernel/random/uuid').write_text('11111111-1111-4111-8111-111111111111\n')
        (self.root / 'etc/nginx/nginx.conf').write_text(
            f'pid {self.root}/nginx.pid;\nerror_log {self.root}/nginx-error.log;\n'
            f'events {{}}\nhttp {{ access_log off; include {self.root}/etc/nginx/conf.d/*.conf; }}\n')
        self.real_openssl, self.real_nginx = shutil.which('openssl'), shutil.which('nginx')
        def openssl(*args):
            subprocess.run([self.real_openssl, *args], cwd=self.fixtures, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', '-subj', '/CN=Fixture CA')
        openssl('req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
                '-keyout', 'leaf.key', '-out', 'leaf.csr', '-subj', '/CN=example.com')
        (self.fixtures / 'extensions').write_text('subjectAltName=DNS:example.com\nextendedKeyUsage=serverAuth\n')
        openssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
                '-CAcreateserial', '-out', 'leaf.pem', '-days', '1', '-extfile', 'extensions')
        (self.fixtures / 'fullchain.pem').write_bytes((self.fixtures / 'leaf.pem').read_bytes() + (self.fixtures / 'ca.pem').read_bytes())
        shutil.copyfile(self.fixtures / 'ca.pem', self.root / 'etc/ssl/certs/ca-certificates.crt')
        dispatch = self.base / 'dispatch.py'
        dispatch.write_text(DISPATCH)
        prefix = '#!/bin/sh\nexec ' + sys.executable + ' ' + str(dispatch)
        wrapper = prefix + ' "$(basename "$0")" "$@"\n'
        (self.fixtures / 'wrapper').write_text(wrapper)
        for name in ('apt-get', 'ufw', 'dpkg', 'curl', 'v2ray', 'nginx', 'openssl', 'systemctl', 'crontab'):
            path = self.bin / name
            path.write_text(wrapper)
            path.chmod(0o755)
        (self.fixtures / 'acme.sh').write_text(prefix + ' acme "$@"\n')
        (self.fixtures / 'install-release.sh').write_text(prefix + ' fhs "$@"\n')
        (self.fixtures / 'dns_cf.sh').write_text('# fixture only\n')
        (self.fixtures / 'v2ray-linux-64.zip').write_bytes(b'fixture only')
        script = (ROOT / 'legacy/setup_script_fixed.sh').read_text()
        # Translate a private copy only; production has no test environment switch.
        script = re.sub(r'(?<![\w/.-])/(?:run/systemd|proc/sys/kernel|usr/local|etc|root)',
                        lambda match: str(self.root) + match[0], script)
        for digest, filename in (
            ('c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7', 'acme.sh'),
            ('9628ee8238cb3f9cfa1b1a985c0e9593436a3e4f8a9d65a6f775b981be9e76c8', 'dns_cf.sh'),
            ('e82217ce0db9e68f41ca34521ecd4ac98018d22d9ddd83e1316c74fb805603ae', 'install-release.sh'),
            ('6bbb8aee65a57d0b12599b4b7c842b3ad0daca4436e661d94015c447cb31b4fa', 'v2ray-linux-64.zip')):
            script = script.replace(digest, hashlib.sha256((self.fixtures / filename).read_bytes()).hexdigest())
        self.script, self.log = self.base / 'setup.sh', self.base / 'events.jsonl'
        self.script.write_text(script)

    def tearDown(self):
        self.temp.cleanup()

    def install(self, scenario=''):
        env = {
            'PATH': str(self.bin) + ':' + os.environ['PATH'], 'HOME': str(self.root / 'root'),
            'TEST_ROOT': str(self.root), 'TEST_FIXTURES': str(self.fixtures), 'MOCK_SCENARIO': scenario,
            'EVENT_LOG': str(self.log), 'REAL_OPENSSL': self.real_openssl, 'REAL_NGINX': self.real_nginx,
            'SSH_CONNECTION': '198.51.100.9 50000 192.0.2.1 2222',
        }
        harness = test_terminal.TerminalTest('test_actual_bash_heredoc_entry_reads_controlling_terminal')
        return harness.session(['env', *[k + '=' + v for k, v in env.items()], 'bash', str(self.script)],
                               [('Cloudflare 注册邮箱：', b'owner@example.com\n'),
                                ('代理域名（例如 senyz.top）：', b'example.com\n'),
                                ('不是 API Token）：', (KEY + '\n').encode())])

    def events(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()]

    def test_success_retry_hidden_key_and_ssh_rule_order(self):
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertIn('Setup Complete', output)
        self.assertNotIn(KEY, output)
        events = self.events()
        self.assertLess(events.index(['ufw', 'allow', '2222/tcp']), events.index(['ufw', '--force', 'enable']))
        before = (self.root / 'usr/local/etc/v2ray/config.json').read_bytes()
        code, output = self.install('skip-existing')
        self.assertEqual(code, 0, output)
        self.assertNotIn(KEY, output)
        self.assertEqual((self.root / 'usr/local/etc/v2ray/config.json').read_bytes(), before)
        self.assertEqual((self.root / 'etc/nginx/conf.d/legacy-proxy.conf').read_text().count('server_name example.com;'), 1)
        account = (self.root / 'root/.acme.sh/account.conf').read_text()
        self.assertIn(KEY, account)
        self.assertNotIn('stale-fixture-key', account)
        self.assertEqual((self.root / 'root/.acme.sh/account.conf').stat().st_mode & 0o777, 0o600)

    def test_ca_failure_never_deploys_or_reports_success(self):
        code, output = self.install('ca-failure')
        self.assertNotEqual(code, 0)
        self.assertNotIn('Setup Complete', output)
        self.assertFalse(any(x[0] == 'acme' and '--install-cert' in x for x in self.events()))
        self.assertFalse((self.root / 'etc/nginx/conf.d/legacy-proxy.conf').exists())

    def test_certificate_deploy_failure_does_not_restart_v2ray(self):
        code, output = self.install('deploy-failure')
        self.assertNotEqual(code, 0)
        self.assertNotIn('Setup Complete', output)
        self.assertNotIn(['systemctl', 'restart', 'v2ray'], self.events())

    def test_nginx_active_does_not_hide_v2ray_failure(self):
        code, output = self.install('inactive-v2ray')
        self.assertNotEqual(code, 0)
        self.assertNotIn('Setup Complete', output)

    def test_corrupt_download_is_not_executed(self):
        code, output = self.install('bad-download')
        self.assertNotEqual(code, 0)
        self.assertNotIn('Setup Complete', output)
        self.assertFalse(any(x[0] in ('acme', 'fhs') for x in self.events()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
