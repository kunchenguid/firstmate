#!/usr/bin/env bash
# fm-suggestions.sh - inspect and clean up the legacy suggested-tasks list.
#
# This script is the only writer of the legacy stores in the home's data
# directory (FM_DATA_OVERRIDE, else $FM_HOME/data):
#   suggestions.jsonl             existing suggestions not yet archived
#   suggestions-not-picked.jsonl  the "not picked" archive; records are never deleted,
#                                 and leave it only when `restore` moves one back
# Nothing dispatches from either file, and neither is a tasks-axi state.
# .agents/skills/scout-completion/SKILL.md owns the current close-time rule.
#
# Usage:
#   fm-suggestions.sh summary [--json]
#   fm-suggestions.sh list --json
#   fm-suggestions.sh digest [--json]
#   fm-suggestions.sh pick <suggestion-id>... [--task-kind <kind>]
#   fm-suggestions.sh bundle <suggestion-id>... --into <suggestion-or-task-id>
#   fm-suggestions.sh drop <suggestion-id>...
#   fm-suggestions.sh restore <suggestion-id>...
#   fm-suggestions.sh expire
#   fm-suggestions.sh archive [--json]
#
# Recorded outcomes (the `outcome` field):
#   suggested  waiting in the list
#   picked     the captain picked it; `target` is the backlog row it filed
#   bundled    folded into `target`
#   repeat     duplicate of `target`, a suggestion or an open backlog row
#   expired    went unpicked for FM_SUGGESTIONS_EXPIRE_DAYS (default 30) days
#   escalated  sent to the captain; `target` is the captain-held row
#   dropped    the captain removed it from the list (bin/fm-forget.sh)
#
# add        Refused: new worker follow-ups are not logged.
# summary    Read-only and lock-free, so bin/fm-bearings-snapshot.sh can call it.
#            Past-due records already count as gone even before `expire` moves them.
#            --json prints {count, oldest_age_days, line}; plain prints the line,
#            which is empty when nothing is waiting.
# list       Read-only and lock-free: the waiting suggestions as a JSON array,
#            oldest first, each with age_days; past-due records are left out.
# digest     Expires past-due records, then lists what is waiting, oldest first.
# pick       Files a backlog row for each id with a stable row id, so a retry after
#            a partial failure reuses the row. Works on an archived record too.
#            Does not start the row. Prints `picked <id> <task-id>`.
#            Default task kind: scout for question and research, otherwise ship.
# bundle     Records each id as bundled into the target, which must be a waiting
#            suggestion or an open backlog row.
# drop       Moves each waiting suggestion to the archive as `dropped`. Prints
#            `dropped <id> <title>`; anything not waiting is refused.
# restore    Moves each dropped record back to the list as waiting, its 30 days
#            starting again. Prints `restored <id>`; any other record is refused.
# expire     Moves past-due records to the archive. Idempotent, also after a crash
#            between the archive append and the list rewrite.
# archive    Lists the "not picked" archive.
#
# Environment: FM_SUGGESTIONS_NOW (epoch override), FM_SUGGESTIONS_EXPIRE_DAYS.
# Exit: 0 ok, 1 refused or failed, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LIST="$DATA/suggestions.jsonl"
ARCHIVE="$DATA/suggestions-not-picked.jsonl"
LOCK="$DATA/.suggestions.lock"
NOW="${FM_SUGGESTIONS_NOW:-$(date +%s)}"
EXPIRE_DAYS="${FM_SUGGESTIONS_EXPIRE_DAYS:-30}"
LOCK_HELD=0

die() { printf 'fm-suggestions: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq not found"; }
case "$NOW" in ''|*[!0-9]*) die "FM_SUGGESTIONS_NOW must be an epoch" 2 ;; esac
case "$EXPIRE_DAYS" in ''|*[!0-9]*) die "FM_SUGGESTIONS_EXPIRE_DAYS must be a whole number" 2 ;; esac

