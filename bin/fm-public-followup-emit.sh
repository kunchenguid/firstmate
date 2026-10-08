#!/usr/bin/env bash
# fm-public-followup-emit.sh - emit ONE structured terminal work result for work
# bound to a public commitment, into the owning home's private event inbox.
#
# WHY THIS EXISTS: a public promise is kept by the home that owns the relay
# consent and the thread binding. The home doing the work only has to report a
# TYPED result. Firstmate must never recover the source home, work id, outcome,
# or deliverables by parsing a free-form "done: ..." status sentence, so this
# script is the structured channel that carries them.
#
# WHAT IT DOES NOT DO: it never posts anything, never reads relay credentials,
# and never resolves a public thread. Outward delivery stays with the owning
# home (bin/fm-public-followup.sh deliver).
#
# Usage:
#   fm-public-followup-emit.sh (--home <owning-home> | --stage-in <work-home>) \
#     --obligation <obligation-id> --relation <relation-id> \
#     --source-home <main|secondmate:<id>> --work-id <task-id> \
#     --generation <n> --outcome <outcome-type> \
#     [--deliverable <key>=<value>]... [--require-deliverable <key>]... \
#     (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)
#
# Options:
#   --home <path>          The home that owns the public commitment (the primary
#                          that took the mention). Must already have a
#                          registration for --obligation; see
#                          `fm-public-followup.sh register`. Use this whenever
#                          the owning home is on THIS machine.
#   --stage-in <path>      The home THIS worker runs in, when the owning home is
#                          on another machine and no local path reaches it. The
#                          typed event is staged in this home's public-followup
#                          outbox with the identical identity, shape, and bounds,
#                          and the owning home collects it over the route's own
#                          transport (bin/fm-public-followup-collect.sh). Exactly
#                          one of --home and --stage-in is required;
#                          `fm-public-followup.sh brief` prints whichever the
#                          bound work home actually needs.
#   --obligation <id>      tasks-axi public-followup obligation id.
#   --relation <id>        The relation_id this work fulfills or contributes to.
#   --source-home <id>     This worker's stable home identity, exactly as bound:
#                          "main" or "secondmate:<stable-id>".
#   --work-id <id>         This worker's exact task id, exactly as bound.
#   --generation <n>       The bound relation generation (integer >= 1).
#   --outcome <type>       Typed outcome. With --home, an outcome that cannot
#                          satisfy the registered expected final is refused here,
#                          and so is 'superseded', which tasks-axi takes only
#                          with a successor this result cannot carry. tasks-axi
#                          still owns the vocabulary.
#   --deliverable k=v      Repeatable safe deliverable (for example
#                          pr_url=https://...). A key this promise does not carry
#                          on this outcome, or a value tasks-axi refuses - a bad
#                          format such as an absolute report_path, more than 500
#                          characters, or anything but safe single-line text - is
#                          refused here with the specific problem and applicable
#                          correction, in both destinations.
#                          fm-public-followup-lib.sh owns those mirrored rules.
#   --require-deliverable <key>
#                          Repeatable key this event MUST carry, so an event
#                          missing a required value is refused here instead of
#                          being quarantined by the owning home. It is how the
#                          obligation's required keys reach a staged emit, where
#                          that obligation's own record is on another machine;
#                          `fm-public-followup.sh brief` prints one per required
#                          key. With --home the obligation's required keys are
#                          read from tasks-axi and enforced whether or not the
#                          flag is passed; a staged emit enforces exactly the
#                          keys it was given, because the outcome alone cannot
#                          tell a key this promise requires from one it does
#                          not. A failed outcome is exempt only from a key it
#                          could not carry anyway: a promise whose expected
#                          final IS the failure still needs its error_code.
#   --outcome-text ...     Public-safe outcome sentence, from an argument, a
#                          file, or stdin ("-"). Collapsed to one line; the
#                          event builder bounds it by codepoint, so control
#                          characters cannot survive.
#
# Output: the event id on stdout. Exit 0 on a published or already-present event
# (both are successes: the id is derived, so re-emitting the same terminal result
# is a no-op), 2 on a usage or validation error, 1 on a publication failure.
#
# IDEMPOTENCY: the event id is a digest of the identity tuple (obligation,
# relation, source home, work id, generation, outcome type, deliverables), so a
# retry, a duplicate report, or a rerun after restart resolves to the same file
# and the first published copy wins. Nothing here needs coordination.
#
# SAFETY: the event is published through the shared private-artifact primitive -
# atomic rename into place, single link, mode 0600 (never executable), inside a
# 0700 directory. The owning home must already have registered the obligation, so
# a home that never opted into the relay can never be given public-followup
# artifacts by a child. --stage-in writes into the CALLER'S OWN home instead, so
# that gate does not apply and does not run: the registration and the relay
# consent both live on the other machine, and the collecting home re-validates
# every field against its own registration and tasks-axi before accepting the
# event. A staged event is never posted, never read as a public reply, and never
# consumed by the staging home's own reconciliation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-public-followup-emit.sh (--home <owning-home> | --stage-in <work-home>)
         --obligation <id> --relation <id>
         --source-home <main|secondmate:<id>> --work-id <id> --generation <n>
         --outcome <type> [--deliverable <key>=<value>]...
         [--require-deliverable <key>]...
         (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)
