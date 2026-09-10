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
#   1. Every installed harness that bin/fm-session-lock-lib.sh recognises is
#      launched bare, as a real process, working in a scratch home. It must be
#      reported as a live session OF THAT HOME. A real session reading as absent
#      is the dangerous direction of the error. A harness that owner does not
#      recognise is noted and skipped instead: the overview cannot scope what is
#      not a harness to it, and reporting that as drift here would blame this
#      component for a shortfall in another one.
#   2. If this machine has a real home whose recorded lock names a live harness,
#      every harness process under it must be accounted for - either as a
#      session of that home, as running one of that home's own workers, or as
#      belonging elsewhere - with none unexplained.
#
# Both checks drive the ordinary `--json` contract: the first against a scratch
# home whose recorded session lock names the probe process, the second against
# the real home itself, read-only, because whether a session is working in THAT
# home is the question. Nothing here reads the implementation, so this guard
# cannot drift from the production rule by transcribing it.
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

# The same command against a home that already records its own lock. Nothing is
# written: the inventory is read-only over the home it is pointed at, and the
# lock it reads is the one that home wrote itself. That matters for check 2,
# where the sessions really are working in THAT home - pointed at the scratch
# home instead, no real session could ever be inside FM_HOME and the accounting
# it checks would be zero against zero.
inventory_of_home() {  # <home>
  FM_HOME="$1" "$INVENTORY" --json
}

# Independently enumerate the harness processes under <root>, the way the
# overview scopes itself: harness children of a harness, depth-bounded. Identity
# comes from bin/fm-session-lock-lib.sh, the fleet's single owner of that
# question, so this counts processes without transcribing the rule the overview
# is being checked against.
HARNESS_UNDER=0
count_harness_under() {  # <pid> <depth>
  local pid=$1 depth=$2 child comm args
  [ "$depth" -lt 6 ] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    comm=$(ps -o comm= -p "$child" 2>/dev/null) || continue
    [ -n "$comm" ] || continue
    args=$(ps -o args= -p "$child" 2>/dev/null || true)
    fm_harness_process_matches "$comm" "$args" || continue
    HARNESS_UNDER=$((HARNESS_UNDER + 1))
    count_harness_under "$child" $((depth + 1))
  done
}
harness_processes_under() {  # <root-pid>
  HARNESS_UNDER=0
  count_harness_under "$1" 0
  # A harness with no harness children is itself the only process there is.
  [ "$HARNESS_UNDER" -gt 0 ] || HARNESS_UNDER=1
  printf '%s\n' "$HARNESS_UNDER"
}

# --- 1. a real, live harness working in a home must be reported as its session -

CHECKED=0
SKIPPED=
UNRECOGNISED=

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

for harness in claude codex opencode pi pi-signed omp grok kimi cursor rovo muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its role is unverified here"
    continue
  fi

  # WHAT THIS GUARD IS FOR is the working-directory rule in the overview, not
  # the harness-identity table underneath it. Whether a process counts as a
  # harness at all is bin/fm-session-lock-lib.sh's decision, and it does not
  # cover every harness firstmate can spawn (muse and rovo are not in its
  # tables today). Launching one of those here would fail as "HARNESS IDENTITY
  # DRIFT" every run on a machine that has it installed - reporting a known,
  # separate shortfall in another component as fresh drift in this one. So the
  # owner is asked directly, and a harness it does not claim is noted and
  # skipped before it costs a process.
  if ! fm_harness_process_matches "$bin_path" "$bin_path"; then
    UNRECOGNISED="$UNRECOGNISED $harness"
    note "skip: $harness is installed, but bin/fm-session-lock-lib.sh does not recognise it as a harness, so the overview cannot scope it and this guard has nothing to check (a gap in that owner, not drift here)"
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
if [ -n "$UNRECOGNISED" ]; then
  note "unverified here (installed, but not a harness to bin/fm-session-lock-lib.sh):$UNRECOGNISED"
fi

