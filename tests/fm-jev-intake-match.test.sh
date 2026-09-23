#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-intake-match.sh.
#
# Drives the helper against a real tasks-axi backlog and data/<id>/ records,
# with a fake curl on PATH that records argv, the request body, and the header
# read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT JEV_URL JEV_BASE \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_STATE_OVERRIDE FM_DATA_OVERRIDE

HELPER="$ROOT/bin/fm-jev-intake-match.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-intake-match)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
BODY_MARKER='PRIVATE-REPORT-BODY-MARKER'

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

# respond <choice> <confidence> <probabilities-json>
respond() {
  jq -n --arg c "$1" --argjson conf "$2" --argjson p "$3" \
    '{model: "jev-1.13.0", answers: {match: {type: "choice", choice: $c, confidence: $conf, probabilities: $p}}}' \
    > "$RESPONSE"
}

add_record() {  # <id> <file> <heading>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# %s\n\n%s body text for %s.\n' "$3" "$BODY_MARKER" "$1" > "$HOME_DIR/data/$1/$2"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  : > "$HOME_DIR/data/backlog.md"
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wf-p0-privacy-ceiling "Wiki family p0: privacy-ceiling" \
    --body "Phase 0 of the plan in data/wiki-layer-plan-v1/report.md." --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wf-p1-register "Wiki family p1: register" \
    --body "Next phase of wiki-layer-plan-v1." --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add deck-refresh-v1 "Refresh the pitch deck colors" \
    --file data/backlog.md) >/dev/null
  add_record wiki-layer-plan-v1 report.md "Wiki layer: verdict and prioritized plan"
  add_record bochum-hero-v1 brief.md "Task"
  add_record mail-plane-v1 report.md "Mail plane transport audit"
}

# run_match <exit-var> <out-var> [args...]
run_match() {
  local __exit=$1 __out=$2 _out _code
  shift 2
  rm -rf "$LOG"
  mkdir -p "$LOG"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="${KEY-}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" "$HELPER" "$@" </dev/null 2>"$TMP_ROOT/stderr") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}

test_usage() {
  local code out
  run_match code out
  expect_code 2 "$code" "no reference should be a usage error"
  pass "an empty invocation is a usage error"
}

test_off_falls_back_to_keyword_ranking() {
  local code out first
  fresh_home
  KEY='' run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "off should still exit 0"
  assert_contains "$out" "ranking: keyword" "off did not use the keyword ranking"
  assert_contains "$out" "fallback: off" "off did not say it fell back"
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  assert_contains "$first" "wiki-layer-plan-v1 score=2/" "the plan record was not ranked first"$'\n'"$out"
  assert_contains "$first" "record=$HOME_DIR/data/wiki-layer-plan-v1/report.md" "the record path was not shown"
  assert_not_contains "$out" "deck-refresh-v1" "an unrelated candidate was listed"
  [ ! -e "$LOG/body" ] || fail "off made a model call"
  pass "with no key the helper says so and ranks by keywords"
}

test_jev_ranking_sends_only_ids_and_titles() {
  local code out
  fresh_home
  respond wiki-layer-plan-v1 0.84 \
    '{"wiki-layer-plan-v1":0.84,"wf-p0-privacy-ceiling":0.1,"mail-plane-v1":0.02,"deck-refresh-v1":0.01,"bochum-hero-v1":0.01,"none?":0.02}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "a clear answer should exit 0"
  assert_contains "$out" "ranking: jev" "a clear answer did not rank by Jev"$'\n'"$out"
  assert_contains "$out" "fallback: none" "a clear answer reported a fallback"
  assert_contains "$out" "    1. wiki-layer-plan-v1 confidence=0.84" "the pick was not first"$'\n'"$out"
  assert_contains "$out" "    2. wf-p0-privacy-ceiling confidence=0.1 state=queued" \
    "the runner-up backlog item was not second with its state"$'\n'"$out"
  jq -e '.questions.match.type == "choice" and (.questions.match.criteria | has("none?"))' "$LOG/body" >/dev/null \
    || fail "the request was not one Choice with a no-candidate option"
  jq -e '.questions.match.criteria["wiki-layer-plan-v1"] | contains("Wiki layer: verdict")' "$LOG/body" >/dev/null \
    || fail "the record title did not reach the criteria"
  jq -e '.state | contains("get our wiki plan")' "$LOG/body" >/dev/null || fail "the reference did not reach state"
  assert_no_grep "$BODY_MARKER" "$LOG/body" "a file body reached the request"
  assert_no_grep "$TS_KEY" "$LOG/argv" "the key reached curl argv"
  assert_grep "Bearer $TS_KEY" "$LOG/header" "the key did not travel on fd 3"
  jq -e 'select(.purpose == "intake-match" and .ranking == "jev" and .choice == "wiki-layer-plan-v1")' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null || fail "the call was not logged"
  jq -e 'select(.reference_chars == 43 and (.reference_sha256 | test("^[0-9a-f]{64}$")) and (has("reference") | not))' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null || fail "the log did not keep only the reference length and hash"
  jq -e 'select(.route == "typesafe" and .http == "200" and (.latency_ms | type) == "number")' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null || fail "the call route and timing were not logged"
  assert_no_grep "get our wiki plan" "$HOME_DIR/state/jev-intake-match.jsonl" "the log stored the reference text"
  pass "a clear Jev answer ranks by probabilities and sends only ids and titles"
}

