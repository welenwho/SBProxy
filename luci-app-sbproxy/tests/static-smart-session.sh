#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SELECT="$ROOT/root/etc/sbproxy/scripts/smart_select.uc"
SCORE="$ROOT/root/etc/sbproxy/scripts/smart_score.uc"

grep -Fq 'observeSession' "$SELECT"
grep -Fq 'sing-box-c.log' "$SELECT"
grep -Fq 'inbound' "$SELECT"
grep -Fq 'session_failures >= 2' "$SCORE"
grep -Fq 'session_failures: old.session_failures || 0' "$SCORE"
printf 'Smart selection consumes real session timeouts\n'
