#!/usr/bin/env bash
# tests/fm-watch-codex-bridge.test.sh - portable behavioral regression for the
# Codex-primary watcher bridge (bin/fm-watch-codex-bridge.sh).
#
# Covers, with real processes and no harness binary:
#   - the canonical doorbell prompt's exact bytes and its operational-input
#     classification (kind watcher, verbatim reason, canonical drain
#     instruction, single-line transport form);
#   - the queue-driven delivery state machine: undelivered detection, the
#     delivered marker, and duplicate suppression ("nothing newer than the
#     last confirmed injection"), including the reset-sequence-counter case;
#   - the Codex primary identity binding (a pid must positively sit inside the
#     pane shell's descendant process tree; name and pane label are never
#     authority);
#   - every arm fail-closed gate that needs no pane: away mode, harness
#     identity, missing/dead/foreign session lock, unresolved target;
#   - the injection decision matrix through stubbed backend primitives:
#     confirmed delivery records the delivery point, duplicate suppression,
#     busy deferral (native and rendered), pending-composer deferral,
#     unconfirmed submit, and identity loss standing the bridge down;
#   - the terminal record format, stop by exact id, reconcile refusal on a
#     live bridge, and run-entry binding validation.
# The Herdr end-to-end (real lab session, real submit path, real tracked
# terminal) lives in tests/fm-watch-codex-bridge-herdr-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-codex-bridge)
BRIDGE="$ROOT/bin/fm-watch-codex-bridge.sh"

# A real process whose command name matches the verified-harness regex, so
# fm_harness_pid_alive and the ancestry walk recognize it as a session-lock
# holder. A copied bash binary reports its own file name as comm.
STANDIN_BIN="$TMP_ROOT/codex"
cp "$(command -v bash)" "$STANDIN_BIN"

start_session_standin() {  # <outfile> [seconds] -> "child_pid session_pid"
  # A codex-named bash that spawns a child sleep and waits, so the session pid
  # positively contains a real descendant for the binding test. It stays
  # running (waiting on its child) until the test kills it; the caller reads
  # both pids from the line printed as soon as the child exists.
  local out_file=$1 secs=${2:-300}
  : > "$out_file"
  "$STANDIN_BIN" -c "sleep $secs >/dev/null 2>&1 & echo \"\$! \$$\"; wait" >"$out_file" 2>/dev/null &
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    { [ -s "$out_file" ]; } && break
    sleep 0.05
  done
  head -n 1 "$out_file"
}

bridge_call() {  # <state> <fn> [args...]  (bridge sourced; extra stubs file via FM_TEST_STUB)
  local state=$1 fn=$2
  shift 2
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      [ -z "${FM_TEST_STUB:-}" ] || . "$FM_TEST_STUB"
      "$2"
    ' _ "$BRIDGE" "$fn" "$@"
}

append_wake() {  # <state> <kind> <key> <payload>
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2" "$3" "$4"
}

queue_top() {  # <state>
  FM_STATE_OVERRIDE="$1" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_bridge_queue_top
  ' _ "$BRIDGE"
}

# ---------------------------------------------------------------- prompt shape

