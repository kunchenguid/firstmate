#!/usr/bin/env bash
# Behavior tests for bin/fm-freellmapi.sh - the pinned, localhost-only
# FreeLLMAPI lane manager. These tests never install the real upstream, never
# start the real service, and never touch a real API key: git, npm, node, curl,
# and lsof are PATH shims, and every "key" is an invented fake value whose only
# job is to prove it cannot leak into stdout, stderr, argv, or the wrapper log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-freellmapi.sh"
PIN=526c86349891bd336b470481ee2d732cd8e13c14

assert_present "$TOOL" "bin/fm-freellmapi.sh is missing"
[ -x "$TOOL" ] || fail "fm-freellmapi.sh must be executable"

# --- fixture builders --------------------------------------------------------

# fresh_home <root>: build an isolated FM_HOME with a fakebin and echo both
# paths as "home fakebin".
fresh_home() {
  local root=$1 home fakebin
  home="$root/home"
  mkdir -p "$home/data"
  fakebin=$(fm_fakebin "$root")
  printf '%s %s\n' "$home" "$fakebin"
}

# install_fakes <fakebin> <capture-dir>: git/npm/node shims that record argv.
install_fakes() {
  local fakebin=$1 cap=$2
  mkdir -p "$cap"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$cap/git.log'
for a in "\$@"; do
  [ "\$a" = HEAD ] && { printf '%s\n' "\${FAKE_GIT_HEAD:-$PIN}"; exit 0; }
done
exit 0
SH
  cat > "$fakebin/npm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$cap/npm.log'
exit 0
SH
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/git" "$fakebin/npm" "$fakebin/node"
}

# server_fakes <fakebin> <capture-dir>: node/curl/lsof shims for start/stop.
# The fake node records its environment shape (never raw secret values except
# into the private capture file the test greps) and stays alive until TERM.
server_fakes() {
  local fakebin=$1 cap=$2
  mkdir -p "$cap"
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
{
  printf 'argv=%s\n' "\$*"
  printf 'host=%s\n' "\${HOST:-unset}"
  printf 'port=%s\n' "\${PORT:-unset}"
  printf 'node_env=%s\n' "\${NODE_ENV:-unset}"
  printf 'catalog_sync_disabled=%s\n' "\${CATALOG_SYNC_DISABLED:-unset}"
  printf 'encryption_key=%s\n' "\${ENCRYPTION_KEY:-unset}"
} > '$cap/node-env.capture'
trap 'echo term >> "'$cap'/node-signal.capture"; exit 0' TERM
# Bounded lifetime so a failed assertion can never leak an immortal process.
i=0
while [ "\$i" -lt 120 ]; do sleep 1; i=\$((i + 1)); done
SH
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$cap/curl-argv.log'
url=''
for a in "\$@"; do case "\$a" in http*) url=\$a ;; esac; done
# Read stdin only when the caller actually pipes a body (-d @-), so plain
# GET-style calls can never block on an inherited stdin.
for a in "\$@"; do
  if [ "\$a" = '@-' ]; then
    body=\$(cat)
    printf '%s\n' "\$body" >> '$cap/curl-stdin.log'
    break
  fi
done
case "\$url" in
  */api/ping) exit "\${FAKE_PING_EXIT:-0}" ;;
  */api/auth/status) printf '{"needsSetup":%s,"authenticated":false}' "\${FAKE_NEEDS_SETUP:-true}" ;;
  */api/auth/setup|*/api/auth/login) printf '{"token":"fake-session-token-1234"}' ;;
  */api/keys)
    for a in "\$@"; do case "\$a" in %*http_code*) printf '%s' "\${FAKE_KEYS_HTTP:-201}"; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/lsof" <<SH
#!/usr/bin/env bash
[ "\${FAKE_LSOF_EXIT:-0}" = 0 ] || exit "\$FAKE_LSOF_EXIT"
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
printf 'node 999 u 23u IPv4 0x0 0t0 TCP %s:3001 (LISTEN)\n' "\${FAKE_LSOF_ADDR:-127.0.0.1}"
SH
  chmod +x "$fakebin/node" "$fakebin/curl" "$fakebin/lsof"
}

