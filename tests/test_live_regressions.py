"""Regressions derived from the 2026-10-06 Vultr run; no live mutation here."""
import copy
import subprocess
import unittest
from unittest.mock import Mock, patch
from test_candidate import module


class LiveRegressions(unittest.TestCase):
    def setUp(self):
        self.app = module()

    def test_both_official_exclusions_must_be_verified(self):
        for text in ('Included routes:\n  0.0.0.0/0\n  ::/0\n',
                     'Excluded routes:\n  0.0.0.0/0\n',
                     'Excluded routes:\n  0.0.0.0/1\n  ::/0\n'):
            self.app.run = Mock(return_value=subprocess.CompletedProcess([], 0, text, ''))
            with self.assertRaises(self.app.Stop):
                self.app.verify_native_split()
        self.app.run = Mock(return_value=subprocess.CompletedProcess([], 0,
            'Excluded routes:\n  10.0.0.0/8\n  0.0.0.0/0 (CLI exclude)\n  ::/0 (CLI exclude)\n', ''))
        self.app.configure_native_split()
        self.assertEqual(self.app.run.call_count, 3)

    def test_failed_exclusion_never_proceeds_to_verification(self):
        self.app.run = Mock(side_effect=self.app.Stop('CLI failed'))
        self.app.verify_native_split = Mock()
        with self.assertRaises(self.app.Stop):
            self.app.configure_native_split()
        self.app.verify_native_split.assert_not_called()

    def ufw(self):
        entries = []
        for family, prefix in [('ip', 'ufw-'), ('ip6', 'ufw6-')]:
            entries += [{'table': {'family': family, 'name': 'filter'}},
                        {'chain': {'family': family, 'table': 'filter', 'name': 'INPUT'}},
                        {'chain': {'family': family, 'table': 'filter', 'name': prefix + 'user-input'}},
                        {'rule': {'family': family, 'table': 'filter', 'chain': 'INPUT',
                                  'expr': [{'counter': {'packets': 2, 'bytes': 100}},
                                           {'jump': {'target': prefix + 'user-input'}}]}}]
        return {'nftables': entries}

    def test_ufw_is_retained_only_when_its_tables_are_isolated(self):
        base = self.ufw()
        self.assertTrue(self.app.reviewed_ufw_rules(base))
        for extra in ({'table': {'family': 'inet', 'name': 'other'}},
                      {'chain': {'family': 'ip', 'table': 'filter', 'name': 'custom'}},
                      {'rule': {'family': 'ip', 'table': 'filter', 'chain': 'INPUT', 'expr': [{'drop': None}]}},
                      {'table': {'family': 'ip', 'name': 'nat'}}):
            altered = copy.deepcopy(base)
            altered['nftables'].append(extra)
            self.assertFalse(self.app.reviewed_ufw_rules(altered))

    def test_boot_waits_for_both_saved_address_and_default(self):
        self.app.load = lambda _: {'ssh': {'server': '192.0.2.10'}, 'network': {'dev': 'eth0'}}
        self.app.run = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, '[]', ''),
            subprocess.CompletedProcess([], 0, '[]', ''),
            subprocess.CompletedProcess([], 0, '[{"addr_info":[{"local":"192.0.2.10"}]}]', ''),
            subprocess.CompletedProcess([], 0, '[{"dev":"eth0","gateway":"192.0.2.1"}]', '')])
        with patch.object(self.app.time, 'sleep') as sleep:
            self.app.wait_native_network()
            sleep.assert_called_once()

    def test_boot_refuses_a_different_address_without_network_mutation(self):
        self.app.load = lambda _: {'ssh': {'server': '192.0.2.10'}, 'network': {'dev': 'eth0'}}
        self.app.run = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, '[{"addr_info":[{"local":"192.0.2.99"}]}]', ''),
            subprocess.CompletedProcess([], 0, '[{"dev":"eth0","gateway":"192.0.2.1"}]', '')])
        with self.assertRaises(self.app.Stop):
            self.app.wait_native_network(seconds=0)
        self.assertEqual(self.app.run.call_count, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
