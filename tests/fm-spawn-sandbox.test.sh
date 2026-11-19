#!/usr/bin/env bash
# tests/fm-spawn-sandbox.test.sh - the worker sandbox launch seam in bin/fm-spawn.sh
# (bin/fm-sandbox-lib.sh, docs/configuration.md "Worker sandbox (config/sandbox)").
#
# The wrapper is a stub that records its argv and, for a real run, execs the
# command after `--`; no real sandbox is needed. The assertions
# drive the real spawn against a fake pane and a real git worktree and read what
# the pane was handed, never the script source.
#
# Load-bearing contracts:
#   1. No config/sandbox: nothing changes (no wrapper call, no record field, no
#      spool, the busy extension still runs fm-busy-event.sh).
#   2. A mapped ship or scout is wrapped at one seam: the agent segment only, with
#      the task binds and NEVER a writable state/ or FM_HOME; the OSC reporter,
#      the FM_TASK_INBOX export and the launch-env allowlist stay outside it.
#   3. enforce=off is a kill switch, on allows --sandbox off, strict refuses
#      both an unmapped spawn and --sandbox off.
#   4. A profile that applies is always enforced: a missing or old wrapper, an
#      unknown profile, a non-omp harness, a raw launch command refuses before
#      any record, worktree, or launch exists, and never launches raw.
#   5. The profile is recorded as sandbox=; --relaunch re-wraps with it.
#   6. A sandboxed omp extension reports through the relay spool, and the relay
#      turns that into the same busy-state a direct writer produces.
#   7. A secondmate is never sandboxed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-sandbox)
SPAWN="$ROOT/bin/fm-spawn.sh"

make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf '%s\n' '{"models":[]}' ;;
  *) printf 'FAKE_OMP_RAN comp=%s task=%s inbox=%s\n' "${COMPACT_ADVISER_DISABLE:-unset}" "${FM_TASK_ID:-unset}" "${FM_TASK_INBOX:-unset}" ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

# A wrapper that records every call, accepts every profile but unknown-profile,
# behaves like a wrapper without --profile under FM_FAKE_SANDBOX_MODE=old, and
# on a real (non dry-run) call execs the command after `--`.
make_fake_sandbox() {  # <fakebin>
  cat > "$1/worker-sandbox" <<'SH'
#!/usr/bin/env bash
{ printf 'CALL'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "${FM_FAKE_SANDBOX_LOG:-/dev/null}"
profile=
dry=0
prev=
for a in "$@"; do
  [ "$a" = -- ] && break
  [ "$prev" = --profile ] && profile=$a
  [ "$a" = --dry-run ] && dry=1
  prev=$a
done
if [ "${FM_FAKE_SANDBOX_MODE:-}" = old ] && [ -n "$profile" ]; then
  echo "worker-sandbox: unknown option --profile" >&2
  exit 2
fi
if [ "$profile" = unknown-profile ]; then
  echo "worker-sandbox: unknown profile $profile" >&2
  exit 2
fi
[ "$dry" = 0 ] || exit 0
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  chmod +x "$1/worker-sandbox"
}

# make_case <name> <id> -> "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch>|<pane>|<sandbox-log>"
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  make_fake_sandbox "$fakebin"
  fm_test_spawn_home "$home" omp
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log|$case_dir/sandbox.log"
}

read_case() {
  # shellcheck disable=SC2034 # the record shape is shared by every test
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG SB_LOG <<EOF
$1
EOF
  STATE_DIR=$(cd "$HOME_DIR/state" && pwd -P)
}

run_spawn() {  # <spawn args...>; uses the case globals
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  : > "$SB_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" FM_FAKE_SANDBOX_LOG="$SB_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# write_sandbox_config <lines...>: the fake wrapper is named unless a line already
# sets wrapper= (a case that needs a missing or relative wrapper).
write_sandbox_config() {
  case "$*" in
    *wrapper=*) printf '%s\n' "$@" > "$HOME_DIR/config/sandbox" ;;
    *) printf '%s\n' "wrapper=$FAKEBIN_DIR/worker-sandbox" "$@" > "$HOME_DIR/config/sandbox" ;;
  esac
}

