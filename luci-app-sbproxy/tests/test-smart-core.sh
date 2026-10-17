#!/bin/sh
# Optional actual sing-box API smoke test in a disposable OpenWrt container.
set -eu
: "${SING_BOX:?Set SING_BOX to the core binary}"
TMP="$(mktemp -d)"
core_pid='' http_pid=''
trap '[ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null || :; [ -z "$http_pid" ] || kill "$http_pid" 2>/dev/null || :; rm -rf "$TMP"' EXIT
cat > "$TMP/core.json" <<'JSON'
{
 "log":{"level":"error"},
 "experimental":{"clash_api":{"external_controller":"127.0.0.1:19090"}},
 "inbounds":[{"type":"mixed","tag":"probe-in","listen":"127.0.0.1","listen_port":19091}],
 "outbounds":[
  {"type":"direct","tag":"node one"},
  {"type":"direct","tag":"node two"},
  {"type":"urltest","tag":"fallback","outbounds":["node one","node two"],"url":"http://127.0.0.1:19092/index.html","interval":"60s"},
  {"type":"selector","tag":"main-out","outbounds":["fallback","node one","node two"],"default":"fallback"},
  {"type":"selector","tag":"probe","outbounds":["node one","node two"]}
 ],
 "route":{"rules":[{"inbound":"probe-in","action":"route","outbound":"probe"}],"final":"main-out"}
}
JSON
printf 'hello smart probe\n' > "$TMP/index.html"
uhttpd -f -p 127.0.0.1:19092 -h "$TMP" &
http_pid=$!
"$SING_BOX" run -c "$TMP/core.json" > "$TMP/log" 2>&1 &
core_pid=$!
sleep 1
get() { printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" | nc 127.0.0.1 19090; }
get '/proxies/node%20one/delay?timeout=2000&url=http%3A%2F%2F127.0.0.1%3A19092%2Findex.html' > "$TMP/delay"
grep -q '"delay"' "$TMP/delay"
body='{"name":"node two"}'
printf 'PUT /proxies/main-out HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body" | nc 127.0.0.1 19090 > "$TMP/put"
grep -q '204' "$TMP/put"
get /proxies/main-out > "$TMP/current"
grep -Eq '"now"[[:space:]]*:[[:space:]]*"node two"' "$TMP/current"
printf 'GET http://127.0.0.1:19092/index.html HTTP/1.1\r\nHost: 127.0.0.1:19092\r\nConnection: close\r\n\r\n' | nc 127.0.0.1 19091 > "$TMP/probe"
grep -q 'hello smart probe' "$TMP/probe"
echo 'Actual core API passed: encoded node delay, selector PUT, isolated HTTP probe'
