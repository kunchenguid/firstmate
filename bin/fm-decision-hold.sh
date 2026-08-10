#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Every captain decision filed here carries its context as SEPARATE structured
# body fields rather than one free-text reason, so no dimension can be skipped
# inside a blob: an optional exact question, an optional set of two to four short
# answer labels, an optional `fact` intake kind carrying its expected-answer hint
# and optional JSON fact-field schema, an optional shared-group slug, a required
# "Why now", "What it affects", and
# "Recommendation", and a required
# conscious choice between a private decision-aid URL and an explicit "no built
# surface applies" acknowledgment. Each is required only when the item does not
# already record it, so a first filing can never omit one while an idempotent retry
# never has to retype what is already stored. Repeating --option supplies the
# complete ordered set: two to four distinct labels of at most 80 bytes each.
# --kind accepts only `fact`; --expects describes the expected answer shape and
# free-text fallback, is valid only for that kind, and is REQUIRED once that kind
# is set, because a fact request the captain cannot answer in the expected shape
# is not answerable.
# --fact-fields accepts an optional compact JSON array for that kind. The schema
# shape is owned by bin/fm-decision-readiness.jq; use roughly three to eight
# fields for one sub-question, and file separate grouped decisions rather than a
# repeating row editor. --group accepts one privacy-safe slug of at most 80
# bytes and marks decisions that share one origin without changing their separate
# identities. Supplying an optional field later replaces that
# stored field, while omitting its flag preserves it. This script
# judges only that each dimension was addressed. Whether the prose is genuinely
# clear and jargon-free is a semantic
# judgement no script can make; the skill owns it, and data/captain-shared.md's
# decision-presentation bar is what it is judged against.
# `link` is the supported backfill for an existing hold; it accepts HTTPS only,
# preserves the rest of the body, and never fetches or rewrites the URL. It also
# clears a recorded "no built surface" claim, because a decision that has gained a
# built surface must stop saying it has none.
#
# Those per-flag rules are the filing bar. On top of them, one STRUCTURAL
# readiness checklist decides whether a filed decision is answerable at all, and
# bin/fm-decision-readiness.jq owns it so this script, `doctor`, and the board
# apply exactly the same rule. A decision carrying structured context is ready
# when it records a question and a recommendation, makes exactly one surface
# choice, keeps any option set to two to four distinct short labels, and pairs a
# `fact` kind with an expected-answer hint. Both filing paths refuse an
# incomplete filing, reporting every gap at once. An optional fact-field schema
# must match the shared supported shape and accompany that fact kind. A hold
# carrying only a free-text reason predates structured context and is deliberately
# outside the checklist, so it is never reported as incomplete. The checklist judges presence
# and shape only; whether the question is clear or the recommendation sound stays
# the semantic judgement above.
#
# `doctor` is the read-only sweep of that checklist. With no argument it checks
# every open captain decision in the active home, meaning an item that is not
# done and carries an active captain hold; a parked decision stays out of scope
# because the captain set it aside. With a task id it checks that one item. It
# names the specific failed check and the flag that fixes it, and exits non-zero
# when anything is incomplete. Nobody has to remember to run it: the same
# checklist reaches bin/fm-fleet-snapshot.sh and surfaces on the board's fleet
# health section, which docs/mission-control.md owns.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>] \
#     [--question <exact-question>] [--option <short-label> --option <short-label> ...] \
#     [--kind fact [--expects <short-hint>] [--fact-fields <json-array>]] [--group <short-slug>] \
#     --why <why-now> --affects <what-it-affects> \
#     --recommendation <recommendation> \
#     (--decision-url <https-url> | --no-surface <why-none-applies>)
#   fm-decision-hold.sh hold-item <task-id> --reason <reason> \
#     [--question <exact-question>] [--option <short-label> --option <short-label> ...] \
#     [--kind fact [--expects <short-hint>] [--fact-fields <json-array>]] [--group <short-slug>] \
#     --why <why-now> --affects <what-it-affects> \
#     --recommendation <recommendation> \
#     (--decision-url <https-url> | --no-surface <why-none-applies>)
#   fm-decision-hold.sh link <origin-id> <decision-key> --url <https-url>
#   fm-decision-hold.sh doctor [<task-id>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh retract <origin-id> <decision-key> --superseded-by <decision-key>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh resolve-board <hold-id> --answer-file <path>
#
# `hold-item` applies that same bar to a backlog item that ALREADY EXISTS, whatever
# its own kind. It is the supported replacement for a bare
# `tasks-axi hold <id> --kind captain`, so a captain decision meets one bar
# whichever path filed it. It never creates the item and never changes its title,
# kind, or repo, and it never touches the decision_keys inventory that `complete`,
# `verify`, and scout teardown read: it records context and activates the captain
# hold, nothing else. It requires a QUEUED item, because a captain hold on an
# in-flight row leaves that row in flight, where it reads as work under way rather
# than as a decision waiting on the captain. Gate work already under way with
# `hold` under its own decision identity instead.
#
# Two captain-hold operations stay deliberately outside this bar because they
# restore text that already exists rather than file a decision: setting a decision
# aside under tasks-axi's "parked" hold kind, and bringing it back by restoring
# hold kind captain. bin/fm-mission-control.sh owns both, including the hazard that
# a different --reason silently rewrites the captain's own stored text.
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# A decision identity is looked up in the live backlog first and, only when it is
# absent there, in data/done-archive.md, where tasks-axi Done retention prunes older
# resolved records. That secondary lookup is read-only and never restores a record.
# It satisfies the gate only for an archived record that is marked done, is kind
# captain, and still carries the durable resolution record. An identity absent from
# both sources, an archived record that is not resolved, and a missing, unreadable,
# or malformed archive all keep today's refusal, and the refusal now names what it
# actually found rather than reporting every case as absence.
#
# `retract` is the supported way to take a decision key back out of the recorded
# inventory when a later review pass establishes that it duplicates a decision
# already inventoried under a different key. Removing the duplicate backlog item
# with `tasks-axi rm` alone leaves the key in the recorded union and absent from
# both durability sources, which makes `verify` and `complete` refuse forever and
# strands scout teardown. `--superseded-by` is required and names the surviving
# key, which must already be in this origin's inventory and must itself pass the
# same durability check. That anchor is what keeps the gate intact: the question
# stays gated, only its duplicate identity goes away, and the union can never be
# emptied by a retraction. A key that is no longer in the recorded inventory takes
# a no-op path that does not inspect or mutate the retracted identity. Otherwise
# the retracted identity is removed from the backlog when it is still there, so
# `tasks-axi rm`'s own refusal to delete an id that active work still blocks on
# continues to apply. A decision that already carries a recorded captain answer
# is never retractable, whether it is durably resolved or still queued because
# `resolve` was interrupted after writing that answer. Deleting it would lose both
# the answer and the retry identity. Retraction is idempotent, so an interrupted
# run is repaired by running the same command again.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# `resolve-board` is the board-answer entry point that firstmate calls after it
# has read a durably captured board request. It accepts only the parser's
# structured answer shape, validates fact keys against the filed decision schema,
# derives the hold's recorded origin, key, and dependent routes, then delegates
# to `resolve`. It never reads prose to recover facts and never changes the
# resolution ordering. A refusal leaves the captured board request available and
# does not change the decision state, so firstmate can report and retry it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARCHIVE="$DATA/done-archive.md"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

