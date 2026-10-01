"""Real Linux controlling-terminal checks; no VPS, packages, or services touched.

Unlike mocked prompt tests, these exec the Bash entry with its Python heredoc.
The old r+ failure is reproduced inside a real PTY before testing the fix.
"""
import errno
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import unittest

if os.name == 'posix':
    import pty

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'setup_script.sh'


@unittest.skipUnless(sys.platform.startswith('linux'), 'Requires a real Linux PTY')
class TerminalTest(unittest.TestCase):
    def session(self, args, exchanges=()):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp(args[0], args)
        output = bytearray()
        pending = list(exchanges)
        status = None
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if pending and pending[0][0].encode() in output:
                    _, reply = pending.pop(0)
                    os.write(fd, reply)
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        chunk = b''
                    if chunk:
                        output.extend(chunk)
                    else:
                        break
            else:
                self.fail('PTY child timed out: ' + output.decode(errors='replace'))
            for _ in range(50):
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    pid = None
                    break
                time.sleep(0.02)
            self.assertIsNone(pid, 'PTY child did not exit')
            self.assertFalse(pending, 'Expected prompt missing: ' + output.decode(errors='replace'))
            return os.waitstatus_to_exitcode(status), output.decode(errors='replace')
        finally:
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(fd)

    def test_old_rplus_failure_is_reproduced_on_real_terminal(self):
        old = """import io
try:
    open('/dev/tty', 'r+')
except io.UnsupportedOperation as exc:
    print('REPRODUCED: ' + str(exc), flush=True)
else:
    raise SystemExit('Old failure was not reproduced')
"""
        code, output = self.session([sys.executable, '-c', old])
        self.assertEqual(code, 0, output)
        self.assertIn('REPRODUCED:', output)
        self.assertIn('seek', output)

    def test_actual_bash_heredoc_entry_reads_controlling_terminal(self):
        code, output = self.session(['bash', str(SCRIPT), 'check-terminal'],
                                    [('请输入 TERMINAL-OK', b'TERMINAL-OK\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('PASS：终端交互正常', output)

    def test_two_prompts_with_python_source_on_stdin(self):
        source = """import runpy
app = runpy.run_path(%r)['module']()
assert not app.sys.stdin.isatty()
assert app.prompt('FIRST') == 'proxy.example.com'
assert app.prompt('SECOND') == 'owner@example.com'
print('TWO PROMPTS PASS', flush=True)
""" % str(ROOT / 'tests/test_candidate.py')
        # Same stdin boundary as setup_script.sh; no network or install calls.
        command = "python3 - <<'TERMINAL_TEST'\n" + source + '\nTERMINAL_TEST\n'
        code, output = self.session(['bash', '-c', command],
                                    [('FIRST：', b'proxy.example.com\n'),
                                     ('SECOND：', b'owner@example.com\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('TWO PROMPTS PASS', output)

    def test_eof_cancels_without_success(self):
        code, output = self.session(['bash', str(SCRIPT), 'check-terminal'],
                                    [('请输入 TERMINAL-OK', b'\x04')])
        self.assertNotEqual(code, 0, output)
        self.assertIn('输入已取消', output)
        self.assertNotIn('PASS：', output)

    def test_interrupt_cancels_without_success(self):
        code, output = self.session(['bash', str(SCRIPT), 'check-terminal'],
                                    [('请输入 TERMINAL-OK', b'\x03')])
        self.assertNotEqual(code, 0, output)
        self.assertIn('操作已中断', output)
        self.assertNotIn('PASS：', output)

    def test_no_controlling_terminal_has_actionable_error(self):
        result = subprocess.run(['bash', str(SCRIPT), 'check-terminal'],
                                input='TERMINAL-OK\n', text=True,
                                capture_output=True, start_new_session=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('无法读写控制终端 /dev/tty', result.stdout)
        self.assertNotIn('PASS：', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
