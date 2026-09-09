#!/usr/bin/env bash
# tests/fm-session-inventory-live-e2e.test.sh - opt-in drift guard for the
# live-session verdict in bin/fm-session-inventory.sh.
#
# Why this file exists: almost everything about a harness background session is
# structural - whether a process is a verified harness is owned by
# bin/fm-session-lock-lib.sh, and the parent/child relation is a kernel fact.
# The remaining judgement is which of those processes is a live session working
# in THIS home, and it is answered from the process working directory.
#
# That answer depends on one piece of real vendor behaviour: a harness pre-warms
# pooled processes and turns one into a session by CLAIMING it, and a claimed
# process works in the home or worktree it was claimed for. Reading argv instead
# is what this guard used to check, and it is exactly what failed - a claimed
# process keeps the argv it started with, so four live sessions in one home were
# reported as zero. If a future release stops moving a claimed process into the
# home, the overview would silently go back to reporting zero sessions while
# several are running. Only a real harness release can cause that, and no stub
# can see it.
#
# Two independent checks run here, and each fails naming the harness and its
# version:
#   1. Every installed harness is launched bare, as a real process, working in a
#      scratch home. It must be reported as a live session OF THAT HOME. A real
#      session reading as absent is the dangerous direction of the error.
#   2. If this machine has a real home whose recorded lock names a live harness,
#      every harness process under it must be accounted for - either as a
#      session of that home or as belonging elsewhere - with none unexplained.
#
# Both checks drive the ordinary `--json` contract against a scratch home whose
# recorded session lock names the process under test. Nothing here reads the
# implementation, so this guard cannot drift from the production rule by
# transcribing it.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. Standard CI has no harness binaries or credentials, so this guard is
# opt-in and on-demand; tests/fm-session-inventory.test.sh pins the portable
# logic in CI with real processes and no harness. Run this after any harness
# upgrade, and before trusting refreshed per-harness evidence.
set -u

if [ "${FM_SESSION_ROLE_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_SESSION_ROLE_DRIFT=1 to run the installed-harness live-session drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$ROOT/bin/fm-session-inventory.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-role.XXXXXX") || exit 1
SOCKET="fm-session-role-$$"
SESSION=roles
REAL_TMUX=
cleanup_all() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  return 0
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || fail "jq not found"
# A private tmux server gives each harness a real terminal. Without one an
# interactive harness exits the instant it is launched with no tty, and this
# guard would report drift that is entirely its own fault.
command -v tmux >/dev/null 2>&1 || fail "tmux not found; it is what gives each harness a real terminal here"
REAL_TMUX=$(command -v tmux)

# shellcheck source=bin/fm-session-lock-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-cursor-lib.sh"

# The scratch home is what each probe harness is launched IN, because working in
# the home is precisely the signal under test.
HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB" \
  || fail "could not start the private tmux server"

# Ask the real command what it sees, with <pid> recorded as this scratch home's
# session lock. That is the ordinary path: the inventory scopes harness sessions
# to the harness that owns the recorded lock.
inventory_for() {  # <pid>
  printf '%s\n' "$1" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" "$INVENTORY" --json
}

# --- 1. a real, live harness working in a home must be reported as its session -

CHECKED=0
SKIPPED=

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch. Kimi and cursor are routinely absent
# from a non-interactive PATH under the name the adapter uses.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  return 1
}

