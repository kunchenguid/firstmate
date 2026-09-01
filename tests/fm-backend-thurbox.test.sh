#!/usr/bin/env bash
# tests/fm-backend-thurbox.test.sh - fake-thurbox-CLI unit tests for the
# thurbox session-provider adapter (bin/backends/thurbox.sh), verified against
# the real thurbox-cli 2.11.0 (docs/thurbox-backend.md). Mirrors
# tests/fm-backend-cmux.test.sh's fakebin/command-log convention: a small,
# LOG-based, canned-response fake `thurbox-cli` plus a REAL `jq` (jq is a real
# required tool for this backend, not faked).
#
# The cases below are grouped by the property they protect, and several exist
# because the real CLI's contracts are easy to get wrong in ways that fail
# SILENTLY rather than loudly - notably the stdout-error contract, whose whole
# danger is that a broken adapter looks like a working one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the thurbox adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-thurbox-tests)

# make_thurbox_fakebin: a `thurbox-cli` stub that logs every invocation (one
# line, unit-separated args, to $FM_THURBOX_LOG) and returns the canned
# response for that call from $FM_THURBOX_RESPONSES/<n>.out, consumed IN ORDER.
# A missing response file means "succeed with empty stdout". `version` is
# special-cased (not call-counted, not consuming the ordered queue) because the
# version gate runs at points a test may not want to hand-count.
make_thurbox_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/thurbox-cli" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_THURBOX_LOG:?}"
RESP="${FM_THURBOX_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  for a in "$@"; do printf '%s\x1f' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = version ]; then
  printf '{"version":"%s","tmux_socket":"%s","schema_version":41}\n' \
    "${FM_THURBOX_FAKE_VERSION:-2.11.0}" "${FM_THURBOX_FAKE_SOCKET:-thurbox}"
  exit 0
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
if [ -f "$RESP/$next.out" ]; then cat "$RESP/$next.out"; fi
if [ -f "$RESP/$next.exit" ]; then exit "$(cat "$RESP/$next.exit")"; fi
exit 0
SH
  chmod +x "$fb/thurbox-cli"
  printf '%s\n' "$fb"
}

# new_case: a fresh fixture dir with its own log, response queue and fake CLI.
# Sets CASE_DIR and the two env vars the fake reads. Called DIRECTLY, never in a
# command substitution: the exports have to land in this shell, not a subshell.
# BASE_PATH is captured once so each case gets its own fake on a clean PATH
# rather than stacking fakebin dirs.
BASE_PATH=$PATH

new_case() {  # <name>
  local name dir fb
  name=$1
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses"
  fb=$(make_thurbox_fakebin "$dir")
  CASE_DIR=$dir
  export FM_THURBOX_LOG="$dir/log"
  export FM_THURBOX_RESPONSES="$dir/responses"
  : > "$FM_THURBOX_LOG"
  export PATH="$fb:$BASE_PATH"
}

respond() {  # <case-dir> <n> <json>
  printf '%s' "$3" > "$1/responses/$2.out"
}

respond_exit() {  # <case-dir> <n> <code> [stdout]
  printf '%s' "${4:-}" > "$1/responses/$2.out"
  printf '%s' "$3" > "$1/responses/$2.exit"
}

# assert_log_args <case-dir> <msg> <arg>...: the fake logs each invocation as
# its arguments each followed by a unit separator, so an ADJACENT argument
# sequence ("--lines" immediately followed by "500") is checked as one fixed
# string rather than as two independent matches that could come from different
# calls.
assert_log_args() {  # <msg> <arg>...
  local msg=$1 needle='' a
  shift
  for a in "$@"; do needle="$needle$a"$'\x1f'; done
  grep -F -- "$needle" "$FM_THURBOX_LOG" >/dev/null || fail "$msg"
}

# A REAL 2.11.0 session row. Deliberately carries no `stopped` field, because
# neither `session get` nor `session list` emits one - the parked flag is
# reachable only through `watch`. A fixture that invented it would let the
# adapter's parked handling pass against a field that does not exist.
SESSION_ROW='{"id":"11111111-2222-3333-4444-555555555555","name":"fm-firstmate-abcd1234-t1","state":"working","state_source":"hook","hook_state_contradicted":false,"cwd":"/tmp/wt"}'
TARGET='thurbox:11111111-2222-3333-4444-555555555555'

