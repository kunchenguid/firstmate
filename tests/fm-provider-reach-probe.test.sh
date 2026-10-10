#!/usr/bin/env bash
# Behavior tests for fm-provider-reach-probe.sh - the one hard-bounded,
# non-destructive reachability probe of an explicitly named provider endpoint.
#
# Two defects this suite pins:
#
# 1. Upstream outage was previously visible only by reading worker panes, so
#    "the endpoint is down" was never a machine-readable finding at an intake.
#    The three outage shapes the fleet actually recorded must each land on their
#    own exit status and wording: no address at all (HTTP 000 / NXDOMAIN), a
#    request that reached the endpoint and was refused (401/403), and an endpoint
#    that answered successfully (2xx). The last two must never be conflated,
#    because a refusal proves routing while proving nothing about usability, and a
#    2xx is recorded as reachable rather than as proof a model or credential works.
#
# 2. A probe must not smuggle in routing knowledge, a provider endpoint, or a
#    service. The caller names the endpoint with --host; the probe ships no
#    endpoint of its own. Every assertion below runs against local stand-ins only
#    - a fake curl, a fake resolver, and for the curl-config isolation case a
#    loopback listener - so no third-party endpoint is ever contacted to justify
#    an expected value. The fake curl records every URL it was handed, so
#    "unauthenticated, exactly one request, bounded" are observable facts.
set -u
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
unset CURL_HOME XDG_CONFIG_HOME

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-provider-reach-probe.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-provider-reach-probe-tests)

# A sentinel token the probe must never carry anywhere.
SENTINEL_KEY='SENTINEL-SECRET-MUST-NEVER-APPEAR'
PROBE_HOST=api.example.invalid

# --- stand-in toolchain -----------------------------------------------------
#
# Fake curl: prints FM_FAKE_CURL_CODE as the HTTP code and logs each call's argv.
# It never opens a socket, so a suite regression cannot turn into real traffic.
# The stand-ins go in <dir> itself and <dir> is prepended to PATH, because
# /usr/bin/curl would otherwise shadow a fakebin subdirectory of the same case.
make_standins() {
  local dir=$1 fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=''
out=/dev/null
printf '%s\n' "$*" >> "${FM_FAKE_CURL_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$*" >> "${FM_FAKE_CURL_LOG:-/dev/null}"
printf '%s\n' "$url" >> "${FM_FAKE_CURL_URL_LOG:-/dev/null}"
case "${FM_FAKE_CURL_MODE:-code}" in
  hang) sleep 30; printf '200\n'; exit 0 ;;
  partial) printf '%s\n' "${FM_FAKE_CURL_CODE:-200}"; exit 18 ;;
  *) printf '%s\n' "${FM_FAKE_CURL_CODE:-200}" ;;
esac
SH
  chmod +x "$fakebin/curl"

  make_fake_dig "$fakebin"
}

# make_fake_dig <dir> [argv-log]: the resolver stand-in. Output shape is driven
# by FM_FAKE_DIG_MODE, including BIND `host`'s "not found: 2(SERVFAIL)" wording
# and a dscacheutil-shaped usage block, so classification can be exercised
# behaviorally on any host without the real binary. It records its own argv so an
# assertion can prove which candidate actually ran.
make_fake_dig() {
  local dir=$1 log=${2-${FM_FAKE_DIG_LOG:-/dev/null}}
  cat > "$dir/dig" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
query_type=A
for arg in "\$@"; do [ "\$arg" = AAAA ] && query_type=AAAA; done
case "\${FM_FAKE_DIG_MODE:-address}" in
  nxdomain) printf 'status: NXDOMAIN\nno answer\n' ; exit 0 ;;
  empty) printf ';; no addresses\n'; exit 0 ;;
  servfail) printf 'status: SERVFAIL\n'; exit 0 ;;
  host-servfail) printf 'Host $PROBE_HOST not found: 2(SERVFAIL)\n'; exit 1 ;;
  host-refused) printf 'Host $PROBE_HOST not found: 5(REFUSED)\n'; exit 1 ;;
  usage) printf 'Usage: dscacheutil -cachedelete | -flushcache | -L | -q name | -m\n'; exit 64 ;;
  timestamp) printf '2026-10-04T12:34:56Z\n'; exit 0 ;;
  server-only) printf '%s\n' \
    ';; Query time: 1 msec' \
    ';; SERVER: 100.100.100.100#53(100.100.100.100)' \
    ';; WHEN: Mon Oct 07 00:00:00 UTC 2026' ; exit 0 ;;
  authority-additional) if [ "\$query_type" = AAAA ]; then printf 'unfamiliar response\n'; else printf '%s\n' \
    ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345' \
    ';; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1' \
    ';; AUTHORITY SECTION:' \
    'example.invalid. 300 IN A 1.2.3.4' \
    ';; ADDITIONAL SECTION:' \
    'ns.example.invalid. 300 IN AAAA 2001:db8::1'; fi; exit 0 ;;
  nodata) printf '%s\n' \
    '; <<>> DiG 9.10.6 <<>> nodata.example.invalid' \
    ';; global options: +cmd' \
    ';; Got answer:' \
    ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345' \
    ';; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1' \
    '' \
    ';; QUESTION SECTION:' \
    ';nodata.example.invalid. IN A' \
    '' \
    ';; AUTHORITY SECTION:' \
    'example.invalid. 3600 IN SOA ns.example.invalid. hostmaster.example.invalid. 1 7200 3600 1209600 86400' \
    '' \
    ';; Query time: 1 msec' \
    ';; SERVER: 100.100.100.100#53(100.100.100.100)' \
    ';; WHEN: Mon Oct 07 00:00:00 UTC 2026' \
    ';; MSG SIZE  rcvd: 100' ; exit 0 ;;
  answer-diagnostics) printf '%s\n' \
    ';; Query time: 1 msec' \
    ';; SERVER: 100.100.100.100#53(100.100.100.100)' \
    ';; ANSWER SECTION:' \
    'nodata.example.invalid. 300 IN A 1.2.3.4' ; exit 0 ;;
  digrc) if [ "\$query_type" = AAAA ]; then printf '%s\\n' \
    ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345' \
    ';; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0'; else printf 'example.invalid. A 1.2.3.4\\n'; fi; exit 0 ;;
  ipv6) printf ';; ANSWER SECTION:\\nexample.invalid. 300 IN AAAA 2001:db8::1\\n'; exit 0 ;;
  a-noanswer) if [ "\$query_type" = AAAA ]; then printf ';; ANSWER SECTION:\nexample.invalid. 300 IN AAAA 2001:db8::1\n'; else printf ';; no A records\n'; fi; exit 0 ;;
  a-aaaa-error) if [ "\$query_type" = AAAA ]; then printf 'unrecognized resolver failure\n'; exit 9; else printf ';; no A records\n'; exit 0; fi ;;
  fail) printf 'connection failed\n'; exit 9 ;;
  hang) sleep 30; printf 'ok\n'; exit 0 ;;
  *) printf ';; ANSWER SECTION:\nexample.invalid. 300 IN A 1.2.3.4\n'; exit 0 ;;
