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
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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

# Model clap's leading-dash refusal for `session send`, the one parser rule this
# adapter can get wrong. A bare positional beginning with `-` is read as a flag
# unless it follows `--`; the real CLI answers exactly this way, and a fake that
# accepted it would let a broken argv order pass the suite forever.
if [ "${1:-}" = session ] && [ "${2:-}" = send ]; then
  seen_ddash=0
  seen_id=0
  for a in "$@"; do
    case "$a" in
      session|send) continue ;;
      --) seen_ddash=1; continue ;;
    esac
    [ "$seen_ddash" = 1 ] && continue
    case "$a" in
      -*)
        if [ "$seen_id" = 1 ]; then
          case "$a" in
            --no-enter|--json|--pretty|--toon|--text|--full) continue ;;
          esac
          printf '{"error":"unexpected argument '"'"'%s'"'"' found","suggestion":"..."}\n' "$a"
          exit 2
        fi
        ;;
      *) seen_id=1 ;;
    esac
  done
fi

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

# make_fake_tmux <dir> <live-pane-id>...: a `tmux` stub whose `list-panes -a`
# reports exactly the given pane ids. The thurbox adapter needs it to answer
# "is this deleted session's pane still up", which thurbox itself will not say.
make_fake_tmux() {  # <fakebin-dir> [pane-id...]
  local fb=$1
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  *list-panes*)\n'
    for pane in "$@"; do printf "    printf '%%s\\\\n' '%s'\n" "$pane"; done
    printf '    exit 0 ;;\n'
    printf 'esac\nexit 0\n'
  } > "$fb/tmux"
  chmod +x "$fb/tmux"
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

# A REAL 2.11.1 session row, including the `stopped` field that release put on
# `session get` and `session list`. 2.11.0 omitted it and reported a parked
# session identically to a running one, which is why the adapter's floor is
# 2.11.1: below it these reads cannot answer at all.
SESSION_ROW='{"id":"11111111-2222-3333-4444-555555555555","name":"fm-firstmate-abcd1234-t1","state":"working","state_source":"hook","hook_state_contradicted":false,"stopped":false,"cwd":"/tmp/wt"}'
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
  fm_backend_thurbox_version_at_least 2.11.1 2.11.1 && echo eq
  fm_backend_thurbox_version_at_least 2.11.2 2.11.1 && echo patch-up
  fm_backend_thurbox_version_at_least 2.12.0 2.11.1 && echo minor-up
  fm_backend_thurbox_version_at_least 3.0.0 2.11.1 && echo major-up
  fm_backend_thurbox_version_at_least 2.11.0 2.11.1 || echo below-patch
  fm_backend_thurbox_version_at_least 1.99.99 2.11.1 || echo below-major
')
for want in eq patch-up minor-up major-up below-patch below-major; do
  case "$out" in *"$want"*) ;; *) fail "version floor: missing $want (got: $out)" ;; esac
done
pass "version comparison holds at the floor boundary in both directions"

new_case version-refusal; d=$CASE_DIR
out=$(FM_BACKEND_THURBOX_VERSION_OVERRIDE=2.10.0 adapter "$d" 'fm_backend_thurbox_version_check 2>&1; echo "rc=$?"')
assert_contains "$out" 'rc=1' "a below-floor thurbox-cli must be refused"
assert_contains "$out" '2.11.1 floor' "the refusal must name the floor it needs"
pass "a thurbox-cli below the version floor is refused loudly, naming the floor"

# 2.11.0 has every verb this adapter calls and still fails the gate, because it
# cannot report a parked session. Pinning the boundary keeps a future floor
# change from silently re-admitting it.
new_case version-refusal-2110; d=$CASE_DIR
out=$(FM_BACKEND_THURBOX_VERSION_OVERRIDE=2.11.0 adapter "$d" 'fm_backend_thurbox_version_check 2>&1; echo "rc=$?"')
assert_contains "$out" 'rc=1' "2.11.0 must be refused: it cannot report a parked session"
pass "2.11.0 is refused despite having every verb, because it cannot report a parked session"

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

# --- send: text the shell would read as a flag -------------------------------
#
# `session send` promises paste delivery, so a leading `-`, quote or newline
# survives intact - and that promise is about the PASTE, not the argument
# parser. With the text as a trailing positional, clap reads a leading `-` as a
# flag of its own and refuses the call outright, so nothing is typed at all.
# Reproduced against the real 2.18.0 binary; the fake above models the same rule.

