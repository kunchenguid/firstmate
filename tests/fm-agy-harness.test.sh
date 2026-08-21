#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
AGY_CONFIG="$ROOT/bin/fm-agy-config.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
AGY_RUNTIME_TASK_TMP=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_agy_harness() {
  [ -z "$AGY_RUNTIME_TASK_TMP" ] || rm -rf "$AGY_RUNTIME_TASK_TMP"
  fm_test_cleanup
}
trap cleanup_agy_harness EXIT

# agy's real rendered composer: content rows between two solid horizontal rules
# with a leading `>` prompt glyph, and a footer that swaps between `? for
# shortcuts` (idle) and `esc to cancel` (turn running). Captured live from
# agy 1.1.15 and reduced to the rows the classifier reads.
agy_screen() {  # <composer-text> <footer> [task-strip]
  printf '  Some transcript output.\n'
  printf '%s\n' "$(printf '─%.0s' $(seq 1 40))"
  printf '> %s\n' "$1"
  printf '%s\n' "$(printf '─%.0s' $(seq 1 40))"
  if [ -n "${3:-}" ]; then
    printf '  ● [00:41:11] sleep 40 && echo finished running\n'
    printf '%s\n' "$(printf '─%.0s' $(seq 1 40))"
  fi
  printf '%s                       Gemini 3.7 Flash · low\n' "$2"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)
rule() { printf '────────────────────────────────────────\n'; }
# agy is MID-TURN the moment it is up: the brief rode in on the launch command,
# so its composer sits under a busy footer. Nothing in the spawn path reads this
# pane - agy needs no post-launch delivery or readiness gate - but the pane a
# real launch produces is what the fake should show.
fake_screen() {
  case "$state" in
    running)
      rule; printf '> \n'; rule
      printf 'esc to cancel                    Gemini 3.7 Flash · low\n'
      ;;
    *) printf 'shell starting\n$ \n' ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    running) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev= literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *' -i '*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'LAUNCH\n' >> "$FM_FAKE_AGY_KEY_LOG"
          printf 'typed\n' > "$FM_FAKE_AGY_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        printf 'Enter\n' >> "$FM_FAKE_AGY_KEY_LOG"
        # The launch Enter starts agy; the NEXT Enter is the one that clears a
        # trust dialog, exactly as the real pane sequences them.
        case "$state" in
          typed) printf 'running\n' > "$FM_FAKE_AGY_STATE" ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/gemini/config"
  printf 'brief for agy\n' > "$home/data/$id/brief.md"
  printf 'agy\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/keys.log"
  : > "$case_dir/agy.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_AGY_CONFIG_DIR="$case_dir/gemini/config" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_AGY_KEY_LOG="$case_dir/keys.log" \
    FM_FAKE_AGY_STATE="$case_dir/agy.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --scout --harness agy "$@" 2>&1
}