esac
SH
  chmod +x "$dir/dig"
}

new_case() {
  local dir=$1
  mkdir -p "$dir"
  make_standins "$dir"
  : > "$dir/urls.log"; : > "$dir/calls.log"; : > "$dir/dig.log"
}

# --- loopback listener ------------------------------------------------------
#
# start_proxy_listener <portfile> <logfile>: bind a loopback listener on an
# ephemeral port, publish that port to <portfile>, accept one connection, and
# write the received bytes to <logfile>. The port travels through a file rather
# than stdout because the listener runs in the background; a command
# substitution would run it in a subshell whose pid the caller cannot wait on.
LISTENER_PID=''
start_proxy_listener() {
  python3 - "$1" "$2" <<'PY' &
import socket, sys
portfile, logfile = sys.argv[1], sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(4)
with open(portfile, 'w') as f:
    f.write(str(s.getsockname()[1]))
s.settimeout(2)
data = b''
try:
    conn, _ = s.accept()
    conn.settimeout(1)
    while True:
        try:
            chunk = conn.recv(65536)
        except Exception:
            break
        if not chunk:
            break
        data += chunk
    conn.close()
except Exception:
    pass
with open(logfile, 'wb') as f:
    f.write(data)
PY
  LISTENER_PID=$!
}

wait_for_file() {
  local file=$1 i=0
  while [ ! -s "$file" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$file" ] || fail "listener never published its port in $file"
}

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# --- the probe exists and documents its contract ----------------------------
[ -x "$SCRIPT" ] || fail "bin/fm-provider-reach-probe.sh is missing or not executable"

out=$("$SCRIPT" --help 2>&1); rc=$?
expect_code 0 "$rc" "help exits 0"
assert_contains "$out" "routed-auth" "help names the 401/403 verdict"
assert_contains "$out" "unreachable" "help names the unreachable verdict"
assert_contains "$out" "renders no verdict" "help states the probe holds no routing judgment"
assert_contains "$out" "--host" "help documents the explicit endpoint interface"
assert_not_contains "$out" "Registered targets" "the probe advertises no built-in provider endpoint"
assert_not_contains "$out" "xhyapi.com" "shared help contains no provider-specific target"

# --- HTTP 200: routable and answering, and nothing more ---------------------
tmp=$TMP_ROOT/ok; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "http 200 probes as reachable (exit 0)"
assert_contains "$out" "result=reachable" "http 200 wording is reachable"
assert_contains "$out" "http=200" "http 200 line carries the code"
assert_contains "$out" "dns=ok" "a resolved name reports dns=ok"
assert_not_contains "$out" "available" "a 2xx is never worded as channel-available"
assert_not_contains "$out" "eligible" "the probe renders no dispatch eligibility"

# --- HTTP 401 / 403: routing proven, usability NOT proven -------------------
for code in 401 403; do
  tmp=$TMP_ROOT/auth-$code; new_case "$tmp"
  out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=$code FM_FAKE_DIG_MODE=address \
    FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
    "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
  expect_code 10 "$rc" "http $code exits 10"
  assert_contains "$out" "result=routed-auth" "http $code wording is routed-auth"
  assert_contains "$out" "http=$code" "http $code line carries the code"
  assert_contains "$out" "dns=ok" "http $code still reports a resolved name"
done

# --- HTTP 000: cannot connect ------------------------------------------------
tmp=$TMP_ROOT/zero; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=000 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "http 000 exits 20"
assert_contains "$out" "result=unreachable" "http 000 wording is unreachable"
assert_contains "$out" "reason=no_connection" "http 000 names the connection failure"
assert_not_contains "$out" "routed-auth" "a dead connection is never reported as reachable routing"

# --- HTTP 5xx: answered but unhealthy ---------------------------------------
tmp=$TMP_ROOT/server; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=502 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 11 "$rc" "http 502 exits 11"
assert_contains "$out" "result=server-error" "http 502 wording is server-error"

# --- a status code survives curl exiting non-zero ---------------------------
# An endpoint that answers with a 2xx/401 header and then truncates the body makes
# curl print the code and exit non-zero. The code is a valid fact and must not be
# discarded; only an absent or malformed code is 000.
tmp=$TMP_ROOT/partial-200; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_MODE=partial FM_FAKE_CURL_CODE=200 \
  FM_FAKE_DIG_MODE=address FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a 200 with a truncated body is still reachable"
assert_contains "$out" "http=200" "the captured 200 survives curl's non-zero exit"
assert_contains "$out" "result=reachable" "a truncated 200 is not downgraded to unreachable"
assert_not_contains "$out" "reason=no_connection" "a truncated 200 is not reported as no connection"

tmp=$TMP_ROOT/partial-401; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_MODE=partial FM_FAKE_CURL_CODE=401 \
  FM_FAKE_DIG_MODE=address FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 10 "$rc" "a 401 with a truncated body is still routed-auth"
assert_contains "$out" "http=401" "the captured 401 survives curl's non-zero exit"
assert_contains "$out" "result=routed-auth" "a truncated 401 is not downgraded to unreachable"

# --- status-only: no response body file is ever created ---------------------
# The body is discarded to /dev/null. A mktemp stand-in that always fails must
# never be invoked, and the fake curl must be handed -o /dev/null rather than a
# temp path, so no predictable file exists for a local attacker to redirect.
tmp=$TMP_ROOT/no-body-file; new_case "$tmp"
real_mktemp=$(command -v mktemp)
cat > "$tmp/mktemp" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 0 ]; then
  printf 'bare-mktemp-called\n' >> "$tmp/mktemp.log"
  exit 1
fi
exec "$real_mktemp" "\$@"
SH
chmod +x "$tmp/mktemp"
: > "$tmp/mktemp.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_LOG="$tmp/calls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "the probe works without creating a response-body file"
assert_contains "$out" "result=reachable" "the status-only probe still reports reachable"
[ ! -s "$tmp/mktemp.log" ] || fail "the probe still creates a response-body temp file: $(cat "$tmp/mktemp.log")"
assert_contains "$(cat "$tmp/calls.log")" "-o /dev/null" "the response body is directed to /dev/null, not a file"