EOF
}

# The header comment IS the help text, so the two can never drift apart.
help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-public-followup-emit: %s\n' "$1" >&2; exit "${2:-2}"; }

# set_home_target <owning|staging> <path>: record which home this event is being
# written into, and which of the two destinations that means. The two modes
# answer different questions - is the owning home reachable from here, or not -
# so mixing them in one invocation is always a mistake and is refused rather
# than silently resolved by argument order.
set_home_target() {
  if [ -n "$HOME_MODE" ] && [ "$HOME_MODE" != "$1" ]; then
    die "--home and --stage-in are mutually exclusive; pass exactly one"
  fi
  HOME_MODE=$1
  HOME_DIR=$2
}

HOME_DIR=
HOME_MODE=
OBLIGATION=
RELATION=
SOURCE_HOME=
WORK_ID=
GENERATION=
OUTCOME=
TEXT_SOURCE=
TEXT_MODE=
DELIVERABLE_KEYS=()
DELIVERABLE_VALUES=()
REQUIRED_KEYS=()

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)            shift; set_home_target owning "${1:-}" ;;
    --stage-in)        shift; set_home_target staging "${1:-}" ;;
    --obligation)      shift; OBLIGATION=${1:-} ;;
    --relation)        shift; RELATION=${1:-} ;;
    --source-home)     shift; SOURCE_HOME=${1:-} ;;
    --work-id)         shift; WORK_ID=${1:-} ;;
    --generation)      shift; GENERATION=${1:-} ;;
    --outcome)         shift; OUTCOME=${1:-} ;;
    --outcome-text)    shift; TEXT_MODE='inline'; TEXT_SOURCE=${1:-} ;;
    --outcome-text-file) shift; TEXT_MODE='file'; TEXT_SOURCE=${1:-} ;;
    --deliverable)
      shift
      case "${1:-}" in
        *=*) ;;
        *) die "--deliverable needs <key>=<value>, got '${1:-}'" ;;
      esac
      i=0
      while [ "$i" -lt "${#DELIVERABLE_KEYS[@]}" ]; do
        [ "${DELIVERABLE_KEYS[$i]}" != "${1%%=*}" ] \
          || die "--deliverable key '${1%%=*}' is repeated; pass each deliverable once"
        i=$((i + 1))
      done
      DELIVERABLE_KEYS+=("${1%%=*}")
      DELIVERABLE_VALUES+=("${1#*=}")
      ;;
    --require-deliverable)
      shift
      fm_pf_deliverable_key_valid "${1:-}" \
        || die "--require-deliverable needs a lowercase letter then at most 63 more of [a-z0-9_], got '${1:-}'"
      REQUIRED_KEYS+=("$1")
      ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$HOME_DIR" ]    || { usage; exit 2; }
[ -n "$OBLIGATION" ]  || { usage; exit 2; }
[ -n "$RELATION" ]    || { usage; exit 2; }
[ -n "$SOURCE_HOME" ] || { usage; exit 2; }
[ -n "$WORK_ID" ]     || { usage; exit 2; }
[ -n "$GENERATION" ]  || { usage; exit 2; }
[ -n "$OUTCOME" ]     || { usage; exit 2; }
[ -n "$TEXT_MODE" ]   || { usage; exit 2; }