# shellcheck disable=SC2016
JQ_DEFS='
  def age_days($now): (($now - .filed_at) / 86400 | floor);
  def past_due($now; $days): .outcome == "suggested" and ($now - .filed_at) >= ($days * 86400);
'

release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null
  LOCK_HELD=0
}

# A directory lock, because flock is absent on macOS. A holder that died is
# reclaimed by renaming its lock first, so two waiters cannot both remove it.
acquire_lock() {
  local tries=0 holder stale
  mkdir -p "$DATA" || die "cannot create $DATA"
  until mkdir "$LOCK" 2>/dev/null; do
    holder=$(cat "$LOCK/pid" 2>/dev/null) || holder=
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      stale="$LOCK.stale.$$"
      if mv "$LOCK" "$stale" 2>/dev/null; then
        rm -f "$stale/pid"
        rmdir "$stale" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 150 ] || die "timed out waiting for $LOCK"
    sleep 0.2
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  LOCK_HELD=1
  trap release_lock EXIT
}

# One JSON array of a store's records. An unreadable store refuses, because a
# rewrite built from a partial read would delete what it could not parse.
read_store() {  # <file>
  [ -s "$1" ] || { printf '[]\n'; return 0; }
  jq -s -c '.' "$1" 2>/dev/null || die "cannot parse $1; refusing to read or rewrite it"
}

write_store() {  # <file> <json-array>
  local tmp
  case "$2" in '['*) ;; *) die "refusing to rewrite $1 from an unreadable state" ;; esac
  tmp=$(mktemp "$1.XXXXXX") || die "cannot write beside $1"
  if ! printf '%s' "$2" | jq -c '.[]' > "$tmp" || ! mv "$tmp" "$1"; then
    rm -f "$tmp"
    die "cannot write $1"
  fi
}