test_sparse_probabilities_omit_zero_probability_candidates() {
  local code out candidate_lines
  fresh_home
  respond wiki-layer-plan-v1 0.9 '{"wiki-layer-plan-v1":1}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "a sparse probability map should remain advisory"
  assert_contains "$out" "ranking: jev" "the valid sparse map was not used"$'\n'"$out"
  assert_contains "$out" "1. wiki-layer-plan-v1 confidence=1" "the positive-probability candidate was omitted"$'\n'"$out"
  candidate_lines=$(printf '%s\n' "$out" | grep -c 'confidence=')
  [ "$candidate_lines" -eq 1 ] || fail "zero-probability candidates were printed as Jev results"$'\n'"$out"
  jq -e 'select(.ranked_ids == ["wiki-layer-plan-v1"])' "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null \
    || fail "the sparse ranking log included zero-probability candidates"
  pass "sparse probability maps print only candidates with positive mass"
}

test_no_candidate_probability_falls_back_to_keywords() {
  local code out
  fresh_home
  respond wf-p0-privacy-ceiling 0.9 '{"none?":1}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "a no-candidate probability map should remain advisory"
  assert_contains "$out" "ranking: keyword" "a candidate with no probability mass received a Jev ranking"$'\n'"$out"
  assert_contains "$out" "fallback: no-candidate-probability" \
    "the no-candidate probability fallback was not identified"$'\n'"$out"
  assert_not_contains "$out" "confidence=" "the unsupported Jev ranking was printed"$'\n'"$out"
  jq -e 'select(.ranking == "keyword" and .fallback == "no-candidate-probability" and .ranked_ids == [])' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null \
    || fail "the no-candidate probability result was not logged as a fallback"
  pass "probability mass only on none? falls back to keyword ranking"
}

test_unoffered_probability_keys_use_the_single_pick_fallback() {
  local code out first
  fresh_home
  respond wf-p0-privacy-ceiling 0.9 '{"bogus":1}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "an invalid probability map should remain advisory"
  assert_contains "$out" "ranking: jev" "the valid single pick was not used"$'\n'"$out"
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  assert_contains "$first" "wf-p0-privacy-ceiling confidence=0.9" \
    "the invalid map did not fall back to the selected candidate"$'\n'"$out"
  jq -e 'select(.ranked_ids == ["wf-p0-privacy-ceiling"] and .fallback == "none")' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null \
    || fail "the invalid map did not produce a single-pick ranking"
  pass "probability maps with unoffered keys fall back to the valid selected item"
}

test_probability_map_ranks_every_candidate_independently_of_choice_confidence() {
  local code out first second
  fresh_home
  respond wiki-layer-plan-v1 0.9 \
    '{"wiki-layer-plan-v1":0.1,"wf-p0-privacy-ceiling":0.8,"wf-p1-register":0.04,"deck-refresh-v1":0.02,"bochum-hero-v1":0.02,"mail-plane-v1":0.01,"none?":0.01}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "a probability-ranked answer should exit 0"
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  second=$(printf '%s\n' "$out" | grep -m1 '^    2\. ')
  assert_contains "$first" "wf-p0-privacy-ceiling confidence=0.8" \
    "the probability leader did not outrank the selected candidate"$'\n'"$out"
  assert_contains "$second" "wiki-layer-plan-v1 confidence=0.1" \
    "the selected candidate did not keep its probability score"$'\n'"$out"
  pass "valid candidate probabilities determine the full ranking"
}

