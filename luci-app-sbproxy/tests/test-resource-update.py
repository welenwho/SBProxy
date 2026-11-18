#!/usr/bin/env python3
"""Exercise resource selection, the cron lock and manual update results."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'root'
UPDATER = ROOT / 'etc/sbproxy/scripts/update_resources.sh'
WORKER = ROOT / 'usr/libexec/sbproxy-resource-update'


class ResourceUpdateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.run_dir = self.base / 'run'
        self.run_dir.mkdir()
        self.state_dir = self.base / 'state'
        self.resources = self.base / 'resources'
        self.curl_log = self.base / 'curl.log'
        self.env = dict(os.environ,
                        PATH=f"{self.base}:{os.environ['PATH']}",
                        RUN_DIR=str(self.run_dir),
                        RESOURCES_DIR=str(self.resources),
                        DASHBOARD_DIR=str(self.base / 'active'),
                        SINGBOX_DASHBOARD_DIR=str(self.base / 'dashboard'),
                        YACD_DASHBOARD_DIR=str(self.base / 'yacd'),
                        METACUBEXD_DASHBOARD_DIR=str(self.base / 'metacubexd'),
                        SING_BOX=str(self.executable('sing-box', '#!/bin/sh\nexit 0\n')),
                        DASHBOARD_SELECT='/usr/bin/true',
                        CURL_LOG=str(self.curl_log), ROOT=str(self.base))
        self.executable('flock', f'''#!{sys.executable}
import fcntl
import sys
try:
    fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
''')
        curl = self.executable('curl', '''#!/bin/sh
for arg do url="$arg"; done
printf '%s\\n' "$url" >> "$CURL_LOG"
case "$url" in
    */releases/latest) printf '%s\\n' 'https://example.com/releases/tag/20261118' ;;
    *.srs\\?*)
        while [ "$1" != -o ]; do shift; done
        printf 'binary rule set' > "$2" ;;
    */Yacd-meta/*.atom) printf '%s\\n' '<updated>2026-11-18T01:02:03Z</updated>' ;;
    *) exit 1 ;;
esac
''')
        self.updater = self.executable('update', UPDATER.read_text().replace('/usr/bin/curl', str(curl)))
        self.executable('uci', '#!/bin/sh\nexit 1\n')
        init = self.executable('service', '''#!/bin/sh
case "$1" in
    running) exit 0 ;;
    reload) touch "$ROOT/reloaded"; exit "${RELOAD_STATUS:-0}" ;;
esac
''')
        self.worker = self.executable('worker', WORKER.read_text()
                                     .replace('/etc/sbproxy/scripts/update_resources.sh', str(self.updater))
                                     .replace('/etc/init.d/sbproxy', str(init))
                                     .replace('/var/run/sbproxy-resource-update', str(self.state_dir))
                                     .replace('/var/run/sbproxy/sbproxy.log', str(self.run_dir / 'sbproxy.log')))

    def executable(self, name, script):
        target = self.base / name
        target.write_text(script)
        target.chmod(0o755)
        return target

    def run_script(self, script, *args):
        return subprocess.run([str(script), *args], env=self.env, capture_output=True, text=True)

    def results(self, filename):
        return dict(line.split('=', 1) for line in filename.read_text().splitlines())

    def test_single_resource_only_fetches_selected_urls_and_keeps_cron_result(self):
        cron_result = self.run_dir / 'update_resources.result'
        cron_result.write_text('status=3\n')
        self.env['RELOAD_STATUS'] = '1'
        operation = self.run_script(self.worker, 'geoip_cn', 'sample-id')
        self.assertEqual(operation.returncode, 0, operation.stderr)
        self.assertEqual(self.results(self.state_dir / 'result'),
                         dict(id='sample-id', status='0', apply_failed='1', failed=''))
        self.assertEqual(cron_result.read_text(), 'status=3\n')
        self.assertEqual(len(self.curl_log.read_text().splitlines()), 2)
        self.assertTrue(all('sing-geoip' in url for url in self.curl_log.read_text().splitlines()))
        self.assertEqual((self.resources / 'geoip_cn.ver').read_text().strip(), '20261118')
        self.assertFalse((self.resources / 'geosite_cn.ver').exists())
        self.assertTrue((self.base / 'reloaded').exists())
        current = self.run_script(self.worker, 'geoip_cn', 'next-id')
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertEqual(self.results(self.state_dir / 'result')['status'], '3')

    def test_no_arguments_updates_all_and_keeps_partial_success(self):
        result = self.run_script(self.updater)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.results(self.run_dir / 'update_resources.result'), dict(
            status='4', core_updated='1', dashboard_updated='0', updated='geoip_cn,geosite_cn',
            failed='dashboard,yacd,metacubexd'))

    def test_single_dashboard_failure_checks_only_that_dashboard(self):
        result = self.run_script(self.worker, 'yacd', 'sample-id')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.results(self.state_dir / 'result'),
                         dict(id='sample-id', status='1', apply_failed='0', failed='yacd'))
        self.assertTrue(all('Yacd-meta' in url for url in self.curl_log.read_text().splitlines()))
        self.assertFalse((self.base / 'reloaded').exists())

    def test_cron_lock_reports_busy_without_downloading_or_reloading(self):
        with (self.run_dir / 'update_resources.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script(self.worker, 'geosite_cn', 'sample-id')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.results(self.state_dir / 'result'),
                         dict(id='sample-id', status='2', apply_failed='0'))
        self.assertFalse(self.curl_log.exists())
        self.assertFalse((self.base / 'reloaded').exists())


if __name__ == '__main__':
    unittest.main()
