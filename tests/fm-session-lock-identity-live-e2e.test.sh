#!/usr/bin/env bash
# tests/fm-session-lock-identity-live-e2e.test.sh - opt-in guard proving every
# INSTALLED harness is still identified correctly by the session-lock predicates
# in bin/fm-session-lock-lib.sh.
#
# Why this file exists: the whole session-lock verdict is read off things the
# harness vendor emits - the process name it runs under, the argv it presents,
# and the process state the kernel reports for it. A stub agent can only confirm
# the assumption already written into the stub, so the identity of a real
# release has to be checked against a real release. Claude Code already changed
# its own process name to a bare version string once, and every session-lock
# verdict for it was wrong until the classifier was taught the new shape.
#
# What it checks per harness, all against a bare launch with no prompt, so it
# consumes no model tokens:
#   1. the running harness is recognized as a harness at all;
#   2. an unrelated process does NOT get to call that harness its own session,
#      and a running one is treated as a competing holder - the property the
#      session lock exists for;
#   3. a stopped harness is recognized as suspended and stops blocking
#      acquisition, then blocks again once continued.
#
# Each harness runs in its own real pty, because several of them exit
# immediately without a terminal and would be reported as unidentifiable for a
# reason that has nothing to do with identity.
#
# The launch marker that lets a rehosted session recognize its own lock is
# deliberately NOT a pass/fail here: a harness publishes it to the processes it
# starts, and a bare launch with no prompt starts none. This guard reports
# whatever a descendant scan actually finds, with the ambient markers cleared so
# an inherited value from the session running this suite cannot be mistaken for
# the harness's own. docs/verification/runtime-backends.md records the
# per-harness marker evidence and how it was obtained.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. tests/fm-session-lock-ancestry.test.sh pins the same
# logic in CI with real processes and no harness. Run this guard after any
# harness upgrade and before trusting refreshed per-harness evidence.
set -u

if [ "${FM_SESSION_LOCK_IDENTITY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SESSION_LOCK_IDENTITY_LIVE=1 to run the installed-harness session-lock identity guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-session-lock-lib.sh"
SOCKET="fm-session-lock-identity-$$"
LAB=
REAL_TMUX=
# Every harness this guard launched, so no exit path can leave one behind. A
# SIGSTOPped process does not act on the SIGHUP that killing the tmux server
# delivers, so it has to be continued before it can be terminated at all.
LAUNCHED_PIDS=

cleanup_all() {
  local p
  for p in $LAUNCHED_PIDS; do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  return 0
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }
trap cleanup_all EXIT

command -v tmux >/dev/null 2>&1 || fail "tmux not found; this guard needs a real pty because several harnesses exit immediately without one"
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-lock-identity.XXXXXX")
mkdir -p "$LAB/wt"

# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s identity -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# The environment signals the library reads, cleared for every launch so no value
# inherited from the session running this suite can decide a verdict. The list is
# derived from the library's own tables by its single owner, so a signal added
# there is cleared here without this guard being edited.
# shellcheck source=tests/session-signals.sh
. "$ROOT/tests/session-signals.sh"
fm_test_clear_signals_argv
CLEARED=("${FM_TEST_CLEAR_SIGNALS_ARGV[@]}")

# Evaluate one library expression from a process that is NOT related to the
# harness under test, which is the position every competing session speaks from.
probe() {  # <expression>
  "${CLEARED[@]}" bash -c ". \"\$0\"; $1" "$LIB"
}

# Mirror bin/fm-spawn.sh's own resolution order, so this guard covers the same
# binary firstmate would actually launch rather than only what is on PATH.
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

wait_for_state() {  # <pid> <T|running>
  local pid=$1 want=$2 i=0 state
  while [ "$i" -lt 200 ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$want:$state" in
      T:T*) return 0 ;;
      running:T*) : ;;
      running:?*) return 0 ;;
    esac
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Report any launch marker a descendant of <pid> carries that names a process in
# the harness's own run, from the row belonging to <harness> and no other, which
# is the same scoping ownership uses. Informational only.
descendant_marker() {  # <pid> <harness>
  local root=$1 harness=$2 d m
  for d in $(ps -eo pid= -o ppid= 2>/dev/null | awk -v r="$root" '$2 == r { print $1 }'); do
    m=$(probe "fm_session_launcher_pid $d $harness" 2>/dev/null) || continue
    printf '%s\n' "$m"
    return 0
  done
  return 1
}

