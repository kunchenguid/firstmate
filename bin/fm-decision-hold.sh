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
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh verify-resolution <origin-id> <decision-key>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown. An unresolved hold is
# cleanup-authoritative only after `complete` records a receipt under
# data/decision-hold-receipts/ that binds origin id, endpoint dispatch id, the
# exact backlog object digest, and a Bearings snapshot in which the hold appears.
# Every live completion, including `--none`, also retains a report-bound origin
# receipt so a later post-teardown visual-review pass keeps the authenticated
# task and dispatch association needed to create and verify hold receipts.
# This permits cleanup without requiring the captain to answer in the same session.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
# A resolved hold additionally retains the captain decision in
# <hold-id>.decision.md and records <hold-id>.resolved beside it. Verification
# requires one live-or-archived row, a nonzero decision digest, exact origin and
# dispatch links, the canonical existing decision object, every routed task, and
# matching object digests. Historical resolved rows without this receipt refuse;
# there is no implicit or hand-written-row migration. An open historical hold may
# reconstruct its cleanup receipt only by repeating `complete` while its exact
# endpoint dispatch binding survives. Binding-less or already-resolved rows whose
# script-owned objects are absent remain preserved and refused; no safe automatic
# migration, force, or discard is supplied by this command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECEIPT_DIR="$DATA/decision-hold-receipts"

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

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

digest_is_nonzero_sha256() {  # <digest>
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$' || return 1
  [ "$1" != 0000000000000000000000000000000000000000000000000000000000000000 ]
}

regular_nonsymlink_file() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ]
}