new_case send-leading-dash; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
out=$(adapter "$d" "fm_backend_thurbox_send_literal '$TARGET' '-x --weird leading dash'; echo rc=\$?")
assert_contains "$out" 'rc=0' "text beginning with a dash must still reach the pane"
assert_log_args "the text must be delivered after -- so the parser cannot claim it" -- '-x --weird leading dash'
pass "steer text the argument parser would read as a flag is still delivered"

new_case send-ordinary; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
out=$(adapter "$d" "fm_backend_thurbox_send_literal '$TARGET' 'ordinary text'; echo rc=\$?")
assert_contains "$out" 'rc=0' "ordinary text must still be delivered"
assert_log_args "ordinary text must ride the same delivery path" -- 'ordinary text'
pass "ordinary steer text rides the same delivery path"

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

# Both inventories must answer before `missing` is licensed: the live one to
# show the session is not running, the deleted one to show it was not merely
# soft-deleted with its pane still alive.
new_case agent-missing; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = missing ] || fail "a successful inventory omitting the session must read missing (got: $out)"
pass "a session absent from both the live and deleted inventories reports missing"

new_case agent-inventory-failure; d=$CASE_DIR
respond_exit "$d" 1 1 '{"error":"database is locked"}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = unreadable ] || fail "a failed inventory must read unreadable, never missing (got: $out)"
pass "a failed inventory read reports unreadable, so a CLI error can never license recovery"

new_case agent-alive; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555","stopped":false}]'
respond "$d" 2 '{"foreground_process":"claude","foreground_command":"claude --resume x","output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = alive ] || fail "an agent foreground process must read alive (got: $out)"
pass "a live agent in the pane's foreground reports alive"

new_case agent-dead-shell; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555","stopped":false}]'
respond "$d" 2 '{"foreground_process":"bash","foreground_command":"/bin/bash -i","output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = dead ] || fail "a bare shell foreground must read dead (got: $out)"
pass "a pane that fell back to its shell reports dead"

new_case agent-ambiguous; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555","stopped":false}]'
respond "$d" 2 '{"foreground_process":null,"foreground_command":null,"output":""}'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = ambiguous ] || fail "an unattributable foreground must read ambiguous (got: $out)"
pass "a pane whose foreground process cannot be attributed reports ambiguous, not dead"

new_case agent-parked; d=$CASE_DIR
respond "$d" 1 '[{"id":"11111111-2222-3333-4444-555555555555","stopped":true}]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = dead ] || fail "a parked session must read dead, not missing (got: $out)"
pass "a parked session reports dead, keeping its row and checkout out of missing-endpoint recovery"

