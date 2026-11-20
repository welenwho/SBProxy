#!/bin/sh

set -eu

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLIENT="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
TAILSCALE="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale.js"
GENERATOR="$PACKAGE_ROOT/root/etc/sbproxy/scripts/generate_client.uc"
INIT="$PACKAGE_ROOT/root/etc/init.d/sbproxy"
HELPER="$PACKAGE_ROOT/root/usr/sbin/sbproxy_tailscale_helper"
RPC="$PACKAGE_ROOT/root/usr/share/rpcd/ucode/luci.sbproxy"
ACL="$PACKAGE_ROOT/root/usr/share/rpcd/acl.d/luci-app-sbproxy.json"
MENU="$PACKAGE_ROOT/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
CONFIG="$PACKAGE_ROOT/root/usr/share/sbproxy/defaults/sbproxy"
MIGRATION="$PACKAGE_ROOT/root/etc/uci-defaults/00-luci-sbproxy-migrate"
MAKEFILE="$PACKAGE_ROOT/Makefile"
NETIFD_PROTO="$PACKAGE_ROOT/root/lib/netifd/proto/sbproxy_tailscale.sh"
LUCI_PROTO="$PACKAGE_ROOT/htdocs/luci-static/resources/protocol/sbproxy_tailscale.js"

pkg_version="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE")"
pkg_release="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE")"
cache_version="$(printf '%s\n' "$pkg_version" | sed 's/[^A-Za-z0-9_-]/-/g')"
cache_key="${cache_version}-r${pkg_release}"
versioned_client="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client-${cache_key}.js"
versioned_tailscale="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale-${cache_key}.js"

grep -Fq '"admin/vpn/sbproxy"' "$MENU"
grep -Fq 'PKG_NAME:=luci-app-sbproxy' "$PACKAGE_ROOT/Makefile"
grep -Fq 'LUCI_EXTRA_DEPENDS:=sing-box (>=1.14.0)' "$PACKAGE_ROOT/Makefile"
grep -Fq "config sbproxy 'tailscale'" "$CONFIG"
grep -Fq 'NEW_CONFIG="$MIGRATION_ROOT/etc/config/sbproxy"' "$MIGRATION"
grep -Fq 'MIGRATE_FROM_LEGACY=1' "$MIGRATION"

