#!/usr/bin/env bash
# Tests for the firstmate-local lndev attach-as-captain broker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROKER="$ROOT/bin/fm-lndev-captain-broker.sh"
CLIENT="$ROOT/bin/fm-lndev-captain"
TMP_ROOT=$(fm_test_tmproot fm-lndev-captain)
REAL_PATH=$PATH
RAW_LCLI='lcli_TEST_BEARER_SECRET_123'
RAW_SSH='DAYTONA_SSH_TOKEN_SECRET_456'
BROKER_PID=
ENV_ARGS=()

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/project" "$dir/worktree" "$fakebin" "$dir/records"
  printf 'ok\n' > "$dir/scenario"
  printf '/tmp/fmlndev-%s-%s.sock\n' "$$" "$name" > "$dir/socket_path"
  printf '%s\n%s\n' "$RAW_LCLI" "$RAW_SSH" > "$dir/secrets"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "harness=codex" \
    "kind=scout" \
    "mode=local-only" \
    "yolo=off"
  fm_write_meta "$dir/home/state/task-b.meta" \
    "window=fm-task-b" \
    "worktree=$dir/worktree-b" \
    "project=$dir/project" \
    "harness=codex" \
    "kind=scout" \
    "mode=local-only" \
    "yolo=off"
  cat > "$fakebin/lndev" <<'SH'
#!/usr/bin/env bash
set -u
scenario=$(cat "${FM_LNDEV_FAKE_SCENARIO_FILE:?}")
record_dir=${FM_LNDEV_FAKE_RECORD_DIR:?}
mkdir -p "$record_dir"
{
  printf 'argv:'
  for arg in "$@"; do printf ' <%s>' "$arg"; done
  printf '\n'
  env | LC_ALL=C sort
} > "$record_dir/lndev.$$.txt"

version_ok() {
  printf 'lndev 0.1.0 (f6cc7cfe80561288b2dec737e79c1c12a379bcd8)\n'
}

whoami_ok() {
  printf 'Timothy Waldin <tim@example.invalid>  (identity 69fcb044917cb426d03802a7)\n'
  printf 'token 6a1710aaf81f609a8618f365\n'
}

auth_ok() {
  printf '6a1710aaf81f609a8618f365  macOS terminal                  created=2026-05-27T15:41:30.998Z  last-used=2026-07-20T18:51:28.149Z  expires=2099-08-25T15:41:30.998Z\n'
}

github_ok() {
  printf 'connected as twaldin, scopes=<none>, refresh-token expires 2099-01-20T18:00:00.094Z\n'
}