has_non_whitespace() {  # <value>
  case "$1" in
    *[![:space:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

# One structured context field as supplied on the command line. The byte cap is
# the same one the exact question already carried, so no dimension can smuggle an
# unbounded blob into a backlog row.
validate_context_field() {  # <label> <value>
  local label=$1 value=$2
  validate_one_line "$label" "$value"
  if ! has_non_whitespace "$value"; then
    case "$label" in
      question) fail "--question must state the concrete choice the captain needs to make" ;;
      why) fail "--why must state plainly why this decision is needed now" ;;
      affects) fail "--affects must state what this decision affects and what led to it" ;;
      recommendation) fail "--recommendation must state which way you would go and why" ;;
      no-surface) fail "--no-surface must state why no built surface applies" ;;
      *) fail "$label must contain non-whitespace text" ;;
    esac
  fi
  [ "$(printf '%s' "$value" | LC_ALL=C wc -c | tr -d ' ')" -le 2000 ] \
    || fail "$label exceeds 2000 bytes"
}

# Repeated --option values are one optional bounded set, not independent body
# fields. Two choices are the useful minimum, four is the board's readable
# maximum, and short unique labels keep every button honest about what it sends.
validate_decision_options() {  # [<short-label>...]
  local count=$# option seen=$'\n' trimmed
  [ "$count" -eq 0 ] || { [ "$count" -ge 2 ] && [ "$count" -le 4 ]; } \
    || fail "--option must be repeated 2 to 4 times when decision options are supplied"
  for option in "$@"; do
    validate_one_line option "$option"
    has_non_whitespace "$option" || fail "--option must contain non-whitespace text"
    trimmed=$(printf '%s' "$option" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$option" = "$trimmed" ] || fail "--option labels must not have leading or trailing whitespace"
    [ "$(printf '%s' "$option" | LC_ALL=C wc -c | tr -d ' ')" -le 80 ] \
      || fail "option exceeds 80 bytes"
    case "$seen" in
      *$'\n'"$option"$'\n'*) fail "--option labels must be distinct: $option" ;;
    esac
    seen=$seen$option$'\n'
  done
}

encode_decision_options() {  # <short-label>...
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  jq -cn --args '$ARGS.positional' -- "$@"
}

validate_decision_group() {  # <short-slug>
  validate_slug group "$1"
  [ "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" -le 80 ] \
    || fail "group exceeds 80 bytes"
}

encode_decision_fact_fields() {  # <json-array>
  printf '%s' "$1" | jq -R -s -c 'fromjson'
}

