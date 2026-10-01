"""No real credentials or network: safe DNS credential refresh regressions."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('refresh', ROOT / 'tools/refresh_cf_global_key.py')
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)

OLD = 'old-test-key-not-a-real-credential'
NEW = 'new-test-key-not-a-real-credential'


class RefreshTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.account = self.home / 'account.conf'
        self.domain = self.home / 'example.com_ecc' / 'example.com.conf'
        self.domain.parent.mkdir()
        self.account.write_text("export CF_Key='%s'\nSAVED_CF_Key='%s'\nCF_Email='owner@example.com'\n" % (OLD, OLD))
        self.domain.write_text("Le_Webroot='dns_cf'\nLe_RealFullChainPath='/etc/v2ray/v2ray.crt'\nLe_ReloadCmd='unchanged'\n")

    def tearDown(self):
        self.temp.cleanup()

    def test_updates_both_key_forms_without_touching_certificate_settings(self):
        text = self.account.read_text() + 'CF_Key="' + OLD + '"\n'
        updated = app.replacement(text, {'CF_Key': NEW, 'SAVED_CF_Key': NEW})
        self.assertNotIn(OLD, updated)
        parsed = app.settings(updated)
        self.assertEqual(parsed['CF_Key'], NEW)
        self.assertEqual(parsed['SAVED_CF_Key'], NEW)
        self.assertIn("CF_Email='owner@example.com'", updated)
        originals, _, _, _, _ = app.inspect(self.home, 'example.com')
        before = self.domain.read_bytes()
        backup = app.commit_changes(self.home, originals, {self.account: updated.encode()})
        self.assertEqual(self.domain.read_bytes(), before)
        self.assertEqual((backup / '0-account.conf').read_bytes(), originals[self.account])
        if os.name == 'posix':
            self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
            self.assertEqual(self.account.stat().st_mode & 0o777, 0o600)
            self.assertEqual((backup / '0-account.conf').stat().st_mode & 0o777, 0o600)

    def test_rejects_token_in_either_account_or_domain(self):
        for target in (self.account, self.domain):
            original = target.read_text()
            target.write_text(original + "CF_Token='fixture-token'\n")
            with self.assertRaises(app.Stop):
                app.inspect(self.home, 'example.com')
            target.write_text(original)

    def test_rejects_non_dns_mode_and_custom_home(self):
        self.domain.write_text("Le_Webroot='no'\n")
        with self.assertRaises(app.Stop):
            app.inspect(self.home, 'example.com')
        self.domain.write_text("Le_Webroot='dns_cf'\n")
        self.account.write_text("ACCOUNT_CONF_PATH='/another/account.conf'\n")
        with self.assertRaises(app.Stop):
            app.inspect(self.home, 'example.com')

    def test_does_not_evaluate_dynamic_shell_values(self):
        with self.assertRaises(app.Stop):
            app.settings('CF_Key=$(echo never-execute)')
        with self.assertRaises(app.Stop):
            app.settings('CF_Key=abc; touch something')

    def test_concurrent_configuration_change_is_not_overwritten(self):
        originals, _, _, _, _ = app.inspect(self.home, 'example.com')
        self.account.write_text('changed by another process\n')
        with self.assertRaises(app.Stop):
            app.commit_changes(self.home, originals, {self.account: b'replacement\n'})
        self.assertEqual(self.account.read_text(), 'changed by another process\n')

    def test_partial_write_and_interrupt_restore_originals(self):
        for error in (OSError('fixture'), KeyboardInterrupt()):
            originals, _, _, _, _ = app.inspect(self.home, 'example.com')

            def fail_second(path, data):
                app.private_write(path, data)
                if path == self.domain:
                    raise error

            with self.assertRaises(app.Stop):
                app.commit_changes(self.home, originals,
                                   {self.account: b'new-account', self.domain: b'new-domain'}, writer=fail_second)
            self.assertEqual(self.account.read_bytes(), originals[self.account])
            self.assertEqual(self.domain.read_bytes(), originals[self.domain])

    def test_cloudflare_request_is_get_to_official_host_only(self):
        response = io.BytesIO(json.dumps({'success': True, 'result': [{'name': 'example.com'}]}).encode())
        opener = Mock()
        opener.open.return_value = response
        with patch.object(app.urllib.request, 'build_opener', return_value=opener):
            app.verify_cloudflare('owner@example.com', NEW, 'example.com')
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), 'GET')
        self.assertEqual(request.full_url, 'https://api.cloudflare.com/client/v4/zones?name=example.com')
        self.assertEqual(request.get_header('X-auth-key'), NEW)
        self.assertIsNone(app.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com'))

    def test_authentication_error_never_exposes_key(self):
        opener = Mock()
        opener.open.side_effect = OSError('sensitive fixture ' + NEW)
        with patch.object(app.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaises(app.Stop) as caught:
                app.verify_cloudflare('owner@example.com', NEW, 'example.com')
        self.assertNotIn(NEW, str(caught.exception))

    def test_unsuccessful_response_or_missing_zone_is_rejected(self):
        for payload in ({'success': False}, {'success': True, 'result': []}):
            opener = Mock()
            opener.open.return_value = io.BytesIO(json.dumps(payload).encode())
            with patch.object(app.urllib.request, 'build_opener', return_value=opener):
                with self.assertRaises(app.Stop):
                    app.verify_cloudflare('owner@example.com', NEW, 'example.com')

    @unittest.skipUnless(sys.platform.startswith('linux') and getattr(os, 'geteuid', lambda: -1)() == 0,
                         'Requires disposable Linux root PTY test environment')
    def test_real_terminal_hides_key_and_updates_without_network(self):
        import test_terminal as terminal_tests
        harness = f'''import runpy
from pathlib import Path
scope = runpy.run_path({str(ROOT / 'tools/refresh_cf_global_key.py')!r}, run_name='cf_terminal_test')
scope['main'].__globals__['Path'] = lambda value: Path({str(self.home)!r}) if value == '/root/.acme.sh' else Path(value)
def verify(email, key, zone):
    assert email == 'owner@example.com' and key == {NEW!r} and zone == 'example.com'
scope['main'].__globals__['verify_cloudflare'] = verify
scope['main'](['example.com', 'example.com'])
'''
        check = terminal_tests.TerminalTest('test_actual_bash_heredoc_entry_reads_controlling_terminal')
        code, output = check.session([sys.executable, '-c', harness],
                                     [('留空沿用已保存的邮箱）：', b'\n'),
                                      ('勿粘贴 API Token）：', (NEW + '\n').encode())])
        self.assertEqual(code, 0, output)
        self.assertIn('PASS：', output)
        self.assertNotIn(NEW, output)
        self.assertEqual(app.settings(self.account.read_text())['CF_Key'], NEW)


if __name__ == '__main__':
    unittest.main(verbosity=2)
