#!/usr/bin/env bash
# Behavior tests for the live Jev skill hop into fm-spawn.sh.
#
# Fake Jev through the existing curl seam. No case touches the network.
# Assertions pin the published launch-brief overlay and live_loaded, not
# implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-spawn-jev-skill-live)
RESPONSE="$TMP_ROOT/response.json"
TS_KEY='ts-test-key-not-for-argv'

write_pager_response() {
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.82,
    "probabilities": { "pager": 0.8, "review": 0.1, "none": 0.05, "search_external": 0.05 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

write_none_response() {
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "none", "confidence": 0.91,
    "probabilities": { "pager": 0.05, "none": 0.9, "search_external": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
}

install_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${FAKE_CURL_BODY:?}"
cat /dev/fd/3 >/dev/null 2>/dev/null || true
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
  chmod +x "$fakebin/curl"
}

seed_project_skills() {
  local proj=$1
  mkdir -p "$proj/.agents/skills/pager" "$proj/.agents/skills/review"
  printf '# pager\n' > "$proj/.agents/skills/pager/SKILL.md"
  printf '# review\n' > "$proj/.agents/skills/review/SKILL.md"
  mkdir -p "$home/.agents/skills/pager"
  cat > "$home/.agents/skills/pager/SKILL.md" <<'EOF'
---
name: pager
description: Find and explain pager workflows.
---
Use pager workflows.
EOF
}

make_case() {
  local name=$1 id=$2
  local case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  install_fake_curl "$fakebin"
  fm_test_spawn_home "$home" grok
  fm_git_worktree "$proj" "$wt" "wt-$name"
  seed_project_skills "$proj"
  git -C "$proj" add .agents
  git -C "$proj" commit --quiet -m 'Add worker skills'
  git -C "$proj" push --quiet origin HEAD
  git -C "$proj" rm -r --quiet .agents
  git -C "$proj" commit --quiet -m 'Remove skills only in launching checkout'
  mkdir -p "$proj/.agents/skills/launcher-only"
  printf '# launcher only\n' > "$proj/.agents/skills/launcher-only/SKILL.md"
  fm_test_spawn_brief "$home" "$id" 'PRIVATE_EXCERPT <<<<<<< conflict lines'
  printf 'Find pager skills\n' > "$home/data/$id/jev-skill-query.txt"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_ship() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  local -a delivery=(--mode "${TEST_SHIP_MODE:-no-mistakes}" --yolo off)
  if [ "${TEST_RELAUNCH:-0}" = 1 ]; then
    delivery=(--relaunch)
  elif [ "${TEST_SCOUT:-0}" = 1 ]; then
    delivery=(--scout)
  fi
  : > "$launchlog"
  # The shared curl recorder belongs to skill selection, not brief preflight.
  # Keep that independent spawn-time Jev consumer out of this fixture.
  FM_JEV_BRIEF_PREFLIGHT=off \
  FAKE_CURL_BODY="$home/request.json" FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" "${delivery[@]}" --harness "${TEST_HARNESS:-grok}"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<EOF
$1
EOF
}

test_shadow_launch_is_log_only() {
  local rec out status record overlay first_id second_id window TEST_RELAUNCH=0
  write_pager_response
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.9,
    "probabilities": { "pager": 0.9, "none": 0.1 } } },
  "usage": { "input_tokens": 10, "output_tokens": 4 } }
