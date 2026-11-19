#!/usr/bin/env bash
# Fork-reduction regression coverage for bin/fm-fleet-snapshot.sh helpers:
# the meta cache, fork-free line readers, the status-event parts producer, the
# bash open-decision predicates, and _snapshot_wait_one. Each helper replaced a
# per-task fork chain; these pin the observable behavior that chain produced.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-fork-reduction)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The status-line verb/note/epoch readers status_event_json leans on.
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

# Extract function bodies from the snapshot script for direct exercise.
# Multiple names are concatenated with the newline separators sed already
# prints between them (a single trailing newline is stripped by command
# substitution, which is harmless only at the very end - a naive
# "$(f1)$(f2)" would fuse the bodies as `}next() {` and fail to parse).
snapshot_fns() {  # <name>...
  local name
  for name in "$@"; do
    sed -n "/^$name() {/,/^}/p" "$SNAPSHOT"
  done
}

# ---- meta_value (cache) keeps fm_meta_get's last-key-wins semantics ---------
test_meta_value_last_wins() {
  eval "$(snapshot_fns _meta_cache_load meta_value)"
  _SNAPSHOT_META_CACHE_FILE=
  declare -A _SNAPSHOT_META_CACHE=()
  local meta=$TMP_ROOT/dup.meta
  printf 'kind=scout\nworktree=/a\nkind=ship\nhome=\nhome=/b\n' > "$meta"
  [ "$(meta_value "$meta" kind)" = ship ] || fail "meta_value: last kind= must win"
  [ "$(meta_value "$meta" home)" = "/b" ] || fail "meta_value: last home= must win (empty value must not)"
  [ "$(meta_value "$meta" absent)" = "" ] || fail "meta_value: missing key must read empty"
  # A value containing the key prefix or equals signs must survive intact.
  printf 'x=a=b\nc=prefix=x=\n' > "$meta"
  [ "$(meta_value "$meta" c)" = 'prefix=x=' ] || fail "meta_value: equals in value must be kept"
  # Switching files must reload: the cache holds only the latest file.
  printf 'k=two\n' > "$TMP_ROOT/second.meta"
  [ "$(meta_value "$TMP_ROOT/second.meta" k)" = two ] || fail "meta_value: second file must load"
  [ "$(meta_value "$meta" x)" = 'a=b' ] || fail "meta_value: switching back must reload the first file"
  [ "$(meta_value "$TMP_ROOT/absent.meta" k)" = "" ] || fail "meta_value: absent file must read empty"
  pass "meta_value: last-key-wins, equals-safe, one-file cache reload"
}

# ---- last_nonempty_line matches the old grep|tail contract -------------------
test_last_nonempty_line_contract() {
  eval "$(snapshot_fns last_nonempty_line)"
  local log=$TMP_ROOT/status.log out
  printf 'working: one\n\n   \t \r\ndone: two\n' > "$log"
  out=$(last_nonempty_line "$log") || fail "last_nonempty_line: must succeed on a normal file"
  [ "$out" = 'done: two' ] || fail "last_nonempty_line: must skip blank lines, got: $out"
  # Trailing blank lines after the last content line stay skipped.
  printf 'only\n\n\n' > "$log"
  [ "$(last_nonempty_line "$log")" = 'only' ] || fail "last_nonempty_line: trailing blanks must be skipped"
  # Only-blank file: success with empty output, like grep|tail printed nothing.
  printf ' \t \n\n' > "$log"
  out=$(last_nonempty_line "$log" | od -c | head -1)
  [ "$(last_nonempty_line "$log")" = '' ] || fail "last_nonempty_line: blank-only file must print nothing"
  last_nonempty_line "$log" || fail "last_nonempty_line: blank-only file must exit 0"
  # Missing file: the guard's rc 1, as before.
  last_nonempty_line "$TMP_ROOT/nope.log" 2>/dev/null && fail "last_nonempty_line: missing file must exit 1"
  pass "last_nonempty_line: last non-blank line, blank/missing contracts"
}

# ---- first_pr_url_in_file keeps first-match-only ------------------------------
test_first_pr_url_first_match() {
  eval "$(snapshot_fns first_pr_url_in_file)"
  local log=$TMP_ROOT/pr.log
  printf 'see https://github.com/x/y/pull/1 and https://github.com/x/y/pull/2\nlater https://github.com/a/b/pull/9\n' > "$log"
  [ "$(first_pr_url_in_file "$log")" = 'https://github.com/x/y/pull/1' ] \
    || fail "first_pr_url_in_file: must print only the first match"
  first_pr_url_in_file "$TMP_ROOT/nope.log" 2>/dev/null && fail "first_pr_url_in_file: missing file must exit 1"
  printf 'no urls here\n' > "$log"
  first_pr_url_in_file "$log" 2>/dev/null && fail "first_pr_url_in_file: no match must exit 1"
  pass "first_pr_url_in_file: first match only, miss contracts"
}

