#!/usr/bin/env bash
# Task-scoped chrome-devtools-axi bridge bindings.
#
# fm_chrome_task_session_name <state-dir> <task-id>
#   Prints a deterministic, non-default chrome-devtools-axi session name bound
#   to one task in one Firstmate home. The task-id prefix is diagnostic only;
#   the digest prevents equal task ids in separate homes from sharing a bridge.
#
# fm_chrome_binding_write <state-dir> <task-id>
#   Atomically writes <state-dir>/<task-id>.chrome-devtools-session, mode 0600,
#   with the exact session and a started marker, then exports the session through
#   FM_CHROME_TASK_SESSION. Every later rewriter of that record - the worker's
#   launcher under its own ambient umask, and cleanup's marker reset - restores
#   the same mode, so the record never widens after the task's first browser call.
#   A fresh record starts at started=0; rewriting the record for the same session
#   (relaunch) keeps an existing started=1 so a prior incarnation's live bridge
#   stays owned by the task. It also retires the binding's in-flight set: this is
#   the one moment no launcher of this binding can be running, so a registration
#   a killed browser call left behind is cleared here instead of declining every
#   later marker reset for the task.
#
# fm_chrome_launcher_dir_create <parent-dir>
#   Prints a fresh launcher directory created under an already-verified private
#   parent. The name carries a random component from mktemp, so the launcher
#   path is unpredictable even though the task temp root it lives in is a
#   derivable /tmp/fm-<id> name. mktemp also fails rather than reusing an
#   existing directory, so nothing pre-created can become the launcher.
#
# fm_chrome_wrapper_write <state-dir> <task-id> <wrapper-path> <real-tool>
#   Writes a task-private chrome-devtools-axi launcher, the one component on the
#   worker's execution path that can both scope a browser call and witness it.
#   A delegated command is treated as able to start a bridge, and the launcher
#   atomically changes started=0 to started=1 before handing it over, unless it is
#   one of the diagnostic and setup commands that demonstrably do not connect: the
#   bare no-argument invocation, setup, and help or version asked as the sole
#   argument. Sole argument is the whole exemption for the flags: -v is a common
#   verbose switch as well as a version alias, so a flag that merely prefixes a
#   real command marks the binding and delegates. Over-marking costs one bounded
#   status call at teardown; under-marking loses the bridge. The bare one matters
#   most and is not a guess - it is the status read this library itself makes to
#   ask whether a session is live, including against a nonce nothing ever started,
#   and it is what an agent harness runs at session start to print the tool's
#   banner. Marking on it would set the marker for every task on such a host
#   before the worker had done anything, and the whole point of the marker is that
#   an untouched task costs teardown nothing.
#   The mark is written under the binding's mutex, together with registering the
#   call in the binding's in-flight set, and the registration is retired only when
#   the browser command returns - which is why the command is run as a child
#   rather than exec'd. A mark on its own says a bridge exists; the registration
#   says the bridge behind it is still coming up, so nobody may yet conclude
#   anything about it.
#   A delegated stop does not mark either; if the tool reports it succeeded, the
#   launcher clears the marker back to started=0 exactly as cleanup does, so a
#   worker that shut its own bridge down costs teardown no browser call at all. A
#   stop the tool reports failed leaves the marker set, so that task stays
#   cleanup-eligible. That reset carries cleanup's concurrency guard too, and for
#   the same reason: the record is stamped before the stop is handed over, the
#   comparison and the write happen together under the mutex so no fresh mark can
#   land between them, and a stamp refused because a record was replaced or
#   because a browser call is still in flight - a worker that ran a bridge-capable
#   command alongside its own stop - keeps its started=1 rather than having it
#   overwritten, because the stop that just returned says nothing about the bridge
#   that mark describes.
#   Every delegated command is handed to the real tool with the recorded session
#   forced and any ambient CHROME_DEVTOOLS_AXI_PORT dropped, so the binding holds
#   even when the pane shell's exports did not survive to the caller: a scrubbed
#   environment, a nested shell, or an rc file that re-exports the port can no
#   longer put a marked task's bridge on the captain's shared session. The
#   launcher refuses to be written at all unless the session it would force is the
#   one already recorded for the task.
#   The launcher becomes the first entry on the worker's PATH, so it is written
#   only into a directory this user owns that no one else can write, and both the
#   directory and its parent are checked: the task temp root is a predictable
#   /tmp path, and a pre-created one must never let a local user shadow the
#   worker's commands. A directory that fails the check is refused, and the
#   caller drops the PATH prepend instead of launching through it.
#
# fm_chrome_bridge_bound
#   Prints the seconds one browser call may take, from FM_CHROME_BRIDGE_TIMEOUT:
#   unset, non-numeric, and zero take the 20-second default, and anything above
#   the 120-second ceiling is cut to it rather than honoured. A knob that bounds
#   teardown-time work cannot itself be a way to un-bound teardown.
#
# fm_chrome_axi_run <session> [args...]
#   The single door to the browser tool. Every call names the session, drops an
#   ambient CHROME_DEVTOOLS_AXI_PORT (which the tool documents as overriding the
#   port it otherwise derives from the session name, so an inherited one would
#   silently retarget another bridge), and runs under a hard bound because the
#   tool can be a wrapper chain onto a browser that stopped answering.
#
# fm_chrome_session_liveness <session>
#   Prints inactive, present, or unreadable for that exact named session by asking
#   the tool for its status. The tool's only statement this repo has evidence for
#   is the negative one - it reports "no active session" for a name with no bridge
#   behind it - so inactive is the single confident answer, and no wording for a
#   live bridge is guessed at. The other two separate "the tool said something
#   about this name that was not the gone answer" (present) from "the tool said
#   nothing usable at all" - empty output, or the bound was hit (unreadable).
#   Only inactive and present are evidence; unreadable is the absence of it.
#
# fm_chrome_probe_session_name <task-session>
#   Mints one fresh probe name from the task's own binding: the fmprobe- marker,
#   half of the digest that already makes this task's session unique to this task
#   and this home, and a random nonce. It is therefore non-default, derived
#   entirely within this task binding, never the name of a shared or default
#   session and never able to fall back to one, and - being freshly minted - a
#   name nothing in this fleet has ever started. It is built from the digest
#   rather than by extending the session because the session is already most of
#   the name budget: session names are an argument to someone else's tool, the
#   dispatchers this fleet meets refuse anything past
#   FM_CHROME_SESSION_NAME_MAX, and a refused name comes back looking like an
#   ordinary answer that is not the gone answer - which would read as a tool that
#   fails the ownership proof rather than one that was never asked. The minted
#   name is a fixed 41 characters whatever the task id, and the function fails
#   rather than return a name that is too long or that it could not make random.
#
# fm_chrome_session_scoping_proved <session>
#   Whether the resolved tool was shown to act on the session it is handed, by
#   asking it about a freshly minted probe name and requiring the one answer this
#   repo has evidence for: the gone answer. A tool that rewrites every invocation
#   onto one shared bridge, or an inherited port that pins every invocation to one
#   bridge, answers something else for that never-started name; so does a tool
#   that cannot be read at all. Both fail the proof, and this reports only that -
#   which of them is true is not something the answer establishes, so cleanup does
#   not claim it. The probe is evidence only: on its own it authorises nothing,
#   and a stop additionally requires the task's own session to answer differently.
#   Consequence worth stating plainly: on a host whose resolved chrome-devtools-axi
#   is a wrapper that hardcodes one shared session name for every call, the proof
#   fails every time, so this reclamation is inert there. That is the deliberate
#   trade - the only stop such a wrapper would carry out is a stop of the captain's
#   own bridge. Task-scoped reclamation starts working on that host as soon as its
#   wrapper passes CHROME_DEVTOOLS_AXI_SESSION through instead of pinning it. The
#   disclosure says what was observed - the probe was not reported gone - and
#   offers that as the usual cause rather than asserting it, because a tool that
#   words its unknown-session answer some other way fails the same proof for a
#   reason the operator would fix somewhere else entirely.
#
# fm_chrome_binding_inflight <record>
#   Whether some launcher invocation is between marking this binding and its
#   browser command returning. The launcher registers one entry per such call, so
#   a non-empty set means a bridge this task owns may be opening right now.
#
# fm_chrome_binding_lock <record> / fm_chrome_binding_unlock <record>
#   The binding record's mutex, held by every writer that both reads and replaces
#   the record. mkdir is atomic, so exactly one writer holds it; a lock still held
#   after the bounded wait belonged to a process killed inside a critical section
#   of a few local file operations, and is broken once rather than left to wedge
#   every later browser call the task makes. A mutex that cannot be taken is
#   always resolved the safe way by its callers: a reset declines, and a marking
#   launcher refuses to start an untracked bridge.
#
# fm_chrome_binding_stamp <state-dir> <task-id>
#   The binding record's identity as one string - inode, mtime, size - or nothing
#   at all while a browser call is in flight. Every writer of that record replaces
#   it rather than editing in place, so a changed stamp means somebody wrote it,
#   even when the bytes are identical because the marker was already set; and a
#   record whose task has a call in flight has no identity worth holding, because
#   that call marked the binding already and its bridge is still coming up.
#
# fm_chrome_binding_clear_started <state-dir> <task-id> <stamp-before>
#   Resets the startup marker to 0 once the task's bridge is known gone or has
#   been stopped, preserving the record's 0600 mode - but only if the record is
#   still the same file it was when that was established. The pre-refusal cleanup
#   runs while the worker is still live and its bounded browser call takes real
#   time; a bridge opened inside that window leaves the marker set to the same 1
#   it already held, so the value alone cannot say whether the answer in hand is
#   about the bridge the record now describes. The comparison and the write happen
#   together under the record's mutex, so a fresh mark cannot land between them
#   either. A record that moved underneath, a stamp refused because a browser call
#   is in flight, a stamp that could not be taken, and a mutex that could not be
#   taken all decline the reset and leave the task eligible for the post-exit
#   pass, which runs once nothing can open a bridge.
#
# fm_chrome_bridge_cleanup <state-dir> <task-id>
#   Reads only that task's validated binding and never targets the default or
#   another task's session. A task whose launcher recorded no bridge start makes
#   no browser call whatsoever - not a stop, not even a status read - so an
#   unused task costs nothing and a hung tool cannot tax a teardown that had no
#   bridge to reclaim. For a task that did record one, a single bounded read of
#   that exact session decides: the gone answer retires the marker with no stop,
#   an unreadable answer is no evidence and always declines, and only an answer
#   that differs from gone can reach a stop. That stop additionally requires the
#   same tool to return the gone answer for a freshly minted name nothing ever
#   started, so the warrant is always a pair - this name answers one way, a name
#   nobody used answers gone - and never the marker alone. A tool that cannot
#   produce that pair is reported as not having proved it scopes by session, with
#   no claim about why, and the captain's own bridge is never what gets stopped.
#   Missing bindings are no-ops; missing tools, unproved ownership, unreadable
#   answers, and stop errors warn but remain non-fatal, and callers own record
#   retirement.

