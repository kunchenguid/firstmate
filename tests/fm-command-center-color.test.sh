#!/usr/bin/env bash
# Color behavior for fm-command-center.sh.
#
# The dashboard should be readable in logs and tests by default, while still
# allowing explicit forced color for tmux-like captures. NO_COLOR wins over
# force-color knobs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-command-center-color)
COMMAND_CENTER="$ROOT/bin/fm-command-center.sh"

make_fake_tmux() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    printf '@42\n'
    exit 0
    ;;
  capture-pane)
    printf '%s\n' 'Working...'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {
  local dir=$1 home="$1/home"
  mkdir -p "$home/state" "$home/data"
  : > "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/paint-task.meta" \
    "window=firstmate:fm-paint-task" \
    "project=$home/projects/firstmate" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' 'working: adding useful color' > "$home/state/paint-task.status"
  cat > "$home/data/backlog.md" <<'MD'
## In flight
- [ ] paint-task - Add color to command center (repo: firstmate)
MD
  printf '%s\n' "$home"
}

run_dashboard() {
  local fakebin=$1 home=$2
  shift 2
  env -u NO_COLOR -u FORCE_COLOR -u CLICOLOR_FORCE "$@" \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" TERM=dumb \
    "$COMMAND_CENTER" __dashboard_once
}

test_redirected_output_is_plain_by_default() {
  local dir fb home out
  dir="$TMP_ROOT/plain"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  home=$(make_home "$dir")
  out=$(run_dashboard "$fb" "$home")
  assert_contains "$out" "FIRSTMATE COMMAND CENTER" "plain dashboard keeps title text"
  assert_contains "$out" "paint-task" "plain dashboard includes task id"
  assert_contains "$out" "working" "plain dashboard includes pane state"
  assert_not_contains "$out" $'\033[' "plain redirected dashboard must not contain ANSI"
  pass "fm-command-center: redirected dashboard output is plain by default"
}

test_force_color_enables_ansi() {
  local dir fb home out
  dir="$TMP_ROOT/force"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  home=$(make_home "$dir")
  out=$(run_dashboard "$fb" "$home" FORCE_COLOR=1)
  assert_contains "$out" $'\033[' "FORCE_COLOR dashboard includes ANSI"
  assert_contains "$out" "paint-task" "FORCE_COLOR dashboard preserves task id text"
  assert_contains "$out" "working" "FORCE_COLOR dashboard preserves state text"
  pass "fm-command-center: FORCE_COLOR enables ANSI in captured output"
}

test_no_color_overrides_force_color() {
  local dir fb home out
  dir="$TMP_ROOT/no-color"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  home=$(make_home "$dir")
  out=$(run_dashboard "$fb" "$home" FORCE_COLOR=1 NO_COLOR=1)
  assert_not_contains "$out" $'\033[' "NO_COLOR must suppress forced ANSI"
  assert_contains "$out" "paint-task" "NO_COLOR dashboard preserves task id text"
  pass "fm-command-center: NO_COLOR overrides forced color"
}

test_redirected_output_is_plain_by_default
test_force_color_enables_ansi
test_no_color_overrides_force_color