# Open backlog rows as a JSON array of {id, title, body}. tasks-axi lists rows as
# TOON, whose quoted cells are JSON strings and whose other cells have no comma.
open_rows() {
  local listing
  listing=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --fields body 2>/dev/null) || return 1
  case "$listing" in count:*|tasks*) ;; *) return 1 ;; esac
  printf '%s\n' "$listing" | jq -R -s -c '
    [ split("\n")[]
      | select(test("^  [A-Za-z0-9._-]+,"))
      | [ ltrimstr("  ")
          | match("(?:^|,)(\"(?:[^\"\\\\]|\\\\.)*\"|[^,]*)"; "g").captures[0].string
          | if startswith("\"") then fromjson else . end ]
      | select(.[1] != "done")
      | {id:.[0], title:.[4], body:(.[5] // "")} ]'
}

# A readable, stable id for a row filed from a suggestion.
row_id_for() {  # <suggestion-id> <title>
  local slug
  slug=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40)
  slug=${slug#-}
  slug=${slug%-}
  printf '%s%s\n' "${slug:+$slug-}" "${1#sg-}"
}

# Move past-due records to the archive. The append comes first and skips ids the
# archive already holds, so a crash before the rewrite converges on the next run.
do_expire() {
  local list archive due merged
  list=$(read_store "$LIST") || exit 1
  due=$(jq -c --argjson now "$NOW" --argjson days "$EXPIRE_DAYS" "$JQ_DEFS"'
    [ .[] | select(past_due($now; $days)) | .outcome = "expired" | .resolved_at = $now ]' <<<"$list")
  [ "$due" != "[]" ] || { printf '0\n'; return 0; }
  archive=$(read_store "$ARCHIVE") || exit 1
  merged=$(jq -c --slurpfile due <(printf '%s' "$due") '$due[0] as $due | . as $old
    | ($old | map(.id)) as $ids
    | $old + [ $due[] | select(.id as $id | $ids | index($id) | not) ]' <<<"$archive")
  write_store "$ARCHIVE" "$merged"
  write_store "$LIST" "$(jq -c --slurpfile due <(printf '%s' "$due") \
    '$due[0] as $due | ($due | map(.id)) as $ids | [ .[] | select(.id as $id | $ids | index($id) | not) ]' <<<"$list")"
  jq 'length' <<<"$due"
}

cmd_summary() {
  local json=0 list
  case "${1-}" in --json) json=1 ;; '') ;; *) die "summary: unknown argument $1" 2 ;; esac
  list=$(read_store "$LIST") || exit 1
  jq --argjson now "$NOW" --argjson days "$EXPIRE_DAYS" --argjson json "$json" "$JQ_DEFS"'
    [ .[] | select(.outcome == "suggested" and (past_due($now; $days) | not)) ] as $open
    | ($open | length) as $n
    | (if $n == 0 then null else ($open | map(age_days($now)) | max) end) as $oldest
    | (if $n == 0 then "" else
         "\($n) suggested task\(if $n == 1 then "" else "s" end), oldest \($oldest)d" end) as $line
    | if $json == 1 then {count:$n, oldest_age_days:$oldest, line:$line} else $line end' <<<"$list" \
    | if [ "$json" = 1 ]; then cat; else jq -r 'select(. != "")'; fi
}

cmd_digest() {
  local json=0 list
  case "${1-}" in --json) json=1 ;; '') ;; *) die "digest: unknown argument $1" 2 ;; esac
  acquire_lock
  do_expire >/dev/null
  release_lock
  list=$(read_store "$LIST") || exit 1
  if [ "$json" = 1 ]; then
    jq --argjson now "$NOW" "$JQ_DEFS"'
      [ .[] | select(.outcome == "suggested") | . + {age_days:age_days($now)} ] | sort_by(.filed_at)' <<<"$list"
    return 0
  fi
  cmd_summary
  jq -r --argjson now "$NOW" "$JQ_DEFS"'
    [ .[] | select(.outcome == "suggested") ] | sort_by(.filed_at)[]
    | "- \(.id) [\(age_days($now))d\(if .repo != "" then ", " + .repo else "" end)\(if .kind != "" then ", " + .kind else "" end)\(if .size != "" then ", " + .size else "" end)] \(.title)"
      + (if .file_line != "" then " (\(.file_line))" else "" end)
      + (if .risk != "" then " - risk: \(.risk)" else "" end)
      + (if .seen > 1 then " - seen \(.seen) times" else "" end)
      + (if .recommend != "" then " - recommend \(.recommend)" else "" end)' <<<"$list"
}

cmd_pick() {
  local ids=() task_kind=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-kind) [ $# -ge 2 ] || die "--task-kind needs a value" 2; task_kind=$2; shift 2 ;;
      -*) die "pick: unknown argument $1" 2 ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ "${#ids[@]}" -gt 0 ] || die "pick: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local id status=0
  for id in "${ids[@]}"; do
    pick_one "$id" "$task_kind" || status=1
  done
  return "$status"
}