# Directory of this library, used to locate the sibling bounded runner. Resolved
# at source time from BASH_SOURCE so it works whether sourced by a bin/ script
# (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CHROME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CHROME_LIB_DIR="."
# The longest session name a chrome-devtools-axi may be handed. Session names are
# an argument to someone else's tool, and the dispatchers this fleet meets refuse
# anything longer rather than truncating - a refusal that reads as an ordinary
# answer, which would otherwise be mistaken for the tool failing an ownership
# proof it never got the chance to answer. Every name this library mints is kept
# inside the budget instead.
FM_CHROME_SESSION_NAME_MAX=64
# fm_run_timed owns bounded execution for this repo, including the hung-grandchild
# case a vendor CLI behind a wrapper script creates. It declares `set -u` for its
# own hygiene, which must not leak onto this library's consumers.
case $- in *u*) _fm_chrome_nounset=on ;; *) _fm_chrome_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CHROME_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_chrome_nounset" = on ] || set +u

fm_chrome_task_session_name() {  # <state-dir> <task-id>
  local state=$1 id=$2 state_real digest prefix name
  state_real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s' "$state_real" "$id" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s' "$state_real" "$id" | sha256sum 2>/dev/null | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in
    ''|*[!a-fA-F0-9]*) return 1 ;;
  esac
  prefix=${id:0:28}
  name="fm-$prefix-${digest:0:28}"
  [ "${#name}" -le "$FM_CHROME_SESSION_NAME_MAX" ] || return 1
  printf '%s\n' "$name"
}

