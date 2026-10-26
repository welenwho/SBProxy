#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile
import unittest

MANAGER = Path(__file__).resolve().parents[1] / 'root/usr/libexec/sbproxy-core-manager'
SOURCE = MANAGER.read_text().split('action="${1:-status}"')[0]


class HealthWindowTests(unittest.TestCase):
    def test_restart_validates_new_ports_after_config_regeneration(self):
        for refresh_success in (True, False):
            script = SOURCE.replace('/etc/init.d/sbproxy restart', 'restart_fixture') + '''
LOG_FILE=/dev/null
restarted=0
restart_fixture() { restarted=1; }
refresh_runtime_health_plan() { [ "$restarted" = 1 ] || return 97; echo refreshed; return %d; }
wait_for_service() { echo checked; }
restart_if_needed 1
''' % (0 if refresh_success else 1)
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, refresh_success)
            self.assertEqual(result.stdout.splitlines(),
                             ['refreshed', 'checked'] if refresh_success else ['refreshed'])

    def check(self, body):
        with tempfile.TemporaryDirectory() as tmp:
            script = SOURCE + '\nLOG_FILE=/dev/null\nsleep() { :; }\n' + body + '\nwait_for_service\n'
            return subprocess.run(['sh', '-c', script], cwd=tmp, text=True, capture_output=True)

    def test_auxiliary_service_cannot_make_health_pass(self):
        result = self.check('service_running() { return 0; }\nhealth_signature() { return 1; }')
        self.assertNotEqual(result.returncode, 0)

    def test_stable_core_passes(self):
        self.assertEqual(self.check('health_signature() { echo core-pid-start; }').returncode, 0)

    def test_empty_health_response_is_rejected(self):
        self.assertNotEqual(self.check('health_signature() { return 0; }').returncode, 0)

    def test_continuous_restarts_do_not_pass(self):
        result = self.check('health_signature() { n=$(cat counter 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > counter; echo "pid-$n"; }')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__': unittest.main()
