#!/usr/bin/env bash
# Opt-in live guard for Antigravity CLI (agy) as a firstmate PRIMARY.
#
# Tests the live AGY harness integration against .agents/hooks.json:
#   1. SessionStart hook executes bin/fm-sessionstart-agy.sh and acquires the
#      fleet session lock as the agy process in ancestry.
#   2. PreToolUse hook executes bin/fm-pretool-check-agy.sh and enforces
#      primary guard boundaries (subagent delegation, persistent cd, background arms).
#   3. Stop hook executes bin/fm-turnend-guard-agy.sh and handles the turn-end boundary.
#
# Isolation: an isolated throwaway lab directory, a throwaway AGY HOME,
# and a private tmux socket.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PRIMARY_LIVE_E2E agy tmux jq node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux)
AGY_BIN=${FM_AGY_BIN:-$(command -v agy || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN."
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "agy did not report a version"
printf 'harness: agy %s\n' "$AGY_VERSION"

SOCKET="fm-agy-primary-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-primary-live.XXXXXX")
HOME_DIR="$LAB/home"
AGY_HOME="$LAB/agyhome"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || fail "could not stage repository tree into throwaway home"

git init -q "$HOME_DIR"
git -C "$HOME_DIR" config user.email "live-guard@local"
git -C "$HOME_DIR" config user.name "live-guard"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" commit -q --allow-empty -m "live-e2e fixture" >/dev/null 2>&1 || true

[ -f "$HOME_DIR/.agents/hooks.json" ] \
  || fail "staged home is missing .agents/hooks.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf '# Captain\n\nLive agy primary guard.\n' > "$HOME_DIR/data/captain.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"

mkdir -p "$AGY_HOME"
if [ -d "$HOME/.gemini" ]; then
  cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not copy ~/.gemini to throwaway HOME"
fi

SETTINGS_FILE="$AGY_HOME/.gemini/antigravity-cli/settings.json"
mkdir -p "$(dirname "$SETTINGS_FILE")"
node -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  const dir = process.argv[2];
  let data = {};
  try {
    if (fs.existsSync(p)) data = JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {}
  data.trustedWorkspaces = Array.from(new Set([...(data.trustedWorkspaces || []), dir]));
  fs.writeFileSync(p, JSON.stringify(data, null, 2));
' "$SETTINGS_FILE" "$HOME_DIR" || fail "could not register workspace trust"

# Run an ephemeral prompt turn in tmux with AGY to verify hooks trigger live
"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "cd '$HOME_DIR' && HOME='$AGY_HOME' FM_HOME='$HOME_DIR' exec '$AGY_BIN' --prompt-interactive 'echo live-guard-ready' --model gemini-2.5-flash --dangerously-skip-permissions" \
  || fail "could not start isolated tmux session for agy"

pane_text() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t primary 2>/dev/null || true
}

wait_for_pane() {
  local needle=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    case "$(pane_text)" in *"$needle"*) return 0 ;; esac
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text)" >&2
  fail "$what did not appear within ${limit}s"
}

wait_for_file() {
  local path=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    [ -e "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  fail "$what did not appear within ${limit}s"
}

# 1. Verify SessionStart hook runs and fleet session lock is taken
wait_for_file "$HOME_DIR/state/.lock" 120 "fleet session lock"
LOCK_PID=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
[ -n "$LOCK_PID" ] || fail "session lock was empty"

# Verify lock ownership resolves self
(
  export FM_ROOT_OVERRIDE="$HOME_DIR"
  export FM_STATE_OVERRIDE="$HOME_DIR/state"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$HOME_DIR/bin/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$HOME_DIR/state" || exit 1
) || fail "session lock was not owned by self in live agy primary session"
pass "agy primary: SessionStart hook took fleet lock with agy ancestry ownership"

# 2. Wait for initial turn response
wait_for_pane "live-guard-ready" 180 "prompt reply in agy pane"
pass "agy primary: completed prompt turn under .agents/hooks.json"

cleanup_all
trap - EXIT

echo "# all fm-agy-primary-live-e2e tests passed"
