#!/bin/sh

set -eu

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLIENT="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
NODE="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/node.js"
SERVER="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/server.js"
TAILSCALE="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale.js"
GENERATOR="$PACKAGE_ROOT/root/etc/sbproxy/scripts/generate_client.uc"
SERVER_GENERATOR="$PACKAGE_ROOT/root/etc/sbproxy/scripts/generate_server.uc"
MODULE="$PACKAGE_ROOT/root/etc/sbproxy/scripts/sbproxy.uc"
FIREWALL="$PACKAGE_ROOT/root/etc/sbproxy/scripts/firewall_pre.uc"
RPC="$PACKAGE_ROOT/root/usr/share/rpcd/ucode/luci.sbproxy"
DEFAULTS="$PACKAGE_ROOT/root/usr/share/sbproxy/defaults/sbproxy"
MAKEFILE="$PACKAGE_ROOT/Makefile"
MENU="$PACKAGE_ROOT/root/usr/share/luci/menu.d/luci-app-sbproxy.json"

version="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE")"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE")"
cache_version="$(printf '%s\n' "$version" | sed 's/[^A-Za-z0-9_-]/-/g')"
grep -Fq "sbproxy/client-$cache_version-r$release" "$MENU"
grep -Fq "sbproxy/tailscale-$cache_version-r$release" "$MENU"
grep -Fq "sbproxy/core-$cache_version-r$release" "$MENU"

grep -Fq "so.value('dhcp', _('DHCP'));" "$CLIENT"
grep -Fq "cfg.type === 'dhcp' ? cfg.interface" "$GENERATOR"
grep -Fq "'dns_cache_capacity'" "$CLIENT"
grep -Fq 'cache_capacity: strToInt(dns_cache_capacity)' "$GENERATOR"
grep -Fq "'dns_optimistic_timeout'" "$CLIENT"

grep -Fq "'memory_guard_enabled'" "$CLIENT"
grep -Fq "type: 'oom-killer'" "$GENERATOR"
grep -Fq "type: 'oom-killer'" "$SERVER_GENERATOR"
grep -Fq "option memory_guard_enabled '0'" "$DEFAULTS"

for field in connect_timeout disable_tcp_keep_alive tcp_keep_alive tcp_keep_alive_interval; do
	grep -Fq "'$field'" "$NODE"
	grep -Fq "$field:" "$MODULE"
done
grep -Fq "o.value('chrome_pq');" "$NODE"
grep -Fq "'tls_curve_preferences'" "$NODE"
grep -Fq 'curve_preferences:' "$MODULE"
grep -Fq 'curve_preferences:' "$SERVER_GENERATOR"

grep -Fq "o.value('gecko', _('Gecko'));" "$NODE"
grep -Fq "o.value('gecko', _('Gecko'));" "$SERVER"
grep -Fq "'hysteria_hop_interval_max'" "$NODE"
grep -Fq 'hop_interval_max' "$MODULE"
grep -Fq 'bbr_profile' "$MODULE"
grep -Fq 'bbr_profile' "$SERVER_GENERATOR"

grep -Fq "'dashboard_tls_tailscale'" "$CLIENT"
grep -Fq "tag: 'api-internal'" "$GENERATOR"
grep -Fq "certificate_provider: {" "$GENERATOR"
grep -Fq "type: 'tailscale'" "$GENERATOR"
grep -Fq "sbpuci.get('sbproxy', 'infra', 'tailscale_api_port')" "$RPC"
grep -Fq "'derp_server_enabled'" "$TAILSCALE"
grep -Fq "type: 'derp'" "$GENERATOR"
grep -Fq 'verify_client_endpoint:' "$GENERATOR"
grep -Fq 'mesh_with:' "$GENERATOR"
grep -Fq 'stun:' "$GENERATOR"
grep -Fq 'accept DERP HTTPS' "$FIREWALL"
grep -Fq 'accept DERP STUN' "$FIREWALL"
grep -Fq "option derp_server_enabled '0'" "$DEFAULTS"

echo 'Modern sing-box capability checks passed: DNS, memory guard, dialer/TLS, Hysteria2, Tailscale certificates and DERP are integrated'