validate_decision_intake_flags() {  # <kind> <expects> <fact-fields-json>
  local kind=$1 expects=$2 fact_fields=$3 trimmed
  if [ -n "$kind" ] && [ "$kind" != fact ]; then
    fail "--kind supports only fact"
  fi
  if [ -n "$expects" ]; then
    validate_one_line expects "$expects"
    has_non_whitespace "$expects" || fail "--expects must describe the expected answer shape"
    trimmed=$(printf '%s' "$expects" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "$expects" = "$trimmed" ] || fail "--expects must not have leading or trailing whitespace"
    [ "$(printf '%s' "$expects" | LC_ALL=C wc -c | tr -d ' ')" -le 160 ] \
      || fail "expects exceeds 160 bytes"
  fi
  if [ -n "$fact_fields" ]; then
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    printf '%s' "$fact_fields" | jq -R -s -e -L "$SCRIPT_DIR" \
      'include "fm-decision-readiness"; decision_fact_fields_valid' >/dev/null 2>&1 \
      || fail "--fact-fields must be a supported JSON fact-field array"
  fi
}

# An expected-answer hint is meaningful only for an explicitly fact-shaped
# decision. The stored value counts so a later retry can add or replace only the
# hint without retyping --kind fact.
require_decision_intake_kind() {  # <body> <kind> <expects> <fact-fields-json>
  local body=$1 kind=$2 expects=$3 fact_fields=$4 stored_kind
  stored_kind=$(get_body_field "$body" "Decision kind")
  if [ -n "$expects" ] && [ "${kind:-$stored_kind}" != fact ]; then
    fail "--expects requires --kind fact or an existing fact decision"
  fi
  if [ -n "$fact_fields" ] && [ "${kind:-$stored_kind}" != fact ]; then
    fail "--fact-fields requires --kind fact or an existing fact decision"
  fi
}

validate_decision_url() {  # <url>
  local url=$1
  validate_one_line decision-url "$url"
  [ "$(printf '%s' "$url" | LC_ALL=C wc -c | tr -d ' ')" -le 2000 ] \
    || fail "decision-url exceeds 2000 bytes"
  case "$url" in
    https://*) ;;
    *) fail "decision-url must use https://" ;;
  esac
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  jq -n -L "$SCRIPT_DIR" -e --arg url "$url" \
    'include "fm-web-url"; $url | valid_web_url' >/dev/null 2>&1 \
    || fail "decision-url is malformed"
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

show_body() {  # <show-output>
  local raw
  raw=$(show_field "$1" body)
  if [ "$raw" = "-" ] || [ -z "$raw" ]; then
    return 0
  fi
  case "$raw" in
    \"*) printf '%s' "$raw" | jq -er 'if type == "string" then . else error("body is not text") end' ;;
    *) printf '%s' "$raw" ;;
  esac
}

set_body_field() {  # <body> <label> <value>
  local body=$1 label=$2 value=$3
  # An item that carries no body at all is the ordinary hold-item case. Appending
  # to the empty string would leave a blank first line in the backlog row.
  if [ -z "$body" ]; then
    printf '%s: %s\n' "$label" "$value"
    return 0
  fi
  printf '%s\n' "$body" | FM_BODY_FIELD_VALUE=$value awk -v label="$label: " '
    BEGIN { found = 0 }
    index($0, label) == 1 {
      if (!found) print label ENVIRON["FM_BODY_FIELD_VALUE"]
      found = 1
      next
    }
    { print }
    END { if (!found) print label ENVIRON["FM_BODY_FIELD_VALUE"] }
  '
}

get_body_field() {  # <body> <label>
  printf '%s\n' "$1" | awk -v label="$2: " '
    index($0, label) == 1 { print substr($0, length(label) + 1); exit }
  '
}

clear_body_field() {  # <body> <label>
  printf '%s\n' "$1" | awk -v label="$2: " '
    index($0, label) == 1 { next }
    { print }
  '
}

# The legacy context bar owns Why now and What it affects, which are outside the
# structural readiness checklist. A dimension counts as addressed when it is
# supplied now or already recorded on the item.
require_decision_context() {  # <id> <body> <why> <affects>
  local id=$1 body=$2 why=$3 affects=$4
  local stored_why stored_affects
  stored_why=$(get_body_field "$body" "Why now")
  stored_affects=$(get_body_field "$body" "What it affects")
  has_non_whitespace "$why" || has_non_whitespace "$stored_why" \
    || fail "captain decision $id needs --why: state plainly why this decision is needed now"
  has_non_whitespace "$affects" || has_non_whitespace "$stored_affects" \
    || fail "captain decision $id needs --affects: state what it affects and what led to it"
}

# The structural readiness checklist is owned once by bin/fm-decision-readiness.jq
# so this script, the read-only sweep, and the board apply the same rule. Prints
# one "detail<TAB>flag" line per gap, and nothing for a ready decision or for an
# older free-text hold the checklist deliberately leaves alone.
# Prints the decision's shape on the first line, then one indented actionable
# line per gap. Both the filing refusal and the sweep read this one rendering, so
# a gap is worded the same wherever it is reported.
decision_readiness_report() {  # <body>
  printf '%s' "$1" | jq -R -s -L "$SCRIPT_DIR" -r '
    include "fm-decision-readiness";
    split("\n") | decision_readiness
    | (if .structured then "structured" else "free-text" end),
      (.gaps[] | "  - \(.detail) (\(.flag))")'
}