case "${1:-}" in
  --version)
    if [ "$scenario" = unsupported-version ]; then
      printf 'lndev 0.2.0 (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)\n'
    else
      version_ok
    fi
    ;;
  whoami)
    case "$scenario" in
      whoami-changed) printf 'Identity: Timothy Waldin tim@example.invalid 69fcb044917cb426d03802a7\n' ;;
      whoami-missing) printf 'Timothy Waldin <tim@example.invalid>  (identity 69fcb044917cb426d03802a7)\n' ;;
      whoami-duplicated) whoami_ok; printf 'token 6a1710aaf81f609a8618f365\n' ;;
      whoami-error) printf 'error: not authenticated\n' >&2; exit 1 ;;
      whoami-localized) printf 'Conectado como Timothy Waldin <tim@example.invalid> identidad 69fcb044917cb426d03802a7\n' ;;
      whoami-truncated) printf 'Timothy Waldin <tim@example.invalid>\n' ;;
      whoami-unrecognized-exit0) printf 'all good, trust me\n' ;;
      *) whoami_ok ;;
    esac
    ;;
  auth)
    [ "${2:-}" = list ] || exit 64
    case "$scenario" in
      auth-duplicated) auth_ok; auth_ok ;;
      auth-missing-field) printf '6a1710aaf81f609a8618f365  macOS terminal  expires=2099-08-25T15:41:30.998Z\n' ;;
      *) auth_ok ;;
    esac
    ;;
  github)
    [ "${2:-}" = status ] || exit 64
    case "$scenario" in
      github-changed) printf 'GitHub connected: twaldin\n' ;;
      *) github_ok ;;
    esac
    ;;
  shell)
    case "${2:-}" in
      ls)
        case "$scenario" in
          shell-active)
            printf 'ID  STATUS  REPOSITORY  BRANCH  UPDATED\n'
            printf 'sess-ok  running  lindy  main  2099-01-01T00:00:00.000Z\n'
            ;;
          shell-extra)
            printf 'No active engineer shell sessions. Spawn one with: lndev shell new\n'
            printf 'Pass --all to include destroyed sessions.\n'
            printf 'unexpected footer\n'
            ;;
          *)
            printf 'No active engineer shell sessions. Spawn one with: lndev shell new\n'
            printf 'Pass --all to include destroyed sessions.\n'
            ;;
        esac
        ;;
      attach)
        session=${3:-}
        case "$scenario" in
          attach-changed)
            printf 'connected to %s\n' "$session"
            printf 'bye %s\n' "$session"
            ;;
          attach-leaks-secrets)
            sed -n '1p' "${FM_LNDEV_FAKE_SECRET_FILE:?}"
            printf 'sshToken=%s\n' "$(sed -n '2p' "${FM_LNDEV_FAKE_SECRET_FILE:?}")"
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-split-lcli-two)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix '
            printf 'lcli_TEST'
            sleep 0.2
            printf '_BEARER_SECRET_123\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-split-ssh-three)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix '
            printf 'DAYTONA_'
            sleep 0.2
            printf 'SSH_TOKEN'
            sleep 0.2
            printf '_SECRET_456\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-ansi-lcli)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix lcli_\033[32mTEST_BEARER_SECRET_123\033[0m\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-ansi-split-lcli)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix lcli_\033[32m'
            sleep 0.2
            printf 'TEST_BEARER_SECRET_123\033[0m\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-osc-lcli)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix lcli_\033]0;ignored title\aTEST_BEARER_SECRET_123\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-dcs-ss-lcli)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix lcli_\033Pignored payload\033\\\033NZTEST_BEARER_SECRET_123\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-backspace-lcli)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'prefix lcli_TEST_BEARER_SECREX\bT_123\n'
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          attach-read-stdin)
            printf 'Attached to engineer shell session %s\n' "$session"
            IFS= read -r line || line=
            printf 'command seen: %s\n' "$line"
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
          *)
            printf 'Attached to engineer shell session %s\n' "$session"
            printf 'Detached from engineer shell session %s\n' "$session"
            ;;
        esac
        ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$fakebin/lndev"
  printf '%s\n' "$dir"
}

set_scenario() {
  printf '%s\n' "$2" > "$1/scenario"
}

build_env_args() {
  local dir=$1
  ENV_ARGS=(
    "FM_HOME=$dir/home"
    "PATH=$dir/fakebin:$REAL_PATH"
    "FM_LNDEV_CAPTAIN_SOCKET=$(cat "$dir/socket_path")"
    "FM_LNDEV_FAKE_SCENARIO_FILE=$dir/scenario"
    "FM_LNDEV_FAKE_RECORD_DIR=$dir/records"
    "FM_LNDEV_FAKE_SECRET_FILE=$dir/secrets"
    "FM_LNDEV_AUDIT_KEY_FILE=$dir/audit-hmac.key"
  )
}

start_broker() {
  local dir=$1 sock attempt
  sock=$(cat "$dir/socket_path")
  rm -f "$sock"
  build_env_args "$dir"
  env "${ENV_ARGS[@]}" "$BROKER" serve > "$dir/server.out" 2> "$dir/server.err" &
  BROKER_PID=$!
  for ((attempt = 0; attempt < 80; attempt += 1)); do
    [ -S "$sock" ] && return 0
    sleep 0.05
  done
  cat "$dir/server.out" >&2 || true
  cat "$dir/server.err" >&2 || true
  fail "broker did not publish socket"
}

stop_broker() {
  if [ -n "${BROKER_PID:-}" ]; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
    find /tmp -maxdepth 1 -name "fmlndev-$$-*.sock" -delete 2>/dev/null || true
    BROKER_PID=
  fi
}

json_field() {
  node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(o[process.argv[2]] ?? "")' "$1" "$2"
}

