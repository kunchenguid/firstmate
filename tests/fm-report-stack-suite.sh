#!/usr/bin/env bash
# Behavior tests for the machine-global Firstmate completion report stack.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-report-stack)
HOME_DIR="$TMP_ROOT/home"
STACK="$TMP_ROOT/stack"
SCRIPT="$ROOT/bin/fm-report-stack.mjs"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
export FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1
export FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=250

write_task() {
  local id=$1 kind=${2:-ship} task_dir="$HOME_DIR/data/$1"
  mkdir -p "$task_dir"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$TMP_ROOT/no-longer-present" \
    "project=$TMP_ROOT/projects/example" \
    "harness=codex" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "report_required=1" \
    "generation_id=generation-$id" \
    "account_profile=codex-2" \
    "provider_session_id=must-not-leak"
  printf '# Task\n\nFinish the report stack\n\n# Rules\n' > "$task_dir/brief.md"
  printf 'working: implementing\ndone: report stack ready\n' > "$HOME_DIR/state/$id.status"
}

run_stack() {
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" "$@"
}

run_stack_home() {
  local home=$1
  shift
  FM_HOME="$home" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" "$@"
}

expire_report_entry() {  # <report.html> [completed-at] -> updated report.html
  local entry=$1 completed_at=${2:-2000-01-01T00:00:00.000Z}
  local report_dir report_id cohort manifest destination
  report_dir=$(dirname "$entry")
  report_id=$(basename "$report_dir")
  # shellcheck disable=SC2016
  cohort=$(node -e '
    const timestamp = Date.parse(process.argv[1]);
    const retention = 30 * 24 * 60 * 60 * 1000;
    const width = Number(process.argv[2]);
    process.stdout.write(`cohort-${Math.ceil((timestamp + retention) / width) * width}`);
  ' "$completed_at" "${FM_REPORT_RETENTION_COHORT_MS:-300000}") || return 1
  manifest="$report_dir/manifest.json"
  node - "$manifest" "$completed_at" "$cohort" <<'NODE'
const fs = require("fs");
const [file, completedAt, retentionCohort] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.completedAt = completedAt;
value.retentionCohort = retentionCohort;
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
  destination="$STACK/entries/$cohort/$report_id"
  mkdir -p "$STACK/entries/$cohort"
  if [ "$report_dir" != "$destination" ]; then
    [ ! -e "$destination" ] || fail "expired report destination already exists: $destination"
    mv "$report_dir" "$destination"
  fi
  printf '%s/report.html\n' "$destination"
}

write_required_report() {
  local file=$1 summary=$2
  printf '# Completion\n\n## Summary\n\n%s\n\n## What changed\n\nRecorded work.\n\n## Verification\n\nEvidence checked.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' "$summary" > "$file"
}

test_publish_ship_with_visual() {
  local id=report-ship-a1 entry count manifest report_id completed_at
  write_task "$id" ship
  mkdir -p "$HOME_DIR/data/$id/visuals"
  printf '# Completion\n\n## Summary\n\nA searchable report stack is ready.\n\n## What changed\n\nAdded publication.\n\n## Verification\n\nTests passed.\n\npassword=must-also-not-leak\nAWS_SECRET_ACCESS_KEY=aws-secret-value\nDB_PASSWORD=db-secret-value\nSLACK_BOT_TOKEN=slack-secret-value\nhttps://user:url-secret@example.invalid/path\n{"password":"json-password-secret","access_token":"json-access-secret","safe":"visible"}\n\n## Visual evidence\n\nSee overview.\n\n## Artifacts\n\nIndex.\n\n## Follow-ups\n\nNone.\n' > "$HOME_DIR/data/$id/completion.md"
  printf 'synthetic image bytes' > "$HOME_DIR/data/$id/visuals/overview.png"

  run_stack publish "$id" >/dev/null || fail "ship report publication failed"
  entry=$(run_stack path "$id")
  assert_present "$entry" "published report HTML is missing"
  assert_present "$STACK/index.html" "report stack index is missing"
  assert_present "$(dirname "$entry")/visuals/overview.png" "visual evidence was not copied"
  assert_grep 'Finish the report stack' "$entry" "report page lost the task title"
  assert_grep 'overview.png' "$entry" "report page lost the visual gallery"
  assert_grep 'codex-2' "$(dirname "$entry")/manifest.json" "safe account routing label was not retained"
  assert_grep '"generationId": "generation-report-ship-a1"' "$(dirname "$entry")/manifest.json" "stable generation identity was not published"
  if grep -R -F 'must-not-leak' "$STACK" >/dev/null 2>&1; then
    fail "provider session id leaked into the report stack"
  fi
  cmp -s "$HOME_DIR/data/$id/completion.md" "$(dirname "$entry")/report.md" \
    || fail "published report markdown did not preserve its source bytes"
  cmp -s "$HOME_DIR/data/$id/brief.md" "$(dirname "$entry")/brief.md" \
    || fail "published task brief did not preserve its source bytes"
  cmp -s "$HOME_DIR/state/$id.status" "$(dirname "$entry")/status.log" \
    || fail "published status trail did not preserve its source bytes"

  manifest="$(dirname "$entry")/manifest.json"
  report_id=$(sed -n 's/.*"reportId": "\([^"]*\)".*/\1/p' "$manifest")
  completed_at=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  rm -f "$HOME_DIR/data/$id/visuals/overview.png"
  printf 'replacement image bytes' > "$HOME_DIR/data/$id/visuals/corrected.png"
  printf '# Completion\n\n## Summary\n\nThe corrected searchable report is ready.\n\n## What changed\n\nRebuilt publication.\n\n## Verification\n\nRetry passed.\n\n## Visual evidence\n\nSee corrected.\n\n## Artifacts\n\nIndex.\n\n## Follow-ups\n\nNone.\n' > "$HOME_DIR/data/$id/completion.md"
  printf 'working: implementing\ndone: corrected report stack ready\n' > "$HOME_DIR/state/$id.status"
  run_stack publish "$id" >/dev/null || fail "corrected report retry failed"
  assert_grep 'The corrected searchable report is ready' "$(dirname "$entry")/report.md" "report retry retained stale completion text"
  assert_grep 'corrected report stack ready' "$(dirname "$entry")/status.log" "report retry retained a stale status trail"
  assert_present "$(dirname "$entry")/visuals/corrected.png" "report retry lost corrected visual evidence"
  assert_absent "$(dirname "$entry")/visuals/overview.png" "report retry retained removed visual evidence"
  assert_grep "\"reportId\": \"$report_id\"" "$manifest" "report retry changed its stable id"
  assert_grep "\"completedAt\": \"$completed_at\"" "$manifest" "report retry changed its original completion timestamp"
  count=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "report retry created duplicate entries (count=$count)"
  pass "report stack replaces corrected ship reports without changing stable identity"
}

test_report_artifacts_remain_verbatim_across_key_shaped_content() {
  local id=report-verbatim-key-a1b source entry
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

-----BEGIN PRIVATE KEY-----
Preserve this trusted internal artifact exactly.

## What changed

Recorded work.

## Verification

Evidence checked.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
-----END PRIVATE KEY-----
EOF
  run_stack publish "$id" >/dev/null || fail "key-shaped report artifact failed publication"
  entry=$(run_stack path "$id") || fail "key-shaped report artifact path failed"
  cmp -s "$source" "$(dirname "$entry")/report.md" \
    || fail "key-shaped report artifact was inspected or transformed"
  pass "report stack preserves trusted internal artifact bytes verbatim"
}

test_report_links_reject_credentials_and_encode_visual_paths() {
  local id=report-links-a2 entry manifest visual
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Safe report links."
  printf 'pr=https://report-user:report-secret@example.invalid/pull/1\n' >> "$HOME_DIR/state/$id.meta"
  visual="$HOME_DIR/data/$id/visuals/screens/evidence #1?%.png"
  mkdir -p "$(dirname "$visual")"
  printf 'synthetic image bytes' > "$visual"

  run_stack publish "$id" >/dev/null || fail "safe-link report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"prUrl": ""' "$manifest" "credential-bearing pull request URL was retained"
  if grep -R -F 'report-secret' "$STACK" >/dev/null 2>&1; then
    fail "pull request URL credentials leaked into the report stack"
  fi
  assert_grep 'visuals/screens/evidence%20%231%3F%25.png' "$entry" "visual URL path segments were not encoded"
  assert_present "$(dirname "$entry")/visuals/screens/evidence #1?%.png" "encoded visual link lost its copied artifact"
  pass "report links reject credentials and encode visual paths"
}

test_pr_url_strips_query_and_fragment() {
  local id=report-pr-url-a2b entry manifest
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Sanitized pull request URL."
  printf 'pr=https://github.com/example/repo/pull/42?token=secret-query#private-fragment\n' \
    >> "$HOME_DIR/state/$id.meta"
  run_stack publish "$id" >/dev/null || fail "query-bearing PR URL report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"prUrl": "https://github.com/example/repo/pull/42"' "$manifest" \
    "PR URL query and fragment were not stripped"
  if grep -R -E 'secret-query|private-fragment' "$(dirname "$entry")" >/dev/null 2>&1; then
    fail "PR URL query or fragment leaked into the report entry"
  fi
  pass "report PR URLs discard query strings and fragments"
}

test_revision_fields_distinguish_pr_head_from_worktree_head() {
  local id=report-revisions-a3 repo meta meta_tmp entry manifest page head short pr_head
  repo="$TMP_ROOT/revision-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  printf 'revision fixture\n' > "$repo/fixture.txt"
  git -C "$repo" add fixture.txt
  git -C "$repo" commit -q -m fixture
  head=$(git -C "$repo" rev-parse HEAD)
  short=${head:0:12}
  pr_head=abcdef1234567890abcdef1234567890abcdef12

  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Revision identities are precise."
  meta="$HOME_DIR/state/$id.meta"
  meta_tmp="$HOME_DIR/state/.$id.meta.revisions"
  grep -v '^worktree=' "$meta" > "$meta_tmp"
  printf 'worktree=%s\npr_head=%s\n' "$repo" "$pr_head" >> "$meta_tmp"
  mv "$meta_tmp" "$meta"

  run_stack publish "$id" >/dev/null || fail "revision report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  page="$entry"
  assert_grep "\"worktreeHead\": \"$short\"" "$manifest" "manifest did not record the local worktree HEAD accurately"
  assert_grep "\"commit\": \"$short\"" "$manifest" "schema-version-1 commit compatibility alias was not retained"
  assert_grep '"prHead": "abcdef123456"' "$manifest" "manifest did not record the delivered PR head consistently"
  assert_grep '<dt>PR head</dt><dd>abcdef123456</dd>' "$page" "report page mislabeled the delivered PR revision"
  assert_grep "<dt>Worktree HEAD</dt><dd>$short</dd>" "$page" "report page mislabeled the local worktree revision"

  mkdir -p "$STACK/entries/legacy-schema-v1"
  printf '{"schemaVersion":1,"reportId":"legacy-schema-v1","taskId":"legacy-schema-v1","title":"Legacy","summary":"Legacy manifest","completedAt":"2026-07-01T00:00:00.000Z","kind":"ship","project":"example","harness":"codex","commit":"1234567890ab"}\n' \
    > "$STACK/entries/legacy-schema-v1/manifest.json"
  run_stack render >/dev/null || fail "report reader rejected a schema-version-1 manifest without new revision fields"
  pass "report manifests distinguish PR head from worktree HEAD compatibly"
}

test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths() {
  local stack="$TMP_ROOT/legacy-cutover-stack" ready="$TMP_ROOT/legacy-cutover.ready"
  local proceed="$TMP_ROOT/legacy-cutover.proceed" output="$TMP_ROOT/legacy-cutover.out" pid status fresh_path
  mkdir -p "$stack/entries/legacy-fresh" "$stack/entries/legacy-fresh-two" \
    "$stack/entries/legacy-expired" "$stack/entries/.legacy-old.expired"
  printf '{"schemaVersion":1,"reportId":"legacy-fresh","taskId":"legacy-fresh","title":"Fresh","summary":"Fresh","completedAt":"2026-07-15T00:00:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-fresh/manifest.json"
  printf 'fresh bytes\n' > "$stack/entries/legacy-fresh/report.md"
  printf '<script src="../../.retention-policy.js"></script><a href="../../index.html">stack</a>\n' \
    > "$stack/entries/legacy-fresh/report.html"
  printf '{"schemaVersion":1,"reportId":"legacy-fresh-two","taskId":"legacy-fresh-two","title":"Fresh two","summary":"Fresh two","completedAt":"2026-07-15T00:01:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-fresh-two/manifest.json"
  printf 'second fresh bytes\n' > "$stack/entries/legacy-fresh-two/report.md"
  printf '{"schemaVersion":1,"reportId":"legacy-expired","taskId":"legacy-expired","title":"Expired","summary":"Expired","completedAt":"2000-01-01T00:00:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-expired/manifest.json"
  printf 'expired bytes\n' > "$stack/entries/legacy-expired/report.md"
  printf 'old tombstone bytes\n' > "$stack/entries/.legacy-old.expired/report.md"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    FM_REPORT_LEGACY_CUTOVER_TEST_READY="$ready" FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED="$proceed" \
    "$SCRIPT" render > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "legacy cutover preparation gate did not open"; }
  assert_grep 'fresh bytes' "$stack/entries/legacy-fresh/report.md" \
    "bounded legacy migration hid an unstaged fresh report"
  assert_grep 'second fresh bytes' "$stack/entries/legacy-fresh-two/report.md" \
    "bounded legacy migration hid a pending fresh report"
  assert_absent "$stack/entries/legacy-expired" \
    "legacy cutover left expired raw bytes visible during fresh restoration"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "bounded legacy report migration did not surface its pending state"
  assert_grep 'legacy report migration is pending' "$output" \
    "bounded legacy report migration failed without an explicit pending state"
  assert_present "$stack/.legacy-cutover.json" "bounded legacy migration lost its pending marker"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    "$SCRIPT" render >/dev/null || fail "legacy report cutover did not finish its pending migration"
  assert_absent "$stack/entries/legacy-fresh" "legacy flat fresh path survived cohort cutover"
  assert_absent "$stack/entries/legacy-expired" "expired legacy raw path survived cohort cutover"
  assert_absent "$stack/entries/legacy-fresh-two" "second legacy flat fresh path survived cohort cutover"
  fresh_path=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path legacy-fresh) \
    || fail "fresh legacy report was unavailable after atomic cutover"
  assert_grep 'fresh bytes' "$(dirname "$fresh_path")/report.md" \
    "cohort cutover changed fresh legacy artifact bytes"
  assert_grep 'src="../../../.retention-policy.js"' "$fresh_path" \
    "cohort cutover did not rebase the migrated retention-policy link"
  assert_grep 'href="../../../index.html"' "$fresh_path" \
    "cohort cutover did not rebase the migrated stack-navigation link"
  assert_no_grep 'src="../../.retention-policy.js"' "$fresh_path" \
    "cohort cutover retained the flat-entry retention-policy link"
  fresh_path=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path legacy-fresh-two) \
    || fail "second fresh legacy report was unavailable after atomic cutover"
  assert_grep 'second fresh bytes' "$(dirname "$fresh_path")/report.md" \
    "cohort cutover changed second fresh legacy artifact bytes"
  assert_absent "$stack/entries/.legacy-old.expired" \
    "legacy expired tombstone remained in the public report namespace"
  assert_absent "$stack/.legacy-cutover.json" "completed legacy cutover retained its transaction marker"
  pass "legacy cutover keeps pending fresh reports visible and retires expired raw paths"
}

test_retention_owner_advances_pending_legacy_migration() {
  local stack="$TMP_ROOT/legacy-owner-stack" id completed
  mkdir -p "$stack/entries"
  completed=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  for id in legacy-owner-one legacy-owner-two legacy-owner-three; do
    mkdir "$stack/entries/$id"
    printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Fresh","summary":"Fresh","completedAt":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
      "$id" "$id" "$completed" > "$stack/entries/$id/manifest.json"
    printf '%s bytes\n' "$id" > "$stack/entries/$id/report.md"
  done
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_NODE="$(command -v node)" \
    "$ROOT/bin/fm-report-retention.sh" run-once >/dev/null \
    || fail "retention owner did not continue bounded legacy migration"
  assert_absent "$stack/.legacy-cutover.json" "retention owner left bounded legacy migration pending"
  for id in legacy-owner-one legacy-owner-two legacy-owner-three; do
    FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id" >/dev/null \
      || fail "retention owner lost $id while advancing legacy migration"
  done
  pass "retention owner automatically advances bounded legacy migration"
}

test_manifest_cohort_must_match_completion_time() {
  local stack="$TMP_ROOT/manifest-cohort-stack" cohort=cohort-4102444800000 out status
  mkdir -p "$stack/entries/$cohort/cohort-mismatch"
  printf '{"schemaVersion":1,"reportId":"cohort-mismatch","taskId":"cohort-mismatch","title":"Mismatch","summary":"Mismatch","completedAt":"2000-01-01T00:00:00.000Z","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' "$cohort" \
    > "$stack/entries/$cohort/cohort-mismatch/manifest.json"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "manifest cohort metadata was accepted despite a mismatched completion time"
  assert_contains "$out" "manifest identity mismatch" "manifest cohort-time mismatch failed unclearly"
  pass "report manifests bind cohort metadata to completion time"
}

