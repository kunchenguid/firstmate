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
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh open [--origin <origin-id>] [--aging-only]
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>] [--distinct]
#   fm-decision-hold.sh fold <origin-id> --into <hold-id> --note <note>
#   fm-decision-hold.sh complete <origin-id> (--none | --folded | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     (--decision <text> | --decision-file <path>) [--decided-by captain|firstmate] \
#     (--routed-to <task-id>... | --no-routed-work)
#
# `open` lists every open captain decision in the active home with the date it was
# registered and how many days it has been waiting. `--aging-only` keeps just the
# decisions at or past FM_DECISION_AGING_DAYS (default 3). It is read-only.
#
# `hold` refuses to create a NEW backlog identity while the active home already
# holds other open captain decisions, printing that open set and exiting 3. The
# refusal exists because a second key covering an already-open question is the
# common way this queue compounds, and the open set must be in front of the agent
# before it registers another. Clear it either by folding the finding into the
# decision it duplicates or, when the question is genuinely different, by passing
# `--distinct`, which records the attestation in the new hold's body. Repeating
# `hold` on an existing identity stays idempotent and is never gated, so retry and
# recovery paths are unaffected.
#
# `fold` is the first-class alternative to a second decision: it appends this
# pass's finding to an existing open hold's body and records the fold in the new
# origin's metadata, so the origin still satisfies the completion gate without
# creating a duplicate captain decision.
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision, and is refused when the origin recorded folds.
# `--folded` attests that every unresolved decision found is already owned by a
# hold this origin folded into. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` records the captain's answer and closes the hold. The answer arrives as
# `--decision <text>` or `--decision-file <path>`. Dependent work is routed with
# `--routed-to`, which requires every named task to exist and to be blocked by the
# hold. `--no-routed-work` covers the answer that spawns no dependent task; it is
# refused when any backlog task is actually blocked by the hold, so the routing
# requirement survives wherever dependent work genuinely exists. `--decided-by`
# records who settled it: `captain` by default, or `firstmate` when the question
# turned out to be firstmate's own call. Either way the decision text, its digest,
# and the prior registration record are written into the hold body before it is
# marked Done. A failure before the final step leaves the captain hold open.
#
# The completion and teardown gates accept a decision as durably resolved when it
# is closed and carries a decision record, whatever wrote that record, and when
# Done retention has rotated it into data/done-archive.md. A decision closed with
# no record at all is still refused, because that is the loss the gate exists to
# prevent; the gate checks that an answer survives, not that this script formatted
# it.
#
# Environment: FM_DECISION_AGING_DAYS (default 3) sets the ageing threshold and
# FM_DECISION_NOW (YYYY-MM-DD) pins today's date for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

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

require_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required to read and rewrite a decision body"
}

aging_days() {
  local days=${FM_DECISION_AGING_DAYS:-3}
  case "$days" in ''|*[!0-9]*) days=3 ;; esac
  printf '%s\n' "$days"
}

today_utc() {
  printf '%s\n' "${FM_DECISION_NOW:-$(date -u +%Y-%m-%d)}"
}

date_epoch() {  # <YYYY-MM-DD>
  date -u -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || true
}

waiting_days() {  # <since-date>
  local since=$1 now_epoch since_epoch days
  now_epoch=$(date_epoch "$(today_utc)")
  since_epoch=$(date_epoch "$since")
  case "$now_epoch" in ''|*[!0-9]*) return 0 ;; esac
  case "$since_epoch" in ''|*[!0-9]*) return 0 ;; esac
  days=$(( (now_epoch - since_epoch) / 86400 ))
  [ "$days" -ge 0 ] || days=0
  printf '%s\n' "$days"
}

