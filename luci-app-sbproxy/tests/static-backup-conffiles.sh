#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MAKEFILE="$ROOT/Makefile"
DEFAULTS="$ROOT/root/etc/uci-defaults/luci-sbproxy"

for path in \
	'/etc/config/sbproxy' \
	'/etc/sbproxy/certs/' \
	'/etc/sbproxy/ruleset/' \
	'/etc/sbproxy/resources/direct_list.txt' \
	'/etc/sbproxy/resources/proxy_list.txt' \
	'/etc/sbproxy/tailscale/tailscaled.state'
do
	grep -Fq "$path" "$MAKEFILE"
done

for path in \
	'/etc/sbproxy/cache/' \
	'/etc/sbproxy/core/' \
	'/etc/sbproxy/dashboard/' \
	'/etc/sbproxy/dashboard-singbox/' \
	'/etc/sbproxy/dashboard-yacd/' \
	'/etc/sbproxy/dashboard-metacubexd/' \
	'/etc/sbproxy/retired-adaptive/'
do
	if grep -Fq "$path" "$MAKEFILE"; then
		printf 'Backup still preserves %s\n' "$path" >&2
		exit 1
	fi
done

for path in \
	'/etc/sbproxy/cache/' \
	'/etc/sbproxy/core/' \
	'/etc/sbproxy/dashboard/' \
	'/etc/sbproxy/tailscale/'
do
	grep -Fq "$path" "$DEFAULTS"
done

printf 'SBProxy backup paths keep configuration and omit caches\n'