# Enters delivered from the launch command onward. Everything before the LAUNCH
# marker is ordinary pre-launch pane setup (the GOTMPDIR export and friends),
# which every harness gets and which this adapter does not own.
post_launch_enters() {  # <case-dir>
  awk '/^LAUNCH$/ {seen = 1; next} seen && /^Enter$/ {n += 1} END {print n + 0}' \
    "$1/keys.log"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_agy_launch_shape_and_wiring() {
  local id rec out rc launch meta task_tmp token
  id="agy-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  AGY_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.7-flash-high --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "verified agy launch should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "'$FAKEBIN_DIR/agy' --dangerously-skip-permissions" \
    "agy launch did not use the absolute binary with autonomy"
  assert_contains "$launch" "--add-dir '$WT_DIR'" \
    "agy launch omitted the --add-dir binding its guarded hook needs"
  assert_contains "$launch" "--model 'gemini-3.7-flash-high' -i " \
    "agy launch did not pass the model then the interactive prompt flag"
  assert_not_contains "$launch" "--effort" "agy launch emitted an effort flag it must omit"
  assert_not_contains "$launch" " -p " "agy launch used headless print mode"
  assert_not_contains "$launch" "__TURNEND__" "agy launch retained a turn-end placeholder"
  assert_contains "$launch" "env -u CLAUDECODE" "agy launch did not clear foreign primary markers"
  assert_contains "$launch" "-u CURSOR_AGENT" "agy launch did not clear the cursor marker"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=agy' "$meta" "agy meta lost its harness"
  assert_grep 'model=gemini-3.7-flash-high' "$meta" "agy meta lost the requested model"
  assert_grep 'effort=xhigh' "$meta" "agy meta did not retain the unsupported effort axis"

  assert_grep 'token=' "$WT_DIR/.fm-agy-turnend" "agy spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.agy-turnend-token" "agy spawn did not record its token"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-agy-turnend")
  assert_present "$CASE_DIR/gemini/config/fm-agy-turn-end.d/$token" \
    "agy spawn did not mint its private registry entry"
  head -1 "$CASE_DIR/gemini/config/fm-agy-turn-end.d/$token" \
    | grep -Fq "/$id.turn-ended" \
    || fail "agy registry entry did not name this task's turn-end marker first"
  grep -Fqx "$id" "$CASE_DIR/gemini/config/fm-agy-turn-end.d/$token" \
    || fail "agy registry entry did not carry the task id"
  grep -Fqx "$(cat "$HOME_DIR/state/$id.busy-gen")" \
    "$CASE_DIR/gemini/config/fm-agy-turn-end.d/$token" \
    || fail "agy registry entry did not bind the armed busy generation"
  assert_grep 'firstmate-turn-end' "$CASE_DIR/gemini/config/hooks.json" \
    "agy spawn did not install its global hook"
  assert_present "$HOME_DIR/state/$id.busy-gen" "agy spawn did not arm the busy contract"
  pass "fm-spawn: agy launches interactively with --add-dir and registers guarded per-task wiring"
}

test_agy_secondmate_is_refused() {
  local home out rc
  home="$TMP_ROOT/secondmate/home"
  mkdir -p "$home/data/agy-sm" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/agy-sm/brief.md"
  rc=0
  out=$(HOME="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" agy-sm "$home" --harness agy --secondmate 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "agy was allowed to launch a secondmate"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal lacked its reason"

  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supports_kind agy scout || fail "agy should be a verified scout adapter"
  fm_control_harness_supports_kind agy ship || fail "agy should be a verified ship adapter"
  ! fm_control_harness_supports_kind agy secondmate \
    || fail "the control plane accepted an agy secondmate"
  pass "fm-spawn and the control plane both refuse an agy secondmate"
}

test_agy_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id=agy-missing-z4
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/agy"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing agy executable should refuse the spawn"
  assert_contains "$out" "agy executable not found on PATH" "missing agy diagnostic was not concrete"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "missing agy executable created a tmux container or pane"
  fi
  pass "fm-spawn: missing agy executable refuses before pane creation"
}

test_agy_teardown_removes_pointer_and_registry_token() {
  local id rec token
  id=agy-teardown-z5
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "agy spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-agy-turnend")

  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_AGY_CONFIG_DIR="$CASE_DIR/gemini/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "agy teardown failed"
  assert_absent "$WT_DIR/.fm-agy-turnend" "agy token pointer survived teardown"
  assert_absent "$CASE_DIR/gemini/config/fm-agy-turn-end.d/$token" \
    "agy registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.agy-turnend-token" "agy token state survived teardown"
  pass "fm-teardown: agy task pointer and registry token are removed"
}

test_agy_global_config_edit_is_surgical_idempotent_and_removable() {
  local dir config_dir hooks skills original_hooks original_skills once
  dir="$TMP_ROOT/config-surgery"
  config_dir="$dir/gemini/config"
  mkdir -p "$config_dir" "$dir/skills/no-mistakes"
  printf 'name: no-mistakes\n' > "$dir/skills/no-mistakes/SKILL.md"
  hooks="$config_dir/hooks.json"
  skills="$config_dir/skills.json"
  original_hooks="$dir/hooks.original"
  original_skills="$dir/skills.original"
  cat > "$hooks" <<'EOF'
{
  "captains-own": {
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "echo hi" } ] }
    ]
  }
}
EOF
  cat > "$skills" <<'EOF'
{
  "entries": [
    { "path": "/captain/skills" }
  ]
}
EOF
  cp "$hooks" "$original_hooks"
  cp "$skills" "$original_skills"

  HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install "$dir/skills" \
    || fail "agy config install refused a realistic shared config"
  assert_grep 'firstmate-turn-end' "$hooks" "install did not add the Firstmate hook key"
  assert_grep 'captains-own' "$hooks" "install dropped the captain's own hook key"
  assert_grep "$dir/skills" "$skills" "install did not declare the skills root"
  assert_grep '/captain/skills' "$skills" "install dropped the captain's own skills entry"
  assert_present "$config_dir/fm-agy-turn-end.sh" "install did not write the hook script"
  assert_present "$config_dir/fm-agy-turn-end.d" "install did not create the registry"

  once="$dir/hooks.once"
  cp "$hooks" "$once"
  HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install "$dir/skills" \
    || fail "second agy config install failed"
  cmp -s "$once" "$hooks" || fail "second agy config install changed hooks.json bytes"

  HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" remove "$dir/skills" \
    || fail "agy config removal failed"
  "$PYTHON_BIN" - "$hooks" "$original_hooks" "$skills" "$original_skills" <<'PY' \
    || fail "removal did not restore the captain's own configuration"