# built_install <home>: pretend install completed so start can proceed.
built_install() {
  mkdir -p "$1/data/freellmapi/app/server/dist"
  : > "$1/data/freellmapi/app/server/dist/index.js"
}

file_mode() { # <path>: print the octal permission bits, portably
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

run_tool() { # <home> <fakebin> <args...>; captures OUT and CODE
  local home=$1 fakebin=$2
  shift 2
  set +e
  OUT=$(FM_HOME="$home" PATH="$fakebin:$PATH" FM_FREELLMAPI_START_TIMEOUT=3 \
    FM_FREELLMAPI_STOP_TIMEOUT=2 "$TOOL" "$@" 2>&1)
  CODE=$?
  set -e
}

stop_lane() { # <home> <fakebin>: best-effort cleanup of a started fake server
  run_tool "$1" "$2" stop || true
}

# --- static contract ---------------------------------------------------------

test_static_pin_and_safety_contract() {
  assert_grep "$PIN" "$TOOL" "tool must pin the full audited upstream commit SHA"
  assert_no_grep 'clone https' "$TOOL" "tool must fetch the pin, not clone a moving branch"
  assert_no_grep ':latest' "$TOOL" "tool must not reference a floating latest tag"
  assert_grep 'HOST=127.0.0.1' "$TOOL" "tool must force the loopback bind host"
  assert_no_grep '0.0.0.0' "$TOOL" "tool must never mention binding to 0.0.0.0"
  assert_grep 'NODE_ENV=production' "$TOOL" "tool must run upstream in production mode so a dev fallback key is refused"
  assert_grep '--accept-risks' "$TOOL" "install must be gated on explicit risk acceptance"
  assert_no_grep 'set -x' "$TOOL" "tool must never enable shell tracing around secrets"
  # Honest secret contract: argv protection, not absolute process-listing immunity.
  assert_grep 'never on argv' "$TOOL" "tool must state secrets are never on argv"
  assert_grep 'same OS user can still inspect' "$TOOL" "tool must not overclaim process-env secrecy"
  assert_no_grep 'cannot surface in a process listing' "$TOOL" "tool must not claim absolute process-listing protection"
  # status alerts; only start stops a bad bind.
  assert_grep 'status fails with a' "$TOOL" "help must say status fails without stopping"
  assert_grep 'does not stop' "$TOOL" "help must say status does not stop on bad bind"
  pass "static pin and safety contract"
}

test_help_states_policy() {
  set +e
  out=$("$TOOL" --help 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "--help exit"
  assert_contains "$out" "127.0.0.1" "help must state the localhost-only binding"
  assert_contains "$out" "never appear in stdout" "help must state the secret-safety contract"
  assert_contains "$out" "same OS user can still inspect" "help must not overclaim process-env secrecy"
  assert_contains "$out" "docs/freellmapi-lane.md" "help must point at the lane policy doc"
  pass "help states policy"
}

# --- install -----------------------------------------------------------------

test_install_refuses_without_risk_acceptance() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  install_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" install
  [ "$CODE" -ne 0 ] || fail "install without --accept-risks must fail"
  assert_contains "$OUT" "3 critical" "refusal must restate the known vulnerability counts"
  assert_contains "$OUT" "accept-risks" "refusal must name the required flag"
  assert_absent "$cap/git.log" "refused install must not touch git"
  pass "install refuses without risk acceptance"
}

test_install_fetches_exact_pin() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  install_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" install --accept-risks
  expect_code 0 "$CODE" "install --accept-risks"
  assert_grep "fetch -q --depth 1 origin $PIN" "$cap/git.log" "install must fetch exactly the pinned commit"
  assert_grep "checkout -q --detach $PIN" "$cap/git.log" "install must check out exactly the pinned commit"
  assert_grep 'ci' "$cap/npm.log" "install must use lockfile-pinned npm ci"
  assert_grep 'run build' "$cap/npm.log" "install must build the pinned checkout"
  assert_contains "$OUT" "3 critical" "install must restate the known vulnerability counts"
  pass "install fetches the exact pin"
}