write_atomic_file() {  # <path>  (content on stdin)
  local path=$1 dir tmp
  dir=${path%/*}
  mkdir -p "$dir" || fail "could not create receipt directory: $dir"
  tmp=$(mktemp "$dir/.receipt.tmp.XXXXXX") || fail "could not allocate receipt temporary file"
  chmod 600 "$tmp" || { rm -f "$tmp"; fail "could not protect receipt temporary file"; }
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    fail "could not write receipt temporary file"
  fi
  mv "$tmp" "$path" || { rm -f "$tmp"; fail "could not publish receipt: $path"; }
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
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

task_row_count() {  # <id>
  local id=$1 prefix file
  prefix="- [x] $id - "
  {
    for file in "$DATA/backlog.md" "$DATA/done-archive.md"; do
      [ -f "$file" ] || continue
      awk -v open="- [ ] $id - " -v done="$prefix" '
        index($0, open) == 1 || index($0, done) == 1 { count++ }
        END { print count + 0 }
      ' "$file"
    done
  } | awk '{ total += $1 } END { print total + 0 }'
}

task_row_source() {  # <id>
  local id=$1 file count
  [ "$(task_row_count "$id")" -eq 1 ] || return 1
  for file in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -f "$file" ] || continue
    count=$(awk -v open="- [ ] $id - " -v done="- [x] $id - " '
      index($0, open) == 1 || index($0, done) == 1 { count++ }
      END { print count + 0 }
    ' "$file") || return 1
    if [ "$count" -eq 1 ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

archived_task_show() {  # <id>
  local id=$1 archive="$DATA/done-archive.md" prefix
  [ -f "$archive" ] || return 1
  prefix="- [x] $id - "
  {
    printf '## In flight\n\n## Queued\n\n## Done\n'
    awk -v prefix="$prefix" '
      /^- \[[ x]\] / {
        if (capture) exit
        if (index($0, prefix) == 1) {
          capture = 1
          print
        }
        next
      }
      capture {
        if ($0 ~ /^## /) exit
        print
      }
    ' "$archive"
  } | tasks_axi show "$id" --full --file /dev/stdin 2>/dev/null
}

task_show_durable() {  # <id>
  local id=$1 source
  source=$(task_row_source "$id") || return 1
  if [ "$source" = "$DATA/backlog.md" ]; then
    task_show "$id"
  else
    archived_task_show "$id"
  fi
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

meta_exact_value() {  # <meta> <key>
  local meta=$1 key=$2 count
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^$key=//p" "$meta"
}

receipt_value() {  # <receipt> <key>
  local receipt=$1 key=$2 count
  regular_nonsymlink_file "$receipt" || return 1
  count=$(grep -c "^$key=" "$receipt" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^$key=//p" "$receipt"
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
  show=$(task_show_durable "$id") || return 1
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

verify_hold_durable() {  # <origin-id> <hold-id>
  local origin=$1 id=$2 show state held kind hold_kind body
  show=$(task_show_durable "$id") \
    || fail "captain decision $id is absent, duplicated, or indeterminate in the live backlog and archive"
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
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*)
        verify_resolution_receipt "$origin" "$id"
        return 0
        ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

resolution_body_fields() {  # <hold-id> <body>; sets RESOLUTION_DIGEST RESOLUTION_ROUTES
  local id=$1 body=$2 fields prefix
  prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$body" in
    "$prefix"*) fields=${body#"$prefix"} ;;
    *) fail "captain hold $id has no authoritative resolution body" ;;
  esac
  case "$fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*'\n\nRouted work:'*) : ;;
    *) fail "captain hold $id has a malformed resolution body" ;;
  esac
  RESOLUTION_DIGEST=${fields%%\\n*}
  fields=${fields#*\\nRouted identities: }
  RESOLUTION_ROUTES=${fields%%\\n*}
  digest_is_nonzero_sha256 "$RESOLUTION_DIGEST" \
    || fail "captain hold $id must carry a nonzero sha256 decision digest"
  [ -n "$RESOLUTION_ROUTES" ] || fail "captain hold $id has no routed task identities"
}

cleanup_receipt_path() {  # <hold-id>
  printf '%s/%s.hold\n' "$RECEIPT_DIR" "$1"
}

resolution_receipt_path() {  # <hold-id>
  printf '%s/%s.resolved\n' "$RECEIPT_DIR" "$1"
}

decision_object_path() {  # <hold-id>
  printf '%s/%s.decision.md\n' "$RECEIPT_DIR" "$1"
}

origin_receipt_path() {  # <origin-id>
  printf '%s/%s.origin\n' "$RECEIPT_DIR" "$1"
}

write_origin_receipt() {  # <origin-id> <dispatch-id>
  local origin=$1 dispatch=$2 report="$DATA/$1/report.md" report_sha receipt
  regular_nonsymlink_file "$report" || fail "origin $origin has no safe report object to retain its dispatch binding"
  report_sha=$(sha256_file "$report")
  digest_is_nonzero_sha256 "$report_sha" || fail "origin $origin produced an invalid report digest"
  receipt=$(origin_receipt_path "$origin")
  {
    printf 'schema=fm-decision-hold-origin.v1\n'
    printf 'origin_id=%s\n' "$origin"
    printf 'dispatch_id=%s\n' "$dispatch"
    printf 'origin_path=%s\n' "$report"
    printf 'origin_sha256=%s\n' "$report_sha"
  } | write_atomic_file "$receipt"
}

verify_origin_receipt() {  # <origin-id> [expected-dispatch-id]
  local origin=$1 expected=${2:-} receipt schema recorded_origin recorded_dispatch origin_path origin_sha
  receipt=$(origin_receipt_path "$origin")
  regular_nonsymlink_file "$receipt" || fail "origin $origin has no trusted dispatch carrier"
  schema=$(receipt_value "$receipt" schema) || fail "origin $origin has a malformed dispatch carrier schema"
  recorded_origin=$(receipt_value "$receipt" origin_id) || fail "origin $origin dispatch carrier has no task identity"
  recorded_dispatch=$(receipt_value "$receipt" dispatch_id) || fail "origin $origin dispatch carrier has no dispatch identity"
  origin_path=$(receipt_value "$receipt" origin_path) || fail "origin $origin dispatch carrier has no source path"
  origin_sha=$(receipt_value "$receipt" origin_sha256) || fail "origin $origin dispatch carrier has no source digest"
  [ "$schema" = fm-decision-hold-origin.v1 ] || fail "origin $origin has an unsupported dispatch carrier"
  [ "$recorded_origin" = "$origin" ] || fail "origin $origin dispatch carrier links a different task"
  validate_slug dispatch-id "$recorded_dispatch"
  [ "$recorded_dispatch" = "$origin" ] || fail "origin $origin dispatch carrier links a different endpoint dispatch: $recorded_dispatch"
  [ -z "$expected" ] || [ "$recorded_dispatch" = "$expected" ] \
    || fail "origin $origin dispatch carrier disagrees with cleanup dispatch $expected"
  [ "$origin_path" = "$DATA/$origin/report.md" ] || fail "origin $origin dispatch carrier names an unauthorized source path"
  regular_nonsymlink_file "$origin_path" || fail "origin $origin dispatch source path does not exist safely"
  digest_is_nonzero_sha256 "$origin_sha" || fail "origin $origin dispatch source digest must be nonzero sha256"
  [ "$(sha256_file "$origin_path")" = "$origin_sha" ] || fail "origin $origin dispatch source digest no longer matches"
  printf '%s\n' "$recorded_dispatch"
}

completion_dispatch() {  # <origin-id> <meta-path> <has-meta>
  local origin=$1 meta=$2 has_meta=$3 dispatch
  if [ "$has_meta" = 1 ]; then
    dispatch=$(meta_exact_value "$meta" endpoint_task_id) \
      || fail "origin $origin has no unique endpoint dispatch binding; preserve origin metadata and holds because no safe automatic migration is shipped"
    [ "$dispatch" = "$origin" ] || fail "origin $origin metadata links a different endpoint dispatch: $dispatch"
    write_origin_receipt "$origin" "$dispatch"
    verify_origin_receipt "$origin" "$dispatch" >/dev/null
  else
    dispatch=$(verify_origin_receipt "$origin") || return 1
  fi
  printf '%s\n' "$dispatch"
}

fail_missing_cleanup_receipt() {  # <origin-id> <hold-id>
  local origin=$1 id=$2
  if verify_hold_resolved "$id"; then
    fail "historical or hand-written resolved row $id has no trusted cleanup receipt; preserve the origin and row: no safe automatic migration is shipped"
  fi
  fail "captain hold $id has no trusted cleanup receipt; re-run complete $origin with its full recorded decision inventory only while the hold remains open and the exact dispatch binding survives; otherwise preserve origin metadata and holds because no safe automatic migration is shipped"
}

verify_cleanup_receipt_base() {  # <origin-id> <dispatch-id> <hold-id>
  local origin=$1 dispatch=$2 id=$3 receipt schema phase recorded_origin recorded_dispatch recorded_hold object_path object_sha bearings_sha
  receipt=$(cleanup_receipt_path "$id")
  regular_nonsymlink_file "$receipt" \
    || fail_missing_cleanup_receipt "$origin" "$id"
  schema=$(receipt_value "$receipt" schema) || fail "captain hold $id has a malformed cleanup receipt schema"
  phase=$(receipt_value "$receipt" phase) || fail "captain hold $id has a malformed cleanup receipt phase"
  recorded_origin=$(receipt_value "$receipt" origin_id) || fail "captain hold $id has no cleanup task identity"
  recorded_dispatch=$(receipt_value "$receipt" dispatch_id) || fail "captain hold $id has no cleanup dispatch identity"
  recorded_hold=$(receipt_value "$receipt" hold_id) || fail "captain hold $id has no cleanup hold identity"
  object_path=$(receipt_value "$receipt" object_path) || fail "captain hold $id has no cleanup object path"
  object_sha=$(receipt_value "$receipt" object_sha256) || fail "captain hold $id has no cleanup object digest"
  bearings_sha=$(receipt_value "$receipt" bearings_sha256) || fail "captain hold $id has no Bearings evidence digest"
  [ "$schema" = fm-decision-hold-receipt.v1 ] || fail "captain hold $id has an unsupported cleanup receipt"
  [ "$phase" = hold ] || fail "captain hold $id cleanup receipt has the wrong phase"
  [ "$recorded_origin" = "$origin" ] || fail "captain hold $id cleanup receipt links a different task"
  [ "$recorded_dispatch" = "$dispatch" ] || fail "captain hold $id cleanup receipt links a different dispatch"
  [ "$recorded_hold" = "$id" ] || fail "captain hold $id cleanup receipt links a different hold"
  verify_origin_receipt "$origin" "$dispatch" >/dev/null
  [ "$object_path" = "$DATA/backlog.md" ] || fail "captain hold $id cleanup receipt names an unauthorized object path"
  regular_nonsymlink_file "$object_path" || fail "captain hold $id cleanup object path does not exist safely"
  digest_is_nonzero_sha256 "$object_sha" || fail "captain hold $id cleanup object digest must be nonzero sha256"
  digest_is_nonzero_sha256 "$bearings_sha" || fail "captain hold $id Bearings evidence digest must be nonzero sha256"
}

bearings_snapshot() {
  local bearings=${FM_DECISION_HOLD_BEARINGS:-$SCRIPT_DIR/fm-bearings-snapshot.sh}
  [ -x "$bearings" ] || fail "Bearings snapshot executable is unavailable: $bearings"
  command -v jq >/dev/null 2>&1 || fail "jq is required for Bearings receipt verification"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$bearings" --json --all-decisions
}

bearings_has_hold() {  # <json> <hold-id>
  printf '%s\n' "$1" | jq -e --arg id "$2" \
    '.schema == "fm-bearings.v1" and (.decisions_open | any(.id == $id and .verb == "captain-hold"))' \
    >/dev/null 2>&1
}

verify_cleanup_receipt() {  # <origin-id> <dispatch-id> <hold-id>
  local origin=$1 dispatch=$2 id=$3 receipt show recorded_sha fresh
  verify_cleanup_receipt_base "$origin" "$dispatch" "$id"
  receipt=$(cleanup_receipt_path "$id")
  show=$(task_show_durable "$id") || fail "captain hold $id cleanup object is absent, duplicated, or indeterminate"
  recorded_sha=$(receipt_value "$receipt" object_sha256) || fail "captain hold $id cleanup object digest is unavailable"
  [ "$(sha256_text "$show")" = "$recorded_sha" ] \
    || fail "captain hold $id cleanup object digest no longer matches"
  fresh=$(bearings_snapshot) || fail "could not obtain fresh Bearings evidence for $id"
  bearings_has_hold "$fresh" "$id" || fail "captain hold $id does not reappear in Bearings"
}

write_cleanup_receipt() {  # <origin-id> <dispatch-id> <hold-id> <bearings-json>
  local origin=$1 dispatch=$2 id=$3 bearings=$4 show object_sha bearings_sha receipt
  show=$(task_show_durable "$id") || fail "captain hold $id is not one durable backlog object"
  object_sha=$(sha256_text "$show")
  bearings_sha=$(sha256_text "$bearings")
  digest_is_nonzero_sha256 "$object_sha" || fail "captain hold $id produced an invalid object digest"
  digest_is_nonzero_sha256 "$bearings_sha" || fail "captain hold $id produced invalid Bearings evidence"
  receipt=$(cleanup_receipt_path "$id")
  {
    printf 'schema=fm-decision-hold-receipt.v1\n'
    printf 'phase=hold\n'
    printf 'origin_id=%s\n' "$origin"
    printf 'dispatch_id=%s\n' "$dispatch"
    printf 'hold_id=%s\n' "$id"
    printf 'object_path=%s\n' "$DATA/backlog.md"
    printf 'object_sha256=%s\n' "$object_sha"
    printf 'bearings_sha256=%s\n' "$bearings_sha"
  } | write_atomic_file "$receipt"
}

verify_resolution_receipt() {  # <origin-id> <hold-id>
  local origin=$1 id=$2 show state kind body receipt cleanup dispatch schema phase recorded_origin recorded_dispatch recorded_hold decision_path decision_sha routed_ids object_path object_sha source routed task
  show=$(task_show_durable "$id") \
    || fail "captain decision $id is absent, duplicated, or indeterminate in the live backlog and archive"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || fail "captain hold $id is unresolved"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  resolution_body_fields "$id" "$body"

  cleanup=$(cleanup_receipt_path "$id")
  regular_nonsymlink_file "$cleanup" \
    || fail_missing_cleanup_receipt "$origin" "$id"
  dispatch=$(receipt_value "$cleanup" dispatch_id) || fail "captain hold $id cleanup receipt has no dispatch link"
  verify_cleanup_receipt_base "$origin" "$dispatch" "$id"

  receipt=$(resolution_receipt_path "$id")
  regular_nonsymlink_file "$receipt" \
    || fail "historical or hand-written resolved row $id has no trusted resolution receipt; repeat the exact resolve only when the script-owned cleanup receipt and canonical decision object survive; otherwise preserve the origin and row because no safe automatic migration is shipped"
  schema=$(receipt_value "$receipt" schema) || fail "captain hold $id has a malformed resolution receipt schema"
  phase=$(receipt_value "$receipt" phase) || fail "captain hold $id has a malformed resolution receipt phase"
  recorded_origin=$(receipt_value "$receipt" origin_id) || fail "captain hold $id resolution receipt has no task link"
  recorded_dispatch=$(receipt_value "$receipt" dispatch_id) || fail "captain hold $id resolution receipt has no dispatch link"
  recorded_hold=$(receipt_value "$receipt" hold_id) || fail "captain hold $id resolution receipt has no hold link"
  decision_path=$(receipt_value "$receipt" decision_path) || fail "captain hold $id resolution receipt has no decision object path"
  decision_sha=$(receipt_value "$receipt" decision_sha256) || fail "captain hold $id resolution receipt has no decision digest"
  routed_ids=$(receipt_value "$receipt" routed_ids) || fail "captain hold $id resolution receipt has no routed task links"
  object_path=$(receipt_value "$receipt" object_path) || fail "captain hold $id resolution receipt has no row object path"
  object_sha=$(receipt_value "$receipt" object_sha256) || fail "captain hold $id resolution receipt has no row object digest"
  [ "$schema" = fm-decision-hold-receipt.v1 ] || fail "captain hold $id has an unsupported resolution receipt"
  [ "$phase" = resolved ] || fail "captain hold $id resolution receipt has the wrong phase"
  [ "$recorded_origin" = "$origin" ] || fail "captain hold $id resolution receipt links a different task"
  [ "$recorded_dispatch" = "$dispatch" ] || fail "captain hold $id resolution receipt links a different dispatch"
  [ "$recorded_hold" = "$id" ] || fail "captain hold $id resolution receipt links a different hold"
  [ "$decision_path" = "$(decision_object_path "$id")" ] \
    || fail "captain hold $id resolution receipt names an unauthorized decision object"
  regular_nonsymlink_file "$decision_path" || fail "captain hold $id decision object path does not exist safely"
  digest_is_nonzero_sha256 "$decision_sha" || fail "captain hold $id resolution receipt decision digest must be nonzero sha256"
  [ "$(sha256_file "$decision_path")" = "$decision_sha" ] || fail "captain hold $id decision object digest does not match"
  [ "$decision_sha" = "$RESOLUTION_DIGEST" ] || fail "captain hold $id row and decision object digests differ"
  [ "$routed_ids" = "$RESOLUTION_ROUTES" ] || fail "captain hold $id row and receipt routed tasks differ"
  source=$(task_row_source "$id") || fail "captain hold $id row object is no longer unique"
  [ "$object_path" = "$source" ] || fail "captain hold $id resolution receipt names the wrong row object path"
  regular_nonsymlink_file "$object_path" || fail "captain hold $id row object path does not exist safely"
  digest_is_nonzero_sha256 "$object_sha" || fail "captain hold $id row object digest must be nonzero sha256"
  [ "$(sha256_text "$show")" = "$object_sha" ] || fail "captain hold $id row object digest does not match"
  routed=$(printf '%s\n' "$routed_ids" | tr ',' ' ')
  for task in $routed; do
    validate_slug routed-task "$task"
    task_show_durable "$task" >/dev/null \
      || fail "captain hold $id routed task $task is absent, duplicated, or indeterminate"
  done
}

write_resolution_receipt() {  # <origin-id> <dispatch-id> <hold-id> <decision-path> <decision-sha> <routed-csv>
  local origin=$1 dispatch=$2 id=$3 decision_path=$4 decision_sha=$5 routed_csv=$6 show source object_sha receipt
  show=$(task_show_durable "$id") || fail "captain hold $id resolved row is absent, duplicated, or indeterminate"
  source=$(task_row_source "$id") || fail "captain hold $id resolved row has no unique object path"
  object_sha=$(sha256_text "$show")
  digest_is_nonzero_sha256 "$decision_sha" || fail "captain hold $id decision digest must be nonzero sha256"
  digest_is_nonzero_sha256 "$object_sha" || fail "captain hold $id row digest must be nonzero sha256"
  receipt=$(resolution_receipt_path "$id")
  {
    printf 'schema=fm-decision-hold-receipt.v1\n'
    printf 'phase=resolved\n'
    printf 'origin_id=%s\n' "$origin"
    printf 'dispatch_id=%s\n' "$dispatch"
    printf 'hold_id=%s\n' "$id"
    printf 'decision_path=%s\n' "$decision_path"
    printf 'decision_sha256=%s\n' "$decision_sha"
    printf 'routed_ids=%s\n' "$routed_csv"
    printf 'object_path=%s\n' "$source"
    printf 'object_sha256=%s\n' "$object_sha"
  } | write_atomic_file "$receipt"
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
  if show=$(task_show_durable "$id"); then
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
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0 dispatch='' bearings='' id
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

  dispatch=$(completion_dispatch "$origin" "$meta" "$has_meta") || return 1
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$origin" "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF

    bearings=$(bearings_snapshot) || fail "could not obtain Bearings evidence for $origin"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      id=$(hold_id "$origin" "$key")
      if ! verify_hold_resolved "$id"; then
        bearings_has_hold "$bearings" "$id" \
          || fail "captain hold $id does not reappear in Bearings"
        write_cleanup_receipt "$origin" "$dispatch" "$id" "$bearings"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

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
  local origin=${1:-} meta reviewed keys key open dispatch id
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  open=$(origin_open_decisions "$origin")
  if [ -n "$keys" ] || [ -n "$open" ]; then
    dispatch=$(meta_exact_value "$meta" endpoint_task_id) \
      || fail "origin $origin has no unique endpoint dispatch binding; preserve origin metadata and holds because no safe automatic migration is shipped"
    [ "$dispatch" = "$origin" ] || fail "origin $origin metadata links a different endpoint dispatch: $dispatch"
  fi
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      id=$(hold_id "$origin" "$key")
      if verify_hold_resolved "$id"; then
        verify_resolution_receipt "$origin" "$id"
      else
        verify_hold_active "$id"
        verify_cleanup_receipt "$origin" "$dispatch" "$id"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    id=$(hold_id "$origin" "$key")
    verify_hold_active "$id"
    verify_cleanup_receipt "$origin" "$dispatch" "$id"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_verify_resolution() {
  local origin=${1:-} key=${2:-} id
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  verify_resolution_receipt "$origin" "$id"
  printf 'verified: %s trusted resolution receipt\n' "$id"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0 cleanup dispatch decision_object
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
    hold_show=$(task_show_durable "$id") \
      || fail "captain hold $id disappeared after its durable resolution was found"
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    cleanup=$(cleanup_receipt_path "$id")
    regular_nonsymlink_file "$cleanup" || fail_missing_cleanup_receipt "$origin" "$id"
    dispatch=$(receipt_value "$cleanup" dispatch_id) \
      || fail "historical resolved row $id has no trustworthy dispatch link; preserve the origin and row because no safe automatic migration is shipped"
    verify_cleanup_receipt_base "$origin" "$dispatch" "$id"
    decision_object=$(decision_object_path "$id")
    regular_nonsymlink_file "$decision_object" \
      || fail "historical resolved row $id has no canonical decision object; preserve the origin and row because no safe automatic migration is shipped"
    [ "$(sha256_file "$decision_object")" = "$decision_digest" ] \
      || fail "captain hold $id canonical decision object does not match the requested decision"
    if [ ! -f "$(resolution_receipt_path "$id")" ]; then
      write_resolution_receipt "$origin" "$dispatch" "$id" "$decision_object" "$decision_digest" "$routed_csv"
    fi
    verify_resolution_receipt "$origin" "$id"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  cleanup=$(cleanup_receipt_path "$id")
  regular_nonsymlink_file "$cleanup" || fail_missing_cleanup_receipt "$origin" "$id"
  dispatch=$(receipt_value "$cleanup" dispatch_id) \
    || fail "captain hold $id has no trustworthy cleanup dispatch link; preserve origin metadata and holds because no safe automatic migration is shipped"
  verify_cleanup_receipt_base "$origin" "$dispatch" "$id"
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac
  decision_object=$(decision_object_path "$id")
  if [ "$resolution_recorded" = 1 ]; then
    regular_nonsymlink_file "$decision_object" \
      || fail "captain hold $id partial resolution lost its decision object"
    [ "$(sha256_file "$decision_object")" = "$decision_digest" ] \
      || fail "captain hold $id partial resolution decision object drifted"
  else
    verify_cleanup_receipt "$origin" "$dispatch" "$id"
    printf '%s' "$decision" | write_atomic_file "$decision_object"
    [ "$(sha256_file "$decision_object")" = "$decision_digest" ] \
      || fail "captain hold $id decision object digest did not stabilize"
  fi

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
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution row"
  write_resolution_receipt "$origin" "$dispatch" "$id" "$decision_object" "$decision_digest" "$routed_csv"
  verify_resolution_receipt "$origin" "$id"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  verify-resolution) shift; command_verify_resolution "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
