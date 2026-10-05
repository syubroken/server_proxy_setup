"""Timeout/evidence checks; Linux cases use real process locks, never WARP."""
import contextlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from test_candidate import module


class StartupTest(unittest.TestCase):
    def setUp(self):
        self.app = module()
        self.temp = tempfile.TemporaryDirectory()
        self.app.BASE = Path(self.temp.name)
        self.app.STATE = self.app.BASE / 'state.json'
        self.app.STATE.write_text('{}')
        self.app.PENDING = self.app.BASE / 'pending.json'
        self.app.say = Mock()

    def tearDown(self):
        self.temp.cleanup()

    def test_command_timeout_records_phase_and_does_not_leak_output(self):
        started = time.monotonic()
        with self.assertRaisesRegex(self.app.Stop, 'TimeoutExpired'):
            with self.app.step('cli-ready'):
                self.app.run([sys.executable, '-c',
                              'import time; print("SECRET",flush=True); time.sleep(30)'], timeout=0.3)
        self.assertLess(time.monotonic() - started, 4)
        rows = self.app.recent_steps()
        self.assertEqual([r['event'] for r in rows], ['start', 'failed'])
        self.assertNotIn('SECRET', (self.app.BASE / 'steps.jsonl').read_text())

    def test_phase_survives_new_reader_and_records_success(self):
        with self.app.step('service-start'):
            pass
        reader = module()
        reader.BASE = self.app.BASE
        self.assertEqual([(r['step'], r['event']) for r in reader.recent_steps()],
                         [('service-start', 'start'), ('service-start', 'done')])
        if os.name == 'posix':
            self.assertEqual((self.app.BASE / 'steps.jsonl').stat().st_mode & 0o777, 0o600)

    def test_recent_steps_rejects_unknown_fields_values_and_partial_records(self):
        log = self.app.BASE / 'steps.jsonl'
        valid = {'at': '2026-10-06T10:00:00+00:00', 'pid': 12, 'step': 'connect', 'event': 'start'}
        records = [{**valid, 'secret': 'SECRET'}, {**valid, 'step': 'SECRET'},
                   {**valid, 'event': ['SECRET']}, {**valid, 'at': 'SECRET'}, [], None]
        log.write_text('\n'.join(json.dumps(r) for r in records) + '\n{"partial":')
        self.assertEqual(self.app.recent_steps(), [valid])

    def test_logging_failure_does_not_interrupt_work_or_recovery(self):
        with patch.object(self.app.os, 'open', side_effect=OSError('disk unavailable')):
            with self.app.step('connect'):
                reached = True
        self.assertTrue(reached)

    def test_no_log_created_without_initialization(self):
        self.app.STATE.unlink()
        self.app.record_step('connect', 'start')
        self.assertFalse((self.app.BASE / 'steps.jsonl').exists())

    def test_broken_ssh_output_does_not_raise_before_recovery(self):
        app = module()
        for error in (BrokenPipeError(), OSError(5, 'Input/output error')):
            output = Mock()
            output.write.side_effect = error
            with patch.object(app.sys, 'stdout', output):
                app.say('停止：准备恢复')

    def test_service_timeouts_keep_guard_requirement(self):
        units = {}
        self.app.unit_write = lambda name, content: units.update({name: content})
        self.app.write_units()
        self.assertIn('TimeoutStartSec=60', units['sps-guard.service'])
        dropin = units['warp-svc.service.d/50-sps-guard.conf']
        self.assertIn('Requires=sps-guard.service', dropin)
        self.assertIn('TimeoutStartSec=45', dropin)
        self.assertIn('TimeoutStopSec=40', dropin)

    def test_cli_failure_identifies_stage_and_never_reaches_registration(self):
        for name in ('nft_apply', 'management_routes', 'verify_blocking_without_tunnel', 'assert_transaction'):
            setattr(self.app, name, Mock())
        commands = []
        def run(args, **kwargs):
            commands.append(args)
            if args[0] == 'warp-cli':
                raise self.app.Stop('command timeout')
            return subprocess.CompletedProcess(args, 0, '', '')
        self.app.run = run
        with self.assertRaisesRegex(self.app.Stop, 'command timeout'):
            self.app.connect_warp()
        self.assertEqual([(r['step'], r['event']) for r in self.app.recent_steps()], [
            ('guard', 'start'), ('guard', 'done'), ('service-start', 'start'),
            ('service-start', 'done'), ('cli-ready', 'start'), ('cli-ready', 'failed')])
        self.assertFalse(any('registration' in command for command in commands))

    @contextlib.contextmanager
    def held_lock(self):
        code = ('import fcntl,sys; f=open(sys.argv[1],"a"); '
                'fcntl.flock(f,fcntl.LOCK_EX); print("held",flush=True); sys.stdin.read(1)')
        with subprocess.Popen([sys.executable, '-c', code, str(self.app.BASE / 'transaction.lock')],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            try:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, 'lock holder did not start')
                self.assertEqual(process.stdout.readline().strip(), 'held')
                yield process
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=3)

    @unittest.skipUnless(os.name == 'posix', 'needs actual Linux flock')
    def test_old_blocking_flock_stalls_but_new_wait_is_bounded_and_preserves_lock(self):
        with self.held_lock():
            path = self.app.BASE / 'transaction.lock'
            inode = path.stat().st_ino
            code = ('import fcntl,sys; f=open(sys.argv[1],"a"); '
                    'fcntl.flock(f,fcntl.LOCK_EX); print("unexpected")')
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run([sys.executable, '-c', code, str(path)],
                               timeout=0.3, capture_output=True, check=False)
            started = time.monotonic()
            with self.assertRaisesRegex(self.app.Stop, '锁等待超时'):
                with self.app.lock('transaction.lock', nonblocking=False, timeout=0.3):
                    self.fail('must not enter a held transaction')
            self.assertLess(time.monotonic() - started, 2)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual([r['event'] for r in self.app.recent_steps()], ['waiting', 'timeout'])

    @unittest.skipUnless(os.name == 'posix', 'needs actual Linux flock')
    def test_waiter_continues_after_holder_exits_and_releases_on_exception(self):
        with self.held_lock() as holder:
            timer = threading.Timer(0.2, lambda: (holder.stdin.write('x'), holder.stdin.flush()))
            timer.start()
            try:
                with self.assertRaisesRegex(ValueError, 'body failed'):
                    with self.app.lock('transaction.lock', nonblocking=False, timeout=3):
                        raise ValueError('body failed')
                # Both holder and failed body must have released the real lock.
                with self.app.lock('transaction.lock'):
                    pass
            finally:
                timer.join(timeout=3)
        self.assertEqual([r['event'] for r in self.app.recent_steps()], ['waiting', 'acquired'])

    @unittest.skipUnless(os.name == 'posix', 'needs actual Linux flock')
    def test_watchdog_returns_on_contention_and_can_retry_recovery(self):
        self.app.require_root = lambda: None
        self.app.boot_id = lambda: 'current'
        self.app.PENDING.write_text(json.dumps({'boot_id': 'current', 'deadline': 1}))
        self.app.safe_stop_locked = Mock()
        real_lock = self.app.lock
        self.app.lock = lambda name, nonblocking: real_lock(name, nonblocking, timeout=0.2)
        with self.held_lock():
            with self.assertRaisesRegex(self.app.Stop, '锁等待超时'):
                self.app.deadline_check()
            self.app.safe_stop_locked.assert_not_called()
            self.assertTrue(self.app.PENDING.exists())
        self.app.deadline_check()
        self.app.safe_stop_locked.assert_called_once_with('deadline-expired')


if __name__ == '__main__':
    unittest.main(verbosity=2)
