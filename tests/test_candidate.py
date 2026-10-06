"""Offline regression tests. They never run a network or Linux mutation command.

Windows cannot exercise Linux nftables/systemd; these tests must not be reported
as a real VPS, firewall-kernel, reboot or client acceptance test.
"""
import ast
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / 'setup_script.sh'
TEXT = SCRIPT.read_text(encoding='utf-8')
PAYLOAD = TEXT.split("<<'SWO_PYTHON'\n", 1)[1].rsplit('\nSWO_PYTHON', 1)[0]


def module():
    if 'fcntl' not in sys.modules and importlib.util.find_spec('fcntl') is None:
        sys.modules.setdefault('fcntl', types.SimpleNamespace(
            LOCK_EX=1, LOCK_NB=2, flock=lambda *args: None))
    mod = types.ModuleType('candidate_under_test')
    old_argv = sys.argv
    try:
        sys.argv = ['test', str(SCRIPT)]
        exec(compile(PAYLOAD, str(SCRIPT) + ':embedded', 'exec'), mod.__dict__)
    finally:
        sys.argv = old_argv
    return mod


class CandidateTest(unittest.TestCase):
    def setUp(self):
        self.app = module()
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        for name in ('BASE', 'ETC', 'OPT'):
            path = root / name
            path.mkdir()
            setattr(self.app, name, path)
        self.app.STATE = self.app.BASE / 'state.json'
        self.app.PENDING = self.app.BASE / 'pending.json'
        self.app.PROOF = self.app.BASE / 'ssh-proof.json'
        self.app.ACME_STAGE = self.app.BASE / 'acme-staging'
        self.app.ACME_PROD = self.app.BASE / 'acme-production'
        self.app.WEBROOT = self.app.BASE / 'webroot'
        self.app.require_root = lambda: None
        self.app.boot_id = lambda: 'boot-a'
        self.app.say = Mock()

        def atomic(path, content, mode=0o600):
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode() if isinstance(content, str) else content)
        self.app.atomic = atomic
        self.commands = []

        def run(args, **kwargs):
            self.commands.append([str(a) for a in args])
            if args[:2] == ['systemctl', 'is-active']:
                return subprocess.CompletedProcess(args, 3, 'inactive\n', '')
            if len(args) > 3 and args[0] == 'ip' and 'del' in args:
                return subprocess.CompletedProcess(args, 2, '', '')
            return subprocess.CompletedProcess(args, 0, '', '')
        self.app.run = Mock(side_effect=run)
        self.app.nft_apply = Mock()
        self.app.nft_is_present = Mock(return_value=True)
        self.app.management_routes = Mock()
        self.app.business_routes = Mock()
        self.app.clear_own_routes = Mock()
        self.app.restore_dns = Mock()
        self.app.verify_warp_context = Mock()
        self.app.save(self.app.STATE, {
            'version': self.app.VERSION, 'stage': 'prepared', 'prepared': True,
            'ready': False, 'proxy_uid': 1001, 'caddy_uid': 1002,
            'domain': 'proxy.example.com', 'email': 'owner@example.com',
            'ssh': {'client': '8.8.8.8', 'client_port': 40001, 'server': '8.8.4.4', 'server_port': 22},
            'network': {'dev': 'eth0', 'resolv': 'nameserver 1.1.1.1\n', 'main': {}},
            'trace4': '1.1.1.1', 'trace6': '2606:4700:4700::1111',
        })

    def tearDown(self):
        self.temp.cleanup()

    def pending(self, **changes):
        value = {'id': 'transaction-a', 'boot_id': 'boot-a', 'origin': 'old-connection',
                 'deadline': self.app.time.time() + 60, 'ssh_after': self.app.time.time() - 5, **changes}
        self.app.save(self.app.PENDING, value)
        return value

    def proof(self, **changes):
        value = {'transaction': 'transaction-a', 'boot_id': 'boot-a', 'connection': 'new-connection',
                 'ssh_started_at': self.app.time.time(), **changes}
        self.app.save(self.app.PROOF, value)
        return value

    def test_payload_compiles(self):
        ast.parse(PAYLOAD)

    def test_commands_are_not_shell_interpolated(self):
        tree = ast.parse(PAYLOAD)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                for kw in node.keywords:
                    self.assertFalse(kw.arg == 'shell' and isinstance(kw.value, ast.Constant) and kw.value.value)

    def test_inputs_reject_command_or_config_injection(self):
        self.app.validate_inputs('proxy.example.com', 'owner@example.com')
        for domain in ('x;touch /tmp/pwn', 'x\nexample.com', '127.0.0.1', '*.example.com', '-x.example.com'):
            with self.subTest(domain=domain), self.assertRaises(self.app.Stop):
                self.app.validate_inputs(domain, 'owner@example.com')
        for email in ('$(id)@example.com', 'x@y\nexample.com', 'noemail'):
            with self.subTest(email=email), self.assertRaises(self.app.Stop):
                self.app.validate_inputs('proxy.example.com', email)

    def test_simple_stack_has_no_zero_trust_mdm_or_caddy(self):
        self.assertNotIn('mdm.xml', PAYLOAD)
        self.assertNotIn('auth_client_secret', PAYLOAD)
        self.assertNotIn('Caddyfile', PAYLOAD)
        self.assertNotIn('def menu(', PAYLOAD)
        self.assertIn('acme.sh', self.app.DOWNLOADS)

    def test_reused_stale_cancelled_or_expired_ssh_proof_is_rejected(self):
        p = self.pending()
        good = self.proof()
        self.assertTrue(self.app.valid_proof(p, good))
        bad_proofs = [{'connection': 'old-connection'}, {'boot_id': 'other'}, {'transaction': 'old'}, {'connection': None}]
        for changes in bad_proofs:
            self.assertFalse(self.app.valid_proof(p, {**good, **changes}))
        self.assertFalse(self.app.valid_proof({**p, 'deadline': 1}, good))
        self.assertFalse(self.app.valid_proof({**p, 'cancelled': True}, good))
        self.assertFalse(self.app.valid_proof({**p, 'boot_id': 'old-boot'}, good))
        self.assertFalse(self.app.valid_proof(p, {**good, 'ssh_started_at': 1}))
        self.assertFalse(self.app.valid_proof({**p, 'ssh_after': None}, good))

    def test_deadline_recovers_without_waiting_on_operation_lock(self):
        self.pending(deadline=1)
        used = []
        @contextlib.contextmanager
        def lock(name='operation.lock', nonblocking=True):
            used.append(name)
            yield
        self.app.lock = lock
        self.app.safe_stop_locked = Mock()
        self.app.deadline_check()
        self.assertEqual(used, ['transaction.lock'])
        self.app.safe_stop_locked.assert_called_once_with('deadline-expired')

    def test_expired_transaction_cannot_publish_ready(self):
        self.pending(deadline=1)
        self.proof()
        with self.assertRaises(self.app.Stop):
            self.app.transaction_commit('client-trial', ready=True)
        self.assertFalse(self.app.load(self.app.STATE)['ready'])
        self.assertTrue(self.app.PENDING.exists())

    def test_successful_commit_publishes_ready_and_clears_marker(self):
        self.pending()
        self.proof()
        self.app.transaction_commit('client-trial', ready=True)
        self.assertTrue(self.app.load(self.app.STATE)['ready'])
        self.assertFalse(self.app.PENDING.exists())

    def test_recovery_cancels_transaction_before_tearing_down_warp(self):
        self.pending()
        self.proof()
        self.app.safe_stop('test-failure')
        self.assertFalse(self.app.load(self.app.STATE)['ready'])
        self.assertTrue(self.app.load(self.app.PENDING)['cancelled'])
        self.assertFalse(self.app.PROOF.exists())
        stop_proxy = self.commands.index(['systemctl', 'stop', self.app.PROXY_SERVICE])
        stop_warp = self.commands.index(['systemctl', 'stop', 'warp-svc.service'])
        self.assertLess(stop_proxy, stop_warp)
        self.app.restore_dns.assert_called_once()

    def test_live_proxy_prevents_warp_teardown_when_stop_and_kill_fail(self):
        self.pending()
        original = self.app.run.side_effect
        def still_live(args, **kwargs):
            if args == ['systemctl', 'is-active', self.app.PROXY_SERVICE]:
                self.commands.append(args)
                return subprocess.CompletedProcess(args, 0, 'active', '')
            return original(args, **kwargs)
        self.app.run.side_effect = still_live
        with self.assertRaises(self.app.Stop):
            self.app.safe_stop('stuck-process')
        self.assertNotIn(['systemctl', 'stop', 'warp-svc.service'], self.commands)
        self.assertTrue(self.app.load(self.app.PENDING)['cancelled'])

    def test_boot_with_uncommitted_state_refuses_warp_start(self):
        self.pending(boot_id='old-boot')
        self.app.safe_stop = Mock()
        with self.assertRaises(self.app.Stop):
            self.app.internal_guard()
        self.app.safe_stop.assert_called_once_with('reboot-with-uncommitted-transaction', boot=True)
        self.app.management_routes.assert_not_called()

    def test_429_stops_registration_after_one_cli_request(self):
        self.pending()
        self.app.verify_blocking_without_tunnel = Mock()
        original = self.app.run.side_effect
        def rate_limited(args, **kwargs):
            self.commands.append([str(a) for a in args])
            if args[-2:] == ['registration', 'show']:
                return subprocess.CompletedProcess(args, 1, '', 'Registration Missing')
            if args[-2:] == ['registration', 'new']:
                return subprocess.CompletedProcess(args, 1, '', 'HTTP 429 Too Many Requests')
            if args[0] == 'journalctl':
                return subprocess.CompletedProcess(args, 0, '', '')
            return subprocess.CompletedProcess(args, 0, 'Disconnected', '')
        self.app.run.side_effect = rate_limited
        with self.assertRaisesRegex(self.app.Stop, '限流'):
            self.app.connect_warp()
        self.assertTrue(self.app.load(self.app.STATE)['registration_blocked'])
        self.assertTrue(self.app.load(self.app.STATE)['registration_attempted'])
        self.assertEqual(sum(c[-2:] == ['registration', 'new'] for c in self.commands), 1)
        self.assertFalse(any('delete' in c for c in self.commands))

    def test_cancelled_transaction_never_starts_warp(self):
        self.pending(cancelled=True)
        self.app.verify_blocking_without_tunnel = Mock()
        with self.assertRaises(self.app.Stop):
            self.app.connect_warp()
        self.assertFalse(any(cmd[:3] == ['systemctl', 'start', '--no-block'] for cmd in self.commands))

    def test_dns_has_no_system_resolver_fallback(self):
        cfg = self.app.server_config('00000000-0000-4000-8000-000000000001', '/test')
        self.assertNotIn('localhost', json.dumps(cfg))
        self.assertEqual(cfg['outbounds'][0]['settings']['domainStrategy'], cfg['dns']['queryStrategy'])
        self.assertNotIn('disableFallback', cfg['dns'])
        self.assertEqual(len(cfg['dns']['servers']), 1)
        self.assertTrue(cfg['dns']['servers'][0].startswith('https+local://1.1.1.1/'))
        self.assertEqual(cfg['inbounds'][0]['listen'], '127.0.0.1')

    def test_firewall_does_not_allow_any_established_egress_or_all_loopback(self):
        rules = self.app.firewall_text(1001, 2222)
        output = rules.split('chain output', 1)[1]
        self.assertNotIn('ct state established,related accept', output)
        self.assertIn('meta skuid 1001 jump proxy_only', output)
        self.assertIn('ct direction reply ct state established accept', output)
        self.assertNotIn('oifname "lo" accept', output)
        self.assertIn('ip6 daddr', output)
        self.assertIn('oifname "CloudflareWARP" counter accept', output)
        self.assertTrue(output.rstrip().endswith('counter drop\n }\n}'))

    def test_socks_ipv6_test_fixes_destination_without_forcing_ipv6_proxy_socket(self):
        self.app.trace_curl(6, socks=True)
        args = self.commands[-1]
        self.assertNotIn('-6', args)
        self.assertEqual(args[args.index('--noproxy') + 1], '')
        self.assertEqual(args[args.index('--socks5') + 1], '127.0.0.1:18443')
        self.assertIn('www.cloudflare.com:443:[2606:4700:4700::1111]', args)

    def test_direct_success_when_warp_down_is_a_hard_failure(self):
        self.app.trace_curl = Mock(return_value=subprocess.CompletedProcess([], 0, 'warp=off\n', ''))
        with self.assertRaisesRegex(self.app.Stop, '仍可出站'):
            self.app.verify_blocking_without_tunnel()

    def test_plain_disconnected_trace_is_not_success(self):
        self.assertTrue(self.app.trace_ok('warp=on\n'))
        self.assertTrue(self.app.trace_ok('warp=plus\n'))
        for text in ('warp=off\n', 'status=Connected\n', 'notwarp=on', 'warp=unknown'):
            self.assertFalse(self.app.trace_ok(text))

    def test_failed_warp_gate_prevents_any_node_export(self):
        self.app.state_update(ready=True)
        self.app.verify_warp_context.side_effect = self.app.Stop('egress failed')
        self.app.full_proxy_probe = Mock()
        with self.assertRaises(self.app.Stop):
            self.app.export_node()
        self.app.full_proxy_probe.assert_not_called()
        self.assertFalse((self.app.BASE / 'client-trial.txt').exists())

    def test_corrupt_download_is_never_saved_or_executed(self):
        def curl(args, **kwargs):
            Path(args[args.index('--output') + 1]).write_bytes(b'corrupt-not-an-executable')
            return subprocess.CompletedProcess(args, 0, '200', '')
        self.app.run.side_effect = curl
        with self.assertRaisesRegex(self.app.Stop, '摘要不匹配'):
            self.app.download('v2ray.zip')
        self.assertFalse((self.app.BASE / 'downloads/v2ray.zip').exists())
        self.assertEqual(self.app.run.call_count, 1)

    def test_download_transport_retry_ipv4_and_cache(self):
        data = b'fixture verified public file'
        self.app.DOWNLOADS['fixture'] = ('https://example.com/file', self.app.hashlib.sha256(data).hexdigest())
        calls = []
        def curl(args, **kwargs):
            calls.append(args)
            if len(calls) == 1:
                return subprocess.CompletedProcess(args, 28, '000', 'raw-error-not-for-display')
            Path(args[args.index('--output') + 1]).write_bytes(data)
            return subprocess.CompletedProcess(args, 0, '200', '')
        self.app.run.side_effect = curl
        with patch.object(self.app.time, 'sleep') as sleep:
            result = self.app.download('fixture')
            self.assertEqual(result.read_bytes(), data)
            self.assertEqual(self.app.download('fixture'), result)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('-4', calls[0])
        self.assertIn('-4', calls[1])
        self.assertIn('--proto-redir', calls[0])
        self.assertNotIn('--insecure', calls[0])
        sleep.assert_called_once_with(5)

    def test_download_tls_http_denial_and_limit_are_not_retried(self):
        for code, http, text in ((60, '000', 'TLS 证书校验失败'), (22, '403', 'HTTP 403'),
                                 (22, '404', 'HTTP 404'), (22, '429', 'HTTP 429')):
            with self.subTest(code=code, http=http):
                self.app.run.reset_mock(side_effect=True)
                self.app.run.return_value = subprocess.CompletedProcess([], code, http, 'must-not-leak')
                with patch.object(self.app.time, 'sleep') as sleep:
                    with self.assertRaisesRegex(self.app.Stop, text) as caught:
                        self.app.download('warp-key')
                self.assertNotIn('must-not-leak', str(caught.exception))
                self.assertEqual(self.app.run.call_count, 1)
                sleep.assert_not_called()
        self.assertFalse((self.app.BASE / 'downloads/warp-key').exists())

    def test_download_transient_errors_stop_after_three_attempts(self):
        for code, http in ((6, '000'), (22, '503')):
            self.app.run.reset_mock(side_effect=True)
            self.app.run.return_value = subprocess.CompletedProcess([], code, http, '')
            with patch.object(self.app.time, 'sleep') as sleep:
                with self.assertRaisesRegex(self.app.Stop, '尝试 3/3'):
                    self.app.download('warp-key')
            self.assertEqual(self.app.run.call_count, 3)
            self.assertEqual(sleep.call_count, 2)

    def test_public_download_failure_precedes_package_or_service_changes(self):
        self.app.state_update(prepared=False)
        self.app.download = Mock(side_effect=self.app.Stop('TLS 证书校验失败'))
        with self.assertRaisesRegex(self.app.Stop, 'TLS'):
            self.app.prepare()
        self.assertEqual(self.commands, [])
        self.assertFalse(self.app.load(self.app.STATE)['prepared'])

    def test_diagnostics_allowlist_excludes_sensitive_state(self):
        self.app.state_update(secret='must-not-export', private_key='must-not-export',
                              domain='sensitive.example', ssh={'server': '8.8.4.4'},
                              network={'resolv': 'sensitive-network-data'})
        self.app.diagnostics()
        exported = (self.app.BASE / 'diagnostics.json').read_text()
        for text in ('must-not-export', 'sensitive.example', '8.8.4.4', 'sensitive-network-data'):
            self.assertNotIn(text, exported)

    def test_no_uninitialized_lock_directory_is_created(self):
        self.app.STATE.unlink()
        with self.assertRaises(self.app.Stop), self.app.lock():
            pass
        self.assertFalse((self.app.BASE / 'operation.lock').exists())

    def test_units_require_guard_before_warp_and_proxy(self):
        written = {}
        self.app.unit_write = lambda name, text: written.update({name: text})
        self.app.write_units()
        self.assertIn('Requires=sps-guard.service', written['warp-svc.service.d/50-sps-guard.conf'])
        self.assertIn('internal-proxy-gate', written[self.app.PROXY_SERVICE])
        self.assertIn('OnBootSec=15s', written['sps-deadline.timer'])
        self.assertIn('WantedBy=timers.target', written['sps-deadline.timer'])
        self.assertIn('After=network-online.target', written['sps-guard.service'])

    def test_existing_legacy_directory_refuses_before_any_command(self):
        self.app.check_platform = Mock()
        class VirtualPath:
            def __init__(self, path): self.path = str(path)
            def exists(self): return self.path == '/etc/nginx'
        self.app.Path = VirtualPath
        with self.assertRaisesRegex(self.app.Stop, '不能叠加'):
            self.app.clean_check()
        self.assertEqual(self.commands, [])

    def test_ipv4_mapped_dns_is_not_misclassified_as_real_aaaa(self):
        fake = [(None, None, None, None, ('::ffff:8.8.4.4', 443))]
        with patch.object(self.app.socket, 'getaddrinfo', return_value=fake):
            self.app.verify_dns('proxy.example.com', '8.8.4.4')
        fake.append((None, None, None, None, ('2606:4700:4700::1111', 443)))
        with patch.object(self.app.socket, 'getaddrinfo', return_value=fake):
            with self.assertRaises(self.app.Stop):
                self.app.verify_dns('proxy.example.com', '8.8.4.4')

    def test_incomplete_recovery_is_retried_by_deadline_timer(self):
        self.pending(cancelled=True)
        self.app.state_update(recovery_errors=['in-progress'])
        self.app.safe_stop_locked = Mock()
        self.app.deadline_check()
        self.app.safe_stop_locked.assert_called_once_with('retry-incomplete-recovery')

    def test_fully_recovered_cancelled_marker_does_not_trigger_repeated_mutations(self):
        self.pending(cancelled=True)
        self.app.state_update(recovery_errors=[])
        self.app.safe_stop_locked = Mock()
        self.app.deadline_check()
        self.app.safe_stop_locked.assert_not_called()

    def test_resume_cannot_clear_incomplete_recovery_marker(self):
        self.pending(cancelled=True)
        self.app.state_update(recovery_errors=['in-progress'])
        with self.assertRaisesRegex(self.app.Stop, '尚未完成'):
            self.app.reset_cancelled_transaction()
        self.assertTrue(self.app.PENDING.exists())

    def test_service_binary_directories_are_explicitly_traversable(self):
        # Exercise real chmod on POSIX; on Windows verify explicit permissions
        # were requested, since its filesystem does not implement POSIX modes.
        if os.name == 'posix':
            previous = os.umask(0o077)
            try:
                self.app.service_binary_directory()
            finally:
                os.umask(previous)
            for path in (self.app.OPT, self.app.OPT / 'bin'):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)
        else:
            with patch.object(self.app.os, 'chmod') as chmod:
                self.app.service_binary_directory()
            self.assertEqual([call.args for call in chmod.call_args_list],
                             [(self.app.OPT, 0o755), (self.app.OPT / 'bin', 0o755)])



    def test_certificate_failure_sets_visible_failure_without_reinstall(self):
        self.app.state_update(ready=True)
        self.app.acme = Mock(return_value=subprocess.CompletedProcess([], 1, '', 'failed'))
        self.app.verify_served_certificate = Mock()
        with self.assertRaisesRegex(self.app.Stop, '续期'):
            self.app.renew_certificate()
        self.assertFalse(self.app.load(self.app.STATE)['certificate_ok'])
        self.app.verify_served_certificate.assert_not_called()
        self.assertFalse(any('apt-get' in c for c in self.commands))

    def test_renewal_checks_actual_served_certificate_even_if_nothing_due(self):
        self.app.state_update(ready=True)
        self.app.acme = Mock(return_value=subprocess.CompletedProcess([], 2, '', 'not due'))
        self.app.verify_served_certificate = Mock(return_value=self.app.time.time() + 30 * 86400)
        self.app.renew_certificate()
        self.app.verify_served_certificate.assert_called_once()
        self.assertTrue(self.app.load(self.app.STATE)['certificate_ok'])

    def test_nginx_webroot_and_tls_preserve_existing_protocol(self):
        cfg = self.app.nginx_config('proxy.example.com', '/ray')
        self.assertIn('location ^~ /.well-known/acme-challenge/', cfg)
        self.assertIn('proxy_pass http://127.0.0.1:10001;', cfg)
        self.assertIn('ssl_protocols TLSv1.2 TLSv1.3;', cfg)
        self.assertIn('proxy_read_timeout 3600s;', cfg)
        self.assertNotIn('listen 443', self.app.nginx_config('proxy.example.com', '/ray', tls=False))

    def test_certificate_issuance_is_webroot_not_standalone(self):
        self.app.state_update(email='owner@example.com')
        self.app.acme = Mock(return_value=subprocess.CompletedProcess([], 0, '', ''))
        with patch.object(self.app.os, 'chmod'):
            self.app.issue_certificate(staging=False)
        args = self.app.acme.call_args_list[0].args[1]
        self.assertIn('--webroot', args)
        self.assertNotIn('--standalone', args)
        self.assertNotIn('--force', args)
        self.assertIn('--reloadcmd', self.app.acme.call_args_list[1].args[1])

    def test_unknown_registration_error_cannot_trigger_new_registration(self):
        self.pending()
        self.app.verify_blocking_without_tunnel = Mock()
        def fail(args, **kwargs):
            self.commands.append(list(args))
            if args[-2:] == ['registration', 'show']:
                return subprocess.CompletedProcess(args, 1, '', 'IPC failure')
            return subprocess.CompletedProcess(args, 0, 'Disconnected', '')
        self.app.run.side_effect = fail
        with self.assertRaisesRegex(self.app.Stop, '状态查询失败'):
            self.app.connect_warp()
        self.assertFalse(any(c[-2:] == ['registration', 'new'] for c in self.commands))

    def test_prior_registration_attempt_does_not_repeat_automatically(self):
        self.pending()
        self.app.state_update(registration_attempted=True)
        self.app.verify_blocking_without_tunnel = Mock()
        def fail(args, **kwargs):
            self.commands.append(list(args))
            if args[-2:] == ['registration', 'show']:
                return subprocess.CompletedProcess(args, 1, '', 'Registration Missing')
            return subprocess.CompletedProcess(args, 0, 'Disconnected', '')
        self.app.run.side_effect = fail
        with self.assertRaisesRegex(self.app.Stop, '已尝试'):
            self.app.connect_warp()
        self.assertFalse(any(c[-2:] == ['registration', 'new'] for c in self.commands))

if __name__ == '__main__':
    unittest.main(verbosity=2)