# adapter: run <body> in a subshell with the adapter sourced fresh. Every <body>
# below is single-quoted on purpose - it is eval'd inside that subshell, so its
# $-expressions must reach it unexpanded.
adapter() {  # <case-dir> <body>
  # The subshell-local environment is the point: each case gets a fresh
  # adapter with its own FM_HOME, and nothing leaks back to the caller.
  # shellcheck disable=SC2030,SC2031
  ( set +e
    FM_ROOT_OVERRIDE="$ROOT"
    export FM_ROOT_OVERRIDE
    FM_BACKEND_LIB_DIR="$ROOT/bin"
    FM_HOME="$1"
    # shellcheck source=bin/fm-transition-lib.sh
    . "$ROOT/bin/fm-transition-lib.sh"
    # shellcheck source=bin/fm-composer-lib.sh
    . "$ROOT/bin/fm-composer-lib.sh"
    # shellcheck source=bin/backends/tmux.sh
    . "$ROOT/bin/backends/tmux.sh"
    # shellcheck source=bin/backends/thurbox.sh
    . "$ROOT/bin/backends/thurbox.sh"
    eval "$2"
  )
}

# --- version floor -----------------------------------------------------------

new_case version-floor; d=$CASE_DIR
out=$(adapter "$d" '
  fm_backend_thurbox_version_at_least 2.11.0 2.11.0 && echo eq
  fm_backend_thurbox_version_at_least 2.11.1 2.11.0 && echo patch-up
  fm_backend_thurbox_version_at_least 2.12.0 2.11.0 && echo minor-up
  fm_backend_thurbox_version_at_least 3.0.0 2.11.0 && echo major-up
  fm_backend_thurbox_version_at_least 2.10.9 2.11.0 || echo below-minor
  fm_backend_thurbox_version_at_least 1.99.99 2.11.0 || echo below-major
')
for want in eq patch-up minor-up major-up below-minor below-major; do
  case "$out" in *"$want"*) ;; *) fail "version floor: missing $want (got: $out)" ;; esac
done
pass "version comparison holds at the floor boundary in both directions"

new_case version-refusal; d=$CASE_DIR
out=$(FM_BACKEND_THURBOX_VERSION_OVERRIDE=2.10.0 adapter "$d" 'fm_backend_thurbox_version_check 2>&1; echo "rc=$?"')
assert_contains "$out" 'rc=1' "a below-floor thurbox-cli must be refused"
assert_contains "$out" '2.11.0 floor' "the refusal must name the floor it needs"
pass "a thurbox-cli below the version floor is refused loudly, naming the floor"

# --- the stdout-error contract -----------------------------------------------
#
# This is the sharpest trap in the whole CLI: thurbox-cli prints failures as a
# JSON object on STDOUT with an empty stderr and a non-zero exit. An adapter
# that pipes straight into jq gets exit 0 and empty output from a FAILED call.
# Both halves are pinned: the exit status AND the error-shaped payload.

new_case stdout-error-exit; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"Session not found: x","suggestion":"..."}'
out=$(adapter "$d" 'fm_backend_thurbox_json session get x; echo "rc=$?"')
assert_contains "$out" 'rc=1' "a non-zero thurbox-cli exit must fail the read"
assert_not_contains "$out" 'Session not found' "a failed read must not return the error payload as data"
pass "a failed thurbox-cli call fails the read instead of returning its stdout error as data"

new_case stdout-error-zero-exit; d=$CASE_DIR
respond "$d" 1 '{"error":"Session not found: x","suggestion":"..."}'
out=$(adapter "$d" 'fm_backend_thurbox_json session get x; echo "rc=$?"')
assert_contains "$out" 'rc=1' "an error-shaped payload must fail the read even on a zero exit"
pass "an error-shaped payload is refused even when thurbox-cli exits zero"

new_case capture-propagates-failure; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"sh: thurbox-cli: Too many levels of symbolic links"}'
out=$(adapter "$d" "fm_backend_thurbox_capture '$TARGET' 50; echo \"rc=\$?\"")
assert_contains "$out" 'rc=1' "a failed capture must return 1, not an empty success"
pass "a failed pane read propagates failure rather than reporting an empty capture"

# --- capture shape -----------------------------------------------------------