decision_readiness_gaps() {  # <report>
  printf '%s\n' "$1" | tail -n +2
}

# A filing that is already knowably incomplete is refused at the point of filing
# rather than left for the sweep to find, so an unanswerable decision never
# reaches the captain's board at all. Every gap is reported at once, because a
# filer fixing them one refusal at a time learns the bar one dimension at a time.
require_decision_readiness() {  # <id> <body>
  local report gaps
  report=$(decision_readiness_report "$2") \
    || fail "could not check captain decision $1 against the readiness checklist"
  gaps=$(decision_readiness_gaps "$report")
  [ -n "$gaps" ] || return 0
  fail "captain decision $1 is not ready for the captain:
$gaps"
}

# Shape validation for the context flags both filing paths accept. Kept separate
# from the presence bar above so a malformed value is refused on its own terms
# rather than being reported as a missing dimension.
validate_decision_context_flags() {  # <question> <why> <affects> <recommendation> <decision-url> <no-surface>
  [ -z "$1" ] || validate_context_field question "$1"
  [ -z "$2" ] || validate_context_field why "$2"
  [ -z "$3" ] || validate_context_field affects "$3"
  [ -z "$4" ] || validate_context_field recommendation "$4"
  [ -z "$5" ] || validate_decision_url "$5"
  [ -z "$6" ] || validate_context_field no-surface "$6"
}

# Prints the body with every supplied dimension merged in.
write_decision_context() {  # <body> <question> <options-json> <decision-kind> <expects> <fact-fields-json> <group> <why> <affects> <recommendation> <decision-url> <no-surface>
  local body=$1 question=$2 options_json=$3 decision_kind=$4 expects=$5 fact_fields=$6 group=$7
  local why=$8 affects=$9 recommendation=${10} decision_url=${11} no_surface=${12}
  [ -z "$question" ] || body=$(set_body_field "$body" "Decision question" "$question")
  [ -z "$options_json" ] || body=$(set_body_field "$body" "Decision options" "$options_json")
  [ -z "$decision_kind" ] || body=$(set_body_field "$body" "Decision kind" "$decision_kind")
  [ -z "$expects" ] || body=$(set_body_field "$body" "Decision expects" "$expects")
  [ -z "$fact_fields" ] || body=$(set_body_field "$body" "Decision fact fields" "$fact_fields")
  [ -z "$group" ] || body=$(set_body_field "$body" "Decision group" "$group")
  [ -z "$why" ] || body=$(set_body_field "$body" "Why now" "$why")
  [ -z "$affects" ] || body=$(set_body_field "$body" "What it affects" "$affects")
  [ -z "$recommendation" ] || body=$(set_body_field "$body" "Recommendation" "$recommendation")
  if [ -n "$decision_url" ] && [ -n "$no_surface" ]; then
    body=$(set_body_field "$body" "Decision URL" "$decision_url")
    body=$(set_body_field "$body" "No decision surface" "$no_surface")
  elif [ -n "$decision_url" ]; then
    body=$(set_body_field "$body" "Decision URL" "$decision_url")
    body=$(clear_body_field "$body" "No decision surface")
  elif [ -n "$no_surface" ]; then
    body=$(set_body_field "$body" "No decision surface" "$no_surface")
    body=$(clear_body_field "$body" "Decision URL")
  fi
  printf '%s' "$body"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

# tasks-axi Done retention prunes older resolved records out of the live backlog
# into the archive, so a genuinely resolved captain decision stops being visible to
# `tasks-axi show`. These two helpers are the read-only secondary lookup for that
# case. They never write to the archive and never restore a record from it.
archive_record() {  # <hold-id> - prints the most recent archived record and its body
  [ -f "$ARCHIVE" ] && [ -r "$ARCHIVE" ] || return 1
  awk -v id="$1" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] /, "", rest)
      space = index(rest, " ")
      entry = (space > 0 ? substr(rest, 1, space - 1) : rest)
      if (entry == id) { keep = 1; body = $0 "\n" } else { keep = 0 }
      next
    }
    /^## / { keep = 0; next }
    /^- / { keep = 0; next }
    keep { body = body $0 "\n" }
    END { printf "%s", body }
  ' "$ARCHIVE" 2>/dev/null || return 1
}

# Prints `resolved` only for an archived record that is genuinely a closed captain
# decision: marked done, kind captain, and still carrying the durable resolution
# record that `resolve` writes before it closes a hold. Every other outcome - a
# record that was never filed, a record that is not done, an identity that is not a
# captain decision, a missing or unreadable archive, and malformed content - prints
# something else, so the caller keeps refusing exactly as it does today.
# `unreadable` is reported separately because an archive that cannot be read is the
# one case where absence from the live backlog does not prove the decision was never
# filed, and the refusal must not claim more than it checked.
archive_hold_status() {  # <hold-id> - prints resolved | unresolved | unreadable | absent
  local record='' entry_line
  if [ -e "$ARCHIVE" ] && [ ! -r "$ARCHIVE" ]; then
    printf 'unreadable\n'
    return 0
  fi
  record=$(archive_record "$1") || true
  if [ -z "$record" ]; then
    printf 'absent\n'
    return 0
  fi
  entry_line=${record%%$'\n'*}
  case "$entry_line" in
    '- [x] '*) : ;;
    *) printf 'unresolved\n'; return 0 ;;
  esac
  case "$entry_line" in
    *'(kind: captain)'*) : ;;
    *) printf 'unresolved\n'; return 0 ;;
  esac
  case "$record" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) printf 'resolved\n' ;;
    *) printf 'unresolved\n' ;;
  esac
}