test_manifest_cohort_deadline_cannot_precede_expiry() {
  local stack="$TMP_ROOT/manifest-early-cohort-stack" completed cohort out status
  completed=$(node -e 'process.stdout.write(new Date().toISOString())')
  cohort=$(node -e '
    const deadline = Math.ceil((Date.parse(process.argv[1]) + 15 * 24 * 60 * 60 * 1000) / 300000) * 300000;
    process.stdout.write("cohort-" + deadline);
  ' "$completed") || fail "early cohort-deadline fixture could not be computed"
  mkdir -p "$stack/entries/$cohort/early-cohort"
  printf '{"schemaVersion":1,"reportId":"early-cohort","taskId":"early-cohort","title":"Early","summary":"Early","completedAt":"%s","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$completed" "$cohort" > "$stack/entries/$cohort/early-cohort/manifest.json"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "manifest cohort deadline preceding the 30-day expiry was accepted"
  assert_contains "$out" "manifest identity mismatch" "early cohort-deadline refusal was unclear"
  pass "report manifests reject cohort deadlines that precede the 30-day expiry"
}

test_manifest_validation_is_cohort_width_independent() {
  local id=report-cohort-width-shift-z37a entry json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Width-shift stable report."
  run_stack publish "$id" >/dev/null || fail "cohort width-shift publication failed"
  entry=$(run_stack path "$id") || fail "cohort width-shift path failed"
  json=$(FM_REPORT_RETENTION_COHORT_MS=3600000 run_stack list --json) \
    || fail "report list rejected existing entries after a cohort width change"
  printf '%s\n' "$json" | grep -F "\"taskId\": \"$id\"" >/dev/null \
    || fail "cohort width change hid an existing report entry"
  FM_REPORT_RETENTION_COHORT_MS=1295000000 run_stack render >/dev/null \
    || fail "report render rejected existing entries after a cohort width change"
  assert_present "$entry" "cohort width change displaced an existing report entry"
  pass "report manifest validation is independent of the retention cohort width"
}

test_retention_cohort_never_precedes_exact_expiry() {
  local id=report-cohort-ceiling-z36a entry manifest completed cohort deadline expiry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cohort deadline alignment."
  run_stack publish "$id" >/dev/null || fail "cohort ceiling publication failed"
  entry=$(run_stack path "$id") || fail "cohort ceiling path failed"
  manifest="$(dirname "$entry")/manifest.json"
  completed=$(jq -r '.completedAt' "$manifest")
  cohort=$(jq -r '.retentionCohort' "$manifest")
  deadline=${cohort#cohort-}
  expiry=$(node -e 'process.stdout.write(String(Date.parse(process.argv[1]) + 30 * 24 * 60 * 60 * 1000))' "$completed")
  [ "$deadline" -ge "$expiry" ] || fail "retention cohort deadline preceded the exact 30-day expiry"
  [ "$deadline" -lt $((expiry + 300000)) ] || fail "retention cohort ceiling exceeded one cohort"
  pass "report retention cohorts never expire reports before the published cutoff"
}

test_retention_cohort_and_sweep_share_drift_budget() {
  local stack="$TMP_ROOT/retention-drift-budget-stack" out status
  mkdir -p "$stack/entries"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=691200000 FM_REPORT_RETENTION_INTERVAL=691200 \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention accepted cohort and sweep drift beyond 15 days"
  assert_contains "$out" "must not exceed 15 days" \
    "retention joint drift rejection was not actionable"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=604800000 FM_REPORT_RETENTION_INTERVAL=691200 \
    "$SCRIPT" prune --status >/dev/null \
    || fail "retention rejected cohort and sweep drift at the 15-day boundary"
  pass "retention jointly bounds cohort and sweep drift to 15 days"
}

test_retention_guard_cannot_advance_minimum_age() {
  local stack="$TMP_ROOT/retention-minimum-age-stack" before after completed deadline cohort cutoff
  local retention_ms=2592000000 id legacy_id
  id='minimum-age-cohort'
  legacy_id='minimum-age-legacy'
  mkdir -p "$stack/entries"
  before=$(node -e 'process.stdout.write(String(Date.now()))')
  completed=$(node -e 'process.stdout.write(new Date(Number(process.argv[1]) - 30 * 24 * 60 * 60 * 1000 + 60000).toISOString())' "$before")
  deadline=$(node -e 'process.stdout.write(String(Math.ceil((Date.parse(process.argv[1]) + 30 * 24 * 60 * 60 * 1000) / 300000) * 300000))' "$completed")
  cohort="cohort-$deadline"
  mkdir -p "$stack/entries/$cohort/$id" "$stack/entries/$legacy_id"
  printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Minimum age","summary":"Minimum age","completedAt":"%s","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$id" "$id" "$completed" "$cohort" > "$stack/entries/$cohort/$id/manifest.json"
  printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Legacy minimum age","summary":"Legacy minimum age","completedAt":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$legacy_id" "$legacy_id" "$completed" > "$stack/entries/$legacy_id/manifest.json"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_GUARD_MS=600000 \
    FM_REPORT_RETENTION_INTERVAL=300 FM_REPORT_RETENTION_NODE="$(command -v node)" \
    "$ROOT/bin/fm-report-retention.sh" run-once >/dev/null \
    || fail "retention owner rejected reports inside the minimum age"
  after=$(node -e 'process.stdout.write(String(Date.now()))')
  cutoff=$(node -e '
const source = require("fs").readFileSync(process.argv[1], "utf8");
process.stdout.write(String(JSON.parse(source.match(/=(\{.*\});/)[1]).cutoffMs));
' "$stack/.retention-policy.js")

  [ "$cutoff" -ge $((before - retention_ms)) ] \
    || fail "retention visibility cutoff preceded the exact 30-day boundary"
  [ "$cutoff" -le $((after - retention_ms)) ] \
    || fail "retention visibility cutoff advanced past the exact 30-day boundary"
  assert_present "$stack/entries/$cohort/$id/manifest.json" \
    "cohort cleanup retired a report before its 30-day minimum age"
  assert_present "$stack/entries/$cohort/$legacy_id/manifest.json" \
    "legacy migration retired a report before its 30-day minimum age"
  pass "retention guard cannot advance visibility or cleanup before 30 days"
}

test_retention_cutoff_never_regresses_with_wall_time() {
  local stack="$TMP_ROOT/retention-monotonic-stack" prior actual now retention_ms=2592000000
  mkdir -p "$stack/entries"
  now=$(node -e 'process.stdout.write(String(Date.now()))')
  prior=$((now - retention_ms + 600000))
  printf 'window.firstmateRetentionPolicy={"schemaVersion":1,"generation":"prior-clock","cutoffMs":%s};\n' \
    "$prior" > "$stack/.retention-policy.js"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" prune >/dev/null \
    || fail "retention rejected an existing cutoff from a later wall-clock reading"
  actual=$(node -e '
const source = require("fs").readFileSync(process.argv[1], "utf8");
process.stdout.write(String(JSON.parse(source.match(/=(\{.*\});/)[1]).cutoffMs));
' "$stack/.retention-policy.js")
  [ "$actual" -ge "$prior" ] || fail "retention visibility cutoff moved backward with wall time"
  pass "report retention cutoff remains monotonic across wall-clock regressions"
}

test_republish_new_generation_refreshes_completion_time() {
  local id=report-generation-a4 repo meta entry manifest staged previous_completed completed
  repo="$TMP_ROOT/generation-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  git -C "$repo" commit -q --allow-empty -m first
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "First generation."
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.generation"
  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$repo" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "first generation report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  previous_completed=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02

  git -C "$repo" commit -q --allow-empty -m second
  sed 's/^harness=.*/harness=claude/; s/^account_profile=.*/account_profile=claude-3/; s/^generation_id=.*/generation_id=generation-restored/' "$meta" > "$staged"
  mv "$staged" "$meta"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Restored generation."
  run_stack publish "$id" >/dev/null || fail "restored generation report publication failed"
  entry=$(run_stack path "$id") || fail "restored generation report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  completed=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$completed" ] && [ "$completed" != "$previous_completed" ] \
    || fail "new generation retained the superseded completion timestamp"
  assert_grep '"harness": "claude"' "$manifest" "new generation report retained the superseded harness"
  assert_grep '"accountProfile": "claude-3"' "$manifest" "new generation report retained the superseded profile"
  pass "report republish refreshes completion time for a new task generation"
}

test_same_generation_republish_preserves_revision_without_worktree() {
  local id=report-revision-retry-a4b repo meta staged entry manifest head short branch
  repo="$TMP_ROOT/revision-retry-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  git -C "$repo" commit -q --allow-empty -m first
  head=$(git -C "$repo" rev-parse HEAD)
  short=${head:0:12}
  branch=$(git -C "$repo" branch --show-current)
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Revision survives retry."
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.revision-retry"
  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$repo" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "revision retry precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"

  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$TMP_ROOT/removed-revision-worktree" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "same-generation retry without a worktree failed"
  assert_grep "\"commit\": \"$short\"" "$manifest" \
    "same-generation retry erased the compatibility commit"
  assert_grep "\"worktreeHead\": \"$short\"" "$manifest" \
    "same-generation retry erased the worktree HEAD"
  assert_grep "\"branch\": \"$branch\"" "$manifest" \
    "same-generation retry erased the branch"
  pass "same-generation report retries preserve unavailable revision provenance"
}

test_generation_identity_falls_back_only_when_both_sides_are_legacy() {
  local id meta staged entry manifest first second

  id=report-new-id-over-legacy-a4c
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "New identity over legacy manifest."
  run_stack publish "$id" >/dev/null || fail "new-id-over-legacy precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  staged="$manifest.staged"
  grep -v '"generationId":' "$manifest" > "$staged"
  mv "$staged" "$manifest"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "new-id-over-legacy publication failed"
  entry=$(run_stack path "$id") || fail "new-id-over-legacy path lookup failed"
  manifest="$(dirname "$entry")/manifest.json"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "a new generation id reused a legacy manifest completion time"

  id=report-legacy-over-new-id-a4d
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Legacy metadata over new identity."
  run_stack publish "$id" >/dev/null || fail "legacy-over-new-id precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.legacy"
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "legacy-over-new-id publication failed"
  entry=$(run_stack path "$id") || fail "legacy-over-new-id path lookup failed"
  manifest="$(dirname "$entry")/manifest.json"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "legacy metadata reused a generation-bound manifest completion time"

  id=report-both-legacy-a4e
  write_task "$id" ship
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.legacy"
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Both sides legacy."
  run_stack publish "$id" >/dev/null || fail "both-legacy precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "both-legacy compatibility publication failed"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ "$second" = "$first" ] || fail "both-legacy retry lost compatibility generation matching"
  pass "generation matching uses legacy heuristics only for two legacy identities"
}

test_text_sources_are_stored_verbatim_and_completion_is_bounded() {
  local id entry stored_brief stored_status oversized out status
  id=report-bounded-trails-a5
  write_task "$id" ship
  {
    printf '# Task\n\nBounded trail title\n\n'
    dd if=/dev/zero bs=1048576 count=5 2>/dev/null | tr '\000' 'b'
  } > "$HOME_DIR/data/$id/brief.md"
  {
    dd if=/dev/zero bs=1048576 count=5 2>/dev/null | tr '\000' 's'
    printf '\ndone: bounded status tail survives\n'
  } > "$HOME_DIR/state/$id.status"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bounded informational trails."

  run_stack publish "$id" >/dev/null || fail "bounded informational trails did not publish"
  entry=$(run_stack path "$id")
  stored_brief="$(dirname "$entry")/brief.md"
  stored_status="$(dirname "$entry")/status.log"
  cmp -s "$HOME_DIR/data/$id/brief.md" "$stored_brief" || fail "oversized brief was truncated or re-encoded"
  cmp -s "$HOME_DIR/state/$id.status" "$stored_status" || fail "oversized status trail was truncated or re-encoded"

  oversized=report-oversized-completion-a6
  write_task "$oversized" ship
  dd if=/dev/zero bs=1048576 count=17 2>/dev/null | tr '\000' 'r' > "$HOME_DIR/data/$oversized/completion.md"
  out=$(run_stack publish "$oversized" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized load-bearing completion report was silently published"
  assert_contains "$out" "exceeds the 16777216-byte publication limit" "oversized report refusal omitted its byte limit"
  assert_contains "$out" "This attempt did not replace the durable report" "oversized report refusal omitted retry safety"
  if find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d -name "$oversized-*" -print -quit | grep -q .; then
    fail "oversized load-bearing completion report created a durable entry"
  fi
  assert_grep 'Buffer.alloc(maxBytes + 1)' "$SCRIPT" \
    "bounded report readers do not reserve an overflow sentinel byte"
  assert_grep 'readDescriptorAtMost(descriptor, maxBytes' "$SCRIPT" \
    "bounded report control readers do not read through the capped descriptor helper"
  pass "report stack preserves informational trails and rejects oversized completion reports"
}

test_metadata_is_bounded_before_reading() {
  local id=report-oversized-meta-a7 out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Metadata bounds."
  dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\000' 'm' >> "$HOME_DIR/state/$id.meta"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized task metadata was read and published"
  assert_contains "$out" "task metadata exceeds its 1048576-byte limit" \
    "oversized metadata refusal omitted its pre-read limit"
  pass "report stack rejects oversized metadata before reading it"
}

test_report_temps_are_exclusive_and_randomized() {
  local id=report-temp-safety-a8 outside entry report_id index_plant transaction_plant
  id=report-temp-safety-a8
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Exclusive report staging."
  outside="$TMP_ROOT/report-temp-sentinel"
  printf 'sentinel\n' > "$outside"
  mkdir -p "$STACK"
  index_plant="$STACK/.index.html.${BASHPID:-$$}.tmp"
  (
    ln -s "$outside" "$index_plant"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable index temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report index staging followed a planted temp symlink"
  rm -f "$index_plant"
  entry=$(run_stack path "$id")
  report_id=$(basename "$(dirname "$entry")")
  transaction_plant="$STACK/entries/.$report_id.transaction.${BASHPID:-$$}.tmp"
  (
    ln -s "$outside" "$transaction_plant"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable transaction temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report transaction staging followed a planted temp symlink"
  rm -f "$transaction_plant"
  pass "report transactions and indexes use exclusive randomized staging"
}

test_visual_inventory_is_count_and_depth_bounded() {
  local id out status current i
  id=report-visual-count-a9
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual count."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  i=1
  while [ "$i" -le 512 ]; do
    : > "$HOME_DIR/data/$id/visuals/file-$i.png"
    i=$((i + 1))
  done
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "oversized visual entry inventory was published"
  assert_contains "$out" "visual evidence exceeds the 512-entry limit" \
    "visual entry refusal omitted its count limit"

  id=report-visual-depth-b1
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual depth."
  current="$HOME_DIR/data/$id/visuals"
  mkdir -p "$current"
  i=1
  while [ "$i" -le 25 ]; do
    current="$current/level-$i"
    mkdir "$current"
    i=$((i + 1))
  done
  : > "$current/evidence.png"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "overdeep visual inventory was published"
  assert_contains "$out" "visual evidence exceeds the 24-level depth limit" \
    "visual depth refusal omitted its depth limit"
  pass "report visual traversal rejects excessive count and depth"
}

test_required_source_fails_closed() {
  local id=report-missing-b2 out status
  write_task "$id" ship
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing required completion report unexpectedly published"
  assert_contains "$out" "required completion report is missing" "missing report failure was not actionable"
  pass "report stack refuses a required ship report with no completion source"
}

test_required_sections_fail_actionably() {
  local id=report-headings-b3 out status before after source heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary\n\nIncomplete.\n\n## Artifacts\n\nNone.\n' > "$source"
  while [[ "$source" == *//* ]]; do source=${source//\/\//\/}; done
  before=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report with missing required sections unexpectedly published"
  assert_contains "$out" "$source" "section failure omitted the exact report source"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "section failure omitted missing heading $heading"
  done
  assert_contains "$out" "fm-report-stack.mjs publish $id" "section failure omitted the direct publication retry"
  assert_contains "$out" "fm-teardown.sh $id" "section failure omitted the teardown retry"
  assert_contains "$out" "teardown remains stopped before destructive cleanup" "section failure omitted teardown safety state"
  after=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "failed section validation changed the durable report stack"
  assert_present "$HOME_DIR/state/$id.meta" "failed section validation removed task state"
  pass "report stack rejects incomplete reports with a retry-safe actionable correction"
}

test_required_sections_reject_empty_bodies() {
  local id=report-empty-sections-b3a source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

## What changed

## Verification

## Visual evidence

## Artifacts

## Follow-ups
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report with empty required sections unexpectedly published"
  assert_contains "$out" "required sections have no substantive content" \
    "empty-section failure did not identify the content requirement"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "empty-section failure omitted $heading"
  done
  assert_present "$HOME_DIR/state/$id.meta" "empty-section validation removed task state"
  pass "report stack requires substantive content in every completion section"
}

test_required_sections_reject_container_only_markers() {
  local id=report-container-only-sections-b3r source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary\n\n> \n\n## What changed\n\n+ \n\n## Verification\n\n1. \n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "container-only section markers unexpectedly satisfied required sections"
  for heading in "## Summary" "## What changed" "## Verification"; do
    assert_contains "$out" "$heading" "container-only failure omitted $heading"
  done
  assert_present "$HOME_DIR/state/$id.meta" "container-only validation removed task state"
  pass "report stack rejects bare container markers as section content"
}

test_fenced_required_section_bodies_use_scoped_content() {
  local id source out status

  id=report-fenced-body-content-b3n
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

```console
$ firstmate status
crew ready
```

## What changed

Recorded work.

## Verification

```text
{}
```

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "meaningful transcript and punctuation-only fenced bodies were rejected"

  id=report-empty-fenced-body-b3o
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

```text

```

## What changed

Recorded work.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "empty fenced body unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "empty fenced-body failure omitted the blank Summary section"

  id=report-control-only-fenced-body-b3q
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  {
    cat <<'EOF'
# Completion

## Summary

```text
EOF
    printf '\342\200\213\n'
    cat <<'EOF'
```

## What changed

Recorded work.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  } > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "format-control-only fenced body unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "control-only fenced-body failure omitted the blank Summary section"

  id=report-container-whitespace-fenced-body-b3p
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Complete.

## What changed

> ```text
>
> ```

## Verification

Verified.

## Visual evidence

None.

## Artifacts

- ```text

  ```

## Follow-ups

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "container-scoped whitespace fences unexpectedly satisfied required sections"
  assert_contains "$out" "## What changed" "blank blockquote fence failure omitted What changed"
  assert_contains "$out" "## Artifacts" "blank list fence failure omitted Artifacts"
  pass "report sections accept meaningful fenced content but reject empty scoped fence bodies"
}

test_nested_short_fences_do_not_satisfy_required_sections() {
  local id source out status heading

  id=report-four-backtick-fence-b3b
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

````markdown
```
## What changed

Hidden example.

## Verification

Hidden example.

## Visual evidence

Hidden example.

## Follow-ups

Hidden example.
```
````

## Artifacts

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a four-backtick fence unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "four-backtick fence failure omitted missing heading $heading"
  done

  id=report-four-tilde-fence-b3c
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

~~~~markdown
~~~
## What changed

Hidden example.

## Verification

Hidden example.

## Visual evidence

Hidden example.

## Follow-ups

Hidden example.
~~~
~~~~

## Artifacts

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a four-tilde fence unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "four-tilde fence failure omitted missing heading $heading"
  done
  pass "report section validation respects the opening Markdown fence length"
}

test_raw_html_does_not_satisfy_required_sections() {
  local id=report-raw-html-b3k source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

<!--
## What changed
-->

<div>
## Verification

Hidden.

## Visual evidence

Hidden.

## Artifacts

Hidden.

## Follow-ups

Hidden.
</div>

EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside raw HTML unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "raw HTML failure omitted missing heading $heading"
  done
  pass "report parsing excludes CommonMark raw HTML blocks and comments"
}

test_nested_html_containers_do_not_satisfy_required_sections() {
  local id=report-nested-html-b3l source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- <!--
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
  -->
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside nested raw HTML unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "nested raw HTML failure omitted missing heading $heading"
  done
  pass "report parsing excludes raw HTML nested in Markdown containers"
}

test_container_scoped_fences_do_not_close_from_top_level() {
  local container id source out status heading
  for container in quote list; do
    id="report-container-scope-$container-b3m"
    write_task "$id" ship
    source="$HOME_DIR/data/$id/completion.md"
    if [ "$container" = quote ]; then
      cat > "$source" <<'EOF'
# Completion

> ```text
> Nested example.
```text
## Summary
## What changed
## Verification
## Visual evidence
## Artifacts
## Follow-ups
```
EOF
    else
      cat > "$source" <<'EOF'
# Completion

- ```text
  Nested example.
```text
## Summary
## What changed
## Verification
## Visual evidence
## Artifacts
## Follow-ups
```
EOF
    fi
    out=$(run_stack publish "$id" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$container-scoped fence was closed by a top-level fence"
    for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
      assert_contains "$out" "$heading" "$container fence-scope failure omitted missing heading $heading"
    done
  done
  pass "report parsing keeps fenced blocks scoped to their Markdown containers"
}

test_indented_pseudo_closers_do_not_end_fences() {
  local id source out status heading

  for marker in backtick tilde; do
    id="report-indented-$marker-fence-b3d"
    write_task "$id" ship
    source="$HOME_DIR/data/$id/completion.md"
    if [ "$marker" = backtick ]; then
      cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

```markdown
    ```
## What changed

Hidden.

## Verification

Hidden.

## Visual evidence

Hidden.

## Follow-ups

Hidden.
```

## Artifacts

None.
EOF
    else
      printf '# Completion\n\n## Summary\n\nIncomplete.\n\n~~~markdown\n    ~~~\n## What changed\n\nHidden.\n\n## Verification\n\nHidden.\n\n## Visual evidence\n\nHidden.\n\n## Follow-ups\n\nHidden.\n~~~\n\n## Artifacts\n\nNone.\n' > "$source"
    fi
    out=$(run_stack publish "$id" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "four-space $marker pseudo-closer unexpectedly ended its fence"
    for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
      assert_contains "$out" "$heading" "$marker pseudo-closer failure omitted missing heading $heading"
    done
  done
  pass "four-space pseudo-closers remain code inside Markdown fences"
}

test_required_headings_follow_commonmark_atx_rules() {
  local id source out status

  id=report-indented-headings-b3e
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n   ## Summary ###\n\nComplete.\n\n  ## What changed\n\nChanged.\n\n ## Verification ##\n\nVerified.\n\n   ## Visual evidence\t###\n\nNone.\n\n## Artifacts\n\nReport.\n\n   ## Follow-ups\n\nNone.\n' > "$source"
  run_stack publish "$id" >/dev/null || fail "valid indented ATX headings were rejected"

  id=report-unseparated-closing-hash-b3f
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary###\n\nInvalid.\n\n## What changed\n\nChanged.\n\n## Verification\n\nVerified.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unseparated closing hashes unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "invalid closing-hash failure omitted the missing Summary heading"

  id=report-four-space-heading-b3g
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n    ## Summary\n\nIndented code.\n\n## What changed\n\nChanged.\n\n## Verification\n\nVerified.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "four-space indented code unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "four-space heading failure omitted the missing Summary heading"
  pass "required headings follow CommonMark ATX indentation and closing-hash rules"
}

test_invalid_backtick_info_string_does_not_open_fence() {
  local id=report-invalid-backtick-info-b3h source
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

```language`invalid

## Summary

Complete.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "backtick-containing info string was treated as a valid fence opener"
  pass "invalid backtick fence info strings do not hide report headings"
}

test_summary_extraction_uses_validated_markdown_structure() {
  local id=report-structured-summary-b3i source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

````markdown
## Summary

Fenced fake summary.
```
````

   ## Summary ###

Validated real summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "structured-summary report failed to publish"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Validated real summary."' "$manifest" "manifest did not use the validated real Summary section"
  assert_no_grep 'Fenced fake summary' "$manifest" "manifest summary used a fenced example"
  pass "summary extraction shares fence-aware ATX parsing"
}

test_list_container_fences_hide_report_headings_and_summaries() {
  local id=report-list-fence-b3j source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- ````markdown
  ## Summary

  Fenced fake summary.

  ## What changed

  Hidden.

  ## Verification

  Hidden.

  ## Visual evidence

  Hidden.

  ## Artifacts

  Hidden.

  ## Follow-ups

  Hidden.
  ```
  ````
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a list-container fence unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list-container fence failure omitted missing heading $heading"
  done
  pass "report parsing ignores headings and summaries inside list-container fences"
}

test_list_lazy_continuations_do_not_satisfy_required_sections() {
  local id=report-list-lazy-b3k source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- list paragraph
  ## Sacrificial heading
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
EOF
  if out=$(run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "lazy list-continuation headings unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "lazy list-continuation failure omitted missing heading $heading"
  done
  pass "report parsing excludes headings in lazy list continuations"
}

test_underindented_list_headings_exit_lazy_continuation() {
  local id=report-list-underindent-b3l source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

 - list paragraph
  ## Summary

Accepted top-level summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "a heading indented less than its list item's required content indent stayed hidden"
  entry=$(run_stack path "$id") || fail "underindented-list report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Accepted top level summary."' "$manifest" \
    "underindented list heading did not become the visible Summary section"
  pass "report parsing exits lazy list continuation below the actual required content indent"
}

test_nested_list_parent_scope_hides_required_headings() {
  local id=report-list-parent-b3m source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- outer paragraph
  - inner paragraph
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
EOF
  if out=$(run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "headings inside a nested list's parent scope unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "nested parent-list failure omitted missing heading $heading"
  done
  pass "report parsing preserves parent list scope after nested lists"
}

test_blockquote_list_scope_requires_quote_markers() {
  local id=report-quote-list-exit-b3p invalid=report-list-quote-nested-b3q source entry manifest out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

> - quoted list paragraph
  ## Summary

Visible summary after the quote.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "a heading outside a blockquote list stayed attached without an explicit quote marker"
  entry=$(run_stack path "$id") || fail "blockquote-list report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Visible summary after the quote."' "$manifest" \
    "blockquote-list ancestry hid the valid heading outside the quote"

  write_task "$invalid" ship
  source="$HOME_DIR/data/$invalid/completion.md"
  cat > "$source" <<'EOF'
# Completion

- > quoted list paragraph
  > ## Summary
  > ## What changed
  > ## Verification
  > ## Visual evidence
  > ## Artifacts
  > ## Follow-ups
EOF
  if out=$(run_stack publish "$invalid" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "headings inside a list-nested blockquote unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list-nested blockquote failure omitted missing heading $heading"
  done
  pass "report parsing requires explicit blockquote markers for lazy list ancestry"
}

test_container_scopes_preserve_commonmark_blank_and_exit_rules() {
  local valid=report-container-exit-b3n invalid=report-list-blank-b3o source out status heading
  write_task "$valid" ship
  source="$HOME_DIR/data/$valid/completion.md"
  cat > "$source" <<'EOF'
# Completion

> ```text
> Quoted code.
  ## Summary

  Valid summary.

  ## What changed

  Changed.

  ## Verification

  Verified.

  ## Visual evidence

  None.

  ## Artifacts

  Report.

  ## Follow-ups

  None.
EOF
  run_stack publish "$valid" >/dev/null || fail "top-level headings after a blockquote fence stayed trapped in the old container"

  write_task "$invalid" ship
  source="$HOME_DIR/data/$invalid/completion.md"
  cat > "$source" <<'EOF'
# Completion

- ```text

  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
  ```
EOF
  if out=$(run_stack publish "$invalid" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "a blank line ended a list-scoped fence and exposed nested headings"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list blank-line scope failure omitted missing heading $heading"
  done
  pass "report parsing tracks CommonMark containers independently from indentation"
}

test_large_non_utf8_text_artifacts_are_stored_verbatim() {
  local id=report-verbatim-bytes-b3p entry source brief status
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  brief="$HOME_DIR/data/$id/brief.md"
  status="$HOME_DIR/state/$id.status"
  write_required_report "$source" "Binary-safe report."
  printf '\377\376\375' >> "$source"
  dd if=/dev/zero bs=1048576 count=4 >> "$brief" 2>/dev/null
  printf '\377brief-tail\n' >> "$brief"
  dd if=/dev/zero bs=1048576 count=4 >> "$status" 2>/dev/null
  printf '\376status-tail\n' >> "$status"

  run_stack publish "$id" >/dev/null || fail "large non-UTF-8 artifact publication failed"
  entry=$(run_stack path "$id")
  cmp -s "$source" "$(dirname "$entry")/report.md" || fail "report bytes changed during publication"
  cmp -s "$brief" "$(dirname "$entry")/brief.md" || fail "large brief bytes were truncated or re-encoded"
  cmp -s "$status" "$(dirname "$entry")/status.log" || fail "large status bytes were truncated or re-encoded"
  pass "report publication stores raw text artifact bytes independently from decoded views"
}

test_large_visual_inventory_does_not_share_text_buffer_headroom() {
  local id=report-visual-inventory-b3q entry count
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Large visual inventory."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  python3 - "$HOME_DIR/data/$id/visuals" <<'PY'
import os
import sys

root = os.fsencode(sys.argv[1])
for index in range(503):
    name = f"{index:04d}".encode() + bytes([1 + index % 31]) * 240
    descriptor = os.open(os.path.join(root, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
PY
  run_stack publish "$id" >/dev/null || fail "valid large visual inventory exhausted text helper headroom"
  entry=$(run_stack path "$id")
  count=$(find "$(dirname "$entry")/visuals" -type f -print0 | tr -cd '\000' | wc -c | tr -d ' ')
  [ "$count" = 503 ] || fail "large visual inventory lost entries (count=$count)"
  pass "visual inventory transport has independently bounded capacity"
}

test_scout_and_legacy_sources() {
  local scout=report-scout-c3 legacy=report-legacy-d4 json
  write_task "$scout" scout
  printf '# Scout report\n\n## Summary\n\nThe investigation is complete.\n\n## What changed\n\nInvestigated.\n\n## Verification\n\nEvidence checked.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nRecommendation recorded.\n' > "$HOME_DIR/data/$scout/report.md"
  run_stack publish "$scout" >/dev/null || fail "scout report publication failed"

  write_task "$legacy" ship
  grep -v '^report_required=' "$HOME_DIR/state/$legacy.meta" > "$HOME_DIR/state/$legacy.meta.precutover"
  mv "$HOME_DIR/state/$legacy.meta.precutover" "$HOME_DIR/state/$legacy.meta"
  run_stack publish "$legacy" --legacy >/dev/null || fail "legacy compatibility publication failed"
  json=$(run_stack list --json)
  printf '%s' "$json" | grep -F '"taskId": "report-scout-c3"' >/dev/null || fail "scout is absent from report inventory"
  printf '%s' "$json" | grep -F '"taskId": "report-legacy-d4"' >/dev/null || fail "legacy task is absent from report inventory"
  assert_grep 'compatibility report was synthesized' "$(dirname "$(run_stack path "$legacy")")/report.md" "legacy synthesis was not preserved"
  pass "report stack accepts scout reports and intentional legacy synthesis"
}

test_stale_lock_rejects_reused_pid() {
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  run_stack render >/dev/null || fail "stale report lock with a reused pid was not reclaimed"
  assert_absent "$STACK/.publish.lock" "report render retained a reclaimed publication lock"
  pass "report stack lock verifies process-start identity before trusting a live pid"
}

test_stale_lock_reclaim_is_serialized() {
  local pids="" pid failures=0 i
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  for i in 1 2 3 4 5 6 7 8; do
    run_stack render > "$TMP_ROOT/render-$i.out" 2>&1 &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || failures=$((failures + 1))
  done
  if [ "$failures" -ne 0 ]; then
    for i in 1 2 3 4 5 6 7 8; do
      [ ! -s "$TMP_ROOT/render-$i.out" ] || printf 'render-%s: %s\n' "$i" "$(cat "$TMP_ROOT/render-$i.out")" >&2
    done
    fail "concurrent stale-lock reclaim lost $failures publisher(s)"
  fi
  assert_absent "$STACK/.publish.lock" "concurrent render retained the publication lock"
  if find "$STACK" -maxdepth 1 -name '.publish.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "concurrent stale-lock reclaim leaked quarantine state"
  fi
  pass "report stack serializes concurrent stale-lock reclamation"
}

test_install_guard_release_failure_cleans_owned_lock() {
  local stack="$TMP_ROOT/install-guard-release-stack" out status residue
  mkdir -p "$stack"
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_INSTALL_GUARD_RELEASE_TEST_FAILURE=1 "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic install-guard release failure exited successfully"
  assert_contains "$out" "synthetic report install-guard release failure" \
    "install-guard release failure was not observable"
  assert_absent "$stack/.publish.lock" \
    "install-guard release failure retained its newly installed canonical lock"
  assert_present "$stack/.publish.lock.reclaim" \
    "install-guard release failure did not leave an owned recoverable guard"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "next publisher did not recover the failed install guard"
  assert_absent "$stack/.publish.lock" "recovery retained the canonical publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "recovery retained the install guard"
  residue=$(find "$stack" -maxdepth 1 \( \
    -name '.publish.lock.candidate.*' -o \
    -name '.publish.lock.reclaim.candidate.*' -o \
    -name '.publish.lock.reclaim.pin.*' -o \
    -name '..publish.lock.reclaim.removed.*' -o \
    -name '..publish.lock.released.*' -o \
    -name '.publish.lock.stale.*' \
    \) -print)
  [ -z "$residue" ] || fail "install-guard recovery leaked owned residue: $residue"
  pass "install-guard release failure cleans its lock and remains recoverable"
}

test_post_install_guard_owner_death_is_recovered() {
  local stack="$TMP_ROOT/post-install-owner-death-stack"
  local precheck_ready="$TMP_ROOT/post-install-precheck.ready"
  local precheck_proceed="$TMP_ROOT/post-install-precheck.proceed"
  local owner_ready="$TMP_ROOT/post-install-owner.ready"
  local owner_proceed="$TMP_ROOT/post-install-owner.proceed"
  local observed_ready="$TMP_ROOT/post-install-observed.ready"
  local observed_proceed="$TMP_ROOT/post-install-observed.proceed"
  local acquired_ready="$TMP_ROOT/post-install-acquired.ready"
  local acquired_proceed="$TMP_ROOT/post-install-acquired.proceed"
  local owner_out="$TMP_ROOT/post-install-owner.out"
  local waiter_out="$TMP_ROOT/post-install-waiter.out"
  local owner_pid waiter_pid owner_status waiter_status state started_at elapsed residue
  mkdir -p "$stack"
  mkfifo "$precheck_ready" "$precheck_proceed" "$owner_ready" "$owner_proceed" \
    "$observed_ready" "$observed_proceed" "$acquired_ready" "$acquired_proceed"
  exec 7<>"$precheck_ready"
  exec 8<>"$precheck_proceed"
  exec 9<>"$owner_ready"
  exec 10<>"$owner_proceed"
  exec 11<>"$observed_ready"
  exec 12<>"$observed_proceed"
  exec 13<>"$acquired_ready"
  exec 14<>"$acquired_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_PRECHECK_TEST_READY="$precheck_ready" \
    FM_REPORT_LOCK_PRECHECK_TEST_PROCEED="$precheck_proceed" \
    FM_REPORT_RECLAIM_WAITER_TEST_READY="$observed_ready" \
    FM_REPORT_RECLAIM_WAITER_TEST_PROCEED="$observed_proceed" \
    FM_REPORT_LOCK_ACQUIRED_TEST_READY="$acquired_ready" \
    FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED="$acquired_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter did not reach its pre-install check: $(cat "$waiter_out")"
  fi
  [ "$state" = "guard-absent" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter emitted an unexpected pre-install state: $state"
  }

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_INSTALLED_GUARD_TEST_READY="$owner_ready" \
    FM_REPORT_LOCK_INSTALLED_GUARD_TEST_PROCEED="$owner_proceed" \
    "$SCRIPT" render > "$owner_out" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 state <&9; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "report owner did not pause after installing its lock: $(cat "$owner_out")"
  fi
  [ "$state" = "lock-installed-guard-held" ] || {
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "report owner emitted an unexpected post-install state: $state"
  }
  assert_present "$stack/.publish.lock" "post-install owner did not install the canonical lock"
  assert_present "$stack/.publish.lock.reclaim" "post-install owner released its guard before the crash gate"

  printf 'continue\n' >&8
  if ! IFS= read -r -t 10 state <&11; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "already-running report waiter did not observe the installed owner's guard: $(cat "$waiter_out")"
  fi
  [ "$state" = "guard-observed" ] || {
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "already-running report waiter emitted an unexpected guard state: $state"
  }

  started_at=$(date +%s)
  kill -TERM "$owner_pid" 2>/dev/null || true
  if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
  [ "$owner_status" -ne 0 ] || fail "synthetically terminated post-install owner exited successfully"
  printf 'continue\n' >&10
  printf 'continue\n' >&12
  if ! IFS= read -r -t 10 state <&13; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter did not recover the freshly installed dead-owner lock: $(cat "$waiter_out")"
  fi
  [ "$state" = "lock-acquired" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "recovered report waiter emitted an unexpected acquisition state: $state"
  }
  assert_present "$stack/.publish.lock" "recovered report waiter did not own the canonical lock"
  assert_absent "$stack/.publish.lock.reclaim" "recovered report waiter retained the outer guard"
  printf 'continue\n' >&14
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  elapsed=$(( $(date +%s) - started_at ))
  [ "$waiter_status" -eq 0 ] || fail "fresh dead-owner recovery failed: $(cat "$waiter_out")"
  [ "$elapsed" -le 15 ] || fail "fresh dead-owner recovery took ${elapsed}s"
  assert_absent "$stack/.publish.lock" "fresh dead-owner recovery retained the canonical lock"
  assert_absent "$stack/.publish.lock.reclaim" "fresh dead-owner recovery retained the outer guard"
  residue=$(find "$stack" -maxdepth 1 \( \
    -name '.publish.lock.candidate.*' -o \
    -name '.publish.lock.reclaim.candidate.*' -o \
    -name '.publish.lock.reclaim.pin.*' -o \
    -name '..publish.lock.reclaim.removed.*' -o \
    -name '..publish.lock.released.*' -o \
    -name '.publish.lock.stale.*' \
    \) -print)
  [ -z "$residue" ] || fail "fresh dead-owner recovery leaked owned residue: $residue"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-; exec 11>&-; exec 12>&-
  exec 13>&-; exec 14>&-
  pass "already-running report waiters recover a freshly installed dead-owner lock"
}

test_reclaim_guard_fences_the_stale_generation_gap() {
  local stack="$TMP_ROOT/reclaim-fence-stack" precheck_ready precheck_proceed
  local reclaimer_ready reclaimer_proceed waiter_ready waiter_proceed acquired_ready acquired_proceed
  local released_ready released_proceed
  local reclaimer_out waiter_out reclaimer_pid waiter_pid reclaimer_status waiter_status
  local precheck_state waiter_state started_at elapsed
  mkdir -p "$stack"
  precheck_ready="$TMP_ROOT/reclaim-precheck.ready"
  precheck_proceed="$TMP_ROOT/reclaim-precheck.proceed"
  reclaimer_ready="$TMP_ROOT/reclaim-fence.ready"
  reclaimer_proceed="$TMP_ROOT/reclaim-fence.proceed"
  waiter_ready="$TMP_ROOT/reclaim-waiter.ready"
  waiter_proceed="$TMP_ROOT/reclaim-waiter.proceed"
  acquired_ready="$TMP_ROOT/reclaim-acquired.ready"
  acquired_proceed="$TMP_ROOT/reclaim-acquired.proceed"
  released_ready="$TMP_ROOT/reclaim-released.ready"
  released_proceed="$TMP_ROOT/reclaim-released.proceed"
  reclaimer_out="$TMP_ROOT/reclaim-fence.out"
  waiter_out="$TMP_ROOT/reclaim-waiter.out"
  mkfifo "$precheck_ready" "$precheck_proceed" "$reclaimer_ready" "$reclaimer_proceed" \
    "$waiter_ready" "$waiter_proceed" "$released_ready" "$released_proceed" \
    "$acquired_ready" "$acquired_proceed"
  exec 7<>"$precheck_ready"
  exec 8<>"$precheck_proceed"
  exec 9<>"$reclaimer_ready"
  exec 10<>"$reclaimer_proceed"
  exec 11<>"$waiter_ready"
  exec 12<>"$waiter_proceed"
  exec 13<>"$acquired_ready"
  exec 14<>"$acquired_proceed"
  exec 15<>"$released_ready"
  exec 16<>"$released_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_PRECHECK_TEST_READY="$precheck_ready" FM_REPORT_LOCK_PRECHECK_TEST_PROCEED="$precheck_proceed" \
    FM_REPORT_RECLAIM_WAITER_TEST_READY="$waiter_ready" FM_REPORT_RECLAIM_WAITER_TEST_PROCEED="$waiter_proceed" \
    FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_READY="$released_ready" \
    FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_PROCEED="$released_proceed" \
    FM_REPORT_LOCK_ACQUIRED_TEST_READY="$acquired_ready" FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED="$acquired_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 precheck_state <&7; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report contender did not reach its prechecked state: $(cat "$waiter_out")"
  fi
  [ "$precheck_state" = "guard-absent" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report contender observed an unexpected precheck state: $precheck_state"
  }

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_INSTALL_GUARD_TEST_READY="$reclaimer_ready" FM_REPORT_INSTALL_GUARD_TEST_PROCEED="$reclaimer_proceed" \
    "$SCRIPT" render > "$reclaimer_out" 2>&1 &
  reclaimer_pid=$!
  if ! IFS= read -r -t 10 waiter_state <&9; then
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "report publisher did not pause while holding the install guard: $(cat "$reclaimer_out")"
  fi
  [ "$waiter_state" = "install-guard-held" ] || {
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "report install-guard owner emitted an unexpected gate state: $waiter_state"
  }

  printf 'continue\n' >&8
  if ! IFS= read -r -t 10 waiter_state <&11; then
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not observe the active reclaim guard: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "guard-observed" ] || {
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected guard state: $waiter_state"
  }
  assert_absent "$stack/.publish.lock" \
    "prechecked contender installed a replacement lock while the reclaim guard was held"
  assert_present "$stack/.publish.lock.reclaim" \
    "prechecked contender did not remain behind the publisher's install guard"

  started_at=$(date +%s)
  kill -TERM "$reclaimer_pid" 2>/dev/null || true
  if wait "$reclaimer_pid"; then reclaimer_status=0; else reclaimer_status=$?; fi
  [ "$reclaimer_status" -ne 0 ] || fail "synthetically terminated install-guard owner exited successfully"
  printf 'continue\n' >&10
  printf 'continue\n' >&12
  if ! IFS= read -r -t 10 waiter_state <&15; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not release the dead reclaim guard: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "guard-released" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected guard-release state: $waiter_state"
  }
  assert_absent "$stack/.publish.lock.reclaim" "dead reclaim guard remained after its release event"
  assert_absent "$stack/.publish.lock" "report contender installed before its guard-release event completed"
  printf 'continue\n' >&16
  if ! IFS= read -r -t 10 waiter_state <&13; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not acquire after guard-owner death: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "lock-acquired" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected acquisition state: $waiter_state"
  }
  assert_present "$stack/.publish.lock" "guard-released contender did not own the canonical report lock"
  assert_absent "$stack/.publish.lock.reclaim" "guard-released contender acquired before reclaim-guard cleanup"
  printf 'continue\n' >&14
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  elapsed=$(( $(date +%s) - started_at ))
  [ "$waiter_status" -eq 0 ] || fail "fenced report waiter failed: $(cat "$waiter_out")"
  [ "$elapsed" -le 15 ] || fail "report waiter took ${elapsed}s to recover its dead reclaim-guard owner"
  assert_absent "$stack/.publish.lock" "fenced stale-lock test retained the publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "fenced stale-lock test retained the reclaim guard"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-; exec 11>&-; exec 12>&-
  exec 13>&-; exec 14>&-; exec 15>&-; exec 16>&-
  pass "report install guard fences a negative precheck and is recovered inside the wait budget"
}

test_abandoned_reclaim_guard_is_recovered() {
  local stack="$TMP_ROOT/abandoned-reclaim-guard-stack"
  mkdir -p "$stack"
  printf '{"pid":%s,"startedAt":"different-process-start","token":"abandoned-guard"}\n' "$$" \
    > "$stack/.publish.lock.reclaim"
  touch -t 200001010000 "$stack/.publish.lock.reclaim"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "abandoned report-lock reclaim guard was not recovered"
  assert_absent "$stack/.publish.lock" "abandoned reclaim-guard recovery retained the publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "abandoned reclaim-guard recovery retained the reclaim guard"
  pass "report stack recovers an abandoned outer reclaim guard"
}

test_abandoned_reclaim_marker_is_recovered() {
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  printf '{"pid":%s,"startedAt":"different-process-start","token":"abandoned"}\n' "$$" > "$STACK/.publish.lock/.reclaim"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner" "$STACK/.publish.lock/.reclaim"
  run_stack render >/dev/null || fail "abandoned report-lock reclaim marker was not recovered"
  assert_absent "$STACK/.publish.lock" "report render retained a lock with an abandoned reclaim marker"
  pass "report stack recovers abandoned reclaim ownership by process identity and age"
}

test_abandoned_reclaim_directory_is_recovered() {
  mkdir -p "$STACK/.publish.lock/.reclaim"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  printf 'residue\n' > "$STACK/.publish.lock/.reclaim/residue"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner" \
    "$STACK/.publish.lock/.reclaim"
  run_stack render >/dev/null || fail "abandoned report-lock reclaim directory was not recovered"
  assert_absent "$STACK/.publish.lock" "report render retained a lock with an abandoned reclaim directory"
  pass "report stack recursively cleans quarantined reclaim directories"
}

test_publish_lock_directory_symlink_fails_closed() {
  local outside out status
  outside="$TMP_ROOT/report-lock-outside"
  mkdir -p "$STACK" "$outside"
  printf 'sentinel\n' > "$outside/sentinel"
  ln -s "$outside" "$STACK/.publish.lock"

  out=$(run_stack list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report stack followed a symlinked publish lock directory"
  assert_contains "$out" "report lock must be a real directory" \
    "symlinked report lock refusal was not actionable"
  [ "$(cat "$outside/sentinel")" = sentinel ] || fail "report lock recovery changed outside data"
  assert_absent "$outside/.reclaim" "report lock recovery wrote through a directory symlink"
  [ -L "$STACK/.publish.lock" ] || fail "report lock recovery replaced the unsafe lock symlink"
  rm -f "$STACK/.publish.lock"
  pass "report lock recovery refuses directory symlinks before child access"
}

test_lock_control_files_are_bounded_and_nonfollowing() {
  local outside
  rm -rf "$STACK/.publish.lock"
  mkdir -p "$STACK/.publish.lock"
  outside="$TMP_ROOT/report-lock-owner-target"
  printf '{"pid":999999,"startedAt":"dead","token":"outside"}\n' > "$outside"
  ln -s "$outside" "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  touch -h -t 200001010000 "$STACK/.publish.lock/owner"
  run_stack render >/dev/null || fail "symlinked report-lock owner permanently blocked recovery"
  [ "$(cat "$outside")" = '{"pid":999999,"startedAt":"dead","token":"outside"}' ] \
    || fail "report-lock owner validation changed the symlink target"
  assert_absent "$STACK/.publish.lock" "report stack retained a lock with a symlinked owner control file"

  mkdir -p "$STACK/.publish.lock"
  dd if=/dev/zero bs=8192 count=1 2>/dev/null | tr '\0' x > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner"
  run_stack render >/dev/null || fail "oversized report-lock owner permanently blocked recovery"
  assert_absent "$STACK/.publish.lock" "report stack retained a lock with an oversized owner control file"
  pass "report lock control reads are bounded, nonfollowing, and recoverable"
}

test_namespace_cutover_waiter_pins_entries_after_lock_acquisition() {
  local id=report-cutover-waiter-k2b stack entry owner_ready owner_proceed waiter_ready waiter_proceed owner_out waiter_out
  local owner_pid waiter_pid owner_status waiter_status state
  stack="$STACK"
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Namespace cutover waiter."
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" publish "$id" >/dev/null \
    || fail "namespace-cutover waiter precondition publication failed"
  entry=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id") \
    || fail "namespace-cutover waiter precondition path failed"
  expire_report_entry "$entry" >/dev/null || fail "namespace-cutover waiter report could not be aged"
  owner_ready="$TMP_ROOT/cutover-owner.ready"
  owner_proceed="$TMP_ROOT/cutover-owner.proceed"
  waiter_ready="$TMP_ROOT/cutover-waiter.ready"
  waiter_proceed="$TMP_ROOT/cutover-waiter.proceed"
  owner_out="$TMP_ROOT/cutover-owner.out"
  waiter_out="$TMP_ROOT/cutover-waiter.out"
  mkfifo "$owner_ready" "$owner_proceed" "$waiter_ready" "$waiter_proceed"
  exec 7<>"$owner_ready"
  exec 8<>"$owner_proceed"
  exec 9<>"$waiter_ready"
  exec 10<>"$waiter_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_READY="$owner_ready" FM_REPORT_LOCK_TEST_PROCEED="$owner_proceed" \
    "$SCRIPT" prune --status > "$owner_out" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$owner_pid" 2>/dev/null || true
    fail "namespace-cutover owner did not acquire its publication lock: $(cat "$owner_out")"
  fi
  [ "$state" = "lock-acquired" ] || fail "namespace-cutover owner emitted an unexpected lock state: $state"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_WAITER_TEST_READY="$waiter_ready" FM_REPORT_LOCK_WAITER_TEST_PROCEED="$waiter_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 state <&9; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "namespace-cutover waiter did not observe the held publication lock: $(cat "$waiter_out")"
  fi
  [ "$state" = "lock-observed" ] || fail "namespace-cutover waiter emitted an unexpected lock state: $state"
  printf 'continue\n' >&10
  printf 'continue\n' >&8
  if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  [ "$owner_status" -eq 0 ] || fail "namespace-cutover owner failed: $(cat "$owner_out")"
  [ "$waiter_status" -eq 0 ] || fail "namespace-cutover waiter failed after lock acquisition: $(cat "$waiter_out")"
  assert_absent "$stack/.publish.lock" "namespace-cutover waiter retained its publication lock"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-
  pass "publication waiters pin mutable namespaces only after acquiring the lock"
}

test_post_rename_lock_setup_failure_releases_owned_lock() {
  local stack="$TMP_ROOT/post-rename-setup-stack" out status
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic post-rename lock setup failure unexpectedly succeeded"
  assert_contains "$out" "synthetic report publication lock setup failure" \
    "post-rename setup failure did not preserve its primary error"
  assert_absent "$stack/.publish.lock" "post-rename setup failure retained its owned publication lock"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "post-rename setup cleanup left the report stack blocked"
  pass "post-rename publication setup failures release their owned lock"
}

test_publication_lock_release_failures_are_observable() {
  local stack="$TMP_ROOT/release-failure-stack" setup_stack="$TMP_ROOT/setup-release-failure-stack" out status
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_LOCK_TEST_RELEASE_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic publication lock release failure was hidden"
  assert_contains "$out" "synthetic report publication lock release failure" \
    "normal publication lock release failure was not observable"
  rm -rf "$stack/.publish.lock"

  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$setup_stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 FM_REPORT_LOCK_TEST_RELEASE_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "combined setup and release failure unexpectedly succeeded"
  assert_contains "$out" "synthetic report publication lock setup failure" \
    "release failure replaced the primary setup error"
  assert_contains "$out" "publication lock release also failed" \
    "secondary setup-cleanup release failure was hidden"
  rm -rf "$setup_stack/.publish.lock"
  pass "publication lock release failures remain observable without replacing primary errors"
}

test_previous_generation_is_recovered_for_readers() {
  local id=report-crash-recovery-k2 entry destination report_id cohort previous transaction json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Crash-safe report."
  run_stack publish "$id" >/dev/null || fail "crash-recovery report failed to publish"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  previous="$STACK/entries/.$report_id.previous"
  transaction="$STACK/entries/.$report_id.transaction"
  mv "$destination" "$previous"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$cohort" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover the previous generation"
  printf '%s\n' "$json" | grep -F '"taskId": "report-crash-recovery-k2"' >/dev/null \
    || fail "recovered previous generation was absent from report inventory"
  assert_present "$destination/report.html" "reader recovery did not restore the durable report entry"
  assert_absent "$previous" "reader recovery retained the hidden previous generation"
  assert_absent "$transaction" "reader recovery retained the completed report transaction"
  entry=$(run_stack path "$id") || fail "report path did not resolve after generation recovery"
  assert_present "$entry" "recovered report path is missing"
  pass "report readers recover crash-interrupted generation swaps"
}

test_replacement_transaction_recovery_restores_entry_and_index() {
  local id=report-replacement-transaction-k2b entry destination report_id cohort previous transaction staged json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original transaction generation."
  run_stack publish "$id" >/dev/null || fail "replacement transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  previous="$STACK/entries/.$report_id.previous"
  transaction="$STACK/entries/.$report_id.transaction"
  staged="$STACK/entries/.$report_id.999.tmp"
  mv "$destination" "$previous"
  cp -R "$previous" "$destination"
  sed -i.bak 's/Original transaction generation/Unindexed replacement generation/' "$destination/report.md"
  rm -f "$destination/report.md.bak"
  mkdir -p "$staged"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$cohort" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover an interrupted replacement transaction"
  printf '%s\n' "$json" | grep -F '"taskId": "report-replacement-transaction-k2b"' >/dev/null \
    || fail "replacement recovery omitted the restored report"
  assert_grep 'Original transaction generation' "$destination/report.md" "replacement recovery did not restore the prior report"
  assert_no_grep 'Unindexed replacement generation' "$destination/report.md" "replacement recovery retained the unindexed generation"
  assert_no_grep 'stale index' "$STACK/index.html" "replacement recovery did not rebuild the report index"
  assert_absent "$previous" "replacement recovery retained the rollback generation"
  assert_absent "$transaction" "replacement recovery retained its transaction marker"
  assert_absent "$staged" "replacement recovery retained transaction staging"
  pass "report recovery rolls back replacement entries and their stale index"
}

test_first_publication_transaction_recovery_removes_unindexed_entry() {
  local id=report-first-transaction-k2c entry destination report_id cohort transaction json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Uncommitted first publication."
  run_stack publish "$id" >/dev/null || fail "first-publication transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  transaction="$STACK/entries/.$report_id.transaction"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":null}\n' \
    "$report_id" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover an interrupted first publication"
  if printf '%s\n' "$json" | grep -F '"taskId": "report-first-transaction-k2c"' >/dev/null; then
    fail "first-publication recovery retained an uncommitted report"
  fi
  assert_absent "$destination" "first-publication recovery retained the unindexed entry"
  assert_absent "$transaction" "first-publication recovery retained its transaction marker"
  assert_present "$STACK/index.html" "first-publication recovery did not rebuild the report index"
  assert_no_grep 'stale index' "$STACK/index.html" "first-publication recovery retained the stale index"
  pass "report recovery removes interrupted first publications and rebuilds the index"
}

test_pre_rename_transaction_recovery_keeps_previous_generation() {
  local id=report-pre-rename-recovery-k2u entry destination report_id cohort destination_cohort transaction staged json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pre-rename crash generation."
  run_stack publish "$id" >/dev/null || fail "pre-rename transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  destination_cohort="cohort-$((${cohort#cohort-} + 300000))"
  transaction="$STACK/entries/.$report_id.transaction"
  staged="$STACK/entries/.$report_id.999.tmp"
  mkdir -p "$staged"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$destination_cohort" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover a pre-rename report transaction"
  printf '%s\n' "$json" | grep -F '"taskId": "report-pre-rename-recovery-k2u"' >/dev/null \
    || fail "pre-rename recovery lost the intact previous generation"
  assert_present "$destination/report.html" "pre-rename recovery displaced the intact previous generation"
  assert_absent "$STACK/entries/$destination_cohort/$report_id" "pre-rename recovery fabricated a destination generation"
  assert_absent "$transaction" "pre-rename recovery retained its transaction marker"
  assert_absent "$staged" "pre-rename recovery retained transaction staging"
  assert_no_grep 'stale index' "$STACK/index.html" "pre-rename recovery did not rebuild the report index"
  pass "report recovery keeps the intact previous generation when publication never started"
}

test_transaction_recovery_fails_when_every_generation_is_lost() {
  local id=report-lost-generations-k2v entry destination report_id cohort destination_cohort transaction out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Lost generations."
  run_stack publish "$id" >/dev/null || fail "lost-generation precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  destination_cohort="cohort-$((${cohort#cohort-} + 300000))"
  transaction="$STACK/entries/.$report_id.transaction"
  rm -rf "$destination"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$destination_cohort" "$cohort" > "$transaction"

  if out=$(run_stack list --json 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report recovery accepted a transaction with no surviving generation"
  assert_contains "$out" "lost both generations" "lost-generation refusal was unclear"
  assert_present "$transaction" "failed lost-generation recovery cleared its transaction marker"
  rm -f "$transaction"
  pass "report recovery still fails closed when every generation is lost"
}

test_aged_transactionless_staging_is_reclaimed() {
  local old fresh
  mkdir -p "$STACK/entries"
  old="$STACK/entries/.orphan-report.999.tmp"
  fresh="$STACK/entries/.active-looking-report.1000.tmp"
  mkdir -p "$old/visuals" "$fresh"
  printf 'orphaned visual\n' > "$old/visuals/evidence.txt"
  touch -t 200001010000 "$old"

  run_stack render >/dev/null || fail "report stack could not recover transactionless staging"
  assert_absent "$old" "aged transactionless report staging was not reclaimed"
  assert_present "$fresh" "fresh transactionless staging was reclaimed before the conservative age threshold"
  pass "report recovery reclaims only aged transactionless staging while locked"
}

test_completed_reports_prune_after_minimum_age() {
  local old_id=report-retention-old-k2d fresh_id=report-retention-fresh-k2e old_entry fresh_entry
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Expired report content."
  run_stack publish "$old_id" >/dev/null || fail "expired retention precondition publication failed"
  old_entry=$(run_stack path "$old_id") || fail "expired retention precondition path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Fresh report content."
  run_stack publish "$fresh_id" >/dev/null || fail "fresh retention precondition publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "fresh retention precondition path failed"
  old_entry=$(expire_report_entry "$old_entry") || fail "expired retention fixture could not be aged"
  run_stack render >/dev/null || fail "report retention sweep failed"
  assert_absent "$(dirname "$old_entry")" "expired completed report entry was not pruned"
  assert_present "$fresh_entry" "fresh completed report was pruned"
  assert_no_grep 'Expired report content' "$STACK/index.html" "report index retained an expired completed entry"
  assert_grep 'Fresh report content' "$STACK/index.html" "report index lost the fresh completed entry"
  pass "report stack prunes completed entries after their minimum age"
}

test_retention_binds_manifests_to_entry_directories() {
  local old_id=report-retention-mismatch-old-k2g fresh_id=report-retention-mismatch-fresh-k2h old_entry fresh_entry manifest temp out status fresh_report_id
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Expired mismatched report."
  run_stack publish "$old_id" >/dev/null || fail "mismatched retention old publication failed"
  old_entry=$(run_stack path "$old_id") || fail "mismatched retention old path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Fresh protected report."
  run_stack publish "$fresh_id" >/dev/null || fail "mismatched retention fresh publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "mismatched retention fresh path failed"
  manifest="$(dirname "$old_entry")/manifest.json"
  fresh_report_id=$(basename "$(dirname "$fresh_entry")")
  temp="$manifest.tmp"
  sed -e "s/\"reportId\": \"[^\"]*\"/\"reportId\": \"$fresh_report_id\"/" "$manifest" > "$temp"
  mv "$temp" "$manifest"
  if out=$(run_stack prune 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention accepted a manifest bound to another entry"
  assert_contains "$out" "report manifest identity mismatch" "retention mismatch refusal was unclear"
  assert_present "$old_entry" "retention mismatch deleted the enclosing expired entry"
  assert_present "$fresh_entry" "retention mismatch deleted the fresh entry named by the manifest"
  rm -rf "$(dirname "$old_entry")"
  pass "report retention binds every manifest to its enclosing entry"
}

test_watcher_periodically_owns_idle_report_retention() {
  local old_id=report-retention-watch-old-k2i fresh_id=report-retention-watch-fresh-k2j old_entry fresh_entry
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Watcher-expired report."
  run_stack publish "$old_id" >/dev/null || fail "watch retention old publication failed"
  old_entry=$(run_stack path "$old_id") || fail "watch retention old path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Watcher-fresh report."
  run_stack publish "$fresh_id" >/dev/null || fail "watch retention fresh publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "watch retention fresh path failed"
  old_entry=$(expire_report_entry "$old_entry") || fail "watcher retention fixture could not be aged"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=86400 FM_REPORT_RETENTION_TIMEOUT=5 bash -c '
      . "$1/bin/fm-watch.sh"
      prune_reports_if_due
      prune_reports_if_due
    ' _ "$ROOT" || fail "watcher-owned report retention failed"
  assert_absent "$(dirname "$old_entry")" "watcher-owned retention kept an expired report"
  assert_present "$fresh_entry" "watcher-owned retention removed a fresh report"
  assert_present "$HOME_DIR/state/.last-report-retention" "watcher-owned retention did not persist its cadence"
  pass "watcher supervision periodically owns idle report retention"
}

test_retention_restores_expired_entries_when_index_swap_fails() {
  local id=report-retention-rollback-k2f entry out status tombstone index
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Retention rollback content."
  run_stack publish "$id" >/dev/null || fail "retention rollback precondition publication failed"
  entry=$(run_stack path "$id") || fail "retention rollback precondition path failed"
  entry=$(expire_report_entry "$entry") || fail "retention rollback fixture could not be aged"
  rm -f "$STACK/index.html"
  mkdir "$STACK/index.html"
  if out=$(run_stack render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention unexpectedly replaced an unsafe report index destination"
  assert_absent "$(dirname "$entry")" "failed retention index swap restored an expired entry"
  tombstone=$(find "$STACK/.retention-tombstones" -mindepth 1 -maxdepth 1 -type d -name 'tombstone-*' -print -quit)
  [ -n "$tombstone" ] || fail "failed retention index swap lost its durable deletion tombstone"
  assert_present "$tombstone" "failed retention index swap lost its durable deletion tombstone"
  rmdir "$STACK/index.html"
  for index in $(seq 1 100); do
    run_stack prune >/dev/null || fail "retention could not resume a deletion tombstone"
    [ ! -e "$tombstone" ] && break
  done
  assert_absent "$tombstone" "resumed retention kept a completed deletion tombstone"
  [ -n "$out" ] || true
  pass "report retention preserves deletion tombstones across index failures"
}

test_retention_batches_make_interruption_safe_progress() {
  local id entry output index tombstone
  local -a entries
  for index in 1 2 3; do
    id="report-retention-batch-$index-k2l"
    write_task "$id" ship
    write_required_report "$HOME_DIR/data/$id/completion.md" "Expired batch $index."
    run_stack publish "$id" >/dev/null || fail "retention batch precondition $index failed"
    entry=$(run_stack path "$id") || fail "retention batch path $index failed"
    entries[index]="$entry"
  done
  for index in 1 2 3; do
    entries[index]=$(expire_report_entry "${entries[index]}") \
      || fail "retention batch fixture $index could not be aged"
  done
  output=$(FM_REPORT_RETENTION_BATCH=1 run_stack prune --status) || fail "first bounded retention batch failed"
  assert_contains "$output" '"pending":true' "bounded retention did not advertise remaining work"
  tombstone=$(find "$STACK/.retention-tombstones" -mindepth 1 -maxdepth 1 -type d -name 'tombstone-*' -print -quit)
  [ -n "$tombstone" ] || fail "bounded retention did not retain its pending tombstone"
  for index in 1 2 3; do
    assert_absent "$(dirname "${entries[index]}")" \
      "bounded retention left due report $index live after its visibility transaction"
  done
  assert_no_grep 'report-retention-batch-' "$STACK/index.html" \
    "bounded retention left a due report in the current index"
  for index in $(seq 1 100); do
    output=$(FM_REPORT_RETENTION_BATCH=1 run_stack prune --status) || fail "retention progress batch $index failed"
    case "$output" in *'"pending":false'*) break ;; esac
  done
  assert_absent "$tombstone" "bounded retention did not finish its expired cohort tombstone"
  pass "report retention removes every due report before bounded tombstone cleanup"
}

test_persistent_retention_owner_prunes_without_tasks_or_watcher() {
  local id=report-retention-owner-k2m entry fakebin install_root agents heartbeat out status bash_runtime node_runtime python_runtime plist log
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Persistent-owner expiry."
  run_stack publish "$id" >/dev/null || fail "persistent retention owner precondition failed"
  entry=$(run_stack path "$id") || fail "persistent retention owner path failed"
  entry=$(expire_report_entry "$entry") || fail "persistent retention fixture could not be aged"
  fakebin="$TMP_ROOT/retention-launchctl"; install_root="$TMP_ROOT/retention-install"; agents="$TMP_ROOT/LaunchAgents"
  log="$TMP_ROOT/launchctl.log"
  mkdir -p "$fakebin" "$agents"
  : > "$log"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-bootstrap.sh" install report-retention >/dev/null \
    || fail "retention LaunchAgent installation through bootstrap failed"
  node_runtime=$(command -v node)
  python_runtime=$(command -v python3)
  bash_runtime=$(command -v bash)
  plist="$agents/com.firstmate.report-retention.plist"
  assert_grep "<string>$bash_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Bash runtime"
  assert_grep "<key>FM_REPORT_RETENTION_NODE</key><string>$node_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Node runtime"
  assert_grep "<key>FM_REPORT_PYTHON</key><string>$python_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Python runtime"
  assert_grep "<key>FM_REPORT_RETENTION_COHORT_MS</key><string>${FM_REPORT_RETENTION_COHORT_MS:-300000}</string>" "$plist" \
    "retention LaunchAgent did not pin the publisher cohort width"
  assert_absent "$(dirname "$entry")" "installed retention owner did not enforce retention"
  heartbeat="$STACK/.retention-heartbeat"
  assert_present "$heartbeat" "installed retention owner did not record a successful-prune heartbeat"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure || fail "healthy installed retention owner was rejected"
  temp="$heartbeat.tmp"
  { printf '1\n'; sed -n '2p' "$heartbeat"; } > "$temp"
  mv "$temp" "$heartbeat"
  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "stale successful-prune heartbeat was accepted"
  assert_contains "$out" "heartbeat is stale" "stale retention heartbeat refusal was unclear"
  assert_grep 'bootstrap' "$log" "retention install did not bootstrap its LaunchAgent"
  assert_grep 'kickstart' "$log" "retention install did not start its LaunchAgent"
  pass "restart-capable retention installation is stable, task-independent, and health-checked"
}

test_retention_activation_restores_previous_generation_on_failure() {
  local fakebin install_root agents marker plist saved_plist out status failure failure_command node_runtime fail_marker fake_node log
  fakebin="$TMP_ROOT/retention-transaction-launchctl"
  install_root="$TMP_ROOT/retention-transaction-install"
  agents="$TMP_ROOT/retention-transaction-agents"
  marker="$install_root/bin/previous-generation-marker"
  plist="$agents/com.firstmate.report-retention.plist"
  saved_plist="$TMP_ROOT/retention-transaction-previous.plist"
  fake_node="$TMP_ROOT/retention-transaction-failing-node"
  log="$TMP_ROOT/retention-transaction.log"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = "${FM_FAKE_LAUNCHCTL_FAIL_COMMAND:-none}" ] \
  && [ ! -e "$FM_FAKE_LAUNCHCTL_FAIL_MARKER" ]; then
  : > "$FM_FAKE_LAUNCHCTL_FAIL_MARKER"
  exit 1
fi
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  cat > "$fake_node" <<'SH'
#!/usr/bin/env bash
echo 'synthetic first-prune failure'
exit 1
SH
  chmod +x "$fake_node"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_LAUNCHCTL_FAIL_COMMAND=none FM_FAKE_LAUNCHCTL_FAIL_MARKER="$TMP_ROOT/unused-retention-failure" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention transaction precondition installation failed"
  printf 'previous generation\n' > "$marker"
  cp "$plist" "$saved_plist"
  for failure in bootstrap kickstart prune; do
    fail_marker="$TMP_ROOT/retention-$failure.failure-used"
    rm -f "$fail_marker"
    : > "$log"
    failure_command=$failure
    node_runtime=
    if [ "$failure" = prune ]; then
      failure_command=none
      node_runtime=$fake_node
    fi
    if out=$(FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
      FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
      FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
      FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
      FM_FAKE_LAUNCHCTL_FAIL_COMMAND="$failure_command" FM_FAKE_LAUNCHCTL_FAIL_MARKER="$fail_marker" \
      FM_REPORT_RETENTION_NODE="$node_runtime" "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "$failure retention activation unexpectedly succeeded"
    assert_contains "$out" "previous generation restored" "$failure retention activation rollback was not reported"
    assert_present "$marker" "$failure retention activation discarded the previous owner bundle"
    cmp -s "$saved_plist" "$plist" || fail "$failure retention activation did not restore the previous LaunchAgent"
    assert_grep 'bootstrap' "$log" "$failure retention rollback did not re-bootstrap the prior LaunchAgent"
    assert_grep 'kickstart' "$log" "$failure retention rollback did not restart the prior LaunchAgent"
  done
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_LAUNCHCTL_FAIL_COMMAND=none FM_FAKE_LAUNCHCTL_FAIL_MARKER="$TMP_ROOT/unused-retention-failure" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "healthy retention replacement failed after rollback checks"
  assert_absent "$marker" "healthy retention replacement kept the superseded generation after its first prune"
  assert_present "$STACK/.retention-heartbeat" "healthy retention replacement removed the previous generation before its first-prune heartbeat"
  pass "retention activation keeps and restores the prior healthy generation"
}

test_retention_install_recovers_interrupted_generation_transaction() {
  local fakebin install_root agents marker plist saved_plist log out status transaction
  fakebin="$TMP_ROOT/retention-crash-launchctl"
  install_root="$TMP_ROOT/retention-crash-install"
  agents="$TMP_ROOT/retention-crash-agents"
  marker="$install_root/bin/previous-generation-marker"
  plist="$agents/com.firstmate.report-retention.plist"
  saved_plist="$TMP_ROOT/retention-crash-previous.plist"
  log="$TMP_ROOT/retention-crash.log"
  transaction="$install_root/.install-transaction"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention crash-recovery precondition installation failed"
  printf 'previous generation\n' > "$marker"
  cp "$plist" "$saved_plist"

  if out=$(FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=plist-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention installation interruption hook did not strand its transaction: $out"
  assert_present "$transaction" "interrupted retention installation did not persist its recovery transaction"
  assert_absent "$marker" "interrupted retention installation did not replace the canonical bundle before recovery"

  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not recover an interrupted installation"
  assert_present "$marker" "retention recovery did not restore the previous owner bundle"
  cmp -s "$saved_plist" "$plist" || fail "retention recovery did not restore the previous LaunchAgent"
  assert_absent "$transaction" "retention recovery left its completed install transaction"
  [ -z "$(find "$install_root" "$agents" -maxdepth 1 -name '*.previous.*' -print -quit)" ] \
    || fail "retention recovery left previous-generation backups"
  assert_grep 'bootstrap' "$log" "retention recovery did not re-bootstrap the previous LaunchAgent"
  assert_grep 'kickstart' "$log" "retention recovery did not restart the previous LaunchAgent"
  pass "retention install transactions recover the prior generation after interruption"
}

test_retention_install_and_recovery_share_owned_generation_lock() {
  local fakebin install_root agents log transaction snapshot ready release used
  local installer ensure_pid second_pid owner generation token unchanged=1 live_ensure=1 live_second=1
  local installer_status ensure_status second_status
  fakebin="$TMP_ROOT/retention-race-launchctl"
  install_root="$TMP_ROOT/retention-race-install"
  agents="$TMP_ROOT/retention-race-agents"
  log="$TMP_ROOT/retention-race.log"
  transaction="$install_root/.install-transaction"
  snapshot="$TMP_ROOT/retention-race.transaction"
  ready="$TMP_ROOT/retention-race.ready"
  release="$TMP_ROOT/retention-race.release"
  used="$TMP_ROOT/retention-race.used"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = bootstrap ] && [ ! -e "$FM_FAKE_BLOCK_USED" ]; then
  : > "$FM_FAKE_BLOCK_USED"
  : > "$FM_FAKE_BLOCK_READY"
  while [ ! -e "$FM_FAKE_BLOCK_RELEASE" ]; do sleep 0.05; done
fi
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" install > "$TMP_ROOT/retention-race-first.out" 2>&1 &
  installer=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] && [ -f "$transaction" ] \
    || { touch "$release"; wait "$installer" 2>/dev/null || true; fail "live retention installer did not reach its owned transaction"; }
  cp "$transaction" "$snapshot"
  owner=$(sed -n '5p' "$transaction")
  generation=$(sed -n '7p' "$transaction")
  token=$(sed -n '2p' "$transaction")

  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" ensure > "$TMP_ROOT/retention-race-ensure.out" 2>&1 &
  ensure_pid=$!
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" install > "$TMP_ROOT/retention-race-second.out" 2>&1 &
  second_pid=$!
  sleep 0.2
  cmp -s "$snapshot" "$transaction" || unchanged=0
  kill -0 "$ensure_pid" 2>/dev/null || live_ensure=0
  kill -0 "$second_pid" 2>/dev/null || live_second=0
  touch "$release"
  if wait "$installer"; then installer_status=0; else installer_status=$?; fi
  if wait "$ensure_pid"; then ensure_status=0; else ensure_status=$?; fi
  if wait "$second_pid"; then second_status=0; else second_status=$?; fi

  [ "$owner" = "$installer" ] || fail "retention transaction did not record its installer owner"
  [ "$generation" = "$token" ] || fail "retention transaction generation did not bind its backup token"
  [ "$unchanged" -eq 1 ] || fail "a concurrent install overwrote the live installer's transaction generation"
  [ "$live_ensure" -eq 1 ] || fail "ensure raced through recovery while the installer was live"
  [ "$live_second" -eq 1 ] || fail "a concurrent install bypassed global serialization"
  [ "$installer_status" -eq 0 ] && [ "$ensure_status" -eq 0 ] && [ "$second_status" -eq 0 ] \
    || fail "serialized retention install/ensure operations did not all complete successfully"
  assert_absent "$transaction" "serialized retention operations left a transaction marker"
  assert_absent "$install_root/.install-lock" "serialized retention operations left the global install lock"
  pass "retention install and recovery serialize on one owned transaction generation"
}

test_retention_error_publication_is_atomic_and_nonfollowing() {
  local stack fake_node outside out status
  stack="$TMP_ROOT/retention-error-stack"
  fake_node="$TMP_ROOT/retention-failing-node"
  outside="$TMP_ROOT/retention-error-outside"
  mkdir -p "$stack"
  printf 'outside bytes\n' > "$outside"
  ln -s "$outside" "$stack/.retention-error"
  cat > "$fake_node" <<'SH'
#!/usr/bin/env bash
echo 'synthetic prune failure'
exit 1
SH
  chmod +x "$fake_node"
  if out=$(FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_NODE="$fake_node" \
    FM_REPORT_RETENTION_INTERVAL=1 "$ROOT/bin/fm-report-retention.sh" run-once 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention error publication unexpectedly accepted a symlink control path"
  assert_contains "$out" "unsafe report-retention error control file" "unsafe retention error refusal was unclear"
  [ "$(cat "$outside")" = "outside bytes" ] \
    || fail "retention error publication followed and changed a symlink target"
  [ -L "$stack/.retention-error" ] || fail "retention error publication replaced an unsafe control symlink"
  pass "retention errors publish atomically without following control symlinks"
}

test_report_destination_roots_remain_pinned_during_ancestor_swap() {
  local id=report-destination-race-k2n ready proceed output moved outside pid status published_manifest state
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pinned destination roots."
  ready="$TMP_ROOT/report-destination.ready"; proceed="$TMP_ROOT/report-destination.proceed"
  output="$TMP_ROOT/report-destination.out"; moved="$TMP_ROOT/stack-original"; outside="$TMP_ROOT/stack-outside"
  mkdir -p "$STACK" "$outside"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_STACK_DESTINATION_TEST_READY="$ready" FM_REPORT_STACK_DESTINATION_TEST_PROCEED="$proceed" \
    "$SCRIPT" publish "$id" > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report destination race gate did not open: $(cat "$output")"
  fi
  [ "$state" = "destination-pinned" ] || fail "report destination gate emitted an unexpected state: $state"
  mv "$STACK" "$moved"
  ln -s "$outside" "$STACK"
  printf 'continue\n' >&8
  wait "$pid"; status=$?
  [ "$status" -eq 0 ] || fail "pinned report publication failed after ancestor swap: $(cat "$output")"
  published_manifest=$(grep -R -l -F "\"taskId\": \"$id\"" "$moved/entries")
  [ -n "$published_manifest" ] || fail "pinned report publication did not retain its task manifest"
  assert_grep 'Pinned destination roots.' "$(dirname "$published_manifest")/report.md" \
    "report publication left the originally pinned destination"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail "report publication was redirected through the swapped stack path"
  rm "$STACK"
  mv "$moved" "$STACK"
  exec 7>&-; exec 8>&-
  pass "report stack serializes and publishes through pinned destination roots"
}

test_report_publication_gate_uses_framed_fifo() {
  local id=report-publish-fifo-k2na ready proceed output pid status staged entry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Framed report publication."
  ready="$TMP_ROOT/report-publish-fifo.ready"; proceed="$TMP_ROOT/report-publish-fifo.proceed"
  output="$TMP_ROOT/report-publish-fifo.out"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_CONTAINED_REPORT_PUBLISH_TEST_READY="$ready" FM_CONTAINED_REPORT_PUBLISH_TEST_PROCEED="$proceed" \
    run_stack publish "$id" > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 staged <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report publication FIFO did not emit its staged generation: $(cat "$output")"
  fi
  case "$staged" in ".$id-"*.tmp) ;; *) fail "report publication FIFO emitted an unexpected frame: $staged" ;; esac
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "framed report publication failed: $(cat "$output")"
  entry=$(run_stack path "$id") || fail "framed report publication did not install a report"
  assert_grep 'Framed report publication.' "$(dirname "$entry")/report.md" \
    "framed report publication installed the wrong generation"
  exec 7>&-; exec 8>&-
  pass "report publication synchronization uses a framed one-shot FIFO"
}

test_index_failure_restores_previous_generation() {
  local id=report-index-rollback-k3 entry invalid out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original generation."
  run_stack publish "$id" >/dev/null || fail "index rollback precondition failed"
  entry=$(run_stack path "$id")
  invalid="$(dirname "$(dirname "$entry")")/invalid-manifest"
  mkdir -p "$invalid"
  printf '{invalid\n' > "$invalid/manifest.json"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Replacement generation."

  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "publication unexpectedly succeeded with an unreadable index manifest"
  assert_grep 'Original generation' "$(dirname "$entry")/report.md" "failed index rendering did not restore the previous report generation"
  if grep -F 'Replacement generation' "$(dirname "$entry")/report.md" >/dev/null 2>&1; then
    fail "failed index rendering retained the unindexed replacement generation"
  fi
  rm -rf "$invalid"
  [ -n "$out" ] || true
  pass "report publication restores the previous generation when index rendering fails"
}

test_readers_wait_for_publication_lock() {
  local started reader
  mkdir -p "$STACK/.publish.lock"
  started=$(LC_ALL=C ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')
  printf '{"pid":%s,"startedAt":"%s"}\n' "$$" "$started" > "$STACK/.publish.lock/owner"
  run_stack list --json > "$TMP_ROOT/locked-reader.out" 2> "$TMP_ROOT/locked-reader.err" &
  reader=$!
  sleep 0.2
  kill -0 "$reader" 2>/dev/null || fail "report reader bypassed the publication lock"
  rm -rf "$STACK/.publish.lock"
  wait "$reader" || fail "report reader failed after the publication lock was released: $(cat "$TMP_ROOT/locked-reader.err")"
  pass "report readers hold the publication lock while resolving entries"
}

test_source_symlinks_fail_closed() {
  local id out status outside
  outside="$TMP_ROOT/outside-artifact"
  printf 'outside artifact\n' > "$outside"

  id=report-source-symlink-f6
  write_task "$id" ship
  rm -f "$HOME_DIR/data/$id/completion.md"
  ln -s "$outside" "$HOME_DIR/data/$id/completion.md"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked completion report unexpectedly published"
  assert_contains "$out" "completion report must be a real regular file" "completion symlink refusal was not actionable"

  id=report-brief-symlink-g7
  write_task "$id" ship
  printf '# Completion\n\n## Summary\n\nSafe source.\n' > "$HOME_DIR/data/$id/completion.md"
  rm -f "$HOME_DIR/data/$id/brief.md"
  ln -s "$outside" "$HOME_DIR/data/$id/brief.md"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked task brief unexpectedly published"
  assert_contains "$out" "task brief must be a real regular file" "brief symlink refusal was not actionable"

  id=report-status-symlink-h8
  write_task "$id" ship
  printf '# Completion\n\n## Summary\n\nSafe source.\n' > "$HOME_DIR/data/$id/completion.md"
  rm -f "$HOME_DIR/state/$id.status"
  ln -s "$outside" "$HOME_DIR/state/$id.status"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked status trail unexpectedly published"
  assert_contains "$out" "status trail must be a real regular file" "status symlink refusal was not actionable"

  id=report-data-symlink-i9
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "report_required=1"
  mkdir -p "$TMP_ROOT/outside-task"
  printf '# Task\n\nOutside task.\n' > "$TMP_ROOT/outside-task/brief.md"
  printf '# Completion\n\n## Summary\n\nOutside source.\n' > "$TMP_ROOT/outside-task/completion.md"
  ln -s "$TMP_ROOT/outside-task" "$HOME_DIR/data/$id"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked task-data directory unexpectedly published"
  assert_contains "$out" "task data directory must be a real directory" "task-data symlink refusal was not actionable"

  if grep -R -F 'outside artifact' "$STACK" >/dev/null 2>&1; then
    fail "symlinked source content escaped into the report stack"
  fi
  assert_grep 'fs.openSync(file, flags)' "$SCRIPT" \
    "report text sources are not opened through their original non-following path"
  assert_grep 'stat.dev !== initial.dev || stat.ino !== initial.ino' "$SCRIPT" \
    "report text sources are not identity-bound after opening"
  pass "report stack rejects symlinked report source artifacts"
}

test_ambiguous_task_ids_require_report_ids() {
  local id=report-shared-j1 other_home out status ids first second exact
  other_home="$TMP_ROOT/other-home"
  mkdir -p "$other_home/state" "$other_home/data/$id"

  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "First home."
  run_stack publish "$id" >/dev/null || fail "first duplicate-id report failed to publish"

  fm_write_meta "$other_home/state/$id.meta" "kind=ship" "report_required=1" "project=other"
  printf '# Task\n\nSecond home task.\n' > "$other_home/data/$id/brief.md"
  printf 'done: second home\n' > "$other_home/state/$id.status"
  write_required_report "$other_home/data/$id/completion.md" "Second home."
  run_stack_home "$other_home" publish "$id" >/dev/null || fail "second duplicate-id report failed to publish"

  ids=$(run_stack list --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).filter(r=>r.taskId===process.argv[1]).map(r=>r.reportId).join("\n")))' "$id")
  first=$(printf '%s\n' "$ids" | sed -n '1p')
  second=$(printf '%s\n' "$ids" | sed -n '2p')
  [ -n "$first" ] && [ -n "$second" ] || fail "duplicate task ids did not produce two report ids"

  out=$(run_stack path "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "ambiguous bare task id unexpectedly resolved"
  assert_contains "$out" "is ambiguous" "ambiguous task-id lookup was not actionable"
  assert_contains "$out" "$first" "ambiguous task-id lookup omitted the first report id"
  assert_contains "$out" "$second" "ambiguous task-id lookup omitted the second report id"
  exact=$(run_stack path "$first") || fail "exact report-id lookup failed"
  assert_contains "$exact" "/$first/report.html" "exact report-id lookup selected the wrong entry"
  pass "report stack requires report ids for ambiguous cross-home task ids"
}

test_visual_symlink_fails_closed_and_cleans_staging() {
  local id=report-symlink-e5 out status staged
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Symlink safety."
  mkdir -p "$TMP_ROOT/outside-visuals"
  printf 'private visual bytes\n' > "$TMP_ROOT/outside-visuals/private.png"
  ln -s "$TMP_ROOT/outside-visuals" "$HOME_DIR/data/$id/visuals"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "symlinked visual root unexpectedly published"
  assert_contains "$out" "visual evidence root must be a real directory" "symlinked visual refusal was not actionable"
  if grep -R -F 'private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "symlinked visual content escaped into the report stack"
  fi
  staged=$(find "$STACK/entries" -maxdepth 1 -type d -name ".*${id}*.tmp" -print 2>/dev/null)
  [ -z "$staged" ] || fail "failed report publication leaked staging directory $staged"
  pass "report stack rejects symlinked visuals and removes failed staging"
}

test_visual_copy_is_descriptor_bounded() {
  local id=report-visual-bound-f6 out status source
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual copy."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  source="$HOME_DIR/data/$id/visuals/oversized.png"
  dd if=/dev/zero of="$source" bs=1048576 count=20 2>/dev/null
  printf x >> "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized visual was copied into the report stack"
  assert_contains "$out" "visual evidence exceeds the 20 MiB report limit" \
    "oversized visual refusal omitted its byte limit"
  assert_no_grep 'copyFileSync' "$SCRIPT" "visual publication still reopens sources with copyFileSync"
  assert_grep 'snapshot-task-fd' "$SCRIPT" "visual publication does not use the descriptor-relative snapshot helper"
  assert_grep 'dir_fd=' "$ROOT/bin/fm-contained-read.py" "visual publication does not traverse through directory descriptors"
  assert_grep 'os.O_NOFOLLOW' "$ROOT/bin/fm-contained-read.py" "visual publication does not use non-following descriptor opens"
  pass "report visual copies are descriptor-bound and byte-capped"
}

test_visual_containment_precedes_ancestor_swap() {
  local id=report-visual-race-f7 out status parent moved outside source hook marker entry tmp_real
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Stable visual containment."
  parent="$HOME_DIR/data/$id/visuals/nested"
  moved="$TMP_ROOT/pinned-visual-parent"
  outside="$TMP_ROOT/outside-visual-parent"
  source="$parent/evidence.png"
  hook="$TMP_ROOT/visual-swap-hook"
  marker="$TMP_ROOT/visual-swap-marker"
  mkdir -p "$parent" "$outside" "$hook"
  tmp_real=$(cd "$TMP_ROOT" && pwd -P)
  parent=$(cd "$parent" && pwd -P)
  outside=$(cd "$outside" && pwd -P)
  moved="$tmp_real/pinned-visual-parent"
  source="$parent/evidence.png"
  printf 'inside visual bytes\n' > "$source"
  printf 'outside private visual bytes\n' > "$outside/evidence.png"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "evidence.png" and not flags & os.O_WRONLY:
        swapped = True
        os.rename(os.environ["FM_REPORT_VISUAL_SWAP_PARENT"], os.environ["FM_REPORT_VISUAL_SWAP_MOVED"])
        os.rename(os.environ["FM_REPORT_VISUAL_SWAP_OUTSIDE"], os.environ["FM_REPORT_VISUAL_SWAP_PARENT"])
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_REPORT_VISUAL_SWAP_PARENT"], os.environ["FM_REPORT_VISUAL_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_REPORT_VISUAL_SWAP_MOVED"], os.environ["FM_REPORT_VISUAL_SWAP_PARENT"])
            with open(os.environ["FM_REPORT_VISUAL_SWAP_MARKER"], "w", encoding="utf-8") as marker:
                marker.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  if out=$(PYTHONPATH="$hook" \
    FM_REPORT_VISUAL_SWAP_PARENT="$parent" \
    FM_REPORT_VISUAL_SWAP_MOVED="$moved" \
    FM_REPORT_VISUAL_SWAP_OUTSIDE="$outside" \
    FM_REPORT_VISUAL_SWAP_MARKER="$marker" \
    run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "descriptor-relative visual publication failed during a restored ancestor swap: $out"
  assert_present "$marker" "visual ancestor-swap hook did not run"
  entry=$(run_stack path "$id") || fail "descriptor-relative visual report could not be resolved"
  assert_grep 'inside visual bytes' "$(dirname "$entry")/visuals/nested/evidence.png" \
    "visual publication lost the file beneath its pinned directory"
  if grep -R -F 'outside private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "ancestor-swapped outside visual escaped into the report stack"
  fi
  pass "report visual traversal remains anchored across ancestor swaps"
}

test_task_directory_identity_is_pinned_for_all_artifacts() {
  local id=report-task-root-race-f8 out status parent moved outside hook marker entry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Inside task report."
  parent=$(cd "$HOME_DIR/data/$id" && pwd -P)
  moved="$TMP_ROOT/pinned-task-root"
  outside="$TMP_ROOT/outside-task-root"
  hook="$TMP_ROOT/task-root-swap-hook"
  marker="$TMP_ROOT/task-root-swapped"
  mkdir -p "$parent/visuals" "$outside/visuals" "$hook"
  printf 'inside pinned visual bytes\n' > "$parent/visuals/evidence.png"
  printf '# Task\n\nOutside private task\n' > "$outside/brief.md"
  write_required_report "$outside/completion.md" "Outside private report."
  printf 'outside private visual bytes\n' > "$outside/visuals/evidence.png"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "brief.md":
        swapped = True
        os.rename(os.environ["FM_REPORT_TASK_SWAP_PARENT"], os.environ["FM_REPORT_TASK_SWAP_MOVED"])
        os.rename(os.environ["FM_REPORT_TASK_SWAP_OUTSIDE"], os.environ["FM_REPORT_TASK_SWAP_PARENT"])
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_REPORT_TASK_SWAP_PARENT"], os.environ["FM_REPORT_TASK_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_REPORT_TASK_SWAP_MOVED"], os.environ["FM_REPORT_TASK_SWAP_PARENT"])
            with open(os.environ["FM_REPORT_TASK_SWAP_MARKER"], "w", encoding="utf-8") as marker:
                marker.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  if out=$(PYTHONPATH="$hook" FM_REPORT_TASK_SWAP_PARENT="$parent" \
    FM_REPORT_TASK_SWAP_MOVED="$moved" FM_REPORT_TASK_SWAP_OUTSIDE="$outside" \
    FM_REPORT_TASK_SWAP_MARKER="$marker" run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "descriptor-relative task publication failed during a restored ancestor swap: $out"
  assert_present "$marker" "task-directory swap hook did not run: $out"
  entry=$(run_stack path "$id") || fail "descriptor-relative task report could not be resolved"
  assert_grep 'Inside task report' "$(dirname "$entry")/report.md" "task report did not come from the pinned task directory"
  assert_grep 'inside pinned visual bytes' "$(dirname "$entry")/visuals/evidence.png" "task visual did not come from the pinned task directory"
  if grep -R -E 'Outside private (task|report)|outside private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "sibling task artifacts escaped into the report stack"
  fi
  pass "report publication traverses every artifact through one pinned task directory"
}

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  test_stale_lock_rejects_reused_pid
  test_stale_lock_reclaim_is_serialized
  test_abandoned_reclaim_marker_is_recovered
  test_publish_lock_directory_symlink_fails_closed
  test_lock_control_files_are_bounded_and_nonfollowing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12 ]; then
  test_pr_url_strips_query_and_fragment
  test_abandoned_reclaim_directory_is_recovered
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  test_visual_copy_is_descriptor_bounded
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-14 ]; then
  test_text_sources_are_stored_verbatim_and_completion_is_bounded
  test_source_symlinks_fail_closed
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-15 ]; then
  test_same_generation_republish_preserves_revision_without_worktree
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-19 ]; then
  test_visual_containment_precedes_ancestor_swap
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-20 ]; then
  test_raw_html_does_not_satisfy_required_sections
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-21 ]; then
  test_nested_html_containers_do_not_satisfy_required_sections
  test_task_directory_identity_is_pinned_for_all_artifacts
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-22 ]; then
  test_task_directory_identity_is_pinned_for_all_artifacts
  test_completed_reports_prune_after_minimum_age
  test_retention_restores_expired_entries_when_index_swap_fails
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-23 ]; then
  test_report_artifacts_remain_verbatim_across_key_shaped_content
  test_container_scoped_fences_do_not_close_from_top_level
  test_retention_binds_manifests_to_entry_directories
  test_watcher_periodically_owns_idle_report_retention
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-24 ]; then
  test_large_non_utf8_text_artifacts_are_stored_verbatim
  test_large_visual_inventory_does_not_share_text_buffer_headroom
  test_container_scopes_preserve_commonmark_blank_and_exit_rules
  test_retention_restores_expired_entries_when_index_swap_fails
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-25 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_report_destination_roots_remain_pinned_during_ancestor_swap
  exit 0
fi

test_lazy_list_blocks_retain_their_container_scope() {
  local id=report-lazy-block-scope-b3p source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- list paragraph
  ```text
  ## Hidden heading
  ```
## Summary

Visible summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "a lazy-list fence consumed headings after the list ended"
  entry=$(run_stack path "$id") || fail "lazy-list fence report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Visible summary."' "$manifest" "lazy-list fence did not release its container scope"
  pass "lazy-list fenced blocks retain and exit their actual container scope"
}

test_contained_reader_rejects_special_files_without_blocking() {
  local root="$TMP_ROOT/contained-special" fifo output status pid
  mkdir -p "$root"
  fifo="$root/source"
  mkfifo "$fifo"
  output="$TMP_ROOT/contained-special.out"
  (
    cd "$root" || exit 1
    python3 "$ROOT/bin/fm-contained-read.py" read-fd source 1024 strict 3< "$root"
  ) > "$output" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "contained reader blocked while opening a FIFO"
  fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "contained reader accepted a FIFO"
  assert_contains "$(cat "$output")" "not a real regular file" "contained reader special-file refusal was unclear"
  pass "contained reads reject special files before nonblocking open"
}

test_report_contract_and_task_transaction_reject_fifos_without_blocking() {
  local root="$TMP_ROOT/task-special" fifo output pid status
  mkdir -p "$root/data/task"
  fifo="$root/data/task/brief.md"; mkfifo "$fifo"; output="$root/out"
  FM_GATE_REFUSE_BYPASS=1 bash -c '. "$1/bin/fm-report-contract-lib.sh"; fm_completion_report_contract_present "$2"' \
    _ "$ROOT" "$fifo" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "report contract blocked on FIFO"; fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report contract accepted FIFO"
  node - "$ROOT/bin/fm-file-transaction.cjs" "$root/data" > "$output" 2>&1 <<'JS' &
const { pinnedTaskFileTransaction } = require(process.argv[2]);
pinnedTaskFileTransaction(process.argv[3], 'task', 'brief.md', content => content);
JS
  pid=$!
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "task transaction blocked on FIFO"; fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "task transaction accepted FIFO"
  pass "task-file readers reject special files before nonblocking open"
}

test_report_entry_manifest_reads_stay_on_pinned_generation() {
  local id=report-entry-pin-z30c stack entry moved outside ready proceed output pid status
  stack="$TMP_ROOT/entry-pin-stack"
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pinned manifest content."
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" publish "$id" >/dev/null \
    || fail "entry-pin publication failed"
  entry=$(dirname "$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id")") \
    || fail "entry-pin path failed"
  moved="$TMP_ROOT/pinned-entry"; outside="$TMP_ROOT/outside-entry"; mkdir -p "$outside"
  printf '{"outside":true}\n' > "$outside/manifest.json"
  ready="$TMP_ROOT/entry-pin.ready"; proceed="$TMP_ROOT/entry-pin.proceed"; output="$TMP_ROOT/entry-pin.out"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_ENTRY_TEST_READY="$ready" FM_REPORT_ENTRY_TEST_PROCEED="$proceed" \
    "$SCRIPT" list --json > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "entry manifest pin gate did not open"; }
  mv "$entry" "$moved"; ln -s "$outside" "$entry"; touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  rm "$entry"; mv "$moved" "$entry"
  [ "$status" -eq 0 ] || fail "pinned manifest read failed: $(cat "$output")"
  assert_no_grep '"outside": true' "$output" "manifest read followed a swapped entry ancestor"
  pass "report manifests are read relative to pinned entry descriptors"
}

test_repository_fingerprint_recurses_through_submodule_worktrees() {
  local root="$TMP_ROOT/fingerprint-root" paths="$TMP_ROOT/fingerprint-paths" first second
  mkdir -p "$root/submodule/nested"
  printf 'first\n' > "$root/submodule/nested/file.txt"
  printf 'submodule\0' > "$paths"
  first=$(python3 "$ROOT/bin/fm-contained-read.py" fingerprint-paths-fd "$paths" 3< "$root") \
    || fail "initial descriptor-relative repository fingerprint failed"
  printf 'second\n' > "$root/submodule/nested/file.txt"
  second=$(python3 "$ROOT/bin/fm-contained-read.py" fingerprint-paths-fd "$paths" 3< "$root") \
    || fail "updated descriptor-relative repository fingerprint failed"
  [ "$first" != "$second" ] || fail "nested dirty submodule content did not change repository identity"
  assert_contains "$second" "submodule/nested/file.txt" "recursive repository identity omitted nested submodule content"
  pass "repository identity traverses pinned roots and dirty submodule content"
}

test_retention_cutoff_is_authoritative_before_cleanup() {
  local id=report-retention-cutoff-k2q second=report-retention-cutoff-k2r fresh=report-retention-fresh-k2q
  local entry second_entry fresh_entry ready output policy cutoff
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cutoff-visible report."
  run_stack publish "$id" >/dev/null || fail "cutoff precondition publication failed"
  entry=$(run_stack path "$id") || fail "cutoff precondition path failed"
  write_task "$fresh" ship
  write_required_report "$HOME_DIR/data/$fresh/completion.md" "Fresh report."
  run_stack publish "$fresh" >/dev/null || fail "fresh cutoff precondition publication failed"
  fresh_entry=$(run_stack path "$fresh") || fail "fresh cutoff precondition path failed"
  entry=$(expire_report_entry "$entry") || fail "retention cutoff fixture could not be aged"
  write_task "$second" ship
  write_required_report "$HOME_DIR/data/$second/completion.md" "Second cutoff-visible report."
  run_stack publish "$second" >/dev/null || fail "second cutoff precondition publication failed"
  second_entry=$(run_stack path "$second") || fail "second cutoff precondition path failed"
  second_entry=$(expire_report_entry "$second_entry" '1999-12-31T00:00:00.000Z') \
    || fail "second retention cutoff fixture could not be aged"
  ready="$TMP_ROOT/retention-policy.ready"; output="$TMP_ROOT/retention-policy.out"
  if FM_REPORT_RETENTION_POLICY_TEST_READY="$ready" FM_REPORT_RETENTION_POLICY_TEST_ABORT=1 \
    run_stack prune --status > "$output" 2>&1; then
    fail "retention namespace interruption hook unexpectedly completed"
  fi
  assert_present "$ready" "retention cutoff publication hook did not run"
  assert_absent "$(dirname "$entry")" "expired raw artifacts remained in the public namespace after the cutoff milestone"
  assert_absent "$(dirname "$second_entry")" "a later due cohort remained public after the atomic cutoff milestone"
  assert_present "$(dirname "$fresh_entry")" "fresh report became unavailable while an expired cohort was retired"
  policy="$STACK/.retention-policy.js"
  assert_present "$policy" "retention did not atomically publish its cutoff generation and index"
  assert_grep 'window.firstmateRetentionPolicy={"schemaVersion":1,"generation":"' "$policy" \
    "retention authority omitted its cutoff generation"
  cutoff=$(sed -n 's/.*"cutoffMs":\([0-9]*\).*/\1/p' "$policy")
  [ -n "$cutoff" ] && [ "$cutoff" -gt 946684800000 ] \
    || fail "retention authority did not hide the expired report before scanning manifests"
  assert_absent "$(dirname "$entry")" "interrupted retention restored expired raw artifacts"
  assert_absent "$(dirname "$second_entry")" "interrupted retention restored a later expired cohort"
  run_stack prune --status >/dev/null || fail "retention did not recover its interrupted namespace generation"
  assert_absent "$(dirname "$entry")" "retention cutoff cleanup left the expired report live"
  assert_present "$(dirname "$fresh_entry")" "retention cleanup removed an unrelated fresh cohort"
  assert_no_grep "$id" "$STACK/index.html" "completed retention rendering left an expired report visible"
  pass "retention atomically retires due cohorts without interrupting fresh reports"
}

test_retention_cohort_tombstone_is_noreplace_owned() {
  local id=report-retention-cohort-race-k2s entry source retired retired_name tombstone ready proceed output pid status
  id=report-retention-cohort-race-k2s
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cohort rename race."
  run_stack publish "$id" >/dev/null || fail "cohort rename race precondition publication failed"
  entry=$(run_stack path "$id") || fail "cohort rename race path failed"
  entry=$(expire_report_entry "$entry") || fail "cohort rename fixture could not be aged"
  source=$(dirname "$(dirname "$entry")")
  ready="$TMP_ROOT/cohort-rename.ready"; proceed="$TMP_ROOT/cohort-rename.proceed"; output="$TMP_ROOT/cohort-rename.out"
  FM_CONTAINED_RENAME_TEST_READY="$ready" FM_CONTAINED_RENAME_TEST_PROCEED="$proceed" \
    run_stack prune --status > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "cohort no-replace gate did not open"; }
  tombstone="$STACK/.retention-tombstones/$(cat "$ready")"
  retired_name=$(sed -n 's/.*"retiredName":"\([^"]*\)".*/\1/p' "$STACK/.retention-cutover.json")
  retired="$STACK/$retired_name"
  [ -n "$retired_name" ] || fail "cohort retirement did not retain its cutover identity"
  mkdir "$tombstone"; printf 'replacement\n' > "$tombstone/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "cohort retirement replaced a concurrently created tombstone"
  assert_present "$retired" "failed cohort retirement lost its uncommitted retired namespace"
  assert_grep replacement "$tombstone/sentinel" "cohort retirement mutated a replacement tombstone"
  rm -rf "$retired" "$tombstone" "$source"
  rm -f "$STACK/.retention-cutover.json"
  pass "retention cohort retirement is no-replace and generation-owned"
}

test_retention_cohort_source_swap_restores_replacement() {
  local source="$TMP_ROOT/cohort-source-swap" original="$TMP_ROOT/cohort-source-original"
  local tombstones="$TMP_ROOT/cohort-source-tombstones" ready="$TMP_ROOT/cohort-source.ready"
  local proceed="$TMP_ROOT/cohort-source.proceed" output="$TMP_ROOT/cohort-source.out" pid status identity
  mkdir -p "$source" "$tombstones"
  printf 'original\n' > "$source/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$source"; else stat -c '%d:%i' "$source"; fi)
  FM_CONTAINED_RENAME_TEST_READY="$ready" FM_CONTAINED_RENAME_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" rename-noreplace-owned-fd \
      "$(basename "$source")" tombstone "$identity" 3< "$(dirname "$source")" 4< "$tombstones" \
      > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "owned source-swap gate did not open"; }
  mv "$source" "$original"
  mkdir "$source"
  printf 'replacement\n' > "$source/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "owned cohort rename accepted a swapped source generation"
  assert_grep replacement "$source/sentinel" "swapped source generation was not restored to its public name"
  assert_grep original "$original/sentinel" "original owned generation was changed during the race"
  assert_absent "$tombstones/tombstone" "swapped source generation remained stranded in tombstones"
  pass "owned cohort retirement restores a replacement raced through rename"
}

test_retention_handoff_persists_and_retries_old_owner_fencing() {
  local fakebin="$TMP_ROOT/retention-handoff-launchctl" install_root="$TMP_ROOT/retention-handoff-install"
  local agents="$TMP_ROOT/retention-handoff-agents" log="$TMP_ROOT/retention-handoff.log" output status old_label
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap|kickstart) exit 0 ;;
  bootout) [ "${FM_FAKE_BOOTOUT_FAIL:-0}" != 1 ] || exit 1; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  if ! output=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then
    fail "retention handoff precondition installation failed: $output; retention error: $(cat "$STACK/.retention-error" 2>/dev/null)"
  fi
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' \
    "$agents/com.firstmate.report-retention.plist")
  if output=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" FM_FAKE_BOOTOUT_FAIL=1 \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention handoff completed while the previous owner remained loaded"
  assert_contains "$output" "previous owner fencing is pending" "unfenced previous owner failure was unclear"
  assert_present "$install_root/.owner-handoff-fence" "unfenced previous owner lacked a durable retry record"
  assert_grep "bootout gui/$(id -u)/$old_label" "$log" "retention handoff did not attempt to fence the previous owner"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 \
    FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" \
    FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not retry previous-owner fencing"
  assert_absent "$install_root/.owner-handoff-fence" "successful retry retained the previous-owner fence"
  pass "retention handoff persists and retries previous-owner fencing"
}

test_failed_initial_retention_activation_disarms_plist() {
  local fakebin="$TMP_ROOT/retention-initial-failure-launchctl" install_root="$TMP_ROOT/retention-initial-failure-install"
  local agents="$TMP_ROOT/retention-initial-failure-agents" log="$TMP_ROOT/retention-initial-failure.log"
  local plist out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=100 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "first retention installation unexpectedly accepted missing launched health"
  assert_contains "$out" "activation failed" "first-install activation failure was not reported"
  assert_absent "$plist" "failed first retention installation left an unproven reboot-armed plist"
  assert_grep 'bootout' "$log" "failed first retention installation did not unload its replacement job"
  pass "failed first retention installation removes its owned canonical plist"
}

test_retention_activation_wait_budget_accepts_delayed_health() {
  local fakebin="$TMP_ROOT/retention-delayed-launchctl" install_root="$TMP_ROOT/retention-delayed-install"
  local agents="$TMP_ROOT/retention-delayed-agents" log="$TMP_ROOT/retention-delayed.log"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap) exit 0 ;;
  kickstart)
    (
      sleep 5.5
      temp="$FM_REPORT_STACK_ROOT/.retention-heartbeat.delayed.$$"
      printf '%s\n%s\n%s\n%s\n' "$(date +%s)" "$FM_REPORT_RETENTION_EXPECTED_PROVENANCE" \
        "$FM_REPORT_RETENTION_EXPECTED_NONCE" "delayed-$$" > "$temp"
      mv -f "$temp" "$FM_REPORT_STACK_ROOT/.retention-heartbeat"
    ) &
    exit 0
    ;;
  bootout) exit 1 ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=7000 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention activation rejected health inside its configured wait budget"
  assert_present "$agents/com.firstmate.report-retention.plist" \
    "successful delayed retention activation removed its canonical plist"
  pass "retention activation honors its explicit launched-health wait budget"
}