new_case capture-no-trim; d=$CASE_DIR
# --lines 3 against a 5-row screen: the real CLI prepends scrollback to the
# WHOLE visible screen, so the response is returned whole. A `tail -n 3` here
# would silently drop the top of the screen and every scrollback row.
respond "$d" 1 '{"output":"s1\ns2\nrow1\nrow2\nrow3","cursor_row":4,"lines":3}'
out=$(adapter "$d" "fm_backend_thurbox_capture '$TARGET' 3")
[ "$(printf '%s' "$out" | wc -l)" -eq 4 ] || fail "capture must not trim locally (got: $out)"
assert_contains "$out" 's1' "the requested scrollback rows must survive"
assert_contains "$out" 'row3' "the bottom of the screen must survive"
pass "capture returns thurbox's response whole, never trimming away scrollback or screen top"

new_case capture-passes-lines; d=$CASE_DIR
respond "$d" 1 '{"output":"x"}'
adapter "$d" "fm_backend_thurbox_capture '$TARGET' 500" >/dev/null
assert_log_args "the caller's bound must be passed to thurbox, not applied locally" --lines 500
pass "the requested line bound is enforced through thurbox rather than after the read"

new_case capture-clamps-max; d=$CASE_DIR
respond "$d" 1 '{"output":"x"}'
adapter "$d" "fm_backend_thurbox_capture '$TARGET' 99999" >/dev/null
assert_log_args "an over-max bound must be clamped to thurbox's documented 10000" --lines 10000
pass "a line bound above thurbox's maximum is clamped rather than rejected by the CLI"

# --- target shape ------------------------------------------------------------

new_case target-shape; d=$CASE_DIR
# shellcheck disable=SC2016  # the body is eval'd in adapter's subshell
out=$(adapter "$d" '
  fm_backend_thurbox_parse_target "thurbox:abc-123" && echo "ok=$FM_BACKEND_THURBOX_SESSION"
  fm_backend_thurbox_parse_target "abc-123" || echo bare-refused
  fm_backend_thurbox_parse_target "tmux:abc" || echo foreign-refused
  fm_backend_thurbox_parse_target "thurbox:a:b" || echo extra-colon-refused
  fm_backend_thurbox_parse_target "thurbox:" || echo empty-refused
')
assert_contains "$out" 'ok=abc-123' "a well-formed target must yield its session uuid"
for want in bare-refused foreign-refused extra-colon-refused empty-refused; do
  assert_contains "$out" "$want" "target parsing must refuse: $want"
done
pass "only a well-formed thurbox:<uuid> target parses; a bare uuid is refused"

# --- native busy state, and its hook-coverage gate ---------------------------

new_case busy-hook-working; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
out=$(adapter "$d" "fm_backend_thurbox_busy_state '$TARGET'")
[ "$out" = busy ] || fail "a live hook-reported working state must read busy (got: $out)"
pass "a hook-reported working state is trusted as busy"

new_case busy-non-hook-source; d=$CASE_DIR
respond "$d" 1 '{"id":"11111111-2222-3333-4444-555555555555","state":"idle","state_source":"name"}'
out=$(adapter "$d" "fm_backend_thurbox_busy_state '$TARGET'")
[ "$out" = unknown ] || fail "a non-hook state source must not be trusted (got: $out)"
pass "a state thurbox did not get from an agent hook reads unknown, never a stale idle"

new_case busy-contradicted; d=$CASE_DIR
respond "$d" 1 '{"id":"11111111-2222-3333-4444-555555555555","state":"idle","state_source":"hook","hook_state_contradicted":true}'
out=$(adapter "$d" "fm_backend_thurbox_busy_state '$TARGET'")
[ "$out" = unknown ] || fail "a contradicted hook state must not be trusted (got: $out)"
pass "a hook state thurbox itself marks contradicted reads unknown"

new_case busy-read-failure; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"nope"}'
out=$(adapter "$d" "fm_backend_thurbox_busy_state '$TARGET'")
[ "$out" = unknown ] || fail "a failed row read must read unknown (got: $out)"
pass "a failed session read reports unknown rather than guessing a busy verdict"

# --- recovery-grade agent state ----------------------------------------------
#
# Only `dead` and `missing` license recovery, so the distinction between a
# successful inventory that omits the session and a FAILED inventory read is
# load-bearing: confusing them would let a CLI error authorize tearing down a
# live agent.

new_case agent-missing; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session"}]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = missing ] || fail "a successful inventory omitting the session must read missing (got: $out)"
pass "a successful inventory that omits the session reports missing"

new_case agent-inventory-failure; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"database is locked"}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = unreadable ] || fail "a failed inventory must read unreadable, never missing (got: $out)"
pass "a failed inventory read reports unreadable, so a CLI error can never license recovery"