for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its role is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  launch_args=""
  # cursor blocks on a workspace-trust prompt in a directory it has never seen;
  # --trust is the same flag fm-spawn passes for the same reason.
  [ "$harness" = cursor ] && launch_args="--trust"
  # The window is opened IN the scratch home: a harness working in a home is
  # what a claimed session looks like, and what must be reported as one.
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$HOME_DIR" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the live-session probe"

  pid=
  observed=
  for _ in $(seq 1 100); do
    pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:$harness" '#{pane_pid}' 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) pid= ;; esac
    if [ -n "$pid" ]; then
      observed=$(ps -o args= -p "$pid" 2>/dev/null || true)
      [ -n "$observed" ] && break
    fi
    sleep 0.1
  done
  if [ -z "$pid" ] || [ -z "$observed" ]; then
    note "skip: $harness $version exited before it could be observed"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:$harness" >/dev/null 2>&1 || true
    continue
  fi

  json=$(inventory_for "$pid") || fail "$harness $version: the inventory command failed"
  if ! kill -0 "$pid" 2>/dev/null; then
    note "skip: $harness $version exited while it was being inventoried"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:$harness" >/dev/null 2>&1 || true
    continue
  fi
  owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
  sessions=$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')

  [ "$owner" != stale ] || fail \
    "HARNESS IDENTITY DRIFT: a live $harness $version process is not recognised as a harness at all, so the running-session overview can never scope this home. Observed argv: [$observed]. bin/fm-session-lock-lib.sh owns that identity."
  [ "${sessions:-0}" -ge 1 ] || fail \
    "LIVE-SESSION DRIFT: a live $harness $version process working in a home is reported as no session at all (lock_owner=$owner). The overview would tell the captain nothing is running while a real session is. This release may no longer move a claimed process into the home it was claimed for; observed argv: [$observed]. The working-directory rule in bin/fm-session-inventory.sh is what needs revisiting."

  note "$harness $version: sessions=$sessions lock_owner=$owner argv=[$observed]"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:$harness" >/dev/null 2>&1 || true
  pass "live session: a working $harness $version process is reported as this home's session"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness could be launched here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi

# --- 2. every harness process under a real home's lock must be accounted for --

# Scoped exactly as production is scoped. bin/fm-session-inventory.sh only ever
# enumerates the harness that owns a home's recorded session lock, so a
# machine-wide sweep for "any harness daemon" would reach process trees the
# command never touches - a desktop app embedding a vendor CLI, for one - and
# report drift for something firstmate does not classify at all.
#
# Only the home's recorded lock pid is read here. The inventory itself still
# runs against the scratch home, so a real home is never written to.
ROLE_HOME=${FM_SESSION_ROLE_HOME:-${FM_HOME:-}}

if [ -z "$ROLE_HOME" ]; then
  note "no home named (set FM_SESSION_ROLE_HOME or FM_HOME), so the lock-owner half of this guard checked nothing"
elif [ ! -r "$ROLE_HOME/state/.lock" ]; then
  note "$ROLE_HOME records no session lock, so the lock-owner half of this guard checked nothing"
else
  lock_pid=$(cat "$ROLE_HOME/state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*)
      note "$ROLE_HOME records no usable session lock, so the lock-owner half of this guard checked nothing"
      ;;
    *)
      json=$(inventory_for "$lock_pid") || fail "the inventory command failed for lock pid $lock_pid"
      owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
      root=$(printf '%s' "$json" | jq -r '.harness_sessions.root_pid // "none"')
      sessions=$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')
      elsewhere=$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')
      rows=$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")] | length')
      if [ "$owner" = stale ] || [ "$owner" = absent ]; then
        note "the session lock in $ROLE_HOME names no live harness right now, so the lock-owner half of this guard checked nothing"
      elif [ "$owner" = not_checked ]; then
        fail "LIVE-SESSION DRIFT: the working directory of the processes under harness $root could not be read here, so a live session cannot be told from an idle pool process at all. That is the one input the verdict rests on."
      else
        # Every listed row must be a session of this home, and the counted total
        # must match: a process that is neither claimed nor counted is one the
        # overview has quietly lost.
        [ "$rows" = "$sessions" ] || fail \
          "LIVE-SESSION DRIFT: harness $root reports $sessions session(s) but lists $rows row(s); the overview is counting and showing different things."
        note "harness $root: $sessions session(s) in this home, $elsewhere elsewhere, lock_owner=$owner"
        pass "live session: every harness process under this home lock-owning harness is accounted for"
      fi
      ;;
  esac
fi

note "checked $CHECKED installed harness(es)"
cleanup_all
trap - EXIT
