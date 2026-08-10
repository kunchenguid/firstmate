#!/usr/bin/env bash
# fm-commitment-register.sh - the typed register of RECORDED-BUT-NOT-YET-REAL
# commitments, and the only interpreter of commitments/ and of the pinned probe
# block in a decision file.
#
# WHY THIS EXISTS. A commitment recorded with no enforcement probe reads as
# protection while protecting nothing. This fleet hit that failure four separate
# ways in one day: a captain ruling recorded and never enforced; a guard believed
# to close an inversion that has no runtime caller at all; a derived-state row
# that went stale inside a hand-maintained literal while being trusted; and a
# dated exception that self-expired into prose and was saved by a human filing a
# reminder rather than by any structure. Each was found by a person looking. None
# would have surfaced on its own.
#
# So an entry here carries a PROBE, and the probe is the load-bearing field. The
# entry's state is computed from that probe on every read and is never stored:
#
#   SATISFIED   the probe passed. The entry retires - it stops being surfaced,
#               with no hand edit. A register that needs hand-maintenance is the
#               defect it was built to fix.
#   UNMET       the probe reached a verdict and the commitment is not real yet.
#   UNOBSERVED  the probe reached no verdict, the entry is inadmissible, or the
#               entry is attested rather than probed. Three values, as everywhere
#               else in this fleet: could-not-observe is a real result, and it is
#               never read as enforced.
#
# THREE ENTRY CLASSES, two producers.
#
#   ruling_not_enforced      a ruling is recorded and nothing enforces it
#   authorisation_not_owned  authorised work has no owner
#         Both are JSON entries under commitments/ or the home overlay, and both
#         declare a TYPED probe (see probe_kinds in commitments/schema.json).
#         Typed rather than a raw command because the tracked register ships to
#         every home and a shared file must never become a shell-execution seam.
#
#   ruled_finding_not_met    a review finding was ruled, a fix was reported
#         APPLIED, and nothing establishes that the criterion is MET. Applied is
#         an action; met is a predicate, and a pipeline only ever knows the action
#         happened. These are NOT hand-registered here: the captain ruling of
#         2026-08-10 (data/captain-rulings-2026-08-10/ruled-criterion-must-carry-a-probe.md)
#         pins the probe into the decision file firstmate already writes, at
#         $FM_HOME/data/<task-id>/decision-<key>.md, as exactly one fenced block:
#
#             ```probe
#             tier: executable | cited-control | attested
#             run: <command, run from the task worktree; exit 0 means met>
#             control: <name of the test or artifact watched to fail first>
#             reason: <required for tier attested only - why no probe is possible>
#             ```
#
#         The format is pinned so what firstmate writes and what this file reads
#         cannot drift, which is why this register discovers those probes rather
#         than asking anyone to copy them into a second place.
#
# THE TIERS are the ruling's three, shared by both producers, because forcing a
# probe where none is possible would recreate this same failure one level up:
#   executable     the probe runs directly and its result is the answer.
#   cited-control  the probe confirms a named test exists and passes NOW, while
#                  the watched-it-fail observation is cited as a named artifact
#                  rather than a claim. The DEFAULT: the strongest routinely
#                  achievable form. The ruling pins `control` as a NAME, so it is
#                  surfaced and marked when it also resolves on disk, never gated
#                  on - what no mechanism can confirm is that the cited artifact
#                  records a real red observation, which is why the tier is
#                  "cited" rather than "verified".
#   attested       the criterion genuinely cannot execute. It carries a reason,
#                  declares no probe, and NEVER reaches SATISFIED: it stays marked
#                  and visible rather than being read as verified.
#
# NO BACK-FILLING. A decision key ruled before 2026-08-10 carries no probe block,
# and none is invented for it: it simply has no registered probe, so the fold
# below behaves for it exactly as it always did, and this register reports its
# criterion as could-not-observe rather than manufacturing evidence. A fabricated
# record is indistinguishable from a real one afterwards.
#
# NOT A REPLACEMENT FOR DILIGENCE. Every instance this register was built from was
# caught by a worker re-checking its own work. The probe is a floor beneath that,
# never a substitute, and a green entry licenses nothing.
#
# TRUST BOUNDARY. A decision file's `run:` is executed. Those files are
# firstmate-written, home-private, gitignored material in the operational home
# this command was pointed at - the same trust class as the rest of $FM_HOME/data.
# The tracked register deliberately has no such field: it ships between homes, and
# a shared file that could execute would be a different thing entirely.
#
# Three-valued results are produced and consumed through bin/fm-verify-lib.sh, so
# no probe's silence, error, or empty answer can reach a pass terminal.
#
# It never mutates. It takes no lock, spawns nothing, writes nothing, and touches
# no project. bin/fm-bootstrap.sh relays --open at every session start, so session
# start cannot report a clean or quiet state while a registered commitment is open,
# and bin/fm-classify-lib.sh's open-decision fold calls --closes so a reported-
# applied fix cannot close a criterion nothing established.
#
# Usage:
#   fm-commitment-register.sh [--json]
#       Every entry - both JSON classes and every discovered decision probe -
#       with its computed state and the evidence behind it.
#   fm-commitment-register.sh <id> [--json]
#       One entry. A discovered decision probe's id is decision:<task>:<key>.
#   fm-commitment-register.sh --open
#       One complete "COMMITMENT: ..." line per REGISTERED entry that is not
#       SATISFIED, in the form bin/fm-bootstrap.sh relays verbatim. Silent when
#       every registered entry is satisfied. Never suppressed by age, count, or
#       rate: a quieter question hides a genuine unmet commitment along with the
#       noise. Discovered decision probes are deliberately NOT relayed here - the
#       open-decision fold is their surface, and this adds no second one.
#   fm-commitment-register.sh --closes <task-id> <decision-key>
#       May a `resolved` event for this keyed decision be accepted? Exits 0 when
#       no probe is registered for the key, when its probe passes, or when it is
#       an attested criterion (whose acceptance is printed, never silent), and
#       non-zero otherwise with one line of evidence.
#   fm-commitment-register.sh --help
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  every entry is SATISFIED (or, for --closes, the resolution is accepted)
#   2  usage error
#   3  at least one entry is UNMET, and none is UNOBSERVED
#   4  at least one entry is UNOBSERVED - including a register that could not be
#      read at all, which is never a quiet pass
#
# Entries are read from three places, and a JSON id must be unique across the two
# JSON sources:
#   commitments/<id>.json                tracked; commitments about this repo's own
#                                        shared code, shipped to every home. Its
#                                        absence is UNOBSERVED, not silence: the
#                                        directory ships with bin/, so a missing
#                                        one means the register is not working.
#   $FM_HOME/data/commitments/<id>.json  optional home overlay for captain-private
#                                        commitments that must not reach a shared
#                                        template repo. Its absence is silent.
#   $FM_HOME/data/<task>/decision-<key>.md  discovered ruled-finding probes.
#
# Environment:
#   FM_HOME                       operational home to read (default: repo root)
#   FM_COMMITMENT_DIR             read this tracked register instead (tests)
#   FM_COMMITMENT_HOME_DIR        read this home overlay instead (tests)
#   FM_COMMITMENT_PROBE_TIMEOUT   seconds bounding one probe (default 10)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG_DIR="${FM_COMMITMENT_DIR:-$FM_ROOT/commitments}"
HOME_REG_DIR="${FM_COMMITMENT_HOME_DIR:-$DATA/commitments}"