test_candidate_id_none_does_not_collide_with_no_match_choice() {
  local code out
  fresh_home
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add none \
    "None is a real backlog item" --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add none_ \
    "Another none-like item" --file data/backlog.md) >/dev/null
  respond none 0.9 '{"none":0.9,"none_":0.05,"none?":0.05}'
  KEY=$TS_KEY run_match code out none
  expect_code 0 "$code" "the candidate named none should remain selectable"
  assert_contains "$out" "ranking: jev" "the real none candidate was treated as the sentinel"$'\n'"$out"
  assert_contains "$out" "    1. none confidence=0.9" "the candidate named none was not selected"$'\n'"$out"
  jq -e '.questions.match.criteria["none"] | contains("None is a real backlog item")' "$LOG/body" >/dev/null \
    || fail "the real none candidate was overwritten in the Choice criteria"
  jq -e '.questions.match.criteria["none_"] | contains("Another none-like item")' "$LOG/body" >/dev/null \
    || fail "the candidate id none_ was overwritten in the Choice criteria"
  jq -e '.questions.match.criteria["none?"] == "No candidate is the record the captain means."' "$LOG/body" >/dev/null \
    || fail "the no-match sentinel collided with a valid candidate id"
  pass "a candidate id of none no longer collides with the no-match choice"
}

test_related_tasks_follow_a_matched_record() {
  local code out
  fresh_home
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wiki-layer-plan-v1-followup \
    "Unrelated follow-up" --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wiki-layer-plan-v10 \
    "Unrelated version ten" --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add title-mentions-record \
    "Title mentions wiki-layer-plan-v1" --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add lookalike-body \
    "Body mentions a longer id" --body "This names wiki-layer-plan-v10 only." --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add dotted-lookalike \
    "Body mentions a dotted id" --body "This names wiki-layer-plan-v1.0 only." --file data/backlog.md) >/dev/null
  respond wiki-layer-plan-v1 0.9 '{"wiki-layer-plan-v1":0.9,"none?":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "  related:" "a matched record listed no related tasks"$'\n'"$out"
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p0-privacy-ceiling state=queued title=Wiki family p0: privacy-ceiling" \
    "a task whose body names the record was not listed"$'\n'"$out"
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p1-register state=queued" \
    "a second related task was not listed"$'\n'"$out"
  assert_not_contains "$out" "-> deck-refresh-v1" "a task that does not name the record was listed"
  assert_not_contains "$out" "-> wiki-layer-plan-v1-followup" "a longer task id was mistaken for the record token"
  assert_not_contains "$out" "-> wiki-layer-plan-v10" "a longer version id was mistaken for the record token"
  assert_not_contains "$out" "-> title-mentions-record" "a title mention was mistaken for a body reference"
  assert_not_contains "$out" "-> lookalike-body" "a longer id in the body was matched by prefix"
  assert_not_contains "$out" "-> dotted-lookalike" "a longer dotted id was matched as the record token"
  [ "$(jq '.questions | length' "$LOG/body")" -eq 1 ] || fail "related tasks cost an extra question"
  KEY='' run_match code out wiki plan
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p0-privacy-ceiling" \
    "the keyword fallback did not list related tasks"$'\n'"$out"
  pass "a matched record brings the backlog tasks that name it, with no extra Jev question"
}

test_stdin_reference_mode_is_rejected() {
  local code=0 out
  fresh_home
  rm -rf "$LOG"
  mkdir -p "$LOG"
  out=$(printf 'wiki plan\n' | PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    "$HELPER" - 2>"$TMP_ROOT/stderr") || code=$?
  expect_code 2 "$code" "stdin mode should be rejected as an unsupported option"
  assert_grep "unknown option: -" "$TMP_ROOT/stderr" "stdin mode was still accepted"
  [ ! -e "$LOG/body" ] || fail "a stdin reference reached Jev"
  pass "intake references are accepted only as positional arguments"
}

