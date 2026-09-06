#!/usr/bin/env bash
# tests/fm-backend-paseo.test.sh - portable regressions for the paseo backend's
# SAFETY BOUNDARY, which lands before any lifecycle code exists: registration
# as a known-but-not-spawn-capable name, runtime-detection ordering, the spawn
# refusal, and endpoint-record validation.
#
# Nothing here runs a real `paseo`, and nothing here can. That is the point of
# doing this stage first: every behavior below is decided from environment
# markers, task metadata, and refusals, so the whole suite runs on a machine
# with no Paseo installed and never reaches a live Paseo daemon. The
# real-binary smoke test arrives with the lifecycle adapter.
#
# Detection ordering is the load-bearing case. Paseo exports PASEO_AGENT_ID into
# every process an agent session starts, so a tmux pane spawned by a
# Paseo-hosted firstmate carries BOTH markers and only $TMUX names the layer
# actually executing - the both-markers cases below are what keep that from
# silently rerouting a whole fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)

# uname pinned to Linux makes the cmux bundle-id/ancestry fallback inert, so an
# assertion about paseo detection never depends on which terminal app this suite
# happens to be running inside. FAKE_DARWIN_BIN is its counterpart for the one
# case that must exercise that fallback against a Paseo marker.
FAKE_NONDARWIN_BIN=$(mktemp -d "$TMP_ROOT/fake-nondarwin.XXXXXX")
printf '#!/bin/sh\necho Linux\n' > "$FAKE_NONDARWIN_BIN/uname"
chmod +x "$FAKE_NONDARWIN_BIN/uname"
FAKE_DARWIN_BIN=$(mktemp -d "$TMP_ROOT/fake-darwin.XXXXXX")
printf '#!/bin/sh\necho Darwin\n' > "$FAKE_DARWIN_BIN/uname"
chmod +x "$FAKE_DARWIN_BIN/uname"

PASEO_WS=wks_c7e413f9c986b0f8
PASEO_TERM=11111111-2222-3333-4444-555555555555

# --- registration ------------------------------------------------------------

