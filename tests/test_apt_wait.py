"""Real Debian APT locks in private directories; no host packages are changed."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def helper(path):
    text = path.read_text(encoding='utf-8')
    return text.split('# BEGIN APT WAIT\n', 1)[1].split('# END APT WAIT', 1)[0]


@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('apt-get'), 'Requires Debian APT')
class AptWaitTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sps-apt-lock-')
        self.root = Path(self.temp.name)
        self.helper = helper(ROOT / 'legacy/setup_script_fixed.sh')
        # Shorten only the test copy's retry interval, not the production wait budget.
        self.helper = self.helper.replace('sleep 5', 'sleep 0.1')
        for name in ('lists/partial', 'archives/partial', 'conf.d', 'sources.d'):
            (self.root / name).mkdir(parents=True)
        (self.root / 'status').touch()
        (self.root / 'sources.list').touch()
        config = self.root / 'apt.conf'
        config.write_text(
            f'Dir::Etc::Parts "{self.root}/conf.d";\nDir::Etc::main "-";\n'
            f'Dir::Etc::sourcelist "{self.root}/sources.list";\n'
            f'Dir::Etc::sourceparts "{self.root}/sources.d";\n'
            f'Dir::State::status "{self.root}/status";\n'
            f'Dir::State::lists "{self.root}/lists";\n'
            f'Dir::Cache::archives "{self.root}/archives";\n'
            f'Dir::Cache::pkgcache "{self.root}/pkgcache.bin";\n'
            f'Dir::Cache::srcpkgcache "{self.root}/srcpkgcache.bin";\n'
            f'Dir::Log "{self.root}";\n')
        self.env = {**os.environ, 'APT_CONFIG': str(config)}

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, args, code=None):
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + (code or self.helper)
                               + '\napt_wait "$@"\n', 'apt-test', *args],
                              env=self.env, text=True, capture_output=True, timeout=12)

    def test_standalone_installers_share_lock_handling(self):
        self.assertEqual(helper(ROOT / 'setup_script.sh'), helper(ROOT / 'legacy/setup_script_fixed.sh'))

    def held_lock(self, filename, action):
        import fcntl
        lockpath = self.root / filename
        with open(lockpath, 'w') as lock:
            inode = lockpath.stat().st_ino
            fcntl.lockf(lock, fcntl.LOCK_EX)
            p = subprocess.Popen(['bash', '-c', 'set -euo pipefail\n' + self.helper
                                  + '\napt_wait "$@"\n', 'apt-test', action],
                                 env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                # The helper must encounter the real lock, rather than only a mock return code.
                import select
                ready, _, _ = select.select([p.stdout], [], [], 8)
                self.assertTrue(ready, 'APT did not report the held lock')
                first = p.stdout.readline()
                self.assertIn('自动等待', first)
                self.assertIsNone(p.poll())
                fcntl.lockf(lock, fcntl.LOCK_UN)
                rest = p.communicate(timeout=8)[0]
                self.assertEqual(p.returncode, 0, first + rest)
                self.assertEqual(lockpath.stat().st_ino, inode, 'Lock file must not be deleted')
            finally:
                if p.poll() is None:
                    p.kill()
                    p.communicate()

    def test_real_frontend_lock_releases_and_install_continues(self):
        self.held_lock('lock-frontend', 'install')

    def test_real_lists_lock_releases_and_update_continues(self):
        self.held_lock('lists/lock', 'update')

    def test_real_lock_timeout_keeps_lock_and_returns_failure(self):
        import fcntl
        path = self.root / 'lock-frontend'
        with open(path, 'w') as lock:
            inode = path.stat().st_ino
            fcntl.lockf(lock, fcntl.LOCK_EX)
            p = self.invoke(['install'], self.helper.replace('>= 600', '>= 0'))
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('不要删除锁', p.stderr)
            self.assertEqual(path.stat().st_ino, inode)

    def test_non_lock_failure_does_not_wait_or_retry(self):
        p = self.invoke(['install', 'sps-impossible-package-fixture'])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('Unable to locate package', p.stderr)
        self.assertNotIn('自动等待', p.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
