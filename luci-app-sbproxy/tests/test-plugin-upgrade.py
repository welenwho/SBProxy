#!/usr/bin/env python3
"""Plugin transaction tests: no router paths, network or actual APK writes."""
from pathlib import Path
import hashlib
import os
import shlex
import subprocess
import tempfile
import unittest

MANAGER = Path(__file__).resolve().parents[1] / 'root/usr/libexec/sbproxy-core-manager'
PREFIX = MANAGER.read_text().split('action="${1:-status}"')[0]


class PluginUpgradeTests(unittest.TestCase):
    def test_target_package_must_come_from_the_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.apk'
            source.write_text('  name: luci-app-sbproxy\n  version: 1.0.1-r39\n  arch: noarch\n')
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            setup = '\nSTATE_DIR=' + shlex.quote(tmp) + '\nLOG_FILE="$STATE_DIR/log"\n'
            setup += f'''
apk() {{ [ "$1" = adbdump ] && cat "$2"; }}
asset_by_name() {{ [ "$1" = luci-app-sbproxy-1.0.1-r39.apk ] && printf '%s\\turl\\tsha256:{source_hash}\\t100\\tdate\\n' "$1"; }}
curl_to_file() {{ cp "$STATE_DIR/source.apk" "$2"; }}
prepare_plugin_package luci-app-sbproxy 1.0.1-r39 "$STATE_DIR/candidate.apk" || exit 1
! prepare_plugin_package luci-app-sbproxy 1.0.1-r38 "$STATE_DIR/missing.apk" || exit 2
printf corrupt > "$STATE_DIR/source.apk"
! prepare_plugin_package luci-app-sbproxy 1.0.1-r39 "$STATE_DIR/corrupt.apk" || exit 3
'''
            result = subprocess.run(['sh', '-c', PREFIX + setup], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((Path(tmp) / 'candidate.apk').exists())

    def test_update_files_use_ram_unless_it_is_short(self):
        for ram, on_flash in ((200 * 1024 * 1024, False), (40 * 1024 * 1024, True)):
            with self.subTest(ram=ram), tempfile.TemporaryDirectory() as state, \
                    tempfile.TemporaryDirectory(dir='/tmp') as tmp_work:
                Path(tmp_work, 'plugin-assets').write_text('assets\n')
                setup = '\nSTATE_DIR=' + shlex.quote(state) + '\nLOG_FILE="$STATE_DIR/log"\n'
                setup += 'work_dir=' + shlex.quote(tmp_work) + '\n'
                setup += 'ram_available_bytes() { echo "$RAM"; }\n'
                setup += 'place_plugin_work 20000000 || exit 1\n'
                setup += 'printf "%s\\n%s\\n%s\\n" "$work_dir" "$flash_work_bytes" "$(cat "$assets_file" 2>/dev/null)"\n'
                result = subprocess.run(['sh', '-c', PREFIX + setup], text=True, capture_output=True,
                                        env={**os.environ, 'RAM': str(ram)})
                self.assertEqual(result.returncode, 0, result.stderr)
                work, flash_bytes, assets = result.stdout.splitlines()
                if on_flash:
                    self.assertTrue(work.startswith(state + '/.work.'), work)
                    self.assertEqual(flash_bytes, '20000000')
                    self.assertEqual(assets, 'assets')
                    self.assertFalse(Path(tmp_work).exists())
                else:
                    self.assertEqual(work, tmp_work)
                    self.assertEqual(flash_bytes, '0')

    def test_matching_language_lookup_does_not_replace_plugin_asset_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp) / 'assets'
            assets.write_text('luci-app-sbproxy-1.0.1-r39.apk\tapp-url\tsha256:aaa\t7000000\t2026-10-26\n'
                              'luci-i18n-sbproxy-zh-cn-1.0.1-r39.apk\tlang-url\tsha256:bbb\t24000\t2026-10-26\n')
            setup = '\nassets_file=' + shlex.quote(str(assets)) + '\n'
            setup += '''
fetch_plugin_assets() { :; }
installed_plugin_version() { echo 1.0.1-r38; }
apk() { echo '<'; }
check_plugin_updates
'''
            result = subprocess.run(['sh', '-c', PREFIX + setup], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('asset=luci-app-sbproxy-1.0.1-r39.apk\t1.0.1-r39\tnewer\t7000000', result.stdout)
            self.assertNotIn('asset=luci-i18n', result.stdout)

    def run_upgrade(self, failure='', language=True, target='1.0.1-r39'):
        with tempfile.TemporaryDirectory() as tmp:
            setup = r'''
STATE_DIR="$TEST_ROOT"
LOG_FILE="$STATE_DIR/log"
work_dir="$STATE_DIR/work"
mkdir -p "$work_dir" "$STATE_DIR/plugin-recovery" "$STATE_DIR/plugin-packages"
: > "$STATE_DIR/rollback.apk"
current_plugin=1.0.1-r38
current_language=1.0.1-r38
installed_plugin_version() {
 case "$1" in
 luci-app-sbproxy) echo "$current_plugin" ;;
 *) [ "$LANGUAGE" = 0 ] || echo "$current_language" ;;
 esac
}
package_version() { echo 1.15.0_alpha12-r2; }
fetch_plugin_assets() { :; }
asset_by_name() { echo asset; }
ensure_persistent_storage() { echo "storage:$1"; [ "$FAILURE" != storage ]; }
plugin_asset_size() { echo 11000000; }
plugin_installed_size() {
 [ "$FAILURE" != metadata ] || return 0
 case "$1" in *language.apk) echo 52321 ;; *) echo 19794274 ;; esac
}
place_plugin_work() { echo "work:$1"; flash_work_bytes=0; }
prepare_plugin_package() {
 echo "download:$1:$2"
 [ "$FAILURE" != language ] || [ "$1" != luci-i18n-sbproxy-zh-cn ] || return 1
 echo "$2" > "$3"
}
validate_plugin_plan() { [ "$FAILURE" != dependencies ]; }
apk() {
 [ "$1" = version ] || return 0
 if [ "$3" = "$4" ]; then echo '='; elif [ "$3" = 1.0.1-r38 ] && [ "$4" = 1.0.1-r37 ]; then echo '>'; else echo '<'; fi
}
sha256sum() { echo core-unchanged; }
tar() {
 echo "config:$1"
 [ "$1" != -xzf ] || [ "$FAILURE" != restore ] || return 1
}
capture_expected_cores() { expected_instances=sing-box-c; }
install_plugin_packages() {
 echo "install:$#:$*"
 ! ls "$STATE_DIR"/rollback.* "$STATE_DIR"/plugin-* >/dev/null 2>&1 || exit 94
 [ "$FAILURE" != install ] || return 1
 current_plugin="$TARGET"; current_language="$TARGET"
}
plugin_health() { [ "$FAILURE" != health ] && [ "$FAILURE" != restore ]; }
restart_if_needed() { echo restarted; }
restart_plugin_services() { echo restarted; }
'''
            # Intercept the actual service path on the failure branch too.
            source = PREFIX.replace('/etc/init.d/rpcd reload', 'true')
            result = subprocess.run(['sh', '-c', source + setup +
                                     f'\nupgrade_plugin luci-app-sbproxy-{target}.apk'],
                                    env={**os.environ, 'TEST_ROOT': tmp, 'FAILURE': failure,
                                         'TARGET': target, 'LANGUAGE': '1' if language else '0'},
                                    text=True, capture_output=True)
            result.log = (Path(tmp) / 'log').read_text() if (Path(tmp) / 'log').exists() else ''
            return result

    def test_only_the_selected_packages_are_downloaded_before_install(self):
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = result.stdout.splitlines()
        # No copy of the installed 1.0.1-r38 packages is needed or downloaded.
        self.assertEqual([line for line in out if line.startswith('download:')],
                         ['download:luci-app-sbproxy:1.0.1-r39', 'download:luci-i18n-sbproxy-zh-cn:1.0.1-r39'])
        self.assertTrue(any(line.startswith('install:2:') for line in out), result.stdout)
        self.assertIn('upgraded=1', out)
        self.assertIn('component=plugin', out)
        self.assertIn('package_version=1.0.1-r39', out)
        # RAM only has to hold the new packages plus the configuration backup.
        self.assertEqual(out[0], f'work:{22000000 + 1048576}')
        # Flash only has to hold the installed size of both packages plus the reserve.
        self.assertIn(f'storage:{19794274 + 52321 + 2 * 1048576}', out)
        self.assertIn('config:-czf', result.log, 'Configuration is backed up before install')

    def test_downgrade_and_reinstall_are_supported(self):
        result = self.run_upgrade(target='1.0.1-r37')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('rolled_back=1', result.stdout)
        self.assertIn('previous_package_version=1.0.1-r38', result.stdout)
        self.assertIn('package_version=1.0.1-r37', result.stdout)
        self.assertNotIn('upgraded=1', result.stdout)
        result = self.run_upgrade(target='1.0.1-r38')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('upgraded=1', result.stdout)

    def test_no_translation_is_added_if_not_installed(self):
        result = self.run_upgrade(language=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('install:1:', result.stdout)
        self.assertNotIn('download:luci-i18n', result.stdout)

    def test_preflight_failure_never_installs(self):
        for failure in ('language', 'dependencies', 'storage', 'metadata'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0, failure)
            self.assertNotIn('install:', result.stdout)
        self.assertIn('error_code=plugin_dependencies', self.run_upgrade('dependencies').stdout)
        self.assertIn('error_code=insufficient_storage', self.run_upgrade('storage').stdout)

    def test_install_or_health_failure_restores_configuration_only(self):
        for failure in ('install', 'health'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('config:-xzf', result.log)
            self.assertIn('error_code=plugin_upgrade_failed', result.stdout)
            self.assertEqual(sum(line.startswith('install:') for line in result.stdout.splitlines()), 1,
                             'Packages are not rolled back')
            self.assertNotIn('automatic_rollback', result.stdout)
            self.assertNotIn('upgraded=1', result.stdout)

    def test_failed_configuration_restore_is_reported(self):
        result = self.run_upgrade('restore')
        self.assertIn('error_code=plugin_config_restore_failed', result.stdout)
        self.assertNotIn('upgraded=1', result.stdout)

    def test_install_plan_rejects_core_or_unrelated_package_changes(self):
        for plan, ok in [
            ('(1/2) Upgrading luci-app-sbproxy (a -> b)\n(2/2) Upgrading luci-i18n-sbproxy-zh-cn (a -> b)', True),
            ('(1/1) Reinstalling luci-app-sbproxy (a)', True),
            ('(1/2) Reinstalling sing-box (a)\n(2/2) Upgrading luci-app-sbproxy (a -> b)', False),
            ('(1/1) Installing libc (a)', False),
            ('(1/1) [APK unavailable, skipped] Reinstalling luci-app-sbproxy (a)', False),
            ('OK: no operations', False),
        ]:
            with tempfile.TemporaryDirectory() as tmp:
                setup = '\nwork_dir=' + shlex.quote(tmp) + '\nLOG_FILE="$work_dir/log"\n'
                setup += 'apk() { printf "%s\\n" "$PLAN"; }\nvalidate_plugin_plan test.apk\n'
                result = subprocess.run(['sh', '-c', PREFIX + setup],
                                        env={**os.environ, 'PLAN': plan}, capture_output=True)
                self.assertEqual(result.returncode == 0, ok, plan)


if __name__ == '__main__':
    unittest.main()