fm_chrome_binding_write() {  # <state-dir> <task-id>
  local state=$1 id=$2 session record tmp old_umask started=0 prior_session prior_started
  session=$(fm_chrome_task_session_name "$state" "$id") || return 1
  [ "$session" != default ] || return 1
  record="$state/$id.chrome-devtools-session"
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    prior_session=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
    prior_started=$(sed -n 's/^started=//p' "$record" 2>/dev/null || true)
    if [ "$prior_session" = "$session" ] && [ "$prior_started" = 1 ]; then
      started=1
    fi
  fi
  tmp="$state/.$id.chrome-devtools-session.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if ! printf 'session=%s\nstarted=%s\n' "$session" "$started" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  # This is the one moment no launcher of this binding can be running - the task
  # has not been launched yet, and a relaunch writes here only after the previous
  # endpoint is gone - so a registration left behind by a killed browser call is
  # retired here rather than declining every later marker reset for the task.
  rm -rf -- "$record.inflight" 2>/dev/null || true
  # shellcheck disable=SC2034 # Output variable consumed by the sourcing caller.
  FM_CHROME_TASK_SESSION=$session
}

fm_chrome_dir_is_task_private() {  # <dir>
  local dir=$1 mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -O "$dir" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$dir" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
  fi
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  case "$mode" in
    *[2367]) return 1 ;;
    *[2367]?) return 1 ;;
  esac
  return 0
}