test_install_refuses_head_mismatch() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  install_fakes "$fakebin" "$cap"
  set +e
  OUT=$(FM_HOME="$home" PATH="$fakebin:$PATH" FAKE_GIT_HEAD=deadbeef "$TOOL" install --accept-risks 2>&1)
  CODE=$?
  set -e
  [ "$CODE" -ne 0 ] || fail "install must fail when the checkout does not match the pin"
  assert_contains "$OUT" "checkout mismatch" "mismatch must be named"
  assert_absent "$cap/npm.log" "unverified content must never be built"
  pass "install refuses a pin mismatch"
}

# --- start -------------------------------------------------------------------

test_start_refuses_without_install() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" start
  [ "$CODE" -ne 0 ] || fail "start without an install must fail"
  assert_contains "$OUT" "install --accept-risks" "refusal must point at the install command"
  pass "start refuses without install"
}

test_start_binds_loopback_and_never_leaks_key() {
  local root home fakebin cap key perms argv_line log
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  run_tool "$home" "$fakebin" start
  expect_code 0 "$CODE" "start"
  assert_contains "$OUT" "http://127.0.0.1:3001" "start must report the loopback endpoint"
  assert_contains "$OUT" "loopback binding verified" "start must report the verified binding"

  key=$(cat "$home/data/freellmapi/encryption.key")
  [ "${#key}" -eq 64 ] || fail "generated encryption key must be 64 hex chars"
  case "$key" in *[!0-9a-f]*) fail "generated encryption key must be lowercase hex" ;; esac
  perms=$(file_mode "$home/data/freellmapi/encryption.key")
  [ "$perms" = 600 ] || fail "encryption key file must be mode 0600, got $perms"

  assert_not_contains "$OUT" "$key" "encryption key value must never reach stdout/stderr"
  assert_grep 'host=127.0.0.1' "$cap/node-env.capture" "server must receive HOST=127.0.0.1"
  assert_grep 'node_env=production' "$cap/node-env.capture" "server must run in production mode"
  assert_grep 'catalog_sync_disabled=1' "$cap/node-env.capture" "catalog sync must be off by default"
  assert_grep "encryption_key=$key" "$cap/node-env.capture" "server must receive the key via environment"
  argv_line=$(grep '^argv=' "$cap/node-env.capture")
  case "$argv_line" in
    *"$key"*) fail "encryption key must never be passed as an argument" ;;
  esac
  assert_present "$home/data/freellmapi/run/server.pid" "start must record the server pid"
  log="$home/data/freellmapi/run/server.log"
  [ ! -s "$log" ] || assert_no_grep "$key" "$log" "encryption key must never reach the wrapper log"

  stop_lane "$home" "$fakebin"
  pass "start binds loopback and never leaks the key"
}

test_start_stops_service_on_non_loopback_listener() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  set +e
  OUT=$(FM_HOME="$home" PATH="$fakebin:$PATH" FAKE_LSOF_ADDR=0.0.0.0 \
    FM_FREELLMAPI_START_TIMEOUT=3 FM_FREELLMAPI_STOP_TIMEOUT=2 "$TOOL" start 2>&1)
  CODE=$?
  set -e
  [ "$CODE" -ne 0 ] || fail "start must fail when a listener is not loopback"
  assert_contains "$OUT" "REFUSED" "non-loopback binding must be refused loudly"
  assert_absent "$home/data/freellmapi/run/server.pid" "refused start must not leave a pid record"
  assert_present "$cap/node-signal.capture" "refused start must stop the spawned server"
  pass "start stops the service on a non-loopback listener"
}

test_start_fails_closed_when_binding_unverifiable() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  set +e
  OUT=$(FM_HOME="$home" PATH="$fakebin:$PATH" FAKE_LSOF_EXIT=1 \
    FM_FREELLMAPI_START_TIMEOUT=3 FM_FREELLMAPI_STOP_TIMEOUT=2 "$TOOL" start 2>&1)
  CODE=$?
  set -e
  [ "$CODE" -ne 0 ] || fail "start must fail when the binding cannot be verified"
  assert_contains "$OUT" "REFUSED" "unverifiable binding must be refused, not tolerated"
  assert_present "$cap/node-signal.capture" "unverifiable start must stop the spawned server"
  pass "start fails closed when the binding is unverifiable"
}

