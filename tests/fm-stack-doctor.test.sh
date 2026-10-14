#!/usr/bin/env bash
# tests/fm-stack-doctor.test.sh - the layered stack health command
# (bin/fm-stack-doctor.sh): the evidence line protocol every layer prints, the
# real MCP handshake a group route must complete, the tailnet-route test that
# repeats that handshake over the served entry point with its own limits stated,
# the exposure verdicts that separate a tailnet-only layer from a public one,
# the caller-identity evidence in the traffic layer, the log contracts that say
# what each log is not authoritative for, the non-zero exit that makes it a
# check, the session proxy log that names the real caller of a request, the host config that replaces the shipped inventory, and the
# whole-run budget that bounds it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$ROOT/bin/fm-stack-doctor.sh"
BASH_BIN=$(command -v bash)
TMP_ROOT=$(fm_test_tmproot fm-stack-doctor-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# --- fixture stack ---------------------------------------------------------
#
# One fake app and one fake gateway on loopback ports nothing else listens on,
# with fixture logs written by hand so every count in the report is a fact the
# test can assert rather than a number this host happened to produce.
# The records reuse the shipped layer names so they replace the shipped
# inventory instead of running beside it.

APP_PORT=47351
GATEWAY_PORT=47352
FRONT_PORT=47353
SESSION_PORT=47354
SESSION_LOG="$TMP_ROOT/state/session/session-proxy.jsonl"
APP_LOG="$TMP_ROOT/state/app/server.out.log"
GATEWAY_LOG="$TMP_ROOT/state/gateway/gateway.out.log"
FRONT_LOG="$TMP_ROOT/state/front/proxy.err.log"
mkdir -p "$TMP_ROOT/state/app" "$TMP_ROOT/state/gateway" "$TMP_ROOT/state/front" "$TMP_ROOT/state/session"

cat > "$APP_LOG" <<'LOG'
2026-10-06T05:00:00.000Z ALLOW:localhost 200 GET /live/recent?limit=50 ip=127.0.0.1 ua=Python-urllib/3.9 1ms
2026-10-06T05:00:01.000Z ALLOW:mcp 200 POST /mcp ip=127.0.0.1 ua=curl/8.7.1 40ms
2026-10-06T05:00:02.000Z ALLOW:localhost 200 GET /live/recent?limit=50 ip=127.0.0.1 ua=Python-urllib/3.9 1ms
2026-10-06T05:00:03.000Z ALLOW:mcp 200 POST /jungle/mcp ip=127.0.0.1 ua=curl/8.7.1 12ms
LOG

cat > "$GATEWAY_LOG" <<'LOG'
[GIN] 2026/10/06 - 05:00:00 | 200 | 1.1ms | 127.0.0.1 | GET "/health"
[GIN] 2026/10/06 - 05:00:01 | 200 | 1.2ms | 127.0.0.1 | POST "/v0/groups/chatgpt/mcp"
LOG

cat > "$FRONT_LOG" <<'LOG'
{"level":"warn","logger":"http.handlers.reverse_proxy","msg":"aborting with incomplete response","request":{"remote_ip":"127.0.0.1","headers":{"X-Forwarded-For":["127.0.0.1"],"Tailscale-User-Login":["trillium@github"]}}}
LOG

write_config() {
  cat > "$TMP_ROOT/stack-doctor.conf" <<CONF
app|beads-bridge|$APP_PORT|http://127.0.0.1:$APP_PORT/live/config|$TMP_ROOT/state/app|$APP_LOG
gateway|mcpjungle|$GATEWAY_PORT|http://127.0.0.1:$GATEWAY_PORT/health|$TMP_ROOT/state/gateway|$GATEWAY_LOG|$FRONT_PORT|caddy
CONF
}

# The session proxy records one request and one response line per exchange.
# The fixture holds an attributed MCP call, then an unattributed health check,
# and the session id it presents must never reach the report.
write_session_log() {
  cat > "$SESSION_LOG" <<'LOG'
{"ts": "2026-10-06T04:00:00.000Z", "event": "request", "rid": "r1", "method": "POST", "path": "/v0/groups/chatgpt/mcp", "group": "chatgpt", "session": "SECRET-SESSION-ID-1", "rpc": "tools/call", "client": "198.51.100.7", "forwarded_for": "198.51.100.7", "tailscale_login": "", "tailscale_name": "", "user_agent": "openai-mcp/1.0", "auth_present": true}
{"ts": "2026-10-06T04:00:00.050Z", "event": "response", "rid": "r1", "status": 200, "session": "SECRET-SESSION-ID-1", "verdict": "ok"}
not json at all
{"ts": "2026-10-06T04:30:00.000Z", "event": "request", "rid": "r2", "method": "GET", "path": "/health", "group": "", "session": "absent", "rpc": "", "client": "127.0.0.1", "forwarded_for": "127.0.0.1", "tailscale_login": "", "tailscale_name": "", "user_agent": "curl/8.7.1", "auth_present": false}
{"ts": "2026-10-06T04:30:00.004Z", "event": "response", "rid": "r2", "status": 200, "session": "absent", "verdict": "ok"}
LOG
}

write_config_with_session() {
  write_session_log
  cat > "$TMP_ROOT/stack-doctor.conf" <<CONF
app|beads-bridge|$APP_PORT|http://127.0.0.1:$APP_PORT/live/config|$TMP_ROOT/state/app|$APP_LOG
gateway|mcpjungle|$GATEWAY_PORT|http://127.0.0.1:$GATEWAY_PORT/health|$TMP_ROOT/state/gateway|$GATEWAY_LOG|$FRONT_PORT|caddy|$SESSION_PORT|$SESSION_LOG
CONF
}

write_config_with_dead_gateway() {
  write_config
  printf 'gateway|dead-gateway|%s|http://127.0.0.1:%s/health|%s|%s/missing.log||\n' \
    "$((GATEWAY_PORT + 10))" "$((GATEWAY_PORT + 10))" "$TMP_ROOT/state/gateway" "$TMP_ROOT/state/gateway" >> "$TMP_ROOT/stack-doctor.conf"
}

# --- fake toolchain --------------------------------------------------------
#
# The command reads process, port, and proxy state from ordinary tools, so a
# fake toolchain drives every case deterministically and on a machine that is
# not running this stack at all.

cat > "$FAKEBIN/lsof" <<'STUB'
#!/bin/sh
# A listening-socket and working-directory report for the fixture ports only.
port=""
cwd=""
pid=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -iTCP:*) port=${1#-iTCP:} ;;
    -d)
      shift
      [ "$1" = cwd ] && cwd=yes
      ;;
    -p) pid=$2; shift ;;
  esac
  shift
