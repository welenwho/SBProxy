#!/bin/sh

set -eu

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

: > "$TEST_ROOT/functions.sh"
: > "$TEST_ROOT/log"
: > "$TEST_ROOT/sync.calls"

export SBPROXY_FUNCTIONS_LIB="$TEST_ROOT/functions.sh"
export SBPROXY_TAILSCALE_HELPER_LIBRARY_ONLY=1
export SBPROXY_TAILSCALE_STOP_FILE="$TEST_ROOT/tailscale.stopping"

# shellcheck disable=SC1090
. "$PACKAGE_ROOT/root/usr/sbin/sbproxy_tailscale_helper"

ENABLED=1
API_URL='http://127.0.0.1:19096'
# Poll plan: 25 unreadable polls, 3 running polls, 12 unreadable polls, then stop.
PLAN="$(printf 'down %.0s' $(seq 25))$(printf 'up %.0s' $(seq 3))$(printf 'down %.0s' $(seq 12))"
STEP=1

current_step() {
	printf '%s\n' $PLAN | sed -n "${STEP}p"
}

api() {
	[ "$*" = 'tailscale status' ] || return 1
	if [ "$(current_step)" = up ]; then
		printf 'State: Running\n'
		return 0
	fi
	printf 'failed to connect to API service at %s: connection error\n' "$API_URL" >&2
	return 1
}

log_info() { printf 'info %s\n' "$*" >> "$TEST_ROOT/log"; }
log_error() { printf 'error %s\n' "$*" >> "$TEST_ROOT/log"; }
load_settings() { :; }
trigger_urltests() { :; }
sync_openwrt_locked() { printf 'sync\n' >> "$TEST_ROOT/sync.calls"; return 0; }
sleep() {
	STEP=$((STEP + 1))
	[ -n "$(current_step)" ] || : > "$SBPROXY_TAILSCALE_STOP_FILE"
}

watch_backend

error_count="$(grep -c '^error ' "$TEST_ROOT/log" || true)"
[ "$error_count" -eq 2 ] || {
	echo "Expected one error per unreadable period, got $error_count:" >&2
	cat "$TEST_ROOT/log" >&2
	exit 1
}
grep -Fxq "error Unable to read the Tailscale backend state from $API_URL: failed to connect to API service at $API_URL: connection error" \
	"$TEST_ROOT/log"
[ "$(grep -c '^info Tailscale backend state is readable again: Running$' "$TEST_ROOT/log")" -eq 1 ]
[ "$(wc -l < "$TEST_ROOT/sync.calls" | tr -d ' ')" -eq 3 ]

# A short outage while sing-box starts must stay quiet.
: > "$TEST_ROOT/log"
rm -f "$SBPROXY_TAILSCALE_STOP_FILE"
PLAN="$(printf 'down %.0s' $(seq 5))up up"
STEP=1
watch_backend
if grep -q '^error ' "$TEST_ROOT/log"; then
	echo 'Startup grace period must not log an error' >&2
	cat "$TEST_ROOT/log" >&2
	exit 1
fi

echo 'Tailscale helper watch test passed: unreadable backend state is logged once per outage'
