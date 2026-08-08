#!/usr/bin/env bash
# Public-interface tests for the refill cadence and serialization-debt probe,
# including the fleet-depth quarantine (2026-08-08): legacy capacity is
# unknown, no dispatch verdict or staging is ever emitted, and the
# serialization-debt and authoritative bead-query diagnostics remain.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-refill)
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
TASKS_JSON="$TMP_ROOT/tasks.json"
mkdir -p "$PROJECT" "$FAKEBIN"

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
printf '%s\n' base > "$PROJECT/base.txt"
git -C "$PROJECT" add base.txt
git -C "$PROJECT" commit -q -m base

cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
cat "$TASKS_JSON"
SH
chmod +x "$FAKEBIN/br"

# Default clean lane-contract checker: the probe now always invokes the project
# checker, so probe fixtures need a clean one unless a test overrides it.
cat > "$FAKEBIN/lane-checker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/lane-checker"

# Quarantine fixtures: a clean probe and a debt probe for the refill cadence
# under the fleet-depth quarantine.
cat > "$TMP_ROOT/quar-clean-probe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_ROOT/quar-debt-probe" <<'SH'
#!/usr/bin/env bash
echo "SERIALIZATION-DEBT: quarantine fixture"
exit 1
SH
chmod +x "$TMP_ROOT/quar-clean-probe" "$TMP_ROOT/quar-debt-probe"

# --- shadow stage (Task 3): --count-json emits the shared object; shadow
# mode records it while the quarantined verdict stays unchanged -------------
STATE="$TMP_ROOT/shadow-state"
FAKE_CREW="$TMP_ROOT/fake-crew-state.sh"
mkdir -p "$STATE"

write_meta_fixture() {  # <id> <mode> [kind=ship]; kind defaults to ship so the pinned two-arg calls produce a real implementation row
  local id=$1 mode=$2 kind=${3:-ship}
  {
    printf 'window=w-%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'worktree=%s/wt-%s\n' "$TMP_ROOT" "$id"
  } > "$STATE/$id.meta"
}

cat > "$FAKE_CREW" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-crew-state.v1","id":"fixture","state":"working","source":"run-step","detail":"busy"}'
SH
chmod +x "$FAKE_CREW"

epoch_iso() {
  python3 - "$1" <<'PY'
import datetime as dt
import sys
print(dt.datetime.fromtimestamp(int(sys.argv[1]), dt.timezone.utc).isoformat().replace("+00:00", "Z"))
PY
}

run_probe() {
  local now=$1 shift_seconds=$2 out rc
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    FM_LANE_CONTRACT_CHECKER="${FM_LANE_CONTRACT_CHECKER:-$FAKEBIN/lane-checker}" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now "$now" --shift-seconds "$shift_seconds" 2>&1)
  rc=$?
  printf '%s\037%s' "$rc" "$out"
}