done
[ -n "$pid" ] || pid=$FM_FIXTURE_PID
if [ -n "$cwd" ]; then
  printf 'p%s\nn%s\n' "$pid" "$FM_FIXTURE_SOURCE_DIR"
  exit 0
fi
case "$port" in
  "$FM_FIXTURE_PORT"|"$FM_FIXTURE_GATEWAY_PORT"|"$FM_FIXTURE_FRONT_PORT"|"$FM_FIXTURE_SESSION_PORT") ;;
  *) exit 1 ;;
esac
printf 'p%s\nn127.0.0.1:%s\n' "$pid" "$port"
exit 0
STUB

cat > "$FAKEBIN/ps" <<'STUB'
#!/bin/sh
case "$*" in
  *'-o etime='*) printf '09:04:05\n' ;;
  *'-o command='*) printf 'caddy run --config %s\n' "$FM_FIXTURE_FRONT_CONFIG" ;;
  *'-o pid='*) printf '%s\n' "$FM_FIXTURE_PID" ;;
esac
exit 0
STUB

cat > "$FAKEBIN/git" <<'STUB'
#!/bin/sh
case "$*" in
  *rev-parse\ --short\ HEAD*) printf 'abc1234\n' ;;
  *--format=%cI*) printf '2026-10-05T21:04:43Z\n' ;;
  *abbrev-ref*) printf 'main\n' ;;
  *status*) exit 0 ;;
esac
exit 0
STUB

cat > "$FAKEBIN/launchctl" <<'STUB'
#!/bin/sh
case "$*" in
  list) printf '%s\t0\t%s\n' "$FM_FIXTURE_PID" "$FM_FIXTURE_LAUNCHD_LABEL" ;;
  *print*)
    printf '\tstdout path = %s\n\tstderr path = %s\n' "$FM_FIXTURE_FRONT_LOG_OUT" "$FM_FIXTURE_FRONT_LOG"
    exit 0
    ;;
