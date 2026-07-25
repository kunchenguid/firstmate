#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_ship_completion_report_contract() {
  local home id brief
  home="$TMP_ROOT/completion-report-home"
  mkdir -p "$home/data"
  id="brief-report-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "# Completion report" "$brief" "ship brief has no completion-report contract"
  assert_grep "data/$id/completion.md" "$brief" "ship brief has no durable report path"
  assert_grep "six sections, each as a LEVEL-TWO markdown heading spelled exactly" "$brief" \
    "ship brief does not require exact level-two report headings"
  assert_grep "\`## Summary\`, \`## What changed\`, \`## Verification\`, \`## Visual evidence\`, \`## Artifacts\`, \`## Follow-ups\`" "$brief" \
    "ship brief has no exact review-oriented report schema"
  assert_grep "a level-one \`# Summary\` fails" "$brief" \
    "ship brief does not reject completion sections at the wrong heading level"
  assert_grep "When a section genuinely does not apply, say so in a sentence under the heading rather than omitting the heading." "$brief" \
    "ship brief permits inapplicable report sections to be omitted"
  assert_grep "data/$id/visuals/" "$brief" "ship brief has no visual evidence path"
  assert_grep "Before the final \`done:\` status" "$brief" "ship brief does not order report publication before done"
  assert_grep "no-mistakes pipeline changes the implementation" "$brief" \
    "ship brief does not require a post-gate report refresh"
  pass "fm-brief.sh: ship tasks require a structured completion report and visuals"
}

test_scout_completion_report_contract() {
  local home id brief
  home="$TMP_ROOT/scout-report-home"
  mkdir -p "$home/data"
  id="brief-scout-report-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "data/$id/report.md" "$brief" "scout brief has no durable report path"
  assert_grep "Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups" "$brief" \
    "scout brief does not name every enforced report section"
  pass "fm-brief.sh: scout tasks receive the enforced completion-report schema"
}

test_promoted_scout_receives_completion_contract() {
  local home data id out expected_report
  home="$TMP_ROOT/promote-report-home"
  data="$TMP_ROOT/promote report data"
  id='promote-report-c3'
  mkdir -p "$home/state" "$data"
  printf 'window=firstmate:fm-%s\nkind=scout\n' "$id" > "$home/state/$id.meta"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-promote.sh" "$id") \
    || fail "scout promotion failed"
  assert_grep 'kind=ship' "$home/state/$id.meta" "scout promotion did not update task kind"
  assert_contains "$out" "Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups" \
    "promoted scout did not receive the ship completion-report schema"
  expected_report="$data/$id/completion.md"
  assert_contains "$out" "$expected_report" "promoted scout did not receive the authoritative completion-report path"
  assert_not_contains "$out" "write data/$id/completion.md" "promoted scout retained a worktree-relative report path"
  pass "fm-promote.sh: promoted scouts receive the ship completion-report contract"
}

test_promote_serializes_with_account_session_updates() {
  local home data state id meta ready release holder promote
  home="$TMP_ROOT/promote-meta-lock-home"
  data="$TMP_ROOT/promote-meta-lock-data"
  state="$home/state"
  id='promote-meta-lock-c4'
  meta="$state/$id.meta"
  ready="$home/holder-ready"
  release="$home/holder-release"
  mkdir -p "$state" "$data"
  printf 'window=firstmate:fm-%s\nkind=scout\n' "$id" > "$meta"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(fm_account_meta_lock_acquire "$2" "$3") || exit 1
    touch "$4"
    while [ ! -f "$5" ]; do sleep 0.05; done
    printf "provider_session_id=session-new\n" >> "$2/$3.meta"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state" "$id" "$ready" "$release" &
  holder=$!
  while [ ! -f "$ready" ]; do sleep 0.05; done
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" "$id" > "$home/promote.out" 2> "$home/promote.err" &
  promote=$!
  sleep 0.1
  assert_grep 'kind=scout' "$meta" "scout promotion bypassed the account metadata lock"
  touch "$release"
  wait "$holder" || fail "promotion account session update lock holder failed"
  wait "$promote" || fail "promotion failed after the account metadata lock was released"
  assert_grep 'provider_session_id=session-new' "$meta" "promotion lost the concurrent provider session update"
  assert_grep 'kind=ship' "$meta" "promotion did not publish after the account metadata lock was released"
  pass "fm-promote.sh: serializes with account session updates"
}