# Launch <2> (plus the optional extra arguments in <3>) in its own real pty
# window named <1>, reporting the pid of the process running inside it in
# PROBE_PID and whether the library came to see that process as a harness before
# it exited in PROBE_IDENTIFIED, so a caller can tell "never started" from "not
# identified".
#
# <4> is how long to keep asking, and it is a correctness setting rather than a
# speed one. A harness that is running but unidentifiable is drift, and proving
# that needs the whole window; a control that is SUPPOSED to be unidentifiable
# would spend that window every time and report nothing new, so it asks only
# until the process is visible to ps. Pass `visible` for a control.
#
# Both results are globals rather than stdout deliberately: a command
# substitution would run this in a subshell, which loses PROBE_IDENTIFIED and,
# worse, loses the LAUNCHED_PIDS entry that guarantees cleanup reaches every
# process this guard started.
#
# Each launch runs as a CHILD of the pane's shell, not as the pane process
# itself. That is the shape a captain's own session has - a harness started from
# a shell in a pane - and it is the shape the suspended-holder incident was
# observed in. The trailing no-op is what stops bash from exec'ing the target
# into the shell's own pid and making it the session leader.
PROBE_IDENTIFIED=0
PROBE_PID=
launch_identity_probe() {  # <window> <binary> [<extra-args>] [identified|visible]
  local window=$1 target=$2 extra=${3-} until_what=${4:-identified} pane_pid pid='' tracked=''
  PROBE_IDENTIFIED=0
  PROBE_PID=
  # shellcheck disable=SC2086,SC2016  # an empty value must add no argument; the inner shell's $0/$@ are deliberately unexpanded here
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t identity: -n "$window" -c "$LAB/wt" -- \
    "${CLEARED[@]}" bash -c '"$0" "$@"; :' "$target" $extra \
    || fail "could not launch a pty window for the '$window' identity probe of $target"
  for _ in $(seq 1 300); do
    pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "identity:$window" '#{pane_pid}' 2>/dev/null | tr -d '[:space:]')
    case "$pane_pid" in
      ''|*[!0-9]*) sleep 0.2; continue ;;
    esac
    pid=$(ps -eo pid= -o ppid= 2>/dev/null | awk -v r="$pane_pid" '$2 == r { print $1; exit }')
    case "$pid" in
      ''|*[!0-9]*) sleep 0.2; continue ;;
    esac
    if [ "$pid" != "$tracked" ]; then
      LAUNCHED_PIDS="$LAUNCHED_PIDS $pid"
      tracked=$pid
    fi
    if probe "fm_harness_pid_alive $pid"; then
      PROBE_IDENTIFIED=1
      break
    fi
    [ "$until_what" = visible ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  PROBE_PID=$pid
  [ -n "$pid" ] || return 1
  return 0
}

CHECKED=0
SKIPPED=
UNEXERCISED=
MARKERS=
KINDS=
TYPED=0
INSTALL_NAMES_CHECKED=0