esac
exit 0
STUB

cat > "$FAKEBIN/tailscale" <<'STUB'
#!/bin/sh
cat <<JSON
{
  "Web": {
    "demo.test.ts.net:443": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:$FM_FIXTURE_PORT" } } },
    "demo.test.ts.net:$FM_FIXTURE_FRONT_PORT": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:$FM_FIXTURE_FRONT_PORT" } } }
  },
  "TCP": {},
  "AllowFunnel": { "demo.test.ts.net:443": true }
}
JSON
STUB

# The gateway fixture. It answers the tailnet hostname and the loopback address
# for the same route, refuses the funnel entry the way the real funnel refuses a
# path it does not serve, and appends the access line the real gateway appends,
# including whether it follows X-Forwarded-For.
cat > "$FAKEBIN/curl" <<'STUB'
#!/bin/sh
url=""
headers=""
outfile=""
forwarded=""
want_status=no
prev=""
for arg in "$@"; do
  case "$prev" in
    -D) headers=$arg; prev=""; continue ;;
    -o) outfile=$arg; prev=""; continue ;;
  esac
  case "$arg" in
    -w) want_status=yes ;;
    http://*|https://*) url=$arg ;;
    'X-Forwarded-For: '*) forwarded=${arg#X-Forwarded-For: } ;;
  esac
  prev=$arg
done
log_gateway() {
  client="$1"
  target="$2"
  case "$target" in
    /health)
      printf '[GIN] 2026/10/06 - 06:00:00 | 200 | 1.0ms | %s | GET "%s"\n' "$client" "$target" >> "$FM_FIXTURE_GATEWAY_LOG"
      # A real session proxy records this run's own probe too, which the
      # doctor must not report as the newest real request.
      [ -z "${FM_FIXTURE_SESSION_LOG:-}" ] || printf '{"ts": "2026-10-06T06:00:00.000Z", "event": "request", "rid": "r99", "method": "GET", "path": "/health", "group": "", "session": "absent", "rpc": "", "client": "127.0.0.1", "forwarded_for": "127.0.0.1", "tailscale_login": "", "user_agent": "doctor-own-probe"}\n' >> "$FM_FIXTURE_SESSION_LOG"
      ;;
  esac
}
client=127.0.0.1
if [ -n "$forwarded" ]; then
  case "${FM_FIXTURE_XFF_HONORED:-yes}" in
    yes) client=$forwarded ;;
  esac
fi
status=200
body=''
case "$url" in
  *'/live/config') body='{"ok":true}' ;;
  *'/health')
    body='{"status":"ok"}'
    log_gateway "$client" /health
    [ -n "$headers" ] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: mcp-session-fixture\r\n\r\n' > "$headers"
    ;;
  *'/api/v0/tool-groups/chatgpt')
    body='{"name":"chatgpt","included_servers":["demo-app"],"streamable_http_endpoint":"http://127.0.0.1:FM_FIXTURE_GATEWAY_PORT/v0/groups/chatgpt/mcp"}'
    ;;
  *'/api/v0/tool-groups')
    body='[{"name":"chatgpt","included_servers":["demo-app"]}]'
    ;;
  *'/v0/groups/chatgpt/mcp')
    case "${url}" in
      https://demo.test.ts.net:443*)
        status=403
        body='# forbidden'
        ;;
      https://demo.test.ts.net:$FM_FIXTURE_FRONT_PORT*)
        case "${FM_FIXTURE_TAILNET_HANDSHAKE:-ok}" in
          broken)
            status=200
            body='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"front that answers a status","version":"v0.0.0"}}}'
            ;;
          *)
            [ -n "$headers" ] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: mcp-session-tailnet\r\n\r\n' > "$headers"
            case " $* " in
              *tools/list*)
                body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"demo-app__one"},{"name":"demo-app__two"}]}}'
                ;;
              *)
                body='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"MCPJungle proxy MCP server for tool group: chatgpt","version":"v9.9.9"}}}'
                ;;
            esac
            ;;
        esac
        ;;
      *)
        [ -n "$headers" ] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: mcp-session-fixture\r\n\r\n' > "$headers"
        case " $* " in
          *tools/list*)
            body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"demo-app__one"},{"name":"demo-app__two"}]}}'
            ;;
          *)
            body='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"MCPJungle proxy MCP server for tool group: chatgpt","version":"v9.9.9"}}}'
            ;;
        esac
        ;;
    esac
    ;;
  *)
    status=404
    body='no fixture for this url'
    ;;