import json
import sys

for actual, expected in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    with open(actual) as a, open(expected) as b:
        if json.load(a) != json.load(b):
            raise SystemExit(1)
PY
  assert_absent "$config_dir/fm-agy-turn-end.sh" "removal left the Firstmate hook script"
  assert_absent "$config_dir/fm-agy-turn-end.d" "removal left the Firstmate registry"
  pass "agy global config install is surgical and idempotent, and removal restores captain content"
}

test_agy_global_config_fails_closed_on_unsafe_shared_files() {
  local dir config_dir out rc
  dir="$TMP_ROOT/config-unsafe"
  config_dir="$dir/gemini/config"
  mkdir -p "$config_dir"
  printf '{"broken"\n' > "$config_dir/hooks.json"
  cp "$config_dir/hooks.json" "$dir/before"
  rc=0
  out=$(HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed agy hooks.json was accepted"
  assert_contains "$out" "not valid JSON" "malformed refusal lacked its concrete reason"
  cmp -s "$dir/before" "$config_dir/hooks.json" || fail "malformed refusal changed hooks.json bytes"
  assert_absent "$config_dir/fm-agy-turn-end.sh" "malformed refusal wrote the hook script"

  printf '[]\n' > "$config_dir/hooks.json"
  rc=0
  out=$(HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-object agy hooks.json was accepted"
  assert_contains "$out" "non-object top-level value" "non-object refusal lacked its reason"

  rm -f "$config_dir/hooks.json"
  ln -s /nonexistent "$config_dir/hooks.json"
  rc=0
  out=$(HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked agy hooks.json was accepted"
  assert_contains "$out" "not a regular non-symlink file" "symlink refusal lacked its reason"
  pass "agy global config edits fail closed on malformed, non-object, and symlinked shared files"
}

# The guarded hook is the whole reason one global entry can be shared with the
# captain's own agy sessions. Drive it with real payloads: a registered
# workspace fires, and an unregistered one does not.
#
# Every invocation below runs the hook WITHOUT FM_AGY_CONFIG_DIR and under a HOME
# holding no agy config, because the real hook runs in whatever environment agy
# inherited from its pane rather than in firstmate's. Finding its registry anyway
# is the point: the installer bakes that path in.
test_agy_hook_requires_a_registered_workspace_token() {
  local dir config_dir hook registry token turnend state busy_gen payload rc out
  dir="$TMP_ROOT/hook-guard"
  config_dir="$dir/gemini/config"
  mkdir -p "$config_dir" "$dir/registered" "$dir/outsider" "$dir/state"
  HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" "$AGY_CONFIG" install "$dir/absent-skills" \
    2>/dev/null || fail "agy config install failed"
  hook="$config_dir/fm-agy-turn-end.sh"
  registry="$config_dir/fm-agy-turn-end.d"
  state="$dir/state"
  turnend="$state/hooked.turn-ended"
  busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" hooked) \
    || fail "could not arm a busy generation for the hook test"
  token=fm.aaaaaaaaaaaa
  printf '%s\n%s\n%s\n%s\n%s\n' "$turnend" "$ROOT/bin/fm-busy-event.sh" \
    "$state" hooked "$busy_gen" > "$registry/$token"
  printf 'token=%s\n' "$token" > "$dir/registered/.fm-agy-turnend"

  payload=$(printf '{"fullyIdle":true,"workspacePaths":["%s"]}' "$dir/outsider")
  rc=0
  out=$(printf '%s' "$payload" | env -u FM_AGY_CONFIG_DIR HOME="$dir/no-agy-config" \
    PATH="$(dirname "$JQ_BIN"):$BASE_PATH" bash "$hook" idle 2>&1) || rc=$?
  expect_code 0 "$rc" "the agy hook must always exit zero"
  [ -z "$out" ] || fail "the agy hook printed output for an unregistered workspace: $out"
  assert_absent "$turnend" "an unregistered workspace fired this task's turn-end marker"

  payload=$(printf '{"fullyIdle":true,"workspacePaths":["%s"]}' "$dir/registered")
  printf '%s' "$payload" | env -u FM_AGY_CONFIG_DIR HOME="$dir/no-agy-config" \
    PATH="$(dirname "$JQ_BIN"):$BASE_PATH" bash "$hook" idle >/dev/null 2>&1 \
    || fail "the agy hook must always exit zero"
  assert_present "$turnend" "a registered workspace did not fire the turn-end marker"
  assert_grep 'state=idle source=agy-hook' "$state/hooked.busy-state" \
    "a registered idle Stop did not record the semantic idle event"

  # A mid-turn Stop carries fullyIdle=false and must publish nothing.
  rm -f "$turnend"
  printf '%s' "$ROOT" >/dev/null
  payload=$(printf '{"fullyIdle":false,"workspacePaths":["%s"]}' "$dir/registered")
  printf '%s' "$payload" | env -u FM_AGY_CONFIG_DIR HOME="$dir/no-agy-config" \
    PATH="$(dirname "$JQ_BIN"):$BASE_PATH" bash "$hook" idle >/dev/null 2>&1 \
    || fail "the agy hook must always exit zero"
  assert_absent "$turnend" "a mid-turn Stop fired the turn-end marker"

  payload=$(printf '{"workspacePaths":["%s"]}' "$dir/registered")
  printf '%s' "$payload" | env -u FM_AGY_CONFIG_DIR HOME="$dir/no-agy-config" \
    PATH="$(dirname "$JQ_BIN"):$BASE_PATH" bash "$hook" busy >/dev/null 2>&1 \
    || fail "the agy hook must always exit zero"
  assert_grep 'state=busy source=agy-hook' "$state/hooked.busy-state" \
    "a registered PreInvocation did not record the semantic busy event"

  # A payload with no workspace at all - agy's shape when --add-dir is absent.
  rm -f "$turnend"
  printf '{"fullyIdle":true,"workspacePaths":[]}' | env -u FM_AGY_CONFIG_DIR HOME="$dir/no-agy-config" \
    PATH="$(dirname "$JQ_BIN"):$BASE_PATH" bash "$hook" idle >/dev/null 2>&1 \
    || fail "the agy hook must always exit zero"
  assert_absent "$turnend" "an empty workspacePaths payload fired the turn-end marker"
  pass "the agy global hook fires only for a registered workspace token and only when fully idle"
}

# The skills declaration is the whole reason a crewmate can run no-mistakes at
# all, and it is legitimately skipped when the user-level root does not exist.
# What must never happen is skipping it in silence.
test_agy_config_reports_a_skipped_skills_root() {
  local dir out id rec
  dir="$TMP_ROOT/skills-missing"
  mkdir -p "$dir/gemini/config"
  out=$(HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" \
    "$AGY_CONFIG" install "$dir/absent-skills" 2>&1 >/dev/null) \
    || fail "a missing skills root must not fail the install"
  assert_contains "$out" "$dir/absent-skills" "the skipped skills declaration did not name the root"
  assert_contains "$out" "no-mistakes" "the skipped skills warning did not say what it costs"
  assert_absent "$dir/gemini/config/skills.json" "a missing skills root still wrote skills.json"
  assert_present "$dir/gemini/config/fm-agy-turn-end.sh" \
    "the skipped skills declaration also skipped the hook half of the install"

  mkdir -p "$dir/real-skills"
  out=$(HOME="$dir" FM_AGY_CONFIG_DIR="$dir/gemini/config" \
    "$AGY_CONFIG" install "$dir/real-skills" 2>&1 >/dev/null) \
    || fail "install with a present skills root failed"
  [ -z "$out" ] || fail "install warned about a skills root that exists: $out"

  # And fm-spawn must not swallow it: these homes have no ~/.agents/skills.
  id=agy-skills-warn-z5b
  rec=$(make_spawn_case skills-warn "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") \
    || fail "agy spawn should still succeed with no user skills root"
  assert_contains "$out" "skipped the agy skills declaration" \
    "fm-spawn swallowed the warning that its agy crewmate cannot see no-mistakes"
  pass "fm-agy-config names a skipped skills root, and fm-spawn passes that warning through"
}

# --help is the script's own generated output contract: its header prose and
# nothing past it.
test_agy_config_help_stops_at_the_end_of_its_header() {
  local out
  out=$("$AGY_CONFIG" --help) || fail "fm-agy-config.sh --help exited non-zero"
  assert_contains "$out" "Install or remove Firstmate's global Antigravity CLI" \
    "--help did not print its header prose"
  assert_contains "$out" "fm-agy-config.sh install" "--help did not print its usage"
  if printf '%s\n' "$out" | grep -qE '^(set -u|#!)'; then
    fail "--help printed shell source from past the end of the header block"
  fi
  pass "fm-agy-config.sh --help prints its header prose and stops there"
}

test_agy_busy_source_is_scoped_to_agy() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  fm_busy_source_trusted agy agy-hook || fail "agy must trust its own hook source"
  fm_busy_source_trusted agy fm-spawn || fail "agy must trust the firstmate-owned seed source"
  ! fm_busy_source_trusted claude agy-hook \
    || fail "agy's source classified a claude task"
  ! fm_busy_source_trusted agy claude-hook \
    || fail "claude's source classified an agy task"
  pass "the agy-hook busy source is trusted only for an agy task"
}

test_agy_separated_composer_is_classified() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  local caps; caps=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')

  out=$(fm_composer_classify_screen "$caps" "$(agy_screen '' '? for shortcuts')" 2 "agy	idle")
  [ "$out" = empty ] || fail "an idle empty agy composer should read empty, got '$out'"

  out=$(fm_composer_classify_screen "$caps" "$(agy_screen 'typed steer' '? for shortcuts')" 2 "agy	idle")
  [ "$out" = pending ] || fail "a typed agy composer should read pending, got '$out'"

  out=$(fm_composer_classify_screen "$caps" "$(agy_screen '' 'esc to cancel')" 2 "agy	working")
  [ "$out" = unknown ] || fail "a mid-turn agy composer must not prove empty, got '$out'"

  out=$(fm_composer_classify_screen "$caps" "$(agy_screen '' '? for shortcuts')" 2 probe-absent)
  [ "$out" = unknown ] || fail "an agy shape without identity must stay unknown, got '$out'"

  # agy draws a SECOND separator pair below its composer while a background task
  # runs. The pair holding the cursor is the composer; the lower one is not.
  out=$(fm_composer_classify_screen "$caps" "$(agy_screen '' '? for shortcuts' strip)" 2 "agy	idle")
  [ "$out" = empty ] || fail "a background-task strip must not displace the agy composer, got '$out'"
  pass "composer classifier: agy's separated shape reads empty, pending, and unknown correctly"
}

# The glyph strip that makes agy's `>` row read empty must never reach pi: a pi
# user typing a line that begins `> ` would otherwise read as an empty composer,
# which is exactly the false empty the away-mode injector must never see.
test_agy_glyph_strip_does_not_reach_pi() {
  local out caps
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  caps=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')
  out=$(fm_composer_classify_screen "$caps" "$(agy_screen '' '? for shortcuts')" 2 "pi	idle")
  [ "$out" = pending ] \
    || fail "a pi pane whose composer row begins with > must stay pending, got '$out'"
  pass "composer classifier: agy's prompt-glyph strip is scoped to an agy identity"
}

test_agy_delivery_busy_signature_is_scoped() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  printf 'esc to cancel\n' | fm_busy_lines_match agy \
    || fail "agy's own verified busy footer did not classify an agy pane busy"
  printf '? for shortcuts\n' | fm_busy_lines_match agy \
    && fail "agy's idle footer classified an agy pane busy"
  printf 'esc to cancel\n' | fm_busy_lines_match claude \
    && fail "agy's footer classified a claude pane busy"
  printf 'esc to cancel\n' | fm_busy_lines_match '' \
    || fail "the harness-less delivery union lost agy's footer"
  pass "the agy delivery busy footer is scoped to agy and joins the harness-less union"
}

test_agy_control_plane_mechanics() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported agy || fail "agy is not a supported control-plane harness"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy family resolution is wrong"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy interrupt key is wrong"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupt repeat is wrong"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy needs no composer clear key"
  [ "$(fm_control_interrupt_ack_source agy)" = none ] \
    || fail "agy claims a cancellation acknowledgement it does not have"
  [ "$(fm_control_exit_command agy)" = '/exit' ] || fail "agy exit command is wrong"
  fm_control_harness_wiring_paths agy /wt /state id | grep -Fqx '/wt/.fm-agy-turnend' \
    || fail "agy wiring paths omit the worktree pointer"
  fm_control_harness_wiring_paths agy /wt /state id | grep -Fqx '/state/id.agy-turnend-token' \
    || fail "agy wiring paths omit the state token"
  [ "$(fm_control_harness_turnend_token_path agy /state id)" = '/state/id.agy-turnend-token' ] \
    || fail "agy turn-end token path is wrong"
  [ "$(FM_AGY_CONFIG_DIR=/g/config fm_control_harness_turnend_auth_path agy fm.aaaaaaaaaaaa)" \
    = '/g/config/fm-agy-turn-end.d/fm.aaaaaaaaaaaa' ] \
    || fail "agy registry auth path is wrong"
  [ -z "$(fm_control_harness_turnend_auth_path agy 'bad token')" ] \
    || fail "agy registry auth path accepted an unsafe token"
  pass "the control plane carries agy's verified interrupt, exit, and wiring mechanics"
}

