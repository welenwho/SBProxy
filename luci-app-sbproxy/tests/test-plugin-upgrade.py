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

    def test_downloads_are_not_cached_and_pruning_keeps_requested_versions(self):
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
prune_plugin_cache 1.0.1-r38 ''
'''
            result = subprocess.run(['sh', '-c', PREFIX + setup], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sorted(p.name for p in unrelated.parent.glob('*.apk')),
                ['luci-app-sbproxy-1.0.1-r38.apk', 'unrelated.apk'])
            self.assertTrue((Path(tmp) / 'candidate.apk').exists())

    def cache_installed(self, tmp, free_bytes, language=True):
        work = Path(tmp) / 'work'
        work.mkdir()
        (work / 'plugin.apk').write_bytes(b'p' * 3000)
        (work / 'language.apk').write_bytes(b'l' * 100)
        setup = '\nSTATE_DIR=' + shlex.quote(tmp) + '\nLOG_FILE="$STATE_DIR/log"\n'
        setup += 'work_dir="$STATE_DIR/work"\nplugin_target_version=1.0.1-r39\n'
        setup += 'plugin_language_version=' + ('1.0.1-r39' if language else "''") + '\n'
        setup += 'ensure_persistent_storage() { echo "storage:$1" >> "$STATE_DIR/requests"; [ "$1" -le "$FREE" ]; }\n'
        setup += 'cache_installed_plugin\n'
        result = subprocess.run(['sh', '-c', PREFIX + setup], text=True, capture_output=True,
                                env={**os.environ, 'FREE': str(free_bytes)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cache = Path(tmp) / 'plugin-packages'
        names = sorted(p.name for p in cache.glob('*.apk')) if cache.exists() else []
        log = (Path(tmp) / 'log').read_text() if (Path(tmp) / 'log').exists() else ''
        return names, log, (Path(tmp) / 'requests').read_text().split()

    def test_installed_packages_are_cached_only_with_spare_flash(self):
        reserve = 8 * 1024 * 1024
        with tempfile.TemporaryDirectory() as tmp:
            names, log, requests = self.cache_installed(tmp, 100 * 1024 * 1024)
            self.assertEqual(names, ['luci-app-sbproxy-1.0.1-r39.apk', 'luci-i18n-sbproxy-zh-cn-1.0.1-r39.apk'])
            self.assertEqual(requests, [f'storage:{3000 + reserve}', f'storage:{100 + reserve}'])
            digest = (Path(tmp) / 'plugin-packages/luci-app-sbproxy-1.0.1-r39.apk.sha256').read_text().strip()
            self.assertEqual(digest, hashlib.sha256(b'p' * 3000).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            names, log, _ = self.cache_installed(tmp, reserve + 1000)
            self.assertEqual(names, ['luci-i18n-sbproxy-zh-cn-1.0.1-r39.apk'])
            self.assertIn('Not caching luci-app-sbproxy 1.0.1-r39', log)
        with tempfile.TemporaryDirectory() as tmp:
            names, _, requests = self.cache_installed(tmp, 100 * 1024 * 1024, language=False)
            self.assertEqual(names, ['luci-app-sbproxy-1.0.1-r39.apk'])
            self.assertEqual(len(requests), 1)

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

    def run_upgrade(self, failure='', language=True):
        with tempfile.TemporaryDirectory() as tmp:
            setup = r'''
STATE_DIR="$TEST_ROOT"
LOG_FILE="$STATE_DIR/log"
work_dir="$STATE_DIR/work"
mkdir -p "$work_dir" "$STATE_DIR/plugin-recovery"
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
prune_plugin_cache() { echo "prune:$*"; }
cache_installed_plugin() { echo cached; }
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
 if [ "$1" = "$work_dir/recovery/plugin.apk" ]; then
  echo rollback
  [ "$FAILURE" != rollback ] || return 1
  current_plugin=1.0.1-r38; current_language=1.0.1-r38
 else
  echo "install:$#"
  test -f "$work_dir/recovery/plugin.apk" || exit 92
  [ "$LANGUAGE" = 0 ] || test -f "$work_dir/recovery/language.apk" || exit 93
  ! test -e "$STATE_DIR/plugin-recovery" || exit 94
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
        out = result.stdout.splitlines()
        # Stale copies go first, then the RAM estimate for both versions' packages.
        self.assertEqual(out[:2], ['prune:1.0.1-r38 1.0.1-r38', f'work:{22000000 * 2 + 1048576}'])
        # Flash only has to hold the installed size of both packages plus the reserve.
        self.assertIn(f'storage:{19794274 + 52321 + 2 * 1048576}', out)
        self.assertLess(out.index('install:2'), out.index('prune:1.0.1-r39'))
        self.assertLess(out.index('prune:1.0.1-r39'), out.index('cached'))

    def test_no_translation_is_added_if_not_installed(self):
        result = self.run_upgrade(language=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('install:1', result.stdout)
        self.assertNotIn('download:luci-i18n', result.stdout)

    def test_preflight_failure_never_installs(self):
        for failure in ('recovery', 'language', 'dependencies', 'storage', 'metadata'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0, failure)
            self.assertNotIn('install:', result.stdout)
            self.assertNotIn('cached', result.stdout)
        self.assertIn('error_code=plugin_dependencies', self.run_upgrade('dependencies').stdout)
        self.assertIn('error_code=insufficient_storage', self.run_upgrade('storage').stdout)

    def test_partial_install_and_health_failure_restore_packages_and_config(self):
        for failure in ('install', 'health'):
            result = self.run_upgrade(failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('automatic_rollback=1', result.stdout)
            self.assertIn('config:-xzf', result.log)
            self.assertIn('plugin_upgrade_rolled_back', result.stdout)
            self.assertNotIn('cached', result.stdout)

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