test_bounded_report_reads_reject_fifo_swaps_without_blocking() {
  local id=bounded-read-race-z31 transaction saved ready proceed output pid status
  transaction="$STACK/entries/.$id.transaction"
  saved="$TMP_ROOT/bounded-read-race.transaction"
  ready="$TMP_ROOT/bounded-read-race.ready"
  proceed="$TMP_ROOT/bounded-read-race.proceed"
  output="$TMP_ROOT/bounded-read-race.out"
  printf '{"schemaVersion":1,"reportId":"%s","hadPrevious":false}\n' "$id" > "$transaction"
  FM_REPORT_BOUNDED_READ_TEST_READY="$ready" FM_REPORT_BOUNDED_READ_TEST_PROCEED="$proceed" \
    run_stack render > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "bounded report read race gate did not open"; }
  mv "$transaction" "$saved"
  mkfifo "$transaction"
  touch "$proceed"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "bounded report read blocked after a regular file became a FIFO"
  fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "bounded report read accepted a FIFO replacement"
  assert_contains "$(cat "$output")" "stable real regular file" \
    "bounded report read FIFO refusal was unclear"
  rm -f "$transaction"
  pass "bounded report reads open nonblocking and reject FIFO swaps"
}

test_retention_activation_requires_launched_nonce_without_owner_gap() {
  local fakebin="$TMP_ROOT/retention-nonce-launchctl" install_root="$TMP_ROOT/retention-nonce-install"
  local agents="$TMP_ROOT/retention-nonce-agents" log="$TMP_ROOT/retention-nonce.log"
  local plist saved old_label out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention activation-nonce precondition installation failed"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  saved="$TMP_ROOT/retention-nonce-prior.plist"
  cp "$plist" "$saved"
  : > "$log"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention activation reused its preflight heartbeat"
  assert_contains "$out" "activation failed" "missing launched heartbeat refusal was unclear"
  if grep -F "bootout gui/$(id -u)/$old_label" "$log" >/dev/null 2>&1; then
    fail "retention activation unloaded the working owner before replacement health"
  fi
  cmp -s "$saved" "$plist" \
    || fail "failed retention activation did not preserve its authoritative prior plist"
  pass "retention activation overlaps owners and requires a launched-job nonce"
}

