#!/bin/sh
# Run in disposable OpenWrt container; no service or host UCI is changed.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPTS="$ROOT/root/etc/sbproxy/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/uci" /usr/libexec
cp "$ROOT/root/usr/libexec/sbproxy-random-port" /usr/libexec/sbproxy-random-port
chmod +x /usr/libexec/sbproxy-random-port
cp "$ROOT/root/usr/share/sbproxy/defaults/sbproxy" "$TMP/uci/sbproxy"
cfg() { uci -q -c "$TMP/uci" "$@"; }
cfg set sbproxy.infra.clash_api_port=19090
cfg set sbproxy.config.routing_mode=global
cfg set sbproxy.config.main_node=urltest
cfg set sbproxy.config.main_urltest_smart=1
for id in a b; do
 cfg set sbproxy.$id=node
 cfg set sbproxy.$id.type=socks
 cfg set sbproxy.$id.label="node-$id"
 cfg set sbproxy.$id.address=192.0.2.1
 cfg set sbproxy.$id.port=1080
 cfg add_list sbproxy.config.main_urltest_nodes="$id"
done
cfg commit sbproxy
render() {
 SBPROXY_UCI_CONFIG_DIR="$TMP/uci" SBPROXY_CLIENT_CONFIG_PATH="$TMP/$1.json" \
 ucode -S -L "$SCRIPTS" "$SCRIPTS/generate_client.uc"
}
render main
cfg set sbproxy.config.routing_mode=custom
cfg set sbproxy.config.main_node=nil
cfg set sbproxy.smart=routing_node
cfg set sbproxy.smart.enabled=1
cfg set sbproxy.smart.node=urltest
cfg set sbproxy.smart.urltest_smart=1
cfg add_list sbproxy.smart.urltest_nodes=a
cfg add_list sbproxy.smart.urltest_nodes=b
cfg set sbproxy.routing.default_outbound=smart
cfg commit sbproxy
render custom
cfg set sbproxy.smart.urltest_smart=0
cfg commit sbproxy
render ordinary
ucode -L "$SCRIPTS" "$ROOT/tests/smart-score.uc"
ucode "$ROOT/tests/check-smart-config.uc" "$TMP/main.json" "$TMP/custom.json" "$TMP/ordinary.json"
if [ -n "${SING_BOX:-}" ]; then
 "$SING_BOX" check -c "$TMP/main.json"
 "$SING_BOX" check -c "$TMP/custom.json"
 "$SING_BOX" check -c "$TMP/ordinary.json"
fi