test_prompt_shape() {
  local state out hex body kind
  state="$TMP_ROOT/prompt"
  mkdir -p "$state"
  out=$(FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_bridge_wake_line "stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)"
  ' _ "$BRIDGE")
  hex=$(printf '%s' "$out" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    e281a3*) ;;
    *) fail "the transport line does not start with the U+2063 operational mark (got: ${hex%%FIRSTMATE*})" ;;
  esac
  assert_contains "$out" \
    "FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)" \
    "transport line lost the verbatim wake reason after the watcher-kind header"
  assert_contains "$out" \
    " - Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is bridge-owned." \
    "transport line lost the canonical drain instruction"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "the transport line must be exactly one line"
  pass "the doorbell transport line carries the captain-requested shape on one line"

  out=$(FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_bridge_wake_prompt "stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)"
  ' _ "$BRIDGE")
  body=$(printf '%s' "$out" | FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_operational_input_body "$(cat)" body
    printf "%s" "$body"
  ' _ "$BRIDGE")
  assert_contains "$body" \
    "FIRSTMATE WATCHER WAKE: stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)" \
    "the canonical prompt body lost the verbatim watcher reason"
  assert_contains "$body" "Run bin/fm-wake-drain.sh first and handle the queued wake" \
    "the canonical prompt body lost the drain instruction"
  kind=$(printf '%s' "$out" | FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_operational_input_kind "$(cat)" kind
    printf "%s" "$kind"
  ' _ "$BRIDGE")
  [ "$kind" = watcher ] || fail "the canonical prompt did not classify as the watcher kind (got: $kind)"
  pass "the canonical prompt classifies as the watcher operational kind with a verbatim reason"
}

# ------------------------------------------------------- delivery state machine

assert_pending() {  # <state> <expect-pending: 1=yes 0=no> <msg>
  # fm_bridge_undelivered_pending exits 0 when a row is pending.
  FM_STATE_OVERRIDE="$1" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_bridge_undelivered_pending "$(fm_bridge_delivered_read)"
  ' _ "$BRIDGE"
  local rc=$?
  if [ "$2" = 1 ] && [ "$rc" -ne 0 ]; then
    fail "$3 (expected pending, got suppressed)"
  elif [ "$2" = 0 ] && [ "$rc" -eq 0 ]; then
    fail "$3 (expected suppressed, got pending)"
  fi
}

test_delivery_state() {
  local state top epoch
  state="$TMP_ROOT/delivery"
  mkdir -p "$state"

  assert_pending "$state" 0 "an empty durable queue must never trigger an injection"
  pass "an empty durable queue never triggers an injection"

  append_wake "$state" stale "default:wH:p2" "stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)" \
    || fail "append_wake failed"
  top=$(queue_top "$state") || fail "fm_bridge_queue_top returned nothing for a queued row"
  epoch=${top%%$'\t'*}
  case "$epoch" in ''|*[!0-9]*) fail "queue top epoch is not numeric: $top" ;; esac
  case "${top#*$'\t'}" in ''|*[!0-9]*|0) fail "queue top seq must be a positive integer: $top" ;; esac

  assert_pending "$state" 1 "a queued row with no delivery marker is pending"
  pass "a queued row with no delivery marker is pending"

  printf '%s\n' "$top" > "$state/.watch-codex-bridge-delivered"
  assert_pending "$state" 0 "a delivered marker at the queue top must suppress injection"
  pass "duplicate suppression: a doorbelled queue top never re-fires"

  append_wake "$state" signal "c1.status" "signal:c1.status" || fail "append_wake failed"
  assert_pending "$state" 1 "a newer queued row must be pending after its predecessor was doorbelled"
  pass "a newer queued row re-arms the doorbell"

  # Within the queue's monotonic-sequence lifetime, an equal-epoch marker with
  # a higher sequence legitimately suppresses: rows share the epoch within one
  # second and the ack contract itself assumes a monotonic sequence.
  top=$(queue_top "$state")
  printf '%s\t%s\n' "${top%%$'\t'*}" "$(( ${top##*$'\t'} + 1 ))" > "$state/.watch-codex-bridge-delivered"
  assert_pending "$state" 0 "an equal-epoch marker with a higher sequence suppresses the doorbell"

  # A marker dated beyond the bounded future slack is corrupt, not delivered:
  # it must read as nothing so it can never permanently silence fresh rows.
  printf '9999999999\t1\n' > "$state/.watch-codex-bridge-delivered"
  assert_pending "$state" 1 "a corrupt future-dated marker must not silence fresh rows"
  pass "delivery comparison is epoch-major; a corrupt future marker reads as nothing delivered"

  printf 'garbage\n' > "$state/.watch-codex-bridge-delivered"
  if [ -n "$(FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" bash -c '
    . "$1"; fm_bridge_delivered_read' _ "$BRIDGE")" ]; then
    fail "a malformed delivery marker must read as nothing delivered"
  fi
  pass "a malformed delivery marker reads conservatively as nothing delivered"
}

# ------------------------------------------------------------- identity binding

test_primary_identity_binding() {
  local state pair session_pid child_pid stranger_pid
  state="$TMP_ROOT/identity"
  mkdir -p "$state"

  is_descendant() {  # <root> <needle>
    FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_pid_is_descendant "$2" "$3"
    ' _ "$BRIDGE" "$1" "$2"
  }

  pair=$(start_session_standin "$TMP_ROOT/standin-identity.out" 300)
  child_pid=${pair%% *}
  session_pid=${pair##* }
  stranger_pid=$(bash -c 'sleep 120 >/dev/null 2>&1 & echo $!')

  is_descendant "$session_pid" "$session_pid" || fail "a pid must be its own descendant"
  is_descendant "$session_pid" "$child_pid" || fail "the session pid must positively contain its child tree"
  if is_descendant "$child_pid" "$session_pid"; then
    fail "an ancestor must not be reported as a descendant of its child"
  fi
  if is_descendant "$child_pid" "$stranger_pid"; then
    fail "an unrelated process must never bind to the pane identity"
  fi
  kill "$child_pid" "$session_pid" "$stranger_pid" 2>/dev/null || true
  pass "the Codex primary identity binds by the pane shell's descendant process tree, not by name or label"
}

# ------------------------------------------------------------------ arm gates

test_arm_gates() {
  local state out standin_pid
  state="$TMP_ROOT/arm"
  mkdir -p "$state/state"

  # The suite may itself run inside tmux or herdr; strip both markers so the
  # arm's backend resolution and target gate are deterministic here.
  arm_gate_env() {
    env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH "$@"
  }

  touch "$state/state/.afk"
  # shellcheck disable=SC2016 # the quoted script must not expand in the test shell
  out=$(arm_gate_env env FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_HARNESS=codex bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_arm
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "away mode is active" "arm did not refuse while away mode owns supervision"
  [ ! -e "$state/state/.watch-codex-bridge-terminal" ] || fail "arm wrote a terminal record while refusing on away mode"
  pass "arm refuses when away mode is active and creates nothing"

  rm -f "$state/state/.afk"
  # shellcheck disable=SC2016 # the quoted script must not expand in the test shell
  out=$(arm_gate_env env FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_HARNESS=claude bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_arm
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "arms only a Codex primary" "arm did not refuse a non-Codex harness"
  [ ! -e "$state/state/.watch-codex-bridge-terminal" ] || fail "arm wrote a terminal record for a non-Codex harness"
  pass "arm refuses a non-Codex harness"

  # shellcheck disable=SC2016 # the quoted script must not expand in the test shell
  out=$(arm_gate_env env FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_HARNESS=codex bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_arm
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "no firstmate session lock" "arm did not refuse without a session lock"
  pass "arm refuses without a live session lock (lock-refused read-only mode)"

  printf '%s\n' "999999999" > "$state/state/.lock"
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_HARNESS=codex bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_arm
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "not a live verified harness process" "arm did not refuse a dead session-lock holder"
  pass "arm refuses a dead or foreign session-lock holder"

  # A live harness-named ancestor as the lock holder passes the ownership
  # gate; the unresolvable target must then fail closed without a record.
  # The helper below runs INSIDE a codex-named process, writes its own pid as
  # the lock holder, and runs the arm as its child - the ancestry shape a real
  # Codex primary gives its tool calls.
  cat > "$state/arm-in-session.sh" <<HELPER
#!/usr/bin/env bash
set -u
standin="\$1"; bridge="\$2"; state="\$3"; root="\$4"
printf '%s\n' "\$\$" > "\$state/.lock"
FM_STATE_OVERRIDE="\$state" FM_ROOT_OVERRIDE="\$root" FM_HOME="\$state" \\
  FM_SUPERVISOR_TARGET="firstmate:no-such-window" FM_BRIDGE_HARNESS=codex \\
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \\
    bash "\$bridge" arm > "\$state/arm.out" 2>&1
rc=\$?
# The ownership probe must run through a PLAIN bash child of this harness-named
# session process: a probe spawned from the harness-named binary itself would
# match at self and never climb to the lock holder.
bash -c ". \$root/bin/fm-watch-codex-bridge.sh; fm_session_lock_owned_by_self \$state && echo owned || echo refused" \\
  > "\$state/ownership.probe" 2>&1
sleep 0.1
exit "\$rc"
HELPER
  chmod +x "$state/arm-in-session.sh"
  "$STANDIN_BIN" "$state/arm-in-session.sh" "$STANDIN_BIN" "$BRIDGE" "$state/state" "$ROOT" >/dev/null 2>&1
  grep -q owned "$state/state/ownership.probe" \
    || fail "the session-ownership gate must admit a descendant of the lock holder (probe: $(cat "$state/state/ownership.probe" 2>/dev/null))"
  out=$(cat "$state/state/arm.out" 2>/dev/null)
  assert_contains "$out" "watcher bridge: FAILED" "arm did not fail closed on an unresolvable primary target"
  assert_not_contains "$out" "watcher bridge: started" "arm launched a bridge despite the unresolvable target"
  assert_not_contains "$out" "watcher bridge: attached" "arm attached despite the unresolvable target"
  [ ! -e "$state/state/.watch-codex-bridge-terminal" ] || fail "arm wrote a terminal record while refusing on the target gate"
  pass "arm passes a genuine session descendant and fails closed at the exact-target gate"
}

# ------------------------------------------------- injection decision matrix

# Stub backend layer for the injection matrix. FM_STUB_* fix the verdicts; the
# submit stub records every call so tests assert on the exact submitted bytes.
make_inject_stubs() {  # <stub-file> <busy-state> <composer> <submit-verdict> <capture-tail>
  local file=$1 busy=$2 composer=$3 submit=$4 tail=$5
  cat > "$file" <<STUBS
# Keep the stubbed herdr CLI in place: fm_backend_source would load the real
# herdr adapter over it, and these tests must never touch a real server.
fm_backend_source() { return 0; }
fm_backend_target_exists() { return 0; }
fm_backend_busy_state() { printf '%s\n' '$busy'; }
fm_backend_capture() { printf '%s\n' '$tail'; }
fm_backend_composer_state() { printf '%s\n' '$composer'; }
fm_backend_herdr_cli() {
  case "\${2:-} \${3:-}" in
    "pane get") printf '{"result":{"type":"pane_info","pane":{"pane_id":"wP9","workspace_id":"wsA","tab_id":"tabA"}}}' ;;
    *) printf '{}' ;;
  esac
}
bridge_pane_shell_pid() { printf '%s\n' "\${FM_STUB_SHELL_PID:-1}"; }
fm_backend_send_text_submit() {
  printf '%s\t%s\n' '$submit' "\$3" >> "\${FM_INJECT_LOG:?}"
  printf '%s\n' '$submit'
}
STUBS
}

bridge_inject_run() {  # <state> <stub-file> <session-pid>
  local state=$1 stub=$2 session_pid=$3
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state" \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      . "$2"
      identity=$(fm_pid_identity "$3")
      bridge_inject_attempt herdr "default:wP9" codex "$3" "$identity" "$(printf "wsA\ttabA\twP9")"
      rc=$?
      printf "rc=%s delivered=%s\n" "$rc" "$(cat "$FM_STATE_OVERRIDE/.watch-codex-bridge-delivered" 2>/dev/null || echo none)"
    ' _ "$BRIDGE" "$stub" "$session_pid" 2>"$state/inject.err"
}

test_inject_decision_matrix() {
  local state stub out injected top pair
  state="$TMP_ROOT/inject"
  mkdir -p "$state"

  pair=$(start_session_standin "$TMP_ROOT/standin-inject.out" 300)
  local session_pid=${pair##* }
  # The session lock the identity revalidation reads.
  printf '%s\n' "$session_pid" > "$state/.lock"

  # 1) Confirmed delivery: the exact canonical line reaches the submit core
  #    and the delivered marker records the queue top.
  append_wake "$state" stale "default:wP9" "stale: default:wP9 (idle 61s)" || fail "append_wake failed"
  local top
  top=$(queue_top "$state")
  stub="$state/stubs-deliver"
  : > "$state/inject.log"
  make_inject_stubs "$stub" idle empty empty "composer idle"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in
    "rc=0 delivered=$top") ;;
    *) fail "confirmed submit must record the delivery marker at the queue top (got: $out; err: $(cat "$state/inject.err"))" ;;
  esac
  injected=$(cut -f2 "$state/inject.log")
  assert_contains "$injected" "FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: default:wP9 (idle 61s)" \
    "the submitted line lost the canonical wake envelope"
  assert_contains "$injected" "Run bin/fm-wake-drain.sh first and handle the queued wake" \
    "the submitted line lost the canonical drain instruction"
  [ "$(printf '%s\n' "$injected" | wc -l)" -eq 1 ] || fail "the injected prompt must be one line"
  pass "a confirmed submit delivers the exact canonical prompt and records the delivery point"

  # 2) Duplicate suppression: nothing newer queued -> no submit.
  : > "$state/inject.log"
  stub="$state/stubs-idle"
  make_inject_stubs "$stub" idle empty empty "idle footer"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in rc=4\ delivered="$top") ;;
    *) fail "an already-doorbelled queue must be skipped, not resubmitted (got: $out)" ;;
  esac
  [ ! -s "$state/inject.log" ] || fail "an already-doorbelled queue must not reach the submit path"
  pass "an already-doorbelled queue never reaches the submit path (duplicate suppression)"

  # 3) Busy pane (native busy verdict) -> defer, nothing typed.
  append_wake "$state" check "merge-poll" "check: merged" || fail "append_wake failed"
  stub="$state/stubs-busy"
  make_inject_stubs "$stub" busy empty empty ""
  : > "$state/inject.log"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in rc=2\ delivered="$top") ;;
    *) fail "a busy pane must defer without delivering (got: $out)" ;;
  esac
  [ ! -s "$state/inject.log" ] || fail "a busy pane must never be typed into"
  pass "a busy primary pane defers without typing"

  # 4) Rendered busy footer for a backend without native state.
  stub="$state/stubs-rendered"
  make_inject_stubs "$stub" unknown empty empty "Working... esc to interrupt"
  : > "$state/inject.log"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in rc=2\ delivered="$top") ;;
    *) fail "a rendered-busy footer must defer (got: $out)" ;;
  esac
  [ ! -s "$state/inject.log" ] || fail "a rendered-busy pane must never be typed into"
  pass "a rendered codex busy footer defers the injection"

  # 5) Pending composer (captain input) -> defer, nothing typed.
  stub="$state/stubs-pending"
  make_inject_stubs "$stub" idle pending empty ""
  : > "$state/inject.log"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in rc=3\ delivered="$top") ;;
    *) fail "a pending composer must defer (got: $out)" ;;
  esac
  [ ! -s "$state/inject.log" ] || fail "a non-empty composer must never be typed into"
  pass "a pending composer defers so captain input is never overwritten"

  # 6) Unconfirmed submit -> nothing recorded, retry later.
  rm -f "$state/.watch-codex-bridge-delivered"
  stub="$state/stubs-unconfirmed"
  make_inject_stubs "$stub" idle empty pending ""
  : > "$state/inject.log"
  out=$(FM_STUB_SHELL_PID="$session_pid" FM_INJECT_LOG="$state/inject.log" bridge_inject_run "$state" "$stub" "$session_pid")
  case "$out" in rc=1\ delivered=none) ;;
    *) fail "an unconfirmed submit must not record delivery (got: $out)" ;;
  esac
  pass "an unconfirmed submit records nothing and stays retryable"

  # 7) Identity loss stands the bridge down without injecting.
  local stranger_pid
  stranger_pid=$(bash -c 'sleep 120 >/dev/null 2>&1 & echo $!')
  stub="$state/stubs-standdown"
  make_inject_stubs "$stub" idle empty empty ""
  : > "$state/inject.log"
  FM_STUB_SHELL_PID="$stranger_pid" FM_INJECT_LOG="$state/inject.log" \
    bridge_inject_run "$state" "$stub" "$stranger_pid" >/dev/null 2>&1
  kill "$stranger_pid" 2>/dev/null || true
  [ ! -s "$state/inject.log" ] || fail "a replaced session must never receive an injection"
  grep -q "standing down: the recorded session lock no longer names the recorded live session" "$state/.watch-codex-bridge.log" \
    || fail "a replaced session must stand the bridge down (log: $(cat "$state/.watch-codex-bridge.log" 2>/dev/null))"
  pass "a replaced session stands the bridge down before any injection"
  kill "$session_pid" 2>/dev/null || true
  rm -f "$state/.watch-codex-bridge.log"
}