# Every primary-capable adapter this repo has verified. muse is crewmate-only and
# never holds a home's session lock, so it is deliberately out of scope here.
for harness in claude codex opencode pi pi-signed grok kimi cursor; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its session-lock identity is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe rather than identify anything; --trust is the
  # same flag fm-spawn passes for the same reason.
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  launch_identity_probe "$harness" "$bin_path" "$launch_args" || true
  pid=$PROBE_PID
  identified=$PROBE_IDENTIFIED

  # A harness that never stayed running was not exercised. That is a fact about
  # this machine, not evidence about identity, so report it instead of turning
  # it into a drift verdict or a silent pass.
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    UNEXERCISED="$UNEXERCISED $harness"
    note "unexercised: $harness $version did not stay running in a bare pty launch here, so its session-lock identity is unverified"
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "identity:$harness" >/dev/null 2>&1 || true
    continue
  fi

  comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
  args=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-120 | tr -d '\n')

  [ "$identified" -eq 1 ] || fail \
    "SESSION-LOCK IDENTITY DRIFT: $harness $version is running but bin/fm-session-lock-lib.sh does not identify it as a harness. Every session-lock verdict for this harness is therefore wrong: its own session start cannot recognize its lock, and a dead holder of its own kind is never reclaimed. Observed process name '$comm'; observed argv '$args'. Teach fm_harness_process_matches the identity this release actually reports."

  if probe "fm_session_same_cohort $pid"; then
    fail "SESSION-LOCK SAFETY FAILURE: $harness $version was accepted as an unrelated process's own session, so a separate concurrent session could take over that home. Observed process name '$comm'; observed argv '$args'."
  fi
  probe "fm_session_lock_holder_competes $pid" || fail \
    "SESSION-LOCK SAFETY FAILURE: a running $harness $version holding a home's lock was not treated as a competing session, so another session would acquire that home. Observed process name '$comm'; observed argv '$args'."

  kill -STOP "$pid" 2>/dev/null || fail "$harness $version: could not suspend the launched harness"
  wait_for_state "$pid" T || fail "$harness $version: the launched harness never reached the stopped state"
  probe "fm_harness_pid_suspended $pid" || fail \
    "SESSION-LOCK IDENTITY DRIFT: a stopped $harness $version was not recognized as suspended, so a suspended session of this harness would hold its home forever. Observed process state '$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')'."
  if probe "fm_session_lock_holder_competes $pid"; then
    kill -CONT "$pid" 2>/dev/null || true
    fail "SESSION-LOCK IDENTITY DRIFT: a stopped $harness $version still blocked acquisition, which is the permanent lockout the suspended-holder decision removes."
  fi
  kill -CONT "$pid" 2>/dev/null || fail "$harness $version: could not resume the launched harness"
  wait_for_state "$pid" running || fail "$harness $version: the launched harness never resumed"
  probe "fm_session_lock_holder_competes $pid" || fail \
    "SESSION-LOCK IDENTITY DRIFT: a resumed $harness $version did not go back to blocking acquisition, so a live session of this harness would lose its own home."

  # The cross-harness refusal rests on one input this guard is the only thing that
  # can check against a real release: which harness this release's EXECUTABLE
  # IDENTITY names. A launch marker is consulted only when the asking session and
  # the holder are both the harness that row was verified for, so two releases
  # that answer with the SAME kind would reopen the path where one harness
  # believes another's inherited marker. The refusal decision itself is pinned
  # portably in tests/fm-session-lock-ancestry.test.sh; what needs a real release
  # is this.
  #
  # An empty answer is not drift. Acceptance typing deliberately reads only the
  # command name and argv[0], so a release whose harness name appears nowhere but
  # in its argument list is identified for ancestry and liveness and still has no
  # accept path, which is the fail-closed outcome the library records as a limit.
  # Report it, because that is the observation a later fix would need.
  kind=$(probe "fm_harness_pid_kind $pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$kind" ]; then
    note "$harness $version: executable identity names no harness, so the launch-marker accept path stays closed for it and its session-lock verdict is decided by process ancestry alone"
  else
    # A wrapper legitimately reports its own verified name rather than the label
    # this loop launched it under - Pi's signed wrapper is exactly that - so a
    # mismatch here is reported rather than failed. What must hold is that two
    # DIFFERENT harnesses do not answer with the same kind, because then either
    # would believe the other's inherited marker.
    [ "$kind" = "$harness" ] || \
      note "$harness $version reports harness kind '$kind' rather than '$harness', which is what its launch-marker scoping will use"
    conflict=
    for seen in $KINDS; do
      [ "${seen#*:}" = "$kind" ] || continue
      # pi and pi-signed are one harness with one engine pid, so they are allowed
      # to answer alike; any other repeat is two harnesses that cannot be told
      # apart.
      case "${seen%%:*} $harness" in
        "pi pi-signed"|"pi-signed pi") continue ;;
      esac
      conflict=${seen%%:*}
      break
    done
    [ -z "$conflict" ] || fail \
      "SESSION-LOCK IDENTITY DRIFT: $harness $version reports the same harness kind '$kind' as $conflict, so the two cannot be told apart and either would believe a launch marker the other exported. Observed process name '$comm'; observed argv '$args'."
    KINDS="$KINDS $harness:$kind"
    TYPED=$((TYPED + 1))
  fi

  # What the harness is called on PATH is almost never what it is called on
  # disk: the PATH entry is a symlink named exactly after the harness, so a
  # launch through it can only ever observe the name this guard already expected.
  # That blind spot is not hypothetical. Claude Code's installed executable is a
  # single-file native build named claude.exe, and while the reported name was
  # compared without normalizing it, every process that exec'd that binary
  # directly - which is what Claude's own background workers do - was identified
  # as a harness and yielded no kind at all, so the session's own start refused
  # its home and degraded to read-only while it was the only session alive. The
  # only way to see that is to launch what is actually installed.
  #
  # A resolved target that is an interpreter SCRIPT is reported rather than
  # failed, because its own name never reaches a reported command name: the
  # kernel runs the interpreter named in its `#!` line, so the process is called
  # after the launcher or the interpreter instead. codex ships exactly that shape.
  real_path=$(readlink -f "$bin_path" 2>/dev/null) || real_path=$bin_path
  [ -n "$real_path" ] || real_path=$bin_path
  if [ "$real_path" = "$bin_path" ]; then
    note "$harness $version: the launched path is the installed executable, so its own name was already the name under test"
  elif [ "$(head -c 2 "$real_path" 2>/dev/null)" = '#!' ]; then
    note "$harness $version: the installed executable ${real_path##*/} is an interpreter script, so its own name never reaches a reported command name and only the launcher name is typed"
  else
    launch_identity_probe "$harness-installed" "$real_path" "$launch_args" || true
    real_pid=$PROBE_PID
    if [ -z "$real_pid" ] || ! kill -0 "$real_pid" 2>/dev/null; then
      note "unexercised: $harness $version did not stay running when launched as its installed executable ${real_path##*/}, so that name is unverified"
    else
      real_comm=$(ps -o comm= -p "$real_pid" 2>/dev/null | tr -d '\n')
      real_args=$(ps -o args= -p "$real_pid" 2>/dev/null | cut -c1-120 | tr -d '\n')
      real_kind=$(probe "fm_harness_pid_kind $real_pid" 2>/dev/null | tr -d '[:space:]')
      [ -n "$real_kind" ] || fail \
        "SESSION-LOCK IDENTITY DRIFT: $harness $version run as its own installed executable ${real_path##*/} reports command name '$real_comm' and is typed as no harness at all, while the same release launched through PATH types as '${kind:-nothing}'. Every process that execs that binary directly is then identified as a harness with no kind, the cohort refuses, and this harness's own session start degrades to read-only against its own home while it is the only session alive. Observed argv '$real_args'."
      if [ -n "$kind" ] && [ "$real_kind" != "$kind" ]; then
        fail "SESSION-LOCK IDENTITY DRIFT: $harness $version types as '$kind' when launched through PATH but as '$real_kind' when launched as its installed executable ${real_path##*/}, so one release answers to two harness names and either could believe a launch marker the other exported. Observed command name '$real_comm'; observed argv '$real_args'."
      fi
      note "$harness $version: installed executable ${real_path##*/} reports comm='$real_comm' acceptance-kind='$real_kind'"
      INSTALL_NAMES_CHECKED=$((INSTALL_NAMES_CHECKED + 1))
      kill "$real_pid" 2>/dev/null || true
    fi
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "identity:$harness-installed" >/dev/null 2>&1 || true
  fi

  # The raw observation, recorded for every installed harness rather than only on
  # failure, because a shape this file's rules do not yet identify is exactly the
  # evidence a later fix needs and inference is not allowed to stand in for it.
  note "$harness $version: comm='$comm' argv='$args' acceptance-kind='${kind:-none}'"
  if marker=$(descendant_marker "$pid" "$harness"); then
    MARKERS="$MARKERS $harness=$marker"
    note "$harness $version: a descendant carries this harness's own launch marker naming pid $marker"
  else
    note "$harness $version: no descendant of a bare launch carried a launch marker verified for $harness"
  fi

  "$REAL_TMUX" -L "$SOCKET" kill-window -t "identity:$harness" >/dev/null 2>&1 || true
  pass "session-lock identity: $harness $version is identified, refuses an unrelated session, and releases while suspended"
  CHECKED=$((CHECKED + 1))
