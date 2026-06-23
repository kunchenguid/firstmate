#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-treehouse-env.XXXXXX")

make_fake_tmux() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    exit 0
    ;;
  display-message)
    printf '%s\n' "$FM_FAKE_WORKTREE"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

test_spawn_passes_home_context_to_treehouse_get() {
  local case_dir fakebin home data state projects config project worktree id log
  case_dir="$TMP_ROOT/home context"
  fakebin="$case_dir/fakebin"
  home="$case_dir/home"
  data="$case_dir/data override"
  state="$case_dir/state override"
  projects="$case_dir/projects override"
  config="$case_dir/config override"
  project="$projects/app"
  worktree="$case_dir/worktree app"
  id=env-z1
  log="$case_dir/tmux.log"

  make_fake_tmux "$fakebin"
  mkdir -p "$data/$id" "$state" "$config" "$project" "$worktree"
  printf 'brief\n' > "$data/$id/brief.md"
  mkdir -p "$data"
  printf '%s\n' '- app [direct-PR] - test app (added 2026-06-23)' > "$data/projects.md"

  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_DATA_OVERRIDE="$data" \
    FM_STATE_OVERRIDE="$state" \
    FM_PROJECTS_OVERRIDE="$projects" \
    FM_CONFIG_OVERRIDE="$config" \
    FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_WORKTREE="$worktree" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" projects/app codex >/dev/null \
    || fail "spawn failed"

  grep -F "send-keys -t firstmate:fm-$id -l FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='$state' FM_DATA_OVERRIDE='$data' FM_PROJECTS_OVERRIDE='$projects' FM_CONFIG_OVERRIDE='$config' FM_HOME='$home' treehouse get" "$log" >/dev/null \
    || fail "spawn did not pass active firstmate context to treehouse get"
  pass "spawn passes active home context to treehouse get"
}

test_spawn_passes_home_context_to_treehouse_get