# shellcheck source=bin/fm-verify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-verify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

EXIT_OK=0
EXIT_USAGE=2
EXIT_UNMET=3
EXIT_UNOBSERVED=4

SCHEMA=fm-commitment-register.v1
SCHEMA_VERSION=1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-commitment-register.sh"
}

die() { printf 'fm-commitment-register: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

MODE=human
TARGET=
CLOSES_TASK=
CLOSES_KEY=

while [ $# -gt 0 ]; do
  case "$1" in
    --json) [ "$MODE" = human ] || die "--json, --open and --closes are different reports"; MODE=json ;;
    --open) [ "$MODE" = human ] || die "--json, --open and --closes are different reports"; MODE=open ;;
    --closes)
      [ "$MODE" = human ] || die "--json, --open and --closes are different reports"
      MODE=closes
      shift
      [ $# -ge 2 ] || die "--closes needs a task id and a decision key"
      CLOSES_TASK=$1
      CLOSES_KEY=$2
      shift
      ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$TARGET" ] || die "one commitment id at a time"
      TARGET=$1
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || {
  # No jq means no JSON entry can be read at all. That is the register failing,
  # not an empty register, so it takes the fail-closed exit rather than a quiet 0.
  case "$MODE" in
    open) printf 'COMMITMENT: register unreadable - jq is required to read commitment entries\n' ;;
    closes) printf 'the commitment register could not be read (jq is required), so this resolution is not accepted\n' ;;
    *) printf 'fm-commitment-register: jq is required to read commitment entries\n' >&2 ;;
  esac
  exit "$EXIT_UNOBSERVED"
}

# A probe must be bounded on every supported host, so a wedged command cannot
# stall session start. With no bounding tool the probe does not run: reporting it
# unobservable is honest, and it is also the answer that never reads as enforced.
PROBE_TIMEOUT=${FM_COMMITMENT_PROBE_TIMEOUT:-10}
bounding_tool() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else return 1
  fi
}
run_timed() {  # <seconds> <command...>
  local seconds=$1 tool
  shift
  tool=$(bounding_tool) || return 125
  "$tool" -k 2 "$seconds" "$@"
}

# An evidence string becomes the last field of a fm-verify.sh record, which is
# newline-delimited. Commas survive because evidence is last; a newline would
# split the record, so it is folded rather than carried.
sanitize() { printf '%s' "$1" | tr '\n\t' '  '; }

# --- probes ------------------------------------------------------------------
#
# Each probe sets PROBE_RESULT (PASS|FAIL|NO_VERIFIER_RAN), PROBE_REASON from
# bin/fm-verify.sh's closed reason vocabulary, and PROBE_EVIDENCE. Nothing else
# reads a probe's exit status: the result IS the answer.

PROBE_RESULT=
PROBE_REASON=
PROBE_EVIDENCE=

probe_answer() {  # <result> <reason> <evidence>
  PROBE_RESULT=$1
  PROBE_REASON=$2
  PROBE_EVIDENCE=$(sanitize "$3")
}