# agy's live process name is exactly `agy`, so the ancestry layer is asserted
# against that exact name and against a look-alike that must NOT match. The walk
# is driven through a fake `ps` for the same reason the kimi case is: a renamed
# copy of a real binary is not runnable on a code-signing platform, and the
# behaviour under test is the name rule, not the process table.
#
# The foreign markers are cleared in the ancestry cases because the marker layer
# deliberately outranks ancestry; leaving one set would assert the marker's
# verdict instead of the ancestry match.
test_agy_detection_prefers_marker_then_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detect"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    -u GROK_AGENT FM_CONFIG_OVERRIDE="$cfg" ANTIGRAVITY_AGENT=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT=1 did not detect agy, got '$out'"
  out=$(CLAUDECODE=1 ANTIGRAVITY_AGENT=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] \
    || fail "agy's marker outranked a primary-capable harness marker, got '$out'"
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    -u GROK_AGENT FM_CONFIG_OVERRIDE="$cfg" ANTIGRAVITY_CONVERSATION_ID=abc \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" != agy ] || fail "a conversation id was treated as an identity marker"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid= prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '%s\n' "${FM_FAKE_ANCESTOR_COMM:?}" ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    -u GROK_AGENT PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" \
    FM_FAKE_ANCESTOR_COMM=/Users/x/.local/bin/agy "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "agy ancestry detection returned '$out'"
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    -u GROK_AGENT PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" \
    FM_FAKE_ANCESTOR_COMM=/usr/bin/agyx "$ROOT/bin/fm-harness.sh")
  [ "$out" != agy ] || fail "the anchored agy match claimed an unrelated agyx process"
  pass "fm-harness: agy is detected by its own marker and by an anchored ancestry name"
}