# --- NXDOMAIN: no address, so the request phase is skipped ------------------
tmp=$TMP_ROOT/nxdomain; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=nxdomain FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "NXDOMAIN exits 20"
assert_contains "$out" "dns=nxdomain" "NXDOMAIN is reported as its own finding"
assert_contains "$out" "result=unreachable" "NXDOMAIN wording is unreachable"
assert_contains "$out" "http=none" "NXDOMAIN requests nothing over HTTP"
[ ! -s "$tmp/urls.log" ] || fail "NXDOMAIN path still issued an HTTP request: $(cat "$tmp/urls.log")"

# --- a resolvable name with no address is the same finding ------------------
tmp=$TMP_ROOT/empty-answer; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=empty FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "an addressless answer exits 20"
assert_contains "$out" "dns=nxdomain" "an addressless answer is the no-address class"

# --- a failing resolver is a lookup failure, never a success claim ----------
tmp=$TMP_ROOT/dns-fail; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=fail FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a failed lookup still allows HTTP probing"
assert_contains "$out" "dns=unknown" "a failed lookup without no-record proof is unknown"
assert_contains "$out" "result=reachable" "a failed lookup does not prevent a successful HTTP response"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP follows an uncertain DNS result"

# --- resolver errors and successful no-address answers are distinct ----------
tmp=$TMP_ROOT/dns-servfail; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=servfail FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "SERVFAIL still allows HTTP probing"
assert_contains "$out" "dns=unknown" "SERVFAIL is uncertain, not proof of no records"
assert_contains "$out" "result=reachable" "HTTP follows SERVFAIL"

# BIND `host` renders every non-NXDOMAIN rcode with the same "not found" wording,
# so a classification that tests "not found" before the rcode would mislabel
# these as a successful no-address lookup. Drive that exact wording.
tmp=$TMP_ROOT/host-servfail; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=host-servfail FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "host-shaped SERVFAIL still allows HTTP probing"
assert_contains "$out" "dns=unknown" "host's 'not found: 2(SERVFAIL)' is uncertain, not no-address"
assert_not_contains "$out" "dns=nxdomain" "a SERVFAIL is never classified as a successful no-address answer"

tmp=$TMP_ROOT/host-refused; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=host-refused FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "host-shaped REFUSED still allows HTTP probing"
assert_contains "$out" "dns=unknown" "host's 'not found: 5(REFUSED)' is uncertain, not no-address"
assert_not_contains "$out" "dns=nxdomain" "a REFUSED is never classified as a successful no-address answer"

# A resolver that rejects the call shape (macOS dscacheutil's usage block and
# exit 64) is a resolver error too, never an answer and never leaked into the
# probe's one line.
tmp=$TMP_ROOT/usage-resolver; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=usage FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a usage-block resolver still allows HTTP probing"
assert_contains "$out" "dns=unknown" "a resolver that rejects the call shape is uncertain"
assert_not_contains "$out" "dns=nxdomain" "a usage block is never classified as a successful no-address answer"
assert_not_contains "$out" "Usage:" "the probe line never carries a tool's usage text"

tmp=$TMP_ROOT/timestamp-not-address; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=timestamp FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "timestamp-only output still allows HTTP probing"
assert_contains "$out" "dns=unknown" "timestamp digits are not classified as an IP address or no-record proof"

# dig's SERVER and WHEN metadata live on `;` comment lines and must never be read
# as an answer address: the SERVER IPv4 and the WHEN colon-run both look like one.
# A realistic NODATA reply (status NOERROR, zero answers) therefore stays the
# no-address class and issues no request.
tmp=$TMP_ROOT/server-diagnostics-only; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=server-only FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "diagnostic-only resolver output still allows HTTP probing"
assert_contains "$out" "dns=unknown" "the SERVER IPv4 and WHEN colon-run are not answers or no-record proof"
assert_contains "$out" "result=reachable" "HTTP follows uncertain diagnostic-only output"

tmp=$TMP_ROOT/nodata; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=nodata FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "a NOERROR answer with zero address records exits 20"
assert_contains "$out" "dns=nxdomain" "NODATA is the no-address class, never dns=ok"
assert_contains "$out" "http=none" "NODATA issues no HTTP request"
assert_not_contains "$out" "dns=ok" "dig SERVER/WHEN diagnostics are never read as an address"
[ ! -s "$tmp/urls.log" ] || fail "NODATA still issued an HTTP request: $(cat "$tmp/urls.log")"

tmp=$TMP_ROOT/authority-additional-only; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=authority-additional FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "authority/additional records do not prove an A answer"
assert_contains "$out" "dns=unknown" "addresses outside dig's answer output are not treated as resolved"
assert_contains "$out" "result=reachable" "HTTP follows uncertain DNS output"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP proceeds after no answer-section address"

tmp=$TMP_ROOT/ipv4-mawk-compat; new_case "$tmp"
real_awk=$(command -v awk) || fail "awk is required for the compatibility fixture"
cat > "$tmp/awk" <<SH
#!/usr/bin/env bash
# Model mawk versions that treat ERE interval expressions literally.
for arg in "\$@"; do
  case "\$arg" in *'{1,3}'*|*'{3}'*) exit 2 ;; esac
done
exec "$real_awk" "\$@"
SH
chmod +x "$tmp/awk"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=address FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "an IPv4 answer works with interval-incompatible awk"
assert_contains "$out" "dns=ok" "IPv4 validation does not depend on awk intervals"
assert_contains "$out" "result=reachable" "HTTP follows a valid IPv4 answer under mawk-like awk"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "IPv4 answer still reaches HTTP under mawk-like awk"
tmp=$TMP_ROOT/digrc-nottl-noclass; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=digrc FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" FM_FAKE_DIG_LOG="$tmp/dig.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "dig output without TTL/class still recognizes an A answer"
assert_contains "$out" "dns=ok" "a ~/.digrc-style A record proves DNS success"
assert_contains "$out" "result=reachable" "HTTP follows the valid ~/.digrc-style A record"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP proceeds after the valid A answer"
assert_contains "$(cat "$tmp/dig.log")" "+noall +answer +comments $PROBE_HOST A" "the A lookup overrides ~/.digrc with a fixed format and explicit type"
[ "$(wc -l < "$tmp/dig.log" | tr -d ' ')" = 1 ] || fail "a valid A answer should avoid the unnecessary AAAA fallback"

tmp=$TMP_ROOT/answer-with-diagnostics; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=answer-diagnostics FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a real answer among diagnostics proceeds to HTTP"
assert_contains "$out" "dns=ok" "a real address record is still recognized"
assert_contains "$out" "dns_detail=nodata.example.invalid. 300 IN A 1.2.3.4" "the reported detail is the answer record, not the banner"

tmp=$TMP_ROOT/aaaa-unrecognized-failure; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=a-aaaa-error FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "an unrecognized failed AAAA query proceeds to HTTP"
assert_contains "$out" "dns=unknown" "an uncertain AAAA lookup is never called NXDOMAIN"
assert_not_contains "$out" "dns=nxdomain" "a failed AAAA query is not proof of no records"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP follows the failed AAAA query"