# Does every harness firstmate can launch compose a session whose permission
# enforcement is active? bin/fm-launch-lib.sh's launch_permission_posture is the
# single owner of that answer; this probe reads it and never inspects a flag.
probe_launch_permission_enforced() {  # <probe-json>
  local lib="$SCRIPT_DIR/fm-launch-lib.sh" postures unrestricted unknown
  if [ ! -r "$lib" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "bin/fm-launch-lib.sh is not readable, so the launch posture could not be read"
    return 0
  fi
  postures=$(
    # shellcheck source=bin/fm-launch-lib.sh disable=SC1090,SC1091
    . "$lib" 2>/dev/null && launch_permission_posture 2>/dev/null
  ) || postures=
  if [ -z "$postures" ]; then
    probe_answer NO_VERIFIER_RAN empty_result_set \
      "bin/fm-launch-lib.sh reported no launch posture for any harness"
    return 0
  fi
  unrestricted=$(printf '%s\n' "$postures" | awk '$2 == "unrestricted" { printf "%s ", $1 }')
  unknown=$(printf '%s\n' "$postures" | awk '$2 == "unknown" { printf "%s ", $1 }')
  if [ -n "$unrestricted" ]; then
    probe_answer FAIL verifier_reported_failure \
      "these harnesses launch a worker with permission enforcement disabled: ${unrestricted% }"
    return 0
  fi
  if [ -n "$unknown" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "no harness is unrestricted, but the permission posture of ${unknown% } is not recorded, so enforcement cannot be claimed"
    return 0
  fi
  probe_answer PASS verified "every launchable harness composes a session with permission enforcement active"
}

# Reads .args into the caller's PROBE_ARGV array.
PROBE_ARGV=()
read_probe_argv() {  # <probe-json>
  local line
  PROBE_ARGV=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    PROBE_ARGV+=("$line")
  done < <(printf '%s' "$1" | jq -r '(.args // [])[]')
}

# Does the declared owner exist and answer? An owner that is not there is an
# observed absence, not an unobservable one - that distinction is the whole point
# of naming an owner in the entry.
probe_command_answers() {  # <probe-json>
  local probe=$1 rel cmd out rc
  rel=$(printf '%s' "$probe" | jq -r '.command // ""')
  if [ -z "$rel" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no command"
    return 0
  fi
  case "$rel" in
    /*) cmd=$rel ;;
    *) cmd="$FM_ROOT/$rel" ;;
  esac
  if [ ! -x "$cmd" ]; then
    probe_answer FAIL verifier_reported_failure \
      "the declared owner $rel is not present and executable, so nothing performs this commitment"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound the declared owner $rel, so it was not run"
    return 0
  fi
  read_probe_argv "$probe"
  out=$(run_timed "$PROBE_TIMEOUT" "$cmd" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the declared owner $rel did not answer within ${PROBE_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure "the declared owner $rel exited $rc"
    return 0
  fi
  if [ -z "$out" ]; then
    probe_answer NO_VERIFIER_RAN empty_result_set \
      "the declared owner $rel exited 0 printing nothing, which answers nothing"
    return 0
  fi
  probe_answer PASS verified "the declared owner $rel answered"
}

# Does the named test exist and pass NOW? The probe half of the cited-control
# tier: it establishes that the criterion holds today, while the entry's cited
# control carries the watched-it-fail observation proving the test can go red. A
# test that is absent is FAIL, not could-not-observe: a criterion whose test does
# not exist was never established, and calling that unobservable would hide it.
probe_test_passes() {  # <probe-json>
  local probe=$1 rel test out rc
  rel=$(printf '%s' "$probe" | jq -r '.test // ""')
  if [ -z "$rel" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no test"
    return 0
  fi
  case "$rel" in
    /*) test=$rel ;;
    *) test="$FM_ROOT/$rel" ;;
  esac
  if [ ! -f "$test" ]; then
    probe_answer FAIL verifier_reported_failure \
      "the named test $rel does not exist, so the criterion it was to establish never was established"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound $rel, so it was not run"
    return 0
  fi
  read_probe_argv "$probe"
  if [ -x "$test" ]; then
    out=$(run_timed "$PROBE_TIMEOUT" "$test" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>&1)
  else
    out=$(run_timed "$PROBE_TIMEOUT" bash "$test" "${PROBE_ARGV[@]+"${PROBE_ARGV[@]}"}" 2>&1)
  fi
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the named test $rel did not finish within ${PROBE_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure \
      "the named test $rel exited $rc: $(printf '%s' "$out" | tail -1)"
    return 0
  fi
  probe_answer PASS verified "the named test $rel passes now"
}

# Does this guard have a runtime caller? A function reachable only from its own
# tests enforces nothing in production, however correct the function is.
probe_symbol_called() {  # <probe-json>
  local probe=$1 symbol defined_in callers
  symbol=$(printf '%s' "$probe" | jq -r '.symbol // ""')
  defined_in=$(printf '%s' "$probe" | jq -r '.defined_in // ""')
  if [ -z "$symbol" ] || [ -z "$defined_in" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no symbol or no defining file"
    return 0
  fi
  if [ ! -r "$FM_ROOT/$defined_in" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "$defined_in is not readable, so a definition of $symbol could not be told from a call to it"
    return 0
  fi
  if [ ! -d "$FM_ROOT/bin" ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "$FM_ROOT/bin is not readable, so callers of $symbol could not be enumerated"
    return 0
  fi
  callers=$(
    grep -rlw -- "$symbol" "$FM_ROOT/bin" 2>/dev/null |
      grep -vF -- "$FM_ROOT/$defined_in" |
      sed "s#^$FM_ROOT/##" | sort | tr '\n' ' '
  )
  if [ -z "$callers" ]; then
    probe_answer FAIL verifier_reported_failure \
      "$symbol is defined in $defined_in and called from nowhere under bin/, so it guards nothing at runtime"
    return 0
  fi
  probe_answer PASS verified "$symbol is called from ${callers% }"
}

# Does anything own this authorisation? An authorisation with no owner decays
# into prose exactly the way a dated exception does.
probe_work_owned() {  # <probe-json>
  local probe=$1 id show rc git_answered=0 state=
  id=$(printf '%s' "$probe" | jq -r '.work_id // ""')
  if [ -z "$id" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "probe declares no work_id"
    return 0
  fi
  if [ -f "$STATE/$id.meta" ]; then
    probe_answer PASS verified "a live task record owns $id"
    return 0
  fi
  # git first, because a branch answers without any backlog backend at all.
  if command -v git >/dev/null 2>&1 && git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git_answered=1
    if git -C "$FM_ROOT" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null 2>&1; then
      probe_answer PASS verified "a local branch fm/$id owns $id"
      return 0
    fi
  fi
  # The compatibility floor in fm-tasks-axi-lib.sh gates MUTATION features
  # (update --archive-body, multi-id mv) and costs three subprocesses to answer.
  # This is a read, so it gates on the two things a read actually needs - a
  # non-manual backend and the tool being present - and lets the read itself
  # answer. Session start is on every session's critical path; a check that is
  # slow enough to be turned off protects nothing.
  if fm_backlog_backend_manual "$CONFIG" || ! command -v tasks-axi >/dev/null 2>&1 \
    || ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no live task record and no local branch owns $id, and the backlog could not be read mechanically here, so an already-dispatched or already-landed record cannot be ruled out"
    return 0
  fi
  show=$(cd "$FM_HOME" && run_timed "$PROBE_TIMEOUT" tasks-axi show "$id" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the backlog did not answer for $id within ${PROBE_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" -eq 0 ] && [ -n "$show" ]; then
    state=$(printf '%s\n' "$show" | awk -F': ' '$1 ~ /^ *state$/ { print $2; exit }')
  fi
  case "$state" in
    in_flight|done)
      probe_answer PASS verified "the backlog records $id as $state"
      return 0
      ;;
  esac
  if [ "$git_answered" -eq 0 ]; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "the backlog does not own $id and no git checkout was readable, so a branch owning it could not be ruled out"
    return 0
  fi
  probe_answer FAIL verifier_reported_failure \
    "nothing owns $id: no live task record, no local branch fm/$id, and no in-flight or done backlog record"
}

run_probe() {  # <probe-json>
  local kind
  kind=$(printf '%s' "$1" | jq -r '.kind // ""')
  case "$kind" in
    launch_permission_enforced) probe_launch_permission_enforced "$1" ;;
    command_answers) probe_command_answers "$1" ;;
    test_passes) probe_test_passes "$1" ;;
    symbol_called) probe_symbol_called "$1" ;;
    work_owned) probe_work_owned "$1" ;;
    *) probe_answer NO_VERIFIER_RAN usage_error "unknown probe kind \"$kind\"" ;;
  esac
}

# --- the pinned decision-file probe block ------------------------------------
#
# One fenced ```probe block per decision file, in the format the 2026-08-10 ruling
# pinned. The parser refuses a second block rather than choosing one: a file
# carrying two probes has no single answer, and picking either would invent one.

DP_TIER='' DP_RUN='' DP_CONTROL='' DP_REASON='' DP_FAULT=''
parse_decision_probe() {  # <decision-file> -> 0 with DP_* set, 1 when no block
  local file=$1 line in_block=0 blocks=0 key value
  DP_TIER='' DP_RUN='' DP_CONTROL='' DP_REASON='' DP_FAULT=''
  # An existing file this process cannot read may carry a probe nobody can see,
  # so it is a fault rather than "no block" - and reading it unguarded would put a
  # shell error on stderr instead of an answer.
  if [ ! -r "$file" ]; then
    DP_FAULT="the decision file exists but cannot be read, so a registered probe cannot be ruled out"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '```probe'|'```probe '*)
        if [ "$in_block" -eq 1 ]; then
          DP_FAULT="a probe block is opened inside another probe block"
          return 0
        fi
        blocks=$((blocks + 1))
        in_block=1
        continue
        ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      case "$line" in
        '```'*) in_block=0; continue ;;
      esac
      case "$line" in
        *:*) ;;
        *) continue ;;
      esac
      key=${line%%:*}
      key=${key#"${key%%[![:space:]]*}"}
      key=${key%"${key##*[![:space:]]}"}
      value=${line#*:}
      value=${value#"${value%%[![:space:]]*}"}
      value=${value%"${value##*[![:space:]]}"}
      case "$key" in
        tier) DP_TIER=$value ;;
        run) DP_RUN=$value ;;
        control) DP_CONTROL=$value ;;
        reason) DP_REASON=$value ;;
      esac
    fi
  done < "$file"
  [ "$blocks" -ne 0 ] || return 1
  if [ "$blocks" -gt 1 ]; then
    DP_FAULT="the file carries $blocks probe blocks; the pinned format allows exactly one"
    return 0
  fi
  [ "$in_block" -eq 0 ] || DP_FAULT="the probe block is never closed"
  return 0
}

# Validates DP_* against the pinned per-tier requirements. Prints one fault, or
# nothing when the block is well formed.
decision_probe_fault() {
  [ -z "$DP_FAULT" ] || { printf '%s' "$DP_FAULT"; return 0; }
  case "$DP_TIER" in
    executable)
      [ -n "$DP_RUN" ] || { printf 'tier executable declares no run'; return 0; }
      ;;
    cited-control)
      [ -n "$DP_RUN" ] || { printf 'tier cited-control declares no run'; return 0; }
      [ -n "$DP_CONTROL" ] || { printf 'tier cited-control declares no control'; return 0; }
      ;;
    attested)
      [ -n "$DP_REASON" ] || { printf 'tier attested declares no reason'; return 0; }
      [ -z "$DP_RUN" ] || { printf 'tier attested carries a run; an attested criterion declares no probe'; return 0; }
      ;;
    '') printf 'the probe block declares no tier' ;;
    *) printf 'unknown tier "%s"' "$DP_TIER" ;;
  esac
}

decision_file() {  # <task> <key>
  printf '%s/%s/decision-%s.md' "$DATA" "$1" "$2"
}

# The worktree the ruling says a `run:` executes from. An absent record or an
# absent directory is could-not-observe: the probe did not run, and a probe that
# did not run is never a pass.
task_worktree() {  # <task> -> path, or empty
  local meta="$STATE/$1.meta" wt
  [ -r "$meta" ] || return 1
  wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  printf '%s' "$wt"
}

# Runs one parsed decision probe, setting PROBE_*. DP_* must already be valid.
run_decision_probe() {  # <task> <key>
  local task=$1 key=$2 wt out rc
  if [ "$DP_TIER" = attested ]; then
    # Marked and visible, never verified: an attested criterion has no verdict to
    # reach, so it stays could-not-observe by construction rather than by failure.
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "attested, not probed: $DP_REASON"
    return 0
  fi
  if [ "$DP_TIER" = cited-control ] && [ -z "$DP_CONTROL" ]; then
    probe_answer NO_VERIFIER_RAN usage_error "tier cited-control cites no control"
    return 0
  fi
  if ! wt=$(task_worktree "$task"); then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the task worktree for $task is not recorded or no longer exists, so the probe for $key could not be run from it"
    return 0
  fi
  if ! bounding_tool >/dev/null; then
    probe_answer NO_VERIFIER_RAN verifier_unavailable \
      "no timeout tool is available to bound the probe for $key, so it was not run"
    return 0
  fi
  out=$(cd "$wt" && run_timed "$PROBE_TIMEOUT" bash -c "$DP_RUN" 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the probe for $key did not finish within ${PROBE_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" -eq 125 ] || [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "the probe for $key could not execute (exit $rc): $(printf '%s' "$out" | tail -1)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    probe_answer FAIL verifier_reported_failure \
      "the criterion is not met: the probe for $key exited $rc: $(printf '%s' "$out" | tail -1)"
    return 0
  fi
  if [ "$DP_TIER" = cited-control ]; then
    probe_answer PASS verified \
      "the probe for $key passes now, with $(control_citation "$DP_CONTROL") cited as the control watched to fail first"
    return 0
  fi
  probe_answer PASS verified "the probe for $key exits 0, so the criterion is met"
}

# --- admissibility -----------------------------------------------------------
#
# schema.json owns the field contract; it is read rather than restated, so the
# two cannot disagree. An inadmissible entry is reported, never dropped.

REFUSED_KEYS=
REQUIRED_KEYS=
SCHEMA_PATH=
SCHEMA_READ=0
read_schema() {
  [ "$SCHEMA_READ" -eq 0 ] || return 0
  local path="$REG_DIR/schema.json"
  [ -r "$path" ] || return 1
  jq -e '.commitment_schema_version and .required and .refused_keys
         and .assurance_tiers and .required_by_assurance' "$path" >/dev/null 2>&1 || return 1
  REFUSED_KEYS=$(jq -r '.refused_keys[]' "$path")
  REQUIRED_KEYS=$(jq -r '.required | keys[]' "$path")
  SCHEMA_PATH=$path
  SCHEMA_READ=1
  return 0
}

# Prints one refusal reason, or nothing when the entry is admissible.
entry_inadmissible_reason() {  # <entry-json> <expected-id>
  local doc=$1 want=$2 key got tier
  printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { printf 'entry is not a JSON object'; return 0; }
  got=$(printf '%s' "$doc" | jq -r '.id // ""')
  [ "$got" = "$want" ] \
    || { printf 'entry id "%s" does not match its filename "%s"' "$got" "$want"; return 0; }
  got=$(printf '%s' "$doc" | jq -r '.commitment_schema_version // ""')
  [ "$got" = "$SCHEMA_VERSION" ] \
    || { printf 'commitment_schema_version is "%s", not %s' "$got" "$SCHEMA_VERSION"; return 0; }
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if printf '%s' "$doc" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
      printf 'entry carries a hand-written "%s"; a status word must not be able to satisfy a commitment' "$key"
      return 0
    fi
  done <<EOF
$REFUSED_KEYS
EOF
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! printf '%s' "$doc" | jq -e --arg k "$key" '(.[$k] // "") != ""' >/dev/null 2>&1; then
      printf 'entry has no %s' "$key"
      return 0
    fi
  done <<EOF
$REQUIRED_KEYS
EOF
  tier=$(printf '%s' "$doc" | jq -r '.assurance // ""')
  if ! jq -e --arg t "$tier" '.assurance_tiers | has($t)' "$SCHEMA_PATH" >/dev/null 2>&1; then
    printf 'unknown assurance tier "%s"' "$tier"
    return 0
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! printf '%s' "$doc" | jq -e --arg k "$key" '(.[$k] // "") != "" or ((.[$k] | type) == "object")' >/dev/null 2>&1; then
      printf 'assurance tier "%s" requires %s, and the entry has none' "$tier" "$key"
      return 0
    fi
  done < <(jq -r --arg t "$tier" '.required_by_assurance[$t][]? ' "$SCHEMA_PATH")
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if printf '%s' "$doc" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
      printf 'assurance tier "%s" forbids %s' "$tier" "$key"
      return 0
    fi
  done < <(jq -r --arg t "$tier" '.forbidden_by_assurance[$t][]? ' "$SCHEMA_PATH")
  if [ "$tier" != attested ]; then
    printf '%s' "$doc" | jq -e '(.probe | type) == "object" and ((.probe.kind // "") != "")' >/dev/null 2>&1 \
      || { printf 'entry declares no probe; an entry without one cannot be admitted'; return 0; }
  fi
  return 0
}

# --- reading the register ----------------------------------------------------

REGISTER_FAULT=
ENTRY_IDS=()
ENTRY_PATHS=()
ENTRY_SOURCES=()

collect_dir() {  # <dir> <required 0|1>
  local dir=$1 required=$2 f base i
  if [ ! -d "$dir" ]; then
    [ "$required" -eq 0 ] || REGISTER_FAULT="the tracked register $dir is absent, so no commitment could be read"
    return 0
  fi
  if [ ! -r "$dir" ]; then
    REGISTER_FAULT="the register $dir is not readable"
    return 0
  fi
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in schema.json) continue ;; esac
    base=${base%.json}
    for i in "${ENTRY_IDS[@]+"${ENTRY_IDS[@]}"}"; do
      if [ "$i" = "$base" ]; then
        REGISTER_FAULT="commitment id \"$base\" is declared twice; an id must be unique across the tracked register and the home overlay"
        return 0
      fi
    done
    ENTRY_IDS+=("$base")
    ENTRY_PATHS+=("$f")
    ENTRY_SOURCES+=(json)
  done
}

# Discovered ruled-finding probes. Only files that actually carry a probe block
# become entries: a decision ruled before the format existed has no registered
# probe, and manufacturing one for it is exactly what the ruling forbids.
collect_decisions() {
  local f task key
  [ -d "$DATA" ] || return 0
  for f in "$DATA"/*/decision-*.md; do
    [ -e "$f" ] || continue
    task=${f#"$DATA"/}
    task=${task%%/*}
    key=${f##*/decision-}
    key=${key%.md}
    parse_decision_probe "$f" || continue
    ENTRY_IDS+=("decision:$task:$key")
    ENTRY_PATHS+=("$f")
    ENTRY_SOURCES+=(decision)
  done
}

collect_dir "$REG_DIR" 1
[ -n "$REGISTER_FAULT" ] || collect_dir "$HOME_REG_DIR" 0
if [ -z "$REGISTER_FAULT" ] && [ "${#ENTRY_IDS[@]}" -gt 0 ] && ! read_schema; then
  REGISTER_FAULT="$REG_DIR/schema.json is missing or unreadable, so no entry could be validated"
fi
# Neither --open nor --closes needs the decision inventory: --open deliberately
# leaves discovered probes to the open-decision fold, and --closes is asked about
# one named key and reads only that key's file.
case "$MODE" in
  open|closes) ;;
  *) [ -n "$REGISTER_FAULT" ] || collect_decisions ;;
esac

# --- evaluation --------------------------------------------------------------

ENTRY_STATE=''
# The three handlers fm_verify_case dispatches to. It calls them BY NAME, which
# is the mechanism that lets it refuse a consumer that does not supply all three,
# so they are invoked indirectly and never from this file.
# shellcheck disable=SC2329
on_pass() { ENTRY_STATE=SATISFIED; }
# shellcheck disable=SC2329
on_fail() { ENTRY_STATE=UNMET; }
# shellcheck disable=SC2329
on_unverified() { ENTRY_STATE=UNOBSERVED; }

E_ID='' E_RECORDED='' E_AUTHORITY='' E_UNMET_STATE='' E_SATISFIED_WHEN='' E_TIER='' E_KIND=''
E_CONTROL='' E_DEADLINE='' E_NOTE='' E_OVERDUE=0 E_SOURCE=''

reset_entry_fields() {
  E_RECORDED='' E_AUTHORITY='' E_UNMET_STATE='' E_SATISFIED_WHEN='' E_TIER='' E_KIND=''
  E_CONTROL='' E_DEADLINE='' E_NOTE='' E_OVERDUE=0
}

# Maps PROBE_* onto ENTRY_STATE through the three-valued consumer, which refuses a
# reader that does not handle all three.
settle_entry_state() {  # <id>
  local record
  record=$(printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  commitment:%s,%s,%s,%s\n' \
    "$1" "$PROBE_RESULT" "$PROBE_REASON" "$PROBE_EVIDENCE")
  ENTRY_STATE=
  fm_verify_case "$record" on_pass on_fail on_unverified
  if [ -z "$ENTRY_STATE" ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "the probe result could not be read as a three-valued observation"
  fi
}

evaluate_json_entry() {  # <id> <path>
  local id=$1 path=$2 doc reason
  if ! doc=$(cat "$path" 2>/dev/null) || ! printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "entry file $path could not be read as JSON"
    return 0
  fi
  reason=$(entry_inadmissible_reason "$doc" "$id")
  E_RECORDED=$(printf '%s' "$doc" | jq -r '.recorded // ""')
  E_AUTHORITY=$(printf '%s' "$doc" | jq -r '.authority // ""')
  E_UNMET_STATE=$(printf '%s' "$doc" | jq -r '.unmet_state // ""')
  E_SATISFIED_WHEN=$(printf '%s' "$doc" | jq -r '.satisfied_when // ""')
  E_TIER=$(printf '%s' "$doc" | jq -r '.assurance // ""')
  E_KIND=$(printf '%s' "$doc" | jq -r '.probe.kind // ""')
  E_CONTROL=$(printf '%s' "$doc" | jq -r '.control // ""')
  E_DEADLINE=$(printf '%s' "$doc" | jq -r '.deadline // ""')
  E_NOTE=$(printf '%s' "$doc" | jq -r '.note // ""')
  if [ -n "$reason" ]; then
    # Inadmissible is could-not-observe, and loudly so: an entry this file cannot
    # interpret is an entry whose commitment it cannot judge.
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "inadmissible entry: $reason"
    return 0
  fi
  if [ "$E_TIER" = attested ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN verification_unreachable \
      "attested, not probed: $(printf '%s' "$doc" | jq -r '.reason // "no reason recorded"')"
    return 0
  fi
  run_probe "$(printf '%s' "$doc" | jq -c '.probe')"
  if [ "$E_TIER" = cited-control ] && [ "$PROBE_RESULT" = PASS ]; then
    probe_answer PASS verified \
      "$PROBE_EVIDENCE, with $(control_citation "$E_CONTROL") cited as the control watched to fail first"
  fi
  settle_entry_state "$id"
}

# The ruling pins `control` as the NAME of the test or artifact watched to fail
# first, so the register surfaces it rather than gating on it - a name is not
# required to be a resolvable path, and rejecting a legitimate citation that is
# not one would make the tier unusable. When the name does resolve to something on
# disk, say so, because that is strictly more than the citation claimed. What the
# register cannot do is confirm the artifact records a real red observation; that
# is why the tier is "cited", and why it sits below nothing and above a claim.
control_citation() {  # <control> -> the citation, marked when it resolves
  if [ -n "${1:-}" ] && { [ -e "$FM_ROOT/$1" ] || [ -e "$FM_HOME/$1" ] || [ -e "$1" ]; }; then
    printf '%s (resolves on disk)' "$1"
  else
    printf '%s' "${1:-an unnamed control}"
  fi
}

evaluate_decision_entry() {  # <id> <path>
  local id=$1 path=$2 task key fault
  task=${id#decision:}
  key=${task#*:}
  task=${task%%:*}
  E_AUTHORITY=${path#"$FM_HOME"/}
  E_UNMET_STATE=RULED-NOT-MET
  E_SATISFIED_WHEN="the probe this ruling pinned exits 0, so the ruled criterion is met rather than merely applied"
  if ! parse_decision_probe "$path"; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "the decision file carries no probe block"
    return 0
  fi
  E_TIER=$DP_TIER
  E_CONTROL=$DP_CONTROL
  E_RECORDED="ruled criterion for decision $key on task $task"
  fault=$(decision_probe_fault)
  if [ -n "$fault" ]; then
    ENTRY_STATE=UNOBSERVED
    probe_answer NO_VERIFIER_RAN usage_error "inadmissible probe block: $fault"
    return 0
  fi
  run_decision_probe "$task" "$key"
  settle_entry_state "$id"
}

evaluate_entry() {  # <index>
  local i=$1 today
  E_ID=${ENTRY_IDS[$i]}
  E_SOURCE=${ENTRY_SOURCES[$i]}
  reset_entry_fields
  case "$E_SOURCE" in
    decision) evaluate_decision_entry "$E_ID" "${ENTRY_PATHS[$i]}" ;;
    *) evaluate_json_entry "$E_ID" "${ENTRY_PATHS[$i]}" ;;
  esac
  if [ "$ENTRY_STATE" != SATISFIED ] && [ -n "$E_DEADLINE" ]; then
    today=$(date -u +%Y-%m-%d)
    [ "$E_DEADLINE" \< "$today" ] && E_OVERDUE=1
  fi
  return 0
}

# --- reports -----------------------------------------------------------------

open_line() {
  local label detail
  if [ "$ENTRY_STATE" = UNMET ]; then
    label="UNMET (${E_UNMET_STATE:-unlabelled})"
  else
    label=COULD-NOT-OBSERVE
  fi
  detail=$PROBE_EVIDENCE
  [ "$E_OVERDUE" -eq 1 ] && detail="$detail; past its $E_DEADLINE deadline"
  printf 'COMMITMENT: %s %s - %s\n' "$E_ID" "$label" "$detail"
}

render_open() {
  local worst="$EXIT_OK" i
  if [ -n "$REGISTER_FAULT" ]; then
    printf 'COMMITMENT: register unreadable - %s\n' "$REGISTER_FAULT"
    return "$EXIT_UNOBSERVED"
  fi
  for i in "${!ENTRY_IDS[@]}"; do
    evaluate_entry "$i"
    case "$ENTRY_STATE" in
      SATISFIED) continue ;;
      UNMET) [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET ;;
      *) worst=$EXIT_UNOBSERVED ;;
    esac
    open_line
  done
  return "$worst"
}

render_human() {
  local worst="$EXIT_OK" i satisfied=0 unmet=0 unobserved=0 shown=0
  if [ -n "$REGISTER_FAULT" ]; then
    printf 'commitment register · UNREADABLE\n  %s\n' "$REGISTER_FAULT"
    return "$EXIT_UNOBSERVED"
  fi
  printf 'Commitments recorded, and whether a probe says they are real yet.\n\n'
  for i in "${!ENTRY_IDS[@]}"; do
    [ -z "$TARGET" ] || [ "${ENTRY_IDS[$i]}" = "$TARGET" ] || continue
    evaluate_entry "$i"
    shown=$((shown + 1))
    case "$ENTRY_STATE" in
      SATISFIED) satisfied=$((satisfied + 1)); printf '  SATISFIED   %s (retired: the probe passed)\n' "$E_ID" ;;
      UNMET) unmet=$((unmet + 1)); [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET
        printf '  UNMET       %s   %s\n' "$E_ID" "${E_UNMET_STATE:-unlabelled}" ;;
      *) unobserved=$((unobserved + 1)); worst=$EXIT_UNOBSERVED
        printf '  UNOBSERVED  %s   could-not-observe\n' "$E_ID" ;;
    esac
    [ -z "$E_RECORDED" ] || printf '              recorded:   %s\n' "$E_RECORDED"
    [ -z "$E_AUTHORITY" ] || printf '              authority:  %s\n' "$E_AUTHORITY"
    [ -z "$E_SATISFIED_WHEN" ] || printf '              real when:  %s\n' "$E_SATISFIED_WHEN"
    printf '              tier:       %s\n' "${E_TIER:-none declared}"
    [ -z "$E_CONTROL" ] || printf '              control:    %s\n' "$E_CONTROL"
    printf '              observed:   %s\n' "$PROBE_EVIDENCE"
    [ "$E_OVERDUE" -eq 1 ] && printf '              OVERDUE:    the %s deadline has passed\n' "$E_DEADLINE"
    [ -z "$E_NOTE" ] || printf '              note:       %s\n' "$E_NOTE"
    printf '\n'
  done
  if [ -n "$TARGET" ] && [ "$shown" -eq 0 ]; then
    printf 'fm-commitment-register: no commitment with id "%s"\n' "$TARGET" >&2
    return "$EXIT_UNOBSERVED"
  fi
  printf '%s satisfied · %s unmet · %s could-not-observe\n' "$satisfied" "$unmet" "$unobserved"
  printf 'A state here is computed from the probe on every read and is never stored.\n'
  return "$worst"
}

render_json() {
  local worst="$EXIT_OK" i shown=0 rows='[]' row
  if [ -n "$REGISTER_FAULT" ]; then
    jq -n --arg schema "$SCHEMA" --arg fault "$REGISTER_FAULT" \
      '{schema:$schema, register_fault:$fault, entries:[]}'
    return "$EXIT_UNOBSERVED"
  fi
  for i in "${!ENTRY_IDS[@]}"; do
    [ -z "$TARGET" ] || [ "${ENTRY_IDS[$i]}" = "$TARGET" ] || continue
    evaluate_entry "$i"
    shown=$((shown + 1))
    case "$ENTRY_STATE" in
      UNMET) [ "$worst" -eq "$EXIT_UNOBSERVED" ] || worst=$EXIT_UNMET ;;
      UNOBSERVED) worst=$EXIT_UNOBSERVED ;;
    esac
    row=$(jq -cn \
      --arg id "$E_ID" --arg source "$E_SOURCE" --arg recorded "$E_RECORDED" \
      --arg authority "$E_AUTHORITY" --arg unmet_state "$E_UNMET_STATE" \
      --arg satisfied_when "$E_SATISFIED_WHEN" --arg tier "$E_TIER" \
      --arg kind "$E_KIND" --arg control "$E_CONTROL" --arg deadline "$E_DEADLINE" \
      --arg note "$E_NOTE" --arg state "$ENTRY_STATE" --arg result "$PROBE_RESULT" \
      --arg reason "$PROBE_REASON" --arg evidence "$PROBE_EVIDENCE" \
      --argjson overdue "$E_OVERDUE" \
      '{id:$id, source:$source, recorded:$recorded, authority:$authority,
        unmet_state:$unmet_state, satisfied_when:$satisfied_when,
        assurance:(if $tier == "" then null else $tier end),
        probe_kind:(if $kind == "" then null else $kind end),
        control:(if $control == "" then null else $control end),
        deadline:(if $deadline == "" then null else $deadline end),
        note:(if $note == "" then null else $note end),
        state:$state, probe_result:$result, probe_reason:$reason,
        probe_evidence:$evidence, overdue:($overdue == 1),
        state_is_derived:true}')
    rows=$(printf '%s' "$rows" | jq -c --argjson r "$row" '. + [$r]')
  done
  jq -n --arg schema "$SCHEMA" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg register "$REG_DIR" --arg overlay "$HOME_REG_DIR" --argjson rows "$rows" \
    '{schema:$schema, generated:$generated, register:$register,
      home_overlay:$overlay, register_fault:null, entries:$rows}'
  if [ -n "$TARGET" ] && [ "$shown" -eq 0 ]; then
    printf 'fm-commitment-register: no commitment with id "%s"\n' "$TARGET" >&2
    return "$EXIT_UNOBSERVED"
  fi
  return "$worst"
}