new_case agent-alive; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555"}]'
respond "$d" 2 '{"at":1,"event":"present","session":"11111111-2222-3333-4444-555555555555","state":"working","stopped":false}'
respond "$d" 3 '{"foreground_process":"claude","foreground_command":"claude --resume x","output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = alive ] || fail "an agent foreground process must read alive (got: $out)"
pass "a live agent in the pane's foreground reports alive"

new_case agent-dead-shell; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555"}]'
respond "$d" 2 '{"at":1,"event":"present","session":"11111111-2222-3333-4444-555555555555","state":null,"stopped":false}'
respond "$d" 3 '{"foreground_process":"bash","foreground_command":"/bin/bash -i","output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = dead ] || fail "a bare shell foreground must read dead (got: $out)"
pass "a pane that fell back to its shell reports dead"

new_case agent-ambiguous; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555"}]'
respond "$d" 2 '{"at":1,"event":"present","session":"11111111-2222-3333-4444-555555555555","state":null,"stopped":false}'
respond "$d" 3 '{"foreground_process":null,"foreground_command":null,"output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = ambiguous ] || fail "an unattributable foreground must read ambiguous (got: $out)"
pass "a pane whose foreground process cannot be attributed reports ambiguous, not dead"

new_case agent-parked; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555"}]'
respond "$d" 2 '{"at":1,"event":"present","session":"11111111-2222-3333-4444-555555555555","state":null,"stopped":true}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = dead ] || fail "a parked session must read dead, not missing (got: $out)"
pass "a parked session reports dead, keeping its row and checkout out of missing-endpoint recovery"

# thurbox 2.11.0 reports a parked session through `session get` IDENTICALLY to a
# running one, so this case gives the adapter exactly what the real CLI gives it:
# a perfectly ordinary row, followed by the capture failure that is the only
# observable difference. An adapter that trusts the row calls this ready.
new_case target-ready-parked; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
respond_exit "$d" 2 1 '{"error":"capture_pane_text: ... can'"'"'t find window: tb-fm-x"}'
out=$(adapter "$d" "fm_backend_thurbox_target_ready '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a parked session has no pane and must not be ready"
pass "a parked session is not ready, even though its session row is indistinguishable from a running one"

new_case target-ready-running; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
respond "$d" 2 '{"output":"","cursor_row":0}'
out=$(adapter "$d" "fm_backend_thurbox_target_ready '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "a session with a readable pane must be ready"
pass "a session whose pane reads is ready"

# --- the readiness gate leaves the caller able to address the session --------
#
# Regression for a defect the fake-response cases could not see and a real
# spawn found immediately: the readiness check used to parse the target inside
# a command substitution, so the parsed session id died with that subshell and
# the very next write in the caller addressed an unset session. The property is
# that every write lands on the session the target names, so the assertion is
# on the ARGUMENTS thurbox actually received, not on an internal.

new_case ready-then-write; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
respond "$d" 2 '{"output":"","cursor_row":0}'
adapter "$d" "fm_backend_thurbox_send_literal '$TARGET' hello" >/dev/null 2>&1
assert_log_args "a write gated on the readiness check must address the session the target names" \
  session send 11111111-2222-3333-4444-555555555555 hello
pass "a write gated on the readiness check still addresses the target's own session"

new_case ready-then-key; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
respond "$d" 2 '{"output":"","cursor_row":0}'
adapter "$d" "fm_backend_thurbox_send_key '$TARGET' Enter" >/dev/null 2>&1
assert_log_args "a key gated on the readiness check must address the session the target names" \
  session key 11111111-2222-3333-4444-555555555555 enter
pass "a key gated on the readiness check still addresses the target's own session"

# --- teardown ----------------------------------------------------------------

new_case kill-forces; d=$CASE_DIR
adapter "$d" "fm_backend_thurbox_kill '$TARGET'" >/dev/null 2>&1
assert_log_args "kill must issue a delete" session delete
assert_log_args "kill must force, or the pane outlives the teardown" --force
pass "teardown forces the delete, so the pane never outlives the task headlessly"

new_case gone-needs-proof; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"unavailable"}'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a failed inventory is not proof of absence"
pass "endpoint absence needs a successful inventory, never a failed read"

# --- home scoping ------------------------------------------------------------

new_case scoped-name; d=$CASE_DIR
out=$(adapter "$d" 'fm_backend_thurbox_scoped_name fm-task1')
case "$out" in
  fm-firstmate-*-task1) ;;
  *) fail "a task label must be home-scoped (got: $out)" ;;