test_start_refuses_malformed_encryption_key() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  mkdir -p "$home/data/freellmapi"
  printf 'short-and-invalid\n' > "$home/data/freellmapi/encryption.key"
  run_tool "$home" "$fakebin" start
  [ "$CODE" -ne 0 ] || fail "start must refuse a malformed encryption key"
  assert_contains "$OUT" "64 lowercase hex" "refusal must state the expected key shape"
  assert_not_contains "$OUT" "short-and-invalid" "even a malformed key value must not be echoed"
  assert_absent "$cap/node-env.capture" "server must not start with a malformed key"
  pass "start refuses a malformed encryption key"
}

# --- seed-keys ---------------------------------------------------------------

test_seed_keys_refuses_missing_env_and_var() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" seed-keys google=GEMINI_API_KEY
  [ "$CODE" -ne 0 ] || fail "seed-keys without a fleet .env must fail"
  assert_contains "$OUT" ".env not found" "refusal must name the missing .env"

  printf 'OTHER_VAR=x\n' > "$home/.env"
  run_tool "$home" "$fakebin" seed-keys google=GEMINI_API_KEY
  [ "$CODE" -ne 0 ] || fail "seed-keys with a missing var must fail"
  assert_contains "$OUT" "GEMINI_API_KEY is missing or empty" "refusal must name the variable, not a value"
  pass "seed-keys refuses missing .env and missing variable"
}

test_seed_keys_sends_value_via_stdin_only() {
  local root home fakebin cap fake_key
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  fake_key="fake-test-key-AIzaNotARealKey123456"
  printf 'GEMINI_API_KEY=%s\n' "$fake_key" > "$home/.env"
  run_tool "$home" "$fakebin" seed-keys google=GEMINI_API_KEY
  expect_code 0 "$CODE" "seed-keys"
  assert_contains "$OUT" "seeded google key from GEMINI_API_KEY" "seed-keys must confirm by variable name"
  assert_not_contains "$OUT" "$fake_key" "key value must never reach stdout/stderr"
  assert_grep "$fake_key" "$cap/curl-stdin.log" "key value must travel via stdin body"
  assert_no_grep "$fake_key" "$cap/curl-argv.log" "key value must never appear in curl argv"
  assert_no_grep 'fake-session-token-1234' "$cap/curl-argv.log" "session token must never appear in curl argv"
  assert_grep '"label":"GEMINI_API_KEY"' "$cap/curl-stdin.log" "label must be the env var name"
  pass "seed-keys sends the value via stdin only"
}

test_seed_keys_refuses_injection_prone_value() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  printf 'BAD_KEY=va"lue\n' > "$home/.env"
  run_tool "$home" "$fakebin" seed-keys google=BAD_KEY
  [ "$CODE" -ne 0 ] || fail "seed-keys must refuse a quote-bearing value"
  assert_contains "$OUT" "refuses to forward" "refusal must explain without echoing the value"
  assert_not_contains "$OUT" 'va"lue' "refused value must not be echoed"
  assert_absent "$cap/curl-stdin.log" "no request body may be sent for a refused value"
  pass "seed-keys refuses an injection-prone value"
}

# --- status and stop ---------------------------------------------------------

test_status_reports_not_running() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" status
  [ "$CODE" -ne 0 ] || fail "status must be non-zero when not running"
  assert_contains "$OUT" "not running" "status must say it is not running"
  pass "status reports not running"
}

test_status_warns_on_non_loopback_without_stopping() {
  local root home fakebin cap pid alive
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  run_tool "$home" "$fakebin" start
  expect_code 0 "$CODE" "start before status"
  pid=$(cat "$home/data/freellmapi/run/server.pid")
  set +e
  OUT=$(FM_HOME="$home" PATH="$fakebin:$PATH" FAKE_LSOF_ADDR=0.0.0.0 \
    FM_FREELLMAPI_STOP_TIMEOUT=2 "$TOOL" status 2>&1)
  CODE=$?
  set -e
  [ "$CODE" -ne 0 ] || fail "status must fail when a listener is not loopback"
  assert_contains "$OUT" "WARNING" "status must warn on non-loopback bind"
  assert_contains "$OUT" "status does not stop" "status must say it does not stop"
  alive=0
  kill -0 "$pid" 2>/dev/null && alive=1
  [ "$alive" -eq 1 ] || fail "status must not stop the server (only start/stop do)"
  assert_absent "$cap/node-signal.capture" "status must not send TERM on bad bind"
  stop_lane "$home" "$fakebin"
  pass "status warns on non-loopback without stopping"
}

