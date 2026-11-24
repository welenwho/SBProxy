#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SELECT="$ROOT/root/usr/libexec/sbproxy-dashboard-select"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_select() {
	SBPROXY_DIR="$TMP" SBPROXY_CONFIG="$TMP/etc/sbproxy" "$SELECT"
}

md5() {
	md5sum "$1" | cut -d ' ' -f 1
}

# set -e ignores a negated command, so fail explicitly.
absent() {
	if grep -Fq "$1" "$2"; then
		printf 'unexpected %s in %s\n' "$1" "$2" >&2
		exit 1
	fi
}

# Fixtures keep the markup and service worker formats of the bundled releases.
write_dashboards() {
	mkdir -p "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd"
	printf '<head><script>theme()</script>\n<script type="module" crossorigin src="./assets/index.js"></script>\n</head><body><div id="root"></div></body>\n' \
		> "$TMP/dashboard-singbox/index.html"
	printf 'e([{url:"registerSW.js",revision:"1111"},{url:"index.html",revision:"%s"}]);\n' \
		"$(md5 "$TMP/dashboard-singbox/index.html")" > "$TMP/dashboard-singbox/sw.js"
	# 1.0.5 and 1.0.6 left an empty base URL behind.
	printf '<head><script type="module" crossorigin src="./assets/index.js"></script></head>\n<body><div id="app" data-base-url=""></div></body>\n' \
		> "$TMP/dashboard-yacd/index.html"
	printf 'e([{"revision":"2222","url":"assets/index.js"},{"revision":"0123456789abcdef0123456789abcdef","url":"index.html"}]);\n' \
		> "$TMP/dashboard-yacd/sw.js"
	# MetaCubeXD ships index.html on one line. These are the 1.0.6 leftovers.
	printf '<html><head><script src="sbproxy-login.js"></script><script src="config.js" onerror="x()"></script><script type="module" src="./_nuxt/a.js"></script></head></html>' \
		> "$TMP/dashboard-metacubexd/index.html"
	printf 'e([{url:`200.html`,revision:`3333`},{url:`./`,revision:`0123456789abcdef0123456789abcdef`}]);\n' \
		> "$TMP/dashboard-metacubexd/sw.js"
	printf 'window.__METACUBEXD_CONFIG__ = { sbproxySecret: "router-secret" };\n' > "$TMP/dashboard-metacubexd/config.js"
	printf 'old login\n' > "$TMP/dashboard-metacubexd/sbproxy-login.js"
}

check_precache() {
	grep -Fq "url:\"index.html\",revision:\"$(md5 "$TMP/dashboard-singbox/index.html")\"" "$TMP/dashboard-singbox/sw.js"
	grep -Fq '{url:"registerSW.js",revision:"1111"}' "$TMP/dashboard-singbox/sw.js"
	grep -Fq "\"revision\":\"$(md5 "$TMP/dashboard-yacd/index.html")\",\"url\":\"index.html\"" "$TMP/dashboard-yacd/sw.js"
	grep -Fq '{"revision":"2222","url":"assets/index.js"}' "$TMP/dashboard-yacd/sw.js"
	grep -Fq "url:\`./\`,revision:\`$(md5 "$TMP/dashboard-metacubexd/index.html")\`" "$TMP/dashboard-metacubexd/sw.js"
	grep -Fq 'url:`200.html`,revision:`3333`' "$TMP/dashboard-metacubexd/sw.js"
}

mkdir -p "$TMP/etc"
write_dashboards
printf "config sbproxy 'config'\n\toption dashboard_ui 'singbox'\n\toption dashboard_secret 'router-secret'\n" > "$TMP/etc/sbproxy"
run_select
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-singbox"
grep -Fq '<script src="sbproxy-login.js"></script><script type="module" crossorigin src="./assets/index.js">' "$TMP/dashboard/index.html"
grep -Fq "sing-box-dashboard." "$TMP/dashboard-singbox/sbproxy-login.js"