# expect_refusal <out> <status> <needle> <id>: a refused spawn publishes no
# record and launches nothing, whatever the reason.
expect_refusal() {
  local out=$1 status=$2 needle=$3 id=$4
  expect_code 1 "$status" "spawn should refuse: $out"
  assert_contains "$out" "$needle" "the refusal did not name its reason: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must launch nothing, never raw: $(cat "$LAUNCH_LOG")"
}

# --- 1. Absent config -----------------------------------------------------------

test_absent_config_changes_nothing() {
  local id=sbx-none-a1 out status launch
  read_case "$(make_case none "$id")"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_code 0 "$status" "an unconfigured spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" worker-sandbox "an unconfigured launch must not name the wrapper"
  [ ! -s "$SB_LOG" ] || fail "an unconfigured spawn must not call the wrapper: $(cat "$SB_LOG")"
  assert_not_contains "$(cat "$STATE_DIR/$id.meta")" "sandbox=" "an unconfigured record must carry no sandbox field"
  assert_absent "$STATE_DIR/$id.sbx" "an unconfigured spawn must create no relay spool"
  assert_contains "$(cat "$STATE_DIR/$id.omp-ext.ts")" "fm-busy-event.sh" "the unsandboxed extension must keep its direct writer"
  pass "fm-spawn: no config/sandbox leaves the launch, record, and busy extension untouched"
}

# --- 2. The wrap ----------------------------------------------------------------

test_mapped_project_is_wrapped_at_the_seam() {
  local id=sbx-wrap-a1 out status launch s
  read_case "$(make_case wrap "$id")"
  write_sandbox_config 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_code 0 "$status" "a mapped spawn should succeed: $out"
  assert_contains "$out" " sandbox=strict" "the spawned line must report the profile: $out"
  s=$STATE_DIR
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/worker-sandbox' '--profile' 'strict' '--worktree' '$WT_DIR'" "the wrapper must lead with the profile and worktree"
  assert_contains "$launch" "'--rw-create' '$s/$id.status' '--rw-create' '$s/$id.turn-ended'" "status and turn-ended must be created-and-writable file binds"
  assert_contains "$launch" "'--ro' '$s/operational-inbox'" "the launch record must be read-only"
  assert_contains "$launch" "'--rw' '$s/$id.inbox'" "the steering inbox must be writable"
  assert_contains "$launch" "'--rw' '$HOME_DIR/data/$id'" "the task data directory must be writable"
  assert_contains "$launch" "'--ro' '$s/$id.omp-ext.ts'" "the busy extension must be read-only"
  assert_contains "$launch" "'--ro' '$ROOT'" "the code root must be read-only"
  assert_contains "$launch" "'--rw' '/tmp/fm-$id'" "the private temp root must be writable"
  assert_contains "$launch" "'--rw' '$s/$id.sbx/events'" "the relay spool must be the only writable state path"
  assert_contains "$launch" "'--host-helper' '$s/$id.sbx/relay-helper'" "the relay must start as the wrapper's helper"
  assert_contains "$launch" "'--env' 'COMPACT_ADVISER_DISABLE'" "the compact-adviser switch must reach the sandbox"
  assert_contains "$launch" ' -- env -u CLAUDECODE ' "the unchanged agent segment must follow the wrapper"
  assert_not_contains "$launch" "'--rw' '$s'" "state/ itself must never be writable"
  assert_not_contains "$launch" "'--rw' '$HOME_DIR'" "FM_HOME must never be writable"
  assert_not_contains "$launch" "'--ro' '$s'" "state/ itself must not be bound at all"
  assert_not_contains "$launch" "'--ro' '$HOME_DIR'" "FM_HOME must not be bound at all"
  # The seam: reporter arm, then the exports, then the wrapper; disarm after.
  case "$launch" in
    *"fm-osc7501.sh' arm"*worker-sandbox*"fm-osc7501.sh' disarm"*) ;;
    *) fail "the wrapper must sit between the reporter's arm and disarm: $launch" ;;
  esac
  assert_contains "$launch" "export FM_TASK_INBOX='$s/$id.inbox'" "the doorbell inbox export must stay outside the wrapper"
  case "${launch%%worker-sandbox*}" in
    *"export FM_TASK_INBOX="*) ;;
    *) fail "FM_TASK_INBOX must be exported before the wrapper starts" ;;
  esac
  assert_equals strict "$(sed -n 's/^sandbox=//p' "$s/$id.meta")" "the record must carry sandbox=strict"
  assert_present "$s/$id.sbx/relay-helper" "the relay helper must exist"
  [ -x "$s/$id.sbx/relay-helper" ] || fail "the relay helper must be executable"
  assert_contains "$(cat "$s/$id.sbx/relay-helper")" "--gen '$(cat "$s/$id.busy-gen")'" "the helper must pin the armed busy gen"
  assert_contains "$(cat "$SB_LOG")" '[--dry-run]' "the wrapper must be probed with --dry-run before any launch"
  pass "fm-spawn: a mapped scout is wrapped at the one seam with the task binds, never state/ or FM_HOME"
}