test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline() {
  local fakebin="$TMP_ROOT/retention-bootstrap-heartbeat-launchctl"
  local install_root="$TMP_ROOT/retention-bootstrap-heartbeat-install"
  local agents="$TMP_ROOT/retention-bootstrap-heartbeat-agents"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_BOOTSTRAP=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention rejected a RunAtLoad heartbeat produced after bootstrap"
  assert_present "$agents/com.firstmate.report-retention.plist" \
    "retention did not publish the owner proven healthy during bootstrap"
  pass "retention activation baselines health before bootstrap RunAtLoad"
}

test_retention_pointer_failure_retires_only_candidate() {
  local fakebin="$TMP_ROOT/retention-pointer-failure-launchctl"
  local install_root="$TMP_ROOT/retention-pointer-failure-install"
  local agents="$TMP_ROOT/retention-pointer-failure-agents" log="$TMP_ROOT/retention-pointer-failure.log"
  local plist saved_plist saved_heartbeat old_label out status generations
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention pointer-failure precondition installation failed"
  saved_plist="$TMP_ROOT/retention-pointer-failure.saved.plist"
  saved_heartbeat="$TMP_ROOT/retention-pointer-failure.saved.heartbeat"
  cp "$plist" "$saved_plist"; cp "$STACK/.retention-heartbeat" "$saved_heartbeat"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  : > "$log"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_FAIL_POINTER=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention pointer publication failure unexpectedly succeeded"
  assert_contains "$out" "pointer publication failed" "retention pointer failure diagnostic was unclear"
  cmp -s "$saved_plist" "$plist" || fail "pointer failure changed the authoritative prior plist"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" || fail "pointer failure changed the authoritative prior heartbeat"
  if grep -F "bootout gui/$(id -u)/$old_label" "$log" >/dev/null 2>&1; then
    fail "pointer failure booted out the authoritative prior owner"
  fi
  assert_grep 'bootout ' "$log" "pointer failure did not retire its candidate owner"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 1 ] || fail "pointer failure retained candidate staging or generation state"
  pass "retention pointer failure preserves the authoritative owner and heartbeat"
}

