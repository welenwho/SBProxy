#!/usr/bin/env python3
"""Rule-data updates must ignore rebuild noise and must not publish a plugin."""

import importlib.util
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = ROOT / ".github/scripts/rule-set-identity.py"
UPDATE = ROOT / ".github/scripts/update-sbproxy-geodata.sh"
RESOLVE = ROOT / ".github/scripts/resolve-build-packages.sh"
WORKFLOW = ROOT / ".github/workflows/Update-SBProxy.yml"

spec = importlib.util.spec_from_file_location("rule_set_identity", IDENTITY)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


SAME_RULES = {
    "version": 2,
    "rules": [{
        "domain_suffix": ["example.cn", "doubaoapps.com"],
        "domain_regex": [
            r".+\.awsdns-cn-[0-9][a-e0-9]\.cn$",
            r"^.+-mihayo\.akamaized\.net$",
        ],
    }],
}
REORDERED_RULES = {
    "version": 2,
    "rules": [{
        "domain_regex": [
            r"^.+-mihayo\.akamaized\.net$",
            r".+\.awsdns-cn-[0-9][a-e0-9]\.cn$",
        ],
        "domain_suffix": ["doubaoapps.com", "example.cn"],
    }],
}
CHANGED_RULES = {
    "version": 2,
    "rules": [{
        "domain_suffix": ["example.cn", "doubaoapps.com", "new.example"],
        "domain_regex": SAME_RULES["rules"][0]["domain_regex"],
    }],
}
SAME_IP = {"version": 2, "rules": [{"ip_cidr": ["1.0.0.0/8", "2400::/20"]}]}
REORDERED_IP = {"version": 2, "rules": [{"ip_cidr": ["2400::/20", "1.0.0.0/8"]}]}


class IdentityTests(unittest.TestCase):
    def test_regex_and_domain_order_do_not_change_identity(self):
        self.assertEqual(identity.fingerprint(SAME_RULES), identity.fingerprint(REORDERED_RULES))

    def test_added_domain_changes_identity(self):
        self.assertNotEqual(identity.fingerprint(SAME_RULES), identity.fingerprint(CHANGED_RULES))

    def test_ip_order_does_not_change_identity(self):
        self.assertEqual(identity.fingerprint(SAME_IP), identity.fingerprint(REORDERED_IP))


