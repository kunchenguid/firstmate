#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-skill-select.sh.
#
# Drives the selector with a fake curl on PATH that records argv, the request
# body, and the header read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_JEV_SKILL_SELECT \
  FM_JEV_SKILL_SELECT_LIVE_CONFIRM

TMP_ROOT=$(fm_test_tmproot fm-jev-skill-select)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
SKILLS_DIR="$TMP_ROOT/user-home/.agents/skills"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG" "$SKILLS_DIR/pager" "$SKILLS_DIR/review"
cat > "$SKILLS_DIR/pager/SKILL.md" <<'EOF'
---
name: pager
description: Find and explain pager workflows.
---
Use pager workflows.
EOF
cat > "$SKILLS_DIR/review/SKILL.md" <<'EOF'
---
name: review
description: Review code changes carefully.
---
Review code changes.
EOF

write_response() {
  cat > "$1" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.9,
    "probabilities": { "pager": 0.9, "review": 0.05, "none": 0.05 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

RESPONSE2="$TMP_ROOT/response2.json"
cat > "$RESPONSE2" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "detail": { "type": "choice", "choice": "pager", "confidence": 0.9,
    "probabilities": { "pager": 0.9, "review": 0.05, "none": 0.05 } },
    "fit_pager": { "type": "noul", "noul": 0.9 },
    "fit_review": { "type": "noul", "noul": 0.1 } },
  "usage": { "input_tokens": 60, "output_tokens": 18 } }
JSON

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
if jq -e '.questions | has("detail")' "$FAKE_CURL_LOG/body" >/dev/null 2>&1; then
  sleep "${FAKE_DETAIL_DELAY:-0}"
  cp "${FAKE_CURL_RESPONSE2:?}" "$out"
else
  cp "$FAKE_CURL_LOG/body" "$FAKE_CURL_LOG/first-body"
  sleep "${FAKE_FIRST_DELAY:-0}"
  cp "${FAKE_CURL_RESPONSE:?}" "$out"
fi
if [ "${FAKE_ECHO_MODEL:-0}" = 1 ]; then
  jq --arg model "$(jq -r '.model' "$FAKE_CURL_LOG/body")" '.model = $model' "$out" > "$out.tmp"
  mv "$out.tmp" "$out"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