tmp=$TMP_ROOT/ipv6-address; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=a-noanswer FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "an AAAA-only answer proceeds to HTTP"
assert_contains "$out" "dns=ok" "an AAAA-only name is not classified as no-address"
assert_not_contains "$out" "dns=nxdomain" "an AAAA-only name is never reported as NXDOMAIN"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "an AAAA-only name still reaches the HTTP probe"

tmp=$TMP_ROOT/aaaa-unrecognized-failure; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=a-aaaa-error FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "an unrecognized failed AAAA query proceeds to HTTP"
assert_contains "$out" "dns=unknown" "an uncertain AAAA lookup is never called NXDOMAIN"
assert_not_contains "$out" "dns=nxdomain" "a failed AAAA query is not proof of no records"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP follows the failed AAAA query"

# --- the resolver sees only the host, never a port or an IP literal ---------
# `--host` admits an optional port and IP-literal authorities. The resolver takes
# a bare DNS name, so only the host component may reach it, and an IP literal
# needs no lookup at all. A build that handed the authority verbatim asked dig for
# `host:port`, which it treats as a query name, so a reachable endpoint was
# recorded as NXDOMAIN before the request ran.
tmp=$TMP_ROOT/host-with-port; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST:8443" 2>&1); rc=$?
expect_code 0 "$rc" "a host:port authority still probes over HTTP"
assert_contains "$out" "dns=ok" "the host component resolves"
assert_contains "$out" "dns_detail=example.invalid. 300 IN A 1.2.3.4" "the DNS answer record is reported"
[ "$(cat "$tmp/dig.log")" = "+noall +answer +comments $PROBE_HOST A" ] || fail "the resolver was handed a port-bearing name or non-fixed query: $(cat "$tmp/dig.log")"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST:8443" "the port is preserved in the HTTPS URL"

tmp=$TMP_ROOT/ipv4-literal; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "127.0.0.1:8443" 2>&1); rc=$?
expect_code 0 "$rc" "an IPv4-literal authority probes without a lookup"
assert_contains "$out" "dns=skipped" "an IPv4 literal needs no lookup"
assert_contains "$out" "dns_detail=dns_literal" "the skip is disclosed in the documented detail field"
assert_contains "$out" "http=200" "the IPv4-literal request still runs"
assert_contains "$(cat "$tmp/urls.log")" "https://127.0.0.1:8443" "the literal and port are preserved"
[ ! -s "$tmp/dig.log" ] || fail "an IPv4 literal still ran a resolver: $(cat "$tmp/dig.log")"

tmp=$TMP_ROOT/ipv6-literal; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "[::1]:8443" 2>&1); rc=$?
expect_code 0 "$rc" "a bracketed IPv6 authority probes without a lookup"
assert_contains "$out" "dns=skipped" "a bracketed IPv6 literal needs no lookup"
assert_contains "$out" "dns_detail=dns_literal" "the IPv6 skip is disclosed in the documented detail field"
assert_contains "$(cat "$tmp/urls.log")" "https://[::1]:8443" "the bracketed IPv6 and port are preserved"
[ ! -s "$tmp/dig.log" ] || fail "an IPv6 literal still ran a resolver: $(cat "$tmp/dig.log")"

# --- a glob in the resolver list stays a literal token ----------------------
# The configured value is split on whitespace. A shell `for` over the unquoted
# variable would also pathname-expand it, so an absolute glob entry could expand
# into an unrelated executable in the filesystem and be run as the resolver.
# The list here names an existing executable through a literal glob; the probe
# must skip it (no such literal path) and fall through to dig.
tmp=$TMP_ROOT/glob-candidate; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
cat > "$tmp/evil1" <<SH
#!/usr/bin/env bash
printf 'expanded-glob-ran\n' >> "$tmp/evil.log"
printf '9.9.9.9\n'
SH
chmod +x "$tmp/evil1"
: > "$tmp/evil.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL="$tmp/evil* dig" FM_FAKE_DIG_LOG="$tmp/dig.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a glob in the resolver list does not break resolution"
assert_contains "$out" "dns=ok" "the literal-miss entry is skipped and dig still answers"
assert_not_contains "$out" "9.9.9.9" "a glob-expanded executable was never used as the resolver"
[ ! -s "$tmp/evil.log" ] || fail "a glob in the resolver list expanded and ran $tmp/evil1: $(cat "$tmp/evil.log")"
[ "$(grep -c . "$tmp/dig.log")" = 1 ] || fail "expected exactly one dig call, got: $(cat "$tmp/dig.log")"

# --- a preference list tries every entry until one is installed -------------
# The configured value is one tool OR a whitespace-separated list, so availability
# is decided per entry. A build that tested the whole string as a single executable
# skipped the resolver that was actually on PATH and reported `dns=skipped`
# `dns_tool_missing=dig host` for a name that resolves through dig.
later_dir=$TMP_ROOT/list-second-entry; new_case "$later_dir"
mkdir -p "$later_dir/onlydig"
make_fake_dig "$later_dir/onlydig" "$later_dir/pref.log"
: > "$later_dir/pref.log"
out=$(PATH="$later_dir/onlydig:$later_dir:$BASE_PATH" FM_FAKE_CURL_CODE=200 \
  FM_PROVIDER_REACH_DNS_TOOL='nosuchresolver dig' \
  FM_FAKE_CURL_URL_LOG="$later_dir/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a usable later entry in the list still gets its HTTP phase"
assert_contains "$out" "dns=ok" "an installed entry further down the list is tried, not skipped"
assert_contains "$out" "dns_detail=example.invalid. 300 IN A 1.2.3.4" "the tried entry's own answer record is reported"
assert_not_contains "$out" "dns_tool_missing" "a partially usable list is never disclosed as a missing resolver"
assert_not_contains "$out" "dns=fail" "an absent earlier entry is skipped, not reported as a lookup failure"
[ "$(grep -c . "$later_dir/pref.log")" = 1 ] || fail "expected exactly one resolver call, got: $(cat "$later_dir/pref.log")"
assert_contains "$(cat "$later_dir/pref.log")" "$PROBE_HOST" "the tried resolver was handed the probed authority"

# --- resolver failures fall through to later candidates --------------------
# A configured preference list means try the next installed resolver after a
# timeout, non-zero exit, or SERVFAIL/REFUSED response. A valid no-address result
# remains terminal, so this fixture also verifies that the second resolver ran
# only for the error cases.
for mode in servfail fail hang; do
  tmp=$TMP_ROOT/resolver-fallback-$mode; new_case "$tmp"
  cat > "$tmp/firstresolver" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_FIRST_MODE:-}" in
  servfail) printf 'status: SERVFAIL\n'; exit 0 ;;
  fail) printf 'resolver failed\n'; exit 9 ;;
  hang) sleep 30; exit 0 ;;
