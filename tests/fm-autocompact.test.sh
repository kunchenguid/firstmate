#!/usr/bin/env bash
# Behavior tests for Claude Code's deterministic and judgment-aware autocompact bridge.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153
AUTOCOMPACT="$ROOT/bin/fm-autocompact.sh"
fm_test_tmproot_into TMP_ROOT fm-autocompact-tests
fm_git_identity fmtest fmtest@example.invalid

new_primary() {
  local root="$TMP_ROOT/$1/root" home="$TMP_ROOT/$1/home"
  fm_git_init_commit "$root"
  mkdir -p "$root/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Firstmate fixture\n' > "$root/AGENTS.md"
  printf '%s|%s\n' "$root" "$home"
}

capture() {
  local root=$1 home=$2 trigger=${3:-auto}
  printf '{"hook_event_name":"PreCompact","trigger":"%s","session_id":"session-%s","transcript_path":"%s/transcript.jsonl"}\n' \
    "$trigger" "$trigger" "$home" \
    | FM_AUTOCOMPACT_JUDGMENT=off FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" capture
}

write_transcript() {
  local path=$1 message=$2
  jq -cn --arg message "$message" \
    '{type:"user",isMeta:false,message:{role:"user",content:$message}}' > "$path"
}

seed_pending_memory_transaction() {
  local home=$1 before
  before=$(printf '%s\n' '# Captain preferences' '- Before transaction.')
  printf '%s\n' '# Captain preferences' '- Partially published value.' > "$home/data/captain.md"
  jq -cn --arg content "$before" \
    '{version:1,before:{"captain.md":{present:true,content:($content + "\n")}}}' \
    > "$home/data/.firstmate-data-transaction.json"
}

fake_judgment_claude() {
  local dir=$1 mode=$2 fake
  fake="$dir/claude"
  mkdir -p "$dir"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
case "$FM_FAKE_JUDGMENT_MODE" in
  preference)
    printf '%s\n' '{"is_error":false,"structured_output":{"result":"changes","summary":"captain preference","edits":[{"path":"captain.md","old_text":"# Captain preferences\n\n- Prefer concise reports.\n","new_text":"# Captain preferences\n\n- Prefer concise reports.\n- Use UTC timestamps in completion reports.\n","reason":"durable working-style preference"}]}}'
    ;;
  concurrent)
    "$FM_FAKE_DATA_WRITER" --data "$FM_FAKE_DATA" -- sh -c \
      'printf "%s\n" "# Captain preferences" "" "- Concurrent writer owns this value." > "$1"' sh "$FM_FAKE_CAPTAIN"
    printf '%s\n' '{"is_error":false,"structured_output":{"result":"changes","summary":"captain preference","edits":[{"path":"captain.md","old_text":"# Captain preferences\n\n- Prefer concise reports.\n","new_text":"# Captain preferences\n\n- Prefer concise reports.\n- Use UTC timestamps in completion reports.\n","reason":"durable working-style preference"}]}}'
    ;;
  multi)
    printf '%s\n' '{"is_error":false,"structured_output":{"result":"changes","summary":"preference and learning","edits":[{"path":"captain.md","old_text":"# Captain preferences\n","new_text":"# Captain preferences\n\n- Prefer UTC.\n","reason":"preference"},{"path":"learnings.md","old_text":"# Fleet learnings\n","new_text":"# Fleet learnings\n\n- Preserve writer locks.\n","reason":"learning"}]}}'
    ;;
  timeout)
    sleep 30
    ;;
  failure)
    exit 41
    ;;
  delayed-success)
    : > "$FM_FAKE_JUDGMENT_READY"
    while [ ! -f "$FM_FAKE_JUDGMENT_RELEASE" ]; do
      sleep 0.01
    done
    printf '%s\n' '{"is_error":false,"structured_output":{"result":"no_changes","summary":"nothing durable","edits":[]}}'
    ;;
  *)
    printf '%s\n' '{"is_error":false,"structured_output":{"result":"no_changes","summary":"nothing durable","edits":[]}}'
    ;;