# Every installed copy is prepared, so switching needs no other step.
grep -Fq '<div id="app" data-base-url="http://127.0.0.1:9090"></div><script src="sbproxy-login.js"></script>' \
	"$TMP/dashboard-yacd/index.html"
absent 'data-base-url=""' "$TMP/dashboard-yacd/index.html"
grep -Fq "setAttribute('data-base-url', window.location.origin)" "$TMP/dashboard-yacd/sbproxy-login.js"
absent 'sbproxy-login.js' "$TMP/dashboard-metacubexd/index.html"
grep -Fq '<head><script src="config.js" onerror="x()"></script>' "$TMP/dashboard-metacubexd/index.html"
test ! -e "$TMP/dashboard-metacubexd/sbproxy-login.js"
absent 'router-secret' "$TMP/dashboard-metacubexd/config.js"
grep -Fq 'defaultBackendURL: window.location.origin' "$TMP/dashboard-metacubexd/config.js"
check_precache

# Restarting must not rewrite the pages, add a second loader or leave temp files.
cp -R "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd" "$TMP/etc/"
for kind in yacd metacubexd singbox; do
	printf "config sbproxy 'config'\n\toption dashboard_ui '%s'\n\toption dashboard_secret 'router-secret'\n" "$kind" > "$TMP/etc/sbproxy"
	run_select
	test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-$kind"
done
for kind in singbox yacd metacubexd; do
	for file in "$TMP/etc/dashboard-$kind"/*; do
		cmp "$file" "$TMP/dashboard-$kind/${file##*/}"
	done
	test "$(ls "$TMP/etc/dashboard-$kind" | wc -l)" -eq "$(ls "$TMP/dashboard-$kind" | wc -l)"
done
test "$(grep -o 'sbproxy-login.js' "$TMP/dashboard-yacd/index.html" | wc -l)" -eq 1
test -z "$(find "$TMP" -name '*.tmp.*')"

# A dashboard update restores upstream files; selecting again must prepare them.
rm -rf "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd" "$TMP/etc/dashboard-"*
write_dashboards
printf '<head><script type="module" crossorigin src="./assets/index.js"></script></head>\n<body><div id="app" data-base-url="http://127.0.0.1:9090"></div></body>\n' \
	> "$TMP/dashboard-yacd/index.html"
printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
run_select
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
grep -Fq '<div id="app" data-base-url="http://127.0.0.1:9090"></div><script src="sbproxy-login.js"></script>' \
	"$TMP/dashboard/index.html"
check_precache

if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/dashboard-login.mjs" "$TMP/dashboard-singbox/sbproxy-login.js" "$TMP/dashboard-yacd/sbproxy-login.js"
fi

# A package upgrade with a new Yacd build (seen on a router after 1.0.12):
# apk kept the edited page, saved the packaged one as index.html.apk-new and
# removed the assets the kept page loads. Older packages also wrote the sing-box
# dashboard through the active link into the selected directory.
rm -rf "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd"
write_dashboards
S="$TMP/dashboard-singbox" Y="$TMP/dashboard-yacd" M="$TMP/dashboard-metacubexd"
mkdir -p "$S/assets" "$Y/assets" "$M/_nuxt"
printf 'sing-box app\n' > "$S/assets/index.js"
printf 'shared font\n' > "$S/assets/font.woff2"
printf '<title>sing-box dashboard</title><script type="module" crossorigin src="./assets/index.js"></script>\n' \
	> "$S/index.html.apk-new"
printf '20261011041500\n' > "$S/dashboard.ver"
printf '{"name":"sing-box"}\n' > "$S/manifest.webmanifest"
printf '<head><script type="module" crossorigin src="./assets/index-old.js"></script></head>\n<body><div id="app" data-base-url="http://127.0.0.1:9090"></div><script src="sbproxy-login.js"></script></body>\n' \
	> "$Y/index.html"
printf '<head><script type="module" crossorigin src="./assets/index-new.js"></script></head>\n<body><div id="app" data-base-url="http://127.0.0.1:9090"></div></body>\n' \
	> "$Y/index.html.apk-new"
