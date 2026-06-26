#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh with the kimi harness.
#
# These mock tmux (no real windows/server) and exercise the full single-task spawn
# path: launch template, per-task KIMI_CODE_HOME creation, Stop-hook merge, and
# the missing-auth failure. No real kimi, tmux, treehouse, or network is needed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-spawn.XXXXXX")

# Build a fake tmux that records send-keys and returns a worktree path for the
# pane-current-path poll. Composer state for brief injection is empty by default.
make_fake_tmux() {  # <dir> <session> <worktree>
  local dir=$1 session=$2 worktree=$3 log
  local fb="$dir/fakebin"
  log="$dir/tmux.log"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
log() { printf '%s\n' "\$*" >> "$log"; }
SEEN_PATH=0
PCP_COUNT=0
case "\${1:-}" in
  display-message)
    shift
    target=
    fmt=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -t) shift; target=\$1 ;;
        -p) : ;;
        *) fmt=\$1 ;;
      esac
      shift
    done
    case "\$fmt" in
      '#S'|'#{session_name}')
        printf '%s\n' "$session" ;;
      '#{window_name}')
        printf '\n' ;;
      '#{pane_current_path}')
        # Return project path on first call, then worktree path forever.
        PCP_COUNT=\$((PCP_COUNT + 1))
        if [ "\$PCP_COUNT" -eq 1 ]; then
          printf '%s\n' "\${FM_FAKE_PROJ_ABS:-$worktree}"
        else
          printf '%s\n' "$worktree"
        fi ;;
      '#{cursor_y}')
        printf '0\n' ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
  list-windows)
    printf '\n'; exit 0 ;;
  has-session)
    # Pretend the dedicated session does not exist so spawn creates it.
    exit 1 ;;
  new-session)
    log "new-session \$*"
    exit 0 ;;
  new-window)
    log "new-window \$*"
    exit 0 ;;
  capture-pane)
    # Empty bordered composer for brief injection.
    printf '\\xe2\\x94\\x82 > \\xe2\\x94\\x82\\n'
    exit 0 ;;
  send-keys)
    log "send-keys \$*"
    shift
    target=
    literal=0
    text=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -t) shift; target=\$1 ;;
        -l) literal=1 ;;
        Enter) log "send-keys-enter target=\$target" ;;
        *)
          if [ -n "\$text" ]; then
            text="\$text \$1"
          else
            text="\$1"
          fi ;;
      esac
      shift
    done
    # Capture only the FIRST literal send-keys: the launch command. A kimi spawn
    # also injects the brief via a later 'send-keys -l' into the composer, which
    # must not clobber the launch command we assert on here (brief injection is
    # covered by fm-kimi-inject.test.sh).
    if [ "\$literal" -eq 1 ] && [ -n "\$text" ] && [ ! -f "$dir/launch.txt" ]; then
      printf '%s' "\$text" > "$dir/launch.txt"
    fi
    exit 0 ;;
  load-buffer)
    log "load-buffer \$*"
    cat > "$dir/paste.txt"
    exit 0 ;;
  paste-buffer)
    log "paste-buffer \$*"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Set up a minimal firstmate home, project, and brief.
make_home() {
  local home=$1
  mkdir -p "$home/data/test-id" "$home/state" "$home/projects/foo"
  printf 'implement the thing\n' > "$home/data/test-id/brief.md"
}

run_spawn() {
  local home=$1 fb=$2
  HOME="$home/captain" \
  FM_ROOT_OVERRIDE='' \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE='' \
  FM_DATA_OVERRIDE='' \
  FM_PROJECTS_OVERRIDE='' \
  FM_CONFIG_OVERRIDE='' \
  FM_SPAWN_NO_GUARD=1 \
  PATH="$fb:$PATH" \
    "$SPAWN" test-id projects/foo kimi 2>&1
}

test_launch_template_is_kimi_yolo() {
  local home fb out worktree
  home="$TMP_ROOT/launch"
  worktree="$home/wt"
  mkdir -p "$worktree" "$home/captain/.kimi-code"
  make_home "$home"
  fb=$(make_fake_tmux "$home" testsession "$worktree")

  out=$(run_spawn "$home" "$fb") || fail "spawn failed: $out"
  grep -qF 'kimi --yolo' "$home/launch.txt" || fail "launch command missing 'kimi --yolo'"
  if grep -qF '__BRIEF__' "$home/launch.txt"; then
    fail "launch command contains __BRIEF__ placeholder"
  fi
  printf '%s\n' "$out" | grep -qF 'harness=kimi' || fail "spawn output missing harness=kimi"
  pass "launch template is 'kimi --yolo' with no __BRIEF__ placeholder"
}