esac
SH
  chmod +x "$tmp/firstresolver"
  make_fake_dig "$tmp" "$tmp/second.log"
  : > "$tmp/second.log"
  out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_FIRST_MODE="$mode" FM_FAKE_DIG_MODE=address \
    FM_PROVIDER_REACH_DNS_TOOL='firstresolver dig' FM_PROVIDER_REACH_PROBE_TIMEOUT=1 \
    FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
  expect_code 0 "$rc" "a $mode first resolver falls through to a working candidate"
  assert_contains "$out" "dns=ok" "a successful later resolver determines dns=ok after $mode"
  assert_contains "$out" "result=reachable" "HTTP follows the successful fallback after $mode"
  [ "$(grep -c . "$tmp/second.log")" = 1 ] || fail "the second resolver did not run after $mode: $(cat "$tmp/second.log")"
done

tmp=$TMP_ROOT/resolver-fallback-nxdomain; new_case "$tmp"
cat > "$tmp/firstresolver" <<'SH'
#!/usr/bin/env bash
printf 'status: NXDOMAIN\nno answer\n'
SH
chmod +x "$tmp/firstresolver"
make_fake_dig "$tmp" "$tmp/second.log"
: > "$tmp/second.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL='firstresolver dig' "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "a valid NXDOMAIN answer is terminal"
assert_contains "$out" "dns=nxdomain" "NXDOMAIN remains terminal with a later candidate configured"
[ ! -s "$tmp/second.log" ] || fail "the second resolver ran after terminal NXDOMAIN: $(cat "$tmp/second.log")"

tmp=$TMP_ROOT/resolver-fallback-success-unknown; new_case "$tmp"
cat > "$tmp/firstresolver" <<'SH'
#!/usr/bin/env bash
printf 'unfamiliar successful resolver output\\n'
exit 0
SH
chmod +x "$tmp/firstresolver"
make_fake_dig "$tmp" "$tmp/second.log"
: > "$tmp/second.log"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=address FM_PROVIDER_REACH_DNS_TOOL='firstresolver dig' \
  FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "successful unknown resolver output falls through"
assert_contains "$out" "dns=ok" "later recognized resolver determines DNS"
[ "$(grep -c . "$tmp/second.log")" = 1 ] || fail "later resolver was not tried after unknown success"

tmp=$TMP_ROOT/resolver-all-success-unknown; new_case "$tmp"
cat > "$tmp/firstresolver" <<'SH'
#!/usr/bin/env bash
printf 'unfamiliar successful resolver output\\n'
exit 0
SH
chmod +x "$tmp/firstresolver"
cat > "$tmp/secondresolver" <<'SH'
#!/usr/bin/env bash
printf '\\n'
exit 0
SH
chmod +x "$tmp/secondresolver"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL='firstresolver secondresolver' \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "all successful unknown resolver output still allows HTTP"
assert_contains "$out" "dns=unknown" "unrecognized successes remain uncertain"
assert_contains "$out" "result=reachable" "HTTP proceeds when all resolver output is uncertain"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "HTTP follows all unknown resolver results"

# --- every entry missing is disclosed as a skipped lookup -------------------
# The same preference-list semantics, from the other end: when no listed entry is
# installed, nothing was looked up, and that stays a disclosure rather than becoming
# an outage claim. The probe must still complete its HTTP phase, so the request
# log is the observable proof that the skipped lookup did not short-circuit it.
tmp=$TMP_ROOT/no-dns-tool; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_PROVIDER_REACH_DNS_TOOL=no-such-resolver \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a missing resolver does not block the HTTP phase"
assert_contains "$out" "dns=skipped" "a missing resolver reports dns=skipped"
assert_contains "$out" "dns_tool_missing" "a missing resolver is disclosed in the line"
assert_not_contains "$out" "dns_tool_missing=no-such-resolver" "the disclosure names no usable resolver without echoing the list back"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "a missing resolver still issued the HTTP request"

# --- a blank resolver override is an empty list, never a shell crash --------
# A whitespace-only override is non-empty, so `:-` does not substitute the
# default; `read -ra` then leaves an empty array. On Bash 3.2 under set -u,
# expanding `"${tools[@]}"` on that empty array aborts with "unbound variable"
# and disables DNS. It must be treated as an empty preference list: DNS skipped,
# HTTP still attempted, and no raw shell error on stderr.
tmp=$TMP_ROOT/blank-dns-tool; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_PROVIDER_REACH_DNS_TOOL=' ' \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a whitespace-only resolver override still probes"
assert_contains "$out" "dns=skipped" "a blank override is an empty preference list"
assert_contains "$out" "dns_tool_missing" "a blank override is disclosed as no usable resolver"
assert_not_contains "$out" "unbound variable" "a blank override never leaks a raw shell error"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "a blank override still issued the HTTP request"

# --- the bound is real, on both phases --------------------------------------
tmp=$TMP_ROOT/hang-http; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_MODE=hang FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_PROVIDER_REACH_PROBE_TIMEOUT=1 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 20 "$rc" "a hanging endpoint is bounded to unreachable"
assert_contains "$out" "result=unreachable" "a hanging endpoint wording is unreachable"

tmp=$TMP_ROOT/hang-dns; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=hang FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_PROVIDER_REACH_PROBE_TIMEOUT=1 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "a hanging resolver is bounded and HTTP proceeds"
assert_contains "$out" "dns=unknown" "a hanging resolver is uncertain, not proof of no records"
assert_contains "$out" "result=reachable" "HTTP follows a bounded resolver timeout"

# --- unauthenticated, single request, no credential surface -----------------
tmp=$TMP_ROOT/unauth; new_case "$tmp"
PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  FM_FAKE_CURL_LOG="$tmp/calls.log" \
  API_KEY="$SENTINEL_KEY" TYPESAFE_API_KEY="$SENTINEL_KEY" \
  "$SCRIPT" --host "$PROBE_HOST" >/dev/null 2>&1 || true
urls=$(cat "$tmp/urls.log")
assert_contains "$urls" "https://$PROBE_HOST" "the probe requests the authority the caller named"
[ "$(printf '%s\n' "$urls" | grep -c .)" = 1 ] || fail "expected exactly one HTTP request, got: $urls"
calls=$(cat "$tmp/calls.log")
assert_not_contains "$calls" "-H" "the probe sends no auth header"
assert_not_contains "$calls" "Authorization" "the probe sends no Authorization header"
assert_not_contains "$calls" "$SENTINEL_KEY" "no ambient credential value reaches the request"
assert_not_contains "$urls" "key=" "the probe URL carries no query credential"

