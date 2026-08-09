#!/usr/bin/env bash
# fm-loop-actuate.sh - the governed wake-to-action table for canonical LoopSpecs.
#
# THE GAP THIS CLOSES. bin/fm-loopspec.sh has always been able to select a spec,
# bound an iteration and record a terminal. Nothing ever called it. A LoopSpec
# could be validated but never actuated, so the registry described loops the
# fleet still ran by hand. This script is the missing arrow: it turns an event
# that already reaches the fleet into the lawful next transition of a bound loop.
#
# THE RULE IT IMPLEMENTS. If exactly one lawful transition follows from the
# recorded state, code executes it. A coordinator turn is spent only where the
# transition genuinely is not determined - choosing between candidate specs, or
# doing the bounded work inside an iteration. Agents reason inside bounded work;
# they are not the state machine.
#
# WHAT THIS IS NOT, and the distinction matters because the commission forbids
# every one of them. This is not a runtime, a scheduler, a watcher, an event bus,
# a loop daemon, a task store or a state store. It has no loop, no sleep, no
# poll, no background process and no lifecycle of its own. One invocation
# classifies one event, performs at most one transition, and exits. It owns no
# storage: durable loop state stays with bin/fm-loopspec.sh, wakes stay in the
# existing durable queue that bin/fm-wake-lib.sh owns, and `arm` appends to that
# same queue through fm_wake_append rather than opening a parallel path.
#
# Usage:
#   fm-loop-actuate.sh table
#       Print the governed wake-to-action table. The table is the contract; this
#       command exists so it can be read without reading the code.
#
#   fm-loop-actuate.sh arm --spec <id> --event-key <k>
#       Append one `check` wake for a bound loop onto the existing durable queue,
#       so the ordinary drain surfaces it like any other check.
#
#   fm-loop-actuate.sh candidates --trigger <t> [--scope <s>]
#       Emit the tiny typed applicability headers for a trigger and classify the
#       candidate-set size against the ruled selection shape.
#
#   fm-loop-actuate.sh run --trigger <t> [--scope <s>] --event-key <k>
#                          [--headroom <pct>] [--spec <id>] [--unattended]
#                          [--success-terminal <name>]
#       Actuate one iteration: select, claim, run the bound verifier, and execute
#       the lawful transition the verdict determines. --spec supplies the answer
#       to the small judgment call that ruling 2 keeps out of code; without it,
#       an ambiguous candidate set refuses rather than guessing.
#
#   fm-loop-actuate.sh record [<spec-id>]
#       Print the durable execution record: loop=<spec-id>@<version> and
#       verifier=<canonical verifier>, plus the terminal each execution reached.
#
# Exit status: 0 the transition completed, 1 refused or the loop stopped at a
# non-success terminal, 2 usage error, 3 the candidate set needs the judgment
# call (headers are on stdout).
#
# AUTHORITY. This script expands nothing. It never merges, never tears down,
# never spawns, never pushes and never edits a project. --unattended changes one
# thing only: it stamps the execution record so a session-independent run
# identifies itself durably, exactly as the 2026-08-03 ruling requires. The
# engine, the state machine and every authority check are identical in both
# modes, because operator availability is a policy input, not a different
# controller.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOOPSPEC="$SCRIPT_DIR/fm-loopspec.sh"
# The execution record lives beside the loop state it describes, under the
# directory bin/fm-loopspec.sh already owns. It is a record of what ran, not a
# second source of truth: every field in it is derived from state the interpreter
# already persisted, and deleting it loses evidence, never authority.
EXEC_LOG="${FM_LOOP_EXEC_LOG:-$STATE/loopspec/executions.log}"

die_usage() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf '%s %s\n' "$1" "$2" >&2; exit 1; }