test_ship_kind_default_and_explicit_precedence() {
  local id=sbx-prec-a1 out launch
  read_case "$(make_case prec "$id")"
  write_sandbox_config 'default=generic' 'kind:ship=shipkind' 'project:other=elsewhere'
  out=$(run_spawn "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off)
  expect_code 0 $? "a kind-mapped ship spawn should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "'--profile' 'shipkind'" "kind:ship must beat default"
  assert_equals shipkind "$(sed -n 's/^sandbox=//p' "$STATE_DIR/$id.meta")" "ship record"

  id=sbx-prec-a2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --harness omp --scout)
  expect_code 0 $? "a default-mapped scout should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "'--profile' 'generic'" "default must apply to a kind it does not exclude"

  id=sbx-prec-a3
  fm_test_spawn_brief "$HOME_DIR" "$id"
  write_sandbox_config 'default=generic' 'project:project=projmap'
  out=$(run_spawn "$id" "$PROJ_DIR" --harness omp --scout --sandbox explicit)
  expect_code 0 $? "an explicit profile should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'--profile' 'explicit'" "--sandbox must beat the project mapping"
  assert_not_contains "$launch" "'--profile' 'projmap'" "the mapped profile must not also apply"
  pass "fm-spawn: explicit --sandbox beats project, which beats kind, which beats default"
}

test_launch_env_allowlist_composes() {
  local id=sbx-env-a1 out launch seen
  read_case "$(make_case env "$id")"
  write_sandbox_config 'project:project=strict'
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  expect_code 0 $? "sandbox plus allowlist should spawn: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '/usr/bin/env -i' "the allowlist must still clear the environment"
  case "$launch" in
    *"/bin/sh -c "*worker-sandbox*) ;;
    *) fail "the wrapper must sit inside the allowlist's sh -c: $launch" ;;
  esac
  # Execute what the pane would: the stub wrapper runs the fake omp under the
  # cleared environment, so the doorbell and task vars must still arrive.
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$PANE_LOG")
$launch" 2>&1) || fail "the emitted launch failed to run: $seen"
  assert_contains "$seen" "FAKE_OMP_RAN comp=1 task=$id inbox=$STATE_DIR/$id.inbox" \
    "the sandboxed agent must still receive the task marker, inbox, and switch through the cleared environment: $seen"
  pass "fm-spawn: launch-env-allowlist and the sandbox compose; the agent keeps its task variables"
}

# --- 3. Enforce levels ----------------------------------------------------------

test_enforce_levels() {
  local id out status
  read_case "$(make_case enforce sbx-enf-a1)"

  # off: the mapping is inactive, an explicit profile still applies.
  write_sandbox_config 'enforce=off' 'project:project=strict'
  id=sbx-enf-off
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  expect_code 0 $? "enforce=off should launch plain: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" worker-sandbox "enforce=off must not wrap a mapped project"
  assert_not_contains "$(cat "$STATE_DIR/$id.meta")" "sandbox=" "enforce=off must record nothing"
  id=sbx-enf-off2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox explicit)
  expect_code 0 $? "an explicit profile should apply under enforce=off: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "'--profile' 'explicit'" "an explicit profile applies whatever enforce says"

  # on: --sandbox off waives for one spawn and is recorded.
  write_sandbox_config 'enforce=on' 'project:project=strict'
  id=sbx-enf-on
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox off)
  expect_code 0 $? "enforce=on must allow --sandbox off: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" worker-sandbox "--sandbox off must launch plain"
  assert_equals off "$(sed -n 's/^sandbox=//p' "$STATE_DIR/$id.meta")" "a waiver must be recorded as sandbox=off"
  assert_contains "$out" " sandbox=off" "the spawned line must report the waiver: $out"

  # strict: refuses --sandbox off and an unmapped project, accepts a mapped one.
  write_sandbox_config 'enforce=strict' 'project:project=strict'
  id=sbx-enf-strict1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox off)
  status=$?
  expect_refusal "$out" "$status" "enforce=strict refuses --sandbox off" "$id"
  write_sandbox_config 'enforce=strict' 'project:elsewhere=strict'
  id=sbx-enf-strict2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "maps no profile for scout spawns of project" "$id"
  write_sandbox_config 'enforce=strict' 'default=strict'
  id=sbx-enf-strict3
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  expect_code 0 $? "a strict spawn with a default profile should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "'--profile' 'strict'" "strict plus default must wrap"
  pass "fm-spawn: enforce=off is a kill switch, on allows --sandbox off, strict refuses it and unmapped spawns"
}