class UpdateScriptTests(unittest.TestCase):
    def write_tools(self, bin_dir, bodies):
        curl = bin_dir / "curl"
        curl.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            args = sys.argv[1:]
            url = args[-1]
            out = args[args.index("-o") + 1] if "-o" in args else None
            if url.endswith("/releases/latest"):
                tag = "20260202020202" if "sing-geosite" in url else "20260101010101"
                if "-w" in args:
                    sys.stdout.write("https://github.com/example/releases/tag/" + tag)
                raise SystemExit(0)
            if "gh-pages.atom" in url:
                if "metacubexd" in url:
                    stamp = "2026-05-05T05:05:05Z"
                elif "Yacd-meta" in url:
                    stamp = "2026-04-04T04:04:04Z"
                else:
                    stamp = "2026-03-03T03:03:03Z"
                sys.stdout.write("<feed>\\n<updated>%s</updated>\\n</feed>\\n" % stamp)
                raise SystemExit(0)
            mapping = json.loads(os.environ["FAKE_BODIES"])
            key = None
            if "geosite-cn.srs" in url:
                key = "geosite"
            elif "geoip-cn.srs" in url:
                key = "geoip"
            elif "metacubexd.zip" in url:
                key = "metacubexd"
            elif "yacd.zip" in url:
                key = "yacd"
            elif "dashboard.zip" in url or url.endswith(".zip"):
                key = "dashboard"
            if key is None:
                sys.stderr.write("unexpected URL: %s\\n" % url)
                raise SystemExit(1)
            data = Path(mapping[key]).read_bytes()
            if out:
                Path(out).write_bytes(data)
            raise SystemExit(0 if data else 1)
            """))
        curl.chmod(0o755)
        sing = bin_dir / "sing-box"
        sing.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            args = sys.argv[1:]
            src = args[args.index("decompile") + 1]
            dest = args[args.index("-o") + 1]
            mapping = json.loads(os.environ["FAKE_DECOMPILE"])
            key = Path(src).read_bytes().decode()
            if key not in mapping:
                sys.stderr.write("no decompile for %r\\n" % key)
                raise SystemExit(1)
            Path(dest).write_text(json.dumps(mapping[key]))
            """))
        sing.chmod(0o755)

    def run_update(self, repo, bin_dir, bodies, decompile):
        env = dict(os.environ)
        env.pop("GITHUB_OUTPUT", None)
        env.pop("GITHUB_STEP_SUMMARY", None)
        env.update({
            "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
            "REPO_ROOT": str(repo),
            "SING_BOX": str(bin_dir / "sing-box"),
            "FAKE_BODIES": json.dumps(bodies),
            "FAKE_DECOMPILE": json.dumps(decompile),
            "GEOIP_SOURCE": "https://example.test/geoip-cn.srs",
            "GEOIP_VERSION_URL": "https://example.test/sing-geoip/releases/latest",
            "GEOSITE_SOURCE": "https://example.test/geosite-cn.srs",
            "GEOSITE_VERSION_URL": "https://example.test/sing-geosite/releases/latest",
            "DASHBOARD_SOURCE": "https://example.test/dashboard.zip",
            "DASHBOARD_VERSION_URL": "https://example.test/sing-box-dashboard/commits/gh-pages.atom",
            "YACD_SOURCE": "https://example.test/yacd.zip",
            "YACD_VERSION_URL": "https://example.test/Yacd-meta/commits/gh-pages.atom",
            "METACUBEXD_SOURCE": "https://example.test/metacubexd.zip",
            "METACUBEXD_VERSION_URL": "https://example.test/metacubexd/commits/gh-pages.atom",
            "METACUBEXD_DASHBOARD_DIR": str(repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard-metacubexd"),
            "SINGBOX_DASHBOARD_DIR": str(repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard"),
            "YACD_DASHBOARD_DIR": str(repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard-yacd"),
        })
        return subprocess.run(["bash", str(UPDATE)], env=env, text=True, capture_output=True)

    def test_rebuild_noise_keeps_files_and_real_rules_replace_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            bin_dir = base / "bin"
            bin_dir.mkdir()
            repo = base / "repo"
            resources = repo / "luci-app-sbproxy/root/etc/sbproxy/resources"
            dashboard = repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard"
            yacd = repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard-yacd"
            metacubexd = repo / "luci-app-sbproxy/root/etc/sbproxy/dashboard-metacubexd"
            resources.mkdir(parents=True)
            dashboard.mkdir(parents=True)
            yacd.mkdir(parents=True)
            metacubexd.mkdir(parents=True)
            (repo / "luci-app-sbproxy/Makefile").write_text("PKG_RELEASE:=6\n")

            current_geosite = b"SRS-current-geosite"
            current_geoip = b"SRS-current-geoip"
            noise_geosite = b"SRS-reordered-geosite"
            noise_geoip = b"SRS-reordered-geoip"
            changed_geosite = b"SRS-changed-geosite"
            (resources / "geosite_cn.srs").write_bytes(current_geosite)
            (resources / "geosite_cn.ver").write_text("20260101010101\n")
            (resources / "geoip_cn.srs").write_bytes(current_geoip)
            (resources / "geoip_cn.ver").write_text("20260101010101\n")
            (dashboard / "index.html").write_text("<html>old</html>\n")
            (dashboard / "dashboard.ver").write_text("20260101010101\n")
            (yacd / "index.html").write_text("<html>yacd</html>\n")
            (yacd / "dashboard.ver").write_text("20260101010101\n")
            (metacubexd / "index.html").write_text("<html>xd</html>\n")
            (metacubexd / "dashboard.ver").write_text("20260101010101\n")

            dash_zip = base / "dashboard.zip"
            with zipfile.ZipFile(dash_zip, "w") as archive:
                archive.writestr("sing-box-dashboard/index.html", "<html>old</html>\n")
            yacd_zip = base / "yacd.zip"
            with zipfile.ZipFile(yacd_zip, "w") as archive:
                archive.writestr("Yacd-meta-gh-pages/index.html", "<html>yacd-new</html>\n")
            xd_zip = base / "metacubexd.zip"
            with zipfile.ZipFile(xd_zip, "w") as archive:
                archive.writestr("metacubexd-gh-pages/index.html", "<html>xd-new</html>\n")
            noise_geoip_file = base / "geoip.srs"
            noise_geoip_file.write_bytes(noise_geoip)
            noise_geosite_file = base / "geosite.srs"
            noise_geosite_file.write_bytes(noise_geosite)
            self.write_tools(bin_dir, {})
            decompile = {
                current_geosite.decode(): SAME_RULES,
                noise_geosite.decode(): REORDERED_RULES,
                changed_geosite.decode(): CHANGED_RULES,
                current_geoip.decode(): SAME_IP,
                noise_geoip.decode(): REORDERED_IP,
            }
            bodies = {
                "geosite": str(noise_geosite_file),
                "geoip": str(noise_geoip_file),
                "dashboard": str(dash_zip),
                "yacd": str(yacd_zip),
                "metacubexd": str(xd_zip),
            }
            first = self.run_update(repo, bin_dir, bodies, decompile)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            self.assertIn("geosite_cn unchanged", first.stdout)
            self.assertIn("geoip_cn unchanged", first.stdout)
            self.assertIn("SBProxy dashboard unchanged (upstream 20260303030303)", first.stdout)
            self.assertIn("SBProxy yacd: 20260404040404", first.stdout)
            self.assertIn("SBProxy metacubexd: 20260505050505", first.stdout)
            self.assertEqual((resources / "geosite_cn.srs").read_bytes(), current_geosite)
            self.assertEqual((resources / "geosite_cn.ver").read_text().strip(), "20260101010101")
            self.assertEqual((resources / "geoip_cn.ver").read_text().strip(), "20260101010101")
            self.assertEqual((dashboard / "dashboard.ver").read_text().strip(), "20260101010101")
            self.assertEqual((yacd / "dashboard.ver").read_text().strip(), "20260404040404")
            self.assertEqual((yacd / "index.html").read_text(), "<html>yacd-new</html>\n")
            self.assertEqual((metacubexd / "dashboard.ver").read_text().strip(), "20260505050505")
            self.assertEqual((metacubexd / "index.html").read_text(), "<html>xd-new</html>\n")
            self.assertEqual((repo / "luci-app-sbproxy/Makefile").read_text(), "PKG_RELEASE:=6\n")

            changed_file = base / "geosite-new.srs"
            changed_file.write_bytes(changed_geosite)
            bodies["geosite"] = str(changed_file)
            second = self.run_update(repo, bin_dir, bodies, decompile)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            self.assertIn("geosite_cn 20260202020202", second.stdout)
            self.assertEqual((resources / "geosite_cn.srs").read_bytes(), changed_geosite)
            self.assertEqual((resources / "geosite_cn.ver").read_text().strip(), "20260202020202")
            self.assertEqual((resources / "geoip_cn.srs").read_bytes(), current_geoip)
            self.assertEqual((repo / "luci-app-sbproxy/Makefile").read_text(), "PKG_RELEASE:=6\n")

    def test_workflow_does_not_bump_or_publish(self):
        workflow = WORKFLOW.read_text()
        queue = (ROOT / ".github/workflows/Daily-Maintenance-Queue.yml").read_text()
        self.assertNotIn("bump-sbproxy-release.sh", workflow)
        self.assertNotIn("Build-APK-Packages.yml", workflow)
        self.assertNotIn("build_apks", workflow)
        self.assertNotIn("Update-SBProxy.yml\n    with:\n      build_apks:", queue)


class BuildSelectionTests(unittest.TestCase):
    def test_resource_paths_are_not_package_builds(self):
        script = textwrap.dedent(r"""
            package=luci-app-sbproxy
            classify() {
                case "$1" in
                    "$package/README"|"$package/README.md"|\
                    "$package"/root/etc/sbproxy/resources/*|\
                    "$package"/root/etc/sbproxy/dashboard/*|\
                    "$package"/root/etc/sbproxy/dashboard-singbox/*|\
                    "$package"/root/etc/sbproxy/dashboard-yacd/*|\
                    "$package"/root/etc/sbproxy/dashboard-metacubexd/*) printf 'data\n' ;;
                    *) printf 'build\n' ;;
                esac
            }
            classify luci-app-sbproxy/root/etc/sbproxy/resources/geosite_cn.srs
            classify luci-app-sbproxy/root/etc/sbproxy/dashboard/index.html
            classify luci-app-sbproxy/Makefile
            """)
        result = subprocess.run(["bash", "-c", script], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ["data", "data", "build"])
        source = RESOLVE.read_text()
        self.assertIn('"$package"/root/etc/sbproxy/resources/*', source)
        self.assertIn('"$package"/root/etc/sbproxy/dashboard/*', source)
        self.assertIn('"$package"/root/etc/sbproxy/dashboard-metacubexd/*', source)

    def test_data_only_push_does_not_select_the_package(self):
        probe = subprocess.run(["bash", "-c", "mapfile -t x <<< a"], capture_output=True)
        if probe.returncode != 0:
            self.skipTest("resolve-build-packages.sh needs bash with mapfile; CI provides it")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            package = repo / "luci-app-sbproxy"
            resource = package / "root/etc/sbproxy/resources"
            resource.mkdir(parents=True)
            (package / "Makefile").write_text("PKG_NAME:=luci-app-sbproxy\nPKG_VERSION:=1.0.2\nPKG_RELEASE:=6\n")
            (resource / "geosite_cn.ver").write_text("old\n")
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "test"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
            before = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            (resource / "geosite_cn.ver").write_text("new\n")
            (package / "root/etc/sbproxy/dashboard").mkdir()
            (package / "root/etc/sbproxy/dashboard/index.html").write_text("x\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "data"], cwd=repo, check=True)
            after = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            env = dict(os.environ, REPO_ROOT=str(repo))
            env.pop("GITHUB_OUTPUT", None)
            env.pop("GITHUB_STEP_SUMMARY", None)
            result = subprocess.run(
                ["bash", str(RESOLVE), "push", before, "", after],
                cwd=repo, env=env, text=True, capture_output=True, check=True)
            self.assertIn("changed=false", result.stdout)
            self.assertIn("packages=\n", result.stdout)

            (package / "Makefile").write_text("PKG_NAME:=luci-app-sbproxy\nPKG_VERSION:=1.0.2\nPKG_RELEASE:=7\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "release"], cwd=repo, check=True)
            release = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            result = subprocess.run(
                ["bash", str(RESOLVE), "push", after, "", release],
                cwd=repo, env=env, text=True, capture_output=True, check=True)
            self.assertIn("changed=true", result.stdout)
            self.assertIn("packages=luci-app-sbproxy", result.stdout)


if __name__ == "__main__":
    unittest.main()
