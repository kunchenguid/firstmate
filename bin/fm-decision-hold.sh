#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and requires a durable captain decision
# record before it closes or repairs a hold.
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
#   fm-decision-hold.sh fold <origin-id> --into <hold-id> --note <note> \
#     [--key <decision-key>...]
#   fm-decision-hold.sh complete <origin-id> (--none | --folded | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     (--decision <text> | --decision-file <path>) [--decided-by captain|firstmate] \
#     (--routed-to <task-id>... | --no-routed-work)
#   fm-decision-hold.sh answer <origin-id> <decision-key> \
#     (--decision <text> | --decision-file <path>) [--decided-by captain|firstmate]
#   fm-decision-hold.sh answers <origin-id> --source <provenance>   (keyed answers on stdin)
#   fm-decision-hold.sh bind <source-id> <origin-id>
#   fm-decision-hold.sh unbind <source-id>
#   fm-decision-hold.sh binding <source-id>
#   fm-decision-hold.sh decline <origin-id> <decision-key> \
#     (--decision <text> | --decision-file <path>) [--decided-by captain|firstmate]
#   fm-decision-hold.sh repair <origin-id> <decision-key> \
#     (--decision <text> | --decision-file <path>) [--decided-by captain|firstmate]
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
# creating a duplicate captain decision. It refuses up front, before touching the
# target, when the origin has no metadata to record the fold in, so a reported
# fold always satisfies `complete --folded`. It also transfers the origin's open
# keyed status decision to the decision that now owns it, the same
# `captain-held [key=...]` event `complete` writes, so a folded status decision is
# not left open for a key this origin will never register. `--key` names which
# open status decision this fold covers; it is required while several are open, so
# one fold can never blanket-satisfy more than the question it folded.
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
# `resolve`, `answer`, and `decline` close active holds; `repair` attests a hold
# already closed outside this script. All four paths take the captain's answer as
# `--decision <text>` or `--decision-file <path>` of at most 8192 bytes, record the
# same durable resolution block in the hold body, and store the decision digest
# plus routed identities so an exact retry is idempotent while a changed decision
# or, for `resolve`, routed set is rejected. `--decided-by` records who settled it:
# `captain` by default, or `firstmate` when the question turned out to be
# firstmate's own call. New records include a `Resolution mode:` naming their path
# and a `Decided by:` naming the decider; older records remain valid.
#
# `resolve` is the routed path. It requires every --routed-to task to exist and to
# be blocked by the hold, or declares no dependent work exists with
# `--no-routed-work`, which is refused whenever any backlog task is actually
# blocked by the hold. It writes the captain decision and routed identities into
# the hold body, clears those dependency edges, and only then marks the hold Done.
# A failure before the final step leaves the captain hold open.
#
# `answer` is the answer-time closure path, the hold ledger's counterpart to
# `fm-send.sh --resolve-key`: it exists so the act that carries the captain's
# answer is the act that closes the hold, instead of leaving closure to a
# separate later call nobody is forced to make. It records the captain's answer
# on an actively held hold, records `(none)` as the routed identities because no
# follow-up work has been routed behind the hold yet, and closes it. It shares
# every guard `decline` has, including the refusal while any task is still
# blocked by the hold, so a decision whose follow-up work is already routed still
# goes through `resolve` and the routed-vs-unrouted distinction survives. It says
# only that the captain answered; `decline` still says the captain answered with
# no follow-up work at all.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer closes its matching hold" is a single capability, owned here
# and nowhere else. `answers` is its channel-agnostic entry point: it reads
# `<decision-key>\t<answer>\t<label>` lines on stdin, maps each key to this
# origin's `<origin-id>-decision-<key>` hold, and closes it through the very same
# `answer` path above, so every guard applies identically no matter which channel
# the answer arrived on. `--source` is provenance text recorded in the durable
# decision, never a behavior switch: this command has no per-channel branch and
# no knowledge of chat, review decks, or any transport.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines and
# pipe them here. It must never map keys to holds, build decision records, decide
# resolve-versus-decline, or close a hold itself. A future channel needs no change
# here at all.
#
# The decision text is a pure function of (source, key, answer, label), which is
# what makes a replayed delivery an idempotent no-op rather than a rejected
# "different captain decision". A key whose hold is absent, already closed, or
# still blocking routed work is reported as `skipped:` and left for `resolve`;
# skipping is never forced closure, and the command exits nonzero when any key
# was skipped.
#
# `bind`, `unbind`, and `binding` record which origin a captured-answer SOURCE
# belongs to, for any channel whose answers arrive detached from the origin (a
# process-event source id, for example). The binding is a private record under
# `state/decision-bindings/`; a source with no binding feeds nothing, so this
# whole path is opt-in per source and an unbound source behaves as if it did not
# exist. `bind` deliberately does not require the source to exist yet, so a
# channel can be bound BEFORE it is armed and never produce an answer that has
# nowhere to go.
#
# `decline` is the unrouted sibling of `resolve`, for a decision the captain
# answered with no follow-up work. It takes the same `--decision`/`--decision-file`
# and `--decided-by` inputs but no `--routed-to`; it records `(none)` as the routed
# identities and closes an actively held hold. It refuses while any task is still
# blocked by the hold, because releasing routed work without recording it is
# `resolve`'s job.
#
# `repair` records the missing resolution block on a hold that was already closed
# outside this script, so `verify` stops failing on an origin whose decision was
# genuinely answered. It takes the same decision inputs as `resolve`/`decline`. It
# never reopens a hold, never clears a dependency edge, and refuses a hold that is
# still actively held, so an unanswered decision keeps blocking teardown until
# `resolve` or `decline` closes it with the captain's word. It also refuses an
# identity that does not carry surviving captain-hold provenance, so an ordinary
# captain-kind task cannot be repaired into a decision.
#
# `resolve`, `decline`, and `repair` all record the same durable resolution block
# in the hold body, storing the decision digest and routed identities (`(none)` for
# decline/repair) so an exact retry is idempotent while a changed decision or, for
# `resolve`, a changed routed set is rejected. Each record carries a `Resolution
# mode:` naming its path and a `Decided by:` naming who settled it; older records
# from before either field existed remain valid and default to `captain`.
#
# The completion and teardown gates accept a decision as durably resolved when it
# is closed and carries a decision record, whatever wrote that record, including
# once Done retention has rotated it into data/done-archive.md. A decision closed
# with no record at all is still refused, because that is the loss the gate exists
# to prevent; the gate checks that an answer survives, not that this script
# formatted it. The archived shape is held to the same record test as the live
# one, so retention can never turn a refused closure into an accepted one.
#
# Environment: FM_DECISION_AGING_DAYS (default 3) is the one ageing threshold,
# shared with bin/fm-fleet-snapshot.sh so the CLI listing and the fleet view can
# never disagree; FM_DECISION_NOW (YYYY-MM-DD) pins today's date for tests.
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
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