mint_handle() {
  local dir=$1 operation=$2 out=$3 session=${4:-}
  local cmd
  cmd=(env)
  build_env_args "$dir"
  cmd+=("${ENV_ARGS[@]}")
  cmd+=("$BROKER" mint --task task-a --operation "$operation")
  if [ -n "$session" ]; then cmd+=(--session "$session"); fi
  "${cmd[@]}" > "$out" 2> "$out.err" || fail "mint $operation failed: $(cat "$out.err")"
  json_field "$out" handle
}

run_client() {
  local dir=$1 out=$2 err=$3
  shift 3
  local status cmd
  cmd=(env)
  build_env_args "$dir"
  cmd+=("${ENV_ARGS[@]}")
  status=0
  "${cmd[@]}" "$CLIENT" "$@" > "$out" 2> "$err" || status=$?
  printf '%s\n' "$status"
}

run_client_with_stdin() {
  local dir=$1 input=$2 out=$3 err=$4
  shift 4
  local status cmd
  cmd=(env)
  build_env_args "$dir"
  cmd+=("${ENV_ARGS[@]}")
  status=0
  printf '%s' "$input" | "${cmd[@]}" "$CLIENT" "$@" > "$out" 2> "$err" || status=$?
  printf '%s\n' "$status"
}

direct_socket_request() {
  local dir=$1 out=$2 err=$3 payload=$4
  shift 4
  local status cmd
  cmd=(env)
  cmd+=("$@")
  build_env_args "$dir"
  cmd+=("${ENV_ARGS[@]}")
  status=0
  "${cmd[@]}" node -e '
const net = require("node:net");
const payload = process.argv[1];
const socket = net.connect(process.env.FM_LNDEV_CAPTAIN_SOCKET);
let out = "";
let done = false;
function finish(code) {
  if (done) return;
  done = true;
  process.stdout.write(out);
  process.exitCode = code;
}
socket.setEncoding("utf8");
socket.setTimeout(5000, () => {
  process.stderr.write("socket timeout\n");
  socket.destroy();
  finish(2);
});
socket.on("connect", () => socket.write(payload));
socket.on("data", (chunk) => {
  out += chunk;
});
socket.on("end", () => finish(0));
socket.on("close", () => finish(process.exitCode || 0));
socket.on("error", (error) => {
  process.stderr.write(String(error.message) + "\n");
  finish(1);
});
' "$payload" > "$out" 2> "$err" || status=$?
  printf '%s\n' "$status"
}

normalize_display_text() {
  printf '%s' "$1" | perl -0pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r\n/\n/g; s/\r/\n/g; s/[\x04\x08]//g'
}

assert_records_have_no_raw_secret() {
  local dir=$1
  ! grep -R -- "$RAW_LCLI" "$dir/records" "$dir/home/data" "$dir/home/state" >/dev/null \
    || fail "raw lcli bearer leaked into lane-facing records"
  ! grep -R -- "$RAW_SSH" "$dir/records" "$dir/home/data" "$dir/home/state" >/dev/null \
    || fail "raw ssh token leaked into lane-facing records"
}

test_status_and_shell_list_allowed() {
  local dir handle out err status mint_json shell_handle
  dir=$(make_case status)
  mint_json="$dir/mint-status.json"
  handle=$(mint_handle "$dir" status "$mint_json")
  shell_handle=$(mint_handle "$dir" shell-list "$dir/mint-shell.json")
  start_broker "$dir"
  status=$(run_client "$dir" "$dir/status.out" "$dir/status.err" status --task task-a --handle "$handle")
  expect_code 0 "$status" "status request"
  out=$(cat "$dir/status.out")
  assert_contains "$out" '"tokenId": "6a1710aaf81f609a8618f365"' "status did not include token id metadata"
  assert_not_contains "$out" "$RAW_LCLI" "status leaked raw lcli"
  status=$(run_client "$dir" "$dir/shell.out" "$dir/shell.err" shell-list --task task-a --handle "$shell_handle")
  expect_code 0 "$status" "shell-list request"
  assert_contains "$(cat "$dir/shell.out")" '"sessions": []' "shell-list did not parse no-active shape"
  stop_broker
  pass "status and shell-list require capabilities and return only metadata"
}

