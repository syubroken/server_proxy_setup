"""Route-shape regressions. Kernel behavior is tested separately in a netns."""
import json
import subprocess
import unittest
from unittest.mock import Mock, patch
from test_candidate import module


class RouteTest(unittest.TestCase):
    def setUp(self):
        self.app = module()
        self.tables = {'-4': [], '-6': []}
        self.app.run = Mock(side_effect=lambda args: subprocess.CompletedProcess(
            args, 0, json.dumps(self.tables[args[1]]), ''))

    def test_ra_expiry_and_status_are_not_replayed(self):
        self.tables['-6'] = [{'dst': 'default', 'gateway': 'fe80::1', 'dev': 'eth0',
                              'protocol': 'ra', 'metric': 1024, 'pref': 'medium',
                              'expires': 1700, 'flags': ['linkdown'], 'metrics': [{'mtu': 1500}]}]
        command = self.app.native_route_plan()['-6'][0]
        self.assertNotIn('expires', command)
        self.assertNotIn('linkdown', command)
        self.assertEqual(command[command.index('via') + 1], 'fe80::1')
        self.assertEqual(command[command.index('mtu') + 1], '1500')
        self.assertEqual(command[command.index('proto') + 1], 'static')

    def test_gateway_dependencies_precede_default_and_onlink_is_retained(self):
        self.tables['-4'] = [
            {'dst': 'default', 'gateway': '192.0.2.1', 'dev': 'eth0', 'flags': ['onlink']},
            {'dst': '192.0.2.1', 'dev': 'eth0', 'scope': 'link', 'prefsrc': '192.0.2.10'}]
        plan = self.app.native_route_plan()['-4']
        self.assertIn('192.0.2.1', plan[0])
        self.assertNotIn('via', plan[0])
        self.assertIn('onlink', plan[1])
        self.assertIn('src', plan[0])

    def test_existing_warp_route_is_not_a_native_route(self):
        self.tables['-6'] = [{'dst': 'default', 'dev': 'CloudflareWARP'}]
        self.assertEqual(self.app.native_route_plan()['-6'], [])

    def test_multipath_or_locked_metrics_are_not_silently_discarded(self):
        for extra in ({'nexthops': [{'gateway': '192.0.2.1'}]}, {'metrics': [{'mtu': 'lock 1400'}]}):
            with self.subTest(extra=extra):
                self.tables['-4'] = [{'dst': 'default', 'dev': 'eth0', **extra}]
                with self.assertRaises(self.app.Stop):
                    self.app.native_route_plan()

    def test_failed_plan_leaves_existing_management_rules_untouched(self):
        app = module()
        app.load = lambda _: {'network': {'dev': 'eth0'}, 'ssh': {'server': '192.0.2.10'}}
        app.run = Mock(return_value=subprocess.CompletedProcess([], 0,
            '[{"addr_info":[{"local":"192.0.2.10"}]}]', ''))
        app.native_route_plan = Mock(side_effect=app.Stop('unsupported'))
        app.clear_own_routes = Mock()
        with self.assertRaisesRegex(app.Stop, 'unsupported'):
            app.management_routes()
        app.clear_own_routes.assert_not_called()

    def test_ip_failure_retains_parser_reason_and_redacts_addresses(self):
        app = module()
        error = 'Error: argument "1798sec" is wrong: "expires" value is invalid. 192.0.2.1 fe80::1\n'
        with patch.object(app.subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, '', error)):
            with self.assertRaises(app.Stop) as raised:
                app.run(['ip', '-6', 'route', 'replace', 'table', '51881', 'default'])
        message = str(raised.exception)
        self.assertIn('ip -6 route replace', message)
        self.assertIn('expires', message)
        self.assertNotIn('192.0.2.1', message)
        self.assertNotIn('fe80::1', message)


if __name__ == '__main__':
    unittest.main(verbosity=2)