# ------------------------------------------------------- record, stop, reconcile

test_record_stop_reconcile() {
  local state out rc standin_pid
  state="$TMP_ROOT/record"
  mkdir -p "$state/state" "$state/fakebin"
  cat > "$state/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) printf "can't find session: %s\n" "${2:-}" >&2; exit 1 ;;
  kill-session) printf '%s\n' "killed ${3:-}" >> "${FM_FAKE_TMUX_LOG:?}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$state/fakebin/tmux"

  printf 'tmux\n' > "$state/state/.watch-codex-bridge-terminal"
  FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    bridge_record_read
  ' _ "$BRIDGE" 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ] || fail "a one-field record must be refused (rc=$rc)"
  printf 'bogus\ttarget\tx\n' > "$state/state/.watch-codex-bridge-terminal"
  FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    bridge_record_read
  ' _ "$BRIDGE" 2>/dev/null
  [ "$?" -eq 2 ] || fail "an unknown backend record must be refused"
  printf 'tmux\tfm-codex-bridge-x\t\n' > "$state/state/.watch-codex-bridge-terminal"
  FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    bridge_record_read || exit 1
    [ "$FM_BRIDGE_REC_BACKEND" = tmux ] && [ "$FM_BRIDGE_REC_TARGET" = fm-codex-bridge-x ] || exit 1
    exit 0
  ' _ "$BRIDGE" || fail "a well-formed tmux record must read back"
  pass "the terminal record format is validated before any close action"

  # stop signals the lock pid and closes only the recorded exact terminal.
  : > "$state/state/tmux.log"
  pair=$(start_session_standin "$TMP_ROOT/standin-stop.out" 300)
  standin_pid=${pair##* }
  mkdir "$state/state/.watch-codex-bridge.lock" 2>/dev/null
  printf '%s\n' "$standin_pid" > "$state/state/.watch-codex-bridge.lock/pid"
  fm_pid_identity "$standin_pid" > "$state/state/.watch-codex-bridge.lock/pid-identity" 2>/dev/null
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    PATH="$state/fakebin:$PATH" FM_FAKE_TMUX_LOG="$state/state/tmux.log" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_stop
    ' _ "$BRIDGE" 2>&1)
  rc=$?
  kill "$standin_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "stop of a recorded bridge failed (rc=$rc): $out"
  assert_contains "$(cat "$state/state/tmux.log")" "killed fm-codex-bridge-x" "stop did not target the recorded exact id"
  [ ! -e "$state/state/.watch-codex-bridge-terminal" ] || fail "stop did not drop the terminal record"
  pass "stop signals the lock pid and closes only the recorded exact terminal"

  # reconcile closes a recorded dead terminal and drops the record...
  printf 'tmux\tfm-codex-bridge-leak\t\n' > "$state/state/.watch-codex-bridge-terminal"
  if ! out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    PATH="$state/fakebin:$PATH" FM_FAKE_TMUX_LOG="$state/state/tmux.log" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_reconcile_cmd
    ' _ "$BRIDGE" 2>&1); then
    fail "reconcile of a recorded dead terminal failed: $out"
  fi
  [ ! -e "$state/state/.watch-codex-bridge-terminal" ] || fail "reconcile did not drop the dead terminal record"
  # ...and stands down while a live bridge owns the lock.
  printf 'tmux\tfm-codex-bridge-live\t\n' > "$state/state/.watch-codex-bridge-terminal"
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    mkdir -p "$FM_STATE_OVERRIDE/.watch-codex-bridge.lock"
    printf "%s\n" "${BASHPID:-$$}" > "$FM_STATE_OVERRIDE/.watch-codex-bridge.lock/pid"
    fm_pid_identity "${BASHPID:-$$}" > "$FM_STATE_OVERRIDE/.watch-codex-bridge.lock/pid-identity"
    bridge_reconcile_cmd
  ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "a live bridge holds the lock" "reconcile must stand down while a live bridge owns the lock"
  [ -e "$state/state/.watch-codex-bridge-terminal" ] || fail "reconcile removed the record while a live bridge owned the lock"
  pass "reconcile closes only a dead recorded terminal and refuses a live bridge"
}