ls_run() { FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$LOOPSPEC" "$@"; }

# --- the table ---------------------------------------------------------------
#
# Columns: observed state -> who acts -> the transition.
# "code" means this script executes it with no model turn. "bounded agent" means
# this script sets the bounds and hands off; the agent works inside them and
# comes back through `run` again.
TABLE=$(cat <<'TXT'
OBSERVED STATE                          ACTOR           LAWFUL TRANSITION
--------------------------------------  --------------  ----------------------------------
candidate set is empty                  code            no loop applies; ordinary non-loop
                                                        path, or an authoring opportunity
candidate set is exactly 1              code            claim it under the selection policy
candidate set is 2-3                    bounded agent   choose over the typed headers only,
                                                        never spec bodies; answer via --spec
candidate set is 4 or more              code            refuse: a filtering defect, not a
                                                        selection problem
spec matched, not enabled               code            refuse; an inert spec never runs
trigger has no verified exec path       code            refuse; nothing may claim it
authority class is captain-required     code            refuse to the captain
capacity inside the stop band           code            refuse to start; work in flight is
                                                        never blocked from verifying
iteration budget spent                  code            terminal budget_exhausted (EXHAUSTED)
consecutive no-progress at threshold    code            the spec no_progress terminal
                                                        (STALLED)
iteration claimed                       bounded agent   do the spec-permitted work, then
                                                        return through `run`
verifier verdict pass                   code            the spec success terminal (SUCCESS)
verifier verdict fail, budget remains   code            close this iteration, keep the loop
                                                        open for a bounded next one
verifier verdict fail, budget spent     code            terminal budget_exhausted (EXHAUSTED)
verifier verdict unavailable            code            terminal verification_failed (FAILED);
                                                        an unavailable verifier is never a pass
no verifier run recorded                code            refuse NO_VERIFIER_RAN; never success
TXT
)

cmd_table() { printf '%s\n' "$TABLE"; }

# --- arming ------------------------------------------------------------------

cmd_arm() {
  local spec="" key=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --spec) [ "$#" -gt 1 ] || die_usage "--spec requires a value"; spec=$2; shift 2 ;;
      --event-key) [ "$#" -gt 1 ] || die_usage "--event-key requires a value"; key=$2; shift 2 ;;
      *) die_usage "unknown option for arm: $1" ;;
    esac
  done
  [ -n "$spec" ] || die_usage "arm requires --spec <id>"
  [ -n "$key" ] || die_usage "arm requires --event-key <key>"

  # The same durable queue, the same append function, the same `check` kind that
  # fm-procevent.sh already uses. Extending this path rather than adding another
  # is why a LoopSpec wake needs no new drain, no new dedup and no new recovery.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_append check "loopspec:$spec:$key" "check: loopspec $spec is due for event $key" \
    || refuse refuse_wake_unwritable "could not append the loop wake to the durable queue"
  printf 'LOOPACT_ARM spec=%s event-key=%s\n' "$spec" "$key"
}

# --- selection ---------------------------------------------------------------

# Prints headers on stdout and the classification on stderr, so a caller can pipe
# the headers without the commentary. Returns 0 for one candidate, 3 when the
# judgment call is genuinely required, 1 when the set is empty or a filtering
# defect.
classify_candidates() {
  local trigger=$1 scope=$2 headers count
  headers=$(ls_run candidates --trigger "$trigger" ${scope:+--scope "$scope"}) || return 1
  if [ -z "$headers" ]; then
    count=0
  else
    count=$(printf '%s\n' "$headers" | wc -l | tr -d ' ')
  fi
  [ -n "$headers" ] && printf '%s\n' "$headers"
  case "$count" in
    0)
      printf 'LOOPACT_SELECT candidates=0 shape=no-loop-applies\n' >&2
      return 1 ;;
    1)
      printf 'LOOPACT_SELECT candidates=1 shape=deterministic\n' >&2
      return 0 ;;
    2|3)
      printf 'LOOPACT_SELECT candidates=%s shape=judgment-required\n' "$count" >&2
      return 3 ;;
    *)
      printf 'LOOPACT_SELECT candidates=%s shape=filtering-defect\n' "$count" >&2
      return 1 ;;
  esac
}

cmd_candidates() {
  local trigger="" scope=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -gt 1 ] || die_usage "--trigger requires a value"; trigger=$2; shift 2 ;;
      --scope) [ "$#" -gt 1 ] || die_usage "--scope requires a value"; scope=$2; shift 2 ;;
      *) die_usage "unknown option for candidates: $1" ;;
    esac
  done
  [ -n "$trigger" ] || die_usage "candidates requires --trigger <id>"
  classify_candidates "$trigger" "$scope"
}