fm_pf_slug_valid "$OBLIGATION" || die "unsafe obligation id: $OBLIGATION"
fm_pf_slug_valid "$RELATION"   || die "unsafe relation id: $RELATION"
fm_pf_slug_valid "$WORK_ID"    || die "unsafe work id: $WORK_ID"
fm_pf_slug_valid "$OUTCOME"    || die "unsafe outcome type: $OUTCOME"
fm_pf_home_id_valid "$SOURCE_HOME" \
  || die "source home must be 'main' or 'secondmate:<stable-id>', got '$SOURCE_HOME'"
case "$GENERATION" in
  ''|*[!0-9]*) die "generation must be a positive integer, got '$GENERATION'" ;;
esac
[ "$GENERATION" -ge 1 ] || die "generation must be >= 1, got '$GENERATION'"

# tasks-axi accepts a superseded event only with a successor, and a typed
# terminal result carries none, so such an event could only ever be quarantined.
case "$OUTCOME" in
  superseded) die "a superseded outcome cannot be reported this way: tasks-axi requires a successor obligation for it, which a typed terminal result does not carry" ;;
esac

# Resolve the owning home to a real absolute directory before composing any path
# under it, so a relative or symlinked argument cannot make the destination
# ambiguous in a later message or write.
HOME_FLAG=--home
[ "$HOME_MODE" != staging ] || HOME_FLAG=--stage-in
case "$HOME_DIR" in
  /*) ;;
  *)
    HOME_RESOLVED=$(CDPATH='' cd -- "$HOME_DIR" 2>/dev/null && pwd -P) \
      || die "$HOME_FLAG is not a reachable directory: $HOME_DIR"
    HOME_DIR=$HOME_RESOLVED
    ;;
esac
[ -d "$HOME_DIR" ] && [ ! -L "$HOME_DIR" ] \
  || die "$HOME_FLAG must name an existing directory, got '$HOME_DIR'"
# A staged event is only ever found again by the collecting home reading this
# home's state tree, so a path that is not a firstmate home would swallow the
# result silently. Refuse it here instead.
if [ "$HOME_MODE" = staging ]; then
  case "$SOURCE_HOME" in
    secondmate:*) STAGING_HOME_ID=${SOURCE_HOME#secondmate:} ;;
    *) die "--stage-in must name the secondmate firstmate home identified by --source-home" ;;
  esac
  [ -d "$HOME_DIR/state" ] && [ ! -L "$HOME_DIR/state" ] \
    && [ -f "$HOME_DIR/.fm-secondmate-home" ] && [ ! -L "$HOME_DIR/.fm-secondmate-home" ] \
    || die "--stage-in must name the secondmate firstmate home identified by --source-home"
  STAGING_HOME_MARKER=$(sed -n '1p' "$HOME_DIR/.fm-secondmate-home" 2>/dev/null) || STAGING_HOME_MARKER=
  [ "$STAGING_HOME_MARKER" = "$STAGING_HOME_ID" ] \
    || die "--stage-in must name the secondmate firstmate home identified by --source-home"
fi

STATE="$HOME_DIR/state"
if [ "$HOME_MODE" = owning ]; then
  fm_pf_relay_active "$HOME_DIR" || exit 0
  command -v jq >/dev/null 2>&1 || die "jq is required to build a typed terminal event" 1

  command -v tasks-axi >/dev/null 2>&1 \
    || die "tasks-axi is required to read what this obligation promised" 1

  REGISTRY="$(fm_pf_registry_dir "$STATE")/$OBLIGATION"
  if [ ! -f "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
    die "home '$HOME_DIR' has no public-followup registration for '$OBLIGATION'; the owning home registers a commitment before its work can report one" 1
  fi

  # The registration is the owning home's own record of what it bound, so checking
  # the identity tuple against it catches a mis-briefed worker at the edge with a
  # clear message. tasks-axi still re-validates everything at consume time and
  # remains the authority; this is a cheap early refusal, not a second gatekeeper.
  reg_mismatch() {
    local field=$1 expected=$2 got=$3
    [ -z "$expected" ] || [ "$expected" = "$got" ] \
      || die "event $field '$got' does not match this home's registration ('$expected')"
  }
  reg_mismatch relation   "$(fm_pf_registry_get "$STATE" "$OBLIGATION" relation_id)" "$RELATION"
  reg_mismatch source-home "$(fm_pf_registry_get "$STATE" "$OBLIGATION" work_home)"  "$SOURCE_HOME"
  reg_mismatch work-id    "$(fm_pf_registry_get "$STATE" "$OBLIGATION" work_id)"     "$WORK_ID"
  reg_mismatch generation "$(fm_pf_registry_get "$STATE" "$OBLIGATION" generation)"  "$GENERATION"
else
  # Staging home: the registration and the relay consent live on the other
  # machine, so neither gate can run here and neither is skipped as a shortcut.
  # The collecting home applies both, plus tasks-axi, before it accepts anything.
  command -v jq >/dev/null 2>&1 || die "jq is required to build a typed terminal event" 1
fi

# tasks-axi's own obligation record is what this promise expects, so --home
# applies tasks-axi's rules against it exactly as `brief` reads it, for every
# registration this home holds. A staged emit is on the other side of a machine
# boundary from that record and is told the required keys by `brief` as
# --require-deliverable flags.
EXPECTED_FINAL=
if [ "$HOME_MODE" = owning ]; then
  OBLIGATION_JSON=$(fm_pf_obligation_json "$HOME_DIR" "$OBLIGATION") \
    || die "could not read public-followup obligation '$OBLIGATION' through tasks-axi" 1
  [ -n "$OBLIGATION_JSON" ] \
    || die "public-followup obligation '$OBLIGATION' is missing from tasks-axi" 1
  EXPECTED_FINAL=$(printf '%s' "$OBLIGATION_JSON" \
    | jq -r '.public_followup.expected_final.type // empty' 2>/dev/null)
  fm_pf_expected_outcome "$EXPECTED_FINAL" >/dev/null 2>&1 || EXPECTED_FINAL=
  for key in $(printf '%s' "$OBLIGATION_JSON" \
      | jq -r '(.public_followup.expected_final.required_deliverables // []) | .[] | tostring' 2>/dev/null); do
    fm_pf_deliverable_key_valid "$key" \
      || die "obligation '$OBLIGATION' names an unusable required deliverable key '$key'" 1
    REQUIRED_KEYS+=("$key")
  done
fi

# Only the outcome this promise expects can satisfy it; 'failed' is the one
# other answer it takes, reporting that it could not be kept as promised.
if [ -n "$EXPECTED_FINAL" ] && [ "$OUTCOME" != failed ]; then
  EXPECTED_OUTCOME=$(fm_pf_expected_outcome "$EXPECTED_FINAL") || EXPECTED_OUTCOME=
  [ -z "$EXPECTED_OUTCOME" ] || [ "$OUTCOME" = "$EXPECTED_OUTCOME" ] \
    || die "outcome '$OUTCOME' cannot satisfy this obligation: its $EXPECTED_FINAL final needs outcome '$EXPECTED_OUTCOME', and only 'failed' may answer it otherwise"
fi

# A key or a value tasks-axi would refuse is refused here, where the worker can
# still correct it, instead of travelling to the owning home to be quarantined.
i=0
while [ "$i" -lt "${#DELIVERABLE_KEYS[@]}" ]; do
  key=${DELIVERABLE_KEYS[$i]}
  fm_pf_deliverable_key_valid "$key" \
    || die "deliverable key must be a lowercase letter then at most 63 more of [a-z0-9_], got '$key'"
  problem=$(fm_pf_deliverable_problem "$EXPECTED_FINAL" "$OUTCOME" \
    "$key" "${DELIVERABLE_VALUES[$i]}") || die "$problem"
  i=$((i + 1))
done

# An event missing a key its obligation requires is as dead on arrival as one
# carrying a bad value, so it is refused in the same place. A failure report is
# exempt only from a key it could not carry anyway: a promise whose expected
# final IS the failure still needs its error_code.
CARRIED_KEYS=$(fm_pf_deliverable_keys "$EXPECTED_FINAL" "$OUTCOME") || CARRIED_KEYS=
i=0
while [ "$i" -lt "${#REQUIRED_KEYS[@]}" ]; do
  key=${REQUIRED_KEYS[$i]}
  i=$((i + 1))
  if [ "$OUTCOME" = failed ]; then
    case " $CARRIED_KEYS " in
      *" $key "*) ;;
      *) continue ;;
    esac
  fi
  j=0
  while [ "$j" -lt "${#DELIVERABLE_KEYS[@]}" ]; do
    [ "${DELIVERABLE_KEYS[$j]}" != "$key" ] || break
    j=$((j + 1))
  done
  [ "$j" -lt "${#DELIVERABLE_KEYS[@]}" ] || die "required deliverable '$key' is missing; expected $(fm_pf_deliverable_format "$key" || printf '%s' 'the value tasks-axi requires for it')"
done

case "$TEXT_MODE" in
  inline) OUTCOME_TEXT=$(printf '%s' "$TEXT_SOURCE" | fm_pf_clean_outcome_text) ;;
  file)
    if [ "$TEXT_SOURCE" = '-' ]; then
      OUTCOME_TEXT=$(fm_pf_clean_outcome_text)
    else
      [ -f "$TEXT_SOURCE" ] || die "outcome text file not found: $TEXT_SOURCE"
      OUTCOME_TEXT=$(fm_pf_clean_outcome_text < "$TEXT_SOURCE")
    fi
    ;;
esac
[ -n "$OUTCOME_TEXT" ] || die "outcome text is empty once whitespace and control characters are removed"

# Canonical deliverables object: sorted keys, compact, so the same deliverables
# always hash to the same identity regardless of flag order.
DELIVERABLES_JSON=$(
  {
    i=0
    while [ "$i" -lt "${#DELIVERABLE_KEYS[@]}" ]; do
      printf '%s\n%s\n' "${DELIVERABLE_KEYS[$i]}" "${DELIVERABLE_VALUES[$i]}"
      i=$((i + 1))
    done
  } | jq -Rsc 'split("\n") | .[:-1] | [range(0; length; 2) as $i | {key: .[$i], value: .[$i+1]}] | from_entries | to_entries | sort_by(.key) | from_entries'
) || die "could not encode deliverables" 1

EVENT_ID=$(fm_pf_event_id \
  "$OBLIGATION" "$RELATION" "$SOURCE_HOME" "$WORK_ID" "$GENERATION" "$OUTCOME" \
  "$DELIVERABLES_JSON") || die "sha256 (shasum or sha256sum) is required" 1
# The derived id becomes a filename, so require the exact digest shape rather
# than trusting whatever the hashing tool printed.
case "$EVENT_ID" in
  *[!0-9a-f]*|'') die "could not derive a usable event id" 1 ;;
esac
[ "${#EVENT_ID}" -eq 64 ] || die "could not derive a usable event id" 1

# jq bounds the outcome text by codepoint, so a long or non-ASCII sentence is
# capped without ever splitting a multi-byte character.
EVENT_JSON=$(jq -Sc -n \
  --argjson schema_version "$FM_PF_EVENT_SCHEMA_VERSION" \
  --arg event_id "$EVENT_ID" \
  --arg obligation_id "$OBLIGATION" \
  --arg relation_id "$RELATION" \
  --arg work_id "$WORK_ID" \
  --argjson generation "$GENERATION" \
  --arg source_home_id "$SOURCE_HOME" \
  --arg outcome_type "$OUTCOME" \
  --argjson deliverables "$DELIVERABLES_JSON" \
  --arg public_safe_outcome "$OUTCOME_TEXT" \
  --argjson outcome_max "$FM_PF_OUTCOME_TEXT_MAX" \
  --arg occurred_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:$schema_version, event_id:$event_id, obligation_id:$obligation_id,
    relation_id:$relation_id, work_id:$work_id, generation:$generation,
    source_home_id:$source_home_id, outcome_type:$outcome_type,
    deliverables:$deliverables,
    public_safe_outcome:($public_safe_outcome[0:$outcome_max]),
    occurred_at:$occurred_at, successor:null}') \
  || die "could not build the typed terminal event" 1

EVENT_BYTES=$(printf '%s\n' "$EVENT_JSON" | LC_ALL=C wc -c | tr -d ' ') \
  || die "could not measure the typed terminal event" 1
[ "$EVENT_BYTES" -le "$FM_PF_EVENT_BYTES_MAX" ] \
  || die "typed terminal event exceeds $FM_PF_EVENT_BYTES_MAX bytes" 2

if [ "$HOME_MODE" = owning ]; then
  DESTINATION=$(fm_pf_events_dir "$STATE")
else
  DESTINATION=$(fm_pf_outbox_dir "$STATE")
fi
printf '%s\n' "$EVENT_JSON" \
  | fmx_private_artifact_publish_stdin_once "$DESTINATION" "$EVENT_ID.json" 600
case $? in
  0|1) printf '%s\n' "$EVENT_ID" ;;
  *) die "could not publish the terminal event into $HOME_DIR" 1 ;;
esac