JSON
  rec=$(make_case shadow-log t-shadow-log)
  read_case "$rec"
  mkdir -p "$HOME_DIR/user-home/.pi/agent/skills/pager"
  cp "$HOME_DIR/.agents/skills/pager/SKILL.md" "$HOME_DIR/user-home/.pi/agent/skills/pager/SKILL.md"
  shasum -a 256 "$HOME_DIR/.agents/skills/pager/SKILL.md" | awk '{print $1}' | jq -Rsc 'split("\n")[:-1]' > "$HOME_DIR/config/jev-skill-public.json"
  rm -rf "$HOME_DIR/.agents/skills"
  out=$(HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY run_ship \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "shadow launch should succeed: $out"
  record=$(printf '%s\n' "$HOME_DIR"/state/jev-skill-shadow/cases/*.json)
  overlay="$HOME_DIR/data/$ID/launch-brief.md"
  assert_present "$record" "shadow launch did not write an experiment record"
  jq -e '.shadow == true and ((.live_loaded // false) == false)' "$record" >/dev/null \
    || fail "shadow launch must never mark a live load"
  assert_no_grep '# Jev-selected skills' "$overlay" \
    "shadow launch must not mutate the launch overlay"
  first_id=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$ID.meta")
  assert_equals "$first_id" "$(jq -r '.experiment_id' "$record")" "case ID must identify the worker launch"
  assert_equals "$first_id" "$(cat "$HOME_DIR/data/$ID/jev-skill-launches")" "task must retain launch association"
  jq -e '.questions | (.skill.criteria // .detail.criteria) | has("pager")' "$HOME_DIR/request.json" >/dev/null || fail "approved Pi-only skill must be offered"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-spawn"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
  *'#{pane_tty}'*) exit 0 ;;
esac
exec "$(dirname "$0")/tmux-spawn" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  TEST_RELAUNCH=1
  window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  out=$(FM_FAKE_DUPLICATE_WINDOW="${window#*:}" HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY run_ship \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID")
  status=$?
  expect_code 0 "$status" "shadow relaunch succeeds: $out"
  second_id=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$ID.meta")
  [ "$first_id" != "$second_id" ] || fail "relaunch needs independent case ID"
  assert_equals "$first_id"$'\n'"$second_id" "$(cat "$HOME_DIR/data/$ID/jev-skill-launches")" "both launch associations must survive"
  record="$HOME_DIR/state/jev-skill-shadow/cases/$second_id.json"
  jq -e --arg id "$second_id" '.experiment_id == $id' "$record" >/dev/null || fail "relaunch case must use same ID as metadata"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-jev-skill-select.sh" --harness grok --task-id "$ID" --launch-id "$second_id" --comparison-label no-fit >/dev/null || fail "record ID must work for offline labeling"
  jq -e '.comparison_label == "no-fit"' "$record" >/dev/null || fail "label must persist on originating launch"
  assert_no_grep '# Jev-selected skills' "$overlay" "shadow relaunch must preserve instructions"
  pass "shadow launch associations survive relaunch and approved Pi-only skills are offered"
}

test_live_selection_reaches_overlay() {
  local rec out status overlay record
  write_pager_response
  rec=$(make_case live-load t-live-load)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "live spawn should succeed: $out"
  overlay="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$overlay" "live spawn did not publish launch-brief.md"
  assert_present "$record" "live spawn did not write the skill record"
  jq -e '.live_loaded == true and .primary == "pager" and (.skills | index("pager") != null)' \
    "$record" >/dev/null \
    || fail "live spawn must set live_loaded true for pager"
  assert_grep '# Jev-selected skills' "$overlay" "launch-brief missing selected skills"
  assert_grep '/pager' "$overlay" "launch-brief did not carry pager in grok form"
  assert_grep '# Current worker role contract' "$overlay" "launch-brief lost the worker role"
  assert_grep "$WT_DIR/.agents/skills/pager/SKILL.md" "$overlay" "overlay must locate the worker skill file"
  assert_present "$WT_DIR/.agents/skills/pager/SKILL.md" "freshness must install the selected skill"
  jq -e 'tostring | contains("Find pager skills") and (contains("PRIVATE_EXCERPT") | not) and (contains("launcher-only") | not)' \
    "$HOME_DIR/request.json" >/dev/null || fail "request must use only the safe query and worker catalog"
  pass "live selection reaches the launch overlay and live_loaded is true"
}

test_relaunch_clears_live_evidence() {
  local reason rec out status record cached window TEST_RELAUNCH
  for reason in disabled missing-query; do
    TEST_RELAUNCH=0
    write_pager_response
    rec=$(make_case "relaunch-$reason" "t-relaunch-$reason")
    read_case "$rec"
    : > "$HOME_DIR/config/jev-skill-select-live"
    out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
      run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "initial live spawn must succeed: $out"
    record="$HOME_DIR/state/$ID.jev-skills.json"
    jq -e '.live_loaded == true and .primary == "pager"' "$record" >/dev/null \
      || fail "initial launch must load pager"
    assert_grep '# Jev-selected skills' "$HOME_DIR/data/$ID/launch-brief.md" "initial overlay must load skills"
    cached=$(jq -S 'del(.live_loaded)' "$record")
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-spawn"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
  *'#{pane_tty}'*) exit 0 ;;
esac
exec "$(dirname "$0")/tmux-spawn" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    if [ "$reason" = disabled ]; then
      rm "$HOME_DIR/config/jev-skill-select-live"
    else
      rm "$HOME_DIR/data/$ID/jev-skill-query.txt"
    fi
    rm "$HOME_DIR/request.json"
    TEST_RELAUNCH=1
    window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
    out=$(FM_FAKE_DUPLICATE_WINDOW="${window#*:}" FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
      run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID")
    status=$?
    expect_code 0 "$status" "$reason relaunch must succeed: $out"
    assert_no_grep 'Jev-selected skills' "$HOME_DIR/data/$ID/launch-brief.md" "$reason relaunch must omit skills"
    jq -e '.live_loaded == false' "$record" >/dev/null \
      || fail "$reason relaunch must clear stale live_loaded"
    assert_equals "$cached" "$(jq -S 'del(.live_loaded)' "$record")" "relaunch must retain cached selection"
    assert_absent "$HOME_DIR/request.json" "skipped selection must not contact Jev"
  done
  pass "disabled and missing-query relaunches clear live evidence and retain cached selections"
}

test_disabled_and_none_match_today() {
  local rec out status overlay_disabled overlay_none record
  write_pager_response
  rec=$(make_case disabled t-disabled)
  read_case "$rec"
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "disabled spawn should succeed: $out"
  overlay_disabled="$HOME_DIR/data/$ID/launch-brief.md"
  assert_present "$overlay_disabled" "disabled spawn did not publish launch-brief.md"
  assert_no_grep 'Jev-selected skills' "$overlay_disabled" \
    "disabled spawn must not inject a skills section"
  assert_absent "$HOME_DIR/state/$ID.jev-skills.json" \
    "disabled spawn must not write a skill record"

  write_none_response
  rec=$(make_case none t-none)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "none spawn should succeed: $out"
  overlay_none="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$record" "none spawn should still record the suggestion"
  jq -e '.primary == "none" and .live_loaded == false and .skills == []' "$record" >/dev/null \
    || fail "none spawn must record empty skills and live_loaded false"
  assert_no_grep 'Jev-selected skills' "$overlay_none" \
    "none spawn must not inject a skills section"
  pass "disabled and none launches match today's overlay shape"
}

test_jev_failure_does_not_block_spawn() {
  local rec out status overlay record
  write_pager_response
  rec=$(make_case jev-fail t-jev-fail)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY FAKE_CURL_FAIL=1 \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Jev failure must not refuse spawn: $out"
  overlay="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$overlay" "failed Jev still publishes launch-brief.md"
  assert_contains "$out" "spawned $ID harness=grok" "failed Jev lost the spawn report"
  assert_no_grep 'Jev-selected skills' "$overlay" \
    "failed Jev must not inject a skills section"
  if [ -f "$record" ]; then
    jq -e '.live_loaded == false' "$record" >/dev/null \
      || fail "failed Jev must not claim live_loaded true"
  fi
  pass "Jev failure does not block spawn and does not load skills"
}

test_missing_safe_query_skips_selection() {
  local shape rec out status TEST_SCOUT TEST_SHIP_MODE
  for shape in modern legacy legacy-scout legacy-direct blank; do
    write_pager_response
    rec=$(make_case "query-$shape" "t-query-$shape")
    read_case "$rec"
    : > "$HOME_DIR/config/jev-skill-select-live"
    rm "$HOME_DIR/data/$ID/jev-skill-query.txt"
    if [[ "$shape" = legacy* ]]; then
      printf '# Task\n[captain] PRIVATE_EXCERPT <<<<<<< conflict lines\n' > "$HOME_DIR/data/$ID/brief.md"
    elif [ "$shape" = blank ]; then
      printf '  \n \t\n' > "$HOME_DIR/data/$ID/jev-skill-query.txt"
    fi
    TEST_SCOUT=0 TEST_SHIP_MODE=no-mistakes
    [ "$shape" != legacy-scout ] || TEST_SCOUT=1
    [ "$shape" != legacy-direct ] || TEST_SHIP_MODE=direct-PR
    out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
      run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "missing safe query must not block $shape spawn: $out"
    assert_absent "$HOME_DIR/request.json" "missing safe query must never contact Jev"
    assert_absent "$HOME_DIR/state/$ID.jev-skills.json" "missing safe query must skip selection"
    assert_no_grep 'Jev-selected skills' "$HOME_DIR/data/$ID/launch-brief.md" "missing safe query must not inject skills"
  done
  pass "modern, legacy, and blank queries skip selection without contacting Jev"
}


test_codex_skill_locations() {
  local location rec out status skill_root overlay TEST_HARNESS CODEX_HOME
  for location in default override other-harness; do
    rec=$(make_case "codex-$location" "t-codex-$location")
    read_case "$rec"
    TEST_HARNESS=codex
    CODEX_HOME=''
    skill_root="$HOME_DIR/user-home/.codex/skills"
    if [ "$location" != default ]; then
      CODEX_HOME="$HOME_DIR/custom-codex"
      skill_root="$CODEX_HOME/skills"
      mkdir -p "$HOME_DIR/user-home/.codex/skills/default-only"
      printf '# default only\n' > "$HOME_DIR/user-home/.codex/skills/default-only/SKILL.md"
    fi
    mkdir -p "$skill_root/codex-only"
    printf '# codex only\n' > "$skill_root/codex-only/SKILL.md"
    : > "$HOME_DIR/config/jev-skill-select-live"
    cat > "$RESPONSE" <<'JSON'
{"answers":{"skill":{"type":"choice","choice":"codex-only","confidence":0.95,"probabilities":{"codex-only":0.95,"none":0.05}}}}
JSON
    if [ "$location" = other-harness ]; then
      TEST_HARNESS=grok
      write_none_response
    fi
    out=$(CODEX_HOME="$CODEX_HOME" FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
      run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$location skill discovery must not block spawn: $out"
    if [ "$location" = other-harness ]; then
      jq -e 'tostring | contains("codex-only") | not' "$HOME_DIR/request.json" >/dev/null \
        || fail "other harness must not discover Codex-only skills"
    else
      jq -e 'tostring | contains("codex-only") and (contains("default-only") | not)' \
        "$HOME_DIR/request.json" >/dev/null || fail "Codex must offer skills from its selected home only"
      jq -e '.live_loaded == true and .primary == "codex-only"' \
        "$HOME_DIR/state/$ID.jev-skills.json" >/dev/null || fail "Codex skill must be loaded"
      overlay="$HOME_DIR/data/$ID/launch-brief.md"
      assert_contains "$(cat "$overlay")" "$skill_root/codex-only/SKILL.md" "overlay must locate Codex skill"
      assert_contains "$(cat "$overlay")" "\$codex-only" "overlay must use Codex skill form"
    fi
  done
  pass "Codex discovers default and overridden skill homes only for Codex launches"
}

test_shadow_launch_is_log_only
test_relaunch_clears_live_evidence
test_live_selection_reaches_overlay
test_disabled_and_none_match_today
test_jev_failure_does_not_block_spawn
test_missing_safe_query_skips_selection
test_codex_skill_locations
