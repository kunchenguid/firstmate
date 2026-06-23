#!/usr/bin/env bash
# Behavior tests for the OpenCode server backend path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/fm-opencode-server"
SPAWN="$ROOT/bin/fm-spawn.sh"
PEEK="$ROOT/bin/fm-peek.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-server-tests.XXXXXX")

make_fakebin() {
  local dir=$1 fakebin log
  fakebin="$dir/fakebin"
  log="$dir/backend-tool.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'opencode test\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$FM_BACKEND_TOOL_LOG"
exit 42
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_BACKEND_TOOL_LOG"
exit 42
SH
  chmod +x "$fakebin/opencode" "$fakebin/tmux" "$fakebin/treehouse"
  : > "$log"
  printf '%s\n' "$fakebin"
}

make_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# test project\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.email=tests@example.invalid -c user.name='Firstmate Tests' commit -qm initial
  git -C "$dir" branch -M main
}

test_helper_visibility_modes() {
  local state worktree brief out
  state="$TMP_ROOT/helper-state"
  worktree="$TMP_ROOT/helper-worktree"
  brief="$TMP_ROOT/helper-brief.md"
  mkdir -p "$state" "$worktree"
  printf 'brief\n' > "$brief"

  out=$(FM_STATE_OVERRIDE="$state" FM_OPENCODE_SERVER_MOCK=1 FM_OPENCODE_VISIBILITY=terminal \
    FM_OPENCODE_VISIBILITY_DRY_RUN=1 "$HELPER" start helper-x1 fm-helper-x1 "$worktree" "$brief") \
    || fail "mock helper start failed for terminal visibility"
  printf '%s\n' "$out" | grep -F 'opencode_visibility=desktop' >/dev/null \
    || fail "terminal visibility did not alias to desktop"
  printf '%s\n' "$out" | grep -F 'opencode_desktop=dry-run' >/dev/null \
    || fail "desktop visibility did not report a dry-run desktop launch"
  printf '%s\n' "$out" | grep -F 'opencode_desktop_deeplink=opencode://new-session?' >/dev/null \
    || fail "desktop visibility did not produce an OpenCode new-session deep link"
  printf '%s\n' "$out" | grep -F 'opencode_web=' >/dev/null \
    && fail "desktop-only visibility unexpectedly reported web output"

  out=$(FM_STATE_OVERRIDE="$state" FM_OPENCODE_SERVER_MOCK=1 FM_OPENCODE_VISIBILITY=web \
    FM_OPENCODE_VISIBILITY_DRY_RUN=1 "$HELPER" start helper-x2 fm-helper-x2 "$worktree" "$brief") \
    || fail "mock helper start failed for web visibility"
  printf '%s\n' "$out" | grep -F 'opencode_visibility=web' >/dev/null \
    || fail "web visibility was not recorded"
  printf '%s\n' "$out" | grep -F 'opencode_web=dry-run' >/dev/null \
    || fail "web visibility did not report a dry-run web URL"
  printf '%s\n' "$out" | grep -F 'opencode_desktop=' >/dev/null \
    && fail "web-only visibility unexpectedly reported desktop output"

  out=$(FM_STATE_OVERRIDE="$state" FM_OPENCODE_SERVER_MOCK=1 FM_OPENCODE_SERVER_HOST=0.0.0.0 \
    OPENCODE_SERVER_USERNAME= OPENCODE_SERVER_PASSWORD= \
    "$HELPER" start helper-x3 fm-helper-x3 "$worktree" "$brief") \
    || fail "mock helper start failed for non-loopback host"
  printf '%s\n' "$out" | grep -F 'opencode_server_username=opencode' >/dev/null \
    || fail "non-loopback host did not generate a username"
  printf '%s\n' "$out" | grep -F 'opencode_server_password=' >/dev/null \
    || fail "non-loopback host did not generate a password"

  out=$(FM_STATE_OVERRIDE="$state" FM_OPENCODE_SERVER_MOCK=1 FM_OPENCODE_SERVER_HOST=0.0.0.0 \
    OPENCODE_SERVER_USERNAME=crew OPENCODE_SERVER_PASSWORD=local-secret \
    "$HELPER" start helper-x4 fm-helper-x4 "$worktree" "$brief") \
    || fail "mock helper start failed for provided non-loopback auth"
  printf '%s\n' "$out" | grep -F 'opencode_server_username=crew' >/dev/null \
    || fail "provided non-loopback auth did not persist a username"
  printf '%s\n' "$out" | grep -F 'opencode_server_password=local-secret' >/dev/null \
    || fail "provided non-loopback auth did not persist a password"

  pass "OpenCode helper records desktop deep links and web URLs without shell openers"
}