new_case target-ready-parked; d=$CASE_DIR
respond "$d" 1 '{"id":"11111111-2222-3333-4444-555555555555","state":"stopped","stopped":true}'
out=$(adapter "$d" "fm_backend_thurbox_target_ready '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a parked session has no pane and must not be ready"
pass "a parked session is not a ready target, so no write can silently address nothing"

new_case target-ready-running; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
out=$(adapter "$d" "fm_backend_thurbox_target_ready '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "a running session must be ready"
pass "a running session is a ready target"

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
adapter "$d" "fm_backend_thurbox_send_literal '$TARGET' hello" >/dev/null 2>&1
assert_log_args "a write gated on the readiness check must address the session the target names" \
  session send --no-enter --json 11111111-2222-3333-4444-555555555555 -- hello
pass "a write gated on the readiness check still addresses the target's own session"

new_case ready-then-key; d=$CASE_DIR
respond "$d" 1 "$SESSION_ROW"
adapter "$d" "fm_backend_thurbox_send_key '$TARGET' Enter" >/dev/null 2>&1
assert_log_args "a key gated on the readiness check must address the session the target names" \
  session key 11111111-2222-3333-4444-555555555555 enter
pass "a key gated on the readiness check still addresses the target's own session"

# --- current path ------------------------------------------------------------

new_case current-path-live; d=$CASE_DIR
respond "$d" 1 '{"foreground_cwd":"/tmp/wt/proj","output":""}'
out=$(adapter "$d" "fm_backend_thurbox_current_path '$TARGET'")
[ "$out" = /tmp/wt/proj ] || fail "the live foreground cwd must be returned (got: $out)"
pass "the pane's live foreground cwd is what current-path reports"

# The kernel appends " (deleted)" to /proc/<pid>/cwd when the directory is
# unlinked under a running process, so what arrives is not a path. Observed live
# when a task worktree was removed while its shell was still inside it. Falling
# back to the session row's creation-time cwd would be worse than failing: that
# path may still exist, and fm-spawn's worktree-isolation assertion would then be
# handed a live directory that is not where the pane actually is.
new_case current-path-deleted; d=$CASE_DIR
respond "$d" 1 '{"foreground_cwd":"/tmp/wt/proj (deleted)","output":""}'
respond "$d" 2 '{"id":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/still-here"}'
out=$(adapter "$d" "fm_backend_thurbox_current_path '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a deleted working directory must fail, not resolve"
assert_not_contains "$out" '/tmp/still-here' "a deleted cwd must not fall back to the creation-time directory"
assert_not_contains "$out" 'deleted' "the kernel's suffix must never be handed on as a path"
pass "a working directory deleted under the pane fails closed instead of resolving to a stale path"

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

# --- absence has to be proven, not inferred from the row -----------------------
#
# A soft `session delete` removes the row while the pane keeps running, and
# thurbox will not force-delete a row it can no longer resolve, so that pane
# outlives the session indefinitely. Row-absence therefore does NOT prove
# endpoint-absence. `session list --deleted` carries `force_deleted`, which is
# the discriminator: true means the window was killed, false means it is still
# there. Verified against 2.18.0.

new_case gone-soft-deleted; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false}]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a soft-deleted session whose pane may still run is NOT proven gone"
pass "a soft-deleted endpoint is never reported as provably gone while its pane may still run"

new_case gone-force-deleted; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":true}]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "a force-deleted session had its window killed and IS proven gone"
pass "a force-deleted endpoint is proven gone"

new_case gone-absent-entirely; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "a session in neither list is proven gone"
pass "a session absent from both the live and deleted inventories is proven gone"

new_case gone-deleted-read-fails; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond_exit "$d" 2 1 '{"error":"unavailable"}'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a failed deleted-inventory read is not proof of absence"
pass "absence needs both inventories to answer, never a failed read"

# Recovery is the sharper edge: only dead and missing license a relaunch, so
# reporting missing for a session whose agent is still running invites a second
# agent into the same task.
new_case agent-soft-deleted; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false}]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = unreadable ] || fail "a soft-deleted session must not read missing and license a relaunch (got: $out)"
pass "a soft-deleted session reads unreadable, so recovery cannot start a second agent beside a live one"

new_case agent-force-deleted; d=$CASE_DIR
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":true}]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = missing ] || fail "a force-deleted session is authoritatively gone (got: $out)"
pass "a force-deleted session reports missing, which correctly licenses recovery"

# --- reaping, and proving the pane is actually down ---------------------------
#
# A soft delete is thurbox's lossless undo window, not a leak: the row goes, the
# worktrees stay, and the pane comes down when an interface, the automation
# heartbeat, or `session reap` lets go of it. Firstmate runs headless, so it
# reaps deliberately rather than waiting for something that may never run.
#
# The deleted row cannot report any of this. It is byte-identical before and
# after a reap - `force_deleted` stays false and there is no reaped marker
# (verified on 2.18.0) - and `session get`/`session capture` refuse a deleted row
# either way. The row's own `backend_id` against thurbox's socket is the only
# thing that answers, which is why the proof reaches for the multiplexer here and
# nowhere else in this adapter.

new_case reap-when-force-refused; d=$CASE_DIR
# 1 delete --force refuses a row it can no longer resolve, 2 reap takes the pane down.
respond_exit "$d" 1 1 '{"error":"Session not found: 11111111-2222-3333-4444-555555555555"}'
respond "$d" 2 '{"id":"11111111-2222-3333-4444-555555555555","name":"x","reaped":true}'
out=$(adapter "$d" "fm_backend_thurbox_kill '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "teardown must still bring the pane down when force-delete cannot resolve the row"
assert_log_args "the pane must be released with reap" session reap 11111111-2222-3333-4444-555555555555
pass "teardown reaps the pane when a soft-deleted row refuses a forced delete"

new_case reap-not-needed; d=$CASE_DIR
respond "$d" 1 '{"deleted":true,"killed_window":true,"forced":true}'
out=$(adapter "$d" "fm_backend_thurbox_kill '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "an ordinary forced teardown must succeed"
assert_no_grep 'reap' "$FM_THURBOX_LOG" "a forced delete that worked must not also reap"
pass "an ordinary forced teardown does not reach for reap"

new_case gone-soft-deleted-pane-down; d=$CASE_DIR
make_fake_tmux "$CASE_DIR/fakebin" '%99'
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false,"backend_type":"local-tmux","backend_id":"%42"}]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=0' "a reaped session whose pane is gone IS provably gone"
pass "a soft-deleted session whose pane has been reaped is proven gone"