test_retention_pointer_failure_retains_unfenced_candidate() {
  local fakebin="$TMP_ROOT/retention-unfenced-launchctl" install_root="$TMP_ROOT/retention-unfenced-install"
  local agents="$TMP_ROOT/retention-unfenced-agents" log="$TMP_ROOT/retention-unfenced.log"
  local plist saved_plist saved_heartbeat out status generations
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap|kickstart) exit 0 ;;
  bootout) [ "${FM_FAKE_BOOTOUT_FAIL:-}" != 1 ] ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "unfenced-candidate precondition installation failed"
  saved_plist="$TMP_ROOT/retention-unfenced.saved.plist"
  saved_heartbeat="$TMP_ROOT/retention-unfenced.saved.heartbeat"
  cp "$plist" "$saved_plist"; cp "$STACK/.retention-heartbeat" "$saved_heartbeat"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_FAIL_POINTER=1 FM_FAKE_BOOTOUT_FAIL=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "unfenced candidate pointer failure unexpectedly succeeded"
  assert_contains "$out" "candidate fencing is pending" "unfenced candidate failure was unclear"
  cmp -s "$saved_plist" "$plist" || fail "unfenced candidate replaced the authoritative plist"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" \
    && fail "unfenced candidate restored the prior heartbeat before bootout"
  assert_present "$install_root/.candidate-fence" "unfenced candidate lost its durable recovery record"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 2 ] || fail "unfenced candidate executable generation was removed"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null \
    || fail "later ensure could not finish candidate fencing"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" \
    || fail "successful later fencing did not restore the prior heartbeat"
  assert_absent "$install_root/.candidate-fence" "successful later fencing retained its recovery record"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 1 ] || fail "successful later fencing retained the candidate generation"
  pass "pointer failure retains candidates until bootout is positively confirmed"
}