esac
case "$outfile" in
  ''|-)
    printf '%s' "$body"
    [ "$want_status" = yes ] && printf '\n%s' "$status"
    ;;
  *)
    printf '%s' "$body" > "$outfile"
    [ "$want_status" = yes ] && printf '%s' "$status"
    ;;
esac
exit 0
STUB

cat > "$TMP_ROOT/state/front/Caddyfile" <<'CONF'
:1 {
	reverse_proxy 127.0.0.1:1
}
CONF

chmod +x "$FAKEBIN"/*

doctor() { # <args...>
  PATH="$FAKEBIN:$PATH" \
    HOME="$TMP_ROOT/home" \
    FM_FIXTURE_PID=4242 \
    FM_FIXTURE_PORT="$APP_PORT" \
    FM_FIXTURE_GATEWAY_PORT="$GATEWAY_PORT" \
    FM_FIXTURE_FRONT_PORT="$FRONT_PORT" \
    FM_FIXTURE_SESSION_PORT="$SESSION_PORT" \
    FM_FIXTURE_SESSION_LOG="${FM_FIXTURE_SESSION_LOG:-}" \
    FM_FIXTURE_SOURCE_DIR="$TMP_ROOT/state/app" \
    FM_FIXTURE_FRONT_CONFIG="$TMP_ROOT/state/front/Caddyfile" \
    FM_FIXTURE_FRONT_LOG="$FRONT_LOG" \
    FM_FIXTURE_FRONT_LOG_OUT="$TMP_ROOT/state/front/proxy.out.log" \
    FM_FIXTURE_LAUNCHD_LABEL=com.mcpjungle.proxy \
    FM_FIXTURE_GATEWAY_LOG="$GATEWAY_LOG" \
    FM_STACK_DOCTOR_CONF="$TMP_ROOT/stack-doctor.conf" \
    bash "$DOCTOR" "$@"
}

# --- cases -----------------------------------------------------------------

test_healthy_stack_answers_every_layer() {
  write_config
  local out rc
  out=$(doctor 2>&1) && rc=0 || rc=$?
  assert_equals 0 "$rc" "a healthy stack must exit zero so the command works as a check"
  assert_contains "$out" "[app] beads-bridge" "the app layer must name its layer"
  assert_contains "$out" "pid=4242" "the app layer must print the pid holding its port"
  assert_contains "$out" "revision=abc1234" "the app layer must print the deployed revision"
  assert_contains "$out" "uptime=9h04m" "the app layer must print the uptime of the process holding its port"
  assert_contains "$out" "[gateway] mcpjungle" "the gateway layer must name its layer"
  assert_contains "$out" "front=caddy" "the gateway layer must report the local front proxying it"
  assert_contains "$out" "names=chatgpt" "the group layer must list every group before probing one"
  assert_contains "$out" "handshake=ok" "a group route that completes the handshake must say so"
  assert_contains "$out" "server_version=v9.9.9" "the handshake must print the server version, not only a status"
  assert_contains "$out" "tools=2" "the handshake must print the tool count the route actually serves"
  assert_contains "$out" "[summary] doctor" "the run must end with a summary line"
  assert_contains "$out" "verdict=ok" "a healthy stack must end with an ok verdict"
  pass "healthy stack answers every layer"
}

test_tailnet_route_completes_a_handshake_for_every_group() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "[tailnet] mcpjungle tailnet_route status=published" "the tailnet layer must report the served entry point"
  assert_contains "$out" "base_url=https://demo.test.ts.net:$FRONT_PORT/" "the tailnet layer must print the URL it probes"
  assert_contains "$out" "[tailnet] group chatgpt url=https://demo.test.ts.net:$FRONT_PORT/v0/groups/chatgpt/mcp" \
    "every group must be probed over the tailnet URL, not over localhost"
  assert_contains "$out" "server=\"MCPJungle proxy MCP server for tool group: chatgpt\"" \
    "the tailnet handshake must print the identity the served route reported"
  assert_contains "$out" "[tailnet] group chatgpt" "the tailnet result must be reported per group"
  pass "the tailnet route completes a handshake for every group"
}

test_tailnet_route_states_its_own_limits() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "proves nothing at all about an off-tailnet caller" \
    "a route test run from inside the tailnet must say it proves nothing about an off-tailnet caller"
  assert_contains "$out" "addressing=hostname" \
    "the tailnet layer must state that a raw tailnet IP would fail TLS SNI and read as a false route failure"
  pass "the tailnet route states its own limits"
}

test_a_served_status_without_a_session_is_not_a_working_route() {
  write_config
  local out rc
  out=$(FM_FIXTURE_TAILNET_HANDSHAKE=broken doctor 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a tailnet route that answers a status without an MCP session must fail the check"
  assert_contains "$out" "stage=initialize-reason-no-session-id" \
    "a route that returns a status without an MCP session must be named as such, not as a 200"
  pass "a served status without a session is not a working route"
}

test_funnel_mismatch_is_made_visible() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "[tailnet] funnel group chatgpt" "the funnel answer for a group path must be reported"
  assert_contains "$out" "http=403" "the funnel status must be printed as observed"
  assert_contains "$out" "serves=app:beads-bridge" "the funnel line must name the layer the funnel actually serves"
  assert_contains "$out" "verdict=mismatch" "the funnel pointing at another layer must be called a mismatch"
  assert_contains "$out" "public_funnel_serves=app:beads-bridge" "the exposure layer must name the layer the public funnel serves"
  pass "the funnel mismatch is made visible"
}

test_exposure_separates_tailnet_from_public() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "[exposure] funnel url=https://demo.test.ts.net:443/" "the public funnel mapping must be printed with its target"
  assert_contains "$out" "reachable_from_tailnet=yes" "the gateway front must be reported reachable from the tailnet"
  assert_contains "$out" "reachable_from_public=no" "the gateway must be reported unreachable from the public internet"
  assert_contains "$out" "note=no funnel mapping reaches this gateway" "the mismatch between the funnel and the gateway must be stated"
  pass "exposure separates tailnet-only from public"
}

test_traffic_layer_reports_caller_identity_evidence() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "sent_x_forwarded_for=203.0.113.9" "the traffic layer must say which header it tested"
  assert_contains "$out" "logged_client=203.0.113.9" "the traffic layer must print what the gateway logged for that header"
  assert_contains "$out" "the logged client column follows X-Forwarded-For" \
    "the traffic layer must state what the caller column follows, rather than leaving a silent loopback"
  assert_contains "$out" "lines_recording_tailscale_user=1" \
    "the traffic layer must report the one log that carries a tailnet identity header"
  assert_contains "$out" "mcp_request_lines=2" "the traffic layer must count the MCP request lines it found"
  pass "traffic layer reports caller identity evidence"
}

test_a_client_column_that_ignores_forwarding_is_reported_as_unmeasured() {
  write_config
  local out
  out=$(FM_FIXTURE_XFF_HONORED=no doctor 2>&1) || true
  assert_contains "$out" "did not follow the X-Forwarded-For this run sent" \
    "a gateway that ignores X-Forwarded-For must be reported as unidentified, not as a loopback caller"
  pass "a client column that ignores forwarding is reported as unidentified"
}

test_logs_layer_states_what_each_log_cannot_answer() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "not_authoritative_for=which gateway tool group a caller used" \
    "the app log must state what it is not authoritative for"
  assert_contains "$out" "path=/live/recent?limit=50" "the logs layer must show the paths a log records"
  assert_contains "$out" "path=/mcp" "the logs layer must show MCP request lines when the log records them"
  assert_contains "$out" "with no access log the front records no successful request at all" \
    "a front with no access log must be reported as unable to answer who called"
  pass "logs layer states what each log cannot answer"
}

test_missing_log_reports_absent_rather_than_omitting_the_line() {
  write_config_with_dead_gateway
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "path=$TMP_ROOT/state/gateway/missing.log status=absent" \
    "a layer whose log is missing must print its line anyway"
  assert_contains "$out" "nothing this layer did can be read from logs" \
    "an absent log must say so in words, not merely by omission"
  pass "a missing log reports absent rather than omitting the line"
}

test_a_down_layer_fails_the_check() {
  write_config_with_dead_gateway
  local out rc
  out=$(doctor 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a down layer must make the command exit non-zero, got zero"
  assert_contains "$out" "state=no-listener" "a down layer must print that nothing holds its port"
  assert_contains "$out" "reason=gateway-down" "a down gateway must say that no group can be probed"
  assert_contains "$out" "verdict=degraded" "a run with a down layer must end with a degraded verdict"
  pass "a down layer fails the check"
}

test_config_replaces_the_shipped_inventory() {
  write_config
  local records
  records=$(doctor --records 2>&1)
  assert_contains "$records" "app|beads-bridge|$APP_PORT|" "a host config record must appear in the resolved inventory"
  assert_not_contains "$records" "app|beads-bridge|3737|" "a host config record must replace the shipped default of the same kind and name"
  assert_contains "$records" "gateway|mcpjungle|$GATEWAY_PORT|" "a replaced gateway record must carry the host's own port"
  pass "host config replaces the shipped inventory"
}

test_a_missing_tool_is_reported_as_evidence() {
  write_config
  local out
  # A PATH with the version-managed tools removed still has the basics the
  # command needs to run, so the missing-tool path is exercised rather than a
  # script that dies before it can report anything.
  out=$(PATH="/usr/bin:/bin:/usr/sbin" FM_STACK_DOCTOR_CONF="$TMP_ROOT/stack-doctor.conf" \
    "$BASH_BIN" "$DOCTOR" 2>&1) || true
  assert_contains "$out" "[tools] tailscale path=absent status=missing" \
    "an absent probe tool must be reported, never hidden behind silence"
  assert_contains "$out" "reason=tailscale-absent" \
    "a missing tailscale CLI must be reported as the exposure layer being absent"
  assert_contains "$out" "status=unknown" "a layer that could not be probed must print unknown rather than nothing"
  pass "a missing tool is reported as evidence"
}

test_the_whole_run_budget_is_reported_and_bounds_the_run() {
  write_config
  local started ended out
  started=$(date +%s)
  out=$(FM_STACK_DOCTOR_BUDGET=1 doctor 2>&1) || true
  ended=$(date +%s)
  assert_contains "$out" "budget=1s" "the run must report the budget it is held to"
  [ $((ended - started)) -le 30 ] || fail "the run must finish inside its budget, took $((ended - started))s"
  pass "the whole-run budget is reported and bounds the run"
}

test_a_budget_exhausted_run_says_so_instead_of_silently_skipping() {
  write_config
  local out
  out=$(FM_STACK_DOCTOR_BUDGET=0 doctor 2>&1) || true
  assert_contains "$out" "handshake=skipped" "a group left unprobed by the budget must say so"
  assert_contains "$out" "budget" "the exhausted budget must be named in the reason"
  pass "a budget-exhausted run says so instead of silently skipping"
}

test_session_proxy_log_names_the_real_caller() {
  write_config_with_session
  local out
  out=$(FM_FIXTURE_SESSION_LOG="$SESSION_LOG" doctor 2>&1) || true
  assert_contains "$out" "session_proxy=yes session_proxy_port=$SESSION_PORT" "the session proxy must be reported as a layer with its port"
  assert_contains "$out" "pid=4242" "the session proxy layer must print the pid holding its port"
  assert_contains "$out" "session_proxy_newest log=$SESSION_LOG requests_read=2" \
    "the newest request must come from the log as it stood before this run, counting only parseable requests"
  assert_contains "$out" "rid=r2 method=GET path=/health" "the newest request must be the last one recorded before the run"
  assert_not_contains "$out" "doctor-own-probe" "the run's own probe must never be reported as the newest request"
  assert_contains "$out" "session_proxy_newest_mcp at=2026-10-06T04:00:00.000Z" "the newest MCP call must be reported apart from health checks"
  assert_contains "$out" "rpc=tools/call" "the newest MCP call must print its JSON-RPC method"
  assert_contains "$out" "group=chatgpt" "the newest MCP call must print the tool group it used"
  assert_contains "$out" "client=198.51.100.7" "the real client address must be printed"
  assert_contains "$out" "status=200 verdict=ok" "the response the proxy logged for the request must be printed"
  assert_contains "$out" "session=presented" "a presented session id must be reported as presence only"
  assert_not_contains "$out" "SECRET-SESSION-ID" "a session id must never be printed"
  assert_contains "$out" "session_proxy_newest_attributed requests_with_caller_identity=1" \
    "the newest request that carries a caller identity must be reported with its count"
  assert_contains "$out" "a caller identity was recorded for it" "an identified caller must be stated as identified"
  assert_contains "$out" "path=$SESSION_LOG status=present" "the logs layer must describe the session proxy log"
  assert_contains "$out" "the real client from X-Forwarded-For" "the logs layer must say what the session proxy log is authoritative for"
  pass "the session proxy log names the real caller"
}

test_a_session_proxy_log_without_identity_says_the_client_cannot_be_determined() {
  write_config_with_session
  grep -v 'openai-mcp' "$SESSION_LOG" > "$SESSION_LOG.tmp" && mv "$SESSION_LOG.tmp" "$SESSION_LOG"
  local out
  out=$(FM_FIXTURE_SESSION_LOG="$SESSION_LOG" doctor 2>&1) || true
  assert_contains "$out" "requests_with_caller_identity=0" "a log with only loopback callers must report no identified request"
  assert_contains "$out" "the real client cannot be determined" "an unidentified caller must be stated plainly, not left as a silent loopback"
  assert_contains "$out" "requests_with_jsonrpc_method=0" "a log with no JSON-RPC request must say no MCP call was seen"
  pass "a session proxy log without identity says the client cannot be determined"
}

test_a_missing_session_proxy_log_reports_absent() {
  write_config_with_session
  rm -f "$SESSION_LOG"
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "session_proxy log=$SESSION_LOG status=absent" "a missing session proxy log must print its line"
  assert_contains "$out" "the real client of the newest request cannot be determined from any log" "an absent log must say the client is unknown"
  pass "a missing session proxy log reports absent"
}

test_an_unconfigured_session_proxy_is_reported_as_unknown() {
  write_config
  local out
  out=$(doctor 2>&1) || true
  assert_contains "$out" "session_proxy log=unknown" "a gateway with no session proxy log configured must print the unknown line"
  pass "an unconfigured session proxy is reported as unknown"
}

test_a_down_session_proxy_fails_the_check() {
  write_config_with_session
  sed -i.bak "s/|$SESSION_PORT|/|$((SESSION_PORT + 10))|/" "$TMP_ROOT/stack-doctor.conf"
  local out rc
  out=$(FM_FIXTURE_SESSION_LOG="$SESSION_LOG" doctor 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a session proxy with nothing listening must make the command exit non-zero"
  assert_contains "$out" "session_proxy=yes session_proxy_port=$((SESSION_PORT + 10)) session_proxy_listen=none pid=none" \
    "a down session proxy must print that nothing holds its port"
  pass "a down session proxy fails the check"
}

test_healthy_stack_answers_every_layer
test_tailnet_route_completes_a_handshake_for_every_group
test_tailnet_route_states_its_own_limits
test_a_served_status_without_a_session_is_not_a_working_route
test_funnel_mismatch_is_made_visible
test_exposure_separates_tailnet_from_public
test_traffic_layer_reports_caller_identity_evidence
test_a_client_column_that_ignores_forwarding_is_reported_as_unmeasured
test_logs_layer_states_what_each_log_cannot_answer
test_missing_log_reports_absent_rather_than_omitting_the_line
test_a_down_layer_fails_the_check
test_config_replaces_the_shipped_inventory
test_a_missing_tool_is_reported_as_evidence
test_the_whole_run_budget_is_reported_and_bounds_the_run
test_a_budget_exhausted_run_says_so_instead_of_silently_skipping
test_session_proxy_log_names_the_real_caller
test_a_session_proxy_log_without_identity_says_the_client_cannot_be_determined
test_a_missing_session_proxy_log_reports_absent
test_an_unconfigured_session_proxy_is_reported_as_unknown
test_a_down_session_proxy_fails_the_check

fm_test_reap_orphans
fm_test_cleanup