test_paseo_is_known_but_not_spawn_capable() {
  local out rc
  fm_backend_validate paseo 2>/dev/null \
    || fail "fm_backend_validate should accept paseo (it is in FM_BACKEND_KNOWN)"
  set +e
  out=$(fm_backend_validate_spawn paseo 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "fm_backend_validate_spawn must refuse paseo while it has no lifecycle adapter"
  assert_contains "$out" "backend 'paseo' does not support task spawning yet" \
    "the spawn refusal should say paseo cannot spawn yet"
  if fm_backend_list_contains "$FM_BACKEND_SPAWN" paseo; then
    fail "paseo must not advertise itself as spawn-supported, got '$FM_BACKEND_SPAWN'"
  fi
  pass "backend registry: paseo is a known backend name that is refused for spawning until its adapter lands"
}

test_unknown_backend_still_refuses_and_names_paseo() {
  local out rc
  set +e
  out=$(fm_backend_validate paseo-typo 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm_backend_validate should still refuse an unknown backend name"
  assert_contains "$out" "unknown backend 'paseo-typo'" \
    "the unknown-backend refusal no longer names the rejected value"
  assert_contains "$out" "paseo" \
    "the unknown-backend refusal should list paseo among the known backends"
  pass "backend registry: an unknown backend name still refuses, and the known list now includes paseo"
}

test_paseo_required_tools_are_transport_independent() {
  local tools
  tools=$(fm_backend_required_tools paseo) \
    || fail "fm_backend_required_tools should answer for the registered paseo backend"
  fm_backend_list_contains "$tools" treehouse \
    || fail "paseo is session-provider-only, so treehouse must be a required tool, got '$tools'"
  if fm_backend_list_contains "$tools" paseo; then
    fail "paseo's CLI shim is not on PATH (it is reached through \$PASEO_CLI), so it must not be declared a required PATH tool, got '$tools'"
  fi
  pass "fm_backend_required_tools: paseo requires treehouse and declares no PATH-resolved Paseo CLI"
}

# --- detection ---------------------------------------------------------------

test_paseo_detect_markers() {
  local out rc
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when PASEO_AGENT_ID is set"
  [ "$out" = paseo ] || fail "PASEO_AGENT_ID alone should detect paseo, got '$out'"

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_AGENT_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_TERMINAL_ID='terminal-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when PASEO_TERMINAL_ID is set"
  [ "$out" = paseo ] || fail "PASEO_TERMINAL_ID alone should detect paseo, got '$out'"

  # The winning signal is reported, so a caller can say WHICH Paseo context won.
  set +e
  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' \
      fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECT_SIGNAL" = PASEO_AGENT_ID ] || exit 2
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='' PASEO_TERMINAL_ID='terminal-uuid' \
      fm_backend_detect >/dev/null || exit 3
    [ "$FM_BACKEND_DETECT_SIGNAL" = PASEO_TERMINAL_ID ] || exit 4
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "fm_backend_detect did not report the winning Paseo marker in FM_BACKEND_DETECT_SIGNAL (subshell exit $rc)"

  pass "fm_backend_detect: either PASEO_AGENT_ID or PASEO_TERMINAL_ID selects paseo and names itself as the signal"
}

test_paseo_cli_is_not_a_detection_marker() {
  local out
  # PASEO_CLI is exported by the Paseo CLI shim into everything it touches, so
  # it survives arbitrarily far down a process tree and cannot mean "running
  # inside Paseo". Detection must ignore it, and every other inherited PASEO_*
  # value, entirely.
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier PASEO_AGENT_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_CLI='/Applications/Paseo.app/Contents/Resources/bin/paseo' \
    PASEO_WEB_UI_ENABLED=false PASEO_AGENT_CWD=/tmp fm_backend_detect); then
    fail "PASEO_CLI (plus other inherited PASEO_* values) must not detect paseo, got '$out'"
  fi
  pass "fm_backend_detect: PASEO_CLI is a binary-resolution variable, never a runtime marker"
}

test_paseo_detect_is_ordered_last() {
  local out
  # The live case: a tmux pane spawned by a Paseo-hosted firstmate carries BOTH
  # $TMUX and PASEO_AGENT_ID. Only $TMUX names the layer actually executing, so
  # checking paseo any earlier would reroute every tmux task of a Paseo-hosted
  # firstmate to an experimental backend.
  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" TMUX='fake,1,0' PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both \$TMUX and PASEO_AGENT_ID present"
  [ "$out" = tmux ] || fail "\$TMUX must win over PASEO_AGENT_ID (innermost-first), got '$out'"

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID PASEO_AGENT_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" TMUX='fake,1,0' PASEO_TERMINAL_ID='terminal-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both \$TMUX and PASEO_TERMINAL_ID present"
  [ "$out" = tmux ] || fail "\$TMUX must win over PASEO_TERMINAL_ID (innermost-first), got '$out'"

  out=$(unset TMUX CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" HERDR_ENV=1 PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both HERDR_ENV and PASEO_AGENT_ID present"
  [ "$out" = herdr ] || fail "HERDR_ENV=1 must win over PASEO_AGENT_ID, got '$out'"

  out=$(unset TMUX HERDR_ENV PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" CMUX_WORKSPACE_ID='fake-uuid' PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both CMUX_WORKSPACE_ID and PASEO_AGENT_ID present"
  [ "$out" = cmux ] || fail "CMUX_WORKSPACE_ID must win over PASEO_AGENT_ID, got '$out'"

  # Paseo also sits behind the cmux FALLBACK signals, not just its primary
  # marker: an inherited cmux bundle id still outranks a Paseo marker.
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_DARWIN_BIN:$PATH" __CFBundleIdentifier='com.cmuxterm.app' PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with a cmux bundle id and PASEO_AGENT_ID present"
  [ "$out" = cmux ] || fail "the cmux bundle-id fallback must be consulted before paseo, got '$out'"

  # Pathological: every marker at once. tmux still wins.
  out=$(PATH="$FAKE_NONDARWIN_BIN:$PATH" TMUX='fake,1,0' HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' \
    PASEO_AGENT_ID='agent-uuid' PASEO_TERMINAL_ID='terminal-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with all markers present"
  [ "$out" = tmux ] || fail "tmux must win with all markers present, got '$out'"

  # The divergence itself: with the other markers removed, the SAME Paseo marker
  # that just lost now wins - so none of the cases above passed vacuously.
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with PASEO_AGENT_ID alone"
  [ "$out" = paseo ] || fail "PASEO_AGENT_ID alone should still detect paseo, got '$out'"

  pass "fm_backend_detect: paseo is checked LAST - \$TMUX, HERDR_ENV, and both cmux signals all outrank a Paseo marker, which still wins alone"
}

test_paseo_autodetect_notice_and_explicit_override() {
  local dir cfg errfile out
  dir=$(mktemp -d "$TMP_ROOT/name-notice.XXXXXX")
  cfg="$dir/config"; errfile="$dir/err"
  mkdir -p "$cfg"

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' \
    FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = paseo ] || fail "fm_backend_name should auto-detect paseo from PASEO_AGENT_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "auto-detected paseo runtime (PASEO_AGENT_ID)" \
    "the paseo auto-detect notice should name the winning signal"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL" \
    "the paseo auto-detect notice should say the backend is experimental"

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_AGENT_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_TERMINAL_ID='terminal-uuid' \
    FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = paseo ] || fail "fm_backend_name should auto-detect paseo from PASEO_TERMINAL_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "auto-detected paseo runtime (PASEO_TERMINAL_ID)" \
    "the paseo auto-detect notice should name PASEO_TERMINAL_ID when that marker wins"

  # An explicit setting always wins outright, and silently: this is exactly how
  # a home pins itself to another backend while an experimental one soaks.
  printf 'tmux\n' > "$cfg/backend"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' \
    FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "config/backend should win over a Paseo auto-detect marker, got '$out'"
  [ ! -s "$errfile" ] || fail "an explicitly configured backend must not print an auto-detect notice, got '$(cat "$errfile")'"

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID PASEO_TERMINAL_ID; \
    PATH="$FAKE_NONDARWIN_BIN:$PATH" PASEO_AGENT_ID='agent-uuid' \
    FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "FM_BACKEND should win over a Paseo auto-detect marker, got '$out'"

  pass "fm_backend_name: a Paseo marker auto-detects with one loud notice naming the signal, and any explicit setting silently wins"
}

# --- spawn refusals ----------------------------------------------------------

# spawn_refuses_paseo <label> <extra fm-spawn args...>: run a real fm-spawn.sh
# invocation and require it to refuse at the shared backend boundary.
spawn_refuses_paseo() {  # <label> <args...>
  local label=$1 dir state data config projects out status
  shift
  dir=$(mktemp -d "$TMP_ROOT/spawn-refuse.XXXXXX")
  state="$dir/state"; data="$dir/data"; config="$dir/config"; projects="$dir/projects"
  mkdir -p "$state" "$data" "$config" "$projects"
  set +e
  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$projects" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1 )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a $label spawn with --backend paseo"
  assert_contains "$out" "backend 'paseo' does not support task spawning yet" \
    "the $label refusal should come from the shared fm_backend_validate_spawn boundary"
  [ ! -e "$state/$SPAWN_REFUSE_ID.meta" ] \
    || fail "a refused paseo $label spawn must not leave a task record behind"
}

test_spawn_refuses_paseo_at_the_shared_boundary() {
  # Every spawn kind refuses at the SAME boundary - fm_backend_validate_spawn,
  # which every spawn caller already crosses - because paseo has no lifecycle
  # adapter. That is well before the project lock is taken or any task record
  # is written, so no kind needs its own late refusal.
  SPAWN_REFUSE_ID=sm-paseo-test
  spawn_refuses_paseo secondmate "$SPAWN_REFUSE_ID" --secondmate --backend paseo

  SPAWN_REFUSE_ID=ship-paseo-test
  spawn_refuses_paseo ship "$SPAWN_REFUSE_ID" "$TMP_ROOT/unused-project" claude \
    --mode no-mistakes --yolo off --backend paseo

  pass "fm-spawn.sh: every paseo spawn kind refuses at the shared fm_backend_validate_spawn boundary, before any task record"
}

# --- endpoint-record validation ---------------------------------------------

# paseo_meta: write one meta file into its OWN mktemp -d directory under this
# suite's scratch root and echo the path. Each case therefore gets a fresh
# directory that is never reconstructed from variables and never removed by
# hand - fm_test_tmproot's registered cleanup owns the whole tree.
paseo_meta() {  # <task-id> <meta lines...> -> echoes meta path
  local id=$1 dir; shift
  dir=$(mktemp -d "$TMP_ROOT/meta-case.XXXXXX") || return 1
  fm_write_meta "$dir/$id.meta" "$@"
  printf '%s\n' "$dir/$id.meta"
}

test_paseo_endpoint_validation_accepts_a_consistent_record() {
  local meta id=paseo-ok
  meta=$(paseo_meta "$id" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=$id" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=$PASEO_TERM")
  fm_backend_validate_task_endpoint "$meta" "$id" \
    || fail "a consistent paseo endpoint record should validate"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = paseo ] \
    || fail "validation should report paseo as the backend, got '$FM_BACKEND_VALIDATED_BACKEND'"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$PASEO_WS:$PASEO_TERM" ] \
    || fail "validation should report the composite workspace:terminal target, got '$FM_BACKEND_VALIDATED_TARGET'"
  [ "$(fm_backend_of_meta "$meta")" = paseo ] \
    || fail "fm_backend_of_meta should read backend=paseo from the record"
  [ "$(fm_backend_target_of_meta "$meta")" = "$PASEO_WS:$PASEO_TERM" ] \
    || fail "fm_backend_target_of_meta should return the recorded window= composite for paseo"
  pass "paseo endpoint validation: a consistent record validates and resolves to its composite workspace:terminal target"
}

# assert_paseo_refusal <case-name> <expect-substring> <meta lines...>
assert_paseo_refusal() {
  local case_name=$1 expect=$2 meta out rc id=paseo-bad
  shift 2
  meta=$(paseo_meta "$id" "$@")
  set +e
  out=$(fm_backend_validate_task_endpoint "$meta" "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "paseo validation should refuse: $case_name"
  assert_contains "$out" "$expect" "the $case_name refusal did not name the problem"
  assert_contains "$out" "preserving task state" \
    "the $case_name refusal must say task state is preserved"
}

test_paseo_endpoint_validation_refuses_malformed_records() {
  # Each case is one way a paseo record can be wrong. Every one must REFUSE and
  # say it is preserving task state, because the caller's next step is teardown.
  # Paseo terminal ids are opaque UUIDs that do not encode the task label, so
  # the endpoint_task_id binding is the ONLY thing tying a record to its task.
  assert_paseo_refusal missing-binding "lacks an exact task binding" \
    "window=$PASEO_WS:$PASEO_TERM" "worktree=/tmp/wt" "project=/tmp/proj" \
    "backend=paseo" "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=$PASEO_TERM"

  assert_paseo_refusal foreign-binding "belongs to task some-other-task" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=some-other-task" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=$PASEO_TERM"

  assert_paseo_refusal missing-workspace "malformed or inconsistent" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=paseo-bad" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_terminal_id=$PASEO_TERM"

  assert_paseo_refusal missing-terminal "malformed or inconsistent" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=paseo-bad" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS"

  # The composite target and its parts disagree: exactly what a truncated or
  # hand-edited record looks like, and the reason both parts are recorded.
  assert_paseo_refusal composite-mismatch "malformed or inconsistent" \
    "window=$PASEO_WS:99999999-9999-9999-9999-999999999999" "endpoint_task_id=paseo-bad" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=$PASEO_TERM"

  assert_paseo_refusal unsafe-atom "malformed or inconsistent" \
    "window=$PASEO_WS:term;rm -rf /" "endpoint_task_id=paseo-bad" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=term;rm -rf /"

  assert_paseo_refusal ambiguous-workspace "malformed or inconsistent" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=paseo-bad" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_workspace_id=wks_other" \
    "paseo_terminal_id=$PASEO_TERM"

  pass "paseo endpoint validation: a missing, foreign, incomplete, mismatched, unsafe, or ambiguous record refuses and preserves task state"
}

test_paseo_endpoint_validation_refuses_before_any_runtime_call() {
  local dir meta fb id=paseo-inert rc
  # Validation is metadata-only, so a down or unreachable Paseo daemon can never
  # turn a valid cleanup record into a refusal, or the reverse. Proven by putting
  # a `paseo` on PATH that records the fact if it is ever executed.
  dir=$(mktemp -d "$TMP_ROOT/endpoint-inert.XXXXXX")
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/paseo" <<'TRIPWIRE'
#!/bin/sh
echo "paseo invoked: $*" >> "$FM_PASEO_TRIPWIRE"
exit 1
TRIPWIRE
  chmod +x "$fb/paseo"
  meta=$(paseo_meta "$id" \
    "window=$PASEO_WS:$PASEO_TERM" "endpoint_task_id=$id" \
    "worktree=/tmp/wt" "project=/tmp/proj" "backend=paseo" \
    "paseo_workspace_id=$PASEO_WS" "paseo_terminal_id=$PASEO_TERM")
  set +e
  PATH="$fb:$PATH" FM_PASEO_TRIPWIRE="$dir/tripwire" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" "$3"' \
    _ "$ROOT" "$meta" "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a valid paseo record should validate with no daemon reachable"
  [ ! -e "$dir/tripwire" ] || fail "paseo endpoint validation invoked a runtime command: $(cat "$dir/tripwire")"
  pass "paseo endpoint validation: decides entirely from durable metadata, never invoking Paseo"
}

test_paseo_is_known_but_not_spawn_capable
test_unknown_backend_still_refuses_and_names_paseo
test_paseo_required_tools_are_transport_independent
test_paseo_detect_markers
test_paseo_cli_is_not_a_detection_marker
test_paseo_detect_is_ordered_last
test_paseo_autodetect_notice_and_explicit_override
test_spawn_refuses_paseo_at_the_shared_boundary
test_paseo_endpoint_validation_accepts_a_consistent_record
test_paseo_endpoint_validation_refuses_malformed_records
test_paseo_endpoint_validation_refuses_before_any_runtime_call