test_retention_install_recovers_owned_stale_reclaim_marker() {
  local fakebin="$TMP_ROOT/retention-reclaim-launchctl" install_root="$TMP_ROOT/retention-reclaim-install"
  local agents="$TMP_ROOT/retention-reclaim-agents" reclaim="$TMP_ROOT/retention-reclaim-install/.install-lock-reclaim"
  mkdir -p "$fakebin" "$agents" "$install_root"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-reclaim-generation\n' > "$reclaim"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention install did not recover a positively stale reclaim owner"
  assert_absent "$reclaim" "retention install retained an abandoned owned reclaim marker"
  pass "retention install reclaim markers are owned and stale-recoverable"
}

test_retention_reclaim_never_removes_replacement_generation() {
  local fakebin="$TMP_ROOT/retention-reclaim-race-launchctl" install_root="$TMP_ROOT/retention-reclaim-race-install"
  local agents="$TMP_ROOT/retention-reclaim-race-agents" reclaim="$install_root/.install-lock-reclaim"
  local ready="$TMP_ROOT/retention-reclaim-race.ready" proceed="$TMP_ROOT/retention-reclaim-race.proceed"
  local replacement="$TMP_ROOT/retention-reclaim-race.replacement" output="$TMP_ROOT/retention-reclaim-race.out"
  local started installer status
  mkdir -p "$fakebin" "$agents" "$install_root"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/launchctl"; chmod +x "$fakebin/launchctl"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-reclaim-generation\n' > "$reclaim"
  started=$(LC_ALL=C ps -o lstart= -p "$$" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n%s\n%s\n' "$$" "$started" live-reclaim-generation > "$replacement"
  FM_CONTAINED_REMOVE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TEST_PROCEED="$proceed" \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install > "$output" 2>&1 &
  installer=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$installer" 2>/dev/null || true; fail "retention reclaim removal gate did not open"; }
  mv -f "$replacement" "$reclaim"
  touch "$proceed"
  if wait "$installer"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention install bypassed a live replacement reclaim owner"
  [ "$(sed -n '3p' "$reclaim")" = live-reclaim-generation ] \
    || fail "retention stale reclaim deleted or overwrote a replacement generation"
  pass "retention reclaim removes only the observed stale inode"
}

test_retention_generations_survive_install_interruptions() {
  local fakebin="$TMP_ROOT/retention-launchctl" install_root="$TMP_ROOT/retention-install"
  local agents="$TMP_ROOT/LaunchAgents" plist old_program new_program saved status out
  plist="$agents/com.firstmate.report-retention.plist"
  old_program=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$plist" | sed -n '2p')
  assert_present "$old_program" "retention precondition generation is missing"
  saved="$TMP_ROOT/retention-old.plist"
  cp "$plist" "$saved"
  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=generation-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "generation publication interrupt hook failed: $out"
  cmp -s "$saved" "$plist" || fail "publishing an immutable generation changed the authoritative job early"
  assert_present "$old_program" "generation publication moved the runnable prior owner"

  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=pointer-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "authoritative pointer interrupt hook failed: $out"
  new_program=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$plist" | sed -n '2p')
  [ "$new_program" != "$old_program" ] || fail "authoritative retention pointer did not advance generations"
  assert_present "$new_program" "authoritative retention pointer references an incomplete generation"
  assert_present "$old_program" "authoritative retention transition removed its prior runnable generation"
  pass "retention installation atomically points at immutable reboot-safe generations"
}

test_retention_install_reclaims_positively_stale_lock() {
  local fakebin="$TMP_ROOT/retention-launchctl" install_root="$TMP_ROOT/retention-install"
  local agents="$TMP_ROOT/LaunchAgents" lock="$TMP_ROOT/retention-install/.install-lock"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-install-token\n' > "$lock"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not reclaim a positively stale install lock"
  assert_absent "$lock" "retention ensure retained its reclaimed install lock"
  pass "retention installation reclaims only a positively stale owned lock"
}

test_retention_prepointer_recovery_fences_candidate() {
  local fakebin="$TMP_ROOT/retention-prepointer-launchctl" install_root="$TMP_ROOT/retention-prepointer-install"
  local agents="$TMP_ROOT/retention-prepointer-agents" log="$TMP_ROOT/retention-prepointer.log"
  local plist old_label candidate_label out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention pre-pointer recovery precondition failed"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=owner-handoff-prepointer \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention pre-pointer interruption hook failed: $out"
  [ "$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")" = "$old_label" ] \
    || fail "retention pre-pointer interruption advanced the authoritative plist"
  assert_absent "$install_root/.candidate-fence" \
    "retention pre-pointer handoff retained duplicate candidate ownership"
  candidate_label=$(sed -n '4p' "$install_root/.owner-handoff-fence")
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null \
    || fail "retention ensure did not recover its pre-pointer handoff"
  assert_grep "bootout gui/$(id -u)/$candidate_label" "$log" \
    "pre-pointer recovery did not fence the running candidate"
  assert_absent "$install_root/.owner-handoff-fence" "pre-pointer recovery retained its handoff fence"
  pass "retention pre-pointer recovery fences the uncommitted candidate"
}

test_retention_candidate_is_fenced_before_bootstrap() {
  local fakebin="$TMP_ROOT/retention-candidate-launchctl" install_root="$TMP_ROOT/retention-candidate-install"
  local agents="$TMP_ROOT/retention-candidate-agents" log="$TMP_ROOT/retention-candidate.log"
  local candidate_label out status
  mkdir -p "$fakebin" "$agents"
  : > "$log"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=candidate-fenced \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention candidate-fence interruption hook failed: $out"
  assert_present "$install_root/.candidate-fence" "candidate ownership was not durable before bootstrap"
  candidate_label=$(sed -n '2p' "$install_root/.candidate-fence")
  assert_no_grep "bootstrap .*${candidate_label}" "$log" \
    "candidate LaunchAgent bootstrapped before its durable ownership fence"
  if FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null 2>&1; then
    fail "retention ensure unexpectedly treated the interrupted first installation as installed"
  fi
  assert_grep "bootout gui/$(id -u)/$candidate_label" "$log" \
    "retention recovery did not fence its recorded candidate"
  assert_absent "$install_root/.candidate-fence" "retention recovery retained its candidate fence"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention installation did not recover after fencing its interrupted candidate"
  pass "retention records candidate ownership before LaunchAgent bootstrap"
}

test_retention_cleanup_is_file_granular() {
  local tombstones="$TMP_ROOT/file-granular-tombstones" tombstone="$TMP_ROOT/file-granular-tombstones/tombstone-test"
  local before after output
  mkdir -p "$tombstone/cohort/report/visuals"
  printf 'one\n' > "$tombstone/cohort/report/report.md"
  printf 'two\n' > "$tombstone/cohort/report/visuals/one.png"
  printf 'three\n' > "$tombstone/cohort/report/visuals/two.png"
  before=$(find "$tombstone" -mindepth 1 | wc -l | tr -d ' ')
  output=$(python3 "$ROOT/bin/fm-contained-read.py" prune-tombstones-fd 1 3< "$tombstones") \
    || fail "file-granular retention cleanup failed"
  after=$(find "$tombstone" -mindepth 1 | wc -l | tr -d ' ')
  [ "$after" -eq "$((before - 1))" ] || fail "one retention batch removed more than one filesystem item"
  assert_contains "$output" '"pending":true' "file-granular retention cleanup did not persist remaining work"
  pass "retention cleanup budgets progress at file granularity"
}

test_retention_fresh_handoff_is_cohort_bounded_and_continuous() {
  local due="$STACK/entries/cohort-946684700000"
  local base name probe probe_identity after_identity count=64 i
  mkdir "$due"
  printf 'expired bytes\n' > "$due/sentinel"
  base=$(( $(date +%s) * 1000 + 86400000 ))
  for i in $(seq 1 "$count"); do
    name="cohort-$((base + i * 300000))"
    mkdir "$STACK/entries/$name"
    printf 'fresh-%s\n' "$i" > "$STACK/entries/$name/sentinel"
  done
  probe="$STACK/entries/cohort-$((base + 300000))"
  probe_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$probe"; else stat -c '%d:%i' "$probe"; fi)
  run_stack prune --status >/dev/null || fail "retention did not retire its due cohort"
  assert_absent "$due" "retention left its due cohort public while preserving fresh cohorts"
  for i in $(seq 1 "$count"); do
    name="cohort-$((base + i * 300000))"
    assert_grep "fresh-$i" "$STACK/entries/$name/sentinel" \
      "recovered retention handoff lost fresh cohort $i"
  done
  after_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$probe"; else stat -c '%d:%i' "$probe"; fi)
  [ "$after_identity" = "$probe_identity" ] || fail "fresh cohort handoff copied instead of moving its owned directory generation"
  pass "retention retires due cohorts without staging or replacing fresh cohorts"
}

test_report_publication_restores_swapped_staging_generation() {
  local id=report-publish-generation-race-k2t entry ready proceed output pid status staged saved
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original published report."
  run_stack publish "$id" >/dev/null || fail "report generation-race precondition failed"
  entry=$(run_stack path "$id") || fail "report generation-race precondition path failed"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Replacement report attempt."
  ready="$TMP_ROOT/report-publish-generation.ready"; proceed="$TMP_ROOT/report-publish-generation.proceed"
  output="$TMP_ROOT/report-publish-generation.out"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_CONTAINED_REPORT_RENAME_TEST_READY="$ready" FM_CONTAINED_REPORT_RENAME_TEST_PROCEED="$proceed" \
    run_stack publish "$id" > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 staged <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report generation rename gate did not open: $(cat "$output")"
  fi
  staged="$STACK/entries/$staged"
  saved="$staged.saved"
  mv "$staged" "$saved"
  mkdir "$staged"
  printf 'unowned replacement\n' > "$staged/sentinel"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report publication accepted a swapped staging generation"
  assert_grep 'Original published report' "$(dirname "$entry")/report.md" \
    "failed report publication did not preserve the prior generation"
  assert_absent "$(dirname "$entry")/sentinel" "unowned staging replacement was published"
  assert_grep 'unowned replacement' "$staged/sentinel" \
    "failed report publication did not restore the unowned staging replacement"
  assert_present "$saved/manifest.json" "failed report publication lost its displaced owned staging generation"
  rm -rf "$staged" "$saved"
  exec 7>&-; exec 8>&-
  pass "report publication restores a staging generation raced through rename"
}

test_owned_tree_cleanup_quarantines_before_deletion() {
  local root="$TMP_ROOT/owned-tree-cleanup" owned="$TMP_ROOT/owned-tree-cleanup/owned"
  local tombstones="$TMP_ROOT/owned-tree-cleanup-tombstones"
  local ready="$TMP_ROOT/owned-tree-cleanup.ready" proceed="$TMP_ROOT/owned-tree-cleanup.proceed"
  local output="$TMP_ROOT/owned-tree-cleanup.out" identity quarantine pid status
  mkdir -p "$owned/nested" "$tombstones"
  printf 'owned generation\n' > "$owned/nested/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$owned"; else stat -c '%d:%i' "$owned"; fi)
  FM_CONTAINED_REMOVE_TREE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TREE_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" remove-owned-tree-fd owned "$identity" \
      3< "$root" 4< "$tombstones" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "owned tree quarantine gate did not open"; }
  quarantine=$(cat "$ready")
  assert_absent "$owned" "owned tree remained at its public name during recursive deletion"
  mkdir "$owned"
  printf 'concurrent replacement\n' > "$owned/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "quarantined owned tree cleanup failed: $(cat "$output")"
  assert_grep 'concurrent replacement' "$owned/sentinel" \
    "owned tree cleanup removed a concurrent replacement generation"
  assert_absent "$tombstones/$quarantine" "owned tree cleanup retained its private quarantine"
  pass "owned tree cleanup quarantines its generation before recursive deletion"
}

