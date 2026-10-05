"""Real iproute2 in a disposable network namespace, without WARP or a VPS."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from test_candidate import module


def run(args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check)


if __name__ == '__main__':
    if os.geteuid() != 0 or os.environ.get('SPS_ISOLATED_TEST') != '1':
        raise SystemExit('Requires the disposable CI network namespace')
    app = module()
    run(['ip', 'link', 'set', 'lo', 'up'])
    run(['ip', 'link', 'add', 'spsnative', 'type', 'dummy'])
    run(['ip', 'link', 'set', 'spsnative', 'up'])
    run(['ip', 'addr', 'add', '192.0.2.10/24', 'dev', 'spsnative'])
    run(['ip', '-6', 'addr', 'add', '2001:db8:1::10/64', 'dev', 'spsnative', 'nodad'])
    run(['ip', '-4', 'route', 'add', 'default', 'via', '192.0.2.1', 'dev', 'spsnative', 'proto', 'dhcp'])
    run(['ip', '-6', 'route', 'add', 'default', 'via', 'fe80::1', 'dev', 'spsnative',
         'proto', 'ra', 'metric', '1024', 'expires', '600', 'mtu', '1500', 'pref', 'medium'])
    text = run(['ip', '-6', 'route', 'show', 'default']).stdout.strip()
    assert 'expires' in text and 'sec' in text, text
    # Exact old behavior: split the display text and feed it back to ip route replace.
    failed = run(['ip', '-6', 'route', 'replace', 'table', '51999', *text.split()], check=False)
    assert failed.returncode == 255 and 'expires' in failed.stderr, failed
    print('REPRODUCED alpha3 display replay: exit 255, expires parser error')

    with tempfile.TemporaryDirectory(prefix='sps-routes-') as tmp:
        app.STATE = Path(tmp) / 'state.json'
        app.save(app.STATE, {'network': {'dev': 'spsnative'}, 'ssh': {'server': '192.0.2.10'}, 'proxy_uid': 65534})
        before4 = json.loads(run(['ip', '-4', '-j', 'route', 'show', 'table', 'main']).stdout)
        app.management_routes()
        for family in ('-4', '-6'):
            rows = json.loads(run(['ip', family, '-j', 'route', 'show', 'table', app.WAN_TABLE]).stdout)
            defaults = [r for r in rows if r.get('dst') == 'default']
            assert len(defaults) == 1, rows
            assert 'expires' not in defaults[0], defaults
            target = '198.51.100.1' if family == '-4' else '2001:db8:2::1'
            route = json.loads(run(['ip', family, '-j', 'route', 'get', target, 'uid', '0']).stdout)[0]
            assert str(route['table']) == app.WAN_TABLE and route['dev'] == 'spsnative', route
        assert json.loads(run(['ip', '-4', '-j', 'route', 'show', 'table', 'main']).stdout) == before4
        app.management_routes()  # repeated boot/guard setup is safe
        app.clear_own_routes()
        assert not any(r.get('priority') in app.RULE_PREFS for r in json.loads(run(['ip', '-4', '-j', 'rule']).stdout))
        print('Native IPv4/DHCP and IPv6/RA management routes, repeat and cleanup: PASS')

        # Typical routed /32 VPS: gateway lies outside the assigned address prefix.
        run(['ip', 'addr', 'del', '192.0.2.10/24', 'dev', 'spsnative'])
        run(['ip', 'addr', 'add', '192.0.2.10/32', 'dev', 'spsnative'])
        run(['ip', '-4', 'route', 'replace', 'default', 'via', '198.51.100.254',
             'dev', 'spsnative', 'onlink'])
        app.management_routes()
        route = json.loads(run(['ip', '-4', '-j', 'route', 'get', '203.0.113.1', 'uid', '0']).stdout)[0]
        assert route.get('gateway') == '198.51.100.254' and str(route['table']) == app.WAN_TABLE, route
        app.clear_own_routes()
        print('Native /32 IPv4 with an onlink gateway: PASS')