esac
pass "a task label is scoped by firstmate home, so two homes cannot collide on one name"

new_case scoped-name-too-long; d=$CASE_DIR
long=$(printf 'a%.0s' $(seq 1 70))
out=$(adapter "$d" "fm_backend_thurbox_scoped_name fm-$long 2>&1; echo rc=\$?")
assert_contains "$out" 'rc=1' "an over-long scoped name must be refused"
assert_contains "$out" '64' "the refusal must name thurbox's limit"
pass "a task label that would exceed thurbox's 64-character name limit is refused, never truncated"

new_case scoped-name-slash; d=$CASE_DIR
out=$(adapter "$d" 'fm_backend_thurbox_scoped_name "fm-a/b" 2>&1; echo rc=$?')
assert_contains "$out" 'rc=1' "thurbox rejects slashes in a session name"
pass "a session name thurbox would reject is refused before the create call"

# --- bare-selector resolution ------------------------------------------------

new_case bare-selector-ambiguous; d=$CASE_DIR
respond "$d" 1 '[{"id":"a","name":"other"},{"id":"b","name":"other"}]'
out=$(adapter "$d" 'fm_backend_thurbox_resolve_bare_selector other 2>&1; echo rc=$?')
assert_contains "$out" 'rc=1' "an ambiguous name must be refused, not guessed"
assert_contains "$out" 'uuid' "the refusal must point at the unambiguous address"
pass "a name matching several live sessions is refused rather than resolved by guessing"

new_case bare-selector-unique; d=$CASE_DIR
respond "$d" 1 '[{"id":"only-one","name":"solo"},{"id":"x","name":"other"}]'
out=$(adapter "$d" 'fm_backend_thurbox_resolve_bare_selector solo')
[ "$out" = 'thurbox:only-one' ] || fail "a unique name must resolve to its target (got: $out)"
pass "a name matching exactly one live session resolves to its thurbox target"

# --- key vocabulary ----------------------------------------------------------

new_case keys; d=$CASE_DIR
# shellcheck disable=SC2016  # the body is eval'd in adapter's subshell
out=$(adapter "$d" '
  for k in Enter enter Escape esc C-c ctrl-c C-u Ctrl+U; do
    printf "%s " "$(fm_backend_thurbox_normalize_key "$k")"
  done
')
[ "$out" = 'enter enter escape escape ctrl-c ctrl-c ctrl-u ctrl-u ' ] \
  || fail "key normalization drifted (got: $out)"
pass "firstmate's key vocabulary maps onto thurbox's canonical key names"

# --- native event push -------------------------------------------------------

make_event_reader() {  # <dir> <ndjson-file>
  local dir=$1 src=$2
  cat > "$dir/reader" <<SH
#!/usr/bin/env bash
cat "$src"
SH
  chmod +x "$dir/reader"
  printf '%s\n' "$dir/reader"
}

new_case events-actionable; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
{"event":"changed","session":"other-session","state":"blocked","name":"x"}
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"blocked","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=0' "a fresh blocked edge must be reported as actionable"
assert_contains "$out" '11111111-2222-3333-4444-555555555555' "the record must name the session that blocked"
assert_not_contains "$out" 'other-session' "an unwatched session's edge must not be reported"
pass "a blocked edge on a watched session is reported, and another session's edge is ignored"

new_case events-absorb-only; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"idle","name":"t"}
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"done","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=1' "a stream with no blocked edge must be a clean timeout, not an escalation"
pass "working, idle and done edges never escalate; the wait reports a clean timeout"

