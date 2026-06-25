#!/usr/bin/env bash
# Tests for fm-teardown.sh cleanup of kimi per-task homes.
#
# Verifies teardown removes state/<id>.kimi-home/ and that secondmate child
# teardown removes nested state/<child_id>.kimi-home/. No real kimi or tmux.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-teardown.XXXXXX")

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 kind=${2:-ship}
  cat > "$case_dir/state/task-x1.meta" <<EOF
window=fm-task-x1
worktree=$case_dir/wt
project=$case_dir/project
harness=kimi
kind=$kind
mode=no-mistakes
EOF
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_teardown_removes_kimi_home() {
  local case_dir
  case_dir=$(make_case removes-home)
  write_meta "$case_dir"
  mkdir -p "$case_dir/state/task-x1.kimi-home/credentials"
  printf 'theme = "dark"\n' > "$case_dir/state/task-x1.kimi-home/config.toml"

  run_teardown "$case_dir" || fail "teardown failed"
  [ ! -e "$case_dir/state/task-x1.kimi-home" ] || fail "kimi-home directory still exists after teardown"
  pass "teardown removes state/<id>.kimi-home/"
}

test_secondmate_child_teardown_removes_nested_kimi_home() {
  local case_dir parent_home child_home
  case_dir=$(make_case secondmate-child)
  parent_home="$case_dir/parent-secondmate"
  child_home="$case_dir/child-secondmate"

  mkdir -p "$parent_home" "$child_home"
  # Parent marker must match the parent id.
  printf 'parent-x1\n' > "$parent_home/.fm-secondmate-home"
  # Child marker must match the child id.
  printf 'child-x2\n' > "$child_home/.fm-secondmate-home"
  # Minimal firstmate home structure for both.
  for h in "$parent_home" "$child_home"; do
    mkdir -p "$h/bin" "$h/data" "$h/state" "$h/config" "$h/projects"
    touch "$h/AGENTS.md"
  done

  # Parent secondmate meta
  cat > "$case_dir/state/parent-x1.meta" <<EOF
window=fm-parent-x1
worktree=$parent_home
project=$parent_home
harness=claude
kind=secondmate
mode=secondmate
home=$parent_home
projects=
EOF

  # Child task meta lives in the parent's state dir.
  mkdir -p "$parent_home/state/child-x2.kimi-home"
  printf 'theme = "dark"\n' > "$parent_home/state/child-x2.kimi-home/config.toml"
  cat > "$parent_home/state/child-x2.meta" <<EOF
window=fm-child-x2
worktree=$child_home/wt
project=$child_home/project
harness=kimi
kind=ship
mode=no-mistakes
home=$child_home
EOF

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" parent-x1 --force || fail "secondmate teardown failed"

  [ ! -e "$parent_home/state/child-x2.kimi-home" ] || fail "nested child kimi-home still exists"
  pass "secondmate child teardown removes nested state/<child_id>.kimi-home/"
}

test_teardown_removes_kimi_home
test_secondmate_child_teardown_removes_nested_kimi_home