pick_one() {  # <id> <task-kind-or-empty>
  local id=$1 kind=$2 store=$LIST content record outcome row title rows body
  content=$(read_store "$store") || exit 1
  record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$content")
  if [ -z "$record" ]; then
    store=$ARCHIVE
    content=$(read_store "$store") || exit 1
    record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id)) // empty' <<<"$content")
  fi
  [ -n "$record" ] || { printf 'fm-suggestions: no suggestion %s\n' "$id" >&2; return 1; }
  outcome=$(jq -r .outcome <<<"$record")
  case "$outcome" in
    picked) printf 'picked %s %s\n' "$id" "$(jq -r .target <<<"$record")"; return 0 ;;
    suggested|expired|dropped) ;;
    *) printf 'fm-suggestions: %s is already %s (%s)\n' "$id" "$outcome" "$(jq -r '.target // "-"' <<<"$record")" >&2; return 1 ;;
  esac
  title=$(jq -r .title <<<"$record")
  row=$(row_id_for "$id" "$title")
  rows=$(open_rows) || { printf 'fm-suggestions: cannot read the backlog; %s not picked\n' "$id" >&2; return 1; }
  if ! jq -e --arg row "$row" 'any(.[]; .id == $row)' <<<"$rows" >/dev/null; then
    [ -n "$kind" ] || case "$(jq -r .kind <<<"$record")" in
      question|research) kind=scout ;;
      *) kind=ship ;;
    esac
    body=$(jq -r '"Picked from suggestion \(.id), a follow-up of \(.origin)."
      + (if .file_line != "" then "\nWhere: \(.file_line)" else "" end)
      + (if .size != "" then "\nSize: \(.size)" else "" end)
      + (if .kind != "" then "\nKind: \(.kind)" else "" end)
      + (if .risk != "" then "\nRisk if ignored: \(.risk)" else "" end)' <<<"$record")
    local repo
    repo=$(jq -r .repo <<<"$record")
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "$row" "$title" --kind "$kind" ${repo:+--repo "$repo"} --body "$body" >/dev/null \
      || { printf 'fm-suggestions: filing a row for %s failed\n' "$id" >&2; return 1; }
  fi
  write_store "$store" "$(jq -c --arg id "$id" --arg row "$row" --argjson now "$NOW" '
    map(if .id == $id then .outcome = "picked" | .target = $row | .resolved_at = $now else . end)' <<<"$content")"
  printf 'picked %s %s\n' "$id" "$row"
}

cmd_bundle() {
  local ids=() into=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --into) [ $# -ge 2 ] || die "--into needs a value" 2; into=$2; shift 2 ;;
      -*) die "bundle: unknown argument $1" 2 ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [ -n "$into" ] || die "bundle: --into is required" 2
  [ "${#ids[@]}" -gt 0 ] || die "bundle: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local list rows id
  list=$(read_store "$LIST") || exit 1
  if ! jq -e --arg t "$into" 'any(.[]; .id == $t and .outcome == "suggested")' <<<"$list" >/dev/null; then
    rows=$(open_rows) || die "cannot read the backlog to verify $into"
    jq -e --arg t "$into" 'any(.[]; .id == $t)' <<<"$rows" >/dev/null \
      || die "bundle target $into is neither a waiting suggestion nor an open backlog row"
  fi
  for id in "${ids[@]}"; do
    [ "$id" != "$into" ] || die "cannot bundle $id into itself"
    jq -e --arg id "$id" 'any(.[]; .id == $id and .outcome == "suggested")' <<<"$list" >/dev/null \
      || die "$id is not a waiting suggestion; nothing bundled"
    list=$(jq -c --arg id "$id" --arg t "$into" --argjson now "$NOW" '
      map(if .id == $id then .outcome = "bundled" | .target = $t | .resolved_at = $now else . end)' <<<"$list")
  done
  write_store "$LIST" "$list"
  printf 'bundled %s into %s\n' "${ids[*]}" "$into"
}

