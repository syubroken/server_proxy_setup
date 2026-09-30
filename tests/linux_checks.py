"""Offline Linux configuration and isolated kernel tests; never register WARP."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
app = runpy.run_path(str(ROOT / 'tests/test_candidate.py'))['module']()


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **kwargs)


def configs():
    with tempfile.TemporaryDirectory(prefix='sps-config-') as tmp:
        app.ETC = Path(tmp)
        app.WEBROOT = Path(tmp) / 'webroot'
        app.WEBROOT.mkdir()
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=proxy.example.com', '-keyout', app.ETC / 'key.pem',
             '-out', app.ETC / 'fullchain.pem'])
        for tls in (False, True):
            config = app.ETC / 'nginx.conf'
            config.write_text(app.nginx_config('proxy.example.com', '/ray', tls))
            run(['nginx', '-t', '-c', config])
        units = {}
        app.unit_write = lambda name, text: units.update({name: text})
        app.SCRIPT = ROOT / 'setup_script.sh'
        app.OPT = app.ETC / 'opt'
        (app.OPT / 'bin').mkdir(parents=True)
        # systemd-analyze checks executable paths; no actual service is started.
        for binary in ('v2ray',):
            (app.OPT / 'bin' / binary).symlink_to('/usr/bin/true')
        app.write_units()
        unit_files = []
        for name, content in units.items():
            if '/' in name:
                continue  # Drop-in content is covered by unit tests.
            target = app.ETC / name
            target.write_text(content)
            unit_files.append(target)
        # WARP is intentionally not installed in this offline test environment.
        (app.ETC / 'warp-svc.service').write_text('[Service]\nExecStart=/usr/bin/true\n')
        run(['systemd-analyze', 'verify', *unit_files])
    print('Nginx HTTP/TLS configs and systemd unit syntax: PASS')


def kernel():
    if os.geteuid() != 0 or os.environ.get('SPS_ISOLATED_TEST') != '1':
        raise SystemExit('Run only in the disposable CI network namespace.')
    uid = int(run(['id', '-u', 'nobody']).stdout)
    run(['ip', 'link', 'set', 'lo', 'up'])
    run(['ip', 'netns', 'add', 'sps-ci-peer'])
    servers = []
    try:
        run(['ip', 'link', 'add', 'spswan', 'type', 'veth', 'peer', 'name', 'spspeer'])
        run(['ip', 'link', 'set', 'spspeer', 'netns', 'sps-ci-peer'])
        run(['ip', 'addr', 'add', '198.51.100.1/24', 'dev', 'spswan'])
        run(['ip', '-6', 'addr', 'add', '2001:db8:1::1/64', 'dev', 'spswan', 'nodad'])
        run(['ip', 'link', 'set', 'spswan', 'up'])
        peer = ['ip', 'netns', 'exec', 'sps-ci-peer']
        for args in (['ip', 'link', 'set', 'lo', 'up'],
                     ['ip', 'addr', 'add', '198.51.100.2/24', 'dev', 'spspeer'],
                     ['ip', '-6', 'addr', 'add', '2001:db8:1::2/64', 'dev', 'spspeer', 'nodad'],
                     ['ip', 'link', 'set', 'spspeer', 'up']):
            run(peer + args)
        for addr in ('198.51.100.2', '2001:db8:1::2'):
            servers.append(subprocess.Popen(peer + ['python3', '-m', 'http.server', '18080', '--bind', addr],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(1)
        rules = app.firewall_text(uid, 22)
        run(['nft', '-c', '-f', '-'], input=rules)
        run(['nft', '-f', '-'], input=rules)

        def request(addr, protected):
            args = ['curl', '--noproxy', '*', '-fsS', '--connect-timeout', '1', '--max-time', '2',
                    f'http://{addr}:18080/']
            if protected:
                args = ['runuser', '-u', 'nobody', '--', *args]
            return subprocess.run(args, capture_output=True).returncode

        for addr in ('198.51.100.2', '[2001:db8:1::2]'):
            assert request(addr, False) == 0, 'Management positive control failed'
            assert request(addr, True) != 0, 'Business UID escaped onto native interface'
        run(['ip', 'link', 'set', 'spswan', 'down'])
        run(['ip', 'link', 'set', 'spswan', 'name', app.WARP_IF])
        run(['ip', 'link', 'set', app.WARP_IF, 'up'])
        for addr in ('198.51.100.2', '[2001:db8:1::2]'):
            assert request(addr, True) == 0, 'Simulated tunnel interface did not allow protected UID'
        run(['ip', 'link', 'set', app.WARP_IF, 'down'])
        run(['ip', 'link', 'set', app.WARP_IF, 'name', 'spswan'])
        run(['ip', 'link', 'set', 'spswan', 'up'])
        for addr in ('198.51.100.2', '[2001:db8:1::2]'):
            assert request(addr, True) != 0, 'Business UID escaped after tunnel name disappeared'
            assert request(addr, False) == 0, 'Management must remain available'
        print('Isolated nftables IPv4/IPv6 UID and interface rules: PASS (simulated tunnel only)')
    finally:
        for process in servers:
            process.terminate()
            process.wait(timeout=5)
        run(['ip', 'netns', 'delete', 'sps-ci-peer'])


if __name__ == '__main__':
    kernel() if '--kernel' in sys.argv else configs()