test_per_task_home_symlinks_everything_except_config() {
  local home fb out worktree
  home="$TMP_ROOT/home"
  worktree="$home/wt"
  mkdir -p "$worktree" "$home/captain/.kimi-code/credentials" "$home/captain/.kimi-code/oauth"
  printf 'theme = "dark"\n' > "$home/captain/.kimi-code/config.toml"
  make_home "$home"
  fb=$(make_fake_tmux "$home" testsession "$worktree")

  out=$(run_spawn "$home" "$fb") || fail "spawn failed: $out"

  [ -d "$home/state/test-id.kimi-home" ] || fail "per-task KIMI_CODE_HOME missing"
  [ -L "$home/state/test-id.kimi-home/credentials" ] || fail "credentials not symlinked"
  [ -L "$home/state/test-id.kimi-home/oauth" ] || fail "oauth not symlinked"
  [ -f "$home/state/test-id.kimi-home/config.toml" ] || fail "config.toml not copied"
  [ ! -L "$home/state/test-id.kimi-home/config.toml" ] || fail "config.toml is a symlink (must be a copy)"
  pass "per-task home symlinks credentials/oauth and copies config.toml"
}

test_copied_config_contains_stop_hook() {
  local home fb out worktree
  home="$TMP_ROOT/hook"
  worktree="$home/wt"
  mkdir -p "$worktree" "$home/captain/.kimi-code"
  printf 'theme = "dark"\n' > "$home/captain/.kimi-code/config.toml"
  make_home "$home"
  fb=$(make_fake_tmux "$home" testsession "$worktree")

  out=$(run_spawn "$home" "$fb") || fail "spawn failed: $out"

  grep -qF 'event = "Stop"' "$home/state/test-id.kimi-home/config.toml" \
    || fail "Stop event missing in copied config"
  grep -qF "command = \"touch '$home/state/test-id.turn-ended'\"" "$home/state/test-id.kimi-home/config.toml" \
    || fail "Stop command missing or wrong turnend path"
  pass "copied config.toml contains the Stop hook"
}

test_symlinked_source_config_is_copied_not_followed() {
  local home fb out worktree real
  home="$TMP_ROOT/symcfg"
  worktree="$home/wt"
  mkdir -p "$worktree" "$home/captain/.kimi-code"
  real="$home/dotfiles/config.toml"
  mkdir -p "$home/dotfiles"
  printf 'theme = "dark"\n' > "$real"
  ln -s "$real" "$home/captain/.kimi-code/config.toml"
  make_home "$home"
  fb=$(make_fake_tmux "$home" testsession "$worktree")

  out=$(run_spawn "$home" "$fb") || fail "spawn failed: $out"

  [ ! -L "$home/state/test-id.kimi-home/config.toml" ] \
    || fail "config.toml is a symlink (must be a standalone copy)"
  grep -qF 'event = "Stop"' "$home/state/test-id.kimi-home/config.toml" \
    || fail "Stop hook missing from per-task config"
  grep -qF 'event = "Stop"' "$real" \
    && fail "captain's real config was mutated through the symlink"
  pass "symlinked source config is copied, not written through"
}

test_spawn_fails_when_kimi_code_home_missing() {
  local home fb out rc worktree
  home="$TMP_ROOT/noauth"
  worktree="$home/wt"
  mkdir -p "$worktree"
  # Deliberately do NOT create $home/captain/.kimi-code
  make_home "$home"
  fb=$(make_fake_tmux "$home" testsession "$worktree")

  set +e
  out=$(run_spawn "$home" "$fb" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "spawn should fail when ~/.kimi-code is missing"
  printf '%s\n' "$out" | grep -qF "run 'kimi login' first" || fail "missing helpful error message"
  pass "spawn fails fast when ~/.kimi-code is missing"
}

test_launch_template_is_kimi_yolo
test_per_task_home_symlinks_everything_except_config
test_copied_config_contains_stop_hook
test_symlinked_source_config_is_copied_not_followed
test_spawn_fails_when_kimi_code_home_missing