new_case gone-soft-deleted-pane-up; d=$CASE_DIR
make_fake_tmux "$CASE_DIR/fakebin" '%42'
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false,"backend_type":"local-tmux","backend_id":"%42"}]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a session whose pane is still up is not gone, reaped or not"
pass "a soft-deleted session whose pane is still up is never reported gone"

new_case gone-soft-deleted-remote; d=$CASE_DIR
make_fake_tmux "$CASE_DIR/fakebin"
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false,"backend_type":"ssh:elsewhere","backend_id":"%42"}]'
out=$(adapter "$d" "fm_backend_thurbox_endpoint_confirmed_gone '$TARGET'; echo rc=\$?")
assert_contains "$out" 'rc=1' "a remote pane cannot be proven absent from this machine"
pass "a remote session's pane is never claimed proven absent from the wrong host"

new_case agent-soft-deleted-pane-down; d=$CASE_DIR
make_fake_tmux "$CASE_DIR/fakebin" '%99'
respond "$d" 1 '[{"id":"other-session","stopped":false}]'
respond "$d" 2 '[{"id":"11111111-2222-3333-4444-555555555555","name":"x","force_deleted":false,"backend_type":"local-tmux","backend_id":"%42"}]'
out=$(adapter "$d" "fm_backend_thurbox_agent_state '$TARGET'")
[ "$out" = missing ] || fail "a reaped session is authoritatively gone and may license recovery (got: $out)"
pass "a reaped session reports missing, which correctly licenses recovery"

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
# Logs its own argv so a test can see exactly how the stream was resumed.
printf '%s\\n' "\$*" >> "$dir/reader-args"
cat "$src"
SH
  chmod +x "$dir/reader"
  : > "$dir/reader-args"
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

# --- resuming the stream, so a transition between windows is not lost ---------
#
# The watcher waits in bounded windows (FM_POLL, 15s by default) and the stream
# is not running between them, so any edge landing in that gap was simply never
# seen. thurbox gives every event a monotonic `seq` and `watch --since <seq>`
# replays exactly what was missed - its help names this case outright, "the gap
# a stream otherwise has across a restart".
#
# The property under test is the resume itself, asserted on the reader's own
# argv and on the persisted cursor, because that is what a caller can observe.

new_case events-first-wait-has-no-since; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":10,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'" >/dev/null 2>&1
assert_not_contains "$(cat "$d/reader-args")" '--since' \
  "the first wait has no cursor yet and must start from now, not replay history"
pass "the first wait starts from now rather than replaying every past transition"