make_branch_commit() {
  local branch=$1 epoch=$2 subject=$3 file commit_date
  file=${branch//\//-}.txt
  commit_date=$(epoch_iso "$epoch")
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D "$branch" >/dev/null 2>&1 || true
  git -C "$PROJECT" checkout -q -b "$branch"
  printf '%s\n' "$branch" > "$PROJECT/$file"
  git -C "$PROJECT" add "$file"
  GIT_AUTHOR_DATE="$commit_date" GIT_COMMITTER_DATE="$commit_date" git -C "$PROJECT" commit -q -m "$subject"
  git -C "$PROJECT" checkout -q main
}

# Switch the project checkout to a fresh branch with a controllable transition
# timestamp: GIT_COMMITTER_DATE is what git records in the HEAD reflog entry.
checkout_switch() {
  local branch=$1 epoch=$2
  GIT_COMMITTER_DATE="$(epoch_iso "$epoch")" git -C "$PROJECT" checkout -q -b "$branch"
}

test_clean_is_silent() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  result=$(run_probe 100000 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 0 "$rc" "clean serialization evidence should exit 0"
  [ -z "$out" ] || fail "clean serialization probe was not calm: $out"
  pass "serialization debt probe is silent when clean"
}

test_branch_and_bead_debt_are_explained() {
  local result rc out created
  make_branch_commit fm/tracker-close 99899 "chore: tracker closure"
  make_branch_commit fm/serialization-lane 99899 "chore: serialization lane"
  created=$(epoch_iso 99899)
  printf '[{"id":"dos-op1","description":"ENCODING PROOF REQUIRED: comment with the exact file path.","created_at":"%s","comments":[]}]\n' "$created" > "$TASKS_JSON"
  result=$(run_probe 100000 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "serialization debt should exit 1"
  assert_contains "$out" "branch=fm/tracker-close class=tracker age_seconds=101" "branch debt was not explained"
  assert_contains "$out" "branch=fm/serialization-lane class=serialization age_seconds=101" "serialization branch debt was not explained"
  assert_contains "$out" "bead=dos-op1 class=op-direction-proof age_seconds=101" "bead proof debt was not explained"
  git -C "$PROJECT" branch -D fm/tracker-close >/dev/null
  git -C "$PROJECT" branch -D fm/serialization-lane >/dev/null
  pass "serialization debt probe explains unmerged branch and missing op-direction proof debt"
}

test_exact_age_boundary_is_clean_then_debt() {
  local result rc out created
  make_branch_commit fm/doctrine-boundary 99900 "docs: doctrine boundary"
  created=$(epoch_iso 99900)
  # Literal backticks are task-record fixture content.
  # shellcheck disable=SC2016
  printf '[{"id":"dos-boundary","description":"ENCODING PROOF REQUIRED: comment with the exact file path.","created_at":"%s","comments":[{"text":"Encoded in `AGENTS.md` and `bin/fm-brief.sh`."}]}]\n' "$created" > "$TASKS_JSON"
  result=$(run_probe 100000 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 0 "$rc" "debt must begin strictly after the exact age boundary"
  [ -z "$out" ] || fail "exact age boundary emitted debt: $out"
  result=$(run_probe 100001 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "one second beyond the age boundary should be debt"
  assert_contains "$out" "branch=fm/doctrine-boundary class=doctrine age_seconds=101" "post-boundary debt was not exact"
  git -C "$PROJECT" branch -D fm/doctrine-boundary >/dev/null
  pass "serialization debt age boundary is exact"
}

test_malformed_and_unavailable_evidence_fail_loudly() {
  local result rc out
  printf '{bad json\n' > "$TASKS_JSON"
  result=$(run_probe 100000 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "malformed task evidence should require action"
  assert_contains "$out" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE" "malformed evidence looked clean"
  out=$(FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" FM_SERIALIZATION_TASK_CLI="$TMP_ROOT/missing-br" \
    "$ROOT/bin/fm-serialization-debt.sh" \
    --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 1 "$rc" "unavailable task evidence should require action"
  assert_contains "$out" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE" "unavailable evidence looked clean"
  pass "serialization debt probe distinguishes malformed and unavailable evidence from clean"
}

test_refill_cadence_propagates_serialization_debt() {
  local debt_probe clean_probe out rc
  debt_probe="$TMP_ROOT/debt-probe"
  clean_probe="$TMP_ROOT/clean-probe"
  cat > "$debt_probe" <<'SH'
#!/usr/bin/env bash
echo "SERIALIZATION-DEBT: fixture"
exit 1
SH
  cat > "$clean_probe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$debt_probe" "$clean_probe"
  printf '{"total":0}\n' > "$TASKS_JSON"
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$debt_probe" "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "refill cadence should propagate serialization debt"
  assert_contains "$out" "SERIALIZATION-DEBT: fixture" "refill cadence hid serialization debt"
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$clean_probe" "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "clean serialization evidence should preserve calm refill behavior"
  assert_not_contains "$out" "SERIALIZATION-DEBT" "clean refill cadence emitted serialization debt"
  pass "fleet refill cadence self-surfaces debt and stays calm when clean"
}

test_checkout_on_base_is_clean_even_with_old_transition() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  checkout_switch fm/returned 1700000000
  git -C "$PROJECT" checkout -q main
  result=$(run_probe 1718409700 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 0 "$rc" "base branch checkout should stay clean at any transition age"
  [ -z "$out" ] || fail "base checkout emitted debt: $out"
  git -C "$PROJECT" branch -D fm/returned >/dev/null
  pass "checkout on the configured base branch is clean regardless of transition age"
}

test_checkout_age_boundary_is_exact() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  checkout_switch fm/boundary-checkout 1718409600
  result=$(run_probe 1718409700 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 0 "$rc" "checkout debt must begin strictly after the exact age boundary"
  [ -z "$out" ] || fail "checkout at the exact age boundary emitted debt: $out"
  result=$(run_probe 1718409701 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "one second beyond the boundary should be checkout debt"
  assert_contains "$out" \
    "SERIALIZATION-DEBT: checkout=fm/boundary-checkout class=canonical-checkout age_seconds=101 limit_seconds=100 expected_base=main" \
    "checkout debt line was not explained"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D fm/boundary-checkout >/dev/null
  pass "checkout-state debt age boundary is exact"
}

test_over_age_detached_head_checkout_is_debt() {
  local result rc out head
  printf '[]\n' > "$TASKS_JSON"
  checkout_switch fm/detach-source 1718409600
  head=$(git -C "$PROJECT" rev-parse --short HEAD)
  GIT_COMMITTER_DATE="$(epoch_iso 1718409500)" git -C "$PROJECT" checkout -q "$head"
  result=$(run_probe 1718409700 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "over-age detached checkout should be debt"
  assert_contains "$out" \
    "checkout=detached-head@$head class=canonical-checkout age_seconds=200 limit_seconds=100 expected_base=main" \
    "detached checkout debt was not explained"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D fm/detach-source >/dev/null
  pass "over-age detached HEAD checkout is reported as checkout debt"
}

test_missing_and_truncated_reflog_evidence_fail_loudly() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  checkout_switch fm/no-reflog 1718409600
  rm -f "$PROJECT/.git/logs/HEAD"
  result=$(run_probe 1718409700 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "missing reflog evidence should require action"
  assert_contains "$out" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE" "missing reflog evidence looked clean"
  checkout_switch fm/truncated 1718409600
  git -C "$PROJECT" reflog delete --rewrite 'HEAD@{0}'
  result=$(run_probe 1718409700 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "truncated reflog evidence should require action"
  assert_contains "$out" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE" "truncated reflog evidence looked clean"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D fm/no-reflog fm/truncated >/dev/null
  pass "missing and truncated reflog evidence fail loudly"
}

test_refill_cadence_propagates_checkout_debt() {
  local out rc
  printf '[]\n' > "$TASKS_JSON"
  checkout_switch fm/refill-checkout 1700000000
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$ROOT/bin/fm-serialization-debt.sh" \
    FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "refill cadence should propagate checkout debt"
  assert_contains "$out" "SERIALIZATION-DEBT: checkout=fm/refill-checkout" "refill cadence hid checkout debt"
  git -C "$PROJECT" checkout -q main
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$ROOT/bin/fm-serialization-debt.sh" \
    FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "clean base checkout should preserve calm refill behavior"
  assert_not_contains "$out" "SERIALIZATION-DEBT" "clean refill cadence emitted checkout debt"
  git -C "$PROJECT" branch -D fm/refill-checkout >/dev/null
  pass "fleet refill cadence propagates canonical checkout debt"
}

test_lane_checker_clean_keeps_probe_calm_and_invokes_project() {
  local result rc out invoked
  printf '[]\n' > "$TASKS_JSON"
  cat > "$FAKEBIN/lane-checker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LANE_CHECKER_ARGS_FILE"
exit 0
SH
  chmod +x "$FAKEBIN/lane-checker"
  invoked="$TMP_ROOT/lane-checker-args"
  result=$(TASKS_JSON="$TASKS_JSON" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" LANE_CHECKER_ARGS_FILE="$invoked" \
    FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 0 "$rc" "clean lane contract checker should keep the probe calm"
  [ -z "$result" ] || fail "clean probe emitted output: $result"
  assert_contains "$(cat "$invoked" 2>/dev/null)" "--repo $PROJECT" "probe did not invoke the checker against the project"
  pass "clean lane contract checker keeps the probe calm and runs against the configured project"
}

test_lane_checker_exit_1_violation_surfaces_debt() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  cat > "$FAKEBIN/lane-checker" <<'SH'
#!/usr/bin/env bash
echo "violation A: HEAD is on fm/fixture, off main for 130.0 min (> LANE_CONTRACT_DWELL_MIN=120 min)"
exit 1
SH
  chmod +x "$FAKEBIN/lane-checker"
  result=$(TASKS_JSON="$TASKS_JSON" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 1 "$rc" "checker exit 1 should surface as serialization debt"
  assert_contains "$result" "SERIALIZATION-DEBT: source=lane-contract-checker violation A: HEAD is on fm/fixture" "checker violation was not surfaced as debt"
  pass "lane contract checker exit 1 surfaces its violation line as debt"
}

test_lane_checker_exit_2_cannot_run_surfaces_debt() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  cat > "$FAKEBIN/lane-checker" <<'SH'
#!/usr/bin/env bash
echo "invariant A cannot run: no 'checkout: moving from main to <X>' line in .git/logs/HEAD (rotated reflog)" >&2
exit 2
SH
  chmod +x "$FAKEBIN/lane-checker"
  result=$(TASKS_JSON="$TASKS_JSON" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 1 "$rc" "checker exit 2 should surface as debt"
  assert_contains "$result" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE: source=lane-contract-checker reason=invariant A cannot run: no 'checkout: moving from main to <X>'" "checker cannot-run condition was not surfaced"
  pass "lane contract checker exit 2 surfaces its cannot-run reason as debt"
}

test_unavailable_lane_checker_reports_condition_without_hiding_other_debt() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  make_branch_commit fm/tracker-close 99899 "chore: tracker closure"
  result=$(TASKS_JSON="$TASKS_JSON" FM_LANE_CONTRACT_CHECKER="$TMP_ROOT/missing-lane-checker" FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 1 "$rc" "unavailable lane checker should require action"
  assert_contains "$result" "SERIALIZATION-DEBT: branch=fm/tracker-close class=tracker" "unavailable checker hid the branch debt"
  assert_contains "$result" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE: source=lane-contract-checker reason=checker-cannot-launch:FileNotFoundError:$TMP_ROOT/missing-lane-checker" "unavailable checker did not name the concrete condition"
  git -C "$PROJECT" branch -D fm/tracker-close >/dev/null
  pass "unavailable lane checker names its condition without hiding other debt"
}

test_lane_checker_defaults_to_project_scripts_path() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  mkdir -p "$PROJECT/scripts"
  cat > "$PROJECT/scripts/check_lane_contract.py" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$PROJECT/scripts/check_lane_contract.py"
  result=$(TASKS_JSON="$TASKS_JSON" FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" \
    "$ROOT/bin/fm-serialization-debt.sh" --project "$PROJECT" --now 100000 --shift-seconds 100 2>&1); rc=$?
  expect_code 0 "$rc" "default checker path should resolve under the project"
  [ -z "$result" ] || fail "clean default-checker run emitted output: $result"
  pass "lane checker defaults to <project>/scripts/check_lane_contract.py"
}

test_refill_cadence_propagates_lane_contract_debt() {
  local result rc out
  printf '[]\n' > "$TASKS_JSON"
  cat > "$FAKEBIN/lane-checker" <<'SH'
#!/usr/bin/env bash
echo "violation B: branch fm/fixture holds tracker commit abc123 (130.0 min old) not contained in main"
exit 1
SH
  chmod +x "$FAKEBIN/lane-checker"
  result=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$ROOT/bin/fm-serialization-debt.sh" \
    FM_SERIALIZATION_TASK_CLI="$FAKEBIN/br" FM_LANE_CONTRACT_CHECKER="$FAKEBIN/lane-checker" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "refill cadence should propagate lane contract checker debt"
  assert_contains "$result" "source=lane-contract-checker violation B: branch fm/fixture" "refill cadence hid lane contract checker debt"
  pass "fleet refill cadence self-surfaces lane contract checker debt"
}

test_clean_is_silent
test_branch_and_bead_debt_are_explained
test_exact_age_boundary_is_clean_then_debt
test_malformed_and_unavailable_evidence_fail_loudly
test_refill_cadence_propagates_serialization_debt
test_checkout_on_base_is_clean_even_with_old_transition
test_checkout_age_boundary_is_exact
test_over_age_detached_head_checkout_is_debt
test_missing_and_truncated_reflog_evidence_fail_loudly
test_refill_cadence_propagates_checkout_debt
test_lane_checker_clean_keeps_probe_calm_and_invokes_project
test_lane_checker_exit_1_violation_surfaces_debt
test_lane_checker_exit_2_cannot_run_surfaces_debt
test_unavailable_lane_checker_reports_condition_without_hiding_other_debt
# --- fleet-depth quarantine and Task 13 cutover (2026-08-08) --------------
# Legacy capacity arithmetic is gone: no owned-manifest/mtime counters, no
# DISPATCH-NEEDED verdict, no next-wave staging. After the Task 13 cutover the
# human verdict derives solely from the shared capacity projection
# (fm-fleet-capacity.v1); the serialization-debt and authoritative bead-query
# diagnostics remain.

test_cutover_verdict_derives_from_shared_projection() {
  # even with abundant open beads (the old dispatch condition would fire), the
  # cut-over script derives its verdict from the shared projection and never
  # dispatches
  local out rc
  printf '{"total":50}\n' > "$TASKS_JSON"
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$FAKE_CREW" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$TMP_ROOT/quar-clean-probe" "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "cut-over refill should stay calm with a clean probe"
  assert_contains "$out" "productive=" "verdict does not derive from the shared projection"
  assert_contains "$out" "refill_safe=" "verdict lacks the shared refill-safety flag"
  assert_contains "$out" "open_beads=50" "authoritative bead-query diagnostic missing"
  assert_not_contains "$out" "DISPATCH-NEEDED" "cut-over refill emitted a dispatch verdict"
  assert_not_contains "$out" "NEXT-WAVE" "cut-over refill staged work"
  assert_not_contains "$out" "active=" "legacy active counter survived the cutover"
  assert_not_contains "$out" "battery=" "legacy battery counter survived the cutover"
  pass "the cut-over verdict derives from the shared projection and never dispatches"
}

test_cutover_ignores_legacy_manifest_and_output_mtimes() {
  # a legacy manifest and fresh-looking output files must not influence the
  # cut-over verdict: the shared projection drives it, the verdict stays calm
  local out rc
  mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/output-tasks"
  printf 'legacy-task-1 legacy-task-2\n' > "$TMP_ROOT/state/fleet-manifest.jsonl"
  : > "$TMP_ROOT/output-tasks/legacy-task-1.output"
  printf '{"total":3}\n' > "$TASKS_JSON"
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$FAKE_CREW" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$TMP_ROOT/quar-clean-probe" "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "legacy manifest presence should not dispatch"
  assert_contains "$out" "productive=" "manifest influenced the cut-over verdict"
  assert_not_contains "$out" "DISPATCH-NEEDED" "manifest triggered a dispatch verdict"
  pass "legacy manifests and output mtimes never influence the cut-over verdict"
}

test_cutover_still_propagates_serialization_debt() {
  # the serialization-debt safety diagnostic remains authoritative after the
  # cutover: debt still surfaces and still fails the cadence
  local out rc
  printf '{"total":0}\n' > "$TASKS_JSON"
  out=$(PATH="$FAKEBIN:$PATH" TASKS_JSON="$TASKS_JSON" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$FAKE_CREW" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$TMP_ROOT/quar-debt-probe" "$ROOT/bin/fm-fleet-refill.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "serialization debt must still surface after cutover"
  assert_contains "$out" "SERIALIZATION-DEBT: quarantine fixture" "debt diagnostic lost after cutover"
  pass "serialization-debt diagnostic remains after the cutover"
}

test_count_json_emits_shared_object() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_REFILL_PROJECT="$PROJECT" FM_SERIALIZATION_DEBT_PROBE="$TMP_ROOT/quar-clean-probe" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema"
  pass "fleet refill --count-json emits the shared capacity object"
}

test_cutover_verdict_is_unchanged_in_shadow_mode() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_REFILL_PROJECT="$PROJECT" FM_SERIALIZATION_DEBT_PROBE="$TMP_ROOT/quar-clean-probe" \
    FM_REFILL_SHADOW="$TMP_ROOT/shadow.json" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1)
  assert_contains "$out" "fleet-refill:" "cut-over summary line missing"
  assert_contains "$out" "productive=" "shadow mode changed the cut-over verdict"
  assert_not_contains "$out" "DISPATCH-NEEDED" "shadow mode emitted a dispatch verdict"
  [ -f "$TMP_ROOT/shadow.json" ] || fail "shadow object not recorded"
  jq -e '.schema == "fm-fleet-capacity.v1"' "$TMP_ROOT/shadow.json" >/dev/null || fail "shadow not capacity object"
  pass "shadow mode records the object while the cut-over verdict stays authoritative"
}

test_frozen_observation_parity() {
  # one frozen observation drives every consumer; rows/aggregates compare
  # byte-identically without timing dependence
  local frozen refill
  write_meta_fixture ship direct-PR
  frozen="$TMP_ROOT/frozen.json"
  FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null > "$frozen"
  jq -e '.schema == "fm-fleet-capacity.v1"' "$frozen" >/dev/null || fail "frozen file is not the capacity object"
  refill=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_CAPACITY_OBSERVATION_FILE="$frozen" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$refill" | jq -c '.rows')" = "$(jq -c '.rows' "$frozen")" ] \
    || fail "frozen observation rows differ"
  [ "$(echo "$refill" | jq -c '.aggregate')" = "$(jq -c '.aggregate' "$frozen")" ] \
    || fail "frozen observation aggregate differs"
  pass "one frozen observation gives deterministic rows and aggregates across consumers"
}

# --- Task 15: deletion and alert-only rollback (2026-08-08) --------------
# The legacy arithmetic is already gone post-quarantine/cutover; these
# fixtures pin that a legacy manifest and output mtimes never become fallback
# arithmetic, that the rollback flip keeps --refill alert-only without
# touching any attempt/bead/branch/ref/copy/receipt record, and that missing
# evidence never converts into zero capacity.

test_legacy_manifest_and_output_mtimes_never_fallback() {
  # a state/fleet-manifest.jsonl with fresh mtimes and a fake output file with
  # a fresh mtime must be ignored completely by the cut-over projection
  local id out
  id=legacy-m
  printf '%s\n' "$id" > "$STATE/fleet-manifest.jsonl"
  mkdir -p "$TMP_ROOT/output-tasks"
  : > "$TMP_ROOT/output-tasks/$id.output"
  printf 'kind=ship\nmode=direct-PR\n' > "$STATE/$id.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  assert_not_contains "$out" "manifest" "legacy manifest leaked into capacity"
  pass "legacy manifests and output mtimes never become fallback arithmetic"
}

test_rollback_is_alert_only_and_preserves_everything() {
  # with config/refill-auto absent and FM_REFILL_AUTO != 1, --refill must not
  # dispatch; attempts, beads, branches, refs, copies, and receipts are
  # untouched (byte-compare the state dir). A fresh empty state keeps the
  # projection complete so the rollback flip itself is what is exercised.
  local state cand before after out
  state="$TMP_ROOT/rollback-state"
  cand="$TMP_ROOT/rollback-candidates.json"
  mkdir -p "$state"
  printf '[{"id":"dos-rb","planned_path":"docs/"}]' > "$cand"
  before=$(find "$state" -type f -exec sha256sum {} + | sort)
  out=$(FM_STATE_OVERRIDE="$state" FM_REFILL_AUTO=0 FM_REFILL_CANDIDATES_FILE="$cand" \
    FM_CREW_STATE_BIN="$FAKE_CREW" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "fleet-ok" "rollback mode did not stay alert-only"
  assert_not_contains "$out" "launch " "rollback mode dispatched"
  after=$(find "$state" -type f -exec sha256sum {} + | sort)
  [ "$before" = "$after" ] || fail "rollback mutated the state dir"
  pass "rollback disables automatic dispatch and preserves every attempt record"
}

test_rollback_never_restores_legacy_arithmetic() {
  # missing evidence yields ambiguous/incomplete rows, never zero capacity
  local out
  printf 'kind=ship\nmode=direct-PR\n' > "$STATE/legacy-r.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKE_CREW" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null \
    || fail "rollback invented capacity"
  pass "rollback never converts missing evidence into zero capacity"
}

test_lane_checker_defaults_to_project_scripts_path
test_refill_cadence_propagates_lane_contract_debt
test_cutover_verdict_derives_from_shared_projection
test_cutover_ignores_legacy_manifest_and_output_mtimes
test_cutover_still_propagates_serialization_debt
test_count_json_emits_shared_object
test_cutover_verdict_is_unchanged_in_shadow_mode
test_frozen_observation_parity
test_legacy_manifest_and_output_mtimes_never_fallback
test_rollback_is_alert_only_and_preserves_everything
test_rollback_never_restores_legacy_arithmetic
