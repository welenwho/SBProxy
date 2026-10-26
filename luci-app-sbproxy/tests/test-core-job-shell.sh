#!/bin/sh
# Safe on routers too: exercises the real shell/lock/RPC-pipe lifecycle, but
# replaces the installer and every state path before any manager action runs.
set -eu
if ! command -v ubus >/dev/null 2>&1; then
	echo 'OpenWrt procd integration test requires ubus; host lifecycle coverage is in test-core-jobs.py'
	exit 0
fi
PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SBPROXY_JOB_TEST_DIR="$(mktemp -d /tmp/sbproxy-core-job-test.XXXXXX)"
export SBPROXY_JOB_TEST_DIR
trap 'touch "$SBPROXY_JOB_TEST_DIR/finish"' EXIT
awk 'FNR == NR { fixture = fixture $0 "\n"; next }
     /^action="\$\{1:-status\}"/ {
       printf "SBPROXY_JOB_TEST_DIR=%s\n", ENVIRON["SBPROXY_JOB_TEST_DIR"]
       printf "UPDATE_SERVICE=sbproxy-isolated-job-test\n%s", fixture
     }
     { print }' "$PACKAGE_ROOT/tests/fixtures/core-job-installer.sh" \
	"$PACKAGE_ROOT/root/usr/libexec/sbproxy-core-manager" > "$SBPROXY_JOB_TEST_DIR/manager"
chmod 700 "$SBPROXY_JOB_TEST_DIR/manager"
manager="$SBPROXY_JOB_TEST_DIR/manager"
id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# Command substitution must return without waiting for the blocked worker.
reply="$("$manager" start-upgrade sing-box-1.14.0-r2.apk "$id")"
printf '%s\n' "$reply" | grep -qx "operation_id=$id"
"$manager" operation "$id" | grep -qx operation_state=running
if "$manager" start-rollback sing-box-1.14.0-r1.apk bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$SBPROXY_JOB_TEST_DIR/busy"; then
	echo 'Concurrent operation was incorrectly accepted' >&2
	exit 1
fi
grep -qx error_code=operation_in_progress "$SBPROXY_JOB_TEST_DIR/busy"
touch "$SBPROXY_JOB_TEST_DIR/finish"
count=0
while [ "$count" -lt 15 ]; do
	"$manager" operation "$id" > "$SBPROXY_JOB_TEST_DIR/status"
	if grep -qx operation_state=succeeded "$SBPROXY_JOB_TEST_DIR/status"; then break; fi
	sleep 1
	count=$((count + 1))
done
grep -qx operation_state=succeeded "$SBPROXY_JOB_TEST_DIR/status"
grep -qx upgraded=1 "$SBPROXY_JOB_TEST_DIR/status"
grep -qx result_code=0 "$SBPROXY_JOB_TEST_DIR/status"
"$manager" operation bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | grep -qx operation_state=unknown
echo "Core detached shell job checks passed (test files: $SBPROXY_JOB_TEST_DIR)"
ubus call service delete '{"name":"sbproxy-isolated-job-test"}' >/dev/null