test_reference_is_one_bounded_line() {
  local code out long
  fresh_home
  KEY=$TS_KEY run_match code out "$(printf 'wiki\nplan')"
  expect_code 2 "$code" "a multi-line reference should be refused"
  assert_grep "one line" "$TMP_ROOT/stderr" "the refusal did not say why"
  long=$(printf 'w%.0s' $(seq 1 301))
  KEY=$TS_KEY run_match code out "$long"
  expect_code 2 "$code" "a 301-character reference should be refused"
  assert_grep "limit is 300" "$TMP_ROOT/stderr" "the refusal did not name the limit"
  [ ! -e "$LOG/body" ] || fail "a refused reference reached Jev"
  pass "a multi-line or over-300-character reference is refused before any call"
}

test_ties_use_selected_record_file_mtime() {
  local code out first
  fresh_home
  add_record alpha-sync-v1 report.md "Alpha sync"
  add_record zeta-sync-v1 report.md "Zeta sync"
  touch -t 202501010100.00 "$HOME_DIR/data/alpha-sync-v1/report.md"
  touch -t 202501010200.00 "$HOME_DIR/data/zeta-sync-v1/report.md"
  touch -t 202501010200.00 "$HOME_DIR/data/alpha-sync-v1"
  touch -t 202501010100.00 "$HOME_DIR/data/zeta-sync-v1"
  KEY='' run_match code out sync
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  assert_contains "$first" "zeta-sync-v1" "the record with the newer selected file did not rank first"$'\n'"$out"
  pass "tied records follow selected report-file mtimes, not directory mtimes"
}

test_record_symlinks_outside_the_data_root_are_not_read() {
  local code out outside
  fresh_home
  outside="$TMP_ROOT/outside-records"
  mkdir -p "$outside" "$HOME_DIR/data/file-link-record"
  printf '# PRIVATE OUTSIDE TITLE\n\nprivate content\n' > "$outside/report.md"
  ln -s "$outside/report.md" "$HOME_DIR/data/file-link-record/report.md"
  ln -s "$outside" "$HOME_DIR/data/directory-link-record"
  KEY='' run_match code out private outside
  expect_code 0 "$code" "symlinked records should be ignored advisory"
  assert_not_contains "$out" "file-link-record" "a symlinked report was offered"$'\n'"$out"
  assert_not_contains "$out" "directory-link-record" "a symlinked record directory was offered"$'\n'"$out"
  assert_not_contains "$out" "PRIVATE OUTSIDE TITLE" "an outside heading was read"$'\n'"$out"
  pass "record symlinks cannot expose titles outside the data root"
}