DECISION_META_LOCK=
DECISION_META_LOCK_HELD=0
decision_hold_cleanup() {
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK" || true
    DECISION_META_LOCK_HELD=0
  fi
}
trap decision_hold_cleanup EXIT

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

# The routed-identity token recorded when a close path routes no work. Slug
# validation rejects parentheses, so no real task identity can collide with it.
ROUTED_NONE='(none)'

DECISION_TEXT=''
DECISION_DIGEST=''
DECIDED_BY=''

# Parses the --decision/--decision-file/--decided-by inputs shared by decline and
# repair - the same shape resolve takes, minus routing - and loads the captain's
# decision into DECISION_TEXT/DECISION_DIGEST and DECIDED_BY.
parse_decision_answer() {  # "$@"
  local decision_file='' decision_text=''
  DECIDED_BY=captain
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --decision) shift; decision_text=${1:-} ;;
      --decided-by) shift; DECIDED_BY=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$DECIDED_BY" in
    captain|firstmate) : ;;
    *) fail "--decided-by must be captain or firstmate" ;;
  esac
  [ -z "$decision_file" ] || [ -z "$decision_text" ] \
    || fail "--decision and --decision-file are mutually exclusive"
  if [ -n "$decision_file" ]; then
    [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
    DECISION_TEXT=$(cat "$decision_file")
    [ -n "$DECISION_TEXT" ] || fail "decision file must not be empty"
  else
    [ -n "$decision_text" ] || fail "--decision <text> or --decision-file <path> is required"
    DECISION_TEXT=$decision_text
  fi
  [ "$(printf '%s' "$DECISION_TEXT" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "the captain decision exceeds 8192 bytes"
  DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
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
  date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null \
    || date -u -d "$1 00:00:00 UTC" +%s 2>/dev/null \
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
#
# The predicate is the same one bin/fm-fleet-snapshot.sh applies for
# captain_actionable - queued, kind captain, held for the captain with a reason,
# and carrying no unresolved blocker - so this listing and Bearings' Captain's
# Call can never cite different decisions. tasks-axi drops a resolved blocker
# from blocked_by and refuses an edge to a task that does not exist, so its
# blocked_by is exactly the unresolved-blocker set the fleet view computes.
list_open_captain_decisions() {
  tasks_axi list --state held --kind captain \
      --fields hold_reason,hold_kind,created,blocked_by 2>/dev/null \
    | awk "
        function emit(line,   f, n) {
          n = parse_csv(line, f)
          if (n < 9) return
          if (f[2] != \"queued\") return
          if (f[6] == \"\") return
          if (f[7] != \"captain\") return
          if (f[9] != \"\" && f[9] != \"none\") return
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

# The one fold check both the completion gate and the teardown gate apply, so the
# two cannot drift apart.
verify_folds() {  # <comma-separated-fold-ids>
  local folds=$1 fold
  [ -n "$folds" ] || return 0
  while IFS= read -r fold; do
    [ -n "$fold" ] || continue
    verify_hold_durable "$fold"
  done <<EOF
$(printf '%s\n' "$folds" | tr ',' '\n')
EOF
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

status_transfer_line() {  # <key> <owner-hold-id>
  printf 'captain-held [key=%s]: tracked by %s\n' "$1" "$2"
}

status_transfer_recorded() {  # <status-file> <key> <owner-hold-id>
  [ -f "$1" ] || return 1
  grep -Fxq -- "$(status_transfer_line "$2" "$3")" "$1"
}

# The origin's open structured decision keys this fold covers, one per line.
# A fold closes the live status copy of the question it folded and nothing else,
# so an explicit --key must name a decision that is open here, and an unqualified
# fold covers a single open decision but refuses while several are open rather
# than blanket-satisfying all of them. A key this fold already transferred to the
# same owner is silently skipped, which keeps repeating a fold idempotent.
fold_covered_keys() {  # <origin-id> <open-set> <requested-keys> <owner-hold-id>
  local origin=$1 open=$2 requested=$3 into=$4 status_file="$STATE/$1.status" key open_keys count covered=''
  open_keys=$(printf '%s' "$open" | awk -F'\t' 'NF { print $1 }')
  if [ -n "$requested" ]; then
    for key in $requested; do
      if printf '%s\n' "$open_keys" | grep -Fxq -- "$key"; then
        covered="${covered}${key}"$'\n'
      elif status_transfer_recorded "$status_file" "$key" "$into"; then
        :
      else
        fail "origin $origin has no open structured decision under key $key"
      fi
    done
    printf '%s' "$covered"
    return 0
  fi
  count=0
  [ -z "$open_keys" ] || count=$(printf '%s\n' "$open_keys" | grep -c . || true)
  [ "$count" -le 1 ] \
    || fail "origin $origin has $count open structured decisions; name the one this fold covers with --key <decision-key>"
  [ -z "$open_keys" ] || printf '%s\n' "$open_keys"
}

body_has_resolution_record() {  # <hold-body>
  case "$1" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

resolution_body() {  # <mode> <routed-csv> [routed-task-id...]
  local mode=$1 routed_csv=$2 body dep
  shift 2
  # Command substitution strips the trailing newline, so restore it before the
  # routed-work list to keep each entry on its own durable backlog line.
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nDecided by: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$DECISION_DIGEST" "$routed_csv" "$DECIDED_BY" "$mode" "$DECISION_TEXT")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    body="${body}${ROUTED_NONE}"$'\n'
  else
    for dep in "$@"; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  printf '%s' "$body"
}

# tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
normalized_blocked_by() {  # <show-output>
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

# Space-separated ids of live work still blocked by <hold-id>. The listing is only
# a cheap prefilter whose first field is always an unquoted id; every candidate is
# confirmed against its own authoritative record before it is reported.
tasks_blocked_by() {  # <hold-id>
  local id=$1 rows row candidate show found=''
  rows=$(tasks_axi list --fields blocked_by) \
    || fail "could not read backlog work while checking what $id still blocks"
  while IFS= read -r row; do
    case "$row" in
      *"$id"*) : ;;
      *) continue ;;
    esac
    candidate=${row%%,*}
    candidate=${candidate// /}
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$id" ] || continue
    case "$candidate" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    show=$(task_show "$candidate") || continue
    list_has_key "$(normalized_blocked_by "$show")" "$id" || continue
    found="${found}${found:+ }$candidate"
  done <<EOF
$rows
EOF
  printf '%s' "$found"
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
  body_has_resolution_record "$body"
}

# The single record test every closed captain decision passes, whether its body
# came from the live backlog or from the Done archive.
#
# A decision closed outside this script - because firstmate decided it, or
# because an earlier captain answer already settled it - is durably resolved when
# its body carries a decision record. The gate exists to stop a decision
# vanishing unanswered, not to insist on this script's own formatting. A body
# still carrying the untouched registration record says in its own words that no
# answer was ever written, so that closure is refused.
closed_body_has_record() {  # <body>
  local body=$1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  case "$body" in
    ''|'""'|'"-"') return 1 ;;
    *"State: awaiting captain decision."*) return 1 ;;
  esac
  return 0
}

# The body of <hold-id>'s archived row, once the backlog's Done retention has
# rotated it into data/done-archive.md; exit 1 when no such row exists. The
# archive preserves the entry's indented body lines verbatim, so the archived
# shape is held to the same record test as the live one and retention can neither
# make a reviewed inventory unverifiable nor launder a recordless closure.
archived_done_body() {  # <hold-id>
  local archive="$DATA/done-archive.md"
  [ -f "$archive" ] || return 1
  awk -v id="$1" '
    BEGIN { want = "- [x] " id " - "; wantu = "- [X] " id " - " }
    index($0, want) == 1 || index($0, wantu) == 1 {
      found = 1; inbody = 1; body = ""; pending = ""; next
    }
    inbody && /^  / {
      body = body pending substr($0, 3) "\n"; pending = ""; next
    }
    inbody && /^[[:space:]]*$/ { pending = pending "\n"; next }
    inbody { inbody = 0; pending = "" }
    END { if (!found) exit 1; printf "%s", body }
  ' "$archive"
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  if ! show=$(task_show "$id"); then
    if body=$(archived_done_body "$id"); then
      if closed_body_has_record "$body"; then
        return 0
      fi
      fail "captain decision $id was archived with no decision record; record the answer in its body"
    fi
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
    if closed_body_has_record "$body"; then
      return 0
    fi
    fail "captain decision $id was closed with no decision record; record the answer in its body"
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

# The retry identity is the decision digest, the routed identities, and the
# recorded attributor. Attribution is part of the identity because a retry that
# claims a different decider than the durable record would print success while the
# record kept contradicting it. A record written before attribution existed reads
# as `captain`, which is what it always meant.
verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 decided_by=$5 resolution_prefix resolution_fields recorded_digest recorded_routes recorded_decided_by tail
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
  tail=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${tail%%\\n*}
  case "$tail" in
    *'\nDecided by: '*)
      tail=${tail#*\\nDecided by: }
      recorded_decided_by=${tail%%\\n*}
      ;;
    *) recorded_decided_by=captain ;;
  esac
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
  [ "$recorded_decided_by" = "$decided_by" ] \
    || fail "captain hold $id records a different decider ($recorded_decided_by)"
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
  local origin=${1:-} into='' note='' requested='' meta previous folds body marker tmp status_file open covered key
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --into) shift; into=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --key) shift; validate_slug decision-key "${1:-}"; requested="${requested}${requested:+ }${1:-}" ;;
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
  # A fold only means something once it is recorded in the origin's metadata,
  # which is what lets `complete --folded` accept the origin. Without that file
  # the fold cannot be recorded, so refuse before touching the target rather than
  # reporting a success the completion gate will later reject.
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin $origin has no runtime metadata at $meta, so the fold cannot be recorded; fold from the home that owns $origin"
  ( verify_hold_active "$into" ) >/dev/null 2>&1 \
    || fail "fold target $into is not an open captain decision; a resolved decision needs a new decision key"
  # Which live status decisions this fold answers for is decided before anything is
  # written, so a fold that cannot name its coverage refuses instead of leaving the
  # target mutated and the origin still unable to complete.
  status_file="$STATE/$origin.status"
  open=$(origin_open_decisions "$origin")
  covered=$(fold_covered_keys "$origin" "$open" "$requested" "$into")

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

  previous=$(meta_value "$meta" decision_folds)
  folds=$(sorted_key_union "$previous" "$into")
  [ "$previous" = "$folds" ] || printf 'decision_folds=%s\n' "$folds" >> "$meta"

  # The live status copy of a folded question is transferred to the decision that
  # now owns it, exactly as `complete` transfers a question to its own hold, so
  # `complete --folded` satisfies the per-key requirement instead of dead-ending
  # on a status decision no key of this origin will ever cover.
  for key in $covered; do
    status_transfer_line "$key" "$into" >> "$status_file"
  done
  printf 'folded: %s -> %s%s\n' "$origin" "$into" \
    "$(if [ -n "$covered" ]; then printf ' [keys=%s]' "$(printf '%s\n' "$covered" | sed '/^$/d' | paste -sd, -)"; fi)"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0 folds='' transfer_rc=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
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
  verify_folds "$folds"
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
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    # The transfer line is this home's own bookkeeping close, written by the
    # turn that just reviewed the decision, so it uses the guarded
    # self-announced append (bin/fm-wake-lib.sh) and does not wake this same
    # session; an append failure still fails this command loudly.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "$(status_transfer_line "$key" "$(hold_id "$origin" "$key")")" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
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
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  verify_folds "$(origin_fold_ids "$origin")"
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
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv" "$decided_by"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv" "$decided_by"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(normalized_blocked_by "$show")
    if ! list_has_key "$blocked" "$id"; then
      case "$hold_body" in
        *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
        *) fail "routed task $dep is not durably blocked by $id" ;;
      esac
    fi
  done

  # Keep the registration record - the origin, key, distinctness attestation, and
  # any folded findings - readable after the resolution is written over it.
  prior=$(prior_registration "$id")
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nDecided by: %s\nResolution mode: resolved\n\nCaptain decision:\n%s\n\nRouted work:' "$decision_digest" "$routed_csv" "$decided_by" "$decision")
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
    if list_has_key "$(normalized_blocked_by "$show")" "$id"; then
      tasks_axi unblock "$dep" --by "$id" >/dev/null \
        || fail "could not route the recorded decision to $dep"
    fi
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "${routed:-(no dependent work)}"
}

# The one unrouted close path, shared by `answer` and `decline`. They differ only
# in the resolution mode they record and the outcome word they print; every
# guard - the captain decision file, the active-hold requirement, the retry
# identity, and the refusal to release still-routed work - is identical, so
# neither can drift into a weaker close than the other.
close_unrouted_hold() {  # <mode> <outcome-word> <origin-id> <decision-key> <flag-args...>
  local mode=$1 outcome=$2 origin=$3 key=$4 id body hold_show hold_body state dependents
  shift 4
  parse_decision_answer "$@"
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE" "$DECIDED_BY"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi
  hold_show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$hold_show" state)
  [ "$state" != "done" ] \
    || fail "captain hold $id was closed outside fm-decision-hold; use repair to record the captain decision"
  verify_hold_active "$id"
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE" "$DECIDED_BY"
      ;;
  esac
  dependents=$(tasks_blocked_by "$id") || exit 1
  [ -z "$dependents" ] \
    || fail "captain hold $id still blocks routed work ($dependents); use resolve to record that work"
  body=$(resolution_body "$mode" "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close $mode captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf '%s: %s\n' "$outcome" "$id"
}

command_answer() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold answered answered "$@"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The origin a captured-answer source belongs to, or empty when it is unbound.
# An unreadable or wrong-schema record is a hard error rather than a silent
# "unbound": feeding nothing is the safe direction only when it is a deliberate
# choice, never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  case "$origin" in
    ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
  esac
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  validate_slug origin-id "$origin"
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

command_answers() {
  local origin=${1:-} source='' key answer label hold tmp err closed=0 skipped=0 reason
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS=$'\t' read -r key answer label; do
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 64 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    hold="$origin-decision-$key"
    keyed_decision_text "$source" "$key" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $hold"
    if "$0" answer "$origin" "$key" --decision-file "$tmp" >/dev/null 2>"$err"; then
      printf 'closed: %s\n' "$hold"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-decision-hold: //')
      printf 'skipped: %s (%s)\n' "$hold" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s origin=%s\n' "$closed" "$skipped" "$origin"
  [ "$skipped" -eq 0 ]
}

command_decline() {
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  close_unrouted_hold declined declined "$@"
}

command_repair() {
  local origin=${1:-} key=${2:-} id body show state kind hold_kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  parse_decision_answer "$@"
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  kind=$(show_field "$show" kind)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  # tasks-axi keeps hold_kind after a close, so it is the surviving proof that
  # this identity really was a captain hold rather than an ordinary captain-kind
  # task that was never held for the captain at all.
  hold_kind=$(show_field "$show" hold_kind)
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id was never held for the captain; repair records a captain decision only on a captain hold"
  state=$(show_field "$show" state)
  hold_body=$(show_field "$show" body)
  if [ "$state" = "done" ] && body_has_resolution_record "$hold_body"; then
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE" "$DECIDED_BY"
    printf 'repaired: %s\n' "$id"
    return 0
  fi
  [ "$state" = "done" ] \
    || fail "captain hold $id is still open (state=$state); use resolve or decline to close it with the captain's decision"
  body=$(resolution_body repaired "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  show=$(task_show "$id") || fail "captain decision $id disappeared while recording the repair"
  [ "$(show_field "$show" state)" = "done" ] || fail "repairing $id reopened a closed captain decision"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'repaired: %s\n' "$id"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  open) shift; command_open "$@" ;;
  hold) shift; command_hold "$@" ;;
  fold) shift; command_fold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  decline) shift; command_decline "$@" ;;
  repair) shift; command_repair "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
