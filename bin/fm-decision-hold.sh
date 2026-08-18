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
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh decline <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh repair <origin-id> <decision-key> --decision-file <path>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` and `decline` close active holds; `repair` attests a hold already closed
# outside this script. All three paths require a non-empty captain decision file of
# at most 8192 bytes, record the same durable resolution block in the hold body, and
# store the decision digest plus routed identities so an exact retry is idempotent
# while a changed decision or, for `resolve`, routed set is rejected. New records
# include a `Resolution mode:` naming their path; older routed records remain valid.
#
# `resolve` is the routed path. It requires every --routed-to task to exist and to
# be blocked by the hold. It writes the captain decision and routed identities into
# the hold body, clears those dependency edges, and only then marks the hold Done.
# A failure before the final step leaves the captain hold open.
#
# `decline` is the unrouted path for a decision the captain answered with no
# follow-up work. It takes no --routed-to task, records `(none)` as the routed
# identities, and closes an actively held hold. It refuses while any task is still
# blocked by the hold, because releasing routed work without recording it is
# `resolve`'s job.
#
# `repair` records the missing resolution block on a hold that was already closed
# outside this script, so `verify` stops failing on an origin whose decision was
# genuinely answered. It never reopens a hold, never clears a dependency edge, and
# refuses a hold that is still actively held, so an unanswered decision keeps
# blocking teardown until `resolve` or `decline` closes it with the captain's word.
# It also refuses an identity that does not carry surviving captain-hold
# provenance, so an ordinary captain-kind task cannot be repaired into a decision.
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

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
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
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$DECISION_DIGEST" "$routed_csv" "$mode" "$DECISION_TEXT")
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

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ] && body_has_resolution_record "$body"; then
    return 0
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
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
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
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
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
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        list_has_key "$keys" "$key" || continue
      "$SCRIPT_DIR/fm-status-event.sh" self-append "$STATE" "$origin" "captain-held [key=$key]: tracked by $(hold_id "$origin" "$key")"
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

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
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
  load_decision "$decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use decline when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
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

  # shellcheck disable=SC2086  # routed is a validated space-separated slug list.
  body=$(resolution_body routed "$routed_csv" $routed)
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
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

parse_decision_only_flags() {  # <args...>; prints the --decision-file value
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  printf '%s' "$decision_file"
}

command_decline() {
  local origin=${1:-} key=${2:-} decision_file id body hold_show hold_body state dependents
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf 'declined: %s\n' "$id"
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
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
      ;;
  esac
  dependents=$(tasks_blocked_by "$id") || exit 1
  [ -z "$dependents" ] \
    || fail "captain hold $id still blocks routed work ($dependents); use resolve to record that work"
  body=$(resolution_body declined "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close declined captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'declined: %s\n' "$id"
}

command_repair() {
  local origin=${1:-} key=${2:-} decision_file id body show state kind hold_kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
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
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$ROUTED_NONE"
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
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  decline) shift; command_decline "$@" ;;
  repair) shift; command_repair "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
