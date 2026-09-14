#!/usr/bin/env bash
# fm-validate.sh - the host-wide validation slot.
#
# Runs ONE validation command (typecheck, tests, build, lint, gates) at a time
# across the entire fleet, on a machine that cannot survive two.
#
#   bin/fm-validate.sh -- npm run typecheck --workspace=@scope/pkg
#   bin/fm-validate.sh --label "marcom tests" -- npm test -w packages/marcom-agent
#
# WHY IT EXISTS. The captain's resource policy said "at most one validation job
# at a time, host-wide" as PROSE, and prose did not hold. On 2026-08-31 the host
# reached 145 MiB available with swap disabled because roughly ten `tsc --noEmit`
# processes ran concurrently in one worktree. Every one of them was "targeted"
# and therefore permitted by the wording; nothing serialized them. Firstmate
# never executes validation itself, each crewmate runs it in its own shell, and
# an instruction cannot reach across shells. A lock can.
#
# WHAT IT ENFORCES, in order, refusing rather than proceeding:
#
#   1. Explicit-approval commands are REFUSED. `ci:gates:static`,
#      `gate:orphan-tables` and `check-orphan-tables.mjs` have frozen this host;
#      the orphan-table gate alone has consumed over 2 GB. Set
#      FM_VALIDATE_CAPTAIN_APPROVED=1 to run one after the captain says yes.
#   2. Available memory is pre-flighted against the captain's own thresholds.
#      Being targeted never justifies starting a job the host has no memory for.
#   3. A compiler already working is a reason to WAIT, not to start a second one.
#   4. The host-wide slot is taken with a FOREGROUND flock, so a later
#      validation queues behind this one instead of overlapping it.
#   5. TURBO_CONCURRENCY is pinned, because one "targeted" `npm run typecheck`
#      in a turbo monorepo fans out to ten compilers by default.
#
# WHAT IT DELIBERATELY DOES NOT DO. It never kills a process it did not start:
# a stray compiler is REPORTED with its pid and the run is refused, because
# killing another agent's or the captain's work to make room for our own is not
# a decision a wrapper gets to make. After its own command finishes it reaps
# only leftover children of its own process group.
#
# IT CANNOT SEE THROUGH A WRAPPER. A script that internally invokes a banned
# gate is not detectable here; the refusal matches the command line it is given.
#
# EXIT CODES. The wrapped command's own exit code is passed through unchanged on
# every path where the command actually ran. Refusals use a distinct high range
# so they can never be confused with a command's own failure:
#
#   70  refused: explicit-approval-only command
#   71  refused: not enough available memory
#   72  refused: a validation process is already running
#   73  refused: could not acquire the host-wide slot within the timeout
#   64  usage error
#
# NESTING. A validation that itself shells out to another fm-validate.sh call
# would deadlock on the lock it already holds, so FM_VALIDATE_ACTIVE marks the
# slot as held by this process tree and an inner call runs straight through.

set -uo pipefail

FM_VALIDATE_LOCK=${FM_VALIDATE_LOCK:-/tmp/firstmate-validation.lock}
FM_VALIDATE_LOCK_TIMEOUT=${FM_VALIDATE_LOCK_TIMEOUT:-1800}
FM_VALIDATE_MIN_AVAILABLE_MB=${FM_VALIDATE_MIN_AVAILABLE_MB:-1536}
FM_VALIDATE_COMFORTABLE_MB=${FM_VALIDATE_COMFORTABLE_MB:-2048}
FM_VALIDATE_PRESSURE_MB=${FM_VALIDATE_PRESSURE_MB:-1024}
FM_VALIDATE_EMERGENCY_MB=${FM_VALIDATE_EMERGENCY_MB:-512}
FM_VALIDATE_TURBO_CONCURRENCY=${FM_VALIDATE_TURBO_CONCURRENCY:-1}
FM_VALIDATE_BUSY_PATTERN=${FM_VALIDATE_BUSY_PATTERN:-'tsc --noEmit|npm run typecheck|turbo run typecheck'}

EXIT_APPROVAL=70
EXIT_MEMORY=71
EXIT_BUSY=72
EXIT_SLOT=73
EXIT_USAGE=64

