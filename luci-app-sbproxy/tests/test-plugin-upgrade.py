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
    def cache_command(self, root, command):
        setup = '\nSTATE_DIR=' + shlex.quote(str(root)) + '\n'
        setup += 'LOG_FILE="$STATE_DIR/log"\n'
        setup += '''
apk() { [ "$1" = adbdump ] && cat "$2"; }
prepare_plugin_package() { return 1; }
'''
        return subprocess.run(['sh', '-c', PREFIX + setup + command],
                              text=True, capture_output=True)

    def cached_package(self, root, name='luci-app-sbproxy', version='1.0.1-r38',
                       metadata_name=None, metadata_version=None, arch='noarch'):
        path = Path(root) / 'plugin-packages' / f'{name}-{version}.apk'
        path.parent.mkdir(exist_ok=True)
        path.write_text(f'  name: {metadata_name or name}\n'
                        f'  version: {metadata_version or version}\n  arch: {arch}\n')
        Path(str(path) + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n')
        return path

    def test_cached_current_packages_survive_release_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('luci-app-sbproxy', 'luci-i18n-sbproxy-zh-cn'):
                cached = self.cached_package(tmp, name=name)
                result = self.cache_command(tmp,
                    f'prepare_plugin_recovery {name} 1.0.1-r38 "$STATE_DIR/recovery.apk"')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((Path(tmp) / 'recovery.apk').read_bytes(), cached.read_bytes())
            # A valid cached package cannot replace a missing release target.
            result = self.cache_command(tmp,
                'prepare_plugin_package luci-app-sbproxy 1.0.1-r38 "$STATE_DIR/target.apk"')
            self.assertNotEqual(result.returncode, 0)

    def test_cached_recovery_rejects_corruption_and_wrong_metadata(self):
        for invalid in ('contents', 'digest', 'missing_digest', 'name', 'version', 'arch'):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as tmp:
                cached = self.cached_package(tmp,
                    metadata_name='unrelated' if invalid == 'name' else None,
                    metadata_version='1.0.1-r37' if invalid == 'version' else None,
                    arch='wrong' if invalid == 'arch' else 'noarch')
                if invalid == 'contents':
                    cached.write_text('corrupt')
                elif invalid == 'digest':
                    Path(str(cached) + '.sha256').write_text('bad\n')
                elif invalid == 'missing_digest':
                    Path(str(cached) + '.sha256').unlink()
                result = self.cache_command(tmp,
                    'prepare_plugin_recovery luci-app-sbproxy 1.0.1-r38 "$STATE_DIR/recovery.apk"')
                self.assertNotEqual(result.returncode, 0, invalid)

    def test_download_is_cached_before_install_and_pruning_keeps_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            for version in ('1.0.1-r36', '1.0.1-r37', '1.0.1-r38'):
                self.cached_package(tmp, version=version)
            source = self.cached_package(tmp, version='1.0.1-r39')
            source.rename(Path(tmp) / 'source.apk')
            source_hash = hashlib.sha256((Path(tmp) / 'source.apk').read_bytes()).hexdigest()
            Path(str(source) + '.sha256').unlink()
            unrelated = Path(tmp) / 'plugin-packages' / 'unrelated.apk'
            unrelated.write_text('keep')
            setup = '\nSTATE_DIR=' + shlex.quote(tmp) + '\nLOG_FILE="$STATE_DIR/log"\n'
            setup += f'''
apk() {{ [ "$1" = adbdump ] && cat "$2"; }}
asset_by_name() {{ printf '%s\\turl\\tsha256:{source_hash}\\t100\\tdate\\n' "$1"; }}
curl_to_file() {{ cp "$STATE_DIR/source.apk" "$2"; }}
prepare_plugin_package luci-app-sbproxy 1.0.1-r39 "$STATE_DIR/candidate.apk" || exit 1
plugin_target_version=1.0.1-r39
previous=1.0.1-r38
plugin_language_version=1.0.1-r38
prune_plugin_cache
'''
            result = subprocess.run(['sh', '-c', PREFIX + setup], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sorted(p.name for p in unrelated.parent.glob('*.apk')),
                ['luci-app-sbproxy-1.0.1-r38.apk', 'luci-app-sbproxy-1.0.1-r39.apk', 'unrelated.apk'])
            self.assertEqual(Path(str(source) + '.sha256').read_text().strip(), source_hash)

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

    def run_upgrade(self, failure='', language=True):
        with tempfile.TemporaryDirectory() as tmp:
            setup = r'''
STATE_DIR="$TEST_ROOT"
LOG_FILE="$STATE_DIR/log"
work_dir="$STATE_DIR/work"
mkdir -p "$work_dir"
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
ensure_persistent_storage() { [ "$FAILURE" != storage ]; }
prepare_plugin_package() {
 echo "download:$1:$2"
 [ "$FAILURE" != recovery ] || [ "$2" != 1.0.1-r38 ] || return 1
 [ "$FAILURE" != language ] || [ "$1" != luci-i18n-sbproxy-zh-cn ] || return 1
 echo "$2" > "$3"
}
validate_plugin_plan() { [ "$FAILURE" != dependencies ]; }
apk() { [ "$1" = version ] && echo '<'; }
sha256sum() { echo core-unchanged; }
tar() { echo "config:$1"; }
capture_expected_cores() { expected_instances=sing-box-c; }
install_plugin_packages() {
 if [ "$1" = "$STATE_DIR/plugin-recovery/plugin.apk" ]; then
  echo rollback
  [ "$FAILURE" != rollback ] || return 1
  current_plugin=1.0.1-r38; current_language=1.0.1-r38
 else
  echo "install:$#"
  test -f "$STATE_DIR/plugin-recovery/plugin.apk" || exit 92
  [ "$LANGUAGE" = 0 ] || test -f "$STATE_DIR/plugin-recovery/language.apk" || exit 93
  [ "$FAILURE" != install ] || return 1
  current_plugin=1.0.1-r39; current_language=1.0.1-r39
 fi
}
plugin_health() { [ "$FAILURE" != health ] && [ "$FAILURE" != rollback ]; }
restart_if_needed() { echo restarted; }
restart_plugin_services() { echo restarted; }
'''
            # Intercept the actual service path on the rollback branch too.
            source = PREFIX.replace('/etc/init.d/rpcd reload', 'true')
            result = subprocess.run(['sh', '-c', source + setup +
                                     '\nupgrade_plugin luci-app-sbproxy-1.0.1-r39.apk'],
                                    env={**os.environ, 'TEST_ROOT': tmp, 'FAILURE': failure,
                                         'LANGUAGE': '1' if language else '0'},
                                    text=True, capture_output=True)
            result.log = (Path(tmp) / 'log').read_text() if (Path(tmp) / 'log').exists() else ''
            return result

    def test_both_packages_and_recovery_prepared_before_install(self):
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('install:2', result.stdout)
        self.assertLess(result.stdout.index('download:luci-i18n-sbproxy-zh-cn:1.0.1-r38'),
                        result.stdout.index('install:'))
        self.assertIn('component=plugin', result.stdout)
        self.assertIn('package_version=1.0.1-r39', result.stdout)

    def test_no_translation_is_added_if_not_installed(self):
        result = self.run_upgrade(language=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('install:1', result.stdout)
        self.assertNotIn('download:luci-i18n', result.stdout)

    def test_preflight_failure_never_installs(self):
        for failure in ('recovery', 'language', 'dependencies', 'storage'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0, failure)
            self.assertNotIn('install:', result.stdout)

    def test_partial_install_and_health_failure_restore_packages_and_config(self):
        for failure in ('install', 'health'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('automatic_rollback=1', result.stdout)
            self.assertIn('config:-xzf', result.log)
            self.assertIn('plugin_upgrade_rolled_back', result.stdout)

    def test_failed_recovery_is_not_reported_as_success(self):
        result = self.run_upgrade('rollback')
        self.assertIn('automatic_rollback=0', result.stdout)
        self.assertIn('plugin_recovery_failed', result.stdout)
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