test_malformed_config_refuses() {
  local id=sbx-bad-a1 out status body
  read_case "$(make_case bad "$id")"
  for body in 'enforce=maybe' 'bogus=1' 'default=' 'default=a b' 'project:=x' 'kind:secondmate=x' 'noequals' $'enforce=on\nenforce=strict'; do
    printf '%s\n' "$body" > "$HOME_DIR/config/sandbox"
    out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
    status=$?
    expect_refusal "$out" "$status" "config/sandbox" "$id"
  done
  printf '%s\n' '# comment' '' '  default = strict' > "$HOME_DIR/config/sandbox"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "unknown key 'default '" "$id"
  pass "fm-spawn: a malformed config/sandbox refuses the spawn instead of launching unsandboxed"
}

# --- 4. A profile that applies is always enforced -------------------------------

test_unusable_wrapper_refuses_without_a_raw_launch() {
  local id=sbx-ref-a1 out status
  read_case "$(make_case refuse "$id")"
  write_sandbox_config 'project:project=strict'

  # No wrapper named at all: an explicit profile has nothing to run, so it refuses.
  printf '%s\n' 'project:project=strict' > "$HOME_DIR/config/sandbox"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "names no wrapper" "$id"
  rm -f "$HOME_DIR/config/sandbox"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox strict)
  status=$?
  expect_refusal "$out" "$status" "names no wrapper" "$id"

  write_sandbox_config "wrapper=$TMP_ROOT/no-such-wrapper" 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "is not installed" "$id"

  write_sandbox_config 'wrapper=relative/worker-sandbox' 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "absolute path or a bare command name" "$id"

  write_sandbox_config 'project:project=strict'
  out=$(FM_FAKE_SANDBOX_MODE=old run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "does not accept --profile strict" "$id"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox unknown-profile)
  status=$?
  expect_refusal "$out" "$status" "does not accept --profile unknown-profile" "$id"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox 'bad profile')
  status=$?
  expect_refusal "$out" "$status" "invalid profile" "$id"

  # A refusal under strict is the same refusal; the escape hatch is enforce=on.
  write_sandbox_config "wrapper=$TMP_ROOT/no-such-wrapper" 'enforce=strict' 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_refusal "$out" "$status" "is not installed" "$id"

  # enforce=on lets --sandbox off through even with the wrapper missing.
  write_sandbox_config "wrapper=$TMP_ROOT/no-such-wrapper" 'enforce=on' 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp --sandbox off)
  expect_code 0 $? "--sandbox off must not need the wrapper: $out"
  pass "fm-spawn: a missing, unnamed, old, or profile-ignorant wrapper refuses and never launches raw"
}

test_unsupported_shapes_refuse() {
  local id=sbx-shape-a1 out status
  read_case "$(make_case shape "$id")"
  write_sandbox_config 'project:project=strict'

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness claude)
  status=$?
  expect_refusal "$out" "$status" "wraps only the omp harness" "$id"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout "$FAKEBIN_DIR/omp --help")
  status=$?
  expect_refusal "$out" "$status" "cannot wrap a raw launch command" "$id"

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness claude --sandbox off)
  expect_code 0 $? "--sandbox off must let a non-omp harness through under enforce=on: $out"
  pass "fm-spawn: a non-omp harness and a raw launch command refuse while a profile applies"
}