# tasks-axi renders rows as CSV that quotes any field containing a comma, so the
# columns are parsed with quote awareness rather than a naive split.
# shellcheck disable=SC2016  # awk source: $0 is awk's record, not a shell expansion.
TASKS_AXI_CSV_AWK='
  function parse_csv(s, out,   i, n, c, field, inq) {
    n = 0; field = ""; inq = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (inq) {
        if (c == "\"") {
          if (substr(s, i + 1, 1) == "\"") { field = field "\""; i++ } else { inq = 0 }
        } else { field = field c }
      } else if (c == "\"") { inq = 1 }
      else if (c == ",") { out[++n] = field; field = "" }
      else { field = field c }
    }
    out[++n] = field
    return n
  }
  function clean(s) { gsub(/\t/, " ", s); return s }
  /^tasks\[/ { rows = 1; next }
  rows && !/^  / { rows = 0 }
  rows && /^  / { line = $0; sub(/^  /, "", line); emit(line) }
'

# Every open captain decision in the active home as
# "<id>\t<since>\t<title>\t<reason>", ordered oldest first.
list_open_captain_decisions() {
  tasks_axi list --state held --kind captain --fields hold_reason,hold_kind,created 2>/dev/null \
    | awk "
        function emit(line,   f, n) {
          n = parse_csv(line, f)
          if (n < 8) return
          if (f[7] != \"captain\") return
          printf \"%s\t%s\t%s\t%s\n\", f[1], f[8], clean(f[5]), clean(f[6])
        }
        $TASKS_AXI_CSV_AWK
      " \
    | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k1,1
}

# Backlog ids whose structured blocked-by edges name <hold-id>.
list_tasks_blocked_by() {  # <hold-id>
  tasks_axi list --blocked --fields blocked_by 2>/dev/null \
    | awk -v want="$1" "
        function emit(line,   f, n, i, parts) {
          n = parse_csv(line, f)
          if (n < 6) return
          split(f[6], parts, \",\")
          for (i in parts) { if (parts[i] == want) { print f[1]; return } }
        }
        $TASKS_AXI_CSV_AWK
      "
}

render_open_decisions() {  # <tsv>
  local tsv=$1 id since title reason days
  [ -n "$tsv" ] || return 0
  while IFS=$'\t' read -r id since title reason; do
    [ -n "$id" ] || continue
    days=$(waiting_days "$since")
    if [ -n "$days" ]; then
      printf -- '- %s (waiting %s day%s, since %s)\n' \
        "$id" "$days" "$([ "$days" = 1 ] || printf s)" "$since"
    else
      printf -- '- %s (since %s)\n' "$id" "$since"
    fi
    printf '    question: %s\n' "$title"
    [ -z "$reason" ] || printf '    reason: %s\n' "$reason"
  done <<EOF
$tsv
EOF
}

read_body() {  # <hold-id>
  local show body
  require_jq
  show=$(task_show "$1") || fail "captain decision $1 is absent from $FM_HOME/data/backlog.md"
  body=$(show_field "$show" body)
  [ -n "$body" ] || return 0
  # tasks-axi renders the body as a JSON string literal on one line.
  printf '%s' "$body" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null \
    || fail "could not read the current body of $1"
}

origin_fold_ids() {  # <origin-id>
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] || return 0
  meta_value "$meta" decision_folds
}

# The registration record a resolution must not erase. On a first resolution that
# is the whole current body; on a retry it is the record the previous attempt
# already carried forward, so retries stay idempotent instead of nesting.
prior_registration() {  # <hold-id>
  local body
  body=$(read_body "$1")
  case "$body" in
    'Resolution recorded by fm-decision-hold.'*)
      case "$body" in
        *"$(printf '\nOrigin record:\n')"*) printf '%s' "${body#*$'\nOrigin record:\n'}" ;;
        *) : ;;
      esac
      ;;
    *) printf '%s' "$body" ;;
  esac
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
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

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
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

