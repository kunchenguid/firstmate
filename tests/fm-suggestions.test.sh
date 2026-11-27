#!/usr/bin/env bash
# New follow-ups are refused without writing; legacy suggestions stay readable,
# expirable, droppable and pickable in a throwaway home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUGGESTIONS="$ROOT/bin/fm-suggestions.sh"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-suggestions)
DAY=86400
T0=1800000000

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# Runs the command in <home> with the clock at T0 plus <days>.
at() {  # <home> <days> <args...>
  local home=$1 days=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SUGGESTIONS_NOW=$((T0 + days * DAY)) "$SUGGESTIONS" "$@"
}

tasks() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$TASKS" "$@"
}

row_count() {  # <home>
  tasks "$1" list | sed -n 's/^count: //p'
}

seed_legacy() {  # <home> <days> <id> <title> [jq filter]
  local home=$1 days=$2 id=$3 title=$4 filter=${5:-.}
  jq -cn --arg id "$id" --arg title "$title" --argjson filed "$((T0 + days * DAY))" '
    {id:$id, origin:"scout-a", item:1, title:$title, file_line:"", size:"", kind:"", risk:"",
     repo:"", recommend:"", filed_at:$filed, resolved_at:null, outcome:"suggested", target:null, seen:1}
    | '"$filter" >> "$home/data/suggestions.jsonl" || fail "legacy fixture could not be seeded"
}

test_add_refuses_without_writing() {
  local home out
  home=$(make_home refuses)
  if out=$(at "$home" 0 add --origin ship-a --item 1 --title "New lead" 2>&1); then
    fail "add accepted a new follow-up"
  fi
  assert_contains "$out" "follow-ups belong only in the done report" "refusal did not explain the new rule"
  assert_contains "$out" "at close" "refusal did not name the decision point"
  assert_absent "$home/data/suggestions.jsonl" "add created a suggestions store"
  assert_absent "$home/data/suggestions-not-picked.jsonl" "add created an archive"

  seed_legacy "$home" 0 sg-00000001 "Old lead"
  cp "$home/data/suggestions.jsonl" "$home/before.jsonl"
  if out=$(at "$home" 31 add --origin ship-a --item 2 --title "Urgent lead" --hold --risk "security: urgent" 2>&1); then
    fail "add accepted its former escalation flags"
  fi
  assert_contains "$out" "follow-ups belong only in the done report" "urgent refusal took a different path"
  cmp -s "$home/before.jsonl" "$home/data/suggestions.jsonl" || fail "add changed the legacy store"
  assert_absent "$home/data/suggestions-not-picked.jsonl" "add expired a legacy suggestion"
  assert_equals "0" "$(row_count "$home")" "add filed a backlog row"
  pass "add refuses new follow-ups without modifying the store or backlog"
}

test_an_empty_list_reports_nothing() {
  local home
  home=$(make_home empty)
  assert_equals "" "$(at "$home" 0 summary)" "an empty list printed a line"
  assert_equals "0" "$(at "$home" 0 summary --json | jq '.count')" "an empty list had a count"
  assert_equals "null" "$(at "$home" 0 summary --json | jq '.oldest_age_days')" "an empty list had an age"
  at "$home" 0 digest > "$home/digest.out" || fail "empty digest failed"
  [ ! -s "$home/digest.out" ] || fail "empty digest printed output"
  pass "an empty list reports no digest, a zero count and no age"
}

test_large_stores_keep_summary_and_expiry() {
  local home out store bytes
  home=$(make_home large-stores)
  # Both stores exceed Linux's 128 KiB per-argument limit.
  # shellcheck disable=SC2016
  seed_legacy "$home" 0 sg-00000001 "Fixture finding" '
    . as $r | range(0;1000) as $i | $r | .id = "sg-fixture-\($i)" | .risk = ("x" * 256)'
  jq -c '.id += "-archived" | .outcome = "expired"' "$home/data/suggestions.jsonl" \
    > "$home/data/suggestions-not-picked.jsonl"
  for store in suggestions.jsonl suggestions-not-picked.jsonl; do
    bytes=$(wc -c < "$home/data/$store")
    [ "$bytes" -gt 400000 ] || fail "large-store fixture is too small: $bytes"
  done
  assert_equals "1000" "$(at "$home" 0 summary --json | jq '.count')" "large summary failed"
  out=$(at "$home" 30 expire 2>&1)
  assert_equals "expired 1000" "$out" "large expiry batch failed"
  assert_equals "expired 0" "$(at "$home" 30 expire 2>&1)" "large expiry was not idempotent"
  assert_equals "2000" "$(at "$home" 30 archive --json | jq 'length')" "large expiry lost archive records"
  pass "stores above 400 KB preserve summary and batch expiry"
}

