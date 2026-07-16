#!/usr/bin/env bash
# tests/fm-backend-paseo.test.sh - fake-paseo-CLI unit tests for the Paseo
# agent-session-provider adapter (bin/backends/paseo.sh).
#
# Mirrors tests/fm-backend-cmux.test.sh / fm-backend-herdr.test.sh: a small
# canned-response fake `paseo` on PATH (logging every invocation) plus real
# `node` (node is a genuine required tool for this adapter, not faked, exactly
# as jq is for herdr). No live Paseo daemon is required, so this runs in CI.
# The real-daemon end-to-end verification is recorded in docs/paseo-backend.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the paseo adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)
FAKE_BIN="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/paseo.log"
mkdir -p "$FAKE_BIN"
: > "$LOG"

# make_paseo_fakebin: a canned-response `paseo` stub. Dispatches on the
# subcommand and honours a few env knobs a test can flip:
#   FAKE_PASEO_VERSION  (default 0.1.104)  - status --json cliVersion
#   FAKE_PASEO_DAEMON   (default running)  - status --json localDaemon
#   FAKE_PASEO_STATUS   (default idle)     - inspect Status for a normal id
#   FAKE_PASEO_RUN_FAIL (default unset)    - make `run` exit non-zero
# An inspect id containing the literal "gone" returns a not-found error body on
# a non-zero exit, modelling a deleted agent.
cat > "$FAKE_BIN/paseo" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FAKE_PASEO_LOG:?}"
{ printf 'ARGS'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
sub=${1:-}
case "$sub" in
  status)
    printf '{"localDaemon":"%s","connectedDaemon":"%s","cliVersion":"%s","daemonVersion":"%s"}\n' \
      "${FAKE_PASEO_DAEMON:-running}" "${FAKE_PASEO_CONN:-reachable}" "${FAKE_PASEO_VERSION:-0.1.104}" "${FAKE_PASEO_VERSION:-0.1.104}"
    ;;
  provider)
    printf '[{"provider":"claude","status":"available"},{"provider":"codex","status":"available"},{"provider":"pi","status":"available"}]\n'
    ;;
  run)
    [ -n "${FAKE_PASEO_RUN_FAIL:-}" ] && exit 1
    printf '{"agentId":"agent-xyz-123","status":"running","provider":"claude","cwd":"/wt","title":"fm-t"}\n'
    ;;
  inspect)
    id=${2:-}
    case "$id" in
      *gone*) printf '{"error":{"code":"INSPECT_FAILED","message":"Failed to inspect agent: Agent not found: %s"}}\n' "$id" >&2; exit 1 ;;
      *) printf '{"Id":"%s","Status":"%s","Mode":"bypassPermissions","Cwd":"/wt"}\n' "$id" "${FAKE_PASEO_STATUS:-idle}" ;;
    esac
    ;;
  logs) printf '[User] do the thing\n[Write] /wt/hello.txt\nDONE\n' ;;
  send) : ;;
  stop) : ;;
  delete) printf '{"deletedCount":1,"agentIds":["%s"]}\n' "${2:-}" ;;
  *) exit 2 ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/paseo"

export FAKE_PASEO_LOG="$LOG"
export PATH="$FAKE_BIN:$PATH"

# shellcheck source=bin/backends/paseo.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/backends/paseo.sh"

last_call() { tail -1 "$LOG"; }

# --- provider mapping / grok refusal ----------------------------------------
for h in claude codex opencode pi; do
  out=$(fm_backend_paseo_provider_for_harness "$h") || fail "provider_for_harness $h should succeed"
  [ "$out" = "$h" ] || fail "provider_for_harness $h -> '$out', expected '$h'"
done
pass "paseo provider mapping accepts claude/codex/opencode/pi"

if out=$(fm_backend_paseo_provider_for_harness grok 2>&1); then
  fail "provider_for_harness grok should refuse"
fi
assert_contains "$out" "grok is not a Paseo provider" "grok refusal message"
pass "paseo refuses harness grok"

if fm_backend_paseo_provider_for_harness bogus >/dev/null 2>&1; then
  fail "provider_for_harness bogus should refuse"
fi
pass "paseo refuses an unknown harness"

# --- version gate -----------------------------------------------------------
fm_backend_paseo_version_ge 0.1.104 0.1.104 || fail "0.1.104 >= 0.1.104 should hold"
fm_backend_paseo_version_ge 0.2.0 0.1.104 || fail "0.2.0 >= 0.1.104 should hold"
if fm_backend_paseo_version_ge 0.1.103 0.1.104; then fail "0.1.103 >= 0.1.104 must be false"; fi
pass "paseo version_ge compares dotted versions"

# --- runtime check ----------------------------------------------------------
fm_backend_paseo_runtime_check || fail "runtime_check should pass with running daemon + verified version"
pass "paseo runtime_check passes on a running, verified daemon"

if FAKE_PASEO_VERSION=0.1.103 fm_backend_paseo_runtime_check 2>/dev/null; then
  fail "runtime_check should refuse an under-floor CLI version"
fi
pass "paseo runtime_check refuses an under-floor version"

if FAKE_PASEO_DAEMON=stopped FAKE_PASEO_CONN=unreachable fm_backend_paseo_runtime_check 2>/dev/null; then
  fail "runtime_check should refuse a stopped daemon"