test_spawn_send_peek_teardown_backend() {
  local home project fakebin log out meta wt peek_out
  home="$TMP_ROOT/home"
  project="$TMP_ROOT/project"
  mkdir -p "$home/data/opencode-task-x1" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'do the task\n' > "$home/data/opencode-task-x1/brief.md"
  printf '%s\n' '- project [local-only] - test project (added 2026-06-23)' > "$home/data/projects.md"
  make_project "$project"
  fakebin=$(make_fakebin "$TMP_ROOT/runtime")
  log="$TMP_ROOT/runtime/backend-tool.log"

  out=$(PATH="$fakebin:$PATH" FM_BACKEND_TOOL_LOG="$log" FM_HOME="$home" FM_BACKEND=opencode-server \
    FM_OPENCODE_SERVER_MOCK=1 FM_OPENCODE_VISIBILITY=desktop FM_OPENCODE_VISIBILITY_DRY_RUN=1 \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" opencode-task-x1 "$project") \
    || fail "opencode-server spawn failed: $out"
  printf '%s\n' "$out" | grep -F 'backend=opencode-server' >/dev/null \
    || fail "spawn output did not identify opencode-server backend"

  meta="$home/state/opencode-task-x1.meta"
  [ -f "$meta" ] || fail "spawn did not write meta"
  grep -qx 'backend=opencode-server' "$meta" || fail "meta missing backend=opencode-server"
  grep -qx 'harness=opencode' "$meta" || fail "opencode-server spawn did not default to opencode harness"
  grep -qx 'window=fm-opencode-task-x1' "$meta" || fail "meta did not record synthetic window name"
  grep -qx 'opencode_session_id=mock-opencode-task-x1' "$meta" || fail "meta missing mock OpenCode session id"
  grep -qx 'opencode_visibility=desktop' "$meta" || fail "meta missing desktop visibility"
  grep -q '^opencode_desktop_deeplink=opencode://new-session?' "$meta" \
    || fail "meta missing desktop deep link"
  wt=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  case "$wt" in
    "$home/state/opencode-server-worktrees/opencode-task-x1") ;;
    *) fail "opencode-server worktree was not under home state: $wt" ;;
  esac
  [ -d "$wt" ] || fail "spawn did not create the OpenCode server worktree"
  git -C "$project" worktree list --porcelain | grep -F "worktree $wt" >/dev/null \
    || fail "OpenCode server worktree was not registered with git"

  peek_out=$(FM_HOME="$home" FM_OPENCODE_SERVER_MOCK=1 "$PEEK" fm-opencode-task-x1 5) \
    || fail "fm-peek failed for OpenCode server task"
  printf '%s\n' "$peek_out" | grep -F 'opencode-server status: idle' >/dev/null \
    || fail "fm-peek did not capture OpenCode server status"
  FM_HOME="$home" FM_OPENCODE_SERVER_MOCK=1 "$SEND" fm-opencode-task-x1 'continue' \
    || fail "fm-send failed for OpenCode server text"
  FM_HOME="$home" FM_OPENCODE_SERVER_MOCK=1 "$SEND" mock-opencode-task-x1 --key Escape \
    || fail "fm-send failed for OpenCode server interrupt by session id"

  PATH="$fakebin:$PATH" FM_BACKEND_TOOL_LOG="$log" FM_HOME="$home" FM_OPENCODE_SERVER_MOCK=1 \
    "$TEARDOWN" opencode-task-x1 --force >/dev/null \
    || fail "opencode-server teardown failed"
  [ ! -e "$wt" ] || fail "teardown did not remove the OpenCode server worktree"
  [ ! -e "$meta" ] || fail "teardown did not remove meta"
  [ ! -s "$log" ] || fail "opencode-server path called tmux/treehouse: $(cat "$log")"

  pass "OpenCode server backend spawns, sends, peeks, and tears down without tmux/treehouse"
}

test_helper_visibility_modes
test_spawn_send_peek_teardown_backend
