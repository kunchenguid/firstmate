#!/usr/bin/env bash
# Behavior tests for the verified Droid harness adapter.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-harness.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_fake_tmux() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        '#S') printf 'testsession\n'; exit 0 ;;
        '#{pane_current_path}') printf '%s\n' "${FM_FAKE_WORKTREE:-/tmp/fm-droid-worktree}"; exit 0 ;;
      esac
    done
    printf 'testsession\n'
    exit 0
    ;;
  list-windows)
    exit 0
    ;;
  has-session|new-session|new-window|send-keys|kill-window)
    {
      printf '%s' "$1"
      shift
      for arg in "$@"; do
        printf '\t%s' "$arg"
      done
      printf '\n'
    } >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  capture-pane)
    printf 'idle prompt\n'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_droid_ship_launch_uses_runtime_stop_hook() {
  local dir home project worktree fakebin log id settings meta
  dir="$TMP_ROOT/ship"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"
  id=droid-ship-a1
  settings="$home/state/$id.droid-settings.json"
  meta="$home/state/$id.meta"
  mkdir -p "$home/data/$id" "$home/state" "$project" "$worktree"
  printf 'do the task\n' > "$home/data/$id/brief.md"
  : > "$log"

  PATH="$fakebin:$PATH" TMUX=1 FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_WORKTREE="$worktree" \
    "$SPAWN" "$id" "$project" droid >/dev/null \
    || fail "droid ship spawn failed"

  [ -f "$settings" ] || fail "droid runtime settings file was not written"
  grep -F "touch '$home/state/$id.turn-ended'" "$settings" >/dev/null \
    || fail "droid Stop hook does not touch the task turn-ended marker"
  grep -F "droid --settings '$settings' --auto high" "$log" >/dev/null \
    || fail "droid launch did not use --settings and --auto high"
  grep -F "$home/data/$id/brief.md" "$log" >/dev/null \
    || fail "droid launch did not pass the task brief"
  grep -Fx 'harness=droid' "$meta" >/dev/null || fail "meta did not record harness=droid"
  pass "droid ship launch uses a runtime Stop hook and records harness metadata"
}

test_droid_secondmate_launch_omits_parent_hook() {
  local dir home subhome subhome_abs fakebin log id settings
  dir="$TMP_ROOT/secondmate"
  home="$dir/home"
  subhome="$dir/subhome"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"
  id=droid-sub-b2
  settings="$home/state/$id.droid-settings.json"
  mkdir -p "$home/data/$id" "$home/state" "$subhome/data" "$subhome/bin"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'charter\n' > "$subhome/data/charter.md"
  printf '%s\n' "- $id - droid secondmate (home: $subhome_abs; scope: droid secondmate; projects: alpha; added 2026-06-24)" > "$home/data/secondmates.md"
  : > "$log"

  PATH="$fakebin:$PATH" TMUX=1 FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" \
    "$SPAWN" "$id" "$subhome" droid --secondmate >/dev/null \
    || fail "droid secondmate spawn failed"

  [ ! -e "$settings" ] || fail "droid secondmate launch wrote a parent Stop hook"
  grep -F "droid --auto high" "$log" >/dev/null \
    || fail "droid secondmate launch did not use --auto high"
  grep -F -- "--settings" "$log" >/dev/null \
    && fail "droid secondmate launch should not use parent runtime settings"
  grep -F "$subhome_abs/data/charter.md" "$log" >/dev/null \
    || fail "droid secondmate launch did not pass persistent charter"
  pass "droid secondmate launch omits parent turn-end hook"
}

test_droid_ship_launch_uses_runtime_stop_hook
test_droid_secondmate_launch_omits_parent_hook