# ------------------------------------------------------------- run-entry binding

test_run_binding_validation() {
  local state out rc standin_pid pair
  state="$TMP_ROOT/run-binding"
  mkdir -p "$state/state"
  pair=$(start_session_standin "$TMP_ROOT/standin-run.out" 300)
  standin_pid=${pair##* }

  bridge_identity_of() {  # <pid> - fm_pid_identity needs the bridge's sourced libraries
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      fm_pid_identity "$2"
    ' _ "$BRIDGE" "$1"
  }

  write_binding() {  # <state> <pid> <generation> [backend] [harness] [home]
    mkdir -p "$1"
    local home=$state/state
    if [ "${5:-herdr}" = herdr ]; then
      printf '%s\t%s\tdefault:wP1\t%s\t%s\t%s\twsA\ttabA\twP9\t%s\n' \
        "$2" "$(bridge_identity_of "$2")" "${5:-herdr}" "${6:-codex}" "$3" "$home" \
        > "$1/.watch-codex-bridge-binding"
    else
      printf '%s\t%s\tdefault:wP1\t%s\t%s\t%s\t%%5\t%s\n' \
        "$2" "$(bridge_identity_of "$2")" "${5:-herdr}" "${6:-codex}" "$3" "$home" \
        > "$1/.watch-codex-bridge-binding"
    fi
  }

  # A binding written for a non-Codex harness must never start a daemon.
  write_binding "$state/state" "$standin_pid" g1 herdr claude
  FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_BINDING="$state/state/.watch-codex-bridge-binding" FM_BRIDGE_HARNESS=codex \
    FM_BRIDGE_SKIP_PANE_VALIDATION=1 \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_run_entry >/dev/null 2>&1
    ' _ "$BRIDGE"
  rc=$?
  [ "$rc" -eq 1 ] || fail "run entry must refuse a non-codex binding (rc=$rc)"

  # A malformed generation token inside an otherwise well-formed binding.
  write_binding "$state/state" "$standin_pid" "bad token"
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_BINDING="$state/state/.watch-codex-bridge-binding" FM_BRIDGE_HARNESS=codex \
    FM_BRIDGE_SKIP_PANE_VALIDATION=1 \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_run_entry
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "invalid bridge generation" "run binding validation must reject a malformed generation"

  # A cross-home binding must be refused: another home's arm can never start
  # this home's daemon.
  write_binding "$state/state" "$standin_pid" g1
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/other-home" \
    FM_BRIDGE_BINDING="$state/state/.watch-codex-bridge-binding" FM_BRIDGE_HARNESS=codex \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_run_entry
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "missing or malformed" "a foreign-home binding must be refused"

  # A binding whose session pid is dead must be refused even with a real
  # identity string, and an identity-matched live session must be accepted.
  write_binding "$state/state" "$standin_pid" g1
  FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_BINDING="$state/state/.watch-codex-bridge-binding" FM_BRIDGE_HARNESS=codex \
    FM_BRIDGE_SKIP_PANE_VALIDATION=1 \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_validate_binding herdr default:wP1 "$2" "$(fm_pid_identity "$2")" g1 "wsA\ttabA\twP9" || exit 1
      exit 0
    ' _ "$BRIDGE" "$standin_pid" || fail "binding validation refused an identity-matched live session"

  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_SKIP_PANE_VALIDATION=1 bash -c '
      # shellcheck source=/dev/null
      . "$1"
      # A real identity string bound to a pid that no longer exists must be
      # refused as not-the-recorded-live-harness, not merely as malformed.
      bridge_validate_binding herdr default:wP1 "$2" "$3" g1
    ' _ "$BRIDGE" "999999999" "$(bridge_identity_of "$standin_pid")" 2>&1)
  assert_contains "$out" "not the recorded live harness identity" "binding validation must refuse a dead session pid"

  # A missing or malformed binding file is a refusal, never a start.
  rm -f "$state/state/.watch-codex-bridge-binding"
  out=$(FM_STATE_OVERRIDE="$state/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$state/state" \
    FM_BRIDGE_BINDING="$state/state/.watch-codex-bridge-binding" FM_BRIDGE_HARNESS=codex \
    bash -c '
      # shellcheck source=/dev/null
      . "$1"
      bridge_run_entry
    ' _ "$BRIDGE" 2>&1)
  assert_contains "$out" "missing or malformed" "a missing binding must be refused"
  kill "$standin_pid" 2>/dev/null || true
  pass "run-entry binding validation is binding-file-, harness-, generation-, and identity-strict"
}

# ------------------------------------------------------------------ dispatch

test_prompt_shape
test_delivery_state
test_primary_identity_binding
test_arm_gates
test_inject_decision_matrix
test_record_stop_reconcile
test_run_binding_validation

pass "fm-watch-codex-bridge portable regression complete"
