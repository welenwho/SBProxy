#!/bin/sh

set -eu

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$PACKAGE_ROOT/.." && pwd)"
BUMP_SCRIPT="$REPO_ROOT/.github/scripts/bump-sbproxy-release.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sbproxy-release-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT INT TERM

version="$(sed -n 's/^PKG_VERSION:=//p' "$PACKAGE_ROOT/Makefile")"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$PACKAGE_ROOT/Makefile")"
new_release=$((release + 1))
cache_version="$(printf '%s\n' "$version" | sed 's/[^A-Za-z0-9_-]/-/g')"
old_cache_key="${cache_version}-r${release}"
new_cache_key="${cache_version}-r${new_release}"

mkdir -p \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d"
cp -p "$PACKAGE_ROOT/Makefile" "$TEST_ROOT/luci-app-sbproxy/Makefile"
cp -p "$PACKAGE_ROOT/root/usr/share/luci/menu.d/luci-app-sbproxy.json" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
cp -p "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client.js"
cp -p "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/tailscale.js"
cp -p "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/core.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/core.js"
cp -P "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client-${old_cache_key}.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client-${old_cache_key}.js"
cp -P "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale-${old_cache_key}.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/tailscale-${old_cache_key}.js"
cp -P "$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/core-${old_cache_key}.js" \
	"$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/core-${old_cache_key}.js"

REPO_ROOT="$TEST_ROOT" "$BUMP_SCRIPT"

test "$(sed -n 's/^PKG_VERSION:=//p' "$TEST_ROOT/luci-app-sbproxy/Makefile")" = "$version"
test "$(sed -n 's/^PKG_RELEASE:=//p' "$TEST_ROOT/luci-app-sbproxy/Makefile")" = "$new_release"
test ! -e "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client-${old_cache_key}.js"
test ! -L "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client-${old_cache_key}.js"
test ! -e "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/tailscale-${old_cache_key}.js"
test ! -L "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/tailscale-${old_cache_key}.js"
test ! -e "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/core-${old_cache_key}.js"
test ! -L "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/core-${old_cache_key}.js"
test "$(readlink "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client-${new_cache_key}.js")" = \
	'client.js'
test "$(readlink "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/tailscale-${new_cache_key}.js")" = \
	'tailscale.js'
test "$(readlink "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/core-${new_cache_key}.js")" = \
	'core.js'
grep -Fq "\"path\": \"sbproxy/client-${new_cache_key}\"" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
grep -Fq "\"path\": \"sbproxy/tailscale-${new_cache_key}\"" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
grep -Fq "\"path\": \"sbproxy/core-${new_cache_key}\"" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d/luci-app-sbproxy.json"

echo 'SBProxy release test passed: automatic maintenance advances only the package release'

# A manual fix starts the next patch and resets the package revision.
patch_version="$(printf '%s\n' "$version" | awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 + 1 }')"
patch_cache_version="$(printf '%s\n' "$patch_version" | sed 's/[^A-Za-z0-9_-]/-/g')"
patch_key="${patch_cache_version}-r1"
REPO_ROOT="$TEST_ROOT" "$BUMP_SCRIPT" patch
test "$(sed -n 's/^PKG_VERSION:=//p' "$TEST_ROOT/luci-app-sbproxy/Makefile")" = "$patch_version"
test "$(sed -n 's/^PKG_RELEASE:=//p' "$TEST_ROOT/luci-app-sbproxy/Makefile")" = 1
test "$(readlink "$TEST_ROOT/luci-app-sbproxy/htdocs/luci-static/resources/view/sbproxy/client-${patch_key}.js")" = \
	'client.js'
grep -Fq "\"path\": \"sbproxy/client-${patch_key}\"" \
	"$TEST_ROOT/luci-app-sbproxy/root/usr/share/luci/menu.d/luci-app-sbproxy.json"

echo 'SBProxy patch test passed: manual fixes advance the patch version and reset the revision'