# --- 2. every harness process under a real home's lock must be accounted for --

# Scoped exactly as production is scoped. bin/fm-session-inventory.sh only ever
# enumerates the harness that owns a home's recorded session lock, so a
# machine-wide sweep for "any harness daemon" would reach process trees the
# command never touches - a desktop app embedding a vendor CLI, for one - and
# report drift for something firstmate does not classify at all.
#
# The inventory runs against that real home, because whether a session is
# working in it is the whole question. That is safe: the command is read-only
# over the home it is pointed at, and the lock it reads is the one that home
# recorded itself. Nothing here writes to a real home.
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
      json=$(inventory_of_home "$ROLE_HOME") || fail "the inventory command failed for $ROLE_HOME"
      owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
      root=$(printf '%s' "$json" | jq -r '.harness_sessions.root_pid // "none"')
      sessions=$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')
      elsewhere=$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')
      own_workers=$(printf '%s' "$json" | jq -r '.harness_sessions.own_workers // 0')
      # `not_checked` has two causes, and only one of them is this guard's
      # subject. sources[] says which: the working-directory read is the input
      # the live-session rule itself rests on, so losing it IS drift here; an
      # unreadable fleet snapshot is an ordinary, disclosed collector failure
      # that merely leaves own_workers unknowable, and reporting it as drift
      # would send the maintainer at the wrong component.
      cwds_ok=$(printf '%s' "$json" | jq -r '[.sources[] | select(.name == "harness-sessions") | .ok] | first // true')
      fleet_ok=$(printf '%s' "$json" | jq -r '[.sources[] | select(.name == "fleet-snapshot") | .ok] | first // true')
      if [ "$owner" = stale ] || [ "$owner" = absent ]; then
        note "the session lock in $ROLE_HOME names no live harness right now, so the lock-owner half of this guard checked nothing"
      elif [ "$owner" = not_checked ] && [ "$cwds_ok" != true ]; then
        fail "LIVE-SESSION DRIFT: the working directory of the processes under harness $root could not be read here, so a live session cannot be told from an idle pool process at all. That is the one input the verdict rests on."
      elif [ "$owner" = not_checked ] || [ "$fleet_ok" != true ]; then
        note "the fleet snapshot for $ROLE_HOME was unreadable this run, so which processes are its own workers is unknowable and the accounting half of this guard checked nothing (that is a snapshot failure, not overview drift)"
      else
        # Every harness process under that root must land on one side or the
        # other: claimed as a session of this home, or counted as belonging
        # elsewhere. One that is neither is a process the overview has quietly
        # lost. Counted twice, because a process starting or exiting between the
        # two reads is an ordinary race on a live machine, while real drift
        # survives a second look.
        found=$(harness_processes_under "$root")
        if [ "$((sessions + own_workers + elsewhere))" != "$found" ]; then
          json=$(inventory_of_home "$ROLE_HOME") || fail "the inventory command failed for $ROLE_HOME"
          sessions=$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')
          elsewhere=$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')
          own_workers=$(printf '%s' "$json" | jq -r '.harness_sessions.own_workers // 0')
          root=$(printf '%s' "$json" | jq -r '.harness_sessions.root_pid // "none"')
          found=$(harness_processes_under "$root")
          [ "$((sessions + own_workers + elsewhere))" = "$found" ] || fail \
            "LIVE-SESSION DRIFT: $found harness process(es) run under harness $root, but the overview accounts for $((sessions + own_workers + elsewhere)) of them ($sessions in this home, $own_workers running this home's own workers, $elsewhere elsewhere). A process that is neither claimed nor counted is one the overview has lost."
        fi
        note "harness $root: $sessions session(s) in this home, $own_workers running this home's workers, $elsewhere elsewhere, $found under the harness, lock_owner=$owner"
        pass "live session: every harness process under this home lock-owning harness is accounted for"
      fi
      ;;
  esac
fi

note "checked $CHECKED installed harness(es)"
cleanup_all
trap - EXIT