# ---- status_event_json parts reconstruct the exact event object --------------
test_status_event_parts_build_the_event_object() {
  eval "$(snapshot_fns last_nonempty_line status_event_json)"
  # shellcheck disable=SC2034  # consumed by the eval'd status_event_json
  SNAPSHOT_EPOCH=1783665600
  local log=$TMP_ROOT/event.status contract out
  contract=$TMP_ROOT/state/task.status
  mkdir -p "$(dirname "$contract")"
  printf 'needs-decision: choose a shape\n' > "$log"
  printf 'working [at=1783662000]: mid turn\n\n' > "$log"
  local present raw verb note age path
  present='' raw='' verb='' note='' age='' path=''
  while IFS= read -r part; do
    case "$part" in
      present=*) present=${part#present=} ;;
      raw=*) raw=${part#raw=} ;;
      verb=*) verb=${part#verb=} ;;
      note=*) note=${part#note=} ;;
      age=*) age=${part#age=} ;;
      path=*) path=${part#path=} ;;
    esac
  done <<EOF
$(status_event_json "$log" "$contract")
EOF
  local rebuilt expected
  rebuilt=$(jq -cn --arg path "$path" --argjson present "$(bool_ref "$present")" \
    --arg raw "$raw" --arg verb "$verb" --arg note "$note" --argjson age "$age" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw,age_seconds:$age}}')
  # The reference object the old per-task jq -n call printed from the same inputs.
  expected=$(jq -cn --arg path "$contract" --argjson present true \
    --arg raw 'working [at=1783662000]: mid turn' \
    --arg verb working --arg note 'mid turn' --argjson age 3600 \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw,age_seconds:$age}}')
  [ "$(jq -Sc . <<<"$rebuilt")" = "$(jq -Sc . <<<"$expected")" ] \
    || fail "status_event_json parts must rebuild the event object exactly: $rebuilt"
  # Absent log: present=0, null age, empty text fields, contract path kept.
  while IFS= read -r part; do
    case "$part" in
      present=*) present=${part#present=} ;;
      raw=*) raw=${part#raw=} ;;
      verb=*) verb=${part#verb=} ;;
      note=*) note=${part#note=} ;;
      age=*) age=${part#age=} ;;
      path=*) path=${part#path=} ;;
    esac
  done <<EOF
$(status_event_json "$TMP_ROOT/nope.status" "$contract")
EOF
  [ "$present$raw$verb$note" = '0' ] || fail "absent status must read present=0 with empty fields"
  [ "$age" = null ] || fail "absent status must read age=null"
  [ "$path" = "$contract" ] || fail "absent status must keep the contract path"
  pass "status_event_json: parts rebuild the exact event object, absent-log contract"
}

bool_ref() { if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi; }

# ---- bash open-decision predicates match the jq any() scans ------------------
test_open_decision_predicates_match_jq() {
  # Same fold shapes status_open_decisions produces: key<TAB>verb<TAB>summary.
  local cases tsv pending blocked jq_pending jq_blocked
  cases=(
    $'k1\tneeds-decision\tchoose a shape'
    $'k2\tblocked\twaiting on service'
    $'k3\tworking\tmid turn'
    ''
    $'no-tabs-at-all'
    $'one\ttab only'
    $'k4\tneeds-decision later\tsummary says needs-decision in prose'
    $'k5\tblocked\ta\ttabbed\tsummary'
  )
  tsv=$(printf '%s\n' "${cases[@]}")
  fold_predicates() {
    local pending=0 blocked=0 line verb rest
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *$'\t'*$'\t'*)
          rest=${line#*$'\t'}
          verb=${rest%%$'\t'*}
          [ "$verb" = needs-decision ] && pending=1
          [ "$verb" = blocked ] && blocked=1
          ;;
      esac
    done <<EOF
$tsv
EOF
    printf '%s %s' "$pending" "$blocked"
  }
  read -r pending blocked <<< "$(fold_predicates)"
  jq_pending=$(jq -R -s '[ splits("\n") | select(length > 0)
      | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
      | select(. != null) ] | if any(.[]; .verb == "needs-decision") then 1 else 0 end' <<< "$tsv")
  jq_blocked=$(jq -R -s '[ splits("\n") | select(length > 0)
      | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
      | select(. != null) ] | if any(.[]; .verb == "blocked") then 1 else 0 end' <<< "$tsv")
  [ "$pending" = "$jq_pending" ] || fail "pending predicate ($pending) must match jq ($jq_pending)"
  [ "$blocked" = "$jq_blocked" ] || fail "blocked predicate ($blocked) must match jq ($jq_blocked)"
  [ "$pending" = 1 ] || fail "a needs-decision verb line must set pending"
  [ "$blocked" = 1 ] || fail "a blocked verb line must set blocked"
  pass "open-decision predicates: two-tab membership and verb match jq any()"
}

# ---- _snapshot_wait_one keeps exit statuses readable by pid ------------------
test_snapshot_wait_one_preserves_status() {
  eval "$(snapshot_fns _snapshot_wait_one)"
  local pid st
  (exit 7) & pid=$!
  _snapshot_wait_one
  wait "$pid"; st=$?
  [ "$st" = 7 ] || fail "_snapshot_wait_one must not consume a job's exit status (got $st)"
  # A second waiter after the job already exited still sees the same status.
  (exit 3) & pid=$!
  sleep 0.3
  _snapshot_wait_one
  wait "$pid"; st=$?
  [ "$st" = 3 ] || fail "_snapshot_wait_one must keep an exited job's status readable (got $st)"
  pass "_snapshot_wait_one: wait-by-pid status stays readable"
}

# ---- basename-free id expansion in the manifest loop --------------------------
test_manifest_id_expansion() {
  local meta=$TMP_ROOT/deep/nested/task-x.meta id
  mkdir -p "$(dirname "$meta")"
  : > "$meta"
  id=${meta##*/}
  id=${id%.meta}
  [ "$id" = task-x ] || fail "id expansion must strip dir and .meta, got $id"
  pass "id expansion strips directory and .meta suffix"
}

test_meta_value_last_wins
test_last_nonempty_line_contract
test_first_pr_url_first_match
test_status_event_parts_build_the_event_object
test_open_decision_predicates_match_jq
test_snapshot_wait_one_preserves_status
test_manifest_id_expansion