test_attach_success_and_no_secret_material() {
  local dir handle status out err
  dir=$(make_case attach-ok)
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  status=$(run_client "$dir" "$dir/attach.out" "$dir/attach.err" attach --task task-a --session sess-ok --handle "$handle")
  expect_code 0 "$status" "attach request"
  out=$(cat "$dir/attach.out")
  err=$(cat "$dir/attach.err")
  assert_contains "$out" "Attached to engineer shell session sess-ok" "attach stdout missing start marker"
  assert_contains "$out" "Detached from engineer shell session sess-ok" "attach stdout missing detach marker"
  assert_not_contains "$out$err" "$RAW_LCLI" "attach leaked raw lcli"
  assert_not_contains "$out$err" "$RAW_SSH" "attach leaked raw ssh token"
  assert_records_have_no_raw_secret "$dir"
  stop_broker
  pass "ordinary attach uses the broker PTY and emits no fake raw credential material"
}

test_attach_transcript_is_redacted_and_audit_anchored() {
  local dir handle status transcript_path digest computed audit_file transcript
  dir=$(make_case attach-transcript)
  set_scenario "$dir" attach-read-stdin
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  status=$(run_client_with_stdin "$dir" "audit-command"$'\n' "$dir/attach.out" "$dir/attach.err" attach --task task-a --session sess-ok --handle "$handle")
  expect_code 0 "$status" "attach transcript request"
  audit_file=$(find "$dir/home/data/lndev-captain-audit" -type f -name '*.jsonl' | sort | tail -n 1)
  node -e '
const fs = require("node:fs");
const records = fs.readFileSync(process.argv[1], "utf8").trim().split(/\n/).map((line) => JSON.parse(line));
const stop = records.find((record) => record.event === "attach_stop" && record.result === "allowed");
if (!stop) process.exit(2);
console.log(stop.attach.transcript_path || "");
console.log(stop.attach.transcript_digest || "");
' "$audit_file" > "$dir/transcript-meta"
  transcript_path=$(sed -n '1p' "$dir/transcript-meta")
  digest=$(sed -n '2p' "$dir/transcript-meta")
  [ -f "$transcript_path" ] || fail "attach transcript file was not written"
  transcript=$(cat "$transcript_path")
  assert_contains "$transcript" '"stream":"stdin"' "attach transcript missing stdin stream"
  assert_contains "$transcript" "audit-command" "attach transcript missing lane stdin"
  assert_contains "$transcript" "Attached to engineer shell session sess-ok" "attach transcript missing stdout"
  assert_not_contains "$transcript" "$RAW_LCLI" "attach transcript leaked raw lcli"
  assert_not_contains "$transcript" "$RAW_SSH" "attach transcript leaked raw ssh token"
  computed=$(node -e 'const fs=require("node:fs"); const crypto=require("node:crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$transcript_path")
  [ "$computed" = "$digest" ] || fail "attach transcript digest was not anchored in audit record"
  stop_broker
  pass "attach writes a redacted PTY transcript and anchors its digest in the audit chain"
}

test_operation_allowlist_denies_writes() {
  local dir handle op status denied
  dir=$(make_case allowlist)
  handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  start_broker "$dir"
  denied=0
  for op in spawn preview keep-alive pause resume kill rescue logs remote-exec github-connect graphite-connect mcp-connect auth-revoke logout purge; do
    status=$(run_client "$dir" "$dir/$op.out" "$dir/$op.err" "$op" --task task-a --session sess-ok --handle "$handle")
    [ "$status" -ne 0 ] || fail "$op was not denied"
    assert_contains "$(cat "$dir/$op.err")" "operation-not-allowed" "$op deny reason missing"
    denied=$((denied + 1))
  done
  stop_broker
  assert_contains "$(cat "$dir/home/data/lndev-captain-audit/"*.jsonl)" '"result":"denied"' "denied audit records missing"
  pass "operation allowlist denied $denied write/lifecycle/connect/auth operations"
}

test_capability_validation_denies_bad_handles_and_args() {
  local dir status_handle attach_handle expired_handle status
  dir=$(make_case capabilities)
  status_handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  attach_handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  build_env_args "$dir"
  env "${ENV_ARGS[@]}" "$BROKER" mint --task task-a --operation status --expires-at 2000-01-01T00:00:00.000Z \
    > "$dir/mint-expired.json" 2> "$dir/mint-expired.err" || fail "expired mint failed"
  expired_handle=$(json_field "$dir/mint-expired.json" handle)
  start_broker "$dir"
  find "$dir/records" -type f -delete
  status=$(run_client "$dir" "$dir/missing.out" "$dir/missing.err" status --task task-a)
  [ "$status" -ne 0 ] || fail "missing handle was not denied"
  assert_contains "$(cat "$dir/missing.err")" "missing-handle" "missing handle reason missing"
  [ -z "$(find "$dir/records" -type f -print -quit)" ] \
    || fail "missing handle triggered lndev probe before capability validation"
  status=$(run_client "$dir" "$dir/wrong-task.out" "$dir/wrong-task.err" status --task task-b --handle "$status_handle")
  [ "$status" -ne 0 ] || fail "wrong task was not denied"
  assert_contains "$(cat "$dir/wrong-task.err")" "capability-task-mismatch" "wrong task reason missing"
  status=$(run_client "$dir" "$dir/wrong-session.out" "$dir/wrong-session.err" attach --task task-a --session sess-other --handle "$attach_handle")
  [ "$status" -ne 0 ] || fail "wrong session was not denied"
  assert_contains "$(cat "$dir/wrong-session.err")" "capability-session-mismatch" "wrong session reason missing"
  status=$(run_client "$dir" "$dir/expired.out" "$dir/expired.err" status --task task-a --handle "$expired_handle")
  [ "$status" -ne 0 ] || fail "expired handle was not denied"
  assert_contains "$(cat "$dir/expired.err")" "expired-handle" "expired handle reason missing"
  stop_broker
  pass "capability validation denies missing, wrong-task, wrong-session, and expired handles"
}

test_sandbox_exclusion_denies_status() {
  local dir handle status sandbox_dir payload forged
  dir=$(make_case sandbox)
  handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  start_broker "$dir"
  status=$(LINDY_SESSION_TYPE=eng-agent run_client "$dir" "$dir/session-type.out" "$dir/session-type.err" status --task task-a --handle "$handle")
  [ "$status" -ne 0 ] || fail "LINDY_SESSION_TYPE marker was not denied"
  status=$(LINDY_AGENT_SESSION_ID=abc run_client "$dir" "$dir/agent.out" "$dir/agent.err" status --task task-a --handle "$handle")
  [ "$status" -ne 0 ] || fail "LINDY_AGENT marker was not denied"
  status=$(LINDY_BOOT_TOKEN=boot run_client "$dir" "$dir/boot.out" "$dir/boot.err" status --task task-a --handle "$handle")
  [ "$status" -ne 0 ] || fail "LINDY_BOOT_TOKEN marker was not denied"
  status=$(LINDY_SHELL_API_URL=https://shell.invalid run_client "$dir" "$dir/api.out" "$dir/api.err" status --task task-a --handle "$handle")
  [ "$status" -ne 0 ] || fail "LINDY_SHELL_API_URL marker was not denied"
  sandbox_dir="$TMP_ROOT/daytona/sandboxes/lane"
  mkdir -p "$sandbox_dir"
  status=0
  (
    cd "$sandbox_dir" || exit 1
    run_client "$dir" "$dir/sandbox-cwd.out" "$dir/sandbox-cwd.err" status --task task-a --handle "$handle"
  ) > "$dir/sandbox-cwd.status"
  status=$(cat "$dir/sandbox-cwd.status")
  [ "$status" -ne 0 ] || fail "sandbox cwd was not denied"
  payload='{"protocol":"fm-lndev-captain.v1","taskId":"task-a","handle":"'"$handle"'","operation":"status","args":{},"caller":{"pid":1,"ppid":1,"exe":"forged","cwd":"/safe","tty":"none","envMarkers":[]}}'
  status=$(direct_socket_request "$dir" "$dir/forged.out" "$dir/forged.err" "$payload"$'\n' "LINDY_SESSION_TYPE=eng-agent")
  expect_code 0 "$status" "direct forged sandbox request transport"
  forged=$(cat "$dir/forged.out")
  assert_contains "$forged" "sandbox-marker" "forged clean caller metadata bypassed server-side sandbox marker check"
  stop_broker
  pass "server-derived sandbox env markers and Daytona/lndev cwd are denied even for status"
}

test_request_buffer_limit_denies_oversized_line() {
  local dir payload status response
  dir=$(make_case request-limit)
  start_broker "$dir"
  payload=$(printf 'x%.0s' {1..70000})
  status=$(direct_socket_request "$dir" "$dir/oversized.out" "$dir/oversized.err" "$payload")
  expect_code 0 "$status" "oversized direct request transport"
  response=$(cat "$dir/oversized.out")
  assert_contains "$response" "request-too-large" "oversized request did not hit fail-closed request limit"
  stop_broker
  assert_contains "$(cat "$dir/home/data/lndev-captain-audit/"*.jsonl)" '"reason":"request-too-large"' "request-too-large audit record missing"
  pass "request line buffers are bounded and fail closed"
}

test_parser_drift_denies_mint() {
  local scenario dir status err expected operation
  for scenario in unsupported-version whoami-changed whoami-missing whoami-duplicated whoami-error whoami-localized whoami-truncated whoami-unrecognized-exit0 auth-duplicated auth-missing-field github-changed shell-extra; do
    dir=$(make_case "parse-$scenario")
    set_scenario "$dir" "$scenario"
    operation=status
    [ "$scenario" = shell-extra ] && operation=shell-list
    status=0
    build_env_args "$dir"
    env "${ENV_ARGS[@]}" "$BROKER" mint --task task-a --operation "$operation" > "$dir/mint.out" 2> "$dir/mint.err" || status=$?
    [ "$status" -ne 0 ] || fail "$scenario did not fail closed during mint"
    err=$(cat "$dir/mint.err")
    expected=parse-mismatch
    [ "$scenario" = unsupported-version ] && expected=unsupported-lndev-version
    assert_contains "$err" "$expected" "$scenario did not report $expected"
  done
  pass "parser drift and unsupported version fail closed before capability mint"
}

test_unsupported_version_denies_existing_capability() {
  local dir handle status
  dir=$(make_case unsupported-request)
  handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  start_broker "$dir"
  set_scenario "$dir" unsupported-version
  status=$(run_client "$dir" "$dir/status.out" "$dir/status.err" status --task task-a --handle "$handle")
  [ "$status" -ne 0 ] || fail "unsupported version request was not denied"
  assert_contains "$(cat "$dir/status.err")" "unsupported-lndev-version" "unsupported request reason missing"
  stop_broker
  pass "unsupported lndev version denies existing capabilities on request"
}

test_request_uses_single_lndev_version_probe() {
  local dir handle status count
  dir=$(make_case version-count)
  handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  start_broker "$dir"
  find "$dir/records" -type f -delete
  status=$(run_client "$dir" "$dir/status.out" "$dir/status.err" status --task task-a --handle "$handle")
  expect_code 0 "$status" "status version count request"
  count=$(grep -R -h '^argv: <--version>$' "$dir/records" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "status request used $count lndev --version probes, expected 1"
  stop_broker
  pass "request-time identity collection performs one lndev --version probe"
}

test_attach_parse_mismatch_and_secret_leak_fail_closed() {
  local dir handle status output
  dir=$(make_case attach-drift)
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  set_scenario "$dir" attach-changed
  status=$(run_client "$dir" "$dir/attach-changed.out" "$dir/attach-changed.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "attach changed markers did not fail"
  assert_contains "$(cat "$dir/attach-changed.err")" "parse-mismatch" "attach changed marker reason missing"
  set_scenario "$dir" attach-leaks-secrets
  status=$(run_client "$dir" "$dir/attach-leak.out" "$dir/attach-leak.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "attach secret output did not fail"
  output="$(cat "$dir/attach-leak.out")$(cat "$dir/attach-leak.err")"
  assert_not_contains "$output" "$RAW_LCLI" "leaky attach exposed raw lcli"
  assert_not_contains "$output" "$RAW_SSH" "leaky attach exposed raw ssh token"
  assert_contains "$output" "secret-output" "leaky attach reason missing"
  stop_broker
  pass "attach success is confirmed only by exact markers and secret-shaped output fails closed"
}

test_split_secret_chunks_never_reach_lane() {
  local dir handle status output
  dir=$(make_case attach-split)
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  set_scenario "$dir" attach-split-lcli-two
  status=$(run_client "$dir" "$dir/split-lcli.out" "$dir/split-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "split lcli output did not fail closed"
  output="$(cat "$dir/split-lcli.out")$(cat "$dir/split-lcli.err")"
  assert_not_contains "$output" "$RAW_LCLI" "split lcli attach exposed raw token"
  assert_not_contains "$output" "lcli_TEST" "split lcli attach exposed token prefix"
  assert_not_contains "$output" "BEARER_SECRET" "split lcli attach exposed token suffix"
  assert_contains "$output" "secret-output" "split lcli failure reason missing"
  set_scenario "$dir" attach-split-ssh-three
  status=$(run_client "$dir" "$dir/split-ssh.out" "$dir/split-ssh.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "split ssh-token output did not fail closed"
  output="$(cat "$dir/split-ssh.out")$(cat "$dir/split-ssh.err")"
  assert_not_contains "$output" "$RAW_SSH" "split ssh attach exposed raw token"
  assert_not_contains "$output" "DAYTONA_" "split ssh attach exposed token prefix"
  assert_not_contains "$output" "SSH_TOKEN" "split ssh attach exposed token middle"
  assert_not_contains "$output" "TOKEN_SECRET" "split ssh attach exposed token suffix"
  assert_contains "$output" "secret-output" "split ssh-token failure reason missing"
  stop_broker
  pass "attach redaction buffers across two- and three-chunk split credentials"
}

test_ansi_split_secret_never_reaches_lane() {
  local dir handle status output normalized
  dir=$(make_case attach-ansi)
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  set_scenario "$dir" attach-ansi-lcli
  status=$(run_client "$dir" "$dir/ansi-lcli.out" "$dir/ansi-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "ANSI-interleaved lcli output did not fail closed"
  output="$(cat "$dir/ansi-lcli.out")$(cat "$dir/ansi-lcli.err")"
  normalized=$(normalize_display_text "$output")
  assert_not_contains "$output" "$RAW_LCLI" "ANSI-interleaved attach exposed raw lcli"
  assert_not_contains "$normalized" "$RAW_LCLI" "ANSI-normalized attach output reconstructs raw lcli"
  assert_not_contains "$normalized" "lcli_TEST" "ANSI-normalized attach output exposes lcli prefix"
  assert_contains "$output$normalized" "secret-output" "ANSI-interleaved lcli failure reason missing"
  set_scenario "$dir" attach-ansi-split-lcli
  status=$(run_client "$dir" "$dir/ansi-split-lcli.out" "$dir/ansi-split-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "ANSI-plus-chunk-split lcli output did not fail closed"
  output="$(cat "$dir/ansi-split-lcli.out")$(cat "$dir/ansi-split-lcli.err")"
  normalized=$(normalize_display_text "$output")
  assert_not_contains "$output" "$RAW_LCLI" "ANSI-plus-chunk-split attach exposed raw lcli"
  assert_not_contains "$normalized" "$RAW_LCLI" "ANSI-plus-chunk-normalized output reconstructs raw lcli"
  assert_not_contains "$normalized" "lcli_TEST" "ANSI-plus-chunk-normalized output exposes lcli prefix"
  assert_contains "$output$normalized" "secret-output" "ANSI-plus-chunk-split lcli failure reason missing"
  stop_broker
  pass "attach redaction normalizes ANSI before detecting split credentials"
}

test_escape_grammar_and_overwrite_secrets_never_reach_lane() {
  local dir handle status output normalized
  dir=$(make_case attach-escape-grammar)
  handle=$(mint_handle "$dir" attach-existing "$dir/mint-attach.json" sess-ok)
  start_broker "$dir"
  set_scenario "$dir" attach-osc-lcli
  status=$(run_client "$dir" "$dir/osc-lcli.out" "$dir/osc-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "OSC-interleaved lcli output did not fail closed"
  output="$(cat "$dir/osc-lcli.out")$(cat "$dir/osc-lcli.err")"
  normalized=$(normalize_display_text "$output")
  assert_not_contains "$output" "$RAW_LCLI" "OSC-interleaved attach exposed raw lcli"
  assert_not_contains "$normalized" "$RAW_LCLI" "OSC-normalized attach output reconstructs raw lcli"
  assert_contains "$output$normalized" "secret-output" "OSC-interleaved lcli failure reason missing"
  set_scenario "$dir" attach-dcs-ss-lcli
  status=$(run_client "$dir" "$dir/dcs-ss-lcli.out" "$dir/dcs-ss-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "DCS/SS2-interleaved lcli output did not fail closed"
  output="$(cat "$dir/dcs-ss-lcli.out")$(cat "$dir/dcs-ss-lcli.err")"
  assert_not_contains "$output" "$RAW_LCLI" "DCS/SS2-interleaved attach exposed raw lcli"
  assert_contains "$output" "secret-output" "DCS/SS2-interleaved lcli failure reason missing"
  set_scenario "$dir" attach-backspace-lcli
  status=$(run_client "$dir" "$dir/backspace-lcli.out" "$dir/backspace-lcli.err" attach --task task-a --session sess-ok --handle "$handle")
  [ "$status" -ne 0 ] || fail "backspace-overwrite lcli output did not fail closed"
  output="$(cat "$dir/backspace-lcli.out")$(cat "$dir/backspace-lcli.err")"
  assert_not_contains "$output" "$RAW_LCLI" "backspace-overwrite attach exposed raw lcli"
  assert_contains "$output" "secret-output" "backspace-overwrite lcli failure reason missing"
  stop_broker
  pass "attach redaction normalizes OSC, DCS, SS2/SS3, and backspace overwrites before detection"
}

test_audit_hash_chain_detects_tamper() {
  local dir handle status file
  dir=$(make_case audit)
  handle=$(mint_handle "$dir" status "$dir/mint-status.json")
  start_broker "$dir"
  status=$(run_client "$dir" "$dir/missing.out" "$dir/missing.err" status --task task-a)
  [ "$status" -ne 0 ] || fail "expected denied request for audit fixture"
  status=$(run_client "$dir" "$dir/status.out" "$dir/status.err" status --task task-a --handle "$handle")
  expect_code 0 "$status" "audit status request"
  stop_broker
  [ -f "$dir/audit-hmac.key" ] || fail "audit HMAC key was not created outside FM_HOME"
  [ ! -e "$dir/home/audit-hmac.key" ] || fail "audit HMAC key was written inside FM_HOME"
  assert_contains "$(cat "$dir/home/data/lndev-captain-audit/head.json")" '"hash_alg": "hmac-sha256"' "audit head does not identify HMAC chain"
  build_env_args "$dir"
  status=0
  env "FM_HOME=$dir/home" "FM_LNDEV_AUDIT_KEY_FILE=$dir/home/bad-audit-hmac.key" "$BROKER" verify-audit \
    > "$dir/verify-inside-key.out" 2> "$dir/verify-inside-key.err" || status=$?
  [ "$status" -ne 0 ] || fail "inside-FM_HOME audit HMAC key path was accepted"
  assert_contains "$(cat "$dir/verify-inside-key.err")" "outside FM_HOME" "inside-key denial reason missing"
  env "${ENV_ARGS[@]}" "$BROKER" verify-audit > "$dir/verify.out" 2> "$dir/verify.err" \
    || fail "audit verification failed before tamper"
  file=$(find "$dir/home/data/lndev-captain-audit" -type f -name '*.jsonl' | sort | head -n 1)
  perl -0pi -e 's/missing-handle/tampered-handle/' "$file"
  status=0
  env "${ENV_ARGS[@]}" "$BROKER" verify-audit > "$dir/verify2.out" 2> "$dir/verify2.err" || status=$?
  [ "$status" -ne 0 ] || fail "audit verification did not detect tamper"
  pass "HMAC audit hash-chain verification detects edited past records"
}

test_status_and_shell_list_allowed
test_attach_success_and_no_secret_material
test_attach_transcript_is_redacted_and_audit_anchored
test_operation_allowlist_denies_writes
test_capability_validation_denies_bad_handles_and_args
test_sandbox_exclusion_denies_status
test_request_buffer_limit_denies_oversized_line
test_parser_drift_denies_mint
test_unsupported_version_denies_existing_capability
test_request_uses_single_lndev_version_probe
test_attach_parse_mismatch_and_secret_leak_fail_closed
test_split_secret_chunks_never_reach_lane
test_ansi_split_secret_never_reaches_lane
test_escape_grammar_and_overwrite_secrets_never_reach_lane
test_audit_hash_chain_detects_tamper