test_promote_locks_lifecycle_before_metadata_and_rechecks_kind() {
  local home data state id meta ready release holder promote
  home="$TMP_ROOT/promote-lifecycle-lock-home"
  data="$TMP_ROOT/promote-lifecycle-lock-data"
  state="$home/state"
  id='promote-lifecycle-lock-c5'
  meta="$state/$id.meta"
  ready="$home/holder-ready"
  release="$home/holder-release"
  mkdir -p "$state" "$data"
  printf 'window=firstmate:fm-%s\nkind=scout\n' "$id" > "$meta"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    lifecycle=$(fm_account_lifecycle_lock_acquire "$2" "$3") || exit 1
    touch "$4"
    while [ ! -f "$5" ]; do sleep 0.05; done
    meta_lock=$(fm_account_meta_lock_acquire "$2" "$3") || exit 1
    sed "s/^kind=scout$/kind=ship/" "$2/$3.meta" > "$2/.$3.meta.test"
    mv "$2/.$3.meta.test" "$2/$3.meta"
    fm_account_meta_lock_release "$meta_lock" || exit 1
    fm_account_lifecycle_lock_release "$lifecycle"
  ' _ "$ROOT" "$state" "$id" "$ready" "$release" &
  holder=$!
  while [ ! -f "$ready" ]; do sleep 0.05; done
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" "$id" > "$home/promote.out" 2> "$home/promote.err" &
  promote=$!
  sleep 0.1
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(fm_account_meta_lock_acquire "$2" "$3") || exit 1
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state" "$id" \
    || { touch "$release"; wait "$holder" 2>/dev/null || true; wait "$promote" 2>/dev/null || true; fail "promotion acquired metadata before the lifecycle lock"; }
  touch "$release"
  wait "$holder" || fail "promotion lifecycle lock holder failed"
  if wait "$promote"; then
    fail "promotion accepted a task whose kind changed while waiting for the lifecycle lock"
  fi
  assert_grep 'kind=ship' "$meta" "promotion overwrote the serialized task generation"
  assert_grep 'not a scout task' "$home/promote.err" "promotion kind recheck failure was unclear"
  assert_absent "$state/.account-lifecycle-$id.lock" "promotion left the lifecycle lock behind"
  assert_absent "$state/.account-meta-$id.lock" "promotion left the metadata lock behind"
  pass "fm-promote.sh: locks lifecycle before metadata and rechecks task kind"
}

test_promote_refuses_pending_rollback_cleanup() {
  local home data state id meta out status
  home="$TMP_ROOT/promote-pending-rollback-home"
  data="$TMP_ROOT/promote-pending-rollback-data"
  state="$home/state"
  id='promote-pending-rollback-c6'
  meta="$state/$id.meta"
  mkdir -p "$state" "$data"
  printf 'window=firstmate:fm-%s\nkind=scout\naccount_rollback_cleanup=pending\n' "$id" > "$meta"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted pending rollback cleanup"
  assert_contains "$out" "rollback cleanup is pending" "pending rollback promotion refusal was unclear"
  assert_grep 'kind=scout' "$meta" "pending rollback promotion changed the task kind"
  assert_absent "$state/.account-lifecycle-$id.lock" "failed promotion left the lifecycle lock behind"
  assert_absent "$state/.account-meta-$id.lock" "failed promotion left the metadata lock behind"
  pass "fm-promote.sh: refuses promotion while rollback cleanup is pending"
}

test_promote_releases_lifecycle_when_metadata_lock_fails() {
  local home data state id meta ready release holder out status
  home="$TMP_ROOT/promote-meta-failure-home"
  data="$TMP_ROOT/promote-meta-failure-data"
  state="$home/state"
  id='promote-meta-failure-c7'
  meta="$state/$id.meta"
  ready="$home/holder-ready"
  release="$home/holder-release"
  mkdir -p "$state" "$data"
  printf 'window=firstmate:fm-%s\nkind=scout\n' "$id" > "$meta"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(fm_account_meta_lock_acquire "$2" "$3") || exit 1
    touch "$4"
    while [ ! -f "$5" ]; do sleep 0.05; done
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state" "$id" "$ready" "$release" &
  holder=$!
  while [ ! -f "$ready" ]; do sleep 0.05; done
  out=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion succeeded despite metadata lock acquisition failure"
  assert_contains "$out" "timed out waiting for account metadata lock" "metadata lock failure was unclear"
  assert_absent "$state/.account-lifecycle-$id.lock" "metadata lock failure leaked the lifecycle lock"
  assert_grep 'kind=scout' "$meta" "metadata lock failure changed the task kind"
  touch "$release"
  wait "$holder" || fail "promotion metadata lock holder failed"
  pass "fm-promote.sh: releases lifecycle ownership when metadata locking fails"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_ship_completion_report_contract
test_scout_completion_report_contract
test_promoted_scout_receives_completion_contract
test_promote_serializes_with_account_session_updates
test_promote_locks_lifecycle_before_metadata_and_rechecks_kind
test_promote_refuses_pending_rollback_cleanup
test_promote_releases_lifecycle_when_metadata_lock_fails
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