new_case events-cursor-advances; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":41,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
{"seq":42,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"idle","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'" >/dev/null 2>&1
cur=$(cat "$d/state/.thurbox-watch-seq" 2>/dev/null)
[ "$cur" = 42 ] || fail "the cursor must record the last event consumed (got: '$cur')"
pass "the cursor records the last transition actually consumed"

new_case events-second-wait-resumes; d=$CASE_DIR
mkdir -p "$d/state"
printf '77\n' > "$d/state/.thurbox-watch-seq"
cat > "$d/stream" <<'NDJSON'
{"seq":78,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'" >/dev/null 2>&1
assert_contains "$(cat "$d/reader-args")" '--since 77' \
  "a later wait must resume from the recorded cursor so the gap between windows is replayed"
pass "a later wait resumes from the cursor, so an edge landing between windows is not lost"

# Returning early on an actionable edge must NOT swallow the events behind it:
# the cursor stops at the edge that was handled, so the rest replay next time.
new_case events-cursor-stops-at-handled-edge; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":90,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"blocked","name":"t"}
{"seq":91,"event":"changed","session":"11111111-2222-3333-4444-555555555555","state":"working","name":"t"}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=0' "the blocked edge must still be reported"
cur=$(cat "$d/state/.thurbox-watch-seq" 2>/dev/null)
[ "$cur" = 90 ] || fail "the cursor must stop at the handled edge so later events replay (got: '$cur')"
pass "an early return leaves later transitions to replay instead of swallowing them"

# --- what the event actually carries ------------------------------------------
#
# The adapter used to read three fields out of an event because 2.11's stream
# carried little else. It now carries the previous state and thurbox's own
# confidence in the one it reports, and both change decisions here.

new_case events-carry-from-state; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":5,"event":"changed","session":"11111111-2222-3333-4444-555555555555","from_state":"working","state":"blocked","to_state":"blocked","agent":"claude","hook_blocked_is_heuristic":false}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "
    rec=\$(fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET') || exit 1
    echo \"from=\$(fm_transition_from_status \"\$rec\") to=\$(fm_transition_to_status \"\$rec\") agent=\$(fm_transition_agent \"\$rec\")\"
  ")
assert_contains "$out" 'from=working' "the record must carry the state the session came from"
assert_contains "$out" 'to=blocked' "the record must carry the state it moved to"
pass "a transition record carries the previous state, not just the new one"

# thurbox reports hook_blocked_is_heuristic because Claude's blocked signal rides
# its Notification hook, which also fires for advisories an auto-mode agent
# clears by itself. Escalating on the first such edge is what produced three
# false alarms; the corroboration belongs here, not in a supervisor's script.

new_case events-heuristic-blocked-transient; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":6,"event":"changed","session":"11111111-2222-3333-4444-555555555555","from_state":"working","state":"blocked","to_state":"blocked","hook_blocked_is_heuristic":true}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
# The corroborating read finds the session already working again.
respond "$d" 1 '{"id":"11111111-2222-3333-4444-555555555555","state":"working","state_source":"hook"}'
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=1' "a heuristic blocked edge the session has already left must not escalate"
pass "a heuristic blocked edge that has already cleared is absorbed, not raised"

new_case events-heuristic-blocked-real; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":7,"event":"changed","session":"11111111-2222-3333-4444-555555555555","from_state":"working","state":"blocked","to_state":"blocked","hook_blocked_is_heuristic":true}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
# The corroborating read confirms it is still blocked.
respond "$d" 1 '{"id":"11111111-2222-3333-4444-555555555555","state":"blocked","state_source":"hook"}'
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=0' "a heuristic blocked edge that is still blocked must escalate"
pass "a heuristic blocked edge that is still blocked is raised"

new_case events-confident-blocked-no-recheck; d=$CASE_DIR
cat > "$d/stream" <<'NDJSON'
{"seq":8,"event":"changed","session":"11111111-2222-3333-4444-555555555555","from_state":"working","state":"blocked","to_state":"blocked","hook_blocked_is_heuristic":false}
NDJSON
reader_bin=$(make_event_reader "$d" "$d/stream")
mkdir -p "$d/state"
out=$(FM_BACKEND_THURBOX_EVENTS_FORCE=1 FM_BACKEND_THURBOX_EVENT_READER="$reader_bin" \
  adapter "$d" "fm_backend_thurbox_wait_transition 5 '$d/state' '$TARGET'; echo \"|rc=\$?\"")
assert_contains "$out" '|rc=0' "a blocked edge thurbox is confident about must escalate"
assert_no_grep 'session get' "$FM_THURBOX_LOG" "a confident blocked edge must not pay for a corroborating read"
pass "a blocked edge thurbox reports confidently escalates with no extra read"

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


# --- spawn wiring: the agent's own hook args reach the typed launch ----------
#
# thurbox reports `state` and emits `watch` events only for an agent whose
# status hooks fired, and those hooks are ARGUMENTS: thurbox appends an agent's
# `args` from agents.toml when IT builds the command line. Firstmate's spawn
# contract creates a shell and TYPES the harness in, so nothing appended them
# and every firstmate-spawned session reported no state at all.
#
# `thurbox-cli agent launch-args <agent>` exists to close that, so the property
# under test is that those args reach the command actually typed into the pane.
# Asserted on the typed text, never on the template, so the placeholder
# plumbing cannot pass while delivering nothing.

make_spawn_thurbox_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb
  fb=$(make_spawn_fakebin "$dir/fake" gh-axi gh)
  cat > "$fb/thurbox-cli" <<'SH'
#!/usr/bin/env bash
set -u
{ for a in "$@"; do printf '%s\x1f' "$a"; done; printf '\n'; } >> "${FM_THURBOX_LOG:?}"
case "${1:-}:${2:-}" in
  version:*)  printf '{"version":"2.11.1","tmux_socket":"thurbox"}\n' ;;
  agent:launch-args)
    # Only `claude` is a registered agent here, mirroring a real agents.toml
    # that carries no entry for every firstmate harness.
    case "${3:-}" in
      claude)
        printf '{"agent":"claude","command":"claude","args":["--settings","/hooks/claude.json"],"env":{},"hooks_enabled":true,"hook_coverage":"full"}\n' ;;
      opencode)
        # Registered with FULL coverage and no args: thurbox installs this
        # agent's hooks out of band, so nothing is appended and state still works.
        printf '{"agent":"opencode","command":"opencode","args":[],"env":{},"hooks_enabled":true,"hook_coverage":"full"}\n' ;;
      *)
        printf '{"error":"no agent named '"'"'%s'"'"' in agents.toml"}\n' "${3:-}"; exit 1 ;;
    esac
    ;;
  session:list)   printf '[]\n' ;;
  session:create) printf '{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"x"}\n' ;;
  session:get)    printf '{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","state":"uncovered","stopped":false,"cwd":"/tmp"}\n' ;;
  session:capture) printf '{"output":"","cursor_row":0,"foreground_process":"bash","foreground_command":"/bin/bash -i","foreground_cwd":"%s"}\n' "${FM_THURBOX_FAKE_CWD:-/tmp}" ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$fb/thurbox-cli"
  printf '%s\n' "$fb"
}

