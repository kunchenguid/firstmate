#!/usr/bin/env bash
# tests/fm-spawn-herdr-flat-abort-e2e.test.sh - mandatory ISOLATED end-to-end
# real-Herdr regression for the flat-spawn abort cleanup in bin/fm-spawn.sh
# (spawn_abort_cleanup).
#
# The guarantee under test: when a flat Herdr spawn fails its `treehouse get`
# worktree wait, the abort closes exactly the pane that spawn created, so the
# pane shell and a hung `treehouse get` cannot survive it. Before this cleanup,
# each timed-out spawn left its pane and a hung `treehouse get` behind; a
# supervisor cleared them with the fleet-wide `pkill -f 'treehouse[ ]get'`,
# which killed the live `treehouse get` parent of every running worker and
# froze the fleet on 2026-09-16.
#
# The scratch project's origin is an `ext::` remote helper that records its own
# PID and then sleeps, so the real `treehouse get` in the pane blocks
# deterministically at its fetch step no matter what PATH that pane shell has.
# A short `sleep` stub on fm-spawn's own PATH keeps its 60-poll worktree wait
# bounded.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): every lifecycle
# operation goes through bin/fm-herdr-lab.sh, which appends the named session
# flag and verifies the default fleet session is unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-flat-abort.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-spawn-flat-abort) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
LAB_READY=0
HANG_PID_FILE="$TMP_ROOT/treehouse-fetch.pid"
REAL_SLEEP=$(command -v sleep)
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse"

cleanup_all() {
  local hang_pid
  if [ -f "$HANG_PID_FILE" ]; then
    IFS= read -r hang_pid < "$HANG_PID_FILE" || true
    [ -z "${hang_pid:-}" ] || kill "$hang_pid" 2>/dev/null || true
  fi
  if [ "$LAB_READY" = 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# Only fm-spawn's own PATH gets this stub; the pane keeps its normal
# environment because the project's remote helper, not PATH, owns the hang.
cat > "$FAKEBIN/sleep" <<SH
#!/usr/bin/env bash
exec "$REAL_SLEEP" 0.05
SH
chmod +x "$FAKEBIN/sleep"

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
TASK_ID="flat-abort"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$TASK_ID"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/data/$TASK_ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise the flat spawn abort cleanup for $TASK_ID.

## Firstmate spec
Assert exactly the failure path under test.
EOF

git init -q "$PROJECT_DIR"
printf 'base\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
# The fetch-hang fixture: a remote helper that records its own PID and then
# never returns, so the pane's `treehouse get` waits on it indefinitely.
cat > "$TMP_ROOT/hang.sh" <<SH
#!/bin/sh
echo "\$\$" > "$HANG_PID_FILE"
exec sleep 600
SH
chmod +x "$TMP_ROOT/hang.sh"
git -C "$PROJECT_DIR" config protocol.ext.allow always
git -C "$PROJECT_DIR" remote add origin "ext::$TMP_ROOT/hang.sh $HANG_PID_FILE"

SPAWN_OUT="$TMP_ROOT/spawn.out"
set +e
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$TASK_ID" "$PROJECT_DIR" --scout --backend herdr \
  >"$SPAWN_OUT" 2>&1
SPAWN_RC=$?
set -e
[ "$SPAWN_RC" -ne 0 ] \
  || fail "the forced flat-spawn worktree timeout unexpectedly succeeded: $(cat "$SPAWN_OUT")"
grep -F "did not enter an isolated worktree" "$SPAWN_OUT" >/dev/null 2>&1 \
  || fail "the flat spawn did not reach the forced worktree-wait refusal: $(cat "$SPAWN_OUT")"

# The refusal names the exact pane it created; that pane must be gone, and the
# hung fetch its `treehouse get` was blocked on must be gone with it.
PANE=$(sed -n 's/.*inspect window [^:]*:\([^ )]*\).*/\1/p' "$SPAWN_OUT" | tail -1)
[ -n "$PANE" ] || fail "the flat spawn refusal did not name the created pane: $(cat "$SPAWN_OUT")"
PRESENCE=unknown
for _ in $(seq 1 50); do
  # Herdr prints the pane_not_found error object on stderr and exits nonzero,
  # so the probe must read both streams before parsing.
  PRESENCE=$(lab pane get "$PANE" 2>&1 | jq -r '.error.code // empty' 2>/dev/null || true)
  if [ "$PRESENCE" = pane_not_found ]; then
    break
  fi
  "$REAL_SLEEP" 0.1
done
[ "$PRESENCE" = pane_not_found ] \
  || fail "the aborted flat spawn left pane $PANE alive, so its hung treehouse get could survive: $PRESENCE"

for _ in $(seq 1 50); do
  [ -f "$HANG_PID_FILE" ] && break
  "$REAL_SLEEP" 0.1
done
[ -f "$HANG_PID_FILE" ] \
  || fail "the fixture never armed: the pane did not reach the hanging fetch"
HANG_PID=$(cat "$HANG_PID_FILE")
for _ in $(seq 1 50); do
  kill -0 "$HANG_PID" 2>/dev/null || break
  "$REAL_SLEEP" 0.1
done
kill -0 "$HANG_PID" 2>/dev/null \
  && fail "the hung treehouse fetch from the aborted attempt survived (pid $HANG_PID)"
if [ -d /proc ]; then
  for pid_dir in /proc/[0-9]*; do
    [ -d "$pid_dir" ] || continue
    cmd=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null) || continue
    case "$cmd" in
      *treehouse*) ;;
      *) continue ;;
    esac
    cwd=$(readlink "$pid_dir/cwd" 2>/dev/null) || continue
    case "$cwd" in
      "$TMP_ROOT"*) fail "an aborted flat spawn left a treehouse process alive in $cwd: $cmd" ;;
    esac
  done
fi
pass "real Herdr: an aborted flat spawn closes its exact pane and leaves no hung treehouse get behind"