test_secondmate_is_never_sandboxed() {
  local out status sm id=sbx-sm-a1
  read_case "$(make_case sm "$id")"
  write_sandbox_config 'enforce=strict' 'default=strict'
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_spawn "$id" "$sm" --secondmate --harness omp)
  status=$?
  expect_code 0 "$status" "a strict config must not touch a secondmate spawn: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" worker-sandbox "a secondmate must launch unwrapped"
  assert_not_contains "$(cat "$STATE_DIR/$id.meta")" "sandbox=" "a secondmate record must carry no sandbox field"
  out=$(run_spawn "$id" "$sm" --secondmate --harness omp --sandbox strict)
  status=$?
  expect_code 1 "$status" "--sandbox on a secondmate must refuse: $out"
  assert_contains "$out" "a secondmate holds fleet state and never runs sandboxed" "the refusal must say why"
  pass "fm-spawn: a secondmate is never sandboxed, even under enforce=strict, and refuses --sandbox"
}

# --- 5. Relaunch ----------------------------------------------------------------

# A task whose agent is gone (zsh in the pane) and whose record names a profile.
make_relaunch_stub() {  # <dir>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'zsh\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

test_relaunch_rewraps_with_the_recorded_profile() {
  local id=sbx-rl-a1 dir home fakebin proj wt out status launch gen_before gen_after s
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" claude)
  make_fake_omp "$fakebin"
  make_fake_sandbox "$fakebin"
  make_relaunch_stub "$fakebin"
  fm_test_spawn_home "$home" omp
  fm_git_worktree "$proj" "$wt" "wt-relaunch"
  fm_test_spawn_brief "$home" "$id"
  s=$(cd "$home/state" && pwd -P)
  mkdir -p "$dir/fake-state"
  printf '%s\n' "fm-$id" > "$dir/fake-state/windows"
  printf '%s' "$wt" > "$dir/fake-state/cwd"
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=omp"
    echo "kind=scout"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "sandbox=strict"
  } > "$home/state/$id.meta"
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$s" "$id")
  : > "$dir/fake-state/literal"
  : > "$dir/sandbox.log"
  # The relaunch takes its profile from the record, whatever config/sandbox now
  # maps; the config supplies only the wrapper.
  printf '%s\n' "wrapper=$fakebin/worker-sandbox" > "$home/config/sandbox"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp 2>&1)
  status=$?
  expect_code 0 "$status" "a sandboxed relaunch should succeed: $out"
  launch=$(cat "$dir/fake-state/literal")
  assert_contains "$launch" "'--profile' 'strict' '--worktree' '$wt'" "the relaunch must re-wrap with the recorded profile: $launch"
  assert_contains "$launch" "'--host-helper' '$s/$id.sbx/relay-helper'" "the relaunch must start a relay"
  gen_after=$(cat "$s/$id.busy-gen")
  [ "$gen_after" != "$gen_before" ] || fail "a relaunch must arm a fresh busy gen"
  assert_contains "$(cat "$s/$id.sbx/relay-helper")" "--gen '$gen_after'" "the relaunch's relay must pin the NEW gen, not the old one"
  assert_equals strict "$(sed -n 's/^sandbox=//p' "$home/state/$id.meta")" "the relaunched record must keep sandbox=strict"

  # The wrapper comes from the current config/sandbox: with the file gone, a
  # recorded profile refuses to relaunch and never starts the worker raw.
  mv "$home/config/sandbox" "$dir/sandbox.saved"
  : > "$dir/fake-state/literal"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp 2>&1)
  expect_code 1 $? "a recorded profile with no wrapper configured must refuse: $out"
  assert_contains "$out" "names no wrapper" "the relaunch refusal must say why: $out"
  [ ! -s "$dir/fake-state/literal" ] || fail "a refused relaunch must launch nothing: $(cat "$dir/fake-state/literal")"
  assert_equals strict "$(sed -n 's/^sandbox=//p' "$home/state/$id.meta")" "a refused relaunch must keep the record"
  mv "$dir/sandbox.saved" "$home/config/sandbox"

  # A recorded waiver stays a waiver; --sandbox off waives a recorded profile;
  # a profile on --relaunch is refused.
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp --sandbox other 2>&1)
  expect_code 1 $? "a profile on --relaunch must refuse: $out"
  assert_contains "$out" "keeps the task's recorded sandbox" "the refusal must say why"
  : > "$dir/fake-state/literal"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp --sandbox off 2>&1)
  expect_code 0 $? "--sandbox off on a relaunch should succeed: $out"
  assert_not_contains "$(cat "$dir/fake-state/literal")" worker-sandbox "a waived relaunch must launch plain"
  assert_equals off "$(sed -n 's/^sandbox=//p' "$home/state/$id.meta")" "the waiver must be recorded"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp 2>&1)
  expect_code 0 $? "a relaunch after a waiver should succeed: $out"
  assert_equals off "$(sed -n 's/^sandbox=//p' "$home/state/$id.meta")" "a recorded waiver must stay a waiver"
  # A flagless relaunch is decided by its record alone: a broken config/sandbox
  # must not strand a task that does not use it.
  printf '%s\n' 'bogus=1' > "$home/config/sandbox"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake-state" TMUX=fake,1,0 FM_BACKEND=tmux \
    HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 FM_FAKE_SANDBOX_LOG="$dir/sandbox.log" \
    "$SPAWN" "$id" --relaunch --harness omp 2>&1)
  expect_code 0 $? "a flagless relaunch must not read a broken config/sandbox: $out"
  pass "fm-spawn: --relaunch re-wraps with the recorded profile and a fresh relay gen; --sandbox off is the only override"
}

