#!/usr/bin/env bash
# tests/fm-trace-context-spawn.test.sh - spawn-path integration regressions for
# native W3C trace context using fake tmux panes and real isolated git worktrees.
# See docs/verification/trace-context.md for the maintained coverage inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-trace-context-spawn)

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise trace propagation for $2.

## Firstmate spec
Verify the spawned process receives the expected trace context.
EOF
}

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# argument (the GOTMPDIR export, the TRACEPARENT export, and the launch command)
# one per line, in send order, so ordering is observable.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_DUPLICATE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ "${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" = 1 ]; then
      for a in "$@"; do
        case "$a" in
          "export TRACEPARENT="*) exit 1 ;;
        esac
      done
    fi
    if [ "${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" = 1 ]; then
      for a in "$@"; do
        case "$a" in
          "export TRACEPARENT="*) exit 2 ;;
        esac
      done
    fi
    if [ "${FM_FAKE_TRACE_METADATA_APPEND_FAIL:-0}" = 1 ]; then
      for a in "$@"; do
        case "$a" in
          "export TRACEPARENT="*)
            chmod a-w "$FM_FAKE_META_PATH"
            ;;
        esac
      done
    fi
    # Capture the text payload of both send forms: the literal launch
    # (`send-keys -t <target> -l <text>`) and a text line
    # (`send-keys -t <target> <text> Enter`). Skip the flags, the target, and
    # the trailing key so only the payload is logged, one per line, in order.
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  write_ship_brief "$home/data/$id/brief.md" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

# Hermetic against an ambient FM_TRACE_CONTEXT: `env -u` unsets it so enablement
# is decided ONLY by the home's config/trace-context, whether the runner's own
# environment enables or disables trace context.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$home/user-home"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TRACEPARENT_SEND_FAIL="${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" \
    FM_FAKE_TRACEPARENT_SEND_UNSAFE="${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" \
    FM_FAKE_TRACE_METADATA_APPEND_FAIL="${FM_FAKE_TRACE_METADATA_APPEND_FAIL:-0}" \
    FM_FAKE_META_PATH="$home/state/$1.meta" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# Same, but with an explicit FM_TRACE_CONTEXT override, to prove the env decides.
