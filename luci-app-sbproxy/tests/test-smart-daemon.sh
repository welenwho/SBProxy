#!/bin/sh
# Run with OpenWrt ucode. Mock only curl; execute the real daemon and scoring module.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
pid=''
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || :; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# With Yacd or MetaCubeXD the API is the dashboard's and needs its secret.
cat > "$TMP/plan.json" <<'JSON'
{"api_port":19090,"api_secret":"dash'secret","probe_port":19091,"probe_tag":"probe","log_path":"LOG_PATH","groups":[{"tag":"main-out","nodes":["low latency","high bandwidth"],"fallback":"fallback","bandwidth":true}]}
JSON
sed -i.bak "s|LOG_PATH|$TMP/sing-box.log|" "$TMP/plan.json"
sed 's|"api_secret":"dash.secret",||' "$TMP/plan.json" > "$TMP/no-secret.json"
# A user session timeout is read from the log; probe traffic is ignored.
cat > "$TMP/sing-box.log" <<'LOG'
ERROR [1 2.0s] inbound/redirect[redirect-in]: process connection from 192.168.1.2:50000: outbound/vless[low latency]: dial tcp 192.0.2.1:443: i/o timeout
ERROR [2 2.0s] outbound/vless[high bandwidth]: dial tcp 192.0.2.2:443: i/o timeout
LOG
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/sh
url=''
data=''
auth=''
for arg do
 url="$arg"
 case "$arg" in *'"name"'*) data="$arg";; 'Authorization: '*) auth="$arg";; esac
done
[ "${MOCK_DOWN:-0}" != 1 ] || exit 7
case "$url" in
 http://127.0.0.1:19090/*) [ "$auth" = "Authorization: Bearer dash'secret" ] || exit 22 ;;
esac
case "$url" in
 */proxies) echo '{"proxies":{"main-out":{"now":"fallback"}}}' ;;
 *'/delay?'*)
  case "$url" in *high%20bandwidth*) echo '{"delay":400}';; *) echo '{"delay":80}';; esac ;;
 *'/proxies/probe') printf '%s\n' "$data" > "$MOCK_TMP/probe" ;;
 *'/proxies/main-out') printf '%s\n' "$data" >> "$MOCK_TMP/switches" ;;
 *'speed.cloudflare.com/__down?bytes=4194304')
  # Fast but distant: 4 MiB in 0.4 s after the first byte. Slow: a partial
  # download cut off by --max-time, which curl reports as exit 28.
  case "$(cat "$MOCK_TMP/probe")" in
   *high*) printf '4194304 0.600 1.000' ;;
   *) printf '80000 0.200 8.200'; exit 28 ;;
  esac ;;
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
# Partial downloads are timed after the first byte: 80000 B / 8 s and 4 MiB / 0.4 s.
ucode -e "import { readfile } from 'fs';
const s = json(readfile('$TMP/plan.json.status'))['main-out'].samples;
exit(s['low latency'].session_failures === 1 && s['high bandwidth'].session_failures === 0 &&
	int(s['low latency'].speed + 0.5) === 10000 && int(s['high bandwidth'].speed + 0.5) === 10485760 ? 0 : 1);"
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
# Without the secret the dashboard API rejects every call, so nothing switches.
PATH="$TMP/bin:$PATH" MOCK_TMP="$TMP" ucode -L "$ROOT/root/etc/sbproxy/scripts" \
 "$ROOT/root/etc/sbproxy/scripts/smart_select.uc" "$TMP/no-secret.json" >"$TMP/no-secret-log" 2>&1 &
pid=$!
sleep 1
kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :
pid=''
[ ! -s "$TMP/switches" ]
echo 'Smart daemon integration passed: throughput selection, session log, private probing, API secret, API outage'
