#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-brief-preflight.sh and its spawn-path caller.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3. Spawn cases stop before any endpoint exists:
# delivery checks and this preflight run ahead of backend creation, and a
# fake tmux that exits non-zero backstops cases that are meant to get past
# them. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-brief-preflight.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_TOOL="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-brief-preflight)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
TASK_ID='pager-off-by-one'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$LOG"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_JEV_BRIEF_PREFLIGHT

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] \
  || [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
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
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

write_complete_brief() {
  cat > "$BRIEF" <<'MD'
You are a crewmate.

# Task
## Captain's intent
Fix the off-by-one in pager.sh line 40 so one page is returned per call.

## Firstmate spec
Change only pager.sh.
Do not refactor the caller.
Add a regression test that fails before the fix and passes after.

# Definition of done
Delivery contract: mode=direct-PR
The pager returns one page per call.
tests/pager.test.sh is green.
The PR is open.

# Setup
TYPESAFE_API_KEY=super-secret-should-not-leave
See data/captain.md and /Users/yelen/github/firstmate/state/other-task.status
MD
}

write_response() {  # <choice> [confidence]
  local choice=$1
  local conf=${2:-0.86}
  local p_complete=0.02 p_acc=0.02 p_con=0.02 p_amb=0.02 p_hum=0.02
  case "$choice" in
    complete) p_complete=0.92 ;;
    missing_acceptance) p_acc=0.92 ;;
    missing_constraints) p_con=0.92 ;;
    ambiguous_scope) p_amb=0.92 ;;
    need_human) p_hum=0.92 ;;
  esac
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "brief": { "type": "choice", "choice": "$choice", "confidence": $conf,
    "probabilities": {
      "complete": $p_complete,
      "missing_acceptance": $p_acc,
      "missing_constraints": $p_con,
      "ambiguous_scope": $p_amb,
      "need_human": $p_hum
    } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"
write_complete_brief
write_response complete

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

record_path() {
  printf '%s' "$HOME_DIR/state/${1:-$TASK_ID}.jev-brief-preflight.jsonl"
}

# run_preflight <exit-var> <out-var> <err-var> [args...]
run_preflight() {
  local __exit=$1 __out=$2 __err=$3
  shift 3
  local _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  rm -f "$(record_path)"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$TOOL" "$@" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

make_spawn_home() {  # <name>
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  cp "$FAKEBIN/curl" "$fakebin/curl"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_spawn_brief() {  # <home> <id> <intent> <spec>
  local home=$1 id=$2 intent=$3 spec=$4
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\n%s\n\n## Firstmate spec\n%s\n\n# Definition of done\nDelivery contract: mode=direct-PR\nThe change is observable and tests cover it.\n' \
      "$intent" "$spec"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  reset_log
  FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_usage_requires_brief_and_task() {
  local code out err
  run_preflight code out err
  expect_code 2 "$code" "missing args exit 2"
  assert_contains "$err" 'Usage:' "usage is printed"
  run_preflight code out err --brief "$BRIEF"
  expect_code 2 "$code" "missing task exits 2"
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID/../escape"
  expect_code 2 "$code" "path-like task id is refused"
  pass "usage requires --brief and --task and refuses a path-like id"
}

test_complete_is_silent_and_records() {
  local code out err line body
  write_complete_brief
  write_response complete 0.88
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" \
    --kind ship --mode direct-PR
  expect_code 0 "$code" "complete preflight exits 0"
  [ -z "$out" ] || fail "complete must be silent on stdout, got '$out'"
  assert_not_contains "$err" 'warning: brief preflight' "complete must not warn"
  assert_present "$(record_path)" "complete must write a record"
  line=$(cat "$(record_path)")
  assert_contains "$line" '"purpose":"brief-preflight"' "record names the purpose"
  assert_contains "$line" '"verdict":"complete"' "record stores complete"
  assert_contains "$line" '"block":false' "complete never blocks"
  assert_contains "$line" '"shadow":true' "complete stays shadow"
  assert_contains "$line" '"surfaced":false' "complete is not surfaced"
  body=$(cat "$LOG/body")
  jq -e '.state == {
    query: "Check worker brief structural completeness",
    kind: "ship", delivery_mode: "direct-PR", recorded_delivery: "direct-PR",
    has_task: true, has_definition_of_done: true,
    has_captain_intent: true, has_firstmate_spec: true
  }' "$LOG/body" >/dev/null || fail "request contains only the query and structural metadata"
  jq -e '.route == "typesafe" and .model == "jev-latest" and .http == "200"
    and (.latency_ms | type == "number" and . >= 0)' "$(record_path)" >/dev/null \
    || fail "successful call retains transport evidence"
  assert_not_contains "$body" 'super-secret-should-not-leave' "Setup secrets stay out of state"
  assert_not_contains "$body" 'data/captain.md' "captain-private records stay out of state"
  assert_not_contains "$body" 'other-task.status' "another task's records stay out of state"
  assert_not_contains "$body" "$TS_KEY" "the API key is not in the request body"
  assert_contains "$(cat "$LOG/child-env")" 'curl:clean' "curl child env has no key"
  assert_contains "$(cat "$LOG/header")" "Bearer $TS_KEY" "key reaches curl only via fd 3"
  pass "a complete brief is silent, recorded, and sends only the query and structural metadata"
}

test_each_defect_class_is_reported() {
  local code out err line choice missing
  write_complete_brief
  while IFS='|' read -r choice missing; do
    [ -n "$choice" ] || continue
    write_response "$choice" 0.84
    TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" \
      --kind ship --mode direct-PR
    expect_code 0 "$code" "$choice exits 0"
    assert_contains "$err" "warning: brief preflight:" "$choice prints a warning"
    assert_contains "$err" "$missing" "$choice names the missing element"
    assert_contains "$err" "spawn continues" "$choice does not claim a refusal"
    line=$(cat "$(record_path)")
    assert_contains "$line" "\"verdict\":\"$choice\"" "$choice is recorded"
    assert_contains "$line" '"block":false' "$choice never blocks"
    assert_contains "$line" '"surfaced":true' "$choice is surfaced"
  done <<'ROWS'
missing_acceptance|acceptance criteria or definition of done
missing_constraints|constraints or out-of-scope boundary
ambiguous_scope|unambiguous observable outcome
need_human|human review of brief completeness
ROWS
  pass "each defect class is reported with the missing element and still exits 0"
}

test_low_confidence_is_not_surfaced() {
  local code out err line
  write_complete_brief
  write_response missing_acceptance 0.4
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" \
    --kind ship --mode direct-PR
  expect_code 0 "$code" "low confidence exits 0"
  assert_not_contains "$err" 'warning: brief preflight' "low confidence stays silent"
  line=$(cat "$(record_path)")
  assert_contains "$line" '"verdict":"missing_acceptance"' "low confidence still records the choice"
  assert_contains "$line" '"surfaced":false' "low confidence is not surfaced"
  assert_contains "$line" '"block":false' "low confidence never blocks"
  pass "low confidence records without surfacing or blocking"
}

test_jev_failure_skips_without_blocking() {
  local code out err line
  write_complete_brief
  write_response complete
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_preflight code out err \
    --brief "$BRIEF" --task "$TASK_ID" --kind ship --mode direct-PR
  expect_code 0 "$code" "transport failure exits 0"
  assert_not_contains "$err" 'warning: brief preflight' "failure stays silent"
  line=$(cat "$(record_path)")
  assert_contains "$line" '"verdict":"skipped"' "failure records skipped"
  assert_contains "$line" '"block":false' "failure never blocks"
  jq -e '.route == "typesafe" and .model == "jev-latest" and .http == "000"
    and (.latency_ms | type == "number") and .decide_code == 1' "$(record_path)" >/dev/null \
    || fail "failed call retains transport evidence"
  pass "a Jev failure skips without blocking"
}

test_absent_key_and_off_skip_curl() {
  local code out err
  write_complete_brief
  write_response complete
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --kind ship
  expect_code 0 "$code" "absent key exits 0"
  assert_absent "$(record_path)" "absent key writes no record"
  assert_absent "$LOG/argv" "absent key never calls curl"
  FM_JEV_BRIEF_PREFLIGHT=off TYPESAFE_API_KEY=$TS_KEY run_preflight code out err \
    --brief "$BRIEF" --task "$TASK_ID" --kind ship --mode direct-PR
  expect_code 0 "$code" "off exits 0"
  assert_absent "$(record_path)" "off writes no record"
  assert_absent "$LOG/argv" "off never calls curl"
  pass "absent key and FM_JEV_BRIEF_PREFLIGHT=off skip curl and write nothing"
}

test_spawn_complete_brief_passes_silently() {
  local rec home proj fakebin out line
  rec=$(make_spawn_home complete)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_spawn_brief "$home" complete-ship \
    "Fix the pager off-by-one on line 40." \
    "Change only pager.sh. Do not refactor the caller."
  write_response complete 0.9
  out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" complete-ship "$proj" claude \
    --mode direct-PR --yolo off)
  assert_not_contains "$out" 'warning: brief preflight' "complete spawn is silent about Jev"
  assert_not_contains "$out" 'still contains {TASK}' "complete spawn is not a structural refusal"
  line=$(cat "$home/state/complete-ship.jev-brief-preflight.jsonl")
  assert_contains "$line" '"verdict":"complete"' "spawn wrote a complete record"
  assert_contains "$line" '"block":false' "spawn record never blocks"
  pass "spawn of a complete brief records silently and still proceeds"
}

test_spawn_reports_each_defect_and_still_proceeds() {
  local rec home proj fakebin out line choice missing id
  rec=$(make_spawn_home defects)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r choice missing; do
    [ -n "$choice" ] || continue
    id="defect-$choice"
    write_spawn_brief "$home" "$id" \
      "Do the work described in the Task." \
      "Keep the change local."
    write_response "$choice" 0.83
    out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" "$id" "$proj" claude \
      --mode direct-PR --yolo off)
    assert_contains "$out" "warning: brief preflight:" "$choice spawn warns"
    assert_contains "$out" "$missing" "$choice spawn names the missing element"
    assert_contains "$out" "spawn continues" "$choice spawn does not refuse"
    assert_not_contains "$out" 'still contains {TASK}' "$choice is not a structural refusal"
    line=$(cat "$home/state/$id.jev-brief-preflight.jsonl")
    assert_contains "$line" "\"verdict\":\"$choice\"" "$choice spawn recorded the verdict"
    assert_contains "$line" '"block":false' "$choice spawn never blocks"
  done <<'ROWS'
missing_acceptance|acceptance criteria or definition of done
missing_constraints|constraints or out-of-scope boundary
ambiguous_scope|unambiguous observable outcome
need_human|human review of brief completeness
ROWS
  pass "spawn reports each defect class and still proceeds past the brief checks"
}

test_spawn_jev_failure_does_not_change_outcome() {
  local rec home proj fakebin out line
  rec=$(make_spawn_home fail)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_spawn_brief "$home" fail-ship \
    "Fix the pager off-by-one on line 40." \
    "Change only pager.sh."
  write_response complete
  out=$(FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" fail-ship "$proj" claude \
    --mode direct-PR --yolo off)
  assert_not_contains "$out" 'warning: brief preflight' "failed Jev stays invisible"
  assert_not_contains "$out" 'still contains {TASK}' "failed Jev is not a structural refusal"
  line=$(cat "$home/state/fail-ship.jev-brief-preflight.jsonl")
  assert_contains "$line" '"verdict":"skipped"' "failed Jev records skipped"
  assert_contains "$line" '"block":false' "failed Jev never blocks"
  pass "a Jev failure does not alter the spawn outcome"
}

test_spawn_structural_refusals_still_fire() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home structural)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_response complete 0.9

  FM_HOME="$home" "$BRIEF_TOOL" unfilled-ship proj --mode direct-PR >/dev/null 2>&1 \
    || fail "unfilled ship brief should still scaffold"
  out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" unfilled-ship "$proj" claude \
    --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "unfilled ship spawn should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled ship spawn still names leftover placeholders"
  assert_absent "$LOG/argv" "structural placeholder refusal never calls Jev"
  assert_absent "$home/state/unfilled-ship.jev-brief-preflight.jsonl" \
    "structural placeholder refusal writes no Jev record"
  assert_absent "$home/state/unfilled-ship.meta" "unfilled ship spawn wrote task metadata"

  FM_HOME="$home" "$BRIEF_TOOL" empty-ship proj --mode direct-PR >/dev/null 2>&1 \
    || fail "empty-ship brief should scaffold"
  content=$(cat "$home/data/empty-ship/brief.md")
  content=${content//'{TASK}'/}
  content=${content//'{FIRSTMATE_SPEC}'/}
  printf '%s\n' "$content" > "$home/data/empty-ship/brief.md"
  reset_log
  out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" empty-ship "$proj" claude \
    --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "empty Task subsections should exit non-zero"
  assert_contains "$out" "must contain nonempty ## Captain's intent and ## Firstmate spec" \
    "empty Task subsections are still rejected"
  assert_absent "$LOG/argv" "empty-subsection refusal never calls Jev"
  assert_absent "$home/state/empty-ship.jev-brief-preflight.jsonl" \
    "empty-subsection refusal writes no Jev record"

  mkdir -p "$home/data/address-ship"
  cat > "$home/data/address-ship/brief.md" <<'EOF'
# Task
## Captain's intent
Captain, fix the pager.

## Firstmate spec
Change only pager.sh.

# Definition of done
Delivery contract: mode=direct-PR
EOF
  reset_log
  out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" address-ship "$proj" claude \
    --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "Captain-addressed intent should exit non-zero"
  assert_contains "$out" "has an operator-address line" \
    "Captain-addressed intent is still refused"
  assert_absent "$LOG/argv" "address-line refusal never calls Jev"
  assert_absent "$home/state/address-ship.jev-brief-preflight.jsonl" \
    "address-line refusal writes no Jev record"
  pass "existing structural brief refusals still fire and never call Jev"
}

test_body_content_stays_local() {
  local code out err content section
  write_response complete
  for section in Task 'Definition of done' Setup; do
    for content in '```' '~~~' '> Quoted page excerpt' '<<<<<<< HEAD' '=======' '>>>>>>> branch' '||||||| base' '    Indented excerpt' '"Inline page excerpt"'; do
      printf '# %s\n%s\nprivate page content\nGH_TOKEN=secret\n' "$section" "$content" > "$BRIEF"
      TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
      expect_code 0 "$code" "body content does not block metadata-only preflight"
      assert_present "$LOG/body" "metadata-only request still reaches Jev"
      jq -e '.state == {
        query: "Check worker brief structural completeness",
        kind: "", delivery_mode: "", recorded_delivery: "",
        has_task: ($section == "Task"), has_definition_of_done: ($section == "Definition of done"),
        has_captain_intent: false, has_firstmate_spec: false
      }' --arg section "$section" "$LOG/body" >/dev/null || fail "brief content entered request state"
      assert_not_contains "$(cat "$LOG/body")" 'private page content' "page content stays local"
      assert_not_contains "$(cat "$LOG/body")" 'GH_TOKEN=secret' "secrets stay local"
      assert_equals '' "$err" "complete metadata verdict is silent"
    done
  done
  pass "quoted, fenced, indented, and conflict bodies never enter request state"
}

test_spawn_generated_briefs_reach_jev() {
  local rec home proj fakebin out content kind id mode
  local -a args
  rec=$(make_spawn_home generated)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_response complete
  for mode in direct-PR local-only no-mistakes scout; do
    id="generated-$mode"
    kind=ship
    args=(--mode "$mode")
    if [ "$mode" = scout ]; then
      kind=scout
      args=(--scout)
    fi
    FM_HOME="$home" "$BRIEF_TOOL" "$id" proj "${args[@]}" >/dev/null \
      || fail "could not scaffold $id"
    content=$(cat "$home/data/$id/brief.md")
    content=${content//'{TASK}'/Fix the pager off-by-one.}
    content=${content//'{FIRSTMATE_SPEC}'/Change only pager.sh and add a regression test.}
    printf '%s\n' "$content" > "$home/data/$id/brief.md"
    if [ "$kind" = ship ]; then args+=(--yolo off); fi
    out=$(TYPESAFE_API_KEY=$TS_KEY run_spawn "$home" "$fakebin" "$id" "$proj" claude "${args[@]}")
    assert_present "$LOG/body" "$id must reach Jev through spawn: $out"
    jq -e --arg kind "$kind" --arg mode "$mode" '.state == {
      query: "Check worker brief structural completeness",
      kind: $kind,
      delivery_mode: (if $kind == "scout" then "" else $mode end),
      recorded_delivery: (if $kind == "scout" then "" else $mode end),
      has_task: true, has_definition_of_done: true,
      has_captain_intent: true, has_firstmate_spec: true
    }' "$LOG/body" >/dev/null || fail "$id request must contain only structural metadata"
    jq -e '.verdict == "complete" and .block == false and .http == "200"' \
      "$home/state/$id.jev-brief-preflight.jsonl" >/dev/null || fail "$id must record the call"
    assert_not_contains "$out" 'warning: brief preflight' "$id complete verdict stays silent"
  done
  pass "populated generated ship and scout briefs reach Jev through spawn"
}

test_compaction_failure_skips_call() {
  local code out err
  write_complete_brief
  JEV_STATE_MAX_BYTES=1 TYPESAFE_API_KEY=$TS_KEY run_preflight code out err \
    --brief "$BRIEF" --task "$TASK_ID"
  expect_code 0 "$code" "compaction refusal does not block"
  assert_absent "$LOG/body" "compaction refusal never calls Jev"
  assert_absent "$(record_path)" "compaction refusal writes no call record"
  assert_equals '' "$err" "compaction refusal is silent"
  pass "compaction failure never bypasses the safe-input boundary"
}

test_timeout_configuration() {
  local code out err
  write_complete_brief
  write_response complete
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  assert_equals 5 "$(awk '/^--max-time$/ {getline; print}' "$LOG/argv")" "default timeout is five seconds"
  printf 'JEV_TIMEOUT=1\n' > "$HOME_DIR/.env"
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  assert_equals 1 "$(awk '/^--max-time$/ {getline; print}' "$LOG/argv")" "dotenv timeout is honored"
  JEV_TIMEOUT=2 TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  assert_equals 2 "$(awk '/^--max-time$/ {getline; print}' "$LOG/argv")" "environment timeout takes precedence"
  rm -f "$HOME_DIR/.env"
  pass "timeout honors environment and dotenv before the local default"
}

test_metadata_does_not_forward_content() {
  local code out err
  printf '# Task\nFix the off-by-one.\n# Definition of done\nGH_TOKEN=secret\nUnmarked page excerpt\n' > "$BRIEF"
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  jq -e '.state == {
    query: "Check worker brief structural completeness",
    kind: "", delivery_mode: "", recorded_delivery: "",
    has_task: true, has_definition_of_done: true,
    has_captain_intent: false, has_firstmate_spec: false
  }' "$LOG/body" >/dev/null || fail "raw content must stay local"
  assert_not_contains "$(cat "$LOG/body")" 'off-by-one' "task body stays local"
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --mode private-content
  assert_absent "$LOG/body" "unrecognized metadata cannot carry arbitrary content"
  printf '# Task\n \n' > "$BRIEF"
  TYPESAFE_API_KEY=$TS_KEY run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  jq -e '.state.has_task == false and .state.has_definition_of_done == false' \
    "$LOG/body" >/dev/null || fail "absent content is represented structurally"
  pass "raw bodies and unrecognized metadata never enter the request"
}

test_usage_requires_brief_and_task
test_complete_is_silent_and_records
test_each_defect_class_is_reported
test_low_confidence_is_not_surfaced
test_jev_failure_skips_without_blocking
test_absent_key_and_off_skip_curl
test_spawn_complete_brief_passes_silently
test_spawn_reports_each_defect_and_still_proceeds
test_spawn_jev_failure_does_not_change_outcome
test_spawn_structural_refusals_still_fire
test_body_content_stays_local
test_spawn_generated_briefs_reach_jev
test_compaction_failure_skips_call
test_timeout_configuration
test_metadata_does_not_forward_content