usage() {
  cat <<'TXT'
usage: fm-validate.sh [--label <text>] [--] <command> [args...]

Runs one validation command in the host-wide validation slot. At most one such
command executes at a time across every crewmate, worktree, secondmate home and
the captain's own shell; a later call waits.

flags:
  --label <text>   human name for this validation, used in refusal messages
  --check          run the preflight only; do not execute the command
  -h, --help       this text

environment:
  FM_VALIDATE_LOCK                 lock file (default /tmp/firstmate-validation.lock)
  FM_VALIDATE_LOCK_TIMEOUT         seconds to wait for the slot (default 1800)
  FM_VALIDATE_MIN_AVAILABLE_MB     refuse below this many MiB available (default 1536)
  FM_VALIDATE_TURBO_CONCURRENCY    pinned TURBO_CONCURRENCY (default 1)
  FM_VALIDATE_CAPTAIN_APPROVED=1   permit an explicit-approval-only command
  FM_VALIDATE_ACTIVE               set by this script; an inner call passes through

exit codes:
  <command's own>  the command ran; its exit code is passed through
  70 refused: explicit-approval-only command   71 refused: memory
  72 refused: validation already running       73 refused: slot not acquired
  64 usage error
TXT
}

refuse() {
  local code=$1
  shift
  printf 'fm-validate: REFUSED - %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do
    printf '  %s\n' "$line" >&2
  done
  exit "$code"
}

LABEL=
CHECK_ONLY=
while [ $# -gt 0 ]; do
  case "$1" in
    --label)
      [ $# -ge 2 ] || { printf 'fm-validate: --label needs a value\n' >&2; exit "$EXIT_USAGE"; }
      LABEL=$2
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-validate: unknown flag %s\n' "$1" >&2
      exit "$EXIT_USAGE"
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -eq 0 ]; then
  usage >&2
  exit "$EXIT_USAGE"
fi

COMMAND_LINE="$*"
[ -n "$LABEL" ] || LABEL=$COMMAND_LINE

# --- 1. explicit-approval-only commands -------------------------------------
#
# These three have each frozen this host. The orphan-table gate has consumed
# over 2 GB by itself. They are refused here rather than trusted to be
# remembered, which is the whole reason this script exists.
#
# THIS CHECK RUNS BEFORE THE NESTING PASSTHROUGH BELOW, DELIBERATELY. An earlier
# ordering put the passthrough first, which meant a command run inside an
# already-held slot skipped this refusal entirely - so the one place a heavy gate
# was most likely to be invoked, from inside another validation, was the one
# place it was not refused. The outer call's admission covers resources, never
# authority: memory and the slot can be inherited, the captain's approval cannot.

APPROVAL_ONLY='ci:gates:static gate:orphan-tables check-orphan-tables.mjs'
for banned in $APPROVAL_ONLY; do
  case "$COMMAND_LINE" in
    *"$banned"*)
      if [ -z "${FM_VALIDATE_CAPTAIN_APPROVED:-}" ]; then
        refuse "$EXIT_APPROVAL" \
          "'$banned' needs the captain's explicit approval before it runs." \
          "command: $COMMAND_LINE" \
          "This gate has frozen WSL on this host; the orphan-table gate alone has used over 2 GB." \
          "If the captain has approved it, re-run with FM_VALIDATE_CAPTAIN_APPROVED=1."
      fi
      printf 'fm-validate: running captain-approved heavy command: %s\n' "$banned" >&2
      ;;
  esac
done

# --- nesting passthrough ----------------------------------------------------
#
# The slot is not re-entrant: an inner flock on a descriptor this process tree
# already holds would block for ever. A nested call therefore runs the command
# directly, having already been admitted by the outer call's RESOURCE preflight.
# The approval refusal above has already been applied and is never inherited.

if [ -n "${FM_VALIDATE_ACTIVE:-}" ]; then
  exec "$@"
fi

# --- 2. memory preflight ----------------------------------------------------
#
# AVAILABLE memory is the budget, not total. `free -m` is read from PATH so a
# test can shim it. An unreadable reading is treated as unknown and allowed
# through with a warning rather than blocking every validation on a host whose
# `free` differs: refusing on ignorance would make the script unusable, while
# the slot and the duplicate check still bound the damage.

available_mb() {
  command -v free >/dev/null 2>&1 || return 1
  free -m 2>/dev/null | awk '/^Mem:/ { print $7; found = 1 } END { exit !found }'
}