# --- the execution record ----------------------------------------------------

# The minimum durable execution record the commission requires. Without a loop=
# line, adoption cannot be demonstrated at all: a loop that ran and left no trace
# is indistinguishable from one that never ran.
append_record() {
  local spec=$1 version=$2 verifier=$3 terminal=$4 kind=$5 iteration=$6 unattended=$7 event_key=$8
  local dir
  dir=$(dirname "$EXEC_LOG")
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\tloop=%s@%s\tverifier=%s\tterminal=%s\tkind=%s\titeration=%s\tevent_key=%s\tunattended=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$spec" "$version" "$verifier" "$terminal" "$kind" \
    "$iteration" "$event_key" "$unattended" >> "$EXEC_LOG"
}

cmd_record() {
  local spec="${1:-}"
  [ -f "$EXEC_LOG" ] || { printf 'no executions recorded\n'; return 0; }
  if [ -n "$spec" ]; then
    grep -F "loop=$spec@" "$EXEC_LOG" || true
  else
    cat "$EXEC_LOG"
  fi
}

# --- actuation ---------------------------------------------------------------

cmd_run() {
  local trigger="" scope="" key="" headroom="" spec="" unattended=false success_terminal=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -gt 1 ] || die_usage "--trigger requires a value"; trigger=$2; shift 2 ;;
      --scope) [ "$#" -gt 1 ] || die_usage "--scope requires a value"; scope=$2; shift 2 ;;
      --event-key) [ "$#" -gt 1 ] || die_usage "--event-key requires a value"; key=$2; shift 2 ;;
      --headroom) [ "$#" -gt 1 ] || die_usage "--headroom requires a value"; headroom=$2; shift 2 ;;
      --spec) [ "$#" -gt 1 ] || die_usage "--spec requires a value"; spec=$2; shift 2 ;;
      --success-terminal) [ "$#" -gt 1 ] || die_usage "--success-terminal requires a value"; success_terminal=$2; shift 2 ;;
      --unattended) unattended=true; shift ;;
      *) die_usage "unknown option for run: $1" ;;
    esac
  done
  [ -n "$trigger" ] || die_usage "run requires --trigger <id>"
  [ -n "$key" ] || die_usage "run requires --event-key <key>"

  # 1. SELECT. The deterministic filter narrows; it never resolves a genuine tie.
  #    Ruling 2 keeps route selection a decision firstmate makes, so when more
  #    than one candidate survives, this refuses with the headers rather than
  #    inventing a tie-break. --spec is how that decision comes back in.
  if [ -z "$spec" ]; then
    local headers rc
    headers=$(classify_candidates "$trigger" "$scope")
    rc=$?
    if [ "$rc" -eq 3 ]; then
      printf '%s\n' "$headers"
      printf 'LOOPACT_RUN needs-judgment: re-run with --spec <id> naming the chosen loop\n' >&2
      exit 3
    fi
    [ "$rc" -eq 0 ] || refuse refuse_no_match "no single loop applies to trigger \"$trigger\""
    local sel
    sel=$(ls_run select --trigger "$trigger" ${scope:+--scope "$scope"}) || exit 1
    spec=$(printf '%s' "$sel" | awk '{print $2}')
  fi

  local version verifier
  version=$(ls_run show "$spec" | jq -r '.spec_version') || exit 1
  verifier=$(ls_run show "$spec" | jq -r '.verification.verifier')

  # 2. CLAIM. Every stop that bounds STARTING an iteration - not enabled, no
  #    verified execution path, captain-required authority, capacity stop band,
  #    iteration budget, no-progress threshold, duplicate event - is enforced by
  #    the interpreter here, and its refusal token is the outcome.
  local claim
  if ! claim=$(ls_run claim "$spec" --event-key "$key" --spec-version "$version" ${headroom:+--headroom "$headroom"} 2>&1); then
    printf '%s\n' "$claim" >&2
    # A budget or no-progress stop is a terminal the loop genuinely reached, so
    # it is recorded as one rather than reported as a mere refusal.
    case "$claim" in
      refuse_budget_exceeded*)
        append_record "$spec" "$version" "$verifier" budget_exhausted failure "-" "$unattended" "$key"
        printf 'LOOPACT_RUN %s terminal=budget_exhausted kind=failure maps_to=EXHAUSTED\n' "$spec" ;;
      refuse_no_progress*)
        local np
        np=$(ls_run show "$spec" | jq -r '.no_progress.terminal')
        append_record "$spec" "$version" "$verifier" "$np" failure "-" "$unattended" "$key"
        printf 'LOOPACT_RUN %s terminal=%s kind=failure maps_to=STALLED\n' "$spec" "$np" ;;
    esac
    exit 1
  fi
  printf '%s\n' "$claim"
  local iteration
  iteration=$(printf '%s' "$claim" | sed -n 's/.*iteration=\([0-9]*\).*/\1/p')

  # 3. VERIFY. The interpreter executes the bound command; nothing here supplies
  #    a verdict, because the actuator is a party to the work.
  local verify verdict
  verify=$(ls_run verify "$spec" --event-key "$key" 2>&1) || true
  printf '%s\n' "$verify"
  verdict=$(printf '%s' "$verify" | sed -n 's/.*verdict=\([a-z]*\).*/\1/p')
  [ -n "$verdict" ] || verdict=unavailable

  # 4. TRANSITION. One lawful transition follows from the verdict and the budget,
  #    so code executes it. This is the whole point of the table.
  local terminal kind maps
  case "$verdict" in
    pass)
      if [ -z "$success_terminal" ]; then
        local successes n
        successes=$(ls_run show "$spec" | jq -r '.terminal_states[] | select(.kind == "success") | .name')
        n=$(printf '%s\n' "$successes" | grep -c . || true)
        if [ "$n" -ne 1 ]; then
          refuse refuse_ambiguous_tie "spec \"$spec\" declares $n success terminals; name one with --success-terminal"
        fi
        success_terminal=$successes
      fi
      terminal=$success_terminal; kind=success; maps=SUCCESS ;;
    fail)
      local max_iter
      max_iter=$(ls_run show "$spec" | jq -r '.budgets.max_iterations')
      if [ "$iteration" -ge "$max_iter" ]; then
        terminal=budget_exhausted; kind=failure; maps=EXHAUSTED
      else
        # Not a terminal: the loop stays open for a bounded next iteration. The
        # iteration is closed as failed so the budget counts it honestly.
        terminal=verification_failed; kind=failure; maps=CONTINUE
      fi ;;
    *)
      terminal=verification_failed; kind=failure; maps=FAILED ;;
  esac

  local progress=made
  [ "$verdict" = "pass" ] || progress=none

  local finish
  if ! finish=$(ls_run finish "$spec" --event-key "$key" --terminal "$terminal" \
                 --verifier-result "$verdict" --progress "$progress" 2>&1); then
    printf '%s\n' "$finish" >&2
    exit 1
  fi
  printf '%s\n' "$finish"

  append_record "$spec" "$version" "$verifier" "$terminal" "$kind" "$iteration" "$unattended" "$key"
  printf 'LOOPACT_RUN %s terminal=%s kind=%s maps_to=%s loop=%s@%s verifier=%s unattended=%s\n' \
    "$spec" "$terminal" "$kind" "$maps" "$spec" "$version" "$verifier" "$unattended"
  [ "$kind" = "success" ] || exit 1
  return 0
}

[ "$#" -ge 1 ] || { printf '%s\n' "$(sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-loop-actuate.sh" | sed 's/^# \{0,1\}//; $d')" >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  table) cmd_table "$@" ;;
  arm) cmd_arm "$@" ;;
  candidates) cmd_candidates "$@" ;;
  run) cmd_run "$@" ;;
  record) cmd_record "$@" ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-loop-actuate.sh" | sed 's/^# \{0,1\}//; $d' ;;
  *) die_usage "unknown command: $COMMAND" ;;
esac