printf 'e([{"revision":"4444","url":"assets/index-new.js"},{"revision":"0123456789abcdef0123456789abcdef","url":"index.html"}]);\n' \
	> "$Y/sw.js.apk-new"
printf 'yacd app loads font.woff2\n' > "$Y/assets/index-new.js"
printf 'same build, other bytes\n' > "$Y/assets/index-new.js.apk-new"
cp "$S/assets/index.js" "$S/assets/font.woff2" "$Y/assets/"
cp "$S/dashboard.ver" "$Y/dashboard.ver.apk-new"
cp "$S/manifest.webmanifest" "$Y/manifest.webmanifest.apk-new"
mkdir -p "$M/assets"
cp "$S/assets/index.js" "$M/assets/"
printf 'packaged config\n' > "$M/config.js.apk-new"
printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
run_select
grep -Fq 'src="./assets/index-new.js"' "$Y/index.html"
grep -Fq '<div id="app" data-base-url="http://127.0.0.1:9090"></div><script src="sbproxy-login.js"></script>' "$Y/index.html"
grep -Fq '{"revision":"4444","url":"assets/index-new.js"}' "$Y/sw.js"
grep -Fq "\"revision\":\"$(md5 "$Y/index.html")\",\"url\":\"index.html\"" "$Y/sw.js"
test -z "$(find "$TMP/dashboard-singbox" "$Y" "$M" -name '*.apk-new')"
# Stray sing-box files go; a file Yacd itself loads stays.
test ! -e "$Y/assets/index.js"
test -f "$Y/assets/font.woff2"
test -f "$Y/assets/index-new.js"
test ! -e "$M/assets"
# The sing-box page still works, so its packaged copy is not swapped in.
grep -Fq '<script src="sbproxy-login.js"></script><script type="module" crossorigin src="./assets/index.js">' "$S/index.html"
check_precache_singbox() {
	grep -Fq "url:\"index.html\",revision:\"$(md5 "$S/index.html")\"" "$S/sw.js"
}
check_precache_singbox
# A page from a newer resource update is complete and stays, even with a
# packaged page beside it.
printf '<head><script type="module" crossorigin src="./assets/index-newer.js"></script></head>\n<body><div id="app" data-base-url="http://127.0.0.1:9090"></div></body>\n' \
	> "$Y/index.html"
printf 'newer\n' > "$Y/assets/index-newer.js"
printf '<head><script type="module" crossorigin src="./assets/index-new.js"></script></head><div id="app" data-base-url="x"></div>\n' \
	> "$Y/index.html.apk-new"
run_select
grep -Fq 'src="./assets/index-newer.js"' "$Y/index.html"
test ! -e "$Y/index.html.apk-new"

printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
rm "$TMP/dashboard"
mkdir -p "$TMP/legacy"
printf '<html>legacy</html>\n' > "$TMP/legacy/index.html"
rm -rf "$TMP/dashboard-singbox"
mv "$TMP/legacy" "$TMP/dashboard"
run_select
test -s "$TMP/dashboard-singbox/index.html"
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"
test "$(cat "$TMP/dashboard-singbox/index.html")" = "<html>legacy</html>"

# Selecting Yacd before its files exist must preserve the official files and
# leave the active path unset until Yacd is installed.
rm -rf "$TMP/dashboard" "$TMP/dashboard-singbox" "$TMP/dashboard-yacd" "$TMP/dashboard-metacubexd"
mkdir -p "$TMP/dashboard"
printf '<html>legacy</html>\n' > "$TMP/dashboard/index.html"
printf "config sbproxy 'config'\n\toption dashboard_ui 'yacd'\n" > "$TMP/etc/sbproxy"
run_select
test ! -e "$TMP/dashboard"
test "$(cat "$TMP/dashboard-singbox/index.html")" = "<html>legacy</html>"
mkdir -p "$TMP/dashboard-yacd"
printf '<html>yacd</html>\n' > "$TMP/dashboard-yacd/index.html"
run_select
test "$(readlink "$TMP/dashboard")" = "$TMP/dashboard-yacd"

printf 'dashboard select passed\n'