test_unpicked_suggestions_expire_into_the_archive() {
  local home id out
  home=$(make_home expiry)
  id=sg-00000001
  seed_legacy "$home" 0 "$id" "Old lead"
  seed_legacy "$home" 20 sg-00000002 "New lead"
  assert_equals "expired 0" "$(at "$home" 29 expire)" "a suggestion expired early"
  assert_equals "2" "$(at "$home" 29 summary --json | jq '.count')" "the count dropped early"

  # Past due, the summary already leaves it out, read-only.
  assert_equals "1" "$(at "$home" 30 summary --json | jq '.count')" "a past-due suggestion still counted"
  assert_equals "10" "$(at "$home" 30 summary --json | jq '.oldest_age_days')" "a past-due suggestion still set the age"
  assert_equals "2" "$(wc -l < "$home/data/suggestions.jsonl" | tr -d ' ')" "summary rewrote the list"

  assert_equals "expired 1" "$(at "$home" 30 expire)" "expiry did not move the record"
  assert_equals "expired 0" "$(at "$home" 31 expire)" "expiry was not idempotent"
  out=$(at "$home" 31 archive --json)
  printf '%s' "$out" | jq -e --arg id "$id" 'length == 1 and .[0].id == $id and .[0].outcome == "expired"' >/dev/null \
    || fail "the archive did not keep the expired suggestion: $out"
  assert_contains "$(at "$home" 31 archive)" "Old lead" "the plain archive lost the record"
  assert_not_contains "$(at "$home" 31 digest)" "Old lead" "an expired suggestion stayed in the digest"
  pass "an unpicked suggestion expires at 30 days into the archive and is kept"
}

test_expiry_recovers_from_a_crash_before_the_list_rewrite() {
  local home
  home=$(make_home expiry-crash)
  seed_legacy "$home" 0 sg-00000001 "Lead"
  # The state a crash leaves: appended to the archive, still in the list.
  jq -c '.outcome = "expired"' "$home/data/suggestions.jsonl" > "$home/data/suggestions-not-picked.jsonl"
  assert_equals "expired 1" "$(at "$home" 30 expire)" "the retried expiry did not converge"
  assert_equals "1" "$(at "$home" 30 archive --json | jq 'length')" "the retry archived the record twice"
  assert_equals "" "$(at "$home" 30 summary)" "the record stayed in the list"
  pass "a retried expiry after a crash archives each record once"
}

test_drop_multiple_legacy_suggestions() {
  local home
  home=$(make_home drop-multiple)
  seed_legacy "$home" 0 sg-00000001 "First lead"
  seed_legacy "$home" 1 sg-00000002 "Second lead"
  assert_equals "2" "$(at "$home" 1 list --json | jq length)" "list omitted legacy suggestions"
  at "$home" 1 drop sg-00000001 sg-00000002 >/dev/null || fail "dropping multiple ids failed"
  assert_equals "0" "$(at "$home" 1 list --json | jq length)" "dropped suggestions stayed waiting"
  assert_equals "2" "$(at "$home" 1 archive --json | jq '[.[] | select(.outcome == "dropped")] | length')" \
    "drop did not archive both suggestions"
  pass "drop archives multiple legacy suggestions in one call"
}

