#!/usr/bin/env bash
# tests/fm-spawn-helpers.sh - shared fixtures for the fm-spawn.sh launch-string
# suites (fm-spawn-dispatch-profile and fm-spawn-claude-config-dir).
#
# Both suites drive a real fm-spawn.sh run against a fake tmux and an isolated
# firstmate home, then assert on the literal launch command. The fake tmux body
# and the FM_*_OVERRIDE env block are the parts that were duplicated verbatim, so
# they live here; the per-suite case builders stay in their own files because
# their seeding differs (crew-harness pin and multiple task ids vs a single
# positional-harness task). The generic git/fakebin primitives come from lib.sh,
# which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_spawn_fakebin <dir> [extra-stub...]: a fakebin whose tmux satisfies the tmux
# backend and records the launch string. The launch command is the only send-keys
# call that uses `-l` (fm_backend_tmux_send_literal); the `treehouse get` and
# GOTMPDIR sends use the text-line form (trailing Enter, no -l) and the final
# Enter uses send_key, so capturing the argument after `-l` isolates the launch
# string. Each captured literal is appended as one line to FM_FAKE_LAUNCH_LOG
# when that variable is set. The pane-path query returns FM_FAKE_PANE_PATH so
# worktree discovery resolves immediately, and new-window prints a stable window
# id the way real tmux does under `-P -F '#{window_id}'`. `treehouse` is always
# stubbed; any extra tool names are stubbed exit-0 as well. Echoes the fakebin.
fm_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
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
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# fm_spawn_home_skeleton <home>: the isolated firstmate home layout every spawn
# case needs (the FM_*_OVERRIDE targets plus a fresh watcher beat so the spawn
# guard sees a live watcher).
fm_spawn_home_skeleton() {
  local home=$1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
}

# fm_spawn_seed_task <home> <id>: the task's data dir and brief.
fm_spawn_seed_task() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
}

# fm_spawn_run <home> <wt> <fakebin> <launchlog> [spawn-args...]: truncate the
# launch log, then run bin/fm-spawn.sh against the isolated home with the fake
# tmux on PATH. stderr is folded into stdout so callers can assert on either;
# fm-spawn's exit status is returned unchanged.
fm_spawn_run() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}
