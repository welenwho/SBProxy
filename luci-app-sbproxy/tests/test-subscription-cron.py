#!/usr/bin/env python3
"""Exercise cron updates without touching the host scheduler or killing jobs."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


INIT = Path(__file__).resolve().parents[1] / 'root/etc/init.d/sbproxy'


class SubscriptionCronTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.crontab = self.root / 'root'
        self.other = '17 3 * * * /usr/bin/unrelated-task\n'
        self.crontab.write_text(self.other)
        # Intercept the old implementation too: a regression must never invoke
        # the host's cron service while running this test.
        cron = self.root / 'cron-service'
        cron.write_text('#!/bin/sh\necho "$*" >> "$TEST_ROOT/service-calls"\n')
        cron.chmod(0o755)
        source = INIT.read_text()
        functions = source[source.index('validate_cron_number() {'):
                           source.index('sync_subscription_cron() {')]
        functions = functions.replace('/etc/init.d/cron', str(cron))
        self.script = self.root / 'configure.sh'
        self.script.write_text('''#!/bin/sh
set -eu
CRON_FILE="$TEST_ROOT/root"
CRON_LOCK="$TEST_ROOT/cron.lock"
CRON_TAG='#sbproxy_autosetup'
SB_DIR=/etc/sbproxy
lock() { :; }
log() { echo "$*" >&2; }
''' + functions + '\nconfigure_subscription_cron "$@"\n')

    def configure(self, enabled, schedule='0 */6 * * *'):
        subprocess.run(['sh', str(self.script), str(enabled), schedule],
                       env={**os.environ, 'TEST_ROOT': str(self.root)},
                       check=True, capture_output=True, text=True)
        self.assertFalse((self.root / 'service-calls').exists(),
                         'Reloading crond can kill the subscription restart job')

    def test_restart_removes_then_restores_schedule_without_restarting_crond(self):
        self.configure(1)
        expected = self.other + ('0 */6 * * * /etc/sbproxy/scripts/'
                                 'update_crond.sh #sbproxy_autosetup\n')
        self.assertEqual(self.crontab.read_text(), expected)
        self.configure(0)
        self.assertEqual(self.crontab.read_text(), self.other)
        self.configure(1)
        self.assertEqual(self.crontab.read_text(), expected)
        self.assertEqual((self.root / 'cron.update').read_text(), 'root\n' * 3)
        self.assertEqual(self.crontab.stat().st_mode & 0o777, 0o600)

    def test_unchanged_schedule_does_not_notify_again(self):
        self.configure(1)
        notification = self.root / 'cron.update'
        notification.unlink()  # Simulate crond consuming the notification.
        self.configure(1)
        self.assertFalse(notification.exists())

    def test_preserves_pending_notifications_for_other_users(self):
        notification = self.root / 'cron.update'
        notification.write_text('another-user\n')
        self.configure(1)
        self.assertEqual(notification.read_text(), 'another-user\nroot\n')


if __name__ == '__main__':
    unittest.main()
