#!/usr/bin/env bash
# Portable Cursor CLI harness-adapter contracts: detection, crew resolution,
# local launch template shape, and remote secondmate rejection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_INVOKED_AS

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
export FM_BACKEND=tmux

make_seeded_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

make_launch_capturing_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

spawn_secondmate_capture() {
  local world=$1 id=$2 home=$3 launchlog=$4 fakebin
  shift 4
  mkdir -p "$world/home/state" "$world/home/data"
  fakebin=$(make_launch_capturing_tmux "$world/tmux-$id")
  : > "$launchlog"
  PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "$@" --secondmate
}

meta_harness() { grep '^harness=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

test_cursor_env_marker_detection() {
  local cfg out
  cfg="$TMP_ROOT/detect-env/config"
  mkdir -p "$cfg"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    CURSOR_INVOKED_AS=agent FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "CURSOR_INVOKED_AS detection returned '$out'"
  out=$(CLAUDECODE=1 CURSOR_INVOKED_AS=agent FM_CONFIG_OVERRIDE="$cfg" \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "env-marker precedence lost to cursor, got '$out'"
  pass "fm-harness: CURSOR_INVOKED_AS detects cursor after verified marker precedence"
}

test_cursor_ancestry_detection() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detect-ancestry"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf 'cursor-agent\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_INVOKED_AS \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "cursor-agent ancestry detection returned '$out'"
  pass "fm-harness: cursor-agent ancestry detects cursor"
}

test_cursor_crew_resolution() {
  local cfg got
  cfg="$TMP_ROOT/crew-resolve/config"
  mkdir -p "$cfg"
  printf 'cursor\n' > "$cfg/crew-harness"
  got=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" crew)
  [ "$got" = cursor ] || fail "crew-harness=cursor resolved '$got'"
  got=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate)
  [ "$got" = cursor ] || fail "secondmate fallback to crew cursor resolved '$got'"
  pass "fm-harness: crew and secondmate resolve config/crew-harness=cursor"
}

test_cursor_local_secondmate_launch_template() {
  local w sm meta launchlog launch out status
  w="$TMP_ROOT/spawn-cursor"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'cursor\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$launchlog" 2>&1); status=$?
  expect_code 0 "$status" "cursor secondmate spawn should succeed"$'\n'"$out"

  meta="$w/home/state/sm.meta"
  [ -f "$meta" ] || fail "cursor spawn wrote no meta"
  [ "$(meta_harness "$meta")" = cursor ] \
    || fail "cursor spawn meta harness='$(meta_harness "$meta")'"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "cursor-agent" "cursor launch must invoke cursor-agent"
  assert_contains "$launch" "--yolo" "cursor launch must include --yolo"
  assert_contains "$launch" "--trust" "cursor launch must include --trust"
  pass "fm-spawn: local cursor secondmate launch uses cursor-agent --yolo --trust"
}

test_cursor_model_flag_without_effort() {
  local w sm launchlog launch out status
  w="$TMP_ROOT/spawn-cursor-model"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$launchlog" \
    --harness cursor --model composer-2 --effort high 2>&1); status=$?
  expect_code 0 "$status" "cursor model spawn should succeed"$'\n'"$out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model" "cursor model spawn must carry --model"
  assert_contains "$launch" "composer-2" "cursor model spawn must carry the model id"
  assert_not_contains "$launch" "--effort" "cursor has no effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor has no reasoning-effort flag"
  pass "fm-spawn: cursor accepts --model and omits effort flags"
}

test_cursor_supervision_snippet_renders() {
  local out
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness cursor)
  assert_contains "$out" "Cursor CLI" "cursor supervision snippet missing title cue"
  assert_contains "$out" "Herdr" "cursor supervision snippet should prefer Herdr"
  assert_contains "$out" "fm-session-start.sh" "cursor supervision snippet must require session start"
  pass "fm-supervision-instructions: cursor snippet renders"
}

test_cursor_env_marker_detection
test_cursor_ancestry_detection
test_cursor_crew_resolution
test_cursor_local_secondmate_launch_template
test_cursor_model_flag_without_effort
test_cursor_supervision_snippet_renders