test_interrupted_owned_tree_cleanup_enters_retention_recovery() {
  local root="$TMP_ROOT/owned-tree-interrupt" owned="$TMP_ROOT/owned-tree-interrupt/owned"
  local tombstones="$TMP_ROOT/owned-tree-interrupt-tombstones"
  local ready="$TMP_ROOT/owned-tree-interrupt.ready" proceed="$TMP_ROOT/owned-tree-interrupt.proceed"
  local output="$TMP_ROOT/owned-tree-interrupt.out" identity quarantine pid status
  mkdir -p "$owned/nested" "$tombstones"
  printf 'recoverable generation\n' > "$owned/nested/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$owned"; else stat -c '%d:%i' "$owned"; fi)
  FM_CONTAINED_REMOVE_TREE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TREE_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" remove-owned-tree-fd owned "$identity" \
      3< "$root" 4< "$tombstones" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "interrupted owned tree quarantine gate did not open"; }
  quarantine=$(cat "$ready")
  kill -KILL "$pid" 2>/dev/null || true
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "owned tree interruption fixture exited successfully"
  assert_absent "$owned" "interrupted cleanup restored an expired public generation"
  assert_grep 'recoverable generation' "$tombstones/$quarantine/nested/sentinel" \
    "interrupted cleanup did not leave its generation in retention recovery"
  python3 "$ROOT/bin/fm-contained-read.py" prune-tombstones-fd 10 3< "$tombstones" >/dev/null \
    || fail "retention recovery did not sweep an interrupted owned tree"
  assert_absent "$tombstones/$quarantine" "retention recovery left the interrupted owned tree indefinitely"
  pass "interrupted owned tree cleanup remains enrolled in retention recovery"
}

