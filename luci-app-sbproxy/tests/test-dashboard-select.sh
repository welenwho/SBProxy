#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SELECT="$ROOT/root/usr/libexec/sbproxy-dashboard-select"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd" "$TMP/etc"
printf '<html>singbox</html>\n' > "$TMP/dashboard-singbox/index.html"
printf '<html>yacd</html>\n<div id="app" data-base-url="http://127.0.0.1:9090"></div>\n' > "$TMP/dashboard-yacd/index.html"
printf '<html>xd</html>\n<div id="app" data-base-url="http://127.0.0.1:9090"></div>\n' > "$TMP/dashboard-metacubexd/index.html"
printf "config sbproxy 'config'\n\toption dashboard_ui 'singbox'\n" > "$TMP/etc/sbproxy"

SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-singbox"
test "$(cat "$TMP/dashboard/index.html")" = "<html>singbox</html>"

printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
grep -Fq 'data-base-url=""' "$TMP/dashboard/index.html"

# Selecting the same dashboard again must still rewrite a stale default URL.
printf '<html>yacd</html>\n<div id="app" data-base-url="http://127.0.0.1:9090"></div>\n' > "$TMP/dashboard-yacd/index.html"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
grep -Fq 'data-base-url=""' "$TMP/dashboard-yacd/index.html"

printf "config sbproxy 'config'\n\toption dashboard_ui 'metacubexd'\n" > "$TMP/etc/sbproxy"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-metacubexd"
grep -Fq 'data-base-url=""' "$TMP/dashboard/index.html"

printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
rm "$TMP/dashboard"
mkdir -p "$TMP/legacy"
printf '<html>legacy</html>\n' > "$TMP/legacy/index.html"
rm -rf "$TMP/dashboard-singbox"
mv "$TMP/legacy" "$TMP/dashboard"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test -s "$TMP/dashboard-singbox/index.html"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
test "$(cat "$TMP/dashboard-singbox/index.html")" = "<html>legacy</html>"

# Selecting Yacd before its files exist must preserve the official files and
# leave the active path unset until Yacd is installed.
rm -rf "$TMP/dashboard" "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd"
mkdir -p "$TMP/dashboard"
printf '<html>legacy</html>\n' > "$TMP/dashboard/index.html"
printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test ! -e "$TMP/dashboard"
test "$(cat "$TMP/dashboard-singbox/index.html")" = "<html>legacy</html>"
mkdir -p "$TMP/dashboard-yacd"
printf '<html>yacd</html>\n' > "$TMP/dashboard-yacd/index.html"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"

printf 'dashboard select passed\n'
