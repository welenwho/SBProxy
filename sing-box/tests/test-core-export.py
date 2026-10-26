#!/usr/bin/env python3
"""Export contract tests, including an SDK with its build_dir removed."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\nset -eu\n' + text)
    path.chmod(0o755)


class ExportTests(unittest.TestCase):
    def export(self, failure='', version='1.14.0'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixture = root / 'fixture'
            executable(fixture / 'usr/bin/sing-box', '''
case "$1" in
version)
  echo "sing-box version $TEST_VERSION"
  echo 'Tags: with_acme,with_clash_api,with_dhcp,with_gvisor,with_quic,with_tailscale,with_utls'
  [ "$FAILURE" = tags ] || echo 'with_wireguard'
  ;;
api) echo 'List Tailscale peer subnet routes';;
check) true;;
esac
''')
            config = fixture / 'etc/sing-box/config.json'
            config.parent.mkdir(parents=True)
            config.write_text('{}')
            sdk = root / 'sdk'
            executable(sdk / 'staging_dir/host/bin/apk', '''
if [ "$1" = adbdump ]; then echo '  arch: x86_64'; else cp -R "$FIXTURE/." "$4/"; fi
''')
            executable(root / 'bin/readelf', '''
if [ "$FAILURE" = dynamic ]; then echo 'INTERP NEEDED'; else echo 'No dynamic dependencies'; fi
''')
            source = root / 'sbproxy-core-source.tar.gz'
            with tarfile.open(source, 'w:gz') as archive:
                data = b'GPL-3.0-or-later test license\n'
                info = tarfile.TarInfo(f'sing-box-{version}/LICENSE')
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            checksum = hashlib.sha256(source.read_bytes()).hexdigest()
            (root / 'sing-box').mkdir()
            (root / 'sing-box/Makefile').write_text(
                'PKG_HASH:=' + checksum + '\nTAILSCALE_MODULE_VERSION:=v1.0.0\n')
            if failure == 'hash':
                source.write_bytes(b'tampered archive')
            scripts = root / '.github/scripts'
            scripts.mkdir(parents=True)
            shutil.copy(ROOT / '.github/scripts/core-release.py', scripts)
            apk_output = root / 'apk-output'
            apk_output.mkdir()
            (apk_output / ('sing-box-' + version.replace('-alpha.', '_alpha') + '-r2.apk')).write_bytes(b'fake package')
            output = root / 'out'
            env = dict(os.environ, FIXTURE=str(fixture), FAILURE=failure,
                       RUNNER_TEMP=tmp, CORE_SOURCE_SHA='a' * 40,
                       TEST_VERSION=version, PATH=str(root / 'bin') + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / '.github/scripts/export-core.sh'),
                                     str(sdk), str(apk_output), str(output), 'amd64', version, '2'],
                                    cwd=root, env=env, capture_output=True, text=True)
            if not failure:
                self.assertTrue((output / 'core-amd64.json').is_file(), result.stdout + result.stderr)
                with tarfile.open(output / f'sing-box-{version}-linux-amd64.tar.gz') as archive:
                    self.assertEqual(archive.extractfile(f'sing-box-{version}-linux-amd64/LICENSE').read(), data)
                self.assertTrue((output / f'sing-box-{version}-amd64.apk').is_file())
                self.assertFalse((output / f'sing-box-{version}-r2-amd64.apk').exists())
            return result

    def test_export_after_sdk_source_cleanup(self):
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_alpha_export_uses_apk_name_and_preserves_upstream_version(self):
        result = self.export(version='1.15.0-alpha.12')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_dynamic_core_rejected(self):
        result = self.export('dynamic')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dynamic ELF interpreter', result.stderr)

    def test_missing_tag_is_identified(self):
        result = self.export('tags')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing core tag: with_wireguard', result.stderr)

    def test_source_hash_failure_reports_stage(self):
        result = self.export('hash')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('source-license', result.stderr)


if __name__ == '__main__':
    unittest.main()