AVAILABLE=$(available_mb) || AVAILABLE=
case "$AVAILABLE" in
  '' | *[!0-9]*)
    printf 'fm-validate: available memory could not be read; proceeding on the slot alone\n' >&2
    AVAILABLE=
    ;;
esac

if [ -n "$AVAILABLE" ]; then
  if [ "$AVAILABLE" -lt "$FM_VALIDATE_EMERGENCY_MB" ]; then
    refuse "$EXIT_MEMORY" \
      "emergency memory pressure: ${AVAILABLE} MiB available." \
      "validation: $LABEL" \
      "Start no new work at all. Report which process is responsible."
  elif [ "$AVAILABLE" -lt "$FM_VALIDATE_PRESSURE_MB" ]; then
    refuse "$EXIT_MEMORY" \
      "resource pressure: ${AVAILABLE} MiB available, below the ${FM_VALIDATE_PRESSURE_MB} MiB floor." \
      "validation: $LABEL" \
      "Stop spawning work and report the pressure before validating."
  elif [ "$AVAILABLE" -lt "$FM_VALIDATE_MIN_AVAILABLE_MB" ]; then
    refuse "$EXIT_MEMORY" \
      "only ${AVAILABLE} MiB available; ${FM_VALIDATE_MIN_AVAILABLE_MB} MiB is the floor for starting validation." \
      "validation: $LABEL" \
      "Wait for memory to free rather than starting this job."
  elif [ "$AVAILABLE" -lt "$FM_VALIDATE_COMFORTABLE_MB" ]; then
    printf 'fm-validate: %s MiB available - essential targeted validation only, add no workers\n' \
      "$AVAILABLE" >&2
  fi
fi

# --- 3. a compiler is already working ---------------------------------------
#
# Never kills what it finds. A slow typecheck is not permission to start a
# replacement alongside it, and killing another agent's or the captain's process
# to make room is not this wrapper's call.

# Return 1 only for a proven mention, not an executing compiler command.
# Linux provides argument boundaries through procfs. On other hosts, or when
# arguments cannot be read, retain the candidate rather than guessing from ps's
# flattened command text. The ancestor exclusion below is portable.
compiler_candidate() {
  local pid=$1 arg tool command_line index=0
  local -a argv=()
  [ -r "/proc/$pid/cmdline" ] || return 0
  while IFS= read -r -d '' arg; do
    argv[${#argv[@]}]=$arg
  done < "/proc/$pid/cmdline" 2>/dev/null || return 0
  [ "${#argv[@]}" -gt 0 ] || return 0
  tool=${argv[0]##*/}
  case "$tool" in
    bash|sh|dash|zsh|ksh|node|nodejs)
      index=1
      while [ "$index" -lt "${#argv[@]}" ]; do
        arg=${argv[$index]}
        case "$arg" in
          --) index=$((index + 1)); break ;;
          -c|-lc|-cl|-ec|-ce)
            case "$tool" in node|nodejs) return 0 ;; esac
            # A shell's source string is not its executable. Any compiler
            # child is examined independently by the host-wide scan.
            return 1 ;;
          --*=*|--no-warnings|--trace-warnings) ;;
          -*) return 0 ;; # Unknown interpreter option arity: fail closed.
          *) break ;;
        esac
        index=$((index + 1))
      done
      [ "$index" -lt "${#argv[@]}" ] || return 0
      tool=${argv[$index]##*/}
      ;;
  esac
  # Wrappers queue on flock; their payload arguments are not running yet.
  [ "$tool" != fm-validate.sh ] || return 1
  case "$tool" in npm-cli.js) tool=npm ;; esac
  command_line=$tool
  index=$((index + 1))
  while [ "$index" -lt "${#argv[@]}" ]; do
    command_line+=" ${argv[$index]}"
    index=$((index + 1))
  done
  # Match at the executable/script position, never inside an argument holding
  # shell source, a prompt, a label, or another command's search expression.
  [[ "$command_line" =~ ^($FM_VALIDATE_BUSY_PATTERN)([[:space:]]|$) ]]
  local result=$?
  [ "$result" -ne 1 ] # Invalid expressions also refuse.
}