fi
pass "paseo runtime_check refuses a stopped/unreachable daemon"

# --- run --------------------------------------------------------------------
echo "brief body" > "$TMP_ROOT/brief.md"
aid=$(fm_backend_paseo_run "/wt" "claude" "default" "fm-t" "t" "/tmp/fm-t/gotmp" "$TMP_ROOT/brief.md") \
  || fail "paseo_run should succeed"
[ "$aid" = "agent-xyz-123" ] || fail "paseo_run should echo the agentId, got '$aid'"
run_call=$(grep '^ARGS' "$LOG" | grep -F 'run' | tail -1)
assert_contains "$run_call" "--mode" "run passes --mode"
assert_contains "$run_call" "bypassPermissions" "run passes bypassPermissions"
assert_contains "$run_call" "fm-task=t" "run passes the fm-task label"
assert_contains "$run_call" "GOTMPDIR=/tmp/fm-t/gotmp" "run passes GOTMPDIR via --env"
pass "paseo_run launches with mode/label/env and returns the agent id"

if FAKE_PASEO_RUN_FAIL=1 fm_backend_paseo_run "/wt" "claude" "default" "fm-t" "t" "/tmp/g" "$TMP_ROOT/brief.md" >/dev/null 2>&1; then
  fail "paseo_run should fail when the CLI fails"
fi
pass "paseo_run surfaces a run failure"

# --- run with a model spec --------------------------------------------------
fm_backend_paseo_run "/wt" "claude" "claude-fable-5" "fm-t" "t" "/tmp/g" "$TMP_ROOT/brief.md" >/dev/null
assert_contains "$(last_call)" "claude/claude-fable-5" "run passes provider/model spec"
pass "paseo_run threads a model into the provider spec"

# --- busy state -------------------------------------------------------------
[ "$(FAKE_PASEO_STATUS=running fm_backend_paseo_busy_state agent-1)" = busy ] || fail "running -> busy"
[ "$(FAKE_PASEO_STATUS=idle fm_backend_paseo_busy_state agent-1)" = idle ] || fail "idle -> idle"
[ "$(fm_backend_paseo_busy_state agent-gone-1)" = unknown ] || fail "not-found -> unknown busy state"
pass "paseo busy_state maps running/idle/unknown"

# --- agent liveness ---------------------------------------------------------
[ "$(FAKE_PASEO_STATUS=running fm_backend_paseo_agent_alive agent-1)" = alive ] || fail "running -> alive"
[ "$(FAKE_PASEO_STATUS=idle fm_backend_paseo_agent_alive agent-1)" = alive ] || fail "idle -> alive"
[ "$(fm_backend_paseo_agent_alive agent-gone-1)" = dead ] || fail "not-found -> dead"
pass "paseo agent_alive maps running/idle -> alive and not-found -> dead"

# --- target exists ----------------------------------------------------------
fm_backend_paseo_target_exists agent-1 || fail "present agent should exist"
if fm_backend_paseo_target_exists agent-gone-1; then fail "gone agent should not exist"; fi
pass "paseo target_exists reflects presence"

# --- send / steer -----------------------------------------------------------
verdict=$(fm_backend_paseo_send_text_submit agent-1 "hello there")
[ "$verdict" = empty ] || fail "send_text_submit should report 'empty' (submitted), got '$verdict'"
send_call=$(grep '^ARGS' "$LOG" | grep -F 'send' | tail -1)
assert_contains "$send_call" "--no-wait" "send uses --no-wait"
assert_contains "$send_call" "hello there" "send delivers the text"
pass "paseo send_text_submit delivers atomically and reports empty"

# --- capture ----------------------------------------------------------------
cap=$(fm_backend_paseo_capture agent-1 5)
assert_contains "$cap" "DONE" "capture returns the logs timeline"
assert_contains "$(last_call)" "--tail" "capture uses logs --tail"
pass "paseo capture reads the activity timeline"

# --- keys -------------------------------------------------------------------
fm_backend_paseo_send_key agent-1 C-c || fail "C-c should succeed"
assert_contains "$(last_call)" "stop" "C-c maps to paseo stop"
fm_backend_paseo_send_key agent-1 Enter || fail "Enter should be a no-op success"
if fm_backend_paseo_send_key agent-1 Escape 2>/dev/null; then fail "Escape must be refused"; fi
pass "paseo send_key: C-c -> stop, Enter no-op, Escape refused"

# --- kill -------------------------------------------------------------------
fm_backend_paseo_kill agent-1
assert_contains "$(last_call)" "delete" "kill maps to paseo delete"
pass "paseo kill hard-deletes the agent"

# --- dispatcher wiring (fm-backend.sh) --------------------------------------
# shellcheck source=bin/fm-backend.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_list_contains "$FM_BACKEND_SPAWN" paseo || fail "paseo must be spawn-capable in fm-backend.sh"
[ "$(fm_backend_busy_state paseo agent-1)" = idle ] || fail "dispatcher busy_state should reach paseo"
[ "$(fm_backend_agent_alive paseo agent-gone-1)" = dead ] || fail "dispatcher agent_alive should reach paseo"
pass "fm-backend.sh dispatches paseo ops"