# True when the backlog's Done retention has rotated <hold-id> into the archive.
# The archived row is durable proof the decision was closed, so retention alone
# must never make a reviewed inventory unverifiable.
archived_done_record() {  # <hold-id>
  local archive="$DATA/done-archive.md"
  [ -f "$archive" ] || return 1
  grep -F -- "- [x] $1 - " "$archive" >/dev/null && return 0
  grep -F -- "- [X] $1 - " "$archive" >/dev/null
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  if ! show=$(task_show "$id"); then
    archived_done_record "$id" && return 0
    fail "captain decision $id is absent from $FM_HOME/data/backlog.md and its Done archive"
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
    # A decision closed outside this script - because firstmate decided it, or
    # because an earlier captain answer already settled it - is durably resolved
    # when its body carries a decision record. The gate exists to stop a decision
    # vanishing unanswered, not to insist on this script's own formatting.
    # A body still carrying the untouched registration record says in its own
    # words that no answer was ever written, so that closure is still refused.
    case "$body" in
      ''|'""'|'"-"') : ;;
      *"State: awaiting captain decision."*) : ;;
      *) return 0 ;;
    esac
    fail "captain decision $id was closed with no decision record; record the answer in its body"
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

command_open() {
  local origin='' aging_only=0 tsv threshold count id since title reason days
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --origin) shift; validate_slug origin-id "${1:-}"; origin=${1:-} ;;
      --aging-only) aging_only=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  require_tasks_axi
  tsv=$(list_open_captain_decisions)
  if [ -n "$origin" ] && [ -n "$tsv" ]; then
    tsv=$(printf '%s\n' "$tsv" | awk -F'\t' -v prefix="$origin-decision-" 'index($1, prefix) == 1')
  fi
  if [ "$aging_only" = 1 ] && [ -n "$tsv" ]; then
    threshold=$(aging_days)
    tsv=$(
      while IFS=$'\t' read -r id since title reason; do
        [ -n "$id" ] || continue
        days=$(waiting_days "$since")
        [ -n "$days" ] || continue
        [ "$days" -ge "$threshold" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$id" "$since" "$title" "$reason"
      done <<EOF
$tsv
EOF
    )
  fi
  count=0
  [ -z "$tsv" ] || count=$(printf '%s\n' "$tsv" | grep -c . || true)
  printf 'open captain decisions in %s: %s\n' "$FM_HOME" "$count"
  render_open_decisions "$tsv"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' distinct=0 id show state kind existing_title body others attest=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --distinct) distinct=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    # A different key covering an already-open question is how this queue
    # compounds, so the open set is placed in front of the caller before any new
    # backlog identity is created. Exact-key retries never reach this branch.
    others=$(list_open_captain_decisions | awk -F'\t' -v self="$id" '$1 != self')
    if [ -n "$others" ] && [ "$distinct" != 1 ]; then
      {
        printf 'fm-decision-hold: refusing to open a new captain decision before the open set is reviewed.\n'
        printf 'Open captain decisions in %s:\n' "$FM_HOME"
        render_open_decisions "$others"
        printf '\n'
        printf 'If %s is the SAME question as one of these, fold this finding in instead:\n' "$key"
        printf '  fm-decision-hold.sh fold %s --into <hold-id> --note <what this pass adds>\n' "$origin"
        printf 'If it is a genuinely different question, re-run the same command with --distinct.\n'
      } >&2
      exit 3
    fi
    if [ -n "$others" ]; then
      attest=$(printf '\nDistinct-from-open: attested %s against %s open captain decision(s).' \
        "$(today_utc)" "$(printf '%s\n' "$others" | grep -c . || true)")
    fi
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.%s' "$origin" "$key" "$attest")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_fold() {
  local origin=${1:-} into='' note='' meta previous folds body marker tmp
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --into) shift; into=${1:-} ;;
      --note) shift; note=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  [ -n "$into" ] || fail "--into <hold-id> is required"
  validate_slug hold-id "$into"
  validate_one_line note "$note"
  require_tasks_axi
  require_jq
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  [ "$into" != "$origin" ] || fail "an origin cannot fold into itself"
  case "$into" in
    "$origin"-decision-*) fail "$into already belongs to $origin; use its own decision key instead" ;;
  esac
  ( verify_hold_active "$into" ) >/dev/null 2>&1 \
    || fail "fold target $into is not an open captain decision; a resolved decision needs a new decision key"

  marker=$(printf 'Also raised by %s: %s' "$origin" "$note")
  body=$(read_body "$into")
  case "$body" in
    *"$marker"*) : ;;
    *)
      tmp=$(mktemp) || fail "could not create a temporary file"
      printf '%s\n%s\n' "$body" "$marker" > "$tmp"
      tasks_axi update "$into" --body-file "$tmp" >/dev/null \
        || { rm -f "$tmp"; fail "could not record the folded finding on $into"; }
      rm -f "$tmp"
      ;;
  esac

  meta="$STATE/$origin.meta"
  if [ -f "$meta" ]; then
    previous=$(meta_value "$meta" decision_folds)
    folds=$(sorted_key_union "$previous" "$into")
    [ "$previous" = "$folds" ] || printf 'decision_folds=%s\n' "$folds" >> "$meta"
  fi
  printf 'folded: %s -> %s\n' "$origin" "$into"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0 folds=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  folds=$(origin_fold_ids "$origin")
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    [ -z "$folds" ] \
      || fail "--none contradicts the folds recorded for $origin ($folds); use --folded"
    supplied=''
  elif [ "$#" -eq 1 ] && [ "$1" = --folded ]; then
    [ -n "$folds" ] \
      || fail "--folded requires at least one recorded fold; run fm-decision-hold.sh fold first"
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      [ "$1" != --folded ] || fail "--folded cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ -n "$folds" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$key"
    done <<EOF
