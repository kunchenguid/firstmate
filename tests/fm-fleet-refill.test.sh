#!/usr/bin/env bash
# Public-interface tests for the refill cadence and serialization-debt probe.
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
  pass "serialization debt age boundary is exact"
}

test_malformed_and_unavailable_evidence_fail_loudly() {
  local result rc out
  printf '{bad json\n' > "$TASKS_JSON"
  result=$(run_probe 100000 100); rc=${result%%$'\037'*}; out=${result#*$'\037'}
  expect_code 1 "$rc" "malformed task evidence should require action"
  assert_contains "$out" "SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE" "malformed evidence looked clean"
  out=$(FM_SERIALIZATION_TASK_CLI="$TMP_ROOT/missing-br" "$ROOT/bin/fm-serialization-debt.sh" \
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

test_clean_is_silent
test_branch_and_bead_debt_are_explained
test_exact_age_boundary_is_clean_then_debt
test_malformed_and_unavailable_evidence_fail_loudly
test_refill_cadence_propagates_serialization_debt