# --- curl -q ignores user curl configuration, proven against a listener ------
# The intent requires that curl's credential isolation survive: no ~/.curlrc
# proxy, credentials, or other user configuration may steer the request. A fake
# curl cannot prove this because it never honors the config. This case runs the
# host's real curl against a loopback listener while a temporary HOME carries a
# .curlrc proxy with credentials. A control invocation without -q must hit the
# listener and expose Proxy-Authorization (proving the fixture is live); the
# probe's own invocation passes -q, so a fresh listener must stay silent.
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the local curl-config listener"
curl_bin=$(command -v curl) || fail "curl is required for the curl-config isolation case"
# Real curl must treat brace/bracket path characters literally and send exactly
# one request. The local HTTP server persists briefly to expose accidental URL
# glob expansion as multiple observable requests.
glob_portfile=$TMP_ROOT/glob.port
glob_log=$TMP_ROOT/glob.log
glob_cert=$TMP_ROOT/glob-cert.pem
glob_key=$TMP_ROOT/glob-key.pem
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$glob_key" -out "$glob_cert" -subj '/CN=127.0.0.1' -days 1 >/dev/null 2>&1 || fail "openssl is required for the local HTTPS glob fixture"
python3 - "$glob_portfile" "$glob_log" "$glob_cert" "$glob_key" <<'PY' &
import http.server, ssl, sys
portfile, logfile, certfile, keyfile = sys.argv[1:5]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(logfile, 'a') as f: f.write(self.path + '\n')
        self.send_response(200); self.end_headers()
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile, keyfile)
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(portfile, 'w') as f: f.write(str(server.server_port))
server.timeout = 2
server.handle_request()
server.server_close()
PY
GLOB_PID=$!
wait_for_file "$glob_portfile"
glob_port=$(cat "$glob_portfile")
env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
  -u NO_PROXY -u no_proxy -u CURL_HOME -u XDG_CONFIG_HOME \
  PATH="$BASE_PATH" CURL_CA_BUNDLE="$glob_cert" FM_PROVIDER_REACH_DNS_TOOL=missing \
  "$SCRIPT" --host "127.0.0.1:$glob_port/{health,status}[v1]" >/dev/null 2>&1
wait "$GLOB_PID" 2>/dev/null || true
[ "$(wc -l < "$glob_log" | tr -d ' ')" = 1 ] || fail "curl URL glob sent more than one request: $(cat "$glob_log")"
[ "$(cat "$glob_log")" = '/{health,status}[v1]' ] || fail "curl did not preserve the literal path: $(cat "$glob_log")"

tmp=$TMP_ROOT/curl-q-isolation
digdir=$tmp/digbin
mkdir -p "$digdir" "$tmp/home"
make_fake_dig "$digdir"

control_portfile=$tmp/control.port
control_log=$tmp/control.log
start_proxy_listener "$control_portfile" "$control_log"
control_pid=$LISTENER_PID
wait_for_file "$control_portfile"
control_port=$(cat "$control_portfile")
printf 'proxy = "http://127.0.0.1:%s"\nproxy-user = "armpuser:armpass"\n' "$control_port" > "$tmp/home/.curlrc"
env -u CURL_HOME -u XDG_CONFIG_HOME -u no_proxy -u NO_PROXY -u ALL_PROXY -u all_proxy \
  -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
  HOME="$tmp/home" "$curl_bin" -sS -o /dev/null --max-time 3 "https://127.0.0.1:1/" >/dev/null 2>&1 || true
wait "$control_pid" 2>/dev/null || true
assert_contains "$(cat "$control_log")" "Proxy-Authorization" "the fixture .curlrc credentials are honored when curl does not receive -q"

probe_portfile=$tmp/probe.port
probe_log=$tmp/probe.log
start_proxy_listener "$probe_portfile" "$probe_log"
probe_pid=$LISTENER_PID
wait_for_file "$probe_portfile"
probe_port=$(cat "$probe_portfile")
printf 'proxy = "http://127.0.0.1:%s"\nproxy-user = "armpuser:armpass"\n' "$probe_port" > "$tmp/home/.curlrc"
target_port=$(free_port)
out=$(env -u CURL_HOME -u XDG_CONFIG_HOME -u no_proxy -u NO_PROXY -u ALL_PROXY -u all_proxy \
  -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
  HOME="$tmp/home" PATH="$digdir:$BASE_PATH" FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_PROVIDER_REACH_PROBE_TIMEOUT=3 \
  "$SCRIPT" --host "127.0.0.1:$target_port" 2>&1); rc=$?
wait "$probe_pid" 2>/dev/null || true
expect_code 20 "$rc" "the direct connection to a closed loopback port is unreachable"
assert_contains "$out" "http=000" "the probe completed its own request without the user proxy"
[ ! -s "$probe_log" ] || fail "curl honored the user .curlrc proxy despite -q: $(cat "$probe_log")"