$(printf '%s\n' "$folds" | tr ',' '\n')
EOF
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
  printf 'complete: %s decision inventory reviewed%s%s\n' \
    "$origin" "${keys:+ ($keys)}" "${folds:+ [folded into $folds]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open folds
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  folds=$(meta_value "$meta" decision_folds)
  if [ -n "$folds" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$key"
    done <<EOF
$(printf '%s\n' "$folds" | tr ',' '\n')
EOF
  fi
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

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' decision_text='' decided_by=captain no_routed=0 id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0 still_blocked prior=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --decision) shift; decision_text=${1:-} ;;
      --decided-by) shift; decided_by=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      --no-routed-work) no_routed=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  case "$decided_by" in
    captain|firstmate) : ;;
    *) fail "--decided-by must be captain or firstmate" ;;
  esac
  [ -z "$decision_file" ] || [ -z "$decision_text" ] \
    || fail "--decision and --decision-file are mutually exclusive"
  if [ -n "$decision_file" ]; then
    [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
    decision=$(cat "$decision_file")
    [ -n "$decision" ] || fail "decision file must not be empty"
  else
    [ -n "$decision_text" ] || fail "--decision <text> or --decision-file <path> is required"
    decision=$decision_text
  fi
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "the captain decision exceeds 8192 bytes"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if [ "$no_routed" = 1 ]; then
    [ -z "$routed" ] || fail "--no-routed-work cannot be combined with --routed-to"
    # The routing requirement survives wherever dependent work genuinely exists.
    still_blocked=$(list_tasks_blocked_by "$id" | paste -sd' ' - | sed 's/ *$//')
    [ -z "$still_blocked" ] \
      || fail "work is blocked by $id ($still_blocked); route it with --routed-to instead of --no-routed-work"
    routed_csv='(none)'
  else
    [ -n "$routed" ] || fail "--routed-to <task-id> or --no-routed-work is required"
    routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
    routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  fi
  decision_digest=$(sha256_text "$decision")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
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

  # Keep the registration record - the origin, key, distinctness attestation, and
  # any folded findings - readable after the resolution is written over it.
  prior=$(prior_registration "$id")
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nDecided by: %s\n\nCaptain decision:\n%s\n\nRouted work:' "$decision_digest" "$routed_csv" "$decided_by" "$decision")
  body="${body}"$'\n'
  if [ "$no_routed" = 1 ]; then
    body="${body}- (none: no dependent work existed when the captain decided)"$'\n'
  else
    for dep in $routed; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  if [ -n "$prior" ]; then
    body="${body}"$'\nOrigin record:\n'"${prior}"$'\n'
  fi
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
  printf 'resolved: %s -> %s\n' "$id" "${routed:-(no dependent work)}"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  open) shift; command_open "$@" ;;
  hold) shift; command_hold "$@" ;;
  fold) shift; command_fold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
