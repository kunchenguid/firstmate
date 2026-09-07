#!/usr/bin/env bash
# tests/fm-session-inventory-live-e2e.test.sh - opt-in drift guard for the
# session-vs-spare role verdict in bin/fm-session-inventory.sh.
#
# Why this file exists: everything else about a harness background session is
# structural - whether a process is a verified harness is owned by
# bin/fm-session-lock-lib.sh, and the parent/child relation is a kernel fact.
# The one remaining judgement reads vendor-supplied argv: is this daemon child a
# live session, or an idle pooled spare waiting to claim work? That answer comes
# from flags the harness vendor controls and can rename in any release. Get it
# wrong in the pooled direction and a real concurrent session is presented to
# the captain as a harmless idle process - exactly the confusion this overview
# exists to end. Only a real harness release can cause that regression, and no
# stub can see it.
#
# Two independent checks run here, and each fails naming the harness and its
# version:
#   1. Every installed harness is launched bare, as a real process, and must not
#      be reported as an idle spare. A real session reading as pool is the
#      dangerous direction of the error.
#   2. If a real harness daemon is running on this machine, every harness child
#      of it must be reported with a KNOWN role. An "unknown" there is the
#      earliest possible warning that a vendor flag was renamed, while the
#      inventory is still refusing to guess rather than mislabelling anything.
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
  echo "skip: set FM_SESSION_ROLE_DRIFT=1 to run the installed-harness session-role drift guard"
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

mkdir -p "$LAB/home/state" "$LAB/home/data"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/home/data/backlog.md"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB" \
  || fail "could not start the private tmux server"

# Ask the real command what it sees, with <pid> recorded as this scratch home's
# session lock. That is the ordinary path: the inventory scopes harness sessions
# to the harness that owns the recorded lock.
inventory_for() {  # <pid>
  printf '%s\n' "$1" > "$LAB/home/state/.lock"
  FM_HOME="$LAB/home" "$INVENTORY" --json
}

# --- 1. a real, live harness process must never be reported as a pooled spare -

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
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the role probe"

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
  role=$(printf '%s' "$json" | jq -r --argjson pid "$pid" \
    '.rows[] | select(.kind == "harness-session" and .pid == $pid) | .label')

  [ "$owner" != stale ] || fail \
    "HARNESS IDENTITY DRIFT: a live $harness $version process is not recognised as a harness at all, so the running-session overview can never scope this home. Observed argv: [$observed]. bin/fm-session-lock-lib.sh owns that identity."
  [ -n "$role" ] || fail \
    "$harness $version: the inventory reported no row for the live process it was pointed at (lock_owner=$owner, argv [$observed])"
  [ "$role" != spare ] || fail \
    "SESSION-ROLE DRIFT: a live $harness $version process is reported as an idle pooled spare. The overview would present a real concurrent session to the captain as a harmless idle process. Observed argv: [$observed]. Fix the pool tokens in session_role in bin/fm-session-inventory.sh."

  note "$harness $version: role='$role' argv=[$observed]"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:$harness" >/dev/null 2>&1 || true
  pass "session role: a live $harness $version process is not reported as a pooled spare"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness could be launched here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi

# --- 2. every child of THIS HOME's lock-owning harness must have a known role -

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
      count=$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")] | length')
      if [ "$owner" = stale ] || [ "$owner" = absent ]; then
        note "the session lock in $ROLE_HOME names no live harness right now, so the lock-owner half of this guard checked nothing"
      elif [ "${count:-0}" -eq 0 ]; then
        note "harness $root has no background sessions right now, so the lock-owner half of this guard checked nothing"
      else
        unknown=$(printf '%s' "$json" | jq -r \
          '[.rows[] | select(.kind == "harness-session" and .label == "unknown") | "\(.pid)"] | join(" ")')
        if [ -n "$unknown" ]; then
          argv=$(ps -o args= -p "${unknown%% *}" 2>/dev/null || true)
          fail "SESSION-ROLE DRIFT: background session(s) $unknown under harness $root match neither the session nor the pool tokens, so the overview cannot tell the captain whether they are real concurrent sessions. Observed argv: [$argv]. Teach session_role in bin/fm-session-inventory.sh the tokens this release actually uses."
        fi
        note "harness $root: $(printf '%s' "$json" | jq -r '"\(.harness_sessions.sessions) session(s), \(.harness_sessions.spares) spare(s), lock_owner=\(.harness_sessions.lock_owner)"')"
        pass "session role: all $count background session(s) under this home lock-owning harness are reported with a known role"
      fi
      ;;
  esac
fi

note "checked $CHECKED installed harness(es)"
cleanup_all
trap - EXIT