run_thurbox_spawn() {  # <home> <wt> <fakebin> <args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="${TMUX:-fake,1,0}" \
    FM_BACKEND=thurbox \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# Sets SPAWN_HOME/SPAWN_PROJ/SPAWN_WT/SPAWN_FB/SPAWN_ID and the fake's env.
# Called DIRECTLY, never in a command substitution: the exports have to land in
# this shell, or the fake answers with a cwd the isolation guard rejects.
spawn_case_thurbox() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/spawn-$name"
  SPAWN_HOME="$case_dir/home"
  SPAWN_PROJ="$case_dir/project"
  SPAWN_WT="$case_dir/wt"
  SPAWN_ID="tbx-$name-x1"
  SPAWN_FB=$(make_spawn_thurbox_fakebin "$case_dir")
  fm_test_spawn_home "$SPAWN_HOME"
  fm_test_spawn_brief "$SPAWN_HOME" "$SPAWN_ID" brief
  fm_git_worktree "$SPAWN_PROJ" "$SPAWN_WT" "fm/$SPAWN_ID"
  export FM_THURBOX_LOG="$case_dir/thurbox-log"
  export FM_THURBOX_FAKE_CWD="$SPAWN_WT"
  : > "$FM_THURBOX_LOG"
}

# The launch command is typed through `session send`, so the log's send lines
# are exactly what the pane received.
thurbox_typed_lines() {
  tr '\037' ' ' < "$FM_THURBOX_LOG" | grep '^session send ' || true
}