new_case events-dedupe; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"blocked","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "
    rec=\$(fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET') && echo first-reported
    fm_backend_thurbox_commit_transition '$d/state' \"\$rec\"
    fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET' >/dev/null || echo second-suppressed
    fm_backend_thurbox_clear_transition '$d/state' '$TARGET'
    fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET' >/dev/null && echo reported-again
  ")
assert_contains "$out" 'first-reported' "the first blocked edge must be reported"
assert_contains "$out" 'second-suppressed' "an already-committed blocked edge must not re-escalate"
assert_contains "$out" 'reported-again' "clearing the marker must re-arm escalation"
pass "a committed blocked edge is not re-escalated until the marker is cleared"

new_case events-absorb-clears; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "
    rec=\$(fm_backend_thurbox_normalize_event '11111111-2222-3333-4444-555555555555' blocked '')
    fm_backend_thurbox_commit_transition '$d/state' \"\$rec\"
    fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET' >/dev/null
    marker=\$(fm_backend_thurbox_escalation_marker '$d/state' '$TARGET')
    [ -e \"\$marker\" ] && echo marker-still-there || echo marker-cleared
  ")
assert_contains "$out" 'marker-cleared' "a working edge must clear the escalation marker"
pass "a return to working clears the escalation marker, re-arming the next blocked edge"

new_case events-incapable; d=$CASE_DIR
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=0 \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=2' "an unusable event path must return 2 so the caller sleeps the budget itself"
pass "an unusable event path returns the fail-closed code that hands the wait back to the poll loop"

new_case events-no-initial; d=$CASE_DIR
out=$(adapter "$d" 'fm_backend_thurbox_event_reader_cmd | tr "\n" " "')
assert_contains "$out" 'watch' "the reader must be thurbox-cli watch"
assert_not_contains "$out" '--initial' "--initial would replay handled state as a fresh edge on every poll"
pass "the event reader never passes --initial, so a handled blocked state is not replayed each poll"

# --- registry wiring ---------------------------------------------------------

out=$( . "$ROOT/bin/fm-backend.sh"
  fm_backend_is_known thurbox && echo known
  fm_backend_validate_spawn thurbox >/dev/null 2>&1 && echo spawnable
  fm_backend_has_push thurbox && echo pushes
  printf 'tools=%s\n' "$(fm_backend_required_tools thurbox)"
)
for want in known spawnable pushes; do
  assert_contains "$out" "$want" "registry wiring: missing $want"
done
assert_contains "$out" 'tools=thurbox-cli jq treehouse' "thurbox needs its CLI, jq, and treehouse as the worktree provider"
pass "thurbox is registered as a known, spawn-capable, push-capable backend with its own tool set"

out=$( . "$ROOT/bin/fm-control-lib.sh"
  fm_control_backend_state_verified thurbox && echo state-verified
  fm_control_backend_supports_key thurbox Escape && echo escape
  fm_control_backend_supports_key thurbox C-u && echo ctrl-u
)
for want in state-verified escape ctrl-u; do
  assert_contains "$out" "$want" "control wiring: missing $want"
done
pass "the control plane treats thurbox as state-verified and able to deliver Escape and Ctrl+U"

# --- runtime detection -------------------------------------------------------
#
# thurbox runs its panes on its OWN tmux server, so a thurbox pane has BOTH
# THURBOX_SESSION and $TMUX set. Detection therefore cannot be a bare marker
# read and cannot sit after the tmux arm. The socket is the discriminator, and
# both directions are pinned: a thurbox pane detects thurbox, and a NESTED
# plain tmux inside one correctly stays tmux.

new_case detect-thurbox; d=$CASE_DIR
out=$(THURBOX_SESSION=abc TMUX=/tmp/tmux-1000/thurbox,123,0 \
  adapter "$d" 'fm_backend_thurbox_is_current_runtime && echo detected')
assert_contains "$out" 'detected' "a pane on thurbox's own socket must detect thurbox"
pass "a pane on thurbox's own tmux socket is detected as the thurbox runtime"

new_case detect-nested-tmux; d=$CASE_DIR
out=$(THURBOX_SESSION=abc TMUX=/tmp/tmux-1000/default,123,0 \
  adapter "$d" 'fm_backend_thurbox_is_current_runtime && echo detected || echo not-thurbox')
assert_contains "$out" 'not-thurbox' "a nested plain tmux inherits THURBOX_SESSION but is not thurbox"
pass "a nested plain tmux inside a thurbox pane stays tmux, not thurbox"

new_case detect-no-marker; d=$CASE_DIR
out=$(TMUX=/tmp/tmux-1000/thurbox,123,0 \
  adapter "$d" 'unset THURBOX_SESSION; fm_backend_thurbox_is_current_runtime && echo detected || echo not-thurbox')
assert_contains "$out" 'not-thurbox' "no THURBOX_SESSION means no thurbox detection"
pass "the socket alone never selects thurbox without the session marker"

new_case detect-precedes-tmux; d=$CASE_DIR
out=$(THURBOX_SESSION=abc TMUX=/tmp/tmux-1000/thurbox,123,0 \
  bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_detect' 2>/dev/null)
[ "$out" = thurbox ] || fail "detection must reach the thurbox arm before tmux (got: $out)"
pass "the thurbox arm is evaluated before tmux, so a thurbox pane is never misread as plain tmux"

echo "all fm-backend-thurbox tests passed"