test_agy_tmux_liveness_classifies_the_agent() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  out=$(fm_backend_tmux_classify_process_name /Users/x/.local/bin/agy)
  [ "$out" = agent ] || fail "tmux liveness did not classify agy as an agent, got '$out'"
  out=$(fm_backend_tmux_classify_process_name /usr/bin/agyx)
  [ "$out" != agent ] || fail "tmux liveness claimed an unrelated agyx process"
  pass "tmux agent liveness recognizes agy by its exact process name"
}

test_agy_launch_shape_and_wiring
test_agy_secondmate_is_refused
test_agy_missing_binary_refuses_before_pane_creation
test_agy_teardown_removes_pointer_and_registry_token
test_agy_global_config_edit_is_surgical_idempotent_and_removable
test_agy_global_config_fails_closed_on_unsafe_shared_files
test_agy_hook_requires_a_registered_workspace_token
test_agy_config_reports_a_skipped_skills_root
test_agy_config_help_stops_at_the_end_of_its_header
test_agy_busy_source_is_scoped_to_agy
test_agy_separated_composer_is_classified
test_agy_glyph_strip_does_not_reach_pi
test_agy_delivery_busy_signature_is_scoped
test_agy_control_plane_mechanics
test_agy_detection_prefers_marker_then_ancestry
test_agy_tmux_liveness_classifies_the_agent