# --- 6. Busy edge end to end ----------------------------------------------------

drive_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, {}); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, {}); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, {}); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
EOF
}

test_sandboxed_extension_reports_through_the_relay() {
  local id=sbx-busy-a1 out ext s events n
  read_case "$(make_case busy "$id")"
  write_sandbox_config 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  expect_code 0 $? "a sandboxed spawn should succeed: $out"
  s=$STATE_DIR
  ext="$s/$id.omp-ext.ts"
  events="$s/$id.sbx/events"
  assert_not_contains "$(cat "$ext")" "fm-busy-event.sh" "a sandboxed extension must not run the state writer"
  assert_contains "$(cat "$ext")" "$events" "a sandboxed extension must write into the relay spool"
  [ "$(fm_busy_classify tmux w omp "$id" "$s")" = "busy fm-spawn" ] || fail "spawn must seed the busy record"

  drive_ext "$ext" end-continuing >/dev/null || fail "continuing agent_end drive failed"
  n=$(find "$events" -type f -name '*.json' | wc -l)
  [ "$n" = 0 ] || fail "agent_end with willContinue must emit no edge, got $n"
  drive_ext "$ext" agent-start >/dev/null || fail "agent_start drive failed"
  drive_ext "$ext" end-final >/dev/null || fail "agent_end drive failed"
  n=$(find "$events" -type f -name '*.json' | wc -l)
  [ "$n" = 2 ] || fail "two edges must be spooled, got $n"
  [ -z "$(find "$events" -name '.*' -print -quit)" ] || fail "the extension must rename its temporary file into place"

  "$ROOT/bin/fm-sandbox-relay.sh" once --state "$s" --id "$id" --gen "$(cat "$s/$id.busy-gen")" --events "$events" \
    || fail "relay pass failed"
  [ "$(fm_busy_classify tmux w omp "$id" "$s")" = "idle omp-ext" ] || fail "the relayed edges must end idle omp-ext: $(cat "$s/$id.busy-state")"
  pass "fm-spawn: the sandboxed omp extension spools its edges and the relay applies them to the busy record"
}

# The pane shell may be zsh, which does not word-split an unquoted expansion:
# run the generated wrapper prefix under every available shell and require the
# optional env names to reach the wrapper as separate argv words (or not at all).
test_optional_env_words_survive_zsh_and_bash() {
  local id=sbx-shell-a1 out status launch prefix sh calls ran=0
  read_case "$(make_case shell "$id")"
  write_sandbox_config 'project:project=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_code 0 "$status" "a mapped spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  prefix="${launch%% -- env -u*}"
  prefix="'$FAKEBIN_DIR/worker-sandbox'${prefix#*"'$FAKEBIN_DIR/worker-sandbox'"}"
  [ "$prefix" != "$launch" ] || fail "could not isolate the wrapper prefix: $launch"
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
    ran=$((ran + 1))
    : > "$SB_LOG"
    FM_FAKE_SANDBOX_LOG="$SB_LOG" PATH="$FAKEBIN_DIR:$PATH" GOTMPDIR=/tmp/gt TRACEPARENT=00-x "$sh" -c "$prefix -- true" \
      || fail "$sh: the wrapper prefix failed to run"
    calls=$(tail -n 1 "$SB_LOG")
    assert_contains "$calls" "[--env] [GOTMPDIR]" "$sh: GOTMPDIR must be two argv words"
    assert_contains "$calls" "[--env] [TRACEPARENT]" "$sh: TRACEPARENT must be two argv words"
    assert_not_contains "$calls" "LAVISH_AXI_HOST" "$sh: an unset name must not be passed"
    assert_not_contains "$calls" "[--env GOTMPDIR]" "$sh: the pair must never be one word"
  done
  [ "$ran" -gt 0 ] || fail "neither bash nor zsh was available to run the wrapper prefix"
  pass "fm-spawn: optional env names reach the wrapper as separate words under bash and zsh"
}

