#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
REMOVED = (
    'gecoosac',
    'luci-app-gecoosac',
    'luci-app-wolultra',
    'wolultra',
)
KEPT = {'luci-app-sbproxy', 'sing-box'}


class PackageSourcesTests(unittest.TestCase):
    def test_repository_keeps_only_sbproxy_packages(self):
        packages = {
            path.parent.name
            for path in ROOT.glob('*/Makefile')
            if path.parent.parent == ROOT and not path.parent.name.startswith('.')
        }
        self.assertEqual(packages, KEPT)
        for name in REMOVED:
            self.assertFalse((ROOT / name).exists(), name)

        metadata = (ROOT / '.github' / 'package-sources.tsv').read_text()
        for name in REMOVED:
            self.assertNotIn(name, metadata)

    def test_prebuilt_core_uses_own_release_repository(self):
        makefile = (ROOT / 'sing-box' / 'Makefile').read_text()
        self.assertIn(
            'https://github.com/welenwho/packages/releases/download/'
            'sbproxy-core-v$(CORE_PIN_VERSION)',
            makefile,
        )


if __name__ == '__main__':
    unittest.main()
