#!/bin/sh
# Run with OpenWrt ucode. Mock only curl; execute the real daemon and scoring module.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
pid=''
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || :; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/plan.json" <<'JSON'
{"api_port":19090,"probe_port":19091,"probe_tag":"probe","groups":[{"tag":"main-out","nodes":["low latency","high bandwidth"],"fallback":"fallback","bandwidth":true}]}
JSON
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/sh
url=''
data=''
for arg do
 url="$arg"
 case "$arg" in *'"name"'*) data="$arg";; esac
done
[ "${MOCK_DOWN:-0}" != 1 ] || exit 7
case "$url" in
 */proxies) echo '{"proxies":{"main-out":{"now":"fallback"}}}' ;;
 *'/delay?'*)
  case "$url" in *high%20bandwidth*) echo '{"delay":400}';; *) echo '{"delay":80}';; esac ;;
 *'/proxies/probe') printf '%s\n' "$data" > "$MOCK_TMP/probe" ;;
 *'/proxies/main-out') printf '%s\n' "$data" >> "$MOCK_TMP/switches" ;;
 *'speed.cloudflare.com'*)
  case "$(cat "$MOCK_TMP/probe")" in *high*) echo '262144 10000000';; *) echo '262144 10000';; esac ;;
 *) exit 22 ;;
esac
MOCK
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH" MOCK_TMP="$TMP" ucode -L "$ROOT/root/etc/sbproxy/scripts" \
 "$ROOT/root/etc/sbproxy/scripts/smart_select.uc" "$TMP/plan.json" >"$TMP/log" 2>&1 &
pid=$!
sleep 2
kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :
pid=''
cat "$TMP/log"
grep -q 'high bandwidth' "$TMP/switches"
grep -q 'speed_checked' "$TMP/plan.json.status"
# An unavailable API must never issue a switch.
: > "$TMP/switches"
PATH="$TMP/bin:$PATH" MOCK_TMP="$TMP" MOCK_DOWN=1 ucode -L "$ROOT/root/etc/sbproxy/scripts" \
 "$ROOT/root/etc/sbproxy/scripts/smart_select.uc" "$TMP/plan.json" >"$TMP/down-log" 2>&1 &
pid=$!
sleep 1
kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :
pid=''
[ ! -s "$TMP/switches" ]
echo 'Smart daemon integration passed: throughput selection, private probing, API outage'
