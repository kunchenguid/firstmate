#!/usr/bin/env bash
# tests/fm-spawn-herdr-prelaunch-fusion.test.sh - a Herdr spawn must reach the
# pane as ONE text write before its launch submit.
#
# Herdr's `pane run` returns once its text is typed, before the submit it carries
# has been executed. A spawn that typed its pre-launch exports as their own
# `pane run` lines and then typed the launch source line fused the two into
# `export COMPACT_ADVISER_DISABLE=1. '/tmp/fm-<id>/launch.s<n>.sh'`, which zsh
# rejects with `export: not valid in this context`; the agent never started and
# the worker was dead. These cases pin the replacement: the pane receives one
# unsubmitted launch literal, and the export statements ride the staged launch
# command's first line, which the sourcing shell executes in the pane's own
# shell before the agent runs.
#
# The fake herdr CLI is stateful and records which verb carried which text, so
# nothing here drives a real Herdr session or server lifecycle.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-prelaunch-fusion)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# reset_write_logs <case-dir>: forget every recorded pane write.
reset_write_logs() { # <case-dir>
  : > "$1/fake/run-texts"
  : > "$1/fake/literal-texts"
  rm -f "$1/fake/staged-path" "$1/fake/staged-command" "$1/fake/literal-submitted"
}

# make_case <name> [harness]: a home, a project, a leased task copy, and a fake
# herdr that records every text write it is asked to make on the pane.
# Echoes the case directory.
make_case() {
  local name=$1 harness=${2:-codex} dir home proj slot fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  slot="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$slot"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr pre-launch delivery for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  reset_write_logs "$dir"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) printf '%s\n' "$FM_FAKE_SLOT" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'session list') exit 0 ;;
  'pane close') : > "$D/pane-gone"; exit 0 ;;
  'pane get')
    [ ! -f "$D/pane-gone" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 0; }
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["zsh"],"cmdline":"zsh"}]}}}\n' \
      "${3:-}" "$$" "$$" "$$"
    exit 0 ;;
  # An atomic `pane run` line and an unsubmitted `pane send-text` literal are
  # recorded separately, because which one carried what is the behavior under
  # test.
  'pane run')
    payload=${4:-}
    printf '%s\n' "$payload" >> "$D/run-texts"
    case "$payload" in
      'cd -- '*)
        path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$path" "$D/cwd"
        cp "$D/cwd" "$D/fg" ;;
    esac
    exit 0 ;;
  'pane send-text')
    payload=${4:-}
    printf '%s\n' "$payload" >> "$D/literal-texts"
    case "$payload" in
      ". '"*"'")
        staged=${payload#". '"}; staged=${staged%"'"}
        if [ -f "$staged" ]; then
          printf '%s\n' "$staged" > "$D/staged-path"
          cp "$staged" "$D/staged-command"
        fi
        ;;
    esac
    exit 0 ;;
  'pane send-keys')
    : > "$D/literal-submitted"
    : > "$D/herdr-agent-live"
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found","message":"no agent registered"}}\n'
    fi
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wsown"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\n'
    exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '{"result":{"tab":{"tab_id":"tabown"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

