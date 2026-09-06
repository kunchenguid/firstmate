#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain"|"firstmate-action","summary":"...",
#     "silent":true|false,"statusEndpoint":N,"statusIdent":"..."}.
#     A wake-linked firstmate-action row carries `wake_seq`:N. Legacy rows
#     without `silent` or status provenance remain valid and are treated as
#     visible, including wake-linked rows with `wake_seq` but no provenance.
#     Every read and append validates the complete log as a gap-free sequence;
#     malformed, duplicate, or reordered rows fail closed.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as a routine merge note, persisted as a sequence-keyed visible captain
#     entry, emitted by the locked session-start replay, or silently consumed
#     there because `silent` is true. Records above the cursor are unread.
#     A captain row advances only after its matching visible entry exists in
#     Pi's session, so reload recovery is idempotent across that crash window.
#     A cursor beyond the validated store tail fails closed.
#   - Processed marker: $STATE/.branch-outcomes-processed holds the highest
#     seq whose captain rows main has ACKNOWLEDGED as processed, separately
#     from the read cursor: reading (the visible entry) is the branch's act,
#     processing (main acting on the outcome and calling its acknowledgement
#     tool) is main's. A captain row between the two markers is "unprocessed":
#     delivered and shown, not yet acted on. Routine rows never wait on this
#     marker. It only advances through an explicit sequence-bound
#     acknowledgement naming a currently unprocessed captain row at or below
#     the read cursor; a routine, unread, or already-processed target is
#     refused. It never moves past the read cursor or backwards, so an
#     unrelated or empty model answer cannot move it. An absent marker reads as
#     0 (every delivered captain row is unprocessed, the safe direction);
#     processed-init is the one-time migration that sets an absent marker to
#     the read cursor so rows delivered before the marker existed are not
#     re-presented. A present marker is validated before the migration returns,
#     and a marker ahead of the read cursor fails closed.
#   - Outcome index: $STATE/.<task>.branch-outcome-index stores one bounded
#     cache of the latest outcome's status provenance. The authoritative copy
#     is in the append-only row. $STATE/.branch-outcome-index-ready is removed
#     before append and published only after the cache update; processed-init
#     rebuilds every cache before publishing it, so interruption or upgrade
#     fails closed without making each drain scan lifetime history.
#     bin/fm-teardown.sh removes a retired task's cache with its other records,
#     and append skips the cache for a task that has neither a live meta nor a
#     status log (the outcome itself is still stored), so the branch's report
#     of a teardown it just performed leaves no index behind.
#     Main-actor drain calls processed-init under the outcome lock when that
#     ready marker is absent or invalid, on every harness; only a genuine store
#     fault keeps the lost-wake backstop skipped.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the outcome is delivered to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain|firstmate-action \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh append-action --task <id> --wake-seq <seq> \
#       --summary <text> [--wake <text>]
#     Append or recover one firstmate-action row and its per-wake marker.
#   fm-branch-outcome.sh action-prepare --seq <seq>
#     Ensure the firstmate-action marker exists and print pending|started.
#   fm-branch-outcome.sh action-status --seq <seq>
#     Print pending|started|none for a firstmate-action row.
#   fm-branch-outcome.sh action-started --seq <seq>
#     Mark the hidden main turn as started.
#   fm-branch-outcome.sh render --seq <seq>
#     Render a main-bound outcome as its operational input envelope.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh unprocessed
#     Print every captain record that is read but not yet processed (raw
#     JSONL, ascending seq). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-processed --through <seq>
#     Advance the processed marker after main acknowledged the captain rows
#     through <seq>; the target itself must be a currently unprocessed captain
#     row at or below the read cursor.
#   fm-branch-outcome.sh processed-init [--held-lock]
#     Rebuild the bounded per-task outcome indexes, then create the processed
#     marker at the current read cursor when it does not exist yet; validate a
#     present marker without changing it. --held-lock is only for a descendant
#     of the process holding $STATE/.branch-outcomes.lock (fm-wake-drain.sh may
#     run its redirected presentation body in a subshell on Bash 3.2); it skips
#     the nested acquire so drain's bounded lock wait remains the deadline.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print the leading routine unread records under a
#     labeled header into the locked startup digest, skip rows whose `silent`
#     field is true, and mark those leading routine rows read. Stop before the
#     first captain or handoff-eligible firstmate-action row because Pi's
#     sequence-keyed visible or hidden handoff must acknowledge those rows.
#     Prints nothing when nothing replayable is unread.
#     Run it only when the session holds the lock (fm-session-start.sh owns the
#     call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
PROCESSED="$STATE/.branch-outcomes-processed"
LOCK="$STATE/.branch-outcomes.lock"
ACTION_DIR="$STATE/branch-action"
MAX_SAFE_SEQ=9007199254740991
OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v1
OUTCOME_INDEX_MAX_BYTES=512
OUTCOME_INDEX_READY="$STATE/.branch-outcome-index-ready"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | unprocessed | mark-processed --through <seq> | processed-init [--held-lock] | list [--recent <n>] | startup-replay" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the outcome cursor is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the outcome cursor is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the outcome cursor is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_processed() {
  local value
  [ -e "$PROCESSED" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$PROCESSED" 2>/dev/null); then
    echo "error: refusing operation because the processed marker is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the processed marker is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the processed marker is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

last_seq() {
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  jq -Rse '
    def valid:
      type == "object"
      and (
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (
          keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
        or (
          keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake", "wake_seq"]
          and (.silent | type) == "boolean"
          and .verdict == "firstmate-action"
          and ((.wake_seq | type) == "number" and .wake_seq >= 1 and .wake_seq <= 9007199254740991 and .wake_seq == (.wake_seq | floor))
        )
        or (
          keys == ["epoch", "seq", "summary", "task", "verdict", "wake", "wake_seq"]
          and .verdict == "firstmate-action"
          and ((.wake_seq | type) == "number" and .wake_seq >= 1 and .wake_seq <= 9007199254740991 and .wake_seq == (.wake_seq | floor))
        )
        or (
          keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake", "wake_seq"]
          and (.silent | type) == "boolean"
          and .verdict == "firstmate-action"
          and ((.wake_seq | type) == "number" and .wake_seq >= 1 and .wake_seq <= 9007199254740991 and .wake_seq == (.wake_seq | floor))
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
      )
      and ((.seq | type) == "number" and .seq >= 1 and .seq <= 9007199254740991 and .seq == (.seq | floor))
      and ((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
      and ((.task | type) == "string" and (.wake | type) == "string")
      and ((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain" or .verdict == "firstmate-action"))
      and (.silent != true or .verdict == "routine");
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated outcome store")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + 1)))
      then .[-1].seq
      else error("malformed or non-sequential outcome store")
      end
  ' "$STORE" 2>/dev/null
}

record_seq() { # <jsonl-line>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | jq -er '.seq'
}

outcome_index_path() { # <task>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.branch-outcome-index' "$STATE" "$1"
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0
  size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  case "$ident" in *$'\t'*|*$'\n'*|'') return 0 ;; esac
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

write_outcome_index() { # <task> <seq> [<endpoint> <identity>]
  local task=$1 seq=$2 endpoint=${3:-$CAPTURED_STATUS_ENDPOINT} ident=${4:-$CAPTURED_STATUS_IDENT} path tmp record
  path=$(outcome_index_path "$task") || return 1
  record=$(printf '%s\t%s\t%s\t%s\n' "$OUTCOME_INDEX_VERSION" "$seq" \
    "$endpoint" "$ident") || return 1
  [ "${#record}" -le "$OUTCOME_INDEX_MAX_BYTES" ] || return 1
  tmp=$(mktemp "$STATE/.branch-outcome-index.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

publish_outcome_index_ready() { # <seq>
  local tmp
  tmp=$(mktemp "$STATE/.branch-outcome-index-ready.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OUTCOME_INDEX_READY"
}

rebuild_outcome_indexes() {
  local rows task seq epoch endpoint ident f mtime
  rm -f -- "$OUTCOME_INDEX_READY" || return 1
  [ -s "$STORE" ] || { publish_outcome_index_ready 0; return; }
  rows=$(jq -r -s '
    map(select(.task != "fleet"))
    | group_by(.task)
    | map(.[-1])[]
    | [.task, (.seq | tostring), (.epoch | tostring),
       ((.statusEndpoint // "") | tostring), (.statusIdent // "")]
    | @tsv
  ' "$STORE") || return 1
  while IFS=$(printf '\t') read -r task seq epoch endpoint ident; do
    [ -n "$task" ] || continue
    if [ -z "$endpoint" ] || [ -z "$ident" ]; then
      f="$STATE/$task.status"
      endpoint=0
      ident=-
      if [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; then
        mtime=$(_fm_status_file_mtime "$f") || mtime=
        case "$mtime" in ''|*[!0-9]*) ;;
          *)
            # Legacy rows have only whole-second epochs, so equal timestamps
            # cannot prove whether the status preceded the outcome. Leave that
            # span uncovered: migration may rarely duplicate an old handled
            # event, but it will not hide a plausibly later captain-facing one.
            if [ "$mtime" -lt "$epoch" ]; then
              capture_status_position "$task"
              endpoint=$CAPTURED_STATUS_ENDPOINT
              ident=$CAPTURED_STATUS_IDENT
            fi
            ;;
        esac
      fi
    fi
    write_outcome_index "$task" "$seq" "$endpoint" "$ident" || return 1
  done <<EOF
$rows
EOF
  publish_outcome_index_ready "$(last_seq)"
}

canonical_positive_sequence() { # <digit-string>
  local raw=$1 canonical
  case "$raw" in ''|*[!0-9]*) return 1 ;; esac
  canonical=$(printf '%s\n' "$raw" | sed 's/^0*//')
  [ -n "$canonical" ] || return 1
  printf '%s\n' "$canonical"
}

record_for_seq() { # <seq>
  local wanted=$1 line seq
  [ -s "$STORE" ] || return 1
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ "$seq" = "$wanted" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$STORE"
  return 1
}

append_record_locked() { # <task> <verdict> <summary> <wake> <silent> <seq> [<wake-seq>]
  local task=$1 verdict=$2 summary=$3 wake=$4 silent=$5 seq=$6 wake_seq=${7:-}
  capture_status_position "$task"
  rm -f -- "$OUTCOME_INDEX_READY" || return 1
  if [ "$verdict" = firstmate-action ] && [ -n "$wake_seq" ]; then
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s","wake_seq":%s}\n' \
      "$seq" "$(date +%s)" "$(json_escape "$task")" "$(json_escape "$wake")" \
      "$verdict" "$(json_escape "$summary")" "$silent" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" "$wake_seq" >> "$STORE"
  else
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
      "$seq" "$(date +%s)" "$(json_escape "$task")" "$(json_escape "$wake")" \
      "$verdict" "$(json_escape "$summary")" "$silent" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
  fi
  if { [ -e "$STATE/$task.meta" ] || [ -e "$STATE/$task.status" ]; } \
      && ! write_outcome_index "$task" "$seq"; then
    return 1
  fi
  publish_outcome_index_ready "$seq"
}

action_marker_path_for_wake() { # <wake-seq>
  local wake_seq candidate
  wake_seq=$(canonical_positive_sequence "$1") || return 1
  candidate="$ACTION_DIR/wake-$wake_seq.json"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in "$ACTION_DIR"/wake-*.json; do
    [ -f "$candidate" ] || continue
    if jq -e --arg wake_seq "$wake_seq" \
      'type == "object" and .wake_seq == ($wake_seq|tonumber)' "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s/wake-%s.json\n' "$ACTION_DIR" "$wake_seq"
}

action_marker_path_for_outcome() { # <outcome-seq>
  local outcome=$1 candidate
  [ -d "$ACTION_DIR" ] || return 1
  for candidate in "$ACTION_DIR"/wake-*.json "$ACTION_DIR"/outcome-*.json; do
    [ -f "$candidate" ] || continue
    if jq -e --argjson seq "$outcome" 'type == "object" and .outcome_seq == $seq' "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

write_action_marker() { # <path> <wake-seq-or-empty> <outcome-seq-or-empty> <state> <task> <summary> <wake>
  local path=$1 wake_seq=$2 outcome_seq=$3 marker_state=$4 task=$5 summary=$6 wake=$7 tmp
  mkdir -p "$ACTION_DIR"
  tmp=$(mktemp "$ACTION_DIR/.marker.tmp.XXXXXX")
  if [ -n "$wake_seq" ]; then
    jq -cn \
      --arg wake_seq "$wake_seq" \
      --arg task "$task" \
      --arg summary "$summary" \
      --arg wake "$wake" \
      --arg state "$marker_state" \
      --arg outcome_seq "$outcome_seq" \
      '{version:"fm-branch-action-v1",wake_seq:($wake_seq|tonumber),outcome_seq:(if $outcome_seq == "" then null else ($outcome_seq|tonumber) end),state:$state,task:$task,verdict:"firstmate-action",summary:$summary,wake:$wake,silent:false}' > "$tmp"
  else
    jq -cn \
      --arg task "$task" \
      --arg summary "$summary" \
      --arg wake "$wake" \
      --arg state "$marker_state" \
      --arg outcome_seq "$outcome_seq" \
      '{version:"fm-branch-action-v1",wake_seq:null,outcome_seq:(if $outcome_seq == "" then null else ($outcome_seq|tonumber) end),state:$state,task:$task,verdict:"firstmate-action",summary:$summary,wake:$wake,silent:false}' > "$tmp"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

update_action_marker() { # <path> <jq-filter>
  local path=$1 filter=$2 tmp
  tmp=$(mktemp "$ACTION_DIR/.marker.tmp.XXXXXX")
  jq "$filter" "$path" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

action_marker_state() { # <path>
  jq -er 'select(type == "object" and .version == "fm-branch-action-v1" and (.state == "pending" or .state == "started")) | .state' "$1"
}

find_action_record_by_wake_seq() { # <wake-seq>
  local wake_seq=$1 line seq
  [ -s "$STORE" ] || return 1
  while IFS= read -r line; do
    if printf '%s\n' "$line" | jq -e \
      --arg wake_seq "$wake_seq" \
      'type == "object" and .verdict == "firstmate-action" and .wake_seq == ($wake_seq|tonumber)' \
      >/dev/null 2>&1; then
      seq=$(record_seq "$line")
      [ -n "$seq" ] || return 1
      printf '%s\n' "$seq"
      return 0
    fi
  done < "$STORE"
  return 1
}

action_marker_for_seq() { # <outcome-seq>
  local outcome=$1 path
  path=$(action_marker_path_for_outcome "$outcome" 2>/dev/null || true)
  if [ -n "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

ensure_action_marker_for_record_locked() { # <record-line>
  local line=$1 seq task summary wake path
  seq=$(record_seq "$line") || return 1
  task=$(printf '%s\n' "$line" | jq -er '.task') || return 1
  summary=$(printf '%s\n' "$line" | jq -er '.summary') || return 1
  wake=$(printf '%s\n' "$line" | jq -er '.wake') || return 1
  path=$(action_marker_for_seq "$seq" 2>/dev/null || true)
  if [ -z "$path" ]; then
    path="$ACTION_DIR/outcome-$seq.json"
    write_action_marker "$path" "" "$seq" pending "$task" "$summary" "$wake" || return 1
  fi
  printf '%s\n' "$path"
}

reconcile_action_markers_locked() {
  local path task summary wake wake_seq seq existing
  [ -d "$ACTION_DIR" ] || return 0
  for path in "$ACTION_DIR"/wake-*.json; do
    [ -f "$path" ] || continue
    jq -e 'type == "object" and .version == "fm-branch-action-v1" and (.state == "pending" or .state == "started") and (.wake_seq | type == "number") and .wake_seq >= 1 and .wake_seq == (.wake_seq | floor) and (.outcome_seq == null or ((.outcome_seq | type == "number") and .outcome_seq >= 1 and .outcome_seq == (.outcome_seq | floor))) and .verdict == "firstmate-action" and (.task | type == "string") and (.summary | type == "string") and (.wake | type == "string")' "$path" >/dev/null 2>&1 || return 1
    wake_seq=$(jq -er '.wake_seq | tostring' "$path") || return 1
    seq=$(jq -r '.outcome_seq // empty' "$path") || return 1
    if [ -z "$seq" ]; then
      task=$(jq -er '.task' "$path") || return 1
      summary=$(jq -er '.summary' "$path") || return 1
      wake=$(jq -er '.wake' "$path") || return 1
      existing=$(find_action_record_by_wake_seq "$wake_seq" 2>/dev/null || true)
      if [ -z "$existing" ]; then
        if ! LAST_SEQ=$(last_seq); then return 1; fi
        existing=$(( LAST_SEQ + 1 ))
        append_record_locked "$task" firstmate-action "$summary" "$wake" false "$existing" "$wake_seq" || return 1
      fi
      update_action_marker "$path" ".outcome_seq = $existing" || return 1
    fi
  done
}

render_record() { # <record-line>
  local line=$1 verdict task summary body encoded encoder
  verdict=$(printf '%s\n' "$line" | jq -er '.verdict') || return 1
  case "$verdict" in
    captain)
      body='This is a supervision outcome delivered automatically by the supervision branch. It was not typed by the captain. The fleet event is already handled: do not re-drain, re-run, or acknowledge it. Do not take another fleet action from this delivery. This outcome is captain-facing: give the captain a visible response now. Use your judgment over the wording and how to incorporate it, not whether to surface it. An outcome that directly answers an explicit captain request is captain-facing, regardless of whether it is healthy, routine, measured, actionable, or requires a decision.'
      ;;
    firstmate-action)
      body='This is a supervision outcome delivered automatically by the supervision branch. It was not typed by the captain. The wake is already acknowledged: do not re-drain, re-run, or acknowledge it. The downstream authorized action is not done. Perform that action now, then report the result. Do not merely relay this worker outcome. Use the standing authority and contracted next step already in fleet context; stop only if the action reaches a genuine captain-only boundary.'
      ;;
    *) return 1 ;;
  esac
  task=$(printf '%s\n' "$line" | jq -er '.task') || return 1
  summary=$(printf '%s\n' "$line" | jq -er '.summary') || return 1
  body=$(printf '%s\n\n%s: %s' "$body" "$task" "$summary")
  encoder=${FM_OPERATIONAL_INPUT_SCRIPT-}
  [ -n "$encoder" ] || encoder="$SCRIPT_DIR/fm-operational-input.sh"
  if encoded=$(printf '%s' "$body" | "$encoder" encode branch-outcome main 2>/dev/null); then
    printf '%s\n' "$encoded"
  else
    printf '%s\n' "$body"
  fi
}

print_unread() {
  local cursor last
  cursor=$(read_cursor)
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor processed tmp
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing cursor advancement because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

write_processed() { # <seq>
  local through=$1 tmp
  tmp=$(mktemp "$STATE/.branch-outcomes-processed.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$PROCESSED"
}

# Captain rows above the processed marker and at or below the read cursor.
print_unprocessed() {
  local cursor processed last
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing read because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson processed "$processed" --argjson cursor "$cursor" \
    'select(.verdict == "captain" and .seq > $processed and .seq <= $cursor)' "$STORE"
}

# Assumes $LOCK is already held. Callers that do not already hold it use the
# processed-init command, which acquires and releases around this body.
processed_init_locked() {
  local store_last cursor_seq processed_seq
  if ! store_last=$(last_seq); then
    echo "error: refusing processed initialization because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if ! cursor_seq=$(read_cursor); then
    return 1
  fi
  if [ "$cursor_seq" -gt "$store_last" ]; then
    echo "error: refusing processed initialization because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ -e "$PROCESSED" ]; then
    if ! processed_seq=$(read_processed); then
      return 1
    fi
    if [ "$processed_seq" -gt "$cursor_seq" ]; then
      echo "error: refusing processed initialization because the processed marker is ahead of the read cursor" >&2
      return 1
    fi
  else
    write_processed "$cursor_seq" || return 1
  fi
  if ! rebuild_outcome_indexes; then
    echo "error: outcome index migration could not be completed safely" >&2
    return 1
  fi
}

held_lock_owned_by_ancestor() {
  local owner owner_pid pid parent depth=0
  case "$PPID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if [ -L "$LOCK" ]; then
    owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null) || return 1
    fm_lock_points_to_owner "$LOCK" "$owner" || return 1
  elif [ -d "$LOCK" ]; then
    owner=$LOCK
  else
    return 1
  fi
  owner_pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_pid_alive "$owner_pid" || return 1

  # Bash 3.2 keeps $$ unchanged in a redirected subshell while that subshell's
  # real pid becomes this script's parent. Walk the bounded live ancestry so
  # that legitimate drain shape is accepted without trusting an arbitrary
  # caller merely because it can name or observe the lock owner.
  pid=$PPID
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$owner_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain|firstmate-action) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
      echo "error: silent outcomes must be routine outcomes" >&2
      exit 2
    fi
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome cursor is invalid or ahead of the store" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    capture_status_position "$TASK"
    rm -f -- "$OUTCOME_INDEX_READY" || { fm_lock_release "$LOCK"; exit 1; }
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
    # A task with neither a live meta nor a status log is retired: the branch
    # reports the teardown it just performed, and writing the index here would
    # recreate the footprint teardown removed. The outcome itself is still
    # stored and delivered; only the reader-less cache is skipped.
    if { [ -e "$STATE/$TASK.meta" ] || [ -e "$STATE/$TASK.status" ]; } \
        && ! write_outcome_index "$TASK" "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    if ! publish_outcome_index_ready "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  append-action)
    TASK=''
    SUMMARY=''
    WAKE=''
    WAKE_SEQ=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --wake-seq) WAKE_SEQ=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    [ -n "$SUMMARY" ] || usage
    WAKE_SEQ=$(canonical_positive_sequence "$WAKE_SEQ") || usage
    fm_lock_acquire_wait "$LOCK"
    mkdir -p "$ACTION_DIR"
    MARKER=$(action_marker_path_for_wake "$WAKE_SEQ")
    if [ -f "$MARKER" ]; then
      if ! jq -e \
        --arg wake_seq "$WAKE_SEQ" \
        'type == "object" and .version == "fm-branch-action-v1" and .wake_seq == ($wake_seq|tonumber) and .verdict == "firstmate-action" and (.state == "pending" or .state == "started")' \
        "$MARKER" >/dev/null 2>&1; then
        fm_lock_release "$LOCK"
        echo "error: firstmate-action wake marker is invalid for the repeated wake sequence" >&2
        exit 1
      fi
      SEQ=$(jq -r '.outcome_seq // empty' "$MARKER")
      if [ -z "$SEQ" ]; then
        SEQ=$(find_action_record_by_wake_seq "$WAKE_SEQ" 2>/dev/null || true)
        if [ -z "$SEQ" ]; then
          if ! LAST_SEQ=$(last_seq); then
            fm_lock_release "$LOCK"
            echo "error: refusing action append because the outcome store has a malformed final record" >&2
            exit 1
          fi
          SEQ=$(( LAST_SEQ + 1 ))
          if ! append_record_locked "$TASK" firstmate-action "$SUMMARY" "$WAKE" false "$SEQ" "$WAKE_SEQ"; then
            fm_lock_release "$LOCK"
            exit 1
          fi
        fi
        if ! update_action_marker "$MARKER" ".outcome_seq = $SEQ"; then
          fm_lock_release "$LOCK"
          exit 1
        fi
      fi
      fm_lock_release "$LOCK"
      printf '%s\n' "$SEQ"
    else
      write_action_marker "$MARKER" "$WAKE_SEQ" "" pending "$TASK" "$SUMMARY" "$WAKE" || {
        fm_lock_release "$LOCK"
        exit 1
      }
      if ! LAST_SEQ=$(last_seq); then
        fm_lock_release "$LOCK"
        echo "error: refusing action append because the outcome store has a malformed final record" >&2
        exit 1
      fi
      SEQ=$(( LAST_SEQ + 1 ))
      if ! append_record_locked "$TASK" firstmate-action "$SUMMARY" "$WAKE" false "$SEQ" "$WAKE_SEQ"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
      if ! update_action_marker "$MARKER" ".outcome_seq = $SEQ"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
      fm_lock_release "$LOCK"
      printf '%s\n' "$SEQ"
    fi
    ;;
  action-prepare)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ] || ! printf '%s\n' "$RECORD" | jq -e '.verdict == "firstmate-action"' >/dev/null 2>&1; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    MARKER=$(ensure_action_marker_for_record_locked "$RECORD") || {
      fm_lock_release "$LOCK"
      exit 1
    }
    ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
    case "$ACTION_STATE" in pending|started) ;;
      *) fm_lock_release "$LOCK"; exit 1 ;;
    esac
    fm_lock_release "$LOCK"
    printf '%s\n' "$ACTION_STATE"
    ;;
  action-status)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    MARKER=$(action_marker_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$MARKER" ]; then
      ACTION_STATE=none
    else
      ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
      [ -n "$ACTION_STATE" ] || { fm_lock_release "$LOCK"; exit 1; }
    fi
    fm_lock_release "$LOCK"
    printf '%s\n' "$ACTION_STATE"
    ;;
  action-pending)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    reconcile_action_markers_locked || {
      fm_lock_release "$LOCK"
      exit 1
    }
    if [ -d "$ACTION_DIR" ]; then
      for MARKER in "$ACTION_DIR"/wake-*.json; do
        [ -f "$MARKER" ] || continue
        if jq -e 'type == "object" and .version == "fm-branch-action-v1" and .state == "pending" and (.wake_seq | type == "number") and .wake_seq >= 1 and .wake_seq == (.wake_seq | floor) and (.outcome_seq | type == "number") and .outcome_seq >= 1 and .outcome_seq == (.outcome_seq | floor) and .verdict == "firstmate-action" and (.task | type == "string") and (.summary | type == "string")' "$MARKER" >/dev/null 2>&1; then
          jq -c '{outcome_seq, wake_seq, task, summary}' "$MARKER"
        fi
      done
    fi
    fm_lock_release "$LOCK"
    ;;
  action-started)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    if [ "${FM_SUPERVISION_ACTOR:-}" != main ]; then
      echo "error: action-started requires the main supervision actor" >&2
      exit 6
    fi
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ] || ! printf '%s\n' "$RECORD" | jq -e '.verdict == "firstmate-action"' >/dev/null 2>&1; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    MARKER=$(ensure_action_marker_for_record_locked "$RECORD") || {
      fm_lock_release "$LOCK"
      exit 1
    }
    ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
    if [ "$ACTION_STATE" = pending ]; then
      update_action_marker "$MARKER" '.state = "started"' || {
        fm_lock_release "$LOCK"
        exit 1
      }
    elif [ "$ACTION_STATE" != started ]; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    printf 'started\n'
    ;;
  render)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ]; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! render_record "$RECORD"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    reconcile_action_markers_locked || {
      fm_lock_release "$LOCK"
      exit 1
    }
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored outcome" >&2
      exit 1
    fi
    if ! advance_cursor "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unprocessed)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unprocessed
    STATUS=$?
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-processed)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is ahead of the read cursor" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement beyond the read cursor ($CURSOR_SEQ)" >&2
      exit 1
    fi
    if [ "$THROUGH" -le "$PROCESSED_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is already processed" >&2
      exit 1
    fi
    VERDICT=$(jq -r --argjson through "$THROUGH" 'select(.seq == $through) | .verdict' "$STORE")
    if [ "$VERDICT" != captain ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is not an unprocessed captain outcome" >&2
      exit 1
    fi
    write_processed "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  processed-init)
    HELD_LOCK=0
    if [ "${1:-}" = --held-lock ]; then
      HELD_LOCK=1
      shift
    fi
    [ "$#" -eq 0 ] || usage
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_acquire_wait "$LOCK"
    elif ! held_lock_owned_by_ancestor; then
      echo "error: --held-lock requires an ancestor process to own the outcome lock" >&2
      exit 1
    fi
    if ! processed_init_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_release "$LOCK"
    fi
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ -s "$STORE" ]; then
      tail -n "$RECENT" "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    reconcile_action_markers_locked || {
      fm_lock_release "$LOCK"
      exit 1
    }
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      REPLAYABLE=$(printf '%s\n' "$UNREAD" | jq -sc '
        . as $rows
        | ($rows | to_entries
           | map(select(.value.verdict == "captain" or (.value.verdict == "firstmate-action" and .value.wake_seq != null)))
           | .[0].key) as $barrier
        | $rows[0:($barrier // length)][]
      ')
      VISIBLE=$(printf '%s\n' "$REPLAYABLE" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$REPLAYABLE" | tail -n 1)")
      if [ -n "$LAST" ] && ! advance_cursor "$LAST"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