if [ "${FM_TEST_FOCUSED:-}" = report-lock-handshakes ]; then
  test_stale_lock_reclaim_is_serialized
  test_install_guard_release_failure_cleans_owned_lock
  test_post_install_guard_owner_death_is_recovered
  test_reclaim_guard_fences_the_stale_generation_gap
  test_abandoned_reclaim_guard_is_recovered
  test_report_publication_restores_swapped_staging_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-27 ]; then
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_install_reclaims_positively_stale_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-29 ]; then
  test_lazy_list_blocks_retain_their_container_scope
  test_contained_reader_rejects_special_files_without_blocking
  test_repository_fingerprint_recurses_through_submodule_worktrees
  test_retention_cutoff_is_authoritative_before_cleanup
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_install_reclaims_positively_stale_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-30 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_install_recovers_owned_stale_reclaim_marker
  test_report_contract_and_task_transaction_reject_fifos_without_blocking
  test_report_entry_manifest_reads_stay_on_pinned_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-31 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_failed_initial_retention_activation_disarms_plist
  test_retention_activation_wait_budget_accepts_delayed_health
  test_bounded_report_reads_reject_fifo_swaps_without_blocking
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-32 ]; then
  test_revision_fields_distinguish_pr_head_from_worktree_head
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_manifest_cohort_must_match_completion_time
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline
  test_retention_pointer_failure_retires_only_candidate
  test_retention_pointer_failure_retains_unfenced_candidate
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_nested_list_parent_scope_hides_required_headings
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-33 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_source_swap_restores_replacement
  test_retention_handoff_persists_and_retries_old_owner_fencing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-retention ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cleanup_is_file_granular
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_retention_prepointer_recovery_fences_candidate
  test_report_publication_restores_swapped_staging_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-35 ]; then
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_report_entry_manifest_reads_stay_on_pinned_generation
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_retention_candidate_is_fenced_before_bootstrap
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-36 ]; then
  test_publish_ship_with_visual
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_retention_owner_advances_pending_legacy_migration
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_owned_tree_cleanup_quarantines_before_deletion
  test_interrupted_owned_tree_cleanup_enters_retention_recovery
  test_retention_cohort_never_precedes_exact_expiry
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-minimum-age ]; then
  test_retention_guard_cannot_advance_minimum_age
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-37 ]; then
  test_retention_guard_cannot_advance_minimum_age
  test_retention_cutoff_never_regresses_with_wall_time
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-38 ]; then
  test_retention_cohort_and_sweep_share_drift_budget
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-parser ]; then
  test_nested_list_parent_scope_hides_required_headings
  test_blockquote_list_scope_requires_quote_markers
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-round-30 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_install_recovers_owned_stale_reclaim_marker
  test_retention_reclaim_never_removes_replacement_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-28 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_underindented_list_headings_exit_lazy_continuation
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-26 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_error_publication_is_atomic_and_nonfollowing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-fence-enforcement ]; then
  test_required_sections_fail_actionably
  test_nested_short_fences_do_not_satisfy_required_sections
  test_indented_pseudo_closers_do_not_end_fences
  test_required_headings_follow_commonmark_atx_rules
  test_invalid_backtick_info_string_does_not_open_fence
  test_summary_extraction_uses_validated_markdown_structure
  test_list_container_fences_hide_report_headings_and_summaries
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = fenced-report-body-final ]; then
  test_fenced_required_section_bodies_use_scoped_content
  test_nested_short_fences_do_not_satisfy_required_sections
  test_container_scoped_fences_do_not_close_from_top_level
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-container-markers ]; then
  test_required_sections_reject_container_only_markers
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-findings ]; then
  test_required_sections_fail_actionably
  test_required_sections_reject_empty_bodies
  test_namespace_cutover_waiter_pins_entries_after_lock_acquisition
  test_report_destination_roots_remain_pinned_during_ancestor_swap
  test_report_publication_gate_uses_framed_fifo
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-generation-recovery ]; then
  test_previous_generation_is_recovered_for_readers
  test_replacement_transaction_recovery_restores_entry_and_index
  test_first_publication_transaction_recovery_removes_unindexed_entry
  test_pre_rename_transaction_recovery_keeps_previous_generation
  test_transaction_recovery_fails_when_every_generation_is_lost
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-cohort-fixtures ]; then
  test_completed_reports_prune_after_minimum_age
  test_retention_binds_manifests_to_entry_directories
  test_watcher_periodically_owns_idle_report_retention
  test_retention_restores_expired_entries_when_index_swap_fails
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-cohort-width ]; then
  test_manifest_cohort_must_match_completion_time
  test_manifest_cohort_deadline_cannot_precede_expiry
  test_manifest_validation_is_cohort_width_independent
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-retention-state-leak ]; then
  test_report_temps_are_exclusive_and_randomized
  test_completed_reports_prune_after_minimum_age
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-handoff-state-leak ]; then
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  test_retention_cohort_source_swap_restores_replacement
  test_retention_handoff_persists_and_retries_old_owner_fencing
  exit 0
fi

run_partitioned_test() {
  FM_TEST_PART_SEQUENCE=$((FM_TEST_PART_SEQUENCE + 1))
  if [ "$FM_TEST_PART_TOTAL" -gt 1 ] \
    && [ $(((FM_TEST_PART_SEQUENCE - 1) % FM_TEST_PART_TOTAL + 1)) -ne "$FM_TEST_PART_INDEX" ]; then
    return 0
  fi
  "$@"
}

run_partitioned_group() {
  local assigned_part group_size=$# test_function
  assigned_part=$((FM_TEST_PART_SEQUENCE % FM_TEST_PART_TOTAL + 1))
  FM_TEST_PART_SEQUENCE=$((FM_TEST_PART_SEQUENCE + group_size))
  if [ "$FM_TEST_PART_TOTAL" -gt 1 ] && [ "$assigned_part" -ne "$FM_TEST_PART_INDEX" ]; then
    return 0
  fi
  for test_function in "$@"; do
    "$test_function"
  done
}

FM_TEST_PART_INDEX=${FM_TEST_PART_INDEX:-1}
FM_TEST_PART_TOTAL=${FM_TEST_PART_TOTAL:-1}
FM_TEST_PART_SEQUENCE=0

run_partitioned_test test_publish_ship_with_visual
run_partitioned_test test_report_artifacts_remain_verbatim_across_key_shaped_content
run_partitioned_test test_report_links_reject_credentials_and_encode_visual_paths
run_partitioned_test test_pr_url_strips_query_and_fragment
run_partitioned_test test_revision_fields_distinguish_pr_head_from_worktree_head
run_partitioned_test test_republish_new_generation_refreshes_completion_time
run_partitioned_test test_same_generation_republish_preserves_revision_without_worktree
run_partitioned_test test_generation_identity_falls_back_only_when_both_sides_are_legacy
run_partitioned_test test_text_sources_are_stored_verbatim_and_completion_is_bounded
run_partitioned_test test_metadata_is_bounded_before_reading
run_partitioned_test test_report_temps_are_exclusive_and_randomized
run_partitioned_test test_visual_inventory_is_count_and_depth_bounded
run_partitioned_test test_required_source_fails_closed
run_partitioned_test test_required_sections_fail_actionably
run_partitioned_test test_required_sections_reject_empty_bodies
run_partitioned_test test_required_sections_reject_container_only_markers
run_partitioned_test test_fenced_required_section_bodies_use_scoped_content
run_partitioned_test test_nested_short_fences_do_not_satisfy_required_sections
run_partitioned_test test_raw_html_does_not_satisfy_required_sections
run_partitioned_test test_container_scoped_fences_do_not_close_from_top_level
run_partitioned_test test_indented_pseudo_closers_do_not_end_fences
run_partitioned_test test_required_headings_follow_commonmark_atx_rules
run_partitioned_test test_invalid_backtick_info_string_does_not_open_fence
run_partitioned_test test_summary_extraction_uses_validated_markdown_structure
run_partitioned_test test_list_container_fences_hide_report_headings_and_summaries
run_partitioned_test test_list_lazy_continuations_do_not_satisfy_required_sections
run_partitioned_test test_underindented_list_headings_exit_lazy_continuation
run_partitioned_test test_nested_list_parent_scope_hides_required_headings
run_partitioned_test test_blockquote_list_scope_requires_quote_markers
run_partitioned_test test_container_scopes_preserve_commonmark_blank_and_exit_rules
run_partitioned_test test_large_non_utf8_text_artifacts_are_stored_verbatim
run_partitioned_test test_large_visual_inventory_does_not_share_text_buffer_headroom
run_partitioned_test test_scout_and_legacy_sources
run_partitioned_test test_stale_lock_rejects_reused_pid
run_partitioned_test test_stale_lock_reclaim_is_serialized
run_partitioned_test test_install_guard_release_failure_cleans_owned_lock
run_partitioned_test test_post_install_guard_owner_death_is_recovered
run_partitioned_test test_reclaim_guard_fences_the_stale_generation_gap
run_partitioned_test test_abandoned_reclaim_guard_is_recovered
run_partitioned_test test_abandoned_reclaim_marker_is_recovered
run_partitioned_test test_abandoned_reclaim_directory_is_recovered
run_partitioned_test test_publish_lock_directory_symlink_fails_closed
run_partitioned_test test_lock_control_files_are_bounded_and_nonfollowing
run_partitioned_test test_namespace_cutover_waiter_pins_entries_after_lock_acquisition
run_partitioned_test test_post_rename_lock_setup_failure_releases_owned_lock
run_partitioned_test test_publication_lock_release_failures_are_observable
run_partitioned_test test_previous_generation_is_recovered_for_readers
run_partitioned_test test_replacement_transaction_recovery_restores_entry_and_index
run_partitioned_test test_first_publication_transaction_recovery_removes_unindexed_entry
run_partitioned_test test_pre_rename_transaction_recovery_keeps_previous_generation
run_partitioned_test test_transaction_recovery_fails_when_every_generation_is_lost
run_partitioned_test test_aged_transactionless_staging_is_reclaimed
run_partitioned_test test_completed_reports_prune_after_minimum_age
run_partitioned_test test_retention_binds_manifests_to_entry_directories
run_partitioned_test test_watcher_periodically_owns_idle_report_retention
run_partitioned_test test_retention_batches_make_interruption_safe_progress
run_partitioned_group \
  test_persistent_retention_owner_prunes_without_tasks_or_watcher \
  test_retention_generations_survive_install_interruptions
run_partitioned_test test_retention_error_publication_is_atomic_and_nonfollowing
run_partitioned_test test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
run_partitioned_test test_retention_owner_advances_pending_legacy_migration
run_partitioned_test test_manifest_cohort_must_match_completion_time
run_partitioned_test test_manifest_cohort_deadline_cannot_precede_expiry
run_partitioned_test test_manifest_validation_is_cohort_width_independent
run_partitioned_test test_retention_cohort_never_precedes_exact_expiry
run_partitioned_test test_retention_cohort_and_sweep_share_drift_budget
run_partitioned_test test_retention_cutoff_is_authoritative_before_cleanup
run_partitioned_test test_retention_cohort_tombstone_is_noreplace_owned
run_partitioned_test test_retention_cohort_source_swap_restores_replacement
run_partitioned_test test_retention_handoff_persists_and_retries_old_owner_fencing
run_partitioned_test test_retention_prepointer_recovery_fences_candidate
run_partitioned_test test_retention_candidate_is_fenced_before_bootstrap
run_partitioned_test test_retention_cleanup_is_file_granular
run_partitioned_test test_retention_fresh_handoff_is_cohort_bounded_and_continuous
run_partitioned_test test_report_entry_manifest_reads_stay_on_pinned_generation
run_partitioned_test test_report_publication_restores_swapped_staging_generation
run_partitioned_test test_owned_tree_cleanup_quarantines_before_deletion
run_partitioned_test test_interrupted_owned_tree_cleanup_enters_retention_recovery
run_partitioned_test test_retention_activation_requires_launched_nonce_without_owner_gap
run_partitioned_test test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline
run_partitioned_test test_retention_pointer_failure_retires_only_candidate
run_partitioned_test test_retention_pointer_failure_retains_unfenced_candidate
run_partitioned_test test_nested_list_parent_scope_hides_required_headings
run_partitioned_test test_report_destination_roots_remain_pinned_during_ancestor_swap
run_partitioned_test test_report_publication_gate_uses_framed_fifo
run_partitioned_test test_index_failure_restores_previous_generation
run_partitioned_test test_readers_wait_for_publication_lock
run_partitioned_test test_visual_symlink_fails_closed_and_cleans_staging
run_partitioned_test test_visual_copy_is_descriptor_bounded
run_partitioned_test test_visual_containment_precedes_ancestor_swap
run_partitioned_test test_source_symlinks_fail_closed
run_partitioned_test test_ambiguous_task_ids_require_report_ids