esac
EOF
  chmod +x "$fake"
  FM_FAKE_JUDGMENT_MODE=$mode printf '%s\n' "$fake"
}

test_tracked_hook_registration_preserves_existing_hooks() {
  local settings="$ROOT/.claude/settings.json" pre recover timeout
  pre=$(jq -r '.hooks.PreCompact[]?.hooks[]?.command // empty' "$settings")
  recover=$(jq -r '.hooks.SessionStart[]? | select(.matcher == "compact") | .hooks[]?.command // empty' "$settings")
  timeout=$(jq -r '.hooks.PreCompact[]?.hooks[]? | select(.command | contains("fm-autocompact.sh capture")) | .timeout' "$settings")
  assert_contains "$pre" "\"\$CLAUDE_PROJECT_DIR\"/bin/fm-autocompact.sh capture" "PreCompact hook is not project-root anchored"
  assert_contains "$recover" "\"\$CLAUDE_PROJECT_DIR\"/bin/fm-autocompact.sh recover" "compact SessionStart hook is not project-root anchored"
  [ "$timeout" = 180 ] || fail "PreCompact hook does not reserve the measured 180s outer budget"
  [ "$(jq '.hooks.Stop | length' "$settings")" -gt 0 ] || fail "Stop hooks were disturbed"
  [ "$(jq '.hooks.PreToolUse | length' "$settings")" -gt 0 ] || fail "PreToolUse hooks were disturbed"
  pass "tracked Claude settings register both compaction phases without disturbing existing hooks"
}

test_capture_writes_fresh_durable_anchor() {
  local rec root home anchor first second
  rec=$(new_primary capture)
  IFS='|' read -r root home <<EOF
$rec
EOF
  mkdir -p "$home/worktree"
  printf '%s\n' '# backlog-v1' '## Queued' '- [ ] queued-1 - Follow-up task blocked-by: active-1 - wait for held merge' > "$home/data/backlog.md"
  fm_write_meta "$home/state/active-1.meta" \
    'window=firstmate:fm-active-1' \
    "worktree=$home/worktree" \
    'kind=ship' \
    'pr=https://github.com/example/firstmate/pull/123' \
    'mode=no-mistakes'
  printf '%s\n' 'needs-decision: PR held for captain merge [key=merge-hold]' > "$home/state/active-1.status"

  capture "$root" "$home" manual
  anchor="$home/data/autocompact-resume.md"
  assert_present "$anchor" "PreCompact did not write the resume anchor"
  first=$(cat "$anchor")
  assert_contains "$first" "Trigger: \`manual\`" "manual trigger was not captured"
  assert_contains "$first" 'Judgment capture: FAILED - judgment capture was disabled' "disabled judgment capture was silently omitted"
  assert_contains "$first" 'in_flight[1]' "live fleet pickup state is missing"
  assert_contains "$first" 'PR held for captain merge' "held merge decision is missing"
  assert_contains "$first" 'https://github.com/example/firstmate/pull/123' "recorded PR is missing"
  assert_contains "$first" '# backlog-v1' "full backlog is missing"
  assert_contains "$first" 'window=firstmate:fm-active-1' "raw in-flight metadata is missing"

  printf '%s\n' '# backlog-v2' '## Queued' '- [ ] queued-2 - Replacement next step' > "$home/data/backlog.md"
  capture "$root" "$home" auto
  second=$(cat "$anchor")
  assert_contains "$second" "Trigger: \`auto\`" "automatic trigger was not captured"
  assert_contains "$second" '# backlog-v2' "fresh backlog did not replace the prior anchor"
  assert_not_contains "$second" '# backlog-v1' "capture appended instead of atomically replacing the anchor"
  pass "PreCompact atomically refreshes all durable pickup surfaces"
}