fm_chrome_launcher_dir_create() {  # <parent-dir>
  local parent=$1 dir
  fm_chrome_dir_is_task_private "$parent" || return 1
  dir=$(umask 077; mktemp -d -- "$parent/bin.XXXXXXXXXXXX" 2>/dev/null) || return 1
  if ! fm_chrome_dir_is_task_private "$dir"; then
    rmdir -- "$dir" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$dir"
}

fm_chrome_wrapper_write() {  # <state-dir> <task-id> <wrapper-path> <real-tool>
  local state=$1 id=$2 wrapper=$3 tool=$4 record tmp old_umask wrapper_dir session recorded
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  session=$(fm_chrome_task_session_name "$state" "$id") || return 1
  [ -n "$session" ] && [ "$session" != default ] || return 1
  recorded=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
  [ "$recorded" = "$session" ] || return 1
  case "$tool" in /*) ;; *) return 1 ;; esac
  [ -x "$tool" ] || return 1
  wrapper_dir=$(dirname -- "$wrapper") || return 1
  fm_chrome_dir_is_task_private "$(dirname -- "$wrapper_dir")" || return 1
  (umask 077; mkdir -p -- "$wrapper_dir") || return 1
  fm_chrome_dir_is_task_private "$wrapper_dir" || return 1
  tmp="$wrapper.tmp.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    printf 'record=%q\n' "$record"
    printf 'tool=%q\n' "$tool"
    printf 'session=%q\n' "$session"
    cat <<'SH'
case "${1:-}" in
  ''|setup)
    exec env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
    ;;
  -h|--help|-v|-V|--version)
    if [ "$#" -eq 1 ]; then
      exec env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
    fi
    ;;
esac
lock="$record.lock"
inflight_dir="$record.inflight"
# The launcher's half of the binding's concurrency contract, kept identical to
# bin/fm-chrome-devtools-lib.sh: the record is only ever replaced under this
# mutex, and a call that has marked the binding stays registered in the in-flight
# set until the browser command behind it returns.
binding_lock() {
  local tries=0 absent=0 mtime now
  while ! mkdir -- "$lock" 2>/dev/null; do
    if [ ! -e "$lock" ]; then
      absent=$(( absent + 1 ))
      [ "$absent" -lt 3 ] || return 1
    fi
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 40 ]; then
      if [ "$(uname)" = Darwin ]; then
        mtime=$(stat -f %m "$lock" 2>/dev/null) || return 1
      else
        mtime=$(stat -c %Y "$lock" 2>/dev/null) || return 1
      fi
      case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
      now=$(date +%s 2>/dev/null) || return 1
      case "$now" in ''|*[!0-9]*) return 1 ;; esac
      [ "$(( now - mtime ))" -ge 30 ] || return 1
      rmdir -- "$lock" 2>/dev/null || return 1
      mkdir -- "$lock" 2>/dev/null || return 1
      return 0
    fi
    sleep 0.05
  done
  return 0
}
binding_unlock() {
  rmdir -- "$lock" 2>/dev/null || true
}
binding_inflight() {
  [ -d "$inflight_dir" ] || return 1
  [ -n "$(find "$inflight_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}
# The binding record's identity - inode, mtime, size - or nothing at all while
# another call is in flight. Every writer of the record replaces it rather than
# editing in place, so a changed stamp means somebody else wrote it, even when
# the bytes are identical; and a record with a browser call still running has no
# identity worth holding, because that call marked the binding already and its
# bridge is still coming up.
record_stamp() {
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  ! binding_inflight || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%i:%m:%z' "$record" 2>/dev/null || return 1
  else
    stat -c '%i:%Y:%s' "$record" 2>/dev/null || return 1
  fi
}
if [ "${1:-}" = stop ]; then
  stamp_before=$(record_stamp || true)
  env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
  stop_status=$?
  if [ "$stop_status" -eq 0 ] && [ -f "$record" ] && [ ! -L "$record" ] \
    && grep -q '^started=1$' "$record" 2>/dev/null; then
    # A started=1 that another invocation wrote while this stop was running, or
    # one whose browser command has not returned yet, describes a bridge this
    # stop never covered. Retiring it would leave that bridge live and unowned -
    # the orphan this whole binding exists to prevent - so the comparison and the
    # write happen together under the record's mutex, and an unstampable or
    # replaced record declines the reset exactly as teardown's does, leaving the
    # task cleanup-eligible.
    if ! binding_lock; then
      echo "chrome-devtools-axi: the task bridge binding could not be locked after this stop; leaving it marked so teardown re-checks that session" >&2
    else
      stamp_after=$(record_stamp || true)
      if [ -z "$stamp_before" ] || [ "$stamp_after" != "$stamp_before" ]; then
        echo "chrome-devtools-axi: the task bridge binding was written by another invocation during this stop; leaving it marked so teardown re-checks that session" >&2
      else
        cleared_tmp="$record.stopped.${BASHPID:-$$}"
        if ! (umask 077; sed 's/^started=1$/started=0/' "$record" > "$cleared_tmp") \
          || ! chmod 600 -- "$cleared_tmp" || ! mv -f -- "$cleared_tmp" "$record"; then
          rm -f -- "$cleared_tmp" 2>/dev/null || true
          echo "chrome-devtools-axi: the task bridge binding could not be reset after this stop; teardown will re-check that session" >&2
        fi
      fi
      binding_unlock
    fi
  fi
  exit "$stop_status"
fi
if [ ! -f "$record" ] || [ -L "$record" ]; then
  echo "chrome-devtools-axi: task bridge binding is unavailable; refusing to start an untracked bridge" >&2
  exit 1
fi
# Registering this call before marking, both under the mutex, is what keeps any
# reset elsewhere from retiring this mark while the bridge behind it is still
# coming up: the mark alone says a bridge exists, and the registration says
# nobody may yet conclude anything about it. The command is therefore run as a
# child rather than exec'd, so the registration is retired when it returns.
if ! binding_lock; then
  echo "chrome-devtools-axi: could not record task bridge startup; refusing to start an untracked bridge" >&2
  exit 1
fi
inflight="$inflight_dir/${BASHPID:-$$}"
marker_tmp="$record.started.${BASHPID:-$$}"
if ! (umask 077; mkdir -p -- "$inflight_dir") || ! (umask 077; : > "$inflight") \
  || ! (umask 077; awk -F= '
  $1 == "started" { print "started=1"; found=1; next }
  { print }
  END { if (!found) exit 1 }
' "$record" > "$marker_tmp") || ! chmod 600 -- "$marker_tmp" \
  || ! mv -f -- "$marker_tmp" "$record"; then
  rm -f -- "$marker_tmp" "$inflight" 2>/dev/null || true
  binding_unlock
  echo "chrome-devtools-axi: could not record task bridge startup; refusing to start an untracked bridge" >&2
  exit 1
fi
trap 'rm -f -- "$inflight" 2>/dev/null || true' EXIT
binding_unlock
env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" "$tool" ${1+"$@"}
exit $?
SH
  } > "$tmp" || ! chmod 700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

fm_chrome_bridge_bound() {
  local bound=${FM_CHROME_BRIDGE_TIMEOUT:-20}
  case "$bound" in
    ''|*[!0-9]*) printf '20\n'; return 0 ;;
  esac
  while [ "${#bound}" -gt 1 ] && [ "${bound#0}" != "$bound" ]; do
    bound=${bound#0}
  done
  # Four digits or more is already past the ceiling, and comparing it as a number
  # first would hand the shell an overflowing literal.
  if [ "${#bound}" -gt 3 ]; then
    bound=120
  elif [ "$bound" -lt 1 ]; then
    bound=20
  elif [ "$bound" -gt 120 ]; then
    bound=120
  fi
  printf '%s\n' "$bound"
}

fm_chrome_axi_run() {  # <session> [args...]
  local session=$1 bound
  shift
  bound=$(fm_chrome_bridge_bound)
  fm_run_timed "$bound" \
    env -u CHROME_DEVTOOLS_AXI_PORT "CHROME_DEVTOOLS_AXI_SESSION=$session" \
    chrome-devtools-axi ${1+"$@"} < /dev/null
}

fm_chrome_session_liveness() {  # <session>
  local session=$1 status answer
  # Both streams and any exit status: a tool that reports the one contract line
  # this repo has evidence for on stderr, or alongside a nonzero status, is still
  # understood. Nothing is inferred from a positive-sounding answer.
  answer=$(fm_chrome_axi_run "$session" 2>&1) && status=0 || status=$?
  case "$answer" in
    *'no active session'*) printf 'inactive\n'; return 0 ;;
  esac
  # 124 is fm_run_timed's bound-was-hit status, so a truncated answer counts as
  # no answer. Anything else the tool actually said about this name is a readable
  # answer that is not the gone answer.
  if [ "$status" = 124 ] || [ -z "$answer" ]; then
    printf 'unreadable\n'
  else
    printf 'present\n'
  fi
}

fm_chrome_probe_session_name() {  # <task-session>
  local session=$1 digest nonce probe
  [ -n "$session" ] && [ "$session" != default ] || return 1
  case "$session" in fm-*-*) ;; *) return 1 ;; esac
  digest=${session##*-}
  case "$digest" in
    ''|*[!a-fA-F0-9]*) return 1 ;;
  esac
  [ "${#digest}" -ge 16 ] || return 1
  nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
  case "$nonce" in
    ''|*[!a-fA-F0-9]*) nonce=$(mktemp -u -- 'XXXXXXXXXXXXXXXX' 2>/dev/null | tr -cd 'a-zA-Z0-9' || true) ;;
  esac
  case "$nonce" in
    ''|*[!a-zA-Z0-9]*) return 1 ;;
  esac
  [ "${#nonce}" -ge 16 ] || return 1
  probe="fmprobe-${digest:0:16}-${nonce:0:16}"
  [ "${#probe}" -le "$FM_CHROME_SESSION_NAME_MAX" ] || return 1
  [ "$probe" != "$session" ] && [ "$probe" != default ] || return 1
  printf '%s\n' "$probe"
}

fm_chrome_session_scoping_proved() {  # <session>
  local session=$1 probe
  [ -n "$session" ] && [ "$session" != default ] || return 1
  probe=$(fm_chrome_probe_session_name "$session") || return 1
  [ -n "$probe" ] && [ "$probe" != "$session" ] && [ "$probe" != default ] || return 1
  case "$probe" in fmprobe-?*-?*) ;; *) return 1 ;; esac
  [ "${#probe}" -le "$FM_CHROME_SESSION_NAME_MAX" ] || return 1
  [ "$(fm_chrome_session_liveness "$probe")" = inactive ] || return 1
  return 0
}

# How long a writer waits for the binding record's mutex, in 0.05s attempts, and
# how old a lock must be before it is treated as abandoned rather than merely
# slow. Every critical section this mutex guards is a handful of local file
# operations, so a lock still held after the wait belonged to a process that was
# killed inside one, and breaking it is what keeps a killed launcher from
# wedging every later browser call the task makes.
FM_CHROME_BINDING_LOCK_TRIES=40
FM_CHROME_BINDING_LOCK_STALE=30

fm_chrome_path_age() {  # <path>
  local path=$1 mtime now
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$path" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$path" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - mtime ))"
}

fm_chrome_binding_inflight() {  # <record>
  local dir="$1.inflight"
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

fm_chrome_binding_lock() {  # <record>
  local lock="$1.lock" tries=0 absent=0 age
  while ! mkdir -- "$lock" 2>/dev/null; do
    # mkdir that fails with no lock in place failed for some other reason - an
    # unwritable state directory - and waiting out the full window would only
    # stall the caller. A couple of retries separate that from losing the race
    # to a holder that released in between.
    if [ ! -e "$lock" ]; then
      absent=$(( absent + 1 ))
      [ "$absent" -lt 3 ] || return 1
    fi
    tries=$(( tries + 1 ))
    if [ "$tries" -ge "$FM_CHROME_BINDING_LOCK_TRIES" ]; then
      age=$(fm_chrome_path_age "$lock") || return 1
      [ "$age" -ge "$FM_CHROME_BINDING_LOCK_STALE" ] || return 1
      rmdir -- "$lock" 2>/dev/null || return 1
      mkdir -- "$lock" 2>/dev/null || return 1
      return 0
    fi
    sleep 0.05
  done
  return 0
}

fm_chrome_binding_unlock() {  # <record>
  rmdir -- "$1.lock" 2>/dev/null || true
}

fm_chrome_binding_stamp() {  # <state-dir> <task-id>
  local record="$1/$2.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  # A record with a browser call in flight has no identity worth holding: that
  # call has already marked the binding and its bridge is still coming up, so no
  # answer taken now describes it. Refusing the stamp is what makes every reset
  # that would have been justified by it decline instead.
  ! fm_chrome_binding_inflight "$record" || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%i:%m:%z' "$record" 2>/dev/null || return 1
  else
    stat -c '%i:%Y:%s' "$record" 2>/dev/null || return 1
  fi
}

fm_chrome_binding_clear_started() {  # <state-dir> <task-id> <stamp-before>
  local state=$1 id=$2 expected=${3:-} record tmp current rc=0
  record="$state/$id.chrome-devtools-session"
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  [ -n "$expected" ] || return 0
  # The marker cannot be retired on the strength of an answer fetched before the
  # worker's last chance to open a bridge, and the record that answer was about
  # must not be replaced between the check and the write. Every writer of this
  # record replaces it and holds this mutex to do so, so re-reading the stamp
  # under the lock is a real comparison rather than a guess that a fresh marker
  # will not land in between. A record that moved underneath, one whose stamp is
  # refused because a browser call is still in flight, and a mutex that cannot be
  # taken all decline the reset and leave the task eligible for the post-exit
  # pass, which runs once nothing can open a bridge any more.
  fm_chrome_binding_lock "$record" || return 0
  current=$(fm_chrome_binding_stamp "$state" "$id" 2>/dev/null || true)
  if [ -n "$current" ] && [ "$current" = "$expected" ] \
    && grep -q '^started=1$' "$record" 2>/dev/null; then
    tmp="$record.cleanup.${BASHPID:-$$}"
    if ! (umask 077; sed 's/^started=1$/started=0/' "$record" > "$tmp") \
      || ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$record"; then
      rm -f -- "$tmp" 2>/dev/null || true
      rc=1
    fi
  fi
  fm_chrome_binding_unlock "$record"
  return "$rc"
}

fm_chrome_bridge_cleanup() {  # <state-dir> <task-id>
  local state=$1 id=$2 record session started expected liveness stamp
  record="$state/$id.chrome-devtools-session"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    echo "warning: chrome-devtools bridge binding for task $id is not an ordinary file; skipping bridge cleanup" >&2
    return 0
  fi
  if [ "$(wc -l < "$record" 2>/dev/null || printf '0')" -ne 2 ]; then
    echo "warning: chrome-devtools bridge binding for task $id is malformed; skipping bridge cleanup" >&2
    return 0
  fi
  session=$(sed -n 's/^session=//p' "$record" 2>/dev/null || true)
  started=$(sed -n 's/^started=//p' "$record" 2>/dev/null || true)
  expected=$(fm_chrome_task_session_name "$state" "$id" 2>/dev/null || true)
  if [ -z "$session" ] || [ "$session" = default ] || [ -z "$expected" ] || [ "$session" != "$expected" ]; then
    echo "warning: chrome-devtools bridge binding for task $id does not match its task-scoped session; skipping bridge cleanup" >&2
    return 0
  fi
  case "$started" in
    0|1) ;;
    *)
      echo "warning: chrome-devtools bridge binding for task $id has an invalid startup marker; skipping bridge cleanup" >&2
      return 0
      ;;
  esac
  # No recorded start means the task's launcher never handed a bridge-capable
  # command to the tool, so there is nothing of this task's to reclaim and no
  # question worth spending a bounded call on.
  [ "$started" = 1 ] || return 0
  if ! command -v chrome-devtools-axi >/dev/null 2>&1; then
    echo "warning: chrome-devtools-axi is unavailable; task $id bridge cleanup was skipped" >&2
    return 0
  fi
  stamp=$(fm_chrome_binding_stamp "$state" "$id" || true)
  liveness=$(fm_chrome_session_liveness "$session")
  if [ "$liveness" = inactive ]; then
    fm_chrome_binding_clear_started "$state" "$id" "$stamp" \
      || echo "warning: chrome-devtools bridge for task $id is already gone, but its binding could not be reset" >&2
    return 0
  fi
  if [ "$liveness" != present ]; then
    echo "warning: chrome-devtools-axi returned no readable status for task $id session $session, so no stop was issued; that task's launcher did record a bridge start, so a bridge may still be running under that session and needs reclaiming by hand" >&2
    return 0
  fi
  if ! fm_chrome_session_scoping_proved "$session"; then
    echo "warning: chrome-devtools-axi did not report a session name nothing has ever started as gone, so it is not established that it acts on the session it is handed; no stop was issued for task $id session $session and no shared bridge was disturbed. Task-scoped bridge reclamation stays inert until that probe answers, which usually means the resolved chrome-devtools-axi must pass CHROME_DEVTOOLS_AXI_SESSION through to the real tool" >&2
    return 0
  fi
  if ! fm_chrome_axi_run "$session" stop >/dev/null 2>&1; then
    echo "warning: chrome-devtools bridge stop failed for task $id session $session; teardown will continue" >&2
    return 0
  fi
  fm_chrome_binding_clear_started "$state" "$id" "$stamp" \
    || echo "warning: chrome-devtools bridge stopped for task $id, but its binding could not be reset" >&2
  return 0
}