test_a_pick_files_a_queued_row_once() {
  local home id out row
  home=$(make_home pick)
  id=sg-00000001
  seed_legacy "$home" 0 "$id" "Fix the parser, (really)" \
    '.file_line = "bin/x.sh:12" | .size = "S" | .kind = "defect" | .risk = "aborts" | .repo = "fm"'
  out=$(at "$home" 1 pick "$id")
  row=${out##* }
  assert_contains "$out" "picked $id " "pick did not report the row"
  assert_equals "$row" "$(tasks "$home" list --state queued --kind ship | sed -n 's/^  \([^,]*\),.*/\1/p')" "pick did not queue a ship row"
  assert_contains "$(tasks "$home" show "$row" --full)" "bin/x.sh:12" "the row lost the evidence"
  assert_equals "" "$(at "$home" 1 summary)" "a picked suggestion stayed waiting"
  assert_equals "$out" "$(at "$home" 2 pick "$id")" "a second pick changed the result"
  assert_equals "1" "$(row_count "$home")" "a second pick filed another row"
  pass "picking a legacy suggestion files one queued row with its evidence"
}

test_a_retried_pick_reuses_a_row_filed_before_a_crash() {
  local home id out row
  home=$(make_home pick-crash)
  id=sg-00000001
  seed_legacy "$home" 0 "$id" "Fix it"
  row=$(at "$home" 0 pick "$id")
  row=${row##* }
  # The state a crash leaves: the row exists, the record still says suggested.
  jq -c '.outcome = "suggested" | .target = null' "$home/data/suggestions.jsonl" > "$home/data/s.tmp"
  mv "$home/data/s.tmp" "$home/data/suggestions.jsonl"
  out=$(at "$home" 0 pick "$id")
  assert_equals "picked $id $row" "$out" "the retried pick did not reuse the row"
  assert_equals "1" "$(row_count "$home")" "the retried pick filed a duplicate"
  pass "a retried pick reuses the row a crashed pick already filed"
}

test_an_archived_suggestion_can_still_be_picked() {
  local home id out
  home=$(make_home pick-archive)
  id=sg-00000001
  seed_legacy "$home" 0 "$id" "Old lead" '.kind = "research"'
  at "$home" 30 expire >/dev/null
  out=$(at "$home" 40 pick "$id")
  assert_contains "$out" "picked $id" "an archived suggestion could not be picked"
  assert_equals "picked" "$(at "$home" 40 archive --json | jq -r '.[0].outcome')" "the archive lost the pick"
  tasks "$home" list --kind scout | grep -q 'old-lead' || fail "a research suggestion did not default to a scout row"
  pass "an archived suggestion stays pickable and research defaults to a scout"
}

test_pick_refuses_what_is_not_waiting() {
  local home out rc id target
  home=$(make_home pick-refuse)
  out=$(at "$home" 0 pick sg-nope 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "picking an unknown id passed"
  target=sg-00000001
  id=sg-00000002
  seed_legacy "$home" 0 "$target" "Target"
  seed_legacy "$home" 0 "$id" "Target again"
  at "$home" 0 bundle "$id" --into "$target" >/dev/null
  out=$(at "$home" 0 pick "$id" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "picking a bundled suggestion passed: $out"
  assert_contains "$out" "already bundled ($target)" "the refusal did not name the bundle"
  assert_equals "0" "$(row_count "$home")" "a refused pick filed a row"
  pass "pick refuses an unknown or already bundled suggestion"
}

test_bundle_folds_suggestions_into_one_candidate() {
  local home a b out rc
  home=$(make_home bundle)
  a=sg-00000001
  b=sg-00000002
  seed_legacy "$home" 0 "$a" "Nit one"
  seed_legacy "$home" 0 "$b" "Polish pass"
  out=$(at "$home" 0 bundle "$a" --into sg-missing 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing bundle target passed: $out"
  assert_equals "2" "$(at "$home" 0 summary --json | jq '.count')" "a refused bundle changed the list"
  at "$home" 0 bundle "$a" --into "$b" >/dev/null || fail "a valid bundle was refused"
  assert_equals "1" "$(at "$home" 0 summary --json | jq '.count')" "a bundled suggestion stayed a candidate"
  pass "bundle folds a nit into one candidate and refuses a missing target"
}

test_a_corrupt_store_is_refused_not_overwritten() {
  local home out rc before
  home=$(make_home corrupt)
  seed_legacy "$home" 0 sg-00000001 "Lead"
  printf 'not json\n' >> "$home/data/suggestions.jsonl"
  before=$(cat "$home/data/suggestions.jsonl")
  out=$(at "$home" 40 expire 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expiry passed on a corrupt store: $out"
  assert_contains "$out" "cannot parse" "the refusal gave no reason"
  assert_equals "$before" "$(cat "$home/data/suggestions.jsonl")" "a corrupt store was rewritten"
  pass "expiry refuses a corrupt legacy store and keeps its bytes"
}

fm_test_run \
  test_add_refuses_without_writing \
  test_an_empty_list_reports_nothing \
  test_large_stores_keep_summary_and_expiry \
  test_unpicked_suggestions_expire_into_the_archive \
  test_expiry_recovers_from_a_crash_before_the_list_rewrite \
  test_drop_multiple_legacy_suggestions \
  test_a_pick_files_a_queued_row_once \
  test_a_retried_pick_reuses_a_row_filed_before_a_crash \
  test_an_archived_suggestion_can_still_be_picked \
  test_pick_refuses_what_is_not_waiting \
  test_bundle_folds_suggestions_into_one_candidate \
  test_a_corrupt_store_is_refused_not_overwritten
