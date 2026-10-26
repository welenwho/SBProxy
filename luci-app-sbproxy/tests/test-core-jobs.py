#!/usr/bin/env python3
"""Run the real detached job protocol with a fake installer in temporary paths."""
from pathlib import Path
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

MANAGER = Path(__file__).resolve().parents[1] / 'root/usr/libexec/sbproxy-core-manager'


class CoreJobTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = os.environ.copy()
        # macOS has flock(2), but no flock CLI. Match the tiny subset used here;
        # Linux CI uses the real util-linux command and inherited FD semantics.
        if not shutil.which('flock'):
            shim = self.root / 'flock'
            shim.write_text('''#!/usr/bin/env python3
import fcntl, os, sys
args = sys.argv[1:]
mode = fcntl.LOCK_EX
if '-n' in args:
    args.remove('-n'); mode |= fcntl.LOCK_NB
if '-u' in args:
    args.remove('-u'); mode = fcntl.LOCK_UN
arg = args[0]
fd = int(arg) if arg.isdigit() else os.open(arg, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, mode)
except (BlockingIOError, OSError):
    sys.exit(1)
''')
            shim.chmod(0o755)
            self.env['PATH'] = str(self.root) + os.pathsep + self.env['PATH']
        shim = self.root / 'ubus'
        shim.write_text('#!/usr/bin/env python3\n' + f'''
import json,os,subprocess,sys
from pathlib import Path
pidfile=Path({str(self.root / 'procd.pid')!r})
if sys.argv[3] == 'add':
    command=json.loads(sys.argv[4])['instances']['worker']['command']
    child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,close_fds=True)
    pidfile.write_text(str(child.pid))
elif sys.argv[3] == 'list':
    running=False
    if pidfile.exists():
        try:
            state=subprocess.check_output(['ps','-o','stat=','-p',pidfile.read_text()],stderr=subprocess.DEVNULL,text=True).strip()
            running=bool(state) and not state.startswith('Z')
        except Exception: pass
    print(json.dumps({{'fixture':{{'instances':{{'worker':{{'running':running}}}}}}}}))
''')
        shim.chmod(0o755)
        if str(self.root) not in self.env['PATH'].split(os.pathsep):
            self.env['PATH'] = str(self.root) + os.pathsep + self.env['PATH']
        source = MANAGER.read_text()
        for variable, path in [('STATE_DIR', 'core'), ('JOB_DIR', 'jobs'),
                               ('LOG_FILE', 'core.log'), ('LOCK_FILE', 'core.lock')]:
            import re
            source = re.sub(r'^' + variable + r'="[^"]*"',
                            variable + '=' + shlex.quote(str(self.root / path)), source, flags=re.M)
        prefix, main = source.split('action="${1:-status}"', 1)
        fake = '''
upgrade_core() {
    echo "$$" > "$JOB_DIR/worker-pid"
    echo attempt >> "$JOB_DIR/attempts"
    progress downloading
    while [ ! -f "$JOB_DIR/allow-finish" ]; do sleep 0.05; done
    progress installing
    if [ "$job_target" = sing-box-1.14.0-r9.apk ]; then
        emit automatic_rollback 1
        fail upgrade_failed_rolled_back 'Previous core restored.'
    fi
    progress checking_health
    sleep 0.1
    if [ "$action" = rollback ]; then emit rolled_back 1; else emit upgraded 1; fi
    emit package_version 1.14.0-r2
}
'''
        fake += '\nupgrade_plugin() { upgrade_core \"$@\"; emit component plugin; }\n'
        self.script = self.root / 'manager'
        self.script.write_text(prefix + fake + 'action="${1:-status}"' + main)
        self.script.chmod(0o755)

    def tearDown(self):
        # Do not remove job state until an outstanding fake worker has finished.
        self.wait_terminal()
        self.tmp.cleanup()

    def run_manager(self, *args):
        return subprocess.run([str(self.script), *args], text=True,
                              capture_output=True, env=self.env, timeout=10)

    def status(self, id=''):
        result = self.run_manager('operation', id)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

    def wait_terminal(self, id=''):
        if (self.root / 'jobs').exists():
            (self.root / 'jobs/allow-finish').touch()
        for _ in range(100):
            status = self.status(id)
            if status.get('operation_state') != 'running':
                return status
            time.sleep(0.03)
        self.fail('worker did not finish')

    def start(self, action='upgrade', target='sing-box-1.14.0-r2.apk', id='a' * 32):
        (self.root / 'jobs/allow-finish').unlink(missing_ok=True)
        return self.run_manager('start-' + action, target, id)

    def test_detached_success_and_recoverable_result(self):
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()['operation_state'], 'running', 'RPC must return before installer can finish')
        self.assertIn('operation_id=' + 'a' * 32, result.stdout)
        status = self.wait_terminal('a' * 32)
        self.assertEqual(status['operation_state'], 'succeeded')
        self.assertEqual(status['result_code'], '0')
        self.assertEqual(status['upgraded'], '1')
        self.assertEqual(self.status(), status, 'refresh must recover the same result')
        self.assertEqual(self.status('b' * 32)['operation_state'], 'unknown')

    def test_exclusion_and_no_duplicate_install(self):
        self.assertEqual(self.start().returncode, 0)
        self.assertIn('operation_in_progress', self.start(id='b' * 32).stdout)
        self.assertIn('operation_in_progress',
                      self.run_manager('upgrade', 'sing-box-1.14.0-r2.apk').stdout)
        self.wait_terminal()
        self.assertEqual(self.start().returncode, 0)
        self.assertEqual((self.root / 'jobs/attempts').read_text().splitlines(), ['attempt'])

    def test_rollback_and_actual_failure(self):
        self.assertEqual(self.start(action='rollback').returncode, 0)
        self.assertEqual(self.wait_terminal()['rolled_back'], '1')
        self.assertEqual(self.start(target='sing-box-1.14.0-r9.apk', id='b' * 32).returncode, 0)
        status = self.wait_terminal()
        self.assertEqual(status['operation_state'], 'failed')
        self.assertEqual(status['automatic_rollback'], '1')
        self.assertEqual(status['error_code'], 'upgrade_failed_rolled_back')

    def test_killed_worker_is_unknown_not_success(self):
        self.assertEqual(self.start().returncode, 0)
        pid_file = self.root / 'jobs/worker-pid'
        for _ in range(50):
            if pid_file.exists():
                break
            time.sleep(0.01)
        os.kill(int(pid_file.read_text()), signal.SIGKILL)
        status = self.wait_terminal()
        self.assertEqual(status['operation_state'], 'unknown')
        self.assertNotIn('upgraded', status)

    def test_plugin_and_core_share_lock_and_worker_survives_self_replacement(self):
        result = self.start(action='plugin-upgrade', target='luci-app-sbproxy-1.0.1-r39.apk')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('operation_in_progress', self.start(id='b' * 32).stdout)
        self.assertTrue((self.root / 'jobs/worker').exists())
        pid_file = self.root / 'jobs/worker-pid'
        for _ in range(100):
            if pid_file.exists():
                break
            time.sleep(0.01)
        pid = int(pid_file.read_text())
        self.assertNotEqual(os.getsid(pid), os.getsid(0), 'Worker must survive caller session termination')
        # Simulate APK overwriting the installed manager during its own update.
        original = self.script.read_text()
        self.script.write_text('#!/bin/sh\nexit 99\n')
        (self.root / 'jobs/allow-finish').touch()
        for _ in range(100):
            status = (self.root / 'jobs/status').read_text()
            if 'operation_state=succeeded' in status:
                break
            time.sleep(0.03)
        self.script.write_text(original)
        self.assertIn('operation_state=succeeded', status)
        self.assertIn('component=plugin', status)

    def test_validation_before_detach(self):
        for args in [dict(id='../untrusted'), dict(target='../../untrusted')]:
            result = self.start(**args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('invalid_target', result.stdout)
        self.assertFalse((self.root / 'jobs/status').exists())


if __name__ == '__main__':
    unittest.main()