# observed_launch <case-dir> <id>: everything the seam could touch, with the
# per-case directory and the per-spawn tokens (task temp hash, generation ids,
# staged-file stamps) normalized out.
observed_launch() {
  local norm="s#$1#<case>#g;s#+[0-9a-f]\{64\}#+<hash>#g;s#g[0-9]\{8,\}\.[0-9.]*#<gen>#g;s#\.s[0-9]\{8,\}\.[0-9.]*\.sh#.<stamp>.sh#g"
  sed "$norm" "$LAUNCH_LOG" "$PANE_LOG"
  sed "$norm;/^spawn_gen=/d;/^busy_gen=/d" "$STATE_DIR/$2.meta"
  sed "$norm" "$STATE_DIR/$2.omp-ext.ts"
}

# With no config/sandbox the launch, the task record, and the busy extension are
# exactly what a present-but-inactive config (enforce=off, with a wrapper and a
# mapping on file) produces: the seam leaves no byte of its own behind. Both
# runs use one task id.
test_default_launch_is_byte_identical() {
  local id=sbx-same-a1 out status
  read_case "$(make_case same1 "$id")"
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_code 0 "$status" "the baseline spawn should succeed: $out"
  observed_launch "$CASE_DIR" "$id" > "$CASE_DIR/observed.txt"
  [ -s "$CASE_DIR/observed.txt" ] || fail "the baseline recorded nothing"
  cp "$CASE_DIR/observed.txt" "$TMP_ROOT/observed-baseline.txt"
  # The unsandboxed extension is what it always was: its transport is spliced in
  # without a stray blank line, and no relay spool code is present.
  ! grep -q '^$' "$STATE_DIR/$id.omp-ext.ts" || fail "the default busy extension gained a blank line"
  assert_not_contains "$(cat "$STATE_DIR/$id.omp-ext.ts")" "renameSync" "the default busy extension must not carry the relay transport"

  read_case "$(make_case same2 "$id")"
  write_sandbox_config 'enforce=off' 'default=strict'
  out=$(run_spawn "$id" "$PROJ_DIR" --scout --harness omp)
  status=$?
  expect_code 0 "$status" "the inactive-config spawn should succeed: $out"
  observed_launch "$CASE_DIR" "$id" > "$CASE_DIR/observed.txt"
  cmp -s "$TMP_ROOT/observed-baseline.txt" "$CASE_DIR/observed.txt" \
    || fail "an inactive config/sandbox changed the launch, record, or extension: $(diff "$TMP_ROOT/observed-baseline.txt" "$CASE_DIR/observed.txt")"
  assert_absent "$STATE_DIR/$id.sbx" "an inactive config must create no relay spool"
  pass "fm-spawn: the launch, task record, and busy extension are byte-identical with no config/sandbox"
}

test_absent_config_changes_nothing
test_mapped_project_is_wrapped_at_the_seam
test_ship_kind_default_and_explicit_precedence
test_launch_env_allowlist_composes
test_enforce_levels
test_malformed_config_refuses
test_unusable_wrapper_refuses_without_a_raw_launch
test_unsupported_shapes_refuse
test_secondmate_is_never_sandboxed
test_relaunch_rewraps_with_the_recorded_profile
test_sandboxed_extension_reports_through_the_relay
test_default_launch_is_byte_identical
test_optional_env_words_survive_zsh_and_bash

echo "all fm-spawn-sandbox tests passed"