test_backlog_listing_failure_is_not_reported_as_empty() {
  local code out
  fresh_home
  rm -rf "$HOME_DIR/data"/*
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN/tasks-axi"
  KEY=$TS_KEY run_match code out wiki plan
  expect_code 0 "$code" "a backlog read failure should remain advisory"
  assert_contains "$out" "ranking: keyword" "an incomplete backlog did not fail open to keyword candidates"$'\n'"$out"
  assert_contains "$out" "fallback: backlog-error" "a failed backlog was reported as an empty candidate set"$'\n'"$out"
  assert_contains "$out" "source-error: backlog listing failed for open, done" \
    "the failed backlog sources were not identified"$'\n'"$out"
  assert_not_contains "$out" "fallback: no-candidates" "an unreadable backlog was described as empty"
  [ ! -e "$LOG/body" ] || fail "Jev ranked an incomplete candidate list"
  rm -f "$FAKEBIN/tasks-axi"
  pass "backlog listing failure is distinct from a successful empty listing"
}

test_related_listing_failure_is_reported() {
  local code out real_tasks_axi
  fresh_home
  real_tasks_axi=$(PATH="$BASE_PATH" command -v tasks-axi)
  cat > "$FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
count_file='$TMP_ROOT/related-list-count'
count=0
[ ! -f "\$count_file" ] || read -r count < "\$count_file"
count=\$((count + 1))
printf '%s\\n' "\$count" > "\$count_file"
[ "\$count" -le 2 ] || exit 1
exec '$real_tasks_axi' "\$@"
SH
  chmod +x "$FAKEBIN/tasks-axi"
  KEY='' run_match code out wiki plan
  expect_code 0 "$code" "related-task listing failures should remain advisory"
  assert_contains "$out" "  related-source-error: related task listing failed for open, done" \
    "a failed related-task read was silently omitted"$'\n'"$out"
  assert_contains "$out" "  candidates:" "the keyword candidates disappeared on related-list failure"$'\n'"$out"
  rm -f "$FAKEBIN/tasks-axi" "$TMP_ROOT/related-list-count"
  pass "related-task listing failures are surfaced without blocking intake"
}

test_low_confidence_falls_back() {
  local code out
  fresh_home
  respond wiki-layer-plan-v1 0.41 '{"wiki-layer-plan-v1":0.41,"wf-p0-privacy-ceiling":0.39,"none?":0.2}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "ranking: keyword" "a low-confidence answer was trusted"
  assert_contains "$out" "fallback: low-confidence" "the low-confidence fallback was not stated"
  assert_contains "$out" "confidence: 0.41" "the low confidence was not shown"
  pass "a pick below the floor falls back to keywords and says so"
}

test_failures_fall_back() {
  local code out
  fresh_home
  FAKE_CURL_FAIL=1 KEY=$TS_KEY run_match code out wiki plan
  expect_code 0 "$code" "a transport failure should exit 0"
  assert_contains "$out" "fallback: error" "a transport failure was not reported"
  respond 'none?' 0.9 '{"none?":0.9,"wiki-layer-plan-v1":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "fallback: no-match" "a none answer was not reported"
  jq -n '{model: "jev-1.13.0", answers: {match: {type: "choice", confidence: 0.9, probabilities: {"none?": 1}}}}' > "$RESPONSE"
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "fallback: error" "a response missing its choice was reported as no-match"
  respond not-offered 0.95 '{"not-offered":0.95,"none?":0.05}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "fallback: error" "an unoffered pick was accepted"
  pass "transport failure, none, and an unoffered pick all fall back to keywords"
}

test_invalid_route_is_reported_as_error_not_off() {
  local code out
  fresh_home
  export JEV_ROUTE=invalid-route
  KEY=$TS_KEY run_match code out wiki plan
  unset JEV_ROUTE
  expect_code 0 "$code" "a route configuration error should remain advisory"
  assert_contains "$out" "fallback: error" "a present key with a bad route was reported as off"$'\n'"$out"
  assert_not_contains "$out" "fallback: off" "a configured but invalid route was indistinguishable from no key"$'\n'"$out"
  [ ! -e "$LOG/body" ] || fail "an invalid route reached curl"
  pass "a present API key reaches route validation instead of appearing off"
}

test_candidate_list_is_bounded() {
  local code out i offered
  fresh_home
  for i in $(seq 1 40); do
    add_record "extra-plan-$i" report.md "Extra plan $i"
  done
  respond wiki-layer-plan-v1 0.9 '{"wiki-layer-plan-v1":0.9,"none?":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  offered=$(jq '.questions.match.criteria | length' "$LOG/body")
  [ "$offered" -eq 25 ] || fail "offered $offered choices, want 24 candidates plus none"
  jq -e '.questions.match.criteria | has("wiki-layer-plan-v1")' "$LOG/body" >/dev/null \
    || fail "the best keyword match was cut from the bounded offer"
  pass "the offer is bounded to 24 candidates and keeps the best keyword match"
}

test_usage
test_off_falls_back_to_keyword_ranking
test_jev_ranking_sends_only_ids_and_titles
test_sparse_probabilities_omit_zero_probability_candidates
test_no_candidate_probability_falls_back_to_keywords
test_unoffered_probability_keys_use_the_single_pick_fallback
test_probability_map_ranks_every_candidate_independently_of_choice_confidence
test_candidate_id_none_does_not_collide_with_no_match_choice
test_related_tasks_follow_a_matched_record
test_stdin_reference_mode_is_rejected
test_reference_is_one_bounded_line
test_ties_use_selected_record_file_mtime
test_record_symlinks_outside_the_data_root_are_not_read
test_backlog_listing_failure_is_not_reported_as_empty
test_related_listing_failure_is_reported
test_low_confidence_falls_back
test_failures_fall_back
test_invalid_route_is_reported_as_error_not_off
test_candidate_list_is_bounded

echo "# all fm-jev-intake-match tests passed"