for view in "$PACKAGE_ROOT"/htdocs/luci-static/resources/view/sbproxy/*.js; do
	if grep -Eq "require sbproxy as hp|(^|[^A-Za-z0-9_])hp[A-Za-z0-9_-]" "$view"; then
		echo "Legacy identifier remains in $view" >&2
		exit 1
	fi
done
grep -Fq "'require sbproxy as sb';" \
	"$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
grep -Fq "'require sbproxy as sb';" "$TAILSCALE"
grep -Fq "'require sbproxy as sb';" \
	"$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/node.js"
grep -Fq "'require sbproxy as sb';" \
	"$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/server.js"
test "$(readlink "$versioned_client")" = \
	'client.js'
test "$(readlink "$versioned_tailscale")" = \
	'tailscale.js'
grep -Fq '"admin/vpn/sbproxy/tailscale"' "$MENU"
grep -Fq "\"path\": \"sbproxy/tailscale-${cache_key}\"" "$MENU"
grep -Fq "type: 'tailscale'" "$GENERATOR"
grep -A12 "const tailscale_endpoint = tailscale_enabled" "$GENERATOR" | grep -Fq "domain_resolver: {"
grep -A14 "const tailscale_endpoint = tailscale_enabled" "$GENERATOR" | grep -Fq "server: 'default-dns'"
grep -Fq "system_interface: true" "$GENERATOR"
grep -Fq "accept_routes: strToBool(uci.get(uciconfig, ucitailscale, 'accept_routes'))" "$GENERATOR"
grep -Fq "dns_mode: 'disabled'" "$GENERATOR"
grep -Fq "inbound: tailscale_endpoint_tag" "$GENERATOR"
grep -Fq "invert: true" "$GENERATOR"
grep -Fq "form.Flag, 'disable_snat_subnet_routes'" "$TAILSCALE"
grep -Fq "The default route must be configured as an exit node." "$TAILSCALE"
grep -Fq "form.Flag, 'ssh_disable_forwarding'" "$TAILSCALE"
grep -Fq "method: 'tailscale_ping'" "$TAILSCALE"
grep -Fq "method: 'tailscale_peer_details'" "$TAILSCALE"
grep -Fq "formatTailscaleBytes" "$TAILSCALE"
grep -Fq "renderTailscaleRouteDiscovery" "$TAILSCALE"
grep -Fq "_('Tailscale IPv4')" "$TAILSCALE"
grep -Fq "_('Tailscale IPv6')" "$TAILSCALE"
grep -Fq "_('Interface Management')" "$TAILSCALE"
grep -Fq '"tailscale"' "$ACL"
# The helper drives Tailscale over gRPC (sing-box api), so it must always use
# the internal API service on tailscale_api_port. The dashboard port serves the
# HTTP Clash API for Yacd/MetaCubeXD and may use TLS for the sing-box UI.
grep -Fq 'config_get API_PORT infra tailscale_api_port' "$HELPER"
if grep -Eq 'dashboard_(port|enabled|secret)|BOX_API_SECRET' "$HELPER"; then
	echo 'Tailscale helper must not talk to the dashboard API listener' >&2
	exit 1
fi
grep -B3 "tag: 'api-internal'" "$GENERATOR" | grep -Fxq 'if (tailscale_enabled)'
grep -A3 "tag: 'api-internal'" "$GENERATOR" | grep -Fq 'listen_port: tailscale_api_port'
grep -Fq 'firewall.sbproxy_tszone.masq 0' "$HELPER"
grep -Fq 'delete firewall.homeproxy_forward' "$PACKAGE_ROOT/root/etc/uci-defaults/luci-sbproxy"
grep -Fq 'delete firewall.homeproxy_input' "$PACKAGE_ROOT/root/etc/uci-defaults/luci-sbproxy"
grep -Fq 'delete firewall.homeproxy_post' "$PACKAGE_ROOT/root/etc/uci-defaults/luci-sbproxy"
grep -Fq 'dashboard_allow_tailscale' "$PACKAGE_ROOT/root/etc/sbproxy/scripts/firewall_pre.uc"
grep -Fq 'iifname \"$INTERFACE_NAME\" oifname != \"$INTERFACE_NAME\" masquerade' "$HELPER"
grep -Fq 'FIREWALL_RUNTIME_CHANGED' "$HELPER"
grep -Fq 'uci_set_if_changed' "$HELPER"
grep -Fq 'network.sbproxy_ts.proto sbproxy_tailscale' "$HELPER"
grep -Fq 'network.sbproxy_ts.auto 1' "$HELPER"
grep -Fq 'network.sbproxy_ts.ipaddr "$TS_IPV4"' "$HELPER"
grep -Fq 'uci_replace_list network.sbproxy_ts.ip6addr "${TS_IPV6:+$TS_IPV6/128}"' "$HELPER"
grep -Fq 'uci_set_if_changed "$section.DirectInterface" sbproxy_ts' "$HELPER"
grep -Fq 'notify_network_status' "$HELPER"
grep -Fq 'system_interface_ready' "$HELPER"
grep -Fq 'trigger_urltests' "$HELPER"
grep -Fq 'tailscale.stopping' "$HELPER"
grep -Fq 'tailscale.stopping' "$INIT"
grep -Fq 'lock "$SYNC_LOCK"' "$HELPER"
grep -Fq 'restart:1|reload:1)' "$INIT"
test -x "$NETIFD_PROTO"
grep -Fq 'proto_init_update "$device" "$up" 1' "$NETIFD_PROTO"
grep -Fq 'no_device=1' "$NETIFD_PROTO"
grep -Fq 'no_proto_task=1' "$NETIFD_PROTO"
grep -Fq 'proto_add_ipv4_address' "$NETIFD_PROTO"
grep -Fq 'proto_add_ipv6_address' "$NETIFD_PROTO"
grep -Fq "network.registerProtocol('sbproxy_tailscale'" "$LUCI_PROTO"
grep -Fq '/etc/init.d/network reload' "$HELPER"
grep -Fq 'firewall.sbproxy_tszone.device "$INTERFACE_NAME"' "$HELPER"
grep -Fq 'to "$route" table 52' "$HELPER"
grep -Fq 'find_tailscale_rule_priority -4' "$HELPER"
grep -Fq 'find_resume_rule_priority -4' "$HELPER"
grep -Fq 'goto "$resume_priority"' "$HELPER"
grep -Fq '0.0.0.0/0|::/0)' "$HELPER"
grep -Fq 'standalone_conflict && fail "Independent Tailscale is enabled or running."' "$HELPER"
grep -A2 '^[[:space:]]*check)' "$HELPER" | grep -Fq 'exit 0'
grep -Fq "backend_state: 'Disabled'" "$RPC"
grep -Fq "parseTailscaleExitNodes" "$RPC"
grep -Fq "[ 'tailscale', 'exit-node', 'list' ]" "$RPC"
grep -Fq "parseTailscalePeerRoutes" "$RPC"
grep -Fq "[ 'tailscale', 'route', 'list' ]" "$RPC"
grep -Fq "parseTailscalePeers" "$RPC"
grep -Fq "parseTailscalePeerDetails" "$RPC"
grep -Fq "[ 'tailscale', 'peer', 'list' ]" "$RPC"
grep -Fq "[ 'tailscale', 'peer', 'show', target ]" "$RPC"
grep -Fq "tailscale_peer_details" "$RPC"
grep -Fq "peer_routes" "$RPC"
grep -Fq "peer_routes_available" "$RPC"
grep -Fq "peer_routes_error" "$RPC"
grep -Fq "tailscaleInterfaceStatus" "$RPC"
grep -Fq "tailscaleSystemRoutingStatus" "$RPC"
grep -Fq '/sbin/ip ${family} -j route show table 52' "$RPC"
grep -Fq '/sbin/ip ${family} -j rule show' "$RPC"
grep -Fq '/sbin/ip -j address show dev ${shellQuote(interface_name)}' "$RPC"
grep -Fq "standalone_installed" "$RPC"
grep -Fq '"tailscale_peer_details"' "$ACL"
grep -Fq "index(route, '/') < 0" "$RPC"
# PPPoE receives a /32 WAN address; it must not become an advertised subnet candidate.
grep -Fq "cidr < 1 || cidr >= 32" "$TAILSCALE"
grep -Fq "widgets.DeviceSelect, 'bind_interface'" "$TAILSCALE"
grep -Fq "bind_interface: uci.get(uciconfig, ucitailscale, 'bind_interface')" "$GENERATOR"
grep -Fq 'local routing_mode tailscale_enabled' "$INIT"
grep -Fq '[ "$outbound_node" = "nil" ] || proxy_client_requested=1' "$INIT"
grep -Fq '[ "$tailscale_enabled" = "0" ]; then' "$INIT"
grep -Fq '[ "$outbound_node" != "nil" ] || [ "$tailscale_enabled" = "1" ]; then' "$INIT"
grep -Fq '} else if (tailscale_enabled) {' "$GENERATOR"
grep -A6 '} else if (tailscale_enabled) {' "$GENERATOR" | grep -Fq 'config.route.default_domain_resolver = {'
grep -Fq "config.route.final = 'direct-out';" "$GENERATOR"

if grep -Fq 'set firewall.sbproxy_tszone.masq=' "$HELPER"; then
	echo 'Embedded Tailscale must not enable zone-wide masquerading' >&2
	exit 1
fi

echo 'Embedded Tailscale test passed: migration-safe SBProxy UI, endpoint, routing, status, and scoped SNAT are present'
