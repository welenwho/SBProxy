#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GENERATOR="$ROOT/root/etc/sbproxy/scripts/generate_client.uc"
SELECT="$ROOT/root/usr/libexec/sbproxy-dashboard-select"

grep -Fq "dashboard_uses_clash" "$GENERATOR"
grep -Fq 'const clash_api_public = dashboard_enabled && dashboard_uses_clash && !isEmpty(dashboard_secret);' "$GENERATOR"
grep -Fq 'external_ui: clash_api_public ? dashboard_path : null' "$GENERATOR"
# Smart selection and the current-node query must follow the API to the
# dashboard port and send its secret.
grep -Fq 'api_port: clash_controller_port, api_secret: clash_controller_secret' "$GENERATOR"
grep -Fq "'Authorization: Bearer ' + plan.api_secret" "$ROOT/root/etc/sbproxy/scripts/smart_select.uc"
grep -Fq 'const controller = clashController();' "$ROOT/root/usr/share/rpcd/ucode/luci.sbproxy"
if grep -n 'clash_api_port' "$ROOT/root/usr/share/rpcd/ucode/luci.sbproxy" | grep -v reserved_controller_port; then
	printf 'rpcd must read the Clash API address from the running config\n' >&2
	exit 1
fi
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
# The active path is a link to the selected dashboard. The package must not
# install files there, or an upgrade writes them into the selected dashboard.
if [ -e "$ROOT/root/etc/sbproxy/dashboard" ]; then
	printf 'the package must not ship files at the active dashboard link\n' >&2
	exit 1
fi
test -s "$ROOT/root/etc/sbproxy/dashboard-singbox/index.html"
grep -Fq 'define Package/luci-app-sbproxy/preinst' "$ROOT/Makefile"
grep -Fq '[ ! -L "$${IPKG_INSTROOT}/etc/sbproxy/dashboard" ]' "$ROOT/Makefile"
grep -Fq 'settle_upgrade "$dir"' "$SELECT"
printf 'Clash dashboards use the Clash API on the dashboard port\n'