spawn_case_thurbox hookargs
out=$(run_thurbox_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FB" "$SPAWN_ID" "$SPAWN_PROJ" claude --mode no-mistakes --yolo off)
status=$?
[ "$status" -eq 0 ] || { printf '%s\n' "--- spawn output ---" "$out" >&2; fail "thurbox spawn should succeed"; }
typed=$(thurbox_typed_lines)
assert_contains "$typed" 'claude' "the harness launch must be typed into the pane"
# Each argument is shell-quoted individually, because a hooks path may contain
# spaces and the launch is typed into a shell rather than exec'd.
assert_contains "$typed" "'--settings' '/hooks/claude.json'" \
  "the agent's own hook args must reach the typed launch, or thurbox reports no state for the session"
assert_contains "$typed" "claude '--settings'" \
  "the hook args must sit directly after the binary, not after the brief positional"
pass "a thurbox spawn types the agent's hook args, so the session reports state and appears in watch"

# A harness thurbox has no agents.toml entry for must still spawn. The lookup
# fails by design there, and a failed lookup is not a spawn failure - it only
# means that session reports no native state, exactly as before this wiring.
spawn_case_thurbox unknownagent
out=$(run_thurbox_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FB" "$SPAWN_ID" "$SPAWN_PROJ" grok --mode no-mistakes --yolo off)
status=$?
[ "$status" -eq 0 ] || { printf '%s\n' "--- spawn output ---" "$out" >&2; fail "a spawn whose harness is not a registered thurbox agent must still succeed"; }
typed=$(thurbox_typed_lines)
assert_contains "$typed" 'grok' "the harness launch must still be typed"
assert_not_contains "$typed" '--settings' "no hook args exist for an unregistered agent; none must be invented"
pass "a harness thurbox does not register still spawns, simply without native state reporting"

# An agent thurbox registers but ships no launch args still spawns clean and
# raises no notice: thurbox installs those hooks by writing the agent's own
# config, so the session reports state with nothing appended. Warning here would
# tell the operator their supervision is degraded when it is not.
spawn_case_thurbox hooklessagent
out=$(run_thurbox_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FB" "$SPAWN_ID" "$SPAWN_PROJ" opencode --mode no-mistakes --yolo off)
status=$?
[ "$status" -eq 0 ] || { printf '%s\n' "--- spawn output ---" "$out" >&2; fail "a registered agent with no launch args must spawn"; }
typed=$(thurbox_typed_lines)
assert_contains "$typed" 'opencode' "the harness launch must be typed"
assert_not_contains "$typed" '--settings' "an agent with no launch args must have none invented"
assert_not_contains "$out" 'no agents.toml entry' \
  "a registered agent with no args must not be reported as losing native state"
pass "a registered agent whose hooks are installed out of band spawns clean and raises no notice"

# The notice fires only for an agent thurbox genuinely does not know.
spawn_case_thurbox unknownnotice
out=$(run_thurbox_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FB" "$SPAWN_ID" "$SPAWN_PROJ" grok --mode no-mistakes --yolo off)
assert_contains "$out" 'no agents.toml entry' \
  "an unregistered harness must say plainly that this session reports no native state"
pass "an unregistered harness raises one notice naming the consequence"

# The slot must cost every OTHER backend nothing. It resolves to the empty
# string off thurbox, so a literal space beside it in a template silently
# doubles up in the command every tmux, herdr, zellij, cmux and orca task runs -
# which is exactly what happened to the pi template on the first attempt. This
# pins the invariant directly rather than relying on another suite noticing.
for _tbx_h in claude codex opencode; do
  _tbx_dir="$TMP_ROOT/slot-cost-$_tbx_h"
  _tbx_home="$_tbx_dir/home"; _tbx_proj="$_tbx_dir/project"; _tbx_wt="$_tbx_dir/wt"
  _tbx_id="slot-$_tbx_h-x1"
  _tbx_fb=$(make_spawn_fakebin "$_tbx_dir/fake" gh-axi gh opencode codex)
  fm_test_spawn_home "$_tbx_home"
  fm_test_spawn_brief "$_tbx_home" "$_tbx_id" brief
  fm_git_worktree "$_tbx_proj" "$_tbx_wt" "fm/$_tbx_id"
  FM_FAKE_LAUNCH_LOG="$_tbx_dir/launch.log"
  export FM_FAKE_LAUNCH_LOG
  : > "$FM_FAKE_LAUNCH_LOG"
  fm_test_run_spawn "$_tbx_home" "$_tbx_wt" "$_tbx_fb" \
    "$_tbx_id" "$_tbx_proj" "$_tbx_h" --mode no-mistakes --yolo off >/dev/null 2>&1
  _tbx_launch=$(grep -F "$_tbx_h" "$FM_FAKE_LAUNCH_LOG" 2>/dev/null | tail -1)
  [ -n "$_tbx_launch" ] || fail "no $_tbx_h launch was typed on the tmux backend"
  assert_not_contains "$_tbx_launch" '__THURBOXARGS__' \
    "the thurbox slot must be substituted away on every backend, not left in the typed command"
  assert_not_contains "$_tbx_launch" '  ' \
    "an empty thurbox slot must leave no stray whitespace in the $_tbx_h launch on a non-thurbox backend"
  unset FM_FAKE_LAUNCH_LOG
done
pass "the thurbox launch slot costs a non-thurbox backend nothing: no placeholder, no stray whitespace"

echo "all fm-backend-thurbox tests passed"
