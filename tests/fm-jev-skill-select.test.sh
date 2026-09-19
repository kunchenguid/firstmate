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
SKILLS_DIR="$TMP_ROOT/skills"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG" "$SKILLS_DIR/pager" "$SKILLS_DIR/review"
printf "# pager\n" > "$SKILLS_DIR/pager/SKILL.md"
printf "# review\n" > "$SKILLS_DIR/review/SKILL.md"

write_response() {
  cat > "$1" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.82,
    "probabilities": { "pager": 0.8, "review": 0.1, "none": 0.05, "search_external": 0.05 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

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

RESPONSE="$TMP_ROOT/response.json"
write_response "$RESPONSE"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run_select <exit-var> <out-var> <err-var> [args...]
run_select() {
  local __exit=$1 __out=$2 __err=$3 _out _errfile _code
  shift 3
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
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
}

test_help_exits_0() {
  local code out err
  run_select code out err --help
  expect_code 0 "$code" "--help exits 0"
  assert_contains "$out" 'once-per-session' "--help prints the header"
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
  record="$HOME_DIR/state/t-shadow.jev-skills.json"
  [ -f "$record" ] || fail "shadow must write state/<id>.jev-skills.json"
  assert_contains "$out" '"status": "clear"' "stdout is the JSON record"
  jq -e '.mode == "shadow" and .status == "clear" and .primary == "pager"
      and .live_loaded == false and .once == true and .floor == 0.7
      and (.skills | index("pager") != null)' "$record" >/dev/null \
    || fail "shadow record must be clear, mode shadow, live_loaded false"
  [ ! -e "$HOME_DIR/state/t-shadow.status" ] || fail "shadow must not append a status note by default"
  assert_contains "$(cat "$LOG/body")" '"type": "choice"' "Jev is asked one Choice question"
  assert_contains "$(cat "$LOG/body")" '"none"' "Choice includes none"
  assert_contains "$(cat "$LOG/body")" '"search_external"' "Choice includes search_external"
  assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from the curl environment"
  pass "default shadow writes JSON, skips status, and does not load skills"
}

test_status_note_only_when_asked() {
  local code out err
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-note --skills-dir "$SKILLS_DIR" --status-note
  expect_code 0 "$code" "status-note select succeeds"
  [ -f "$HOME_DIR/state/t-note.status" ] || fail "--status-note must append state/<id>.status"
  assert_contains "$(cat "$HOME_DIR/state/t-note.status")" 'note: jev-skills clear primary=pager' \
    "status note names the shadow suggestion"
  pass "--status-note appends one status line and is otherwise opt-in"
}

test_once_per_session_reuses_file() {
  local code out err first_stamp
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-once --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "first select succeeds"
  [ -f "$LOG/argv" ] || fail "first select must call curl"
  first_stamp=$(wc -c < "$HOME_DIR/state/t-once.jev-skills.json")
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-once --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "reuse select succeeds without curl"
  [ ! -e "$LOG/argv" ] || fail "reuse must not call curl"
  assert_contains "$out" '"reused": true' "reuse prints reused true"
  assert_equals "$first_stamp" "$(wc -c < "$HOME_DIR/state/t-once.jev-skills.json")" \
    "reuse must not rewrite the recorded suggestion"
  pass "a second call reuses state/<id>.jev-skills.json and does not call Jev"
}

test_below_floor_is_uncertain() {
  local code out err
  fresh_home
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.4,
    "probabilities": { "pager": 0.55, "none": 0.4, "search_external": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-low --skills-dir "$SKILLS_DIR"
  write_response "$RESPONSE"
  expect_code 0 "$code" "below-floor select exits 0"
  jq -e '.status == "uncertain" and .primary == "pager" and .live_loaded == false' \
    "$HOME_DIR/state/t-low.jev-skills.json" >/dev/null \
    || fail "below 0.7 must record status uncertain"
  pass "confidence below 0.7 records status uncertain"
}

test_missing_keys_are_off_without_curl() {
  local code out err
  fresh_home
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  run_select code out err --harness pi --task-id t-off --skills-dir "$SKILLS_DIR"
  expect_code 0 "$code" "missing keys exit 0"
  assert_contains "$err" 'jev-skill-select: off' "missing keys explain off"
  [ ! -e "$HOME_DIR/state/t-off.jev-skills.json" ] || fail "off must not write a sticky suggestion"
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
  printf '# pager\n' > "$SKILLS_DIR/pager/SKILL.md"
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
  jq -e '.mode == "shadow" and .live_loaded == false' \
    "$HOME_DIR/state/t-shadow-ov.jev-skills.json" >/dev/null \
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

test_skills_from_stdin() {
  local code out err body
  fresh_home
  reset_log
  code=0
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY \
    "$ROOT/bin/fm-jev-skill-select.sh" --harness pi --task-id t-stdin --stdin \
    <<<"pager
review" 2> "$TMP_ROOT/stderr") || code=$?
  err=$(cat "$TMP_ROOT/stderr")
  expect_code 0 "$code" "stdin select succeeds"
  body=$(cat "$LOG/body")
  assert_contains "$body" '"pager"' "stdin skill pager is offered"
  assert_contains "$body" '"review"' "stdin skill review is offered"
  jq -e '.primary == "pager"' "$HOME_DIR/state/t-stdin.jev-skills.json" >/dev/null \
    || fail "stdin select must record the Jev choice"
  pass "installed skills can be read from stdin"
}

test_none_choice_records_empty_skills() {
  local code out err
  fresh_home
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "none", "confidence": 0.91,
    "probabilities": { "pager": 0.05, "none": 0.9, "search_external": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  TYPESAFE_API_KEY=$TS_KEY run_select code out err \
    --harness pi --task-id t-none --skills-dir "$SKILLS_DIR"
  write_response "$RESPONSE"
  expect_code 0 "$code" "none choice exits 0"
  jq -e '.primary == "none" and .skills == [] and .status == "clear"' \
    "$HOME_DIR/state/t-none.jev-skills.json" >/dev/null \
    || fail "none must record an empty skills list"
  pass "Choice none records no skills to load"
}

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
test_skills_from_stdin
test_none_choice_records_empty_skills