# The closure gate. Silence plus exit 0 is "no probe is registered for this key",
# which is the answer for every decision ruled before the format existed.
render_closes() {
  local file
  file=$(decision_file "$CLOSES_TASK" "$CLOSES_KEY")
  # No decision file at all means no probe is registered for this key, which is
  # the answer for every decision ruled before the format existed - accept, and
  # say nothing. A file that EXISTS but cannot be read is a different answer: it
  # may carry a probe nobody can see, so it refuses rather than accepting.
  [ -e "$file" ] || return "$EXIT_OK"
  if [ ! -r "$file" ]; then
    printf 'the decision file %s exists but cannot be read, so a registered probe cannot be ruled out and this resolution is not accepted\n' \
      "${file#"$FM_HOME"/}"
    return "$EXIT_UNOBSERVED"
  fi
  parse_decision_probe "$file" || return "$EXIT_OK"
  local fault
  fault=$(decision_probe_fault)
  if [ -n "$fault" ]; then
    printf 'the probe block in %s cannot be read (%s), so this resolution is not accepted\n' \
      "${file#"$FM_HOME"/}" "$fault"
    return "$EXIT_UNOBSERVED"
  fi
  if [ "$DP_TIER" = attested ]; then
    # Accepted, never silently: the acceptance itself says it was attested rather
    # than verified, so nothing downstream can read it as a passed probe.
    printf 'accepted as ATTESTED-NOT-PROBED, not verified: %s\n' "$DP_REASON"
    return "$EXIT_OK"
  fi
  run_decision_probe "$CLOSES_TASK" "$CLOSES_KEY"
  case "$PROBE_RESULT" in
    PASS) return "$EXIT_OK" ;;
    FAIL) printf '%s\n' "$PROBE_EVIDENCE"; return "$EXIT_UNMET" ;;
    *) printf '%s\n' "$PROBE_EVIDENCE"; return "$EXIT_UNOBSERVED" ;;
  esac
}

case "$MODE" in
  open)
    [ -z "$TARGET" ] || die "--open reports the whole register"
    render_open
    exit $?
    ;;
  closes)
    [ -z "$TARGET" ] || die "--closes takes a task id and a decision key"
    render_closes
    exit $?
    ;;
  json) render_json; exit $? ;;
  *) render_human; exit $? ;;
esac