done

# The reporter itself, on this machine. Everything above depends on what ps and
# the kernel here do to a command name, and that differs by platform: procps
# reports the kernel task name and cuts it at 15 characters, while BSD ps reports
# argv[0] and does not. So the two artifacts the library normalizes are produced
# locally, from real executables carrying those exact names, and the names are
# read back through the same ps the library calls.
#
# The near misses matter as much as the acceptances. Normalization strips two
# artifacts before an unchanged exact-equality test, and this is where a widening
# into a prefix rule would show up on the real platform rather than in a fleet.
REPORTER_LAB="$LAB/reporter"
mkdir -p "$REPORTER_LAB"
REPORTER_CHECKED=0
# The two acceptance names are the artifacts a real Claude Code install produces;
# the four after them differ from a verified harness name only in ways
# normalization must not undo.
REPORTER_NAMES=('claude.exe' 'claude bg-pty-host' claudette claude-code node python3)
for reporter_name in "${REPORTER_NAMES[@]}"; do
  ln -sf /bin/bash "$REPORTER_LAB/$reporter_name"
  case "$reporter_name" in
    'claude.exe'|'claude bg-pty-host') reporter_want=claude ;;
    *) reporter_want= ;;
  esac
  launch_identity_probe "reporter-$REPORTER_CHECKED" "$REPORTER_LAB/$reporter_name" '' visible || true
  reporter_pid=$PROBE_PID
  if [ -z "$reporter_pid" ] || ! kill -0 "$reporter_pid" 2>/dev/null; then
    fail "the reporter control named '$reporter_name' never stayed running, so this machine's command-name reporting is unverified"
  fi
  reporter_comm=$(ps -o comm= -p "$reporter_pid" 2>/dev/null | tr -d '\n')
  reporter_base=${reporter_comm##*/}
  reporter_kind=$(probe "fm_harness_exec_kind '$reporter_base' ''" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$reporter_want" ]; then
    # Divergence first: a control that stopped carrying the artifact would pass
    # without testing anything, which is the failure this whole guard removes.
    [ "$reporter_base" != "$reporter_want" ] || fail \
      "the reporter control '$reporter_name' was reported as the bare name '$reporter_base', so this machine no longer reproduces the artifact and the check below would pass vacuously"
    [ "$reporter_kind" = "$reporter_want" ] || fail \
      "SESSION-LOCK IDENTITY DRIFT: a real process reporting command name '$reporter_comm' is typed as '${reporter_kind:-nothing}' rather than $reporter_want on this machine. That is a command name Claude Code actually runs under, so its own session start would refuse its home and degrade to read-only while it is the only session alive."
  else
    [ -z "$reporter_kind" ] || fail \
      "SESSION-LOCK SAFETY FAILURE: a real process named '$reporter_name' is typed as '$reporter_kind' on this machine, so an unrelated process could be accepted as a session's own harness and take over its home."
  fi
  note "reporter control '$reporter_name': comm='$reporter_comm' acceptance-kind='${reporter_kind:-none}' (expected ${reporter_want:-none})"
  kill "$reporter_pid" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "identity:reporter-$REPORTER_CHECKED" >/dev/null 2>&1 || true
  REPORTER_CHECKED=$((REPORTER_CHECKED + 1))
done
[ "$REPORTER_CHECKED" -eq "${#REPORTER_NAMES[@]}" ] || fail \
  "only $REPORTER_CHECKED of the ${#REPORTER_NAMES[@]} command-name reporter controls ran, so this machine's reporting is only partly verified"
pass "session-lock identity: this machine's reported command names are typed after the reporter's own artifacts, and near misses still are not"

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness was exercised here, so this run proved nothing; install at least one harness that stays running in a bare pty launch before trusting a pass"

# Distinctness needs two acceptance kinds to compare, so say plainly when fewer
# were available rather than letting that read as having checked it.
if [ "$TYPED" -ge 2 ]; then
  pass "session-lock identity: the $TYPED exercised harnesses that name themselves by executable identity each report a distinct harness kind, so neither can believe the other's inherited launch marker"
else
  note "unchecked: the cross-harness kind distinctness that scopes launch markers needs two harnesses that name themselves by executable identity, and only $TYPED did here (kinds observed:$KINDS)"
fi

if [ "$INSTALL_NAMES_CHECKED" -eq 0 ]; then
  note "unchecked: no installed harness here resolved to a native executable under a different name, so the installed-executable name check had nothing to exercise"
fi
[ -z "$SKIPPED" ] || note "unverified on this machine (not installed):$SKIPPED"
[ -z "$UNEXERCISED" ] || note "unverified on this machine (did not stay running):$UNEXERCISED"
[ -z "$MARKERS" ] || note "observed launch markers:$MARKERS"
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