test_capture_is_inert_in_child_worktree() {
  local parent="$TMP_ROOT/worktree/parent" child="$TMP_ROOT/worktree/child" home="$TMP_ROOT/worktree/home" out
  fm_git_worktree "$parent" "$child" task-branch
  mkdir -p "$child/bin" "$home/state" "$home/data"
  printf '# Firstmate fixture\n' > "$child/AGENTS.md"
  out=$(capture "$child" "$home" auto 2>&1)
  [ -z "$out" ] || fail "child worktree capture was noisy: $out"
  assert_absent "$home/data/autocompact-resume.md" "child worktree wrote a primary resume anchor"
  pass "tracked hook is a silent no-op in a crewmate worktree"
}

test_capture_failure_blocks_compaction() {
  local rec root home rc out
  rec=$(new_primary failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  mv "$home/data" "$home/data-real"
  ln -s "$home/data-real" "$home/data"
  set +e
  out=$(capture "$root" "$home" auto 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "failed primary capture"
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT CAPTURE FAILED' "capture failure was not surfaced"
  assert_absent "$home/data/autocompact-resume.md" "failed capture published a partial anchor"
  pass "an in-scope capture failure blocks compaction instead of silently losing the anchor"
}

test_capture_and_recovery_do_not_require_jq() {
  local rec root home no_jq anchor capture_out recover_out
  rec=$(new_primary no-jq)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# no-jq-backlog' > "$home/data/backlog.md"
  fm_write_meta "$home/state/no-jq-1.meta" 'window=firstmate:fm-no-jq-1' 'kind=ship'
  no_jq="$TMP_ROOT/no-jq/bash-env"
  mkdir -p "$(dirname "$no_jq")"
  cat > "$no_jq" <<'EOF'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
EOF

  capture_out=$(printf '%s\n' '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"session-no-jq","transcript_path":"/tmp/no-jq.jsonl"}' \
    | FM_AUTOCOMPACT_JUDGMENT=off BASH_ENV="$no_jq" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" capture 2>&1)
  anchor="$home/data/autocompact-resume.md"
  assert_present "$anchor" "capture without jq did not publish an anchor"
  assert_contains "$capture_out" 'FIRSTMATE AUTOCOMPACT CAPTURE LIMITED' "missing jq was not surfaced loudly"
  assert_contains "$(cat "$anchor")" 'LIMITED - jq is unavailable' "limited anchor did not explain the omitted projection"
  assert_contains "$(cat "$anchor")" '# no-jq-backlog' "capture without jq omitted the raw backlog"
  assert_contains "$(cat "$anchor")" 'window=firstmate:fm-no-jq-1' "capture without jq omitted in-flight metadata"

  recover_out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-no-jq"}' \
    | BASH_ENV="$no_jq" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  assert_contains "$recover_out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "recovery without jq emitted no context"
  assert_contains "$recover_out" '# no-jq-backlog' "recovery without jq omitted the durable anchor"
  assert_contains "$recover_out" 'NORMAL SESSION-START RECONCILIATION' "recovery without jq skipped reconciliation output"
  pass "capture and compact recovery preserve durable context without jq"
}

test_intermediate_render_failure_preserves_prior_anchor() {
  local rec root home anchor prior out rc fakebin real_sed
  local -a leftovers
  rec=$(new_primary render-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# render-v1' > "$home/data/backlog.md"
  capture "$root" "$home" auto
  anchor="$home/data/autocompact-resume.md"
  prior=$(cat "$anchor")
  printf '%s\n' '# render-v2' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$TMP_ROOT/render-failure")
  real_sed=$(command -v sed)
  cat > "$fakebin/sed" <<'EOF'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_AUTOCOMPACT_FAIL_FILE" ]; then
  exit 71
fi
exec "$FM_AUTOCOMPACT_REAL_SED" "$@"
EOF
  chmod +x "$fakebin/sed"

  set +e
  out=$(printf '%s\n' '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"session-render","transcript_path":"/tmp/render.jsonl"}' \
    | PATH="$fakebin:$PATH" \
      FM_AUTOCOMPACT_JUDGMENT=off \
      FM_AUTOCOMPACT_FAIL_FILE="$home/data/backlog.md" \
      FM_AUTOCOMPACT_REAL_SED="$real_sed" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "intermediate anchor render failure"
  assert_contains "$out" 'could not render the resume anchor' "intermediate render failure was not surfaced"
  [ "$(cat "$anchor")" = "$prior" ] || fail "intermediate render failure replaced the prior good anchor"
  shopt -s nullglob
  leftovers=("$home/data"/.autocompact-resume.md.*)
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ] || fail "intermediate render failure left a temporary anchor"
  pass "every intermediate render failure blocks partial anchor publication"
}

test_judgment_capture_routes_conversation_only_preference() {
  local rec root home transcript fake anchor out
  rec=$(new_primary judgment-success)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Please remember this standing preference: use UTC timestamps in every completion report.'
  printf '%s\n' '# Captain preferences' '' '- Prefer concise reports.' > "$home/data/captain.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-success" preference)

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-judgment\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=preference \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture

  anchor="$home/data/autocompact-resume.md"
  assert_grep 'Use UTC timestamps in completion reports.' "$home/data/captain.md" "conversation-only preference was not routed to captain.md"
  assert_grep 'Judgment capture: COMPLETE' "$anchor" "successful judgment capture was not marked complete"
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-judgment"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  assert_contains "$out" 'Use UTC timestamps in completion reports.' "compact SessionStart did not surface captured judgment"
  pass "PreCompact routes conversation-only durable judgment before compact recovery"
}

test_judgment_failure_degrades_to_loud_deterministic_anchor() {
  local rec root home transcript fake anchor out rc
  rec=$(new_primary judgment-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Remember that fixture retries require a clean cache.'
  printf '%s\n' '# deterministic-fallback' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-failure" failure)

  set +e
  out=$(printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-failure\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=failure \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "judgment worker failure should preserve deterministic compaction"
  anchor="$home/data/autocompact-resume.md"
  assert_grep 'Judgment capture: FAILED' "$anchor" "judgment failure was silent in the anchor"
  assert_grep 'captain preferences, corrections, and operational learnings may have been lost' "$anchor" "judgment failure did not name the knowledge-loss categories"
  assert_grep '# deterministic-fallback' "$anchor" "judgment failure lost the deterministic anchor"
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT JUDGMENT FAILED' "judgment failure emitted no hook diagnostic"
  pass "judgment failure degrades loudly without regressing deterministic capture"
}

test_judgment_timeout_is_bounded_inside_hook_budget() {
  local rec root home transcript fake anchor started elapsed
  rec=$(new_primary judgment-timeout)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Remember this timeout-only preference.'
  printf '%s\n' '# bounded-fallback' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-timeout" timeout)

  started=$(date +%s)
  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-timeout\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=timeout \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_AUTOCOMPACT_JUDGMENT_TIMEOUT_SECONDS=1 \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 8 ] || fail "judgment timeout exceeded its inner budget (${elapsed}s)"
  anchor="$home/data/autocompact-resume.md"
  assert_grep 'exceeded its 1s budget' "$anchor" "timeout was not stated plainly in the anchor"
  assert_grep '# bounded-fallback' "$anchor" "timeout lost the deterministic anchor"
  pass "the 1s worker deadline leaves headroom inside the tracked 180s hook budget"
}

test_concurrent_memory_change_is_never_overwritten() {
  local rec root home transcript fake anchor expected
  rec=$(new_primary judgment-concurrent)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Please remember to use UTC timestamps in completion reports.'
  printf '%s\n' '# Captain preferences' '' '- Prefer concise reports.' > "$home/data/captain.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-concurrent" concurrent)
  expected=$(printf '%s\n' '# Captain preferences' '' '- Concurrent writer owns this value.')

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-concurrent\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=concurrent \
      FM_FAKE_CAPTAIN="$home/data/captain.md" \
      FM_FAKE_DATA="$home/data" \
      FM_FAKE_DATA_WRITER="$ROOT/bin/fm-data-write.py" \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1

  [ "$(cat "$home/data/captain.md")" = "$expected" ] || fail "judgment capture overwrote a concurrent captain.md update"
  anchor="$home/data/autocompact-resume.md"
  assert_grep 'concurrent data change prevented safe publication' "$anchor" "concurrent refusal was not surfaced in the anchor"
  pass "compare-before-replace refuses to corrupt a concurrent private-memory write"
}

test_partial_publication_failure_rolls_back_every_file() {
  local rec root home transcript fake captain_before learnings_before anchor
  rec=$(new_primary judgment-rollback)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Remember my UTC preference and the writer-lock learning.'
  printf '%s\n' '# Captain preferences' > "$home/data/captain.md"
  printf '%s\n' '# Fleet learnings' > "$home/data/learnings.md"
  printf '%s\n' '# Backlog' '## In flight' '## Queued' '## Done' > "$home/data/backlog.md"
  captain_before=$(cat "$home/data/captain.md")
  learnings_before=$(cat "$home/data/learnings.md")
  fake=$(fake_judgment_claude "$home/fake-rollback" multi)

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-rollback\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=multi \
      FM_AUTOCOMPACT_TEST_FAIL_PUBLISH_AFTER=1 \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1

  [ "$(cat "$home/data/captain.md")" = "$captain_before" ] || fail "partial failure did not roll captain.md back"
  [ "$(cat "$home/data/learnings.md")" = "$learnings_before" ] || fail "partial failure changed learnings.md"
  anchor="$home/data/autocompact-resume.md"
  assert_grep 'Judgment capture: FAILED - PARTIAL' "$anchor" "partial publication failure was not labeled partial"
  assert_not_contains "$(cat "$anchor")" 'Judgment capture: COMPLETE' "partial publication failure was mislabeled complete"
  pass "a partial multi-file publication failure rolls every destination back"
}

test_killed_publication_is_recovered_before_hook_return() {
  local rec root home transcript fake ready capture_pid worker_pid captain_before learnings_before anchor
  rec=$(new_primary judgment-killed-publication)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  ready="$home/publish-ready"
  write_transcript "$transcript" 'Remember my UTC preference and the writer-lock learning.'
  printf '%s\n' '# Captain preferences' > "$home/data/captain.md"
  printf '%s\n' '# Fleet learnings' > "$home/data/learnings.md"
  printf '%s\n' '# Backlog' '## In flight' '## Queued' '## Done' > "$home/data/backlog.md"
  captain_before=$(cat "$home/data/captain.md")
  learnings_before=$(cat "$home/data/learnings.md")
  fake=$(fake_judgment_claude "$home/fake-killed-publication" multi)

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-killed\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=multi \
      FM_AUTOCOMPACT_TEST_PAUSE_PUBLISH_AFTER=1 \
      FM_AUTOCOMPACT_TEST_PUBLISH_READY="$ready" \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1 &
  capture_pid=$!
  fm_test_wait_for_file "$ready" "$capture_pid" || fail "publication did not reach the kill point"
  worker_pid=$(cat "$ready")
  kill -9 "$worker_pid"
  wait "$capture_pid"

  [ "$(cat "$home/data/captain.md")" = "$captain_before" ] || fail "hook return left captain.md partially published"
  [ "$(cat "$home/data/learnings.md")" = "$learnings_before" ] || fail "hook return changed learnings.md"
  assert_absent "$home/data/.firstmate-data-transaction.json" "hook return left a transaction journal pending"
  anchor="$home/data/autocompact-resume.md"
  assert_grep 'Judgment capture: FAILED - PARTIAL' "$anchor" "killed publication was not labeled partial"
  assert_not_contains "$(cat "$anchor")" 'Judgment capture: COMPLETE' "killed publication was presented as complete"
  pass "a killed multi-file publication is recovered before hook return"
}

test_recovery_failure_surfaces_top_partial_alarm() {
  local rec root home transcript fake ready capture_pid worker_pid anchor first_line rc
  rec=$(new_primary judgment-recovery-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  ready="$home/publish-ready"
  write_transcript "$transcript" 'Remember my preference correction and the operational learning.'
  printf '%s\n' '# Captain preferences' > "$home/data/captain.md"
  printf '%s\n' '# Fleet learnings' > "$home/data/learnings.md"
  printf '%s\n' '# Backlog' '## In flight' '## Queued' '## Done' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-recovery-failure" multi)

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-recovery-failure\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=multi \
      FM_AUTOCOMPACT_TEST_PAUSE_PUBLISH_AFTER=1 \
      FM_AUTOCOMPACT_TEST_PUBLISH_READY="$ready" \
      FM_AUTOCOMPACT_TEST_FAIL_RECOVERY_WITH_JOURNAL=1 \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1 &
  capture_pid=$!
  fm_test_wait_for_file "$ready" "$capture_pid" || fail "recovery-failure publication did not reach the kill point"
  worker_pid=$(cat "$ready")
  kill -9 "$worker_pid"
  wait "$capture_pid"
  rc=$?

  expect_code 0 "$rc" "judgment recovery failure must degrade without blocking compaction"
  anchor="$home/data/autocompact-resume.md"
  first_line=$(sed -n '1p' "$anchor")
  assert_contains "$first_line" 'Judgment capture: FAILED - PARTIAL' "recovery failure was not the absolute top-line partial alarm"
  assert_contains "$first_line" 'captain preferences, corrections, and operational learnings may have been lost' "recovery failure omitted durable-knowledge categories"
  assert_not_contains "$(cat "$anchor")" 'Judgment capture: COMPLETE' "partial recovery failure was mislabeled complete"
  assert_grep '# Backlog' "$anchor" "partial alarm replaced the deterministic anchor content"
  assert_present "$home/data/.firstmate-data-transaction.json" "failed recovery hid its pending transaction"
  pass "recovery failure returns zero with a top partial alarm"
}

test_startup_recovery_failure_preserves_deterministic_capture() {
  local rec root home transcript anchor first_line rc
  rec=$(new_primary startup-recovery-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Remember this startup recovery fixture.'
  printf '%s\n' '# startup-recovery-backlog' > "$home/data/backlog.md"
  seed_pending_memory_transaction "$home"

  set +e
  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-startup-recovery\",\"transcript_path\":\"$transcript\"}" \
    | FM_AUTOCOMPACT_TEST_FAIL_RECOVERY_WITH_JOURNAL=1 \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "startup judgment recovery failure must not block compaction"
  anchor="$home/data/autocompact-resume.md"
  first_line=$(sed -n '1p' "$anchor")
  assert_contains "$first_line" 'Judgment capture: FAILED - PARTIAL' "startup recovery failure lacked a top partial alarm"
  assert_grep '# startup-recovery-backlog' "$anchor" "startup recovery failure suppressed deterministic backlog capture"
  assert_present "$home/data/.firstmate-data-transaction.json" "startup recovery failure hid its pending transaction"
  pass "startup recovery failure preserves a zero-exit deterministic anchor"
}

test_sessionstart_recovery_failure_keeps_deterministic_reconciliation() {
  local rec root home out anchor first_line rc
  rec=$(new_primary sessionstart-recovery-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# sessionstart-recovery-backlog' > "$home/data/backlog.md"
  capture "$root" "$home" auto >/dev/null
  seed_pending_memory_transaction "$home"

  set +e
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-recovery-failure"}' \
    | FM_AUTOCOMPACT_TEST_FAIL_RECOVERY_WITH_JOURNAL=1 \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" recover 2>/dev/null)
  rc=$?
  set -e

  expect_code 0 "$rc" "SessionStart judgment recovery failure must return zero"
  anchor="$home/data/autocompact-resume.md"
  first_line=$(sed -n '1p' "$anchor")
  assert_contains "$first_line" 'Judgment capture: FAILED - PARTIAL' "SessionStart recovery failure did not update the anchor alarm"
  assert_contains "$out" 'Judgment capture: FAILED - PARTIAL' "SessionStart recovery output omitted the partial alarm"
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "SessionStart recovery failure suppressed the anchor surface"
  assert_contains "$out" 'NORMAL SESSION-START RECONCILIATION' "SessionStart recovery failure suppressed normal reconciliation"
  assert_contains "$out" '# sessionstart-recovery-backlog' "SessionStart recovery failure suppressed durable backlog context"
  pass "SessionStart recovery failure preserves deterministic reconciliation"
}

test_older_worker_cannot_complete_newer_failed_anchor() {
  local rec root home transcript fake anchor ready release older_pid attempts=0
  rec=$(new_primary anchor-status-race)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 'Remember this overlapping capture fact.'
  printf '%s\n' '# overlap-fallback' > "$home/data/backlog.md"
  fake=$(fake_judgment_claude "$home/fake-overlap" delayed-success)
  ready="$home/older-ready"
  release="$home/release-older"

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"session-older\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=delayed-success \
      FM_FAKE_JUDGMENT_READY="$ready" \
      FM_FAKE_JUDGMENT_RELEASE="$release" \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1 &
  older_pid=$!
  while [ ! -f "$ready" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 500 ] || fail "older judgment worker did not reach the synchronization point"
    sleep 0.01
  done

  printf '%s\n' "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"session_id\":\"session-newer\",\"transcript_path\":\"$transcript\"}" \
    | FM_FAKE_JUDGMENT_MODE=failure \
      FM_AUTOCOMPACT_JUDGMENT_CLAUDE="$fake" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture >/dev/null 2>&1
  : > "$release"
  wait "$older_pid"

  anchor="$home/data/autocompact-resume.md"
  assert_grep "Session: \`session-newer\`" "$anchor" "older worker replaced the newer deterministic anchor"
  assert_grep 'Judgment capture: FAILED' "$anchor" "older worker marked the newer failed anchor complete"
  assert_not_contains "$(cat "$anchor")" 'Judgment capture: COMPLETE' "older worker upgraded a newer failed anchor"
  pass "an older worker cannot mark a newer failed anchor complete"
}

test_killed_lock_holder_cannot_block_future_anchor() {
  local rec root home anchor ready holder_pid attempts=0
  rec=$(new_primary killed-anchor-lock)
  IFS='|' read -r root home <<EOF
$rec
EOF
  ready="$home/lock-ready"
  python3 -c '
import fcntl
import os
import sys
import time
descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(descriptor, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
' "$home/data/.autocompact-anchor.lock" "$ready" &
  holder_pid=$!
  while [ ! -f "$ready" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 500 ] || fail "anchor lock holder did not reach the synchronization point"
    sleep 0.01
  done
  kill -9 "$holder_pid"
  wait "$holder_pid" 2>/dev/null || true

  printf '%s\n' '# after-killed-lock' > "$home/data/backlog.md"
  capture "$root" "$home" manual

  anchor="$home/data/autocompact-resume.md"
  assert_grep "Session: \`session-manual\`" "$anchor" "capture after a killed lock holder did not publish a fresh anchor"
  assert_grep '# after-killed-lock' "$anchor" "capture after a killed lock holder retained stale deterministic state"
  assert_grep 'Judgment capture: FAILED - judgment capture was disabled' "$anchor" "capture after a killed lock holder claimed dishonest judgment status"
  pass "a killed coordination holder cannot block the next deterministic anchor"
}

test_compact_sessionstart_injects_anchor_and_reconciles() {
  local rec root home out
  rec=$(new_primary recover)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# recovery-backlog' > "$home/data/backlog.md"
  fm_write_meta "$home/state/active-1.meta" 'window=firstmate:fm-active-1' 'kind=ship'
  capture "$root" "$home" auto

  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-auto"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "recovery context marker is missing"
  assert_contains "$out" '# Autocompact resume anchor' "fresh anchor was not re-read"
  assert_contains "$out" 'SESSION START -' "normal session-start reconciliation did not run"
  assert_contains "$out" '# recovery-backlog' "session-start did not read the current backlog"
  assert_contains "$out" 'window=firstmate:fm-active-1' "session-start did not read in-flight metadata"
  pass "compact SessionStart re-reads the anchor and runs normal durable-state reconciliation"
}

test_recovery_payload_failures_still_emit_durable_context() {
  local rec root home out payload fakebin real_cat
  rec=$(new_primary recover-payload-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# recovery-payload-fallback' > "$home/data/backlog.md"
  capture "$root" "$home" auto

  for payload in '' '{not-json' '{"hook_event_name":"SessionStart"}'; do
    out=$(printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
    assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY WARNING' "invalid recovery payload was not surfaced"
    assert_contains "$out" '# recovery-payload-fallback' "invalid recovery payload suppressed the durable anchor"
    assert_contains "$out" 'NORMAL SESSION-START RECONCILIATION' "invalid recovery payload suppressed reconciliation"
  done

  fakebin=$(fm_fakebin "$TMP_ROOT/recover-payload-failure")
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  exit 72
fi
exec "$FM_AUTOCOMPACT_REAL_CAT" "$@"
EOF
  chmod +x "$fakebin/cat"
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact"}' \
    | PATH="$fakebin:$PATH" \
      FM_AUTOCOMPACT_REAL_CAT="$real_cat" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" recover)
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY WARNING' "unreadable recovery payload was not surfaced"
  assert_contains "$out" '# recovery-payload-fallback' "unreadable recovery payload suppressed the durable anchor"
  assert_contains "$out" 'NORMAL SESSION-START RECONCILIATION' "unreadable recovery payload suppressed reconciliation"
  pass "recovery payload failures still emit all durable context"
}

test_noncompact_sessionstart_is_inert() {
  local rec root home out
  rec=$(new_primary noncompact)
  IFS='|' read -r root home <<EOF
$rec
EOF
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"resume"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  [ -z "$out" ] || fail "ordinary resume unexpectedly ran compact recovery: $out"
  pass "ordinary startup and resume events do not run compact recovery"
}

test_tracked_hook_registration_preserves_existing_hooks
test_capture_writes_fresh_durable_anchor
test_capture_is_inert_in_child_worktree
test_capture_failure_blocks_compaction
test_capture_and_recovery_do_not_require_jq
test_intermediate_render_failure_preserves_prior_anchor
test_judgment_capture_routes_conversation_only_preference
test_judgment_failure_degrades_to_loud_deterministic_anchor
test_judgment_timeout_is_bounded_inside_hook_budget
test_concurrent_memory_change_is_never_overwritten
test_partial_publication_failure_rolls_back_every_file
test_killed_publication_is_recovered_before_hook_return
test_recovery_failure_surfaces_top_partial_alarm
test_startup_recovery_failure_preserves_deterministic_capture
test_sessionstart_recovery_failure_keeps_deterministic_reconciliation
test_older_worker_cannot_complete_newer_failed_anchor
test_killed_lock_holder_cannot_block_future_anchor
test_compact_sessionstart_injects_anchor_and_reconciles
test_recovery_payload_failures_still_emit_durable_context
test_noncompact_sessionstart_is_inert
