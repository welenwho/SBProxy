# Test-only installer injected before the manager's command dispatch.
: "${SBPROXY_JOB_TEST_DIR:?An isolated test directory is required}"
STATE_DIR="$SBPROXY_JOB_TEST_DIR/core"
LOCK_FILE="$SBPROXY_JOB_TEST_DIR/manager.lock"
LOG_FILE="$SBPROXY_JOB_TEST_DIR/manager.log"
JOB_DIR="$SBPROXY_JOB_TEST_DIR/jobs"
upgrade_core() {
	progress downloading
	while [ ! -f "$SBPROXY_JOB_TEST_DIR/finish" ]; do sleep 1; done
	progress checking_health
	emit upgraded 1
	emit package_version 1.14.0-r2
}