busy_pids() {
  local tree ancestors pid parent line candidates result
  command -v pgrep >/dev/null 2>&1 || {
    printf '%s\n' 'unknown: cannot inspect competing processes (pgrep unavailable)'
    return
  }
  tree=$(ps -e -o pid= -o ppid= 2>/dev/null) || {
    printf '%s\n' 'unknown: cannot inspect process ancestry'
    return
  }
  ancestors=" $$ "
  pid=$$
  while [ "$pid" -gt 1 ]; do
    parent=$(awk -v pid="$pid" '$1 == pid {print $2; exit}' <<< "$tree")
    case "$parent" in
      ''|*[!0-9]*)
        printf '%s\n' 'unknown: incomplete process ancestry'
        return ;;
      0) break ;;
    esac
    case "$ancestors" in *" $parent "*) break ;; esac
    ancestors+="$parent "
    pid=$parent
  done
  # Replace the capture shell so pgrep cannot report that short-lived wrapper
  # clone after it has exited and become impossible to classify safely.
  candidates=$(exec pgrep -af "$FM_VALIDATE_BUSY_PATTERN" "$@" 2>/dev/null)
  result=$?
  if [ "$result" -gt 1 ]; then
    printf '%s\n' 'unknown: competing process scan failed'
    return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%% *}
    case "$ancestors" in *" $pid "*) continue ;; esac
    if compiler_candidate "$pid"; then
      printf '%s\n' "$line"
    fi
  done <<< "$candidates"
}

BUSY=$(busy_pids)
if [ -n "$BUSY" ]; then
  refuse "$EXIT_BUSY" \
    "a validation process is already running; wait for it rather than starting another." \
    "validation: $LABEL" \
    "already running:" \
    "$BUSY" \
    "Nothing was killed. Wait, or stop those processes deliberately yourself."
fi

if [ -n "$CHECK_ONLY" ]; then
  printf 'fm-validate: preflight clear%s\n' \
    "${AVAILABLE:+ (${AVAILABLE} MiB available)}"
  exit 0
fi

# --- 4 and 5. take the slot, pin fan-out, run in the foreground -------------
#
# flock is held on descriptor 9 for the lifetime of the command. The command is
# never backgrounded, so this process observes the exit and the slot is released
# in order rather than being left held by a detached child.

if ! command -v flock >/dev/null 2>&1; then
  printf 'fm-validate: flock is not installed; the host-wide slot cannot be enforced\n' >&2
  printf 'fm-validate: install util-linux, or serialize validation by hand\n' >&2
  exit "$EXIT_SLOT"
fi

if ! : > "$FM_VALIDATE_LOCK" 2>/dev/null && [ ! -e "$FM_VALIDATE_LOCK" ]; then
  printf 'fm-validate: cannot create the lock file %s\n' "$FM_VALIDATE_LOCK" >&2
  exit "$EXIT_SLOT"
fi

exec 9>>"$FM_VALIDATE_LOCK" || {
  printf 'fm-validate: cannot open the lock file %s\n' "$FM_VALIDATE_LOCK" >&2
  exit "$EXIT_SLOT"
}

if ! flock -w "$FM_VALIDATE_LOCK_TIMEOUT" 9; then
  refuse "$EXIT_SLOT" \
    "another validation held the host-wide slot for longer than ${FM_VALIDATE_LOCK_TIMEOUT}s." \
    "validation: $LABEL" \
    "Nothing was run. Check what is holding $FM_VALIDATE_LOCK before retrying."
fi

export FM_VALIDATE_ACTIVE=$$
export TURBO_CONCURRENCY=$FM_VALIDATE_TURBO_CONCURRENCY

"$@"
STATUS=$?

# --- reap our own leftovers -------------------------------------------------
#
# Only children of THIS process group, so a compiler belonging to another agent
# or to the captain is never touched. Anything still alive after the command
# returned is a child that outlived its parent, which is exactly the
# accumulation the policy forbids.

reap_own_children() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local pgid stragglers
  pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ') || return 0
  [ -n "$pgid" ] || return 0
  stragglers=$(busy_pids -g "$pgid" | awk '$1 ~ /^[0-9]+$/ {print $1}')
  [ -n "$stragglers" ] || return 0
  printf 'fm-validate: reaping leftover children of this run: %s\n' "$(printf '%s' "$stragglers" | tr '\n' ' ')" >&2
  printf '%s\n' "$stragglers" | while IFS= read -r pid; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  sleep 1
  printf '%s\n' "$stragglers" | while IFS= read -r pid; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
}

reap_own_children

exit "$STATUS"