# --- proxy environment is explicit, credential-safe, and reported ------------
proxy_env=(-u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy -u CURL_HOME -u XDG_CONFIG_HOME)
for proxy_name in HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
  tmp=$TMP_ROOT/proxy-credential-$proxy_name; new_case "$tmp"
  out=$(env "${proxy_env[@]}" "$proxy_name=http://private:secret@proxy.example:8080" \
    PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
    FM_FAKE_CURL_LOG="$tmp/calls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
  expect_code 2 "$rc" "$proxy_name credentials are refused"
  assert_contains "$out" "proxy URL carries credentials" "$proxy_name refusal uses fixed safe text"
  assert_not_contains "$out" "private:secret" "$proxy_name credentials are never echoed"
  [ ! -s "$tmp/calls.log" ] || fail "$proxy_name was not refused before curl ran: $(cat "$tmp/calls.log")"
done

tmp=$TMP_ROOT/proxy-user-only; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://user@proxy.example:8080' \
  PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_FAKE_CURL_LOG="$tmp/calls.log" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 2 "$rc" "proxy userinfo without a password is refused"
assert_contains "$out" "proxy URL carries credentials" "proxy userinfo refusal uses fixed safe text"
assert_not_contains "$out" "user@proxy.example" "proxy URL is never echoed"
[ ! -s "$tmp/calls.log" ] || fail "proxy userinfo reached curl: $(cat "$tmp/calls.log")"

tmp=$TMP_ROOT/proxy-safe; new_case "$tmp"
out=$(env "${proxy_env[@]}" https_proxy='http://proxy.example:8080' \
  PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "credential-free proxy remains allowed"
assert_contains "$out" "route=via-proxy" "proxied result is labeled"

tmp=$TMP_ROOT/direct; new_case "$tmp"
out=$(env "${proxy_env[@]}" PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "proxy-free direct request completes"
assert_contains "$out" "route=direct" "direct result is labeled"

tmp=$TMP_ROOT/irrelevant-http-proxy; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTP_PROXY='http://private:secret@proxy.example:8080' \
  PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "HTTP proxy credentials do not affect an HTTPS request"
assert_contains "$out" "route=direct" "an irrelevant HTTP proxy does not alter route reporting"

# Prove curl's port-qualified behavior with the real executable: the local proxy
# observes CONNECT plus Proxy-Authorization even when NO_PROXY includes :443.
real_proxy_portfile=$TMP_ROOT/real-proxy.port
real_proxy_log=$TMP_ROOT/real-proxy.log
start_proxy_listener "$real_proxy_portfile" "$real_proxy_log"
real_proxy_pid=$LISTENER_PID
wait_for_file "$real_proxy_portfile"
real_proxy_port=$(cat "$real_proxy_portfile")
env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
  -u NO_PROXY -u no_proxy -u CURL_HOME -u XDG_CONFIG_HOME \
  HTTPS_PROXY="http://localuser:localpass@127.0.0.1:$real_proxy_port" \
  NO_PROXY='api.example.invalid:443' "$curl_bin" -q -sS --max-time 1 \
  'https://api.example.invalid:443/' >/dev/null 2>&1 || true
wait "$real_proxy_pid" 2>/dev/null || true
assert_contains "$(cat "$real_proxy_log")" 'CONNECT api.example.invalid:443' "real curl does not bypass a proxy for port-qualified NO_PROXY"
assert_contains "$(cat "$real_proxy_log")" 'Proxy-Authorization' "real curl sends proxy auth when port-qualified NO_PROXY is ignored"

# curl does not honor port-qualified NO_PROXY entries. Bare host/domain suffix
# entries bypass the proxy and are reported as direct.
tmp=$TMP_ROOT/no-proxy-port-mismatch; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
  NO_PROXY="$PROBE_HOST:443" PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_LOG="$tmp/calls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 2 "$rc" "NO_PROXY host:443 does not bypass proxy credential refusal for HTTPS"
assert_contains "$out" "proxy URL carries credentials" "the mismatched port retains effective proxy credentials"
[ ! -s "$tmp/calls.log" ] || fail "a mismatched NO_PROXY port reached curl"

tmp=$TMP_ROOT/no-proxy-port-match; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
  NO_PROXY="$PROBE_HOST:8443" PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_LOG="$tmp/calls.log" \
  "$SCRIPT" --host "$PROBE_HOST:8443" 2>&1); rc=$?
expect_code 2 "$rc" "a port-qualified NO_PROXY entry does not bypass proxy credentials"
assert_contains "$out" "proxy URL carries credentials" "port-qualified NO_PROXY retains effective proxy credentials"
[ ! -s "$tmp/calls.log" ] || fail "port-qualified NO_PROXY reached curl"

tmp=$TMP_ROOT/no-proxy-host-suffix; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
  NO_PROXY='example.invalid' PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST:8443" 2>&1); rc=$?
expect_code 0 "$rc" "a bare NO_PROXY domain suffix bypasses proxy credentials"
assert_contains "$out" "route=direct" "bare domain suffix is labeled direct"

tmp=$TMP_ROOT/no-proxy-case-insensitive; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
  NO_PROXY='example.com' PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_CODE=200 "$SCRIPT" --host API.EXAMPLE.COM 2>&1); rc=$?
expect_code 0 "$rc" "$PROBE_HOST hostname matching ignores case for NO_PROXY"
assert_contains "$out" "route=direct" "case-insensitive NO_PROXY suffix is labeled direct"

tmp=$TMP_ROOT/no-proxy-embedded-wildcard; new_case "$tmp"
out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
  NO_PROXY='example.*' PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address FM_FAKE_CURL_LOG="$tmp/calls.log" \
  "$SCRIPT" --host api.example.com 2>&1); rc=$?
expect_code 2 "$rc" "an embedded NO_PROXY wildcard does not bypass credential refusal"
assert_contains "$out" "proxy URL carries credentials" "unsupported NO_PROXY pattern keeps proxy credentials refused"
assert_not_contains "$out" "private:secret" "wildcard refusal never discloses proxy credentials"
[ ! -s "$tmp/calls.log" ] || fail "an embedded NO_PROXY wildcard allowed a credential-bearing HTTP request"

# The test above fixes the operator's variables; this live-curl case proves the
# real curl proxy is not reached before the credential guard rejects the request.
real_wild_proxy_portfile=$TMP_ROOT/real-wild-proxy.port
real_wild_proxy_log=$TMP_ROOT/real-wild-proxy.log
start_proxy_listener "$real_wild_proxy_portfile" "$real_wild_proxy_log"
real_wild_proxy_pid=$LISTENER_PID
wait_for_file "$real_wild_proxy_portfile"
real_wild_proxy_port=$(cat "$real_wild_proxy_portfile")
real_wild_dig_dir=$TMP_ROOT/real-wild-dig-only
mkdir -p "$real_wild_dig_dir"
make_fake_dig "$real_wild_dig_dir" "$TMP_ROOT/real-wild-dig.log"
out=$(env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
  -u NO_PROXY -u no_proxy -u CURL_HOME -u XDG_CONFIG_HOME \
  HTTPS_PROXY="http://private:secret@127.0.0.1:$real_wild_proxy_port" \
  NO_PROXY='example.*' PATH="$real_wild_dig_dir:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_DIG_MODE=address "$SCRIPT" --host api.example.com --timeout 2 2>&1); rc=$?
wait "$real_wild_proxy_pid" 2>/dev/null || true
expect_code 2 "$rc" "real curl plus embedded NO_PROXY wildcard still refuses proxy credentials"
assert_contains "$out" "proxy URL carries credentials" "real curl wildcard regression uses fixed refusal text"
assert_not_contains "$out" "private:secret" "real curl wildcard regression does not disclose credentials"
[ ! -s "$real_wild_proxy_log" ] || fail "credential-bearing real proxy received a request despite NO_PROXY wildcard"

for proxy_settings in https-only https-and-all; do
  tmp=$TMP_ROOT/no-proxy-star-$proxy_settings; new_case "$tmp"
  case "$proxy_settings" in
    https-only) out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' NO_PROXY='*' \
      PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
      FM_FAKE_CURL_CODE=200 "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$? ;;
    https-and-all) out=$(env "${proxy_env[@]}" HTTPS_PROXY='http://private:secret@proxy.example:8080' \
      ALL_PROXY='http://other:secret@proxy.example:8080' NO_PROXY='*' PATH="$tmp:$BASE_PATH" \
      FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address FM_FAKE_CURL_CODE=200 \
      "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$? ;;
  esac
  expect_code 0 "$rc" "NO_PROXY=* permits direct request with $proxy_settings configured"
  assert_contains "$out" "route=direct" "NO_PROXY=* labels $proxy_settings request direct"
done

# --- unknown and malformed input are refusals, never silent guesses ---------
tmp=$TMP_ROOT/unknown-target; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig "$SCRIPT" nosuchprovider 2>&1); rc=$?
expect_code 2 "$rc" "a positional target is no longer accepted"
assert_contains "$out" "unexpected argument" "the refusal names the unsupported argument"