# run_in_case <case-dir> <spawn args...>: drive the real spawn against the case's
# fake pane, with no heredity from this process's own Herdr identity.
run_in_case() { # <case-dir> <args...>
  local dir=$1
  shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# The export statements that must ride the launch's first line, one per line,
# read back from the staged launch command the pane received.
staged_exports() { # <case-dir>
  sed -n '1s/; /\n/gp' "$1/fake/staged-command"
}

assert_no_export_line_is_typed() { # <case-dir> <label>
  local dir=$1 label=$2 typed
  typed=$(grep -c '^export ' "$dir/fake/run-texts" || true)
  [ "${typed:-0}" -eq 0 ] \
    || fail "$label: the pane received $typed pre-launch export line(s) as their own command, which the next typed line fuses onto"$'\n'"$(cat "$dir/fake/run-texts")"
}

assert_no_pane_run_is_typed() { # <case-dir> <label>
  local dir=$1 label=$2 runs
  runs=$(grep -c '^' "$dir/fake/run-texts" || true)
  [ "${runs:-0}" -eq 0 ] \
    || fail "$label: the pane received $runs pre-launch run write(s), and each returns before its submit, so the launch literal can fuse onto one"$'\n'"$(cat "$dir/fake/run-texts")"
}

assert_launch_is_one_literal() { # <case-dir> <label>
  local dir=$1 label=$2 literals staged
  literals=$(grep -c '^' "$dir/fake/literal-texts" || true)
  [ "${literals:-0}" -eq 1 ] \
    || fail "$label: the pane received $literals launch text writes, not exactly one, so a later write can fuse onto an earlier one"$'\n'"$(cat "$dir/fake/literal-texts")"
  [ -f "$dir/fake/staged-path" ] \
    || fail "$label: the pane's one text write never named a staged launch file"$'\n'"$(cat "$dir/fake/literal-texts")"
  staged=$(cat "$dir/fake/staged-path")
  grep -qxF ". '$staged'" "$dir/fake/literal-texts" \
    || fail "$label: the pane's one text write was not the launch source line"$'\n'"$(cat "$dir/fake/literal-texts")"
  [ -s "$dir/fake/staged-command" ] \
    || fail "$label: the launch literal named a file the spawn had not staged"
}

assert_exports_ride_the_launch() { # <case-dir> <label> <expected-id>
  local dir=$1 label=$2 id=$3 exports
  exports=$(staged_exports "$dir")
  printf '%s\n' "$exports" | grep -qxF "export GOTMPDIR=/tmp/fm-$id/gotmp" \
    || fail "$label: the staged launch does not open with the GOTMPDIR export"$'\n'"$exports"
  printf '%s\n' "$exports" | grep -qxF 'export COMPACT_ADVISER_DISABLE=1' \
    || fail "$label: the staged launch does not carry the compact-adviser switch"$'\n'"$exports"
  printf '%s\n' "$exports" | grep -qxF "export FM_TASK_ID=$id" \
    || fail "$label: the staged launch does not carry the task marker"$'\n'"$exports"
  sed -n '2,$p' "$dir/fake/staged-command" | grep -qF 'fm-osc7501.sh' \
    || fail "$label: the staged launch carries no launch command after its exports"$'\n'"$(cat "$dir/fake/staged-command")"
}

# Execute the launch's first line in a cleared environment, the way the pane's
# shell does, and read back what a child process of that shell would inherit.
assert_exports_apply_in_the_pane_shell() { # <case-dir> <label> <expected-id>
  local dir=$1 label=$2 id=$3 first seen probe
  first=$(sed -n '1p' "$dir/fake/staged-command")
  [ -n "$first" ] || fail "$label: the staged launch has no first line to run"
  # The probe is the pane shell's own child: it reads the exports back from the
  # environment those statements leave behind.
  read -r -d '' probe <<'SH' || true
printf "GOTMPDIR=%s\nCOMPACT_ADVISER_DISABLE=%s\nFM_TASK_ID=%s\n" "${GOTMPDIR:-}" "${COMPACT_ADVISER_DISABLE:-}" "${FM_TASK_ID:-}"
SH
  seen=$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    HOME="$dir/user-home" TERM=xterm /bin/sh -c "$first
$probe") \
    || fail "$label: the pane shell could not run the exports the launch carries"$'\n'"$first"
  printf '%s\n' "$seen" | grep -qxF "GOTMPDIR=/tmp/fm-$id/gotmp" \
    || fail "$label: the pane shell did not receive GOTMPDIR from the launch line"$'\n'"$seen"
  printf '%s\n' "$seen" | grep -qxF 'COMPACT_ADVISER_DISABLE=1' \
    || fail "$label: the pane shell did not receive the compact-adviser switch"$'\n'"$seen"
  printf '%s\n' "$seen" | grep -qxF "FM_TASK_ID=$id" \
    || fail "$label: the pane shell did not receive the task marker"$'\n'"$seen"
}

test_ship_spawn_launches_in_one_write() {
  local id=fusion-ship dir out status
  dir=$(make_case "$id")
  out=$(run_in_case "$dir" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the herdr ship spawn should succeed"$'\n'"$out"
  assert_no_export_line_is_typed "$dir" "a fresh herdr ship spawn"
  assert_launch_is_one_literal "$dir" "a fresh herdr ship spawn"
  assert_exports_ride_the_launch "$dir" "a fresh herdr ship spawn" "$id"
  assert_exports_apply_in_the_pane_shell "$dir" "a fresh herdr ship spawn" "$id"
  pass "a fresh Herdr ship spawn types its exports only through the launch line, so nothing can fuse onto it"
}

test_scout_spawn_launches_in_one_write() {
  local id=fusion-scout dir out status
  dir=$(make_case "$id")
  out=$(run_in_case "$dir" "$id" "$dir/project" --backend herdr --scout)
  status=$?
  expect_code 0 "$status" "the herdr scout spawn should succeed"$'\n'"$out"
  assert_no_export_line_is_typed "$dir" "a fresh herdr scout spawn"
  assert_launch_is_one_literal "$dir" "a fresh herdr scout spawn"
  assert_exports_ride_the_launch "$dir" "a fresh herdr scout spawn" "$id"
  pass "a fresh Herdr scout spawn types its exports only through the launch line, so nothing can fuse onto it"
}

test_relaunch_launches_in_one_write() {
  local id=fusion-relaunch dir out status
  dir=$(make_case "$id")
  out=$(run_in_case "$dir" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first herdr spawn should succeed"$'\n'"$out"
  # The operator's stop before a replacement: the pane keeps its shell and its
  # recorded endpoint, and the agent that held it has exited.
  rm -f "$dir/fake/herdr-agent-live"
  reset_write_logs "$dir"
  out=$(run_in_case "$dir" "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "the herdr relaunch should succeed"$'\n'"$out"
  assert_no_export_line_is_typed "$dir" "a herdr relaunch"
  assert_no_pane_run_is_typed "$dir" "a herdr relaunch already in its recorded worktree"
  assert_launch_is_one_literal "$dir" "a herdr relaunch"
  assert_exports_ride_the_launch "$dir" "a herdr relaunch" "$id"
  pass "a Herdr relaunch types its exports only through the launch line, so nothing can fuse onto it"
}

test_ship_spawn_launches_in_one_write
test_scout_spawn_launches_in_one_write
test_relaunch_launches_in_one_write

echo "# all fm-spawn-herdr-prelaunch-fusion tests passed"