test_stop_gracefully_terminates() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  built_install "$home"
  run_tool "$home" "$fakebin" start
  expect_code 0 "$CODE" "start before stop"
  run_tool "$home" "$fakebin" stop
  expect_code 0 "$CODE" "stop"
  assert_contains "$OUT" "stopped" "stop must confirm"
  assert_grep 'term' "$cap/node-signal.capture" "stop must deliver SIGTERM, not SIGKILL first"
  assert_absent "$home/data/freellmapi/run/server.pid" "stop must remove the pid record"
  pass "stop gracefully terminates"
}

test_stop_refuses_foreign_pid() {
  local root home fakebin cap foreign
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  sleep 300 &
  foreign=$!
  mkdir -p "$home/data/freellmapi/run"
  printf '%s\n' "$foreign" > "$home/data/freellmapi/run/server.pid"
  run_tool "$home" "$fakebin" stop
  code=$CODE
  alive=0
  kill -0 "$foreign" 2>/dev/null && alive=1
  kill "$foreign" 2>/dev/null || true
  wait "$foreign" 2>/dev/null || true
  [ "$code" -ne 0 ] || fail "stop must refuse a pid that is not this lane's server"
  [ "$alive" -eq 1 ] || fail "stop must not kill an unrelated process"
  assert_contains "$OUT" "refusing to signal" "refusal must be explicit"
  pass "stop refuses a foreign pid"
}

# `node dist/index.js` is a common invocation, so a recycled pid running some
# other service under that relative path must never satisfy the lane guard.
test_stop_refuses_unrelated_dist_index_pid() {
  local root home fakebin cap impostor pid code alive
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  impostor="$root/impostor.sh"
  cat > "$impostor" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
SH
  chmod +x "$impostor"
  bash "$impostor" dist/index.js &
  pid=$!
  mkdir -p "$home/data/freellmapi/run"
  printf '%s\n' "$pid" > "$home/data/freellmapi/run/server.pid"
  run_tool "$home" "$fakebin" stop
  code=$CODE
  alive=0
  kill -0 "$pid" 2>/dev/null && alive=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$code" -ne 0 ] || fail "stop must refuse an unrelated dist/index.js process"
  [ "$alive" -eq 1 ] || fail "stop must not signal an unrelated dist/index.js process"
  assert_contains "$OUT" "refusing to signal" "refusal must be explicit"
  pass "stop refuses an unrelated dist/index.js pid"
}

test_stop_without_pid_record() {
  local root home fakebin cap
  root=$(fm_test_tmproot fm-freellmapi)
  read -r home fakebin <<EOF
$(fresh_home "$root")
EOF
  cap="$root/cap"
  server_fakes "$fakebin" "$cap"
  run_tool "$home" "$fakebin" stop
  [ "$CODE" -ne 0 ] || fail "stop without a pid record must fail loudly"
  assert_contains "$OUT" "not running" "stop must explain there is nothing to stop"
  pass "stop without a pid record refuses clearly"
}

test_static_pin_and_safety_contract
test_help_states_policy
test_install_refuses_without_risk_acceptance
test_install_fetches_exact_pin
test_install_refuses_head_mismatch
test_start_refuses_without_install
test_start_binds_loopback_and_never_leaks_key
test_start_stops_service_on_non_loopback_listener
test_start_fails_closed_when_binding_unverifiable
test_start_refuses_malformed_encryption_key
test_seed_keys_refuses_missing_env_and_var
test_seed_keys_sends_value_via_stdin_only
test_seed_keys_refuses_injection_prone_value
test_status_reports_not_running
test_status_warns_on_non_loopback_without_stopping
test_stop_gracefully_terminates
test_stop_refuses_foreign_pid
test_stop_refuses_unrelated_dist_index_pid
test_stop_without_pid_record

echo "fm-freellmapi tests passed"
