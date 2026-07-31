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
#   fm-public-followup-emit.sh --home <owning-home> \
#     --obligation <obligation-id> --relation <relation-id> \
#     --source-home <main|secondmate:<id>> --work-id <task-id> \
#     --generation <n> --outcome <outcome-type> \
#     [--deliverable <key>=<value>]... \
#     (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)
#
# Options:
#   --home <path>          The home that owns the public commitment (the primary
#                          that took the mention). Must already have a
#                          registration for --obligation; see
#                          `fm-public-followup.sh register`.
#   --obligation <id>      tasks-axi public-followup obligation id.
#   --relation <id>        The relation_id this work fulfills or contributes to.
#   --source-home <id>     This worker's stable home identity, exactly as bound:
#                          "main" or "secondmate:<stable-id>".
#   --work-id <id>         This worker's exact task id, exactly as bound.
#   --generation <n>       The bound relation generation (integer >= 1).
#   --outcome <type>       Typed outcome. tasks-axi owns the vocabulary and
#                          refuses anything it does not accept; this script only
#                          checks the token is a safe slug.
#   --deliverable k=v      Repeatable safe deliverable (for example
#                          pr_url=https://...). tasks-axi owns which keys a given
#                          expected-final type permits.
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
# 0700 directory this script refuses to create. The owning home must already have
# registered the obligation, so a home that never opted into the relay can never
# be given public-followup artifacts by a child.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-public-followup-emit.sh --home <owning-home> --obligation <id> --relation <id>
         --source-home <main|secondmate:<id>> --work-id <id> --generation <n>
         --outcome <type> [--deliverable <key>=<value>]...
         (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)
EOF
}

# The header comment IS the help text, so the two can never drift apart.
help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-public-followup-emit: %s\n' "$1" >&2; exit "${2:-2}"; }

HOME_DIR=
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

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)            shift; HOME_DIR=${1:-} ;;
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
      DELIVERABLE_KEYS+=("${1%%=*}")
      DELIVERABLE_VALUES+=("${1#*=}")
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

i=0
while [ "$i" -lt "${#DELIVERABLE_KEYS[@]}" ]; do
  key=${DELIVERABLE_KEYS[$i]}
  case "$key" in
    ''|*[!a-z0-9_]*) die "deliverable key must be lowercase [a-z0-9_], got '$key'" ;;
  esac
  [ "${#DELIVERABLE_VALUES[$i]}" -le 512 ] \
    || die "deliverable '$key' exceeds 512 characters"
  case "${DELIVERABLE_VALUES[$i]}" in
    *[[:cntrl:]]*) die "deliverable '$key' must be single-line text with no control characters" ;;
  esac
  i=$((i + 1))
done

# Resolve the owning home to a real absolute directory before composing any path
# under it, so a relative or symlinked argument cannot make the destination
# ambiguous in a later message or write.
case "$HOME_DIR" in
  /*) ;;
  *) HOME_DIR=$(CDPATH='' cd -- "$HOME_DIR" 2>/dev/null && pwd -P) \
       || die "--home is not a reachable directory: $1" ;;
esac
[ -d "$HOME_DIR" ] && [ ! -L "$HOME_DIR" ] \
  || die "--home must name an existing directory, got '$HOME_DIR'"

fm_pf_relay_active "$HOME_DIR" || exit 0
command -v jq >/dev/null 2>&1 || die "jq is required to build a typed terminal event" 1

STATE="$HOME_DIR/state"
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

printf '%s\n' "$EVENT_JSON" \
  | fmx_private_artifact_publish_stdin_once "$(fm_pf_events_dir "$STATE")" "$EVENT_ID.json" 600
case $? in
  0|1) printf '%s\n' "$EVENT_ID" ;;
  *) die "could not publish the terminal event into $HOME_DIR" 1 ;;
esac