archive_record_field() {  # <record> <label>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2: //p" | head -1
}

# The item kind is required by default because a decision identity this script
# created is always kind captain. `hold-item` passes an empty second argument
# because it gates an item that already exists under its own kind, where the HOLD
# kind, never the item kind, is what marks it as a captain decision.
verify_hold_active() {  # <hold-id> [required-item-kind, "" for any]
  local id=$1 require_kind=${2-captain} show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ -z "$require_kind" ] || [ "$kind" = "$require_kind" ] \
    || fail "backlog item $id is not kind $require_kind"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body archived
  if ! show=$(task_show "$id"); then
    archived=$(archive_hold_status "$id")
    [ "$archived" != resolved ] || return 0
    [ "$archived" != unresolved ] \
      || fail "captain decision $id is archived in $ARCHIVE without a durable resolution record"
    [ "$archived" != unreadable ] \
      || fail "captain decision $id is absent from $DATA/backlog.md and $ARCHIVE could not be read"
    fail "captain decision $id was never filed: it is absent from both $DATA/backlog.md and $ARCHIVE"
  fi
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' question='' decision_url='' no_surface=''
  local why='' affects='' recommendation='' options_json='' decision_kind='' expects='' fact_fields='' group=''
  local options=()
  local id show state kind existing_title body updated exists=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --question) shift; question=${1:-} ;;
      --option) shift; options+=("${1:-}") ;;
      --kind) shift; decision_kind=${1:-} ;;
      --expects) shift; expects=${1:-} ;;
      --fact-fields) shift; fact_fields=${1:-} ;;
      --group) shift; group=${1:-} ;;
      --why) shift; why=${1:-} ;;
      --affects) shift; affects=${1:-} ;;
      --recommendation) shift; recommendation=${1:-} ;;
      --no-surface) shift; no_surface=${1:-} ;;
      --decision-url) shift; decision_url=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  validate_decision_context_flags "$question" "$why" "$affects" "$recommendation" "$decision_url" "$no_surface"
  validate_decision_intake_flags "$decision_kind" "$expects" "$fact_fields"
  [ -z "$fact_fields" ] || fact_fields=$(encode_decision_fact_fields "$fact_fields") \
    || fail "could not normalize --fact-fields"
  [ -z "$group" ] || validate_decision_group "$group"
  if [ "${#options[@]}" -gt 0 ]; then
    validate_decision_options "${options[@]}"
    options_json=$(encode_decision_options "${options[@]}")
  fi
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    exists=1
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    body=$(show_body "$show") || fail "could not read captain hold $id body"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
  fi
  # Refuse before anything is created or held, so an incomplete filing leaves no
  # half-made backlog identity behind for the next attempt to trip over.
  require_decision_context "$id" "$body" "$why" "$affects"
  require_decision_intake_kind "$body" "$decision_kind" "$expects" "$fact_fields"
  updated=$(write_decision_context "$body" "$question" "$options_json" \
    "$decision_kind" "$expects" "$fact_fields" "$group" "$why" "$affects" "$recommendation" "$decision_url" "$no_surface")
  require_decision_readiness "$id" "$updated"
  if [ "$exists" = 1 ]; then
    if [ "$updated" != "$body" ]; then
      tasks_axi update "$id" --body "$updated" >/dev/null \
        || fail "could not record decision context on $id"
    fi
  else
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$updated" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