RESPONSE="$TMP_ROOT/response.json"
write_response "$RESPONSE"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_RESPONSE2="$RESPONSE2" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run_select <exit-var> <out-var> <err-var> [args...]
run_select() {
  local __exit=$1 __out=$2 __err=$3 _out _errfile _code
  shift 3
  local has_summary=0 arg launch_id='' previous=''
  for arg in "$@"; do
    [ "$previous" != --task-id ] || launch_id=$arg
    [ "$previous" != --launch-id ] || launch_id=$arg
    previous=$arg
    [ "$arg" = --summary ] && has_summary=1
  done
  [ "$has_summary" -eq 1 ] || set -- "$@" --summary 'Find pager workflows'
  [ -z "$launch_id" ] || set -- "$@" --launch-id "$launch_id"
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(HOME="${SKILLS_DIR%/.agents/skills}" PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$ROOT/bin/fm-jev-skill-select.sh" "$@" </dev/null 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  approve_skills
}

approve_skills() {
  python3 - "$SKILLS_DIR" "$HOME_DIR/config/jev-skill-public.json" <<'PYTHON'
import hashlib, json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(json.dumps([hashlib.sha256(p.read_bytes()).hexdigest() for p in pathlib.Path(sys.argv[1]).glob('*/SKILL.md')]))
PYTHON
}

test_help_exits_0() {
  local code out err
  run_select code out err --help
  expect_code 0 "$code" "--help exits 0"
  assert_contains "$out" 'Usage:' "--help prints usage"
  pass "--help prints usage and exits 0"
}

test_missing_harness_is_usage() {
  local code out err
  fresh_home
  run_select code out err --task-id t1 pager
  expect_code 2 "$code" "missing --harness exits 2"
  assert_contains "$err" '--harness is required' "missing harness explains itself"
  pass "missing --harness is a usage error"
}

test_shadow_default_writes_json_not_status() {
  local code out err record
  fresh_home
  unset FM_JEV_SKILL_SELECT
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-shadow --summary 'fix the pager' --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "shadow select succeeds"
  record="$HOME_DIR/state/jev-skill-shadow/cases/t-shadow.json"
  [ -f "$record" ] || fail "shadow must write its launch case"
  assert_contains "$out" '"status": "recommended"' "stdout is the JSON record"
  jq -e '.shadow == true and .status == "recommended"
      and (.decisions.stage1.choice == "pager")
      and (.decisions.stage2.chosen_fit_probability >= 0.8)
      and (.roster_hash | length == 64) and (.request_hash | length == 64)
      and ((.live_loaded // false) == false)' "$record" >/dev/null \
    || fail "shadow record must be recommended without live loading"
  [ ! -e "$HOME_DIR/state/t-shadow.status" ] || fail "shadow must not append a status note by default"
  assert_contains "$(cat "$LOG/body")" '"type": "choice"' "Jev is asked one Choice question"
  assert_contains "$(cat "$LOG/body")" '"none"' "Choice includes none"
  assert_contains "$(cat "$LOG/body")" 'Find and explain pager workflows.' "Choice includes the real skill description"
  assert_equals $'curl:clean\ncurl:clean' "$(cat "$LOG/child-env")" "the API key is absent from the curl environment"
  jq -e '.questions.fit_pager.criteria | keys == ["false", "true"]' "$LOG/body" >/dev/null || fail "Noul wire criteria"
  jq -e '.state.candidates | any(.id == "pager" and (.evidence | contains("Use pager workflows.")))' "$LOG/body" >/dev/null || fail "independent questions need procedure evidence"
  pass "default shadow writes JSON, skips status, and does not load skills"
}

test_status_note_only_when_asked() {
  local code out err
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-note --skills-dir "$SKILLS_DIR" --status-note
  expect_code 0 "$code" "status-note select succeeds"
  [ ! -e "$HOME_DIR/state/t-note.status" ] || fail "shadow records must not append a worker status note"
  jq -e '.comparison_label == "unlabeled"' "$HOME_DIR/state/jev-skill-shadow/cases/t-note.json" >/dev/null \
    || fail "shadow record must retain its comparison label"
  pass "shadow keeps experiment evidence local without a worker status note"
}

test_once_per_session_reuses_file() {
  local code out err first_stamp
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-once --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "first select succeeds"
  [ -f "$LOG/argv" ] || fail "first select must call curl"
  first_stamp=$(wc -c < "$HOME_DIR/state/jev-skill-shadow/cases/t-once.json")
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-once --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "reuse select succeeds without curl"
  [ ! -e "$LOG/argv" ] || fail "reuse must not call curl"
  assert_contains "$out" '"shadow": true' "reuse prints the cached shadow record"
  assert_equals "$first_stamp" "$(wc -c < "$HOME_DIR/state/jev-skill-shadow/cases/t-once.json")" \
    "reuse must not rewrite the recorded suggestion"
  pass "a second call for the same launch ID does not call Jev"
}

test_below_floor_is_uncertain() {
  local code out err
  fresh_home
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.4,
    "probabilities": { "pager": 0.55, "review": 0.4, "none": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-low --skills-dir "$SKILLS_DIR"
  write_response "$RESPONSE"
  expect_code 0 "$code" "below-floor select exits 0"
  jq -e '.status == "none" and .reason == "low_or_none"' \
    "$HOME_DIR/state/jev-skill-shadow/cases/t-low.json" >/dev/null \
    || fail "below 0.8 must record no recommendation"
  pass "confidence below 0.8 records no recommendation"
}

test_missing_keys_are_off_without_curl() {
  local code out err
  fresh_home
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  run_select code out err --harness pi --task-id t-off --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "missing keys exit 0"
  assert_contains "$err" 'jev-skill-select: off' "missing keys explain off"
  [ ! -e "$HOME_DIR/state/jev-skill-shadow/cases/t-off.json" ] || fail "off must not write a sticky suggestion"
  [ ! -e "$LOG/argv" ] || fail "off must not call curl"
  pass "missing keys are off, no network, no JSON record"
}

test_live_without_confirm_refuses() {
  local code out err
  fresh_home
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-live --skills-dir "$SKILLS_DIR"
  expect_code 2 "$code" "live without confirm exits 2"
  assert_contains "$err" 'live skill load refused' "live without confirm explains itself"
  [ ! -e "$HOME_DIR/state/t-live.jev-skills.json" ] || fail "refused live must not write a suggestion"
  [ ! -e "$LOG/argv" ] || fail "refused live must not call curl"
  pass "live without the confirm file is refused"
}

seed_overlay() {
  cat > "$1" <<'EOF'
# Current worker role contract
You are a crewmate.

# Task
Do the work.
EOF
}

test_live_without_overlay_stays_unloaded() {
  local code out err
  fresh_home
  : > "$HOME_DIR/config/jev-skill-select-live"
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-live2 --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "live with confirm exits 0"
  jq -e '.mode == "live" and .live_loaded == false and .status == "clear"' \
    "$HOME_DIR/state/t-live2.jev-skills.json" >/dev/null \
    || fail "live without --overlay must record live_loaded false"
  [ ! -e "$HOME_DIR/state/t-live2.launch" ] || fail "live must not write a sidecar launch file"
  pass "live plus confirm without --overlay only records a suggestion"
}

test_live_overlay_sets_live_loaded() {
  local code out err overlay
  fresh_home
  : > "$HOME_DIR/config/jev-skill-select-live"
  overlay="$HOME_DIR/data/t-overlay/launch-brief.md"
  mkdir -p "$(dirname "$overlay")"
  seed_overlay "$overlay"
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness grok --task-id t-overlay --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  expect_code 0 "$code" "live overlay select succeeds"
  jq -e '.mode == "live" and .live_loaded == true and .status == "clear"
      and (.skills | index("pager") != null)' \
    "$HOME_DIR/state/t-overlay.jev-skills.json" >/dev/null \
    || fail "live overlay must record live_loaded true once pager reached the brief"
  assert_grep '# Jev-selected skills' "$overlay" "overlay missing skills heading"
  assert_grep '/pager' "$overlay" "grok overlay must use slash form"
  assert_contains "$(cat "$overlay")" 'Do not speculatively search beyond these skills as part of this selection step.' \
    "generated launch instruction limits speculative discovery only during selection"
  assert_contains "$(cat "$overlay")" 'Discover and load other applicable skills whenever the task requires them.' \
    "generated launch instruction preserves task-required skill discovery"
  assert_no_grep 'Do not search for extra skills this session' "$overlay" \
    "generated launch instruction must not prohibit discovery for the whole session"
  assert_grep '# Current worker role contract' "$overlay" "overlay lost the worker role"
  assert_grep '# Task' "$overlay" "overlay lost the task"
  pass "live overlay injects selected skills and sets live_loaded true"
  rm "$SKILLS_DIR/pager/SKILL.md"
  seed_overlay "$overlay"
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness grok --task-id t-overlay --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  expect_code 0 "$code" "cached selection with missing file remains fail-open"
  jq -e '.reused == true and .live_loaded == false' \
    "$HOME_DIR/state/t-overlay.jev-skills.json" >/dev/null || fail "missing cached skill must not be loaded"
  assert_no_grep 'Jev-selected skills' "$overlay" "missing cached skill must not reach launch overlay"
  assert_absent "$LOG/body" "cached selection must not repeat the request"
  cat > "$SKILLS_DIR/pager/SKILL.md" <<'EOF'
---
name: pager
description: Find and explain pager workflows.
---
Use pager workflows.
EOF
  pass "cached skills are revalidated against currently readable files"
}

test_shadow_overlay_does_not_change_launch() {
  local code out err overlay before
  fresh_home
  overlay="$HOME_DIR/data/t-shadow-ov/launch-brief.md"
  mkdir -p "$(dirname "$overlay")"
  seed_overlay "$overlay"
  before=$(cat "$overlay")
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-shadow-ov --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  expect_code 0 "$code" "shadow overlay select succeeds"
  jq -e '.shadow == true and ((.live_loaded // false) == false)' \
    "$HOME_DIR/state/jev-skill-shadow/cases/t-shadow-ov.json" >/dev/null \
    || fail "shadow overlay must keep live_loaded false"
  assert_equals "$before" "$(cat "$overlay")" "shadow must not rewrite the launch overlay"
  pass "shadow plus --overlay leaves the launch file unchanged"
}

test_none_overlay_leaves_launch_unchanged() {
  local code out err overlay before
  fresh_home
  : > "$HOME_DIR/config/jev-skill-select-live"
  overlay="$HOME_DIR/data/t-none-ov/launch-brief.md"
  mkdir -p "$(dirname "$overlay")"
  seed_overlay "$overlay"
  before=$(cat "$overlay")
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "none", "confidence": 0.91,
    "probabilities": { "pager": 0.05, "none": 0.9, "search_external": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-none-ov --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  write_response "$RESPONSE"
  expect_code 0 "$code" "none overlay select succeeds"
  jq -e '.primary == "none" and .skills == [] and .live_loaded == false' \
    "$HOME_DIR/state/t-none-ov.jev-skills.json" >/dev/null \
    || fail "none must not claim a live load"
  assert_equals "$before" "$(cat "$overlay")" "none must not rewrite the launch overlay"
  pass "Choice none leaves the launch overlay unchanged"
}

test_jev_failure_does_not_rewrite_overlay() {
  local code out err overlay before
  fresh_home
  : > "$HOME_DIR/config/jev-skill-select-live"
  overlay="$HOME_DIR/data/t-fail-ov/launch-brief.md"
  mkdir -p "$(dirname "$overlay")"
  seed_overlay "$overlay"
  before=$(cat "$overlay")
  FAKE_CURL_FAIL=1 FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-fail-ov --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  expect_code 0 "$code" "Jev failure must not fail the selector"
  jq -e '.status == "error" and .live_loaded == false' \
    "$HOME_DIR/state/t-fail-ov.jev-skills.json" >/dev/null \
    || fail "Jev failure must record error and live_loaded false"
  assert_equals "$before" "$(cat "$overlay")" "Jev failure must not rewrite the launch overlay"
  pass "Jev failure records error, skips load, and exits 0"
}

test_codex_overlay_uses_dollar_form() {
  local code out err overlay
  fresh_home
  : > "$HOME_DIR/config/jev-skill-select-live"
  overlay="$HOME_DIR/data/t-codex/launch-brief.md"
  mkdir -p "$(dirname "$overlay")"
  seed_overlay "$overlay"
  FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness codex --task-id t-codex --skills-dir "$SKILLS_DIR" --overlay "$overlay"
  expect_code 0 "$code" "codex overlay select succeeds"
  jq -e '.live_loaded == true' "$HOME_DIR/state/t-codex.jev-skills.json" >/dev/null \
    || fail "codex overlay must set live_loaded true"
  assert_grep "\$pager" "$overlay" "codex overlay must use dollar form"
  pass "Codex overlay uses the dollar skill form"
}

test_public_roster_uses_descriptions() {
  local code out err body
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-roster --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "public roster select succeeds"
  body=$(cat "$LOG/body")
  assert_contains "$body" 'Find and explain pager workflows.' "roster sends pager description"
  assert_contains "$body" 'Review code changes carefully.' "roster sends review description"
  jq -e '.shadow == true and .status == "recommended"' \
    "$HOME_DIR/state/jev-skill-shadow/cases/t-roster.json" >/dev/null \
    || fail "roster record must be a shadow recommendation"
  pass "the complete public roster uses real descriptions"
}

test_none_choice_records_empty_skills() {
  local code out err
  fresh_home
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "none", "confidence": 0.91,
    "probabilities": { "pager": 0.05, "review": 0.05, "none": 0.9 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-none --skills-dir "$SKILLS_DIR"
  write_response "$RESPONSE"
  expect_code 0 "$code" "none choice exits 0"
  jq -e '.status == "none" and .reason == "low_or_none"' \
    "$HOME_DIR/state/jev-skill-shadow/cases/t-none.json" >/dev/null \
    || fail "none must record no recommendation"
  pass "Choice none records no optional skill"
}

test_public_markdown_and_full_roster() {
  local code out err i old_skills=$SKILLS_DIR
  SKILLS_DIR="$TMP_ROOT/full-roster/.agents/skills"
  mkdir -p "$SKILLS_DIR"
  for i in $(seq -w 1 101); do
    mkdir -p "$SKILLS_DIR/skill-$i"
    printf '%s\n' '---' "name: skill-$i" 'description: Use "approved" public workflows.' '---' '# Public procedure' > "$SKILLS_DIR/skill-$i/SKILL.md"
  done
  mkdir -p "$SKILLS_DIR/typesafe-ai"
  printf '%s\n' '---' 'name: typesafe-ai' 'description: Build "typed" AI.' '---' '# Build with TypeSafe' 'Use the public API.' > "$SKILLS_DIR/typesafe-ai/SKILL.md"
  fresh_home
  python3 - "$RESPONSE" "$RESPONSE2" <<'PYTHON'
import json, sys
ids = [f'skill-{i:03}' for i in range(1, 102)] + ['typesafe-ai', 'none']
p = dict.fromkeys(ids, 0)
p['typesafe-ai'] = .9
p['none'] = .1
json.dump({'model':'jev-1.13.0','answers':{'skill':{'type':'choice','choice':'typesafe-ai','confidence':.9,'probabilities':p}}}, open(sys.argv[1], 'w'))
json.dump({'model':'jev-1.13.0','answers':{'detail':{'type':'choice','choice':'typesafe-ai','confidence':.9,'probabilities':{'typesafe-ai':.9,'skill-001':0,'skill-002':0,'none':.1}},'fit_typesafe-ai':{'type':'noul','noul':.9},'fit_skill-001':{'type':'noul','noul':.1},'fit_skill-002':{'type':'noul','noul':.1}}}, open(sys.argv[2], 'w'))
PYTHON
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id full --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "full roster select succeeds: $err"
  jq -e '.questions.skill.criteria | length == 103' "$LOG/first-body" >/dev/null || fail "all 102 approved skills must be offered"
  jq -e '.state.candidates | any(.id == "typesafe-ai" and (.evidence | contains("# Build with TypeSafe")))' "$LOG/body" >/dev/null || fail "approved heading must reach all detail questions"
  jq -e '.status == "recommended" and .decisions.stage2.choice == "typesafe-ai"' "$HOME_DIR/state/jev-skill-shadow/cases/full.json" >/dev/null || fail "late public candidate must be recommended"
  printf 'private instructions changed\n' >> "$SKILLS_DIR/typesafe-ai/SKILL.md"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id changed --skills-dir "$SKILLS_DIR"
  jq -e '.questions.skill.criteria | has("typesafe-ai") | not' "$LOG/first-body" >/dev/null || fail "changed unapproved content must not be sent"
  SKILLS_DIR=$old_skills
  write_response "$RESPONSE"
  cp "$TMP_ROOT/original-response2.json" "$RESPONSE2"
  pass "complete approved public roster preserves quotes and Markdown"
}

test_invalid_detail_retains_usage() {
  local code out err kind
  for kind in choice noul; do
    fresh_home
    jq --arg kind "$kind" 'if $kind == "choice" then .answers.detail.choice = "absent" else .answers.fit_pager.noul = 2 end' "$TMP_ROOT/original-response2.json" > "$RESPONSE2"
    TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id invalid --skills-dir "$SKILLS_DIR"
    jq -e '.status == "error" and .token_totals == {input_tokens:100,output_tokens:30}' "$HOME_DIR/state/jev-skill-shadow/cases/invalid.json" >/dev/null || fail "invalid detail must retain both billable calls"
  done
  cp "$TMP_ROOT/original-response2.json" "$RESPONSE2"
  pass "invalid Choice and Noul retain total usage"
}

test_timeout_retains_case_and_wall_latency() {
  local code out err
  fresh_home
  FAKE_FIRST_DELAY=2 FAKE_DETAIL_DELAY=10 TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id timeout --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "timeout remains advisory"
  jq -e '.status == "error" and .reason == "timeout" and .latency_ms >= 5600 and .latency_ms < 6000 and .token_totals.input_tokens == 40' "$HOME_DIR/state/jev-skill-shadow/cases/timeout.json" >/dev/null || fail "deadline must preserve stage-one usage and full elapsed time"
  fresh_home
  cat > "$FAKEBIN/shasum" <<'SH'
#!/usr/bin/env bash
sleep .3
exec /usr/bin/shasum "$@"
SH
  chmod +x "$FAKEBIN/shasum"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id latency --skills-dir "$SKILLS_DIR"
  rm "$FAKEBIN/shasum"
  jq -e '.status == "recommended" and .latency_ms >= 600' "$HOME_DIR/state/jev-skill-shadow/cases/latency.json" >/dev/null || fail "hash preparation must count toward latency"
  pass "timeout evidence and complete operation latency are durable"
}

test_launch_identity_and_durable_safety_labels() {
  local code out err label count
  fresh_home
  for count in 1 2; do
    HOME="${SKILLS_DIR%/.agents/skills}" PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY "$ROOT/bin/fm-jev-skill-select.sh" --launch-id "launch-$count" --harness pi --task-id same-task --summary 'Find pager workflows' --skills-dir "$SKILLS_DIR" > /dev/null || fail "fresh launch failed"
  done
  assert_equals 2 "$(find "$HOME_DIR/state/jev-skill-shadow/cases" -name '*.json' | wc -l | tr -d ' ')" "same task needs independent launch records"
  for label in incorrect p2-exposure launch-changed roster-omission; do
    fresh_home
    TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id safety --skills-dir "$SKILLS_DIR"
    run_select code out err --harness pi --task-id safety --summary '' --comparison-label "$label"
    jq -e --arg label "$label" '.comparison_label == $label' "$HOME_DIR/state/jev-skill-shadow/cases/safety.json" >/dev/null || fail "offline label must persist"
    TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id next --skills-dir "$SKILLS_DIR"
    [ ! -f "$LOG/body" ] || fail "safety finding must stop future calls"
    jq -e '.status == "stopped"' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "safety stop must be durable"
  done
  pass "relaunch identity and all immediate stop labels are enforced"
}

test_twenty_case_checkpoint() {
  local code out err i label
  fresh_home
  for i in $(seq 1 20); do
    TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id "case-$i" --skills-dir "$SKILLS_DIR"
    [ "$i" -gt 2 ] && label=correct || label=caught
    run_select code out err --harness pi --task-id "case-$i" --comparison-label "$label"
  done
  jq -e '.cases == 20 and .caught == 2 and .status == "evaluated"' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "20 compared cases should evaluate"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id case-21 --skills-dir "$SKILLS_DIR"
  [ ! -f "$LOG/body" ] || fail "passing cohort must still refuse case 21"
  run_select code out err --harness pi --task-id case-3 --comparison-label missed
  run_select code out err --harness pi --task-id case-4 --comparison-label irrelevant
  jq -e '.status == "review-required"' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "irrelevant alone cannot settle coverage"
  run_select code out err --harness pi --task-id case-4 --comparison-label missed,irrelevant
  jq -e '.comparison_label == "missed,irrelevant"' "$HOME_DIR/state/jev-skill-shadow/cases/case-4.json" >/dev/null || fail "overlapping comparison outcomes must persist"
  jq -e '.caught == 2 and .missed == 2 and .irrelevant == 1 and .status == "stopped" and (.stop_reasons | index("coverage-not-better") != null)' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "overlapping miss must prevent false improved coverage"
  run_select code out err --harness pi --task-id case-1 --comparison-label correct
  run_select code out err --harness pi --task-id case-2 --comparison-label no-fit,irrelevant
  jq -e '.status == "stopped" and (.stop_reasons | index("coverage-not-better") != null and index("insufficient-useful-discoveries") != null)' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "comparison thresholds must stop experiment"
  run_select code out err --harness pi --task-id case-3 --comparison-label no-fit,irrelevant
  jq -e '.stop_reasons | index("irrelevant-suggestions") != null' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "extra irrelevant picks must stop experiment"
  fresh_home
  for i in $(seq 1 20); do
    if [ "$i" -le 2 ]; then
      FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id "failure-$i" --skills-dir "$SKILLS_DIR"
    else
      TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id "failure-$i" --skills-dir "$SKILLS_DIR"
    fi
  done
  jq -e '.status == "stopped" and (.stop_reasons | index("timeouts-or-invalid") != null)' "$HOME_DIR/state/jev-skill-shadow/evaluation.json" >/dev/null || fail "two service failures in 20 must stop collection"
  pass "20-case comparison and stop checkpoint block additional collection"
}

test_route_specific_pins() {
  local code out err variant expected
  for variant in typesafe fallback explicit configured; do
    fresh_home
    expected=typesafe/jev-1.13
    case "$variant" in
      typesafe)
        expected=jev-1.13.0
        FAKE_ECHO_MODEL=1 JEV_MODEL=unversioned TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id route --skills-dir "$SKILLS_DIR"
        ;;
      fallback)
        FAKE_ECHO_MODEL=1 JEV_MODEL=unversioned OPENROUTER_API_KEY=$TS_KEY run_select code out err --harness pi --task-id route --skills-dir "$SKILLS_DIR"
        ;;
      explicit)
        FAKE_ECHO_MODEL=1 JEV_ROUTE=openrouter TYPESAFE_API_KEY=$TS_KEY OPENROUTER_API_KEY=$TS_KEY run_select code out err --harness pi --task-id route --skills-dir "$SKILLS_DIR"
        ;;
      configured)
        printf '%s\n' "OPENROUTER_API_KEY=$TS_KEY" 'JEV_ROUTE=openrouter' 'JEV_MODEL=unversioned' > "$HOME_DIR/.env"
        FAKE_ECHO_MODEL=1 run_select code out err --harness pi --task-id route --skills-dir "$SKILLS_DIR"
        ;;
    esac
    expect_code 0 "$code" "route $variant remains supported"
    jq -e --arg model "$expected" '.model == $model' "$LOG/first-body" >/dev/null || fail "first call must pin selected route model"
    jq -e --arg model "$expected" '.model == $model' "$LOG/body" >/dev/null || fail "detail call must pin selected route model"
    jq -e --arg model "$expected" '.status == "recommended" and .resolved_model == $model and .experiment_id == "route"' "$HOME_DIR/state/jev-skill-shadow/cases/route.json" >/dev/null || fail "record must retain resolved route model and launch ID"
    if [ "$variant" != typesafe ]; then
      assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter must retain existing transport"
    fi
  done
  pass "both selected routes retain their versioned model identifiers"
}

test_low_choice_records_actual_noul() {
  local code out err
  fresh_home
  jq '.answers.detail.confidence = 0.79 | .answers.fit_pager.noul = 0.93' "$TMP_ROOT/original-response2.json" > "$RESPONSE2"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id low-detail --skills-dir "$SKILLS_DIR"
  jq -e '.status == "none" and .decisions.stage2.confidence == 0.79 and .decisions.stage2.chosen_fit_probability == 0.93' "$HOME_DIR/state/jev-skill-shadow/cases/low-detail.json" >/dev/null || fail "low Choice confidence must not overwrite actual Noul"
  cp "$TMP_ROOT/original-response2.json" "$RESPONSE2"
  pass "low Choice confidence preserves actual fit evidence without recommending"
}

test_shadow_requires_launch_and_public_roots() {
  local code out err outside="$TMP_ROOT/other-skills"
  fresh_home
  reset_log
  code=0
  HOME="${SKILLS_DIR%/.agents/skills}" PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY "$ROOT/bin/fm-jev-skill-select.sh" --harness pi --task-id standalone --summary 'Find pager workflows' --skills-dir "$SKILLS_DIR" >"$TMP_ROOT/standalone.out" 2>"$TMP_ROOT/standalone.err" || code=$?
  expect_code 2 "$code" "missing originating launch ID must be rejected"
  [ ! -e "$HOME_DIR/state/jev-skill-shadow" ] || fail "standalone collection must not reserve cohort cases"
  [ ! -e "$LOG/body" ] || fail "standalone collection must not call service"
  mkdir -p "$outside/pager" "$outside/review"
  cp "$SKILLS_DIR/pager/SKILL.md" "$outside/pager/SKILL.md"
  cp "$SKILLS_DIR/review/SKILL.md" "$outside/review/SKILL.md"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id outside --skills-dir "$outside"
  expect_code 0 "$code" "ineligible roots remain advisory"
  [ ! -e "$LOG/body" ] || fail "approved hashes must not permit arbitrary catalog roots"
  [ ! -e "$HOME_DIR/state/jev-skill-shadow/cases/outside.json" ] || fail "outside roots must not consume a case"
  TYPESAFE_API_KEY=$TS_KEY run_select code out err --harness pi --task-id removed-switch --public-only --skills-dir "$SKILLS_DIR"
  expect_code 2 "$code" "removed root switch must not remain an alternate path"
  pass "shadow requires worker identity and consistently restricts public roots"
}

cp "$RESPONSE2" "$TMP_ROOT/original-response2.json"

test_help_exits_0
test_missing_harness_is_usage
test_shadow_default_writes_json_not_status
test_status_note_only_when_asked
test_once_per_session_reuses_file
test_below_floor_is_uncertain
test_missing_keys_are_off_without_curl
test_live_without_confirm_refuses
test_live_without_overlay_stays_unloaded
test_live_overlay_sets_live_loaded
test_shadow_overlay_does_not_change_launch
test_none_overlay_leaves_launch_unchanged
test_jev_failure_does_not_rewrite_overlay
test_codex_overlay_uses_dollar_form
test_public_roster_uses_descriptions
test_none_choice_records_empty_skills

test_public_markdown_and_full_roster
test_invalid_detail_retains_usage
test_timeout_retains_case_and_wall_latency
test_launch_identity_and_durable_safety_labels
test_twenty_case_checkpoint

test_route_specific_pins
test_low_choice_records_actual_noul

test_shadow_requires_launch_and_public_roots
