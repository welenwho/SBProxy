#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SELECT="$ROOT/root/usr/libexec/sbproxy-dashboard-select"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/etc"
printf '<html>singbox</html>\n' > "$TMP/dashboard-singbox/index.html"
printf '<html>yacd</html>\n' > "$TMP/dashboard-yacd/index.html"
printf "config sbproxy 'config'\n\toption dashboard_ui 'singbox'\n" > "$TMP/etc/sbproxy"

SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-singbox"
test "$(cat "$TMP/dashboard/index.html")" = "<html>singbox</html>"

printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
test "$(cat "$TMP/dashboard/index.html")" = "<html>yacd</html>"

rm "$TMP/dashboard"
mkdir -p "$TMP/legacy"
printf '<html>legacy</html>\n' > "$TMP/legacy/index.html"
rm -rf "$TMP/dashboard-singbox"
mv "$TMP/legacy" "$TMP/dashboard"
SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
test -s "$TMP/dashboard-singbox/index.html"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
test "$(cat "$TMP/dashboard-singbox/index.html")" = "<html>legacy</html>"

printf 'dashboard select passed\n'