# The same due-diligence bar on a backlog item that already exists, under whatever
# kind it already has. This is what keeps a captain-gated thread filed by hand from
# being the one decision that skipped the bar.
command_hold_item() {
  local id=${1:-} reason='' question='' decision_url='' no_surface='' show state body updated
  local why='' affects='' recommendation='' options_json='' decision_kind='' expects='' fact_fields='' group=''
  local options=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      --question) shift; question=${1:-} ;;
      --option) shift; options+=("${1:-}") ;;
      --kind) shift; decision_kind=${1:-} ;;
      --expects) shift; expects=${1:-} ;;
      --fact-fields) shift; fact_fields=${1:-} ;;
      --group) shift; group=${1:-} ;;
      --why) shift; why=${1:-} ;;
      --affects) shift; affects=${1:-} ;;
      --recommendation) shift; recommendation=${1:-} ;;
      --no-surface) shift; no_surface=${1:-} ;;
      --decision-url) shift; decision_url=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  validate_one_line reason "$reason"
  validate_decision_context_flags "$question" "$why" "$affects" "$recommendation" "$decision_url" "$no_surface"
  validate_decision_intake_flags "$decision_kind" "$expects" "$fact_fields"
  [ -z "$fact_fields" ] || fact_fields=$(encode_decision_fact_fields "$fact_fields") \
    || fail "could not normalize --fact-fields"
  [ -z "$group" ] || validate_decision_group "$group"
  if [ "${#options[@]}" -gt 0 ]; then
    validate_decision_options "${options[@]}"
    options_json=$(encode_decision_options "${options[@]}")
  fi
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  show=$(task_show "$id") \
    || fail "backlog item $id does not exist in the active home $FM_HOME; hold-item gates an existing item and never creates one"
  state=$(show_field "$show" state)
  [ "$state" = queued ] \
    || fail "backlog item $id is $state, and a captain hold leaves it there; only a queued captain hold is classified as an actionable decision, so gate work already under way with the hold subcommand under its own decision identity"
  body=$(show_body "$show") || fail "could not read backlog item $id body"
  require_decision_context "$id" "$body" "$why" "$affects"
  require_decision_intake_kind "$body" "$decision_kind" "$expects" "$fact_fields"
  updated=$(write_decision_context "$body" "$question" "$options_json" \
    "$decision_kind" "$expects" "$fact_fields" "$group" "$why" "$affects" "$recommendation" "$decision_url" "$no_surface")
  require_decision_readiness "$id" "$updated"
  if [ "$updated" != "$body" ]; then
    tasks_axi update "$id" --body "$updated" >/dev/null \
      || fail "could not record decision context on $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate the captain hold on $id"
  verify_hold_active "$id" ''
  printf '%s\n' "$id"
}

command_link() {
  local origin=${1:-} key=${2:-} url='' id show body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) shift; url=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_decision_url "$url"
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  verify_hold_active "$id"
  show=$(task_show "$id") || fail "captain hold $id disappeared before its link was recorded"
  body=$(show_body "$show") || fail "could not read captain hold $id body"
  body=$(set_body_field "$body" "Decision URL" "$url")
  # A decision that has since gained a built surface must stop claiming it has
  # none, or the board would show the captain a link and a "no built surface"
  # note side by side.
  body=$(clear_body_field "$body" "No decision surface")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the decision URL on $id"
  printf 'linked: %s -> %s\n' "$id" "$url"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_retract() {
  local origin=${1:-} key=${2:-} surviving='' meta reviewed previous keys id surviving_id show kind body archived raw_open open_key
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --superseded-by) shift; surviving=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$surviving" ] || fail "--superseded-by is required: retraction must name the surviving decision key"
  validate_slug superseded-by "$surviving"
  [ "$surviving" != "$key" ] || fail "decision key $key cannot supersede itself"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  previous=$(meta_value "$meta" decision_keys)
  id=$(hold_id "$origin" "$key")
  surviving_id=$(hold_id "$origin" "$surviving")

  # The surviving key is the whole safety anchor: the retracted question must stay
  # gated under an identity this origin already inventoried and that is still
  # actively held or durably resolved. Check it before anything is removed.
  list_has_key "$previous" "$surviving" \
    || fail "superseding decision key $surviving is outside the reviewed inventory for $origin"
  verify_hold_durable "$surviving_id"
  if ! list_has_key "$previous" "$key"; then
    printf 'retracted: %s was already outside the reviewed inventory for %s\n' "$id" "$origin"
    return 0
  fi

  if show=$(task_show "$id"); then
    kind=$(show_field "$show" kind)
    [ "$kind" = captain ] || fail "backlog identity $id is not kind captain"
    body=$(show_field "$show" body)
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*)
        fail "captain decision $id has a recorded captain decision that must not be deleted"
        ;;
    esac
    ! verify_hold_resolved "$id" \
      || fail "captain decision $id is durably resolved and does not need retraction"
    tasks_axi rm "$id" >/dev/null || fail "could not remove duplicate captain hold $id"
  else
    archived=$(archive_hold_status "$id")
    [ "$archived" != resolved ] \
      || fail "captain decision $id is durably resolved in $ARCHIVE and does not need retraction"
  fi

  # Close the live status copy for the retracted key the same way `complete`
  # transfers one to its durable owner. The raw fold is deliberate: a terminal
  # origin suppresses origin_open_decisions, and the line must still be written.
  raw_open=$(status_open_decisions "$STATE/$origin.status")
  while IFS=$'\t' read -r open_key _verb _summary; do
    [ -n "$open_key" ] || continue
    [ "$open_key" = "$key" ] || continue
    printf 'captain-held [key=%s]: superseded by %s\n' "$key" "$surviving_id" >> "$STATE/$origin.status"
  done <<EOF
$raw_open
EOF

  keys=$(printf '%s\n' "$previous" | tr ',' '\n' | sed '/^$/d' | grep -vxF "$key" \
    | LC_ALL=C sort -u | paste -sd, -)
  [ -n "$keys" ] || fail "retracting $key would empty the inventory for $origin"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
  printf 'retracted: %s superseded by %s\n' "$id" "$surviving_id"
}

