#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = (ROOT / 'sing-box/Makefile').read_text()
VERSION = re.search(r'^PKG_VERSION:=(.*)$', MAKEFILE, re.M)[1]
REVISION = int(re.search(r'^PKG_RELEASE:=(\d+)$', MAKEFILE, re.M)[1])
spec = importlib.util.spec_from_file_location('core_release', ROOT / '.github/scripts/core-release.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class CoreReleaseTests(unittest.TestCase):
    def test_fingerprint_excludes_generated_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            shutil.copytree(ROOT / 'sing-box', target / 'sing-box')
            shutil.copytree(ROOT / '.github', target / '.github')
            with patch.object(core, 'ROOT', target):
                before = core.fingerprint()
                (target / 'sing-box/core-prebuilt.mk').write_text('CORE_PIN_VERSION:=1.14.0-r2\n')
                mf = target / 'sing-box/Makefile'
                mf.write_text(re.sub(r'^PKG_RELEASE:=.*$', 'PKG_RELEASE:=999', mf.read_text(), flags=re.M))
                self.assertEqual(before, core.fingerprint())
                p = target / 'sing-box/patches/test.patch'
                p.write_text('new patch')
                self.assertNotEqual(before, core.fingerprint())

    def test_first_release_does_not_reuse_firmware_version(self):
        upstream = dict(tag_name='v' + VERSION, draft=False, prerelease=False)
        with patch.object(core, 'api', return_value=upstream), \
             patch.object(core, 'releases', return_value=[]), \
             patch.object(core, 'output') as out:
            core.resolve()
            self.assertEqual(out.call_args.kwargs['revision'], 1)
            self.assertEqual(out.call_args.kwargs['tag'], f'sbproxy-core-v{VERSION}')
            self.assertNotIn('-r', out.call_args.kwargs['tag'])
            self.assertEqual(out.call_args.kwargs['build'], 'true')

    def test_prerelease_is_rejected(self):
        with patch.object(core, 'api', return_value=dict(tag_name='v1.15.0-rc.1', draft=False, prerelease=True)):
            with self.assertRaises(ValueError):
                core.resolve()

    def test_retention_keeps_five_newest_and_pinned_release(self):
        tags = [f'sbproxy-core-v1.14.{index}' for index in range(3, 8)]
        tags += [f'sbproxy-core-v1.14.{index}-r1' for index in range(3)]
        tags.append('sbproxy-core-v1.13.0-r9')
        tags.append('apk-packages-arm64')
        kept, stale, newest = core.select_retained(
            tags, protected=('sbproxy-core-v1.13.0-r9',))
        self.assertEqual(newest, 'sbproxy-core-v1.14.7')
        self.assertEqual(kept[:5], [
            'sbproxy-core-v1.14.7',
            'sbproxy-core-v1.14.6',
            'sbproxy-core-v1.14.5',
            'sbproxy-core-v1.14.4',
            'sbproxy-core-v1.14.3',
        ])
        self.assertIn('sbproxy-core-v1.13.0-r9', kept)
        self.assertIn('sbproxy-core-v1.14.0-r1', stale)
        self.assertNotIn('apk-packages-arm64', stale)
        higher_revision, _, _ = core.select_retained([
            'sbproxy-core-v1.14.3', 'sbproxy-core-v1.14.3-r10',
            'sbproxy-core-v1.14.10'])
        self.assertEqual(higher_revision[0], 'sbproxy-core-v1.14.10')

    def test_release_workflow_publishes_latest_and_retains_five(self):
        workflow = (ROOT / '.github/workflows/Update-Sing-Box.yml').read_text()
        queue = (ROOT / '.github/workflows/Daily-Maintenance-Queue.yml').read_text()
        self.assertIn('core-release.py retain', workflow)
        self.assertIn('--prerelease --latest=false', workflow)
        self.assertIn('--latest', workflow)
        self.assertIn('--title "SBProxy core $VERSION"', workflow)
        self.assertNotIn('$VERSION-r$REVISION', workflow)
        self.assertIn("cron: '17 18 * * *'", queue)
        self.assertIn("cron: '47 6 * * *'", queue)
        self.assertNotIn("cron: '0 18 * * *'", queue)
        self.assertIn('channel: alpha', queue)

    def test_alpha_channel_selects_numeric_latest_and_never_pins(self):
        upstream = [dict(tag_name='v' + v, draft=False, prerelease=True) for v in
                    ('1.15.0-alpha.9', '1.15.0-alpha.12', '1.15.0-rc.1')]
        upstream += [dict(tag_name='v1.15.0-alpha.99', draft=True, prerelease=True)]
        with patch.object(core, 'api', return_value=upstream), \
             patch.object(core, 'releases', return_value=[]), \
             patch.object(core, 'output') as out:
            core.resolve('alpha')
        self.assertEqual(out.call_args.kwargs['version'], '1.15.0-alpha.12')
        self.assertEqual(out.call_args.kwargs['build'], 'true')
        self.assertEqual(out.call_args.kwargs['publish_needed'], 'true')
        self.assertEqual(out.call_args.kwargs['pin_needed'], 'false')

    def test_published_alpha_is_immutable(self):
        release = dict(tag_name='sbproxy-core-v1.15.0-alpha.12', draft=False, prerelease=True)
        upstream = [dict(tag_name='v1.15.0-alpha.12', draft=False, prerelease=True)]
        for fingerprint in ('old', core.fingerprint()):
            with patch.object(core, 'api', return_value=upstream), \
                 patch.object(core, 'releases', return_value=[release]), \
                 patch.object(core, 'manifest_of', return_value=dict(fingerprint=fingerprint)), \
                 patch.object(core, 'output') as out:
                core.resolve('alpha')
            self.assertEqual(out.call_args.kwargs['build'], 'false')
            self.assertEqual(out.call_args.kwargs['publish_needed'], 'false')
            self.assertEqual(out.call_args.kwargs['pin_needed'], 'false')

    def test_alpha_names_and_ordering(self):
        self.assertEqual(core.apk_version('1.15.0-alpha.12'), '1.15.0_alpha12')
        self.assertEqual(core.parse_core_tag('sbproxy-core-v1.15.0-alpha.12'), ('1.15.0-alpha.12', None))
        tags = ['sbproxy-core-v1.15.0-alpha.9', 'sbproxy-core-v1.15.0-alpha.12', 'sbproxy-core-v1.15.0']
        self.assertEqual(core.select_retained(tags)[0], list(reversed(tags)))
        for invalid in ('1.15.0-alpha.0', '1.15.0-alpha.x', '../../bad', '1.15.0-rc.1'):
            with self.assertRaises(ValueError):
                core.apk_version(invalid)

    def test_retention_keeps_channels_separate_and_only_stable_latest(self):
        published = [dict(tag_name=f'sbproxy-core-v1.14.{i}', prerelease=False) for i in range(7)]
        published += [dict(tag_name=f'sbproxy-core-v1.15.0-alpha.{i}', prerelease=True) for i in range(1, 8)]
        with patch.object(core, 'releases', return_value=published), \
             patch.object(core, 'read_pin', return_value={}), \
             patch.object(core.subprocess, 'run') as run:
            core.retain()
        deleted = [c.args[0][3] for c in run.call_args_list if c.args[0][2] == 'delete']
        self.assertEqual(set(deleted), {'sbproxy-core-v1.14.0', 'sbproxy-core-v1.14.1',
                                       'sbproxy-core-v1.15.0-alpha.1', 'sbproxy-core-v1.15.0-alpha.2'})
        self.assertEqual(run.call_args.args[0][3], 'sbproxy-core-v1.14.6')

    def test_alpha_cannot_be_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'manifest.json'
            path.write_text(json.dumps(dict(version='1.15.0-alpha.12', revision=1)))
            with self.assertRaisesRegex(ValueError, 'stable firmware pin'):
                core.pin(path)

    def test_prepare_alpha_keeps_upstream_tag_but_normalizes_apk_version(self):
        version = '1.15.0-alpha.12'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'sing-box').mkdir()
            makefile = root / 'sing-box/Makefile'
            makefile.write_text(MAKEFILE)
            archive = root / 'sbproxy-core-source.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                data = b'require github.com/sagernet/tailscale v1.2.3-alpha-dependency\n'
                member = tarfile.TarInfo(f'sing-box-{version}/go.mod')
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
            with patch.object(core, 'ROOT', root), \
                 patch.dict(os.environ, RUNNER_TEMP=tmp), \
                 patch.object(core.subprocess, 'run') as download:
                core.prepare(version, '1')
            prepared = makefile.read_text()
            self.assertIn('PKG_UPSTREAM_VERSION:=1.15.0-alpha.12\n', prepared)
            self.assertIn('PKG_VERSION:=1.15.0_alpha12\n', prepared)
            self.assertIn('TAILSCALE_MODULE_VERSION:=v1.2.3-alpha-dependency\n', prepared)
            self.assertIn('https://codeload.github.com/SagerNet/sing-box/tar.gz/v1.15.0-alpha.12',
                          download.call_args.args[0])

    def test_published_version_is_not_rebuilt_with_revision(self):
        release = dict(tag_name='sbproxy-core-v1.14.3', draft=False, prerelease=False,
                       assets=[dict(name='core-manifest.json', browser_download_url='https://example.test')])
        real_check = subprocess.check_output
        def check(command, **kw):
            if command[0] == 'curl':
                return json.dumps(dict(fingerprint='different', package_version='1.14.3'))
            return real_check(command, **kw)
        with patch.object(core, 'api', return_value=dict(tag_name='v1.14.3', draft=False, prerelease=False)), \
             patch.object(core, 'releases', return_value=[release]), \
             patch.object(core.subprocess, 'check_output', side_effect=check), \
             patch.object(core, 'output') as out:
            core.resolve()
            self.assertEqual(out.call_args.kwargs['build'], 'false')
            self.assertEqual(out.call_args.kwargs['tag'], 'sbproxy-core-v1.14.3')
            self.assertEqual(out.call_args.kwargs['pin_needed'], 'false')

    def test_pin_retry_reuses_published_artifact(self):
        release = dict(tag_name='sbproxy-core-v1.14.0-r2', draft=False, prerelease=False,
                       assets=[dict(name='core-manifest.json', browser_download_url='https://example.test')])
        real_check = subprocess.check_output
        def check(command, **kw):
            if command[0] == 'curl':
                return json.dumps(dict(fingerprint=core.fingerprint()))
            return real_check(command, **kw)
        with patch.object(core, 'api', return_value=dict(tag_name='v1.14.0', draft=False, prerelease=False)), \
             patch.object(core, 'releases', return_value=[release]), \
             patch.object(core.subprocess, 'check_output', side_effect=check), \
             patch.object(core, 'output') as out:
            core.resolve()
            self.assertEqual(out.call_args.kwargs['build'], 'false')
            self.assertEqual(out.call_args.kwargs['tag'], release['tag_name'])

    def make_values(self, arch='aarch64', variant='full', pinned=True, force=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'include').mkdir()
            (root / 'rules.mk').write_text('INCLUDE_DIR:=$(TOPDIR)/include\nBUILD_DIR:=$(TOPDIR)/build\n')
            (root / 'include/package.mk').write_text('')
            go = root / 'feeds/packages/lang/golang'
            go.mkdir(parents=True)
            (go / 'golang-package.mk').write_text('GO_ARCH_DEPENDS:=@aarch64||x86_64||mips\n')
            shutil.copyfile(ROOT / 'sing-box/Makefile', root / 'Makefile')
            (root / 'print.mk').write_text('show:\n\t@echo source=$(PKG_SOURCE) deps=$(PKG_BUILD_DEPENDS) prebuilt=$(CORE_PREBUILT)\n')
            if pinned:
                (root / 'core-prebuilt.mk').write_text(
                    f'CORE_PIN_VERSION:={VERSION}-r{REVISION}\nCORE_SHA256_arm64:=' + 'a'*64 +
                    '\nCORE_SHA256_amd64:=' + 'b'*64 + '\n')
            return subprocess.check_output(['make', '-s', '-f', 'Makefile', '-f', 'print.mk',
                                            f'TOPDIR={root}', f'ARCH={arch}', f'BUILD_VARIANT={variant}',
                                            'SBPROXY_CORE_SOURCE_BUILD=' + ('1' if force else '0'), 'show'],
                                           cwd=root, text=True)

    def test_version_only_pin_uses_upstream_archive_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'include').mkdir()
            (root / 'rules.mk').write_text('INCLUDE_DIR:=$(TOPDIR)/include\nBUILD_DIR:=$(TOPDIR)/build\n')
            (root / 'include/package.mk').write_text('')
            go = root / 'feeds/packages/lang/golang'
            go.mkdir(parents=True)
            (go / 'golang-package.mk').write_text('GO_ARCH_DEPENDS:=@aarch64||x86_64||mips\n')
            shutil.copyfile(ROOT / 'sing-box/Makefile', root / 'Makefile')
            (root / 'print.mk').write_text('show:\n\t@echo source=$(PKG_SOURCE) prebuilt=$(CORE_PREBUILT)\n')
            (root / 'core-prebuilt.mk').write_text(
                f'CORE_PIN_VERSION:={VERSION}\nCORE_SHA256_arm64:=' + 'a' * 64 + '\n')
            values = subprocess.check_output(
                ['make', '-s', '-f', 'Makefile', '-f', 'print.mk', f'TOPDIR={root}',
                 'ARCH=aarch64', 'BUILD_VARIANT=full', 'show'], cwd=root, text=True)
        self.assertIn(f'source=sing-box-{VERSION}-linux-arm64.tar.gz', values)
        self.assertIn('prebuilt=' + 'a' * 64, values)

    def test_prebuilt_skips_go_dependency(self):
        for arch, archive_arch in [('aarch64', 'arm64'), ('x86_64', 'amd64')]:
            values = self.make_values(arch)
            self.assertIn(f'linux-{archive_arch}.tar.gz', values)
            self.assertNotIn('golang/host', values)

    def test_fallbacks_compile_from_source(self):
        for options in [dict(pinned=False), dict(force=True), dict(variant='tiny'), dict(arch='mips')]:
            values = self.make_values(**options)
            self.assertIn(f'source=sing-box-{VERSION}.tar.gz', values)
            self.assertIn('deps=golang/host', values)


if __name__ == '__main__':
    unittest.main()