run_spawn_tc() {
  local tc=$1 home=$2 wt=$3 fakebin=$4 launchlog=$5
  shift 5
  : > "$launchlog"
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$home/user-home"
  env FM_TRACE_CONTEXT="$tc" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

start_trace_session() {
  local home=$1 tc=${2-}
  printf '%s\n' "$$" > "$home/state/.lock"
  if [ -n "$tc" ]; then
    FM_TRACE_CONTEXT="$tc" fm_trace_context_session_start \
      "$home/config" "$home/state/.trace-context-effective"
  else
    (
      unset FM_TRACE_CONTEXT
      fm_trace_context_session_start \
        "$home/config" "$home/state/.trace-context-effective"
    )
  fi
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

meta_traceparent() { sed -n 's/^traceparent=//p' "$1"; }
injected_traceparent() { sed -n 's/^export TRACEPARENT=//p' "$1"; }

# Two-level primary -> secondmate -> worker regression for the FM_TRACE_CONTEXT
# effective override. Drives bin/fm-spawn.sh TWICE against real homes and a real
# worktree: first the primary launches a secondmate (capturing the exact env the
# primary injects into it), then that secondmate launches its OWN worker with
# exactly that inherited env, reading the secondmate home's own inherited config.
# This is what proves the primary's effective on/off decision - not only the
# copied config/trace-context file - governs the nested worker, which a
# single-home spawn test cannot reach. Sets TL_ENV_TC, TL_CARRIER, TL_WORKER_TP,
# and TL_SM_FILE for the caller.
#   run_two_level <name> <present|absent primary file> <on|off primary env>
run_two_level() {
  local name=$1 pfile=$2 penv=$3
  local base prim sm sm_id smlog smfake worker_id wproj wwt wlog wfake
  base="$TMP_ROOT/2level-$name"
  prim="$base/primary"
  sm="$base/sm"
  mkdir -p "$prim/config" "$prim/data" "$prim/state" "$prim/projects"
  printf 'claude\n' > "$prim/config/crew-harness"
  [ "$pfile" = present ] && : > "$prim/config/trace-context"
  touch "$prim/state/.last-watcher-beat"
  start_trace_session "$prim" "$penv"

  # Seed the secondmate home so validate_firstmate_home_for_spawn accepts it.
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-%s\n' "$name" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"

  # Spawn 1: the primary launches the secondmate; capture what it injects.
  sm_id="sm-$name"
  mkdir -p "$prim/data/$sm_id"
  printf 'charter brief\n' > "$prim/data/$sm_id/brief.md"
  smlog="$base/sm-launch.log"
  smfake=$(make_spawn_fakebin "$base/sm-fake")
  : > "$smlog"
  env FM_TRACE_CONTEXT="$penv" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 CLAUDECODE=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$smlog" PATH="$smfake:$PATH" \
    "$SPAWN" "$sm_id" "$sm" --secondmate >/dev/null 2>&1 || true

  # Extract the EXACT env the primary put on the secondmate: the normalized
  # FM_TRACE_CONTEXT in the launch prefix, and the TRACEPARENT carrier (if any).
  TL_ENV_TC=$(grep -o 'FM_TRACE_CONTEXT=[a-z]*' "$smlog" | head -1 | cut -d= -f2)
  TL_CARRIER=$(injected_traceparent "$smlog" | head -1)

  # Spawn 2: the secondmate launches its own worker with exactly that inherited
  # env, reading the secondmate home's own (inherited) config.
  worker_id="w-$name"
  wproj="$base/wproj"
  wwt="$base/wwt"
  fm_git_worktree "$wproj" "$wwt" "wt-$name"
  mkdir -p "$sm/state" "$sm/projects" "$sm/data/$worker_id"
  write_ship_brief "$sm/data/$worker_id/brief.md" "$worker_id"
  touch "$sm/state/.last-watcher-beat"
  start_trace_session "$sm" "$TL_ENV_TC"
  wlog="$base/worker-launch.log"
  wfake=$(make_spawn_fakebin "$base/w-fake")
  : > "$wlog"
  mkdir -p "$sm/user-home"
  env FM_TRACE_CONTEXT="$TL_ENV_TC" TRACEPARENT="$TL_CARRIER" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$sm" HOME="$sm/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$sm/state" FM_DATA_OVERRIDE="$sm/data" \
    FM_PROJECTS_OVERRIDE="$sm/projects" FM_CONFIG_OVERRIDE="$sm/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wwt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$wlog" PATH="$wfake:$PATH" \
    "$SPAWN" "$worker_id" "$wproj" --mode no-mistakes --yolo off >/dev/null 2>&1 || true

  TL_WORKER_TP=$(meta_traceparent "$sm/state/$worker_id.meta")
  TL_SM_FILE=absent
  [ -f "$sm/config/trace-context" ] && TL_SM_FILE=present
}

test_enabled_records_and_injects_identical_carrier_before_launch() {
  local rec out status meta mtp itp gl tl ll
  rec=$(make_spawn_case tc-on)
  read_case_record "$rec"
  : > "$HOME_DIR/config/launch-env-allowlist"
  : > "$HOME_DIR/config/trace-context"   # enable via the real config path
  start_trace_session "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "enabled trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "enabled spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  jq -e --arg id "$CASE_ID" '
    .schema == "fm-secondmate-home-summary.v1"
    and any(.endpoints[]; .id == $id)
  ' "$HOME_DIR/state/home-summary.json" >/dev/null \
    || fail "successful task spawn did not publish the task in the home summary ledger"

  mtp=$(meta_traceparent "$meta")
  fm_trace_context_valid "$mtp" || fail "enabled spawn must record a valid traceparent= in meta (got '$mtp')"
  itp=$(injected_traceparent "$LAUNCH_LOG")
  fm_trace_context_valid "$itp" || fail "enabled spawn must inject a valid TRACEPARENT export (got '$itp')"
  [ "$mtp" = "$itp" ] || fail "the recorded and injected carriers must be identical (meta='$mtp' injected='$itp')"

  gl=$(grep -n '^export GOTMPDIR=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  tl=$(grep -n '^export TRACEPARENT=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  ll=$(grep -n 'claude' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  [ -n "$gl" ] && [ -n "$tl" ] && [ -n "$ll" ] || fail "launch log missing GOTMPDIR/TRACEPARENT/launch lines"
  [ "$tl" -gt "$gl" ] || fail "TRACEPARENT export must ride the GOTMPDIR pre-launch site (gotmp=$gl tp=$tl)"
  [ "$tl" -lt "$ll" ] || fail "TRACEPARENT export must be sent before the launch literal (tp=$tl launch=$ll)"
  pass "enabled: one resolved carrier is recorded in meta and the identical TRACEPARENT is exported before launch"
}

test_disabled_writes_and_injects_neither() {
  local rec out status meta
  rec=$(make_spawn_case tc-off)
  read_case_record "$rec"
  # No config/trace-context and no FM_TRACE_CONTEXT: default-off.

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "default-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  # Anchored regex checks (the assert_grep helpers are fixed-string).
  ! grep -q '^traceparent=' "$meta" || fail "default-off spawn must not write a traceparent= line to meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "default-off spawn must not inject a TRACEPARENT export"
  grep -q '^export GOTMPDIR=' "$LAUNCH_LOG" || fail "the spawn should still run (GOTMPDIR is always injected)"
  pass "disabled: neither traceparent= in meta nor a TRACEPARENT export is produced"
}

test_failed_delivery_omits_metadata_and_still_launches() {
  local rec out status meta
  rec=$(make_spawn_case tc-send-failure)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACEPARENT_SEND_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "failed traceparent delivery must not abort spawn"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success after failed traceparent delivery"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  ! grep -q '^traceparent=' "$meta" \
    || fail "failed traceparent delivery must not leave a traceparent= claim in meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" \
    || fail "the failed TRACEPARENT export must not be recorded as delivered"
  grep -q 'claude' "$LAUNCH_LOG" || fail "the source task must still launch"
  pass "failed TRACEPARENT delivery omits metadata while the source task still launches"
}

test_unsafe_delivery_refuses_to_append_launch() {
  local rec out status
  rec=$(make_spawn_case tc-send-unsafe)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACEPARENT_SEND_UNSAFE=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "uncleared traceparent input must stop spawn"
  assert_contains "$out" "refusing to append the launch command" \
    "unsafe traceparent delivery should report why spawn stopped"
  ! grep -q 'claude' "$LAUNCH_LOG" \
    || fail "unsafe traceparent delivery must not append the launch command"
  pass "uncleared TRACEPARENT input stops before the launch command is appended"
}

test_failed_metadata_append_unsets_carrier_and_still_launches() {
  local rec out status meta
  rec=$(make_spawn_case tc-metadata-failure)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACE_METADATA_APPEND_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "failed traceparent metadata append must not abort spawn"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success after failed metadata append"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  ! grep -q '^traceparent=' "$meta" \
    || fail "failed metadata append must not leave a traceparent= claim in meta"
  grep -q '^unset TRACEPARENT; .*claude' "$LAUNCH_LOG" \
    || fail "failed metadata append must unset TRACEPARENT in the launch command"
  pass "failed traceparent metadata append removes the carrier from the launched task"
}

test_duplicate_secondmate_spawn_does_not_converge_trace_context() {
  local base prim sm id log fake out status
  base="$TMP_ROOT/duplicate-secondmate"
  prim="$base/primary"
  sm="$base/sm"
  # shellcheck disable=SC2100 # Literal task id, not arithmetic.
  id=sm-duplicate
  log="$base/launch.log"
  mkdir -p "$prim/config" "$prim/data/$id" "$prim/state" "$prim/projects"
  : > "$prim/config/trace-context"
  printf 'charter brief\n' > "$prim/data/$id/brief.md"
  touch "$prim/state/.last-watcher-beat"
  start_trace_session "$prim"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  fake=$(make_spawn_fakebin "$base/fake")

  out=$(env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 CLAUDECODE=1 TMUX="fake,1,0" \
    FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_LAUNCH_LOG="$log" \
    PATH="$fake:$PATH" "$SPAWN" "$id" "$sm" --secondmate 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "duplicate secondmate spawn should be refused"
  assert_contains "$out" "already exists" "duplicate secondmate spawn should report the existing endpoint"
  [ ! -e "$sm/config/trace-context" ] \
    || fail "duplicate preflight must not converge trace-context into the secondmate home"
  pass "duplicate secondmate preflight leaves trace-context unchanged"
}

test_relaunch_reuses_recorded_carrier() {
  local rec out status meta first second injected
  rec=$(make_spawn_case tc-relaunch)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "first trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "first spawn should report success"
  first=$(meta_traceparent "$meta")
  fm_trace_context_valid "$first" || fail "first spawn must record a valid carrier (got '$first')"

  # Relaunch the same task: the recorded carrier must be reused verbatim for both
  # the meta and the injected export, so an observer keeps one identity across
  # restarts.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "relaunch spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "relaunch spawn should report success"
  second=$(meta_traceparent "$meta")
  injected=$(injected_traceparent "$LAUNCH_LOG")
  [ "$second" = "$first" ] || fail "relaunch must reuse the recorded carrier in meta (first='$first' second='$second')"
  [ "$injected" = "$first" ] || fail "relaunch must inject the same recorded carrier (first='$first' injected='$injected')"
  pass "relaunch reuses the recorded carrier verbatim for both the meta record and the injected export"
}

test_session_start_freezes_env_override_and_ignores_later_edits() {
  local rec out status meta
  rec=$(make_spawn_case tc-envoff)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR" off
  out=$(run_spawn_tc on "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "env-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  ! grep -q '^traceparent=' "$meta" || fail "session-frozen off must ignore a later FM_TRACE_CONTEXT=on"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "session-frozen off must remain disabled after launch-time edits"

  rec=$(make_spawn_case tc-envon)
  read_case_record "$rec"
  start_trace_session "$HOME_DIR" on
  : > "$HOME_DIR/config/trace-context"
  out=$(run_spawn_tc off "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-on spawn should succeed"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  fm_trace_context_valid "$(meta_traceparent "$meta")" \
    || fail "session-frozen on must ignore a later FM_TRACE_CONTEXT=off"
  pass "session start freezes the env override and later config or environment edits do not alter spawns"
}

# End-to-end two-level enable path: the primary is enabled by the environment
# override with NO config file, and that enablement must reach the newly launched
# secondmate's own worker. Before the effective-override fix, the secondmate saw
# only the (absent) inherited file and left its worker untraced despite holding
# the delivered carrier. Enablement is what propagates; trace identity is not:
# the worker is a routed task with its own trace boundary, so it must root a
# fresh trace rather than adopt the Secondmate's carrier from the environment.
test_secondmate_env_on_file_absent_keeps_nested_worker_enabled() {
  run_two_level enable absent on
  [ "$TL_ENV_TC" = on ] || fail "the primary must deliver FM_TRACE_CONTEXT=on to the secondmate (got '$TL_ENV_TC')"
  fm_trace_context_valid "$TL_CARRIER" || fail "an enabled primary must mint a carrier for the secondmate (got '$TL_CARRIER')"
  fm_trace_context_valid "$TL_WORKER_TP" \
    || fail "env-on/file-absent must keep the nested worker enabled (got '$TL_WORKER_TP')"
  [ "${TL_CARRIER:3:32}" != "${TL_WORKER_TP:3:32}" ] \
    || fail "the nested worker must root its own trace, not adopt the Secondmate's trace id (secondmate='${TL_CARRIER:3:32}' worker='${TL_WORKER_TP:3:32}')"
  pass "two-level: env-on/file-absent keeps the nested worker enabled, rooting its own per-task trace"
}

# End-to-end two-level disable path: the primary is disabled by the environment
# override while the config file is PRESENT (so it is copied into the secondmate
# home). The override must still disable the secondmate's own worker, or
# FM_TRACE_CONTEXT=off is not a real kill switch. Before the fix the copied file
# re-enabled the nested worker.
test_secondmate_env_off_file_present_keeps_nested_worker_disabled() {
  run_two_level disable present off
  [ "$TL_ENV_TC" = off ] || fail "the primary must deliver FM_TRACE_CONTEXT=off to the secondmate (got '$TL_ENV_TC')"
  [ -z "$TL_CARRIER" ] || fail "a disabled primary must inject no carrier into the secondmate (got '$TL_CARRIER')"
  [ "$TL_SM_FILE" = present ] \
    || fail "the disable case must exercise a copied config/trace-context in the secondmate home (got '$TL_SM_FILE')"
  [ -z "$TL_WORKER_TP" ] \
    || fail "env-off must keep the nested worker disabled even with the file present (got '$TL_WORKER_TP')"
  pass "two-level: env-off/file-present keeps the nested worker disabled even though the config file was copied into the secondmate home"
}

# The trace boundary is each routed task, not the routing agent: a persistent
# Secondmate exports one TRACEPARENT into its process environment at its own
# launch, and later routed requests never replace that environment. Two
# unrelated tasks spawned sequentially from that one environment must root two
# distinct traces, and neither may adopt the Secondmate's own trace id, while
# each task still keeps one stable identity across its own relaunch.
test_two_routed_tasks_through_one_secondmate_root_distinct_traces() {
  local base sm fakebin sm_tp out status
  local id_a id_b proj_a proj_b wt_a wt_b log_a log_b
  local tp_a tp_b in_a in_b relaunch_tp relaunch_in
  base="$TMP_ROOT/routed-boundary"
  sm="$base/sm-home"
  mkdir -p "$sm/data" "$sm/projects" "$sm/state" "$sm/config"
  printf 'claude\n' > "$sm/config/crew-harness"
  : > "$sm/config/trace-context"
  printf '%s\n' "$$" > "$sm/state/.lock"
  touch "$sm/state/.last-watcher-beat"
  start_trace_session "$sm"
  # The Secondmate's own launch-time carrier: exported once into its pane shell
  # by the primary's spawn and inherited by every subprocess for the process's
  # whole life. Fixed here so any adoption of its trace id is unambiguous.
  sm_tp='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'
  fakebin=$(make_spawn_fakebin "$base/fake")

  id_a=routed-a-z1
  id_b=routed-b-z1
  proj_a="$base/proj-a"; wt_a="$base/wt-a"
  proj_b="$base/proj-b"; wt_b="$base/wt-b"
  fm_git_worktree "$proj_a" "$wt_a" wt-routed-a
  fm_git_worktree "$proj_b" "$wt_b" wt-routed-b
  mkdir -p "$sm/data/$id_a" "$sm/data/$id_b"
  write_ship_brief "$sm/data/$id_a/brief.md" "$id_a"
  write_ship_brief "$sm/data/$id_b/brief.md" "$id_b"
  log_a="$base/launch-a.log"
  log_b="$base/launch-b.log"

  out=$(TRACEPARENT="$sm_tp" run_spawn "$sm" "$wt_a" "$fakebin" "$log_a" "$id_a" "$proj_a")
  status=$?
  expect_code 0 "$status" "routed task A spawn should succeed"
  assert_contains "$out" "spawned $id_a" "routed task A spawn should report success"
  out=$(TRACEPARENT="$sm_tp" run_spawn "$sm" "$wt_b" "$fakebin" "$log_b" "$id_b" "$proj_b")
  status=$?
  expect_code 0 "$status" "routed task B spawn should succeed"
  assert_contains "$out" "spawned $id_b" "routed task B spawn should report success"

  tp_a=$(meta_traceparent "$sm/state/$id_a.meta")
  tp_b=$(meta_traceparent "$sm/state/$id_b.meta")
  in_a=$(injected_traceparent "$log_a")
  in_b=$(injected_traceparent "$log_b")
  fm_trace_context_valid "$tp_a" || fail "routed task A must record a valid carrier (got '$tp_a')"
  fm_trace_context_valid "$tp_b" || fail "routed task B must record a valid carrier (got '$tp_b')"
  [ "$in_a" = "$tp_a" ] || fail "task A's injected and recorded carriers must match (injected='$in_a' meta='$tp_a')"
  [ "$in_b" = "$tp_b" ] || fail "task B's injected and recorded carriers must match (injected='$in_b' meta='$tp_b')"
  [ "${tp_a:3:32}" != "${sm_tp:3:32}" ] \
    || fail "routed task A must not adopt the persistent Secondmate's trace id (got '$tp_a')"
  [ "${tp_b:3:32}" != "${sm_tp:3:32}" ] \
    || fail "routed task B must not adopt the persistent Secondmate's trace id (got '$tp_b')"
  [ "${tp_a:3:32}" != "${tp_b:3:32}" ] \
    || fail "two unrelated routed tasks must root distinct trace ids (A='$tp_a' B='$tp_b')"

  # Same environment, same task: a relaunch must reuse task A's recorded
  # carrier verbatim, so the per-task boundary never costs recovery identity.
  out=$(TRACEPARENT="$sm_tp" run_spawn "$sm" "$wt_a" "$fakebin" "$log_a" "$id_a" "$proj_a")
  status=$?
  expect_code 0 "$status" "routed task A relaunch should succeed"
  relaunch_tp=$(meta_traceparent "$sm/state/$id_a.meta")
  relaunch_in=$(injected_traceparent "$log_a")
  [ "$relaunch_tp" = "$tp_a" ] \
    || fail "task A's relaunch must keep its original carrier (first='$tp_a' relaunch='$relaunch_tp')"
  [ "$relaunch_in" = "$tp_a" ] \
    || fail "task A's relaunch must inject its original carrier (first='$tp_a' injected='$relaunch_in')"
  pass "two unrelated routed tasks through one persistent Secondmate root distinct traces, adopt nothing from its environment, and keep per-task identity across relaunch"
}

# Single-frozen-decision guarantee: for a secondmate spawn the recorded/injected
# carrier and the delivered FM_TRACE_CONTEXT snapshot are always derived from ONE
# effective decision, so they cannot disagree (no carrier paired with off, no
# off snapshot paired with a carrier). This drives the file-decided path
# (FM_TRACE_CONTEXT unset), which is exactly where the two-read correction matters
# because the environment override is empty and only the config file decides.
test_secondmate_carrier_and_snapshot_share_one_decision() {
  run_two_level fileon present ""
  [ "$TL_ENV_TC" = on ] || fail "a file-enabled secondmate must snapshot FM_TRACE_CONTEXT=on (got '$TL_ENV_TC')"
  fm_trace_context_valid "$TL_CARRIER" \
    || fail "a file-enabled secondmate's carrier must be present and valid, consistent with the on snapshot (got '$TL_CARRIER')"

  run_two_level fileoff absent ""
  [ "$TL_ENV_TC" = off ] || fail "a file-disabled secondmate must snapshot FM_TRACE_CONTEXT=off (got '$TL_ENV_TC')"
  [ -z "$TL_CARRIER" ] \
    || fail "a file-disabled secondmate must inject no carrier, consistent with the off snapshot (got '$TL_CARRIER')"
  pass "secondmate carrier and FM_TRACE_CONTEXT snapshot always agree, both derived from one frozen decision (file-decided path)"
}

test_enabled_records_and_injects_identical_carrier_before_launch
test_disabled_writes_and_injects_neither
test_failed_delivery_omits_metadata_and_still_launches
test_unsafe_delivery_refuses_to_append_launch
test_failed_metadata_append_unsets_carrier_and_still_launches
test_duplicate_secondmate_spawn_does_not_converge_trace_context
test_relaunch_reuses_recorded_carrier
test_session_start_freezes_env_override_and_ignores_later_edits
test_secondmate_env_on_file_absent_keeps_nested_worker_enabled
test_secondmate_env_off_file_present_keeps_nested_worker_disabled
test_two_routed_tasks_through_one_secondmate_root_distinct_traces
test_secondmate_carrier_and_snapshot_share_one_decision

echo "# all fm-trace-context-spawn tests passed"
