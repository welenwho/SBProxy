#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GENERATOR="$ROOT/root/etc/sbproxy/scripts/generate_client.uc"
SELECT="$ROOT/root/usr/libexec/sbproxy-dashboard-select"

grep -Fq "dashboard_uses_clash" "$GENERATOR"
grep -Fq 'external_ui: dashboard_enabled && dashboard_uses_clash ? dashboard_path : null' "$GENERATOR"
grep -Fq 'dashboard_enabled && !dashboard_uses_clash' "$GENERATOR"
grep -Fq "ui === 'metacubexd'" "$ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq 'data-base-url="http://127.0.0.1:9090"' "$SELECT"
grep -Fq 'sbproxy-login.js' "$SELECT"
grep -Fq 'refresh_precache' "$SELECT"
if grep -Fq 'sbproxySecret' "$SELECT"; then
	printf 'dashboard secret must not be written to unauthenticated files\n' >&2
	exit 1
fi
grep -Fq "ui === 'yacd'" "$ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq 'hostname: host' "$ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq "'/ui/#/setup?'" "$ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq "'/dashboard/#sbproxy-secret='" "$ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq 'generate_client.uc.apk-new' "$ROOT/root/etc/uci-defaults/luci-sbproxy"
printf 'Clash dashboards use the Clash API on the dashboard port\n'