cmd_list() {
  local list
  [ "${1-}" = --json ] && [ $# -eq 1 ] || die "list: use list --json" 2
  list=$(read_store "$LIST") || exit 1
  jq --argjson now "$NOW" --argjson days "$EXPIRE_DAYS" "$JQ_DEFS"'
    [ .[] | select(.outcome == "suggested" and (past_due($now; $days) | not)) | . + {age_days:age_days($now)} ]
    | sort_by(.filed_at)' <<<"$list"
}

# Waiting records move to the archive as dropped; the append skips ids the
# archive already holds, so a crash before the list rewrite converges.
cmd_drop() {
  [ $# -gt 0 ] || die "drop: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local list archive id status=0 record
  list=$(read_store "$LIST") || exit 1
  archive=$(read_store "$ARCHIVE") || exit 1
  for id in "$@"; do
    record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id and .outcome == "suggested")) // empty' <<<"$list")
    if [ -z "$record" ]; then
      printf 'fm-suggestions: %s is not a waiting suggestion; not dropped\n' "$id" >&2
      status=1
      continue
    fi
    record=$(jq -c --argjson now "$NOW" '.outcome = "dropped" | .resolved_at = $now' <<<"$record")
    archive=$(jq -c --slurpfile r <(printf '%s' "$record") '$r[0] as $r | if any(.[]; .id == $r.id) then . else . + [$r] end' <<<"$archive")
    write_store "$ARCHIVE" "$archive"
    list=$(jq -c --arg id "$id" '[ .[] | select(.id != $id) ]' <<<"$list")
    write_store "$LIST" "$list"
    printf 'dropped %s %s\n' "$id" "$(jq -r .title <<<"$record")"
  done
  return "$status"
}

# A dropped record goes back to the list; the list append comes first and skips
# ids it already holds, so a crash before the archive rewrite converges.
cmd_restore() {
  [ $# -gt 0 ] || die "restore: name at least one suggestion id" 2
  acquire_lock
  do_expire >/dev/null
  local list archive id status=0 record
  list=$(read_store "$LIST") || exit 1
  archive=$(read_store "$ARCHIVE") || exit 1
  for id in "$@"; do
    record=$(jq -c --arg id "$id" 'first(.[] | select(.id == $id and .outcome == "dropped")) // empty' <<<"$archive")
    if [ -z "$record" ]; then
      if jq -e --arg id "$id" 'any(.[]; .id == $id and .outcome == "suggested")' <<<"$list" >/dev/null; then
        printf 'restored %s\n' "$id"
        continue
      fi
      printf 'fm-suggestions: %s is not a dropped suggestion; not restored\n' "$id" >&2
      status=1
      continue
    fi
    record=$(jq -c --argjson now "$NOW" '.outcome = "suggested" | .resolved_at = null | .filed_at = $now' <<<"$record")
    list=$(jq -c --slurpfile r <(printf '%s' "$record") '$r[0] as $r | if any(.[]; .id == $r.id) then . else . + [$r] end' <<<"$list")
    write_store "$LIST" "$list"
    archive=$(jq -c --arg id "$id" '[ .[] | select(.id != $id) ]' <<<"$archive")
    write_store "$ARCHIVE" "$archive"
    printf 'restored %s\n' "$id"
  done
  return "$status"
}

cmd_expire() {
  [ $# -eq 0 ] || die "expire: takes no arguments" 2
  acquire_lock
  local moved
  moved=$(do_expire) || exit 1
  printf 'expired %s\n' "$moved"
}

cmd_archive() {
  local json=0 archive
  case "${1-}" in --json) json=1 ;; '') ;; *) die "archive: unknown argument $1" 2 ;; esac
  archive=$(read_store "$ARCHIVE") || exit 1
  if [ "$json" = 1 ]; then
    jq . <<<"$archive"
  else
    jq -r '.[] | "- \(.id) [\(.outcome)] \(.title)" + (if .target then " -> \(.target)" else "" end)' <<<"$archive"
  fi
}

command=${1-}
[ $# -eq 0 ] || shift
case "$command" in summary|list|digest|pick|bundle|drop|restore|expire|archive) require_jq ;; esac
case "$command" in
  add) die "follow-ups belong only in the done report; firstmate starts a new task now or discards them at close. No suggestions are recorded." ;;
  summary) cmd_summary "$@" ;;
  list) cmd_list "$@" ;;
  digest) cmd_digest "$@" ;;
  pick) cmd_pick "$@" ;;
  bundle) cmd_bundle "$@" ;;
  drop) cmd_drop "$@" ;;
  restore) cmd_restore "$@" ;;
  expire) cmd_expire "$@" ;;
  archive) cmd_archive "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command $command" 2 ;;
esac