tmp=$TMP_ROOT/missing-host; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" 2>&1); rc=$?
expect_code 2 "$rc" "no --host is refused"
assert_contains "$out" "--host" "the refusal names the required option"

tmp=$TMP_ROOT/missing-host-value; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host 2>&1); rc=$?
expect_code 2 "$rc" "--host without a value is refused"

tmp=$TMP_ROOT/bad-timeout; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host "$PROBE_HOST" --timeout 0 2>&1); rc=$?
expect_code 2 "$rc" "--timeout 0 is refused rather than becoming no deadline"
assert_contains "$out" "positive integer" "the timeout refusal explains the requirement"

tmp=$TMP_ROOT/dup-timeout; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host "$PROBE_HOST" --timeout 3 --timeout 4 2>&1); rc=$?
expect_code 2 "$rc" "a repeated --timeout is refused"

tmp=$TMP_ROOT/dup-host; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host a.example.invalid --host b.example.invalid 2>&1); rc=$?
expect_code 2 "$rc" "a repeated --host is refused"

tmp=$TMP_ROOT/extra-arg; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host "$PROBE_HOST" extra 2>&1); rc=$?
expect_code 2 "$rc" "an unexpected extra argument is refused"

# --- an authority-less --host is its own verdict, never a guess --------------
tmp=$TMP_ROOT/full-url; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" --host 'https://example.invalid/path' 2>&1); rc=$?
expect_code 2 "$rc" "a full URL is refused"
assert_contains "$out" "must be a host[:port][/path], not a URL" "full URL refusal explains the expected form"
[ ! -s "$tmp/dig.log" ] || fail "a full URL reached the resolver"
[ ! -s "$tmp/urls.log" ] || fail "a full URL reached curl"

for valid_host in 'example.invalid/path' 'example.invalid/path/https://resource'; do
  tmp=$TMP_ROOT/embedded-url-$RANDOM; new_case "$tmp"
  out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
    FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
    "$SCRIPT" --host "$valid_host" 2>&1); rc=$?
  expect_code 0 "$rc" "a supported host/path is accepted"
  assert_contains "$out" "result=reachable" "the host/path target is probed"
  assert_contains "$out" "probe=host:example.invalid" "the label contains only the authority"
  assert_not_contains "$out" "/path" "the output excludes the path"
  assert_contains "$(cat "$tmp/urls.log")" "https://$valid_host" "the full path reaches curl"
done

tmp=$TMP_ROOT/query-component; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host 'api.example/path?token=secret' 2>&1); rc=$?
expect_code 2 "$rc" "a query component is rejected"
assert_contains "$out" "query component is not supported" "query refusal is fixed text"
assert_not_contains "$out" "secret" "query contents are not disclosed"
[ ! -s "$tmp/dig.log" ] || fail "a query component reached the resolver"
[ ! -s "$tmp/urls.log" ] || fail "a query component reached curl"

tmp=$TMP_ROOT/host-no-authority; new_case "$tmp"
make_fake_dig "$tmp" "$tmp/dig.log"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" --host '/not-a-host' 2>&1); rc=$?
expect_code 2 "$rc" "--host with no authority exits 2"
assert_contains "$out" "result=invalid-target" "an authority-less host says invalid-target"
assert_contains "$out" "base_url_has_no_authority" "it names why"
assert_contains "$out" "probe=host:" "the line identifies the empty authority without disclosing the path"
assert_not_contains "$out" "/not-a-host" "the invalid path is excluded from the output"
assert_contains "$out" "dns=skipped http=none" "an invalid host resolves nothing and requests nothing"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "expected exactly one probe line, got: $out"
[ ! -s "$tmp/dig.log" ] || fail "an invalid host still ran a resolver: $(cat "$tmp/dig.log")"
[ ! -s "$tmp/urls.log" ] || fail "an invalid host still issued an HTTP request: $(cat "$tmp/urls.log")"

tmp=$TMP_ROOT/host-userinfo; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host user:pass@api.example.invalid 2>&1); rc=$?
expect_code 2 "$rc" "a host with userinfo is refused"
assert_contains "$out" "must not contain userinfo" "userinfo refusal is explicit"
[ ! -s "$tmp/urls.log" ] || fail "userinfo host reached curl: $(cat "$tmp/urls.log")"

# --- a missing curl is its own outcome, never another one -------------------
# The curl-absent branch cannot be reached by shrinking PATH on a host whose real
# curl sits in /usr/bin, which the case directory does not shadow. The suite seam
# named in the script's header points the request at a missing executable while
# the PATH `command -v curl` guard still sees the host's own curl, so what is
# observed is "no usable curl", never a fabricated verdict.
NO_CURL_SENTINEL=$TMP_ROOT/no-such-curl-xyz
assert_absent "$NO_CURL_SENTINEL" "the curl stand-in path must not exist"
tmp=$TMP_ROOT/no-curl; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_CURL_CMD="$NO_CURL_SENTINEL" "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 64 "$rc" "an unusable curl exits 64"
assert_contains "$out" "result=tool-missing" "an unusable curl says the tool is absent"
assert_contains "$out" "dns=ok" "an unusable curl keeps the DNS finding already made"
assert_not_contains "$out" "result=reachable" "an unusable curl is never reported as a good probe"
assert_not_contains "$out" "result=unreachable" "an unusable curl is never reported as an outage"

# --- the curl seam is inert unless the suite marker arms it -----------------
# FM_PROVIDER_REACH_CURL_CMD must not redirect a normal run. tests/lib.sh exports
# FM_TEST_SEAM=1 into every child, so the marker has to be removed with `env -u`
# ahead of the assignments; placed after them it would be consumed as an
# env-modifier and this case would prove nothing.
tmp=$TMP_ROOT/curl-seam-inert; new_case "$tmp"
out=$(env -u FM_TEST_SEAM FM_PROVIDER_REACH_CURL_CMD="$tmp/missing-curl" \
  PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" --host "$PROBE_HOST" 2>&1); rc=$?
expect_code 0 "$rc" "an unarmed curl seam does not redirect the probe"
assert_contains "$out" "result=reachable" "the PATH curl still produced the verdict"
assert_not_contains "$out" "tool-missing" "an unarmed seam cannot hide the host curl"
assert_contains "$(cat "$tmp/urls.log")" "https://$PROBE_HOST" "the PATH curl recorded the request"

pass "fm-provider-reach-probe.sh distinguishes 000, 401/403, and 200 with stable wording"