board_answer_valid_for_hold() {  # <answer-file> <decision-kind> <fact-fields>
  local answer_file=$1 fact_kind=$2 fact_fields=$3
  [ -f "$answer_file" ] && [ ! -L "$answer_file" ] \
    || fail "board answer file does not exist or is unsafe: $answer_file"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  jq -e '
    type == "object"
    and .v == "1"
    and .intent == "answer"
    and ([keys[] | select(. != "v" and . != "intent" and . != "note" and . != "facts" and . != "required_keys")] | length == 0)
    and (if has("note") then (.note | type == "string") else true end)
    and (if has("facts") then
      (.facts | type == "object" and all(to_entries[]; (.key | test("^[A-Za-z][A-Za-z0-9_-]{0,63}$")) and (.value | type == "string")))
      and (.required_keys | type == "array")
      else (has("required_keys") | not)
      end)
  ' "$answer_file" >/dev/null 2>&1 \
    || fail "board answer is not the validated structured answer shape"
  if [ "$fact_kind" = fact ] && [ -n "$fact_fields" ]; then
    printf '%s' "$fact_fields" | jq -R -s -e -L "$SCRIPT_DIR" \
      'include "fm-decision-readiness"; decision_fact_fields_valid' >/dev/null 2>&1 \
      || fail "captain hold has an invalid fact-field schema"
    jq -e --argjson fields "$fact_fields" '
      . as $answer
      | ($answer.facts | type == "object")
      and ([$answer.facts | keys[]] - [$fields[].key] | length == 0)
      and ([$fields[] | select(.required == true) | .key] as $required
           | all($required[]; ($answer.facts[.] // "") | test("\\S")))
    ' "$answer_file" >/dev/null 2>&1 \
      || fail "board answer does not satisfy the filed required fact fields"
  elif [ "$fact_kind" = fact ]; then
    jq -e 'has("facts") | not' "$answer_file" >/dev/null 2>&1 \
      || fail "legacy fact decision cannot accept unfiled structured fact keys"
  else
    jq -e 'has("facts") | not' "$answer_file" >/dev/null 2>&1 \
      || fail "choice decision cannot accept structured fact keys"
  fi
}

board_answer_routes() {  # <hold-id> <hold-body>
  local id=$1 body=$2 recorded routes='' candidate show blocked
  recorded=$(get_body_field "$body" "Routed identities")
  if [ -n "$recorded" ]; then
    printf '%s' "$recorded" | tr ',' '\n' | while IFS= read -r candidate || [ -n "$candidate" ]; do
      validate_slug routed-task "$candidate"
      printf '%s\n' "$candidate"
    done
    return 0
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    validate_slug routed-task "$candidate"
    show=$(task_show "$candidate") || continue
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) routes="${routes}${routes:+ }$candidate" ;;
    esac
  done < <(tasks_axi list --blocked --limit 1000000 2>/dev/null \
    | awk -F, '/^  / {id=$1; sub(/^[[:space:]]+/, "", id); sub(/[[:space:]]+$/, "", id); if (id ~ /^[A-Za-z0-9._-]+$/) print id}')
  [ -n "$routes" ] || fail "captain hold $id has no blocked dependent work to route"
  printf '%s\n' "$routes" | tr ' ' '\n' | LC_ALL=C sort -u
}

command_resolve_board() {
  local id=${1:-} answer_file='' show body archived_record origin key expected_id routes route decision_file fact_kind fact_fields
  local -a route_args=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer-file) shift; answer_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug hold-id "$id"
  [ -n "$answer_file" ] || fail "--answer-file is required"
  require_tasks_axi
  if show=$(task_show "$id"); then
    body=$(show_body "$show") || fail "could not read captain hold $id body"
    origin=$(get_body_field "$body" "Origin")
    key=$(get_body_field "$body" "Decision key")
    fact_kind=$(get_body_field "$body" "Decision kind")
    fact_fields=$(get_body_field "$body" "Decision fact fields")
    routes=$(board_answer_routes "$id" "$body")
  else
    [ "$(archive_hold_status "$id")" = resolved ] \
      || fail "captain hold $id disappeared before its board answer was applied"
    archived_record=$(archive_record "$id") \
      || fail "could not read archived captain hold $id"
    origin=$(archive_record_field "$archived_record" "Origin")
    key=$(archive_record_field "$archived_record" "Decision key")
    fact_kind=$(archive_record_field "$archived_record" "Decision kind")
    fact_fields=$(archive_record_field "$archived_record" "Decision fact fields")
    routes=$(archive_record_field "$archived_record" "Routed identities" | tr ',' '\n')
  fi
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  expected_id=$(hold_id "$origin" "$key")
  [ "$id" = "$expected_id" ] \
    || fail "board answer target $id does not match its recorded decision identity"
  board_answer_valid_for_hold "$answer_file" "$fact_kind" "$fact_fields"
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    route_args+=(--routed-to "$route")
  done <<EOF
$routes
EOF
  [ "${#route_args[@]}" -gt 0 ] || fail "captain hold $id has no routes for its board answer"
  decision_file=$(mktemp "${TMPDIR:-/tmp}/fm-board-answer.XXXXXX") \
    || fail "could not stage board answer for resolution"
  if ! jq -cS . "$answer_file" > "$decision_file"; then
    rm -f -- "$decision_file"
    fail "could not stage board answer for resolution"
  fi
  if ! command_resolve "$origin" "$key" --decision-file "$decision_file" "${route_args[@]}"; then
    rm -f -- "$decision_file"
    fail "could not apply board answer to captain hold $id"
  fi
  rm -f -- "$decision_file"
  printf 'resolved-board: %s\n' "$id"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body hold_schema_body archived_record resolution_recorded=0 decision_kind fact_fields
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  # Done retention can prune an already resolved hold out of the live backlog
  # between the original resolve and an exact retry. Confirm the archived record
  # carries this same decision and routed work before reporting it resolved.
  if [ "$(archive_hold_status "$id")" = resolved ]; then
    archived_record=$(archive_record "$id")
    [ "$(archive_record_field "$archived_record" 'Decision digest')" = "$decision_digest" ] \
      || fail "archived captain decision $id records a different captain decision"
    [ "$(archive_record_field "$archived_record" 'Routed identities')" = "$routed_csv" ] \
      || fail "archived captain decision $id records different routed work"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  hold_schema_body=$(show_body "$hold_show") || fail "could not read captain hold $id body"
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  # Preserve the established hold identity beside the durable resolution record
  # so a replayed external answer can re-enter this same idempotent resolve path.
  body="${body}Origin: ${origin}"$'\n'"Decision key: ${key}"
  decision_kind=$(get_body_field "$hold_schema_body" "Decision kind")
  fact_fields=$(get_body_field "$hold_schema_body" "Decision fact fields")
  [ -z "$decision_kind" ] || body="${body}"$'\n'"Decision kind: ${decision_kind}"
  [ -z "$fact_fields" ] || body="${body}"$'\n'"Decision fact fields: ${fact_fields}"
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

# The swept population, defined once here so the sweep and the board can never
# disagree about which decisions are in scope: an item that is not done and
# carries an ACTIVE captain hold. A parked decision is deliberately out of scope,
# because the captain set it aside and re-surfacing it would undo that choice.
open_captain_decision_ids() {
  tasks_axi list --state held --fields hold_kind 2>/dev/null | awk '
    /^tasks\[/ { in_tasks = 1; next }
    /^[^ ]/ { in_tasks = 0 }
    in_tasks && /^  / {
      split(substr($0, 3), field, ",")
      if (field[1] != "") print field[1]
    }
  '
}

decisions_phrase() {  # <count>
  if [ "$1" -eq 1 ]; then
    printf '1 structured captain decision'
  else
    printf '%d structured captain decisions' "$1"
  fi
}

is_open_captain_decision() {  # <show-output>
  [ "$(show_field "$1" held)" = yes ] || return 1
  [ "$(show_field "$1" hold_kind)" = captain ] || return 1
  [ "$(show_field "$1" state)" != "done" ] || return 1
}

# Read-only. Reports which specific check a decision fails rather than a bare
# verdict, so the reader can act on the output directly. Exits non-zero when any
# checked decision is incomplete, which is what makes it usable as a gate.
command_doctor() {  # [<task-id>]
  local named=${1:-} ids id show body report gaps checked=0 incomplete=0
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  require_tasks_axi
  if [ -n "$named" ]; then
    validate_slug task-id "$named"
    task_show "$named" >/dev/null \
      || fail "backlog item $named does not exist in the active home $FM_HOME"
    ids=$named
  else
    ids=$(open_captain_decision_ids)
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(task_show "$id") || continue
    # A named item is checked as asked; a swept one must be an open captain
    # decision, because the sweep speaks for the board and nothing else.
    if [ -z "$named" ]; then
      is_open_captain_decision "$show" || continue
    fi
    body=$(show_body "$show") || fail "could not read backlog item $id body"
    report=$(decision_readiness_report "$body") \
      || fail "could not check captain decision $id against the readiness checklist"
    if [ "$(printf '%s\n' "$report" | head -1)" = free-text ]; then
      [ -z "$named" ] || printf '%s: filed as free text, which this checklist does not cover\n' "$id"
      continue
    fi
    checked=$((checked + 1))
    gaps=$(decision_readiness_gaps "$report")
    [ -n "$gaps" ] || continue
    incomplete=$((incomplete + 1))
    printf '%s: not ready for the captain\n%s\n' "$id" "$gaps"
  done <<EOF
$ids
EOF
  if [ "$incomplete" -gt 0 ]; then
    printf '%d of %s not ready for the captain\n' \
      "$incomplete" "$(decisions_phrase "$checked")"
    exit 1
  fi
  if [ "$checked" -eq 0 ]; then
    printf 'no structured captain decisions to check\n'
    return 0
  fi
  printf 'checked %s; all ready for the captain\n' "$(decisions_phrase "$checked")"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  doctor) shift; command_doctor "$@" ;;
  hold) shift; command_hold "$@" ;;
  hold-item) shift; command_hold_item "$@" ;;
  link) shift; command_link "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  retract) shift; command_retract "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  resolve-board) shift; command_resolve_board "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
