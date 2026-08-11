#!/usr/bin/env bash
# Behavior tests for the strict opt-in Fast Repair intake, evidence, and
# post-publication readiness gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAST="$ROOT/bin/fm-fast-repair.sh"
TMP_ROOT=$(fm_test_tmproot fm-fast-repair)
REGRESSION_TEST=fixture-regression
FOCUSED_TEST=fixture-focused
BROADER_TEST=fixture-broader
FAKE_GH_BIN=
FAKE_GH_DIR=

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_git_init_commit "$home"
  write_test_runner "$home"
  printf 'broken\n' > "$home/fixture-regression-state"
  printf 'passed\n' > "$home/fixture-focused-state"
  printf 'passed\n' > "$home/fixture-broader-state"
  commit_test_file "$home" fixture-regression-state
  commit_test_file "$home" fixture-focused-state
  commit_test_file "$home" fixture-broader-state
  printf '%s\n' "$home"
}

run_fast() {
  local home=$1
  shift
  ( cd "$home" && FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$FAST" "$@" ) 2>&1
}

run_fast_from() {
  local cwd=$1 home=$2
  shift 2
  ( cd "$cwd" && FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$FAST" "$@" ) 2>&1
}

commit_test_file() {
  local home=$1 file=$2
  git -C "$home" add -- "$file"
  git -C "$home" commit --quiet --only -m "add Fast Repair test" -- "$file"
}

write_regression_test() {
  local home=$1 code=${2:-0}
  mkdir -p "$home/tests"
  if ! git -C "$home" cat-file -e HEAD:tests/fixture-regression.test.sh 2>/dev/null; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/fixture-regression.test.sh"
    chmod +x "$home/tests/fixture-regression.test.sh"
    commit_test_file "$home" tests/fixture-regression.test.sh
  fi
  if [ "$code" = 0 ]; then printf 'fixed\n' > "$home/fixture-regression-state"; else printf 'broken\n' > "$home/fixture-regression-state"; fi
  git -C "$home" diff --quiet -- fixture-regression-state || commit_test_file "$home" fixture-regression-state
}

write_focused_test() {
  local home=$1 code=${2:-0}
  mkdir -p "$home/tests"
  if ! git -C "$home" cat-file -e HEAD:tests/fixture-focused.test.sh 2>/dev/null; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/fixture-focused.test.sh"
    chmod +x "$home/tests/fixture-focused.test.sh"
    commit_test_file "$home" tests/fixture-focused.test.sh
  fi
  if [ "$code" = 0 ]; then printf 'passed\n' > "$home/fixture-focused-state"; else printf 'failed\n' > "$home/fixture-focused-state"; fi
  git -C "$home" diff --quiet -- fixture-focused-state || commit_test_file "$home" fixture-focused-state
}

write_test_runner() {
  local home=$1
  mkdir -p "$home/bin"
  # shellcheck disable=SC2016 # Literal fixture code expands only when its generated script runs.
  printf '%s\n' '#!/usr/bin/env bash' 'set -eu' \
    'if [ -n "${FM_FIXTURE_RUN_BLOCK:-}" ] && [ "${1:-}" != --list-families ] && [ "${1:-}" != --list ]; then : > "$FM_FIXTURE_RUN_BLOCK.started"; while [ -e "$FM_FIXTURE_RUN_BLOCK" ]; do sleep 0.05; done; fi' \
    'if [ "${1:-}" = --list-families ]; then printf "%s\n" fixture-regression fixture-focused fixture-broader; exit 0; fi' \
    'if [ "${1:-}" = --list ] && [ "${2:-}" = --family ]; then case "$3" in fixture-regression) printf "%s\n" tests/fixture-regression.test.sh ;; fixture-focused) printf "%s\n" tests/fixture-focused.test.sh ;; fixture-broader) printf "%s\n" tests/fixture-broader.test.sh ;; *) exit 2 ;; esac; exit 0; fi' \
    'if [ "${1:-}" = --family ] && [ "$#" = 2 ]; then family=$2; elif [ "$#" = 1 ]; then case "$1" in tests/fixture-regression.test.sh) family=fixture-regression ;; tests/fixture-focused.test.sh) family=fixture-focused ;; tests/fixture-broader.test.sh) family=fixture-broader ;; *) exit 2 ;; esac; else exit 2; fi' \
    'printf "FM_TEST_BEGIN fixture %s family=%s\n" "$family" "$family"' \
    'if case "$family" in fixture-regression) [ "$(cat fixture-regression-state)" = fixed ] ;; fixture-focused) [ "$(cat fixture-focused-state)" = passed ] ;; fixture-broader) [ "$(cat fixture-broader-state)" = passed ] ;; *) false ;; esac; then status=0; else status=1; fi' \
    'printf "FM_TEST_END fixture %s exit=%s duration_ms=0 gate_skip=false\n" "$family" "$status"; exit "$status"' > "$home/bin/fm-test-run.sh"
  chmod +x "$home/bin/fm-test-run.sh"
  commit_test_file "$home" bin/fm-test-run.sh
}

write_broader_test() {
  local home=$1 code=${2:-0}
  mkdir -p "$home/tests"
  if ! git -C "$home" cat-file -e HEAD:tests/fixture-broader.test.sh 2>/dev/null; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/fixture-broader.test.sh"
    chmod +x "$home/tests/fixture-broader.test.sh"
    commit_test_file "$home" tests/fixture-broader.test.sh
  fi
  if [ "$code" = 0 ]; then printf 'passed\n' > "$home/fixture-broader-state"; else printf 'failed\n' > "$home/fixture-broader-state"; fi
  git -C "$home" diff --quiet -- fixture-broader-state || commit_test_file "$home" fixture-broader-state
}

intake() {
  local home=$1 id=$2 reproduction=${3-reproduced} root_cause=${4-confirmed} isolation=${5-isolated}
  local schema=${6-none} authentication=${7-none} authorization=${8-none} secrets=${9-none} financial=${10-none} legal=${11-none} side_effects=${12-none}
  run_fast "$home" intake "$id" --request 'fast-repair: repair fixture' \
    --reproduction "$reproduction" --reproduction-revision "$(git -C "$home" rev-parse HEAD)" --root-cause "$root_cause" --isolation "$isolation" \
    --schema "$schema" --authentication "$authentication" --authorization "$authorization" \
    --secrets "$secrets" --financial "$financial" --legal "$legal" --side-effects "$side_effects"
}

# The fake reproduces the real `gh-axi pr checks` contract: one TOON `summary:`
# field whose comma-bearing value is double-quoted, and the distinct
# no-checks-configured shape that carries no summary field at all. Every argv is
# recorded so the repository the checks were read from is observable.
write_fake_gh() {
  local fakebin
  fakebin=$(mktemp -d "$TMP_ROOT/fake-gh-bin.XXXXXX")
  FAKE_GH_DIR=$(mktemp -d "$TMP_ROOT/fake-gh-data.XXXXXX")
  FAKE_GH_BIN=$fakebin
  cat > "$fakebin/gh-axi" <<EOF
#!/usr/bin/env bash
FAKE_HOME='$FAKE_GH_DIR'
EOF
  cat >> "$fakebin/gh-axi" <<'SH'
printf '%s\n' "$*" >> "$FAKE_HOME/gh-axi.args"
pwd >> "$FAKE_HOME/gh-axi.cwd"
case "${1:-}" in
  pr)
    case "${2:-}" in
      create) printf 'https://github.com/acme/repo/pull/42\n' ;;
      checks) cat "$FAKE_HOME/checks-output" ;;
    esac
    ;;
esac
SH
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
FAKE_HOME='$FAKE_GH_DIR'
EOF
  cat >> "$fakebin/gh" <<'SH'
case "${1:-} ${2:-}" in
  "pr view") cat "$FAKE_HOME/pr-head" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
}

set_rollup() { # <fake-gh-dir> <summary text>
  printf 'summary: "%s"\n' "$2" > "$1/checks-output"
}

set_no_checks_rollup() { # <fake-gh-dir>
  printf 'checks: "0 passed, 0 failed — this PR has no CI checks configured"\n' > "$1/checks-output"
}

write_fast_meta() {
  local home=$1 id=$2 pr=${3:-} wt=${4:-$1}
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=ship\nmode=fast-repair\nyolo=off\nfast_repair=eligible\nworktree=%s\n' "$wt"
    if [ -n "$pr" ]; then
      printf 'pr=%s\n' "$pr"
      printf 'pr_head=%s\n' "$(git -C "$home" rev-parse HEAD)"
    fi
  } > "$home/state/$id.meta"
}

test_exact_prefix_only() {
  local request
  for request in 'fast-repair: fix fixture' 'fast-repair: a'; do
    "$FAST" is-request "$request" || fail "exact Fast Repair prefix was not recognized: $request"
  done
  for request in 'fast-repair:' 'fast-repair: ' $'fast-repair: \t' 'Fast-repair: fix' 'fast repair: fix' 'fast-repair : fix' 'xfast-repair: fix'; do
    "$FAST" is-request "$request" && fail "near-match activated Fast Repair: $request"
  done
  pass "Fast Repair recognizes only the exact fast-repair: prefix"
}

test_eligibility_requires_every_typed_fact() {
  local home out status field id=eligible-all
  home=$(make_home eligibility)
  out=$(intake "$home" "$id")
  assert_contains "$out" "fast-repair eligible: $id" "complete typed eligibility did not pass"
  run_fast "$home" eligible "$id" >/dev/null || fail "stored complete eligibility did not validate"

  for id in . ..; do
    out=$(intake "$home" "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "a dot task id escaped the Fast Repair task directory: $id"
  done
  [ ! -e "$home/data/fast-repair-eligibility" ] || fail "the dot task id wrote outside its task directory"
  [ ! -e "$home/fast-repair-eligibility" ] || fail "the dot-dot task id wrote outside the data directory"
  write_fast_meta "$home" eligible-all
  for id in ../outside ../../outside; do
    out=$(run_fast "$home" progress "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "progress accepted an escaping task id: $id"
    out=$(run_fast "$home" ready "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "ready accepted an escaping task id: $id"
  done

  out=$(intake "$home" invalid-reproduction a confirmed isolated)
  status=$?
  [ "$status" -ne 0 ] || fail "an untyped reproduction proof was accepted"
  out=$(intake "$home" invalid-root-cause reproduced a isolated)
  status=$?
  [ "$status" -ne 0 ] || fail "an untyped root-cause proof was accepted"
  out=$(intake "$home" invalid-isolation reproduced confirmed a)
  status=$?
  [ "$status" -ne 0 ] || fail "an untyped isolation proof was accepted"

  for field in reproduction root_cause isolation; do
    id="missing-$field"
    case "$field" in
      reproduction) out=$(intake "$home" "$id" '' confirmed isolated) ;;
      root_cause) out=$(intake "$home" "$id" reproduced '' isolated) ;;
      isolation) out=$(intake "$home" "$id" reproduced confirmed '') ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "missing $field was accepted"
    assert_contains "$out" "$field" "missing $field did not name its refusal"

    id="unknown-$field"
    case "$field" in
      reproduction) out=$(intake "$home" "$id" unknown confirmed isolated) ;;
      root_cause) out=$(intake "$home" "$id" reproduced unknown isolated) ;;
      isolation) out=$(intake "$home" "$id" reproduced confirmed ambiguous) ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "unknown or ambiguous $field was accepted"
    assert_contains "$out" "$field" "unknown $field did not name its refusal"
  done

  for field in schema authentication authorization secrets financial legal side_effects; do
    id="risk-$field"
    case "$field" in
      schema) out=$(intake "$home" "$id" reproduced confirmed isolated changed) ;;
      authentication) out=$(intake "$home" "$id" reproduced confirmed isolated none changed) ;;
      authorization) out=$(intake "$home" "$id" reproduced confirmed isolated none none changed) ;;
      secrets) out=$(intake "$home" "$id" reproduced confirmed isolated none none none changed) ;;
      financial) out=$(intake "$home" "$id" reproduced confirmed isolated none none none none changed) ;;
      legal) out=$(intake "$home" "$id" reproduced confirmed isolated none none none none none changed) ;;
      side_effects) out=$(intake "$home" "$id" reproduced confirmed isolated none none none none none none changed) ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "forbidden $field change was accepted"
    assert_contains "$out" "$field" "forbidden $field did not name its refusal"
  done
  pass "Fast Repair accepts only complete positive evidence and explicit no-risk exclusions"
}

test_evidence_and_ready_gates() {
  local home id=gate-fixture out status fakebin outside branch other evidence_other
  home=$(make_home gates)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  write_regression_test "$home" 1
  write_focused_test "$home"
  write_broader_test "$home"

  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "failed regression evidence allowed publication"
  assert_contains "$out" "PR publication remains blocked" "failed evidence did not explain the publication block"

  out=$(run_fast "$home" evidence "$id" --regression-command true --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "an arbitrary successful regression command was accepted"
  mkdir -p "$home/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/pass.sh"
  chmod +x "$home/tests/pass.sh"
  commit_test_file "$home" tests/pass.sh
  out=$(run_fast "$home" evidence "$id" --regression-test pass --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a generic exit-zero script satisfied regression evidence"
  assert_contains "$out" 'one new tracked runner selector' "the pass-script refusal did not require a runner-owned selector"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$home/untracked-test-ran" > "$home/tests/fm-untracked-regression.test.sh"
  chmod +x "$home/tests/fm-untracked-regression.test.sh"
  out=$(run_fast "$home" evidence "$id" --regression-test tests/fm-untracked-regression.test.sh --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "an untracked regression test was accepted"
  [ ! -e "$home/untracked-test-ran" ] || fail "an untracked regression test was executed"
  git -C "$home" add -- tests/fm-untracked-regression.test.sh
  out=$(run_fast "$home" evidence "$id" --regression-test tests/fm-untracked-regression.test.sh --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a staged-only regression test was accepted"
  [ ! -e "$home/untracked-test-ran" ] || fail "a staged-only regression test was executed"
  git -C "$home" rm --cached --quiet -- tests/fm-untracked-regression.test.sh
  rm -f "$home/tests/fm-untracked-regression.test.sh"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$home/modified-test-ran" > "$home/$REGRESSION_TEST"
  chmod +x "$home/$REGRESSION_TEST"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a modified tracked regression test was accepted"
  [ ! -e "$home/modified-test-ran" ] || fail "a modified tracked regression test was executed"
  rm -f "$home/$REGRESSION_TEST"
  git -C "$home" checkout -- tests/fixture-regression.test.sh
  write_regression_test "$home"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-command true)
  status=$?
  [ "$status" -ne 0 ] || fail "an arbitrary successful focused command was accepted"
  outside="$TMP_ROOT/escaped-focused-test"
  mkdir -p "$outside" "$home/tests"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$home/escaped-test-ran" > "$outside/fm-escaped-regression.test.sh"
  chmod +x "$outside/fm-escaped-regression.test.sh"
  ln -s "$outside" "$home/tests/link"
  out=$(run_fast "$home" evidence "$id" --regression-test tests/link/fm-escaped-regression.test.sh --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a parent symlink escaped the Fast Repair worktree"
  [ ! -e "$home/escaped-test-ran" ] || fail "an escaped test path was executed"
  rm -f "$home/tests/link"
  write_focused_test "$home" 1
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a failing focused test allowed publication"
  assert_contains "$out" "PR publication remains blocked" "failed focused evidence did not explain the publication block"
  write_focused_test "$home"
  printf 'task worktree\n' > "$home/cwd-proof"
  commit_test_file "$home" cwd-proof
  # shellcheck disable=SC2016 # Literal fixture code expands only when its generated script runs.
  printf '#!/usr/bin/env bash\n[ "$(cat cwd-proof)" = "task worktree" ]\n' > "$home/$REGRESSION_TEST"
  chmod +x "$home/$REGRESSION_TEST"
  commit_test_file "$home" "$REGRESSION_TEST"
  # shellcheck disable=SC2016 # Literal fixture code expands only when its generated script runs.
  printf '#!/usr/bin/env bash\n[ "$(cat cwd-proof)" = "task worktree" ]\n' > "$home/$FOCUSED_TEST"
  chmod +x "$home/$FOCUSED_TEST"
  commit_test_file "$home" "$FOCUSED_TEST"
  evidence_other=$(make_home evidence-cwd)
  printf 'other checkout\n' > "$evidence_other/cwd-proof"
  out=$(run_fast_from "$evidence_other" "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -eq 0 ] || fail "evidence tests did not run from the task worktree: $out"
  run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" >/dev/null || fail "passing focused evidence was rejected"
  git -C "$home" commit --quiet --allow-empty -m 'advance repair fixture'
  body="$TMP_ROOT/gates-body.md"
  printf 'Fast Repair fixture body.\n' > "$body"
  out=$(run_fast "$home" publish-pr "$id" --title 'Fast Repair fixture' --body-file "$body")
  status=$?
  [ "$status" -ne 0 ] || fail "Fast Repair published a commit that its evidence did not test"
  assert_contains "$out" 'focused evidence is absent or failed' "untested commit refusal was not actionable"
  run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" >/dev/null || fail "updated task HEAD evidence was rejected"
  write_fake_gh "$home"
  fakebin="$FAKE_GH_BIN"
  printf '%040d\n' 0 > "$FAKE_GH_DIR/pr-head"
  # The real green rollup omits the pending segment when nothing is pending.
  set_rollup "$FAKE_GH_DIR" '4 passed, 0 failed, 4 total'
  out=$(PATH="$fakebin:$PATH" run_fast "$home" publish-pr "$id" --title 'Fast Repair fixture' --body-file "$body" --head unrelated)
  status=$?
  [ "$status" -ne 0 ] || fail "Fast Repair published an untested head branch"
  assert_contains "$out" '--head must equal the tested task branch' "untested head refusal was not actionable"
  assert_no_grep 'pr=' "$home/state/$id.meta" "untested head publication wrote a PR record"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" publish-pr "$id" --title 'Fast Repair fixture' --body-file "$body")
  status=$?
  [ "$status" -ne 0 ] || fail "Fast Repair accepted a PR with an untested remote head"
  assert_contains "$out" 'registered PR head does not match' "remote-head refusal was not actionable"
  printf '%s\n' "$(git -C "$home" rev-parse HEAD)" > "$FAKE_GH_DIR/pr-head"
  other=$(make_home other-caller)
  printf 'Fast Repair caller body.\n' > "$other/body.md"
  out=$(PATH="$fakebin:$PATH" run_fast_from "$other" "$home" publish-pr "$id" --title 'Fast Repair fixture' --body-file body.md)
  assert_contains "$out" 'fast-repair PR opened: https://github.com/acme/repo/pull/42' "passing evidence did not open the direct PR"
  assert_grep 'pr=https://github.com/acme/repo/pull/42' "$home/state/$id.meta" "direct PR was not registered"
  branch=$(git -C "$home" symbolic-ref --short HEAD)
  assert_grep "pr create --title Fast Repair fixture --body-file $other/body.md --head $branch" "$FAKE_GH_DIR/gh-axi.args" \
    "direct PR did not use the tested task branch"
  [ "$(tail -n 1 "$FAKE_GH_DIR/gh-axi.cwd")" = "$home" ] \
    || fail "direct PR creation ran outside the task worktree"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" broader "$id" --command true)
  status=$?
  [ "$status" -ne 0 ] || fail "an arbitrary successful broader command was accepted"
  assert_contains "$out" 'broader requires exactly --test' "broader command refusal was not actionable"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" broader "$id" --test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "re-running the focused family satisfied the broader gate"
  assert_contains "$out" 'not the focused family' "the same-family broader refusal was not actionable"
  [ ! -e "$home/state/$id.fast-repair-broader" ] || fail "a refused broader family still wrote a broader record"
  PATH="$fakebin:$PATH" run_fast "$home" broader "$id" --test "$BROADER_TEST" >/dev/null || fail "broader tests could not start after direct PR publication"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  assert_contains "$out" 'fast-repair ready: https://github.com/acme/repo/pull/42' "green broader and PR evidence did not make the PR ready"
  printf '%040d\n' 0 > "$FAKE_GH_DIR/pr-head"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "Fast Repair accepted a PR whose remote head changed after publication"
  assert_contains "$out" 'registered PR head does not match' "changed remote-head refusal was not actionable"
  printf '%s\n' "$(git -C "$home" rev-parse HEAD)" > "$FAKE_GH_DIR/pr-head"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  assert_contains "$out" 'pr-checks-green' "green PR checks were not available to the Fast Repair progress cadence"
  assert_grep '--repo acme/repo' "$FAKE_GH_DIR/gh-axi.args" "PR checks were not read from the registered PR's own repository"
  git -C "$home" commit --quiet --allow-empty -m 'advance broader fixture'
  run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" >/dev/null \
    || fail "updated focused evidence was rejected after a new commit"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "Fast Repair accepted broader evidence from an earlier commit"
  assert_contains "$out" 'broader tests are not passed' "stale broader evidence was not refused"
  pass "Fast Repair blocks failed focused evidence and requires broader plus PR checks before ready"
}

test_regression_selector_must_be_new_since_reproduction() {
  local home id=old-selector out status
  home=$(make_home old-selector)
  intake "$home" "$id" >/dev/null
  write_focused_test "$home"
  write_regression_test "$home"
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  git -C "$home" commit --quiet --allow-empty -m 'repair head after selector'
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a regression selector already present at reproduction was accepted"
  assert_contains "$out" 'one new tracked runner selector' "an old regression selector did not state the Fast Repair contract"
  pass "Fast Repair requires a runner-owned regression selector added after reproduction"
}

test_regression_witness_requires_a_failing_reproduction() {
  local home id=unrelated-witness out status
  home=$(make_home unrelated-witness)
  intake "$home" "$id" >/dev/null
  mkdir -p "$home/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/fixture-unrelated.test.sh"
  chmod +x "$home/tests/fixture-unrelated.test.sh"
  commit_test_file "$home" tests/fixture-unrelated.test.sh
  sed -i 's/fixture-regression fixture-focused/fixture-regression fixture-focused fixture-unrelated/' "$home/bin/fm-test-run.sh"
  sed -i 's/fixture-focused) printf "%s\\n" tests\/fixture-focused.test.sh ;;/fixture-focused) printf "%s\\n" tests\/fixture-focused.test.sh ;; fixture-unrelated) printf "%s\\n" tests\/fixture-unrelated.test.sh ;;/' "$home/bin/fm-test-run.sh"
  sed -i 's/tests\/fixture-focused.test.sh) family=fixture-focused ;;/tests\/fixture-focused.test.sh) family=fixture-focused ;; tests\/fixture-unrelated.test.sh) family=fixture-unrelated ;;/' "$home/bin/fm-test-run.sh"
  # shellcheck disable=SC2016 # Literal fixture text must keep its generated command substitution.
  sed -i 's/fixture-focused) \[ "$(cat fixture-focused-state)" = passed \] ;;/fixture-focused) [ "$(cat fixture-focused-state)" = passed ] ;; fixture-unrelated) true ;;/' "$home/bin/fm-test-run.sh"
  commit_test_file "$home" bin/fm-test-run.sh
  write_focused_test "$home"
  write_fast_meta "$home" "$id"
  out=$(run_fast "$home" evidence "$id" --regression-test fixture-unrelated --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "an unrelated passing selector proved reproduction evidence"
  assert_contains "$out" 'PR publication remains blocked' "an unrelated passing selector did not block publication"
  pass "Fast Repair requires the overlaid regression selector to fail before the repair"
}

test_regression_witness_uses_the_tested_runner() {
  local home id=unsupported-overlay out status
  home=$(make_home unsupported-overlay)
  sed -i 's/if \[ "${1:-}" = --list \].*/if [ "${1:-}" = --list ]; then exit 2; fi/' "$home/bin/fm-test-run.sh"
  commit_test_file "$home" bin/fm-test-run.sh
  intake "$home" "$id" >/dev/null
  write_test_runner "$home"
  write_regression_test "$home"
  write_focused_test "$home"
  write_fast_meta "$home" "$id"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -eq 0 ] || fail "the tested runner could not execute the reproduction overlay: $out"
  assert_grep 'regression_runner=100755:' "$home/state/$id.fast-repair-tests" \
    "the evidence record did not bind the tested runner artifact"
  pass "Fast Repair uses one tested runner for both regression witness halves"
}

test_evidence_requires_clean_bound_artifacts() {
  local home id=dirty-source out status outside
  home=$(make_home dirty-source)
  intake "$home" "$id" >/dev/null
  write_regression_test "$home"
  write_focused_test "$home"
  printf 'broken\n' > "$home/fixture-regression-state"
  commit_test_file "$home" fixture-regression-state
  write_fast_meta "$home" "$id"
  printf 'fixed\n' > "$home/fixture-regression-state"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "dirty repair source satisfied evidence for an older HEAD"
  assert_contains "$out" 'no safe git worktree' "dirty source refusal was not actionable"
  git -C "$home" checkout -- fixture-regression-state

  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/tests/fixture-focused.test.sh"
  chmod +x "$home/tests/fixture-focused.test.sh"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a modified focused artifact satisfied evidence"
  git -C "$home" checkout -- tests/fixture-focused.test.sh

  outside="$TMP_ROOT/focused-artifact-outside"
  mkdir -p "$outside"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$outside/fixture-focused.test.sh"
  chmod +x "$outside/fixture-focused.test.sh"
  rm -f "$home/tests/fixture-focused.test.sh"
  ln -s "$outside/fixture-focused.test.sh" "$home/tests/fixture-focused.test.sh"
  git -C "$home" add -- tests/fixture-focused.test.sh
  git -C "$home" commit --quiet -m 'replace focused artifact with symlink'
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a symlinked focused artifact satisfied evidence"
  assert_contains "$out" 'focused-test must name a supported' "symlinked focused artifact refusal was not actionable"
  pass "Fast Repair binds evidence to clean tracked focused artifacts"
}

test_pr_check_rollup_states() {
  local home id=rollup-fixture fakebin out status
  home=$(make_home rollup)
  intake "$home" "$id" >/dev/null
  write_regression_test "$home"
  write_focused_test "$home"
  write_broader_test "$home"
  write_fast_meta "$home" "$id" https://github.com/acme/repo/pull/42
  write_fake_gh "$home"
  fakebin="$FAKE_GH_BIN"
  printf '%s\n' "$(git -C "$home" rev-parse HEAD)" > "$FAKE_GH_DIR/pr-head"
  run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" >/dev/null \
    || fail "focused evidence fixture was rejected"
  PATH="$fakebin:$PATH" run_fast "$home" broader "$id" --test "$BROADER_TEST" >/dev/null \
    || fail "broader fixture was rejected"

  # A skipped check alongside real passes is ordinary CI, so the rollup is green,
  # but the counts stay visible in the ready line for the approving captain.
  set_rollup "$FAKE_GH_DIR" '3 passed, 1 skipped, 0 failed, 4 total'
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id") \
    || fail "a rollup with only passed and skipped checks was refused: $out"
  assert_contains "$out" 'fast-repair ready:' "skipped-but-green rollup did not report ready"
  assert_contains "$out" '1 skipped' "the ready line hid the rollup counts it was approved on"

  # gh-axi folds CANCELLED into the same skipped count, so a rollup where nothing
  # passed has proven nothing and is never green.
  set_rollup "$FAKE_GH_DIR" '0 passed, 0 failed, 1 skipped, 1 total'
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a rollup whose only check was skipped or cancelled was reported ready"
  assert_contains "$out" 'PR checks are not green' "an all-skipped rollup did not name the refusal"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  [ -z "$out" ] || fail "an all-skipped rollup produced an actionable progress result: $out"

  # "10 failed, 0 pending" contains "0 failed, 0 pending" as a substring.
  set_rollup "$FAKE_GH_DIR" '3 passed, 10 failed, 0 pending, 13 total'
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a rollup with 10 failed checks was reported ready"
  assert_contains "$out" 'PR checks are not green' "failed rollup did not name the refusal"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  assert_contains "$out" 'pr-checks-failed' "failed rollup was not surfaced to the progress cadence"

  set_rollup "$FAKE_GH_DIR" '2 passed, 0 failed, 2 pending, 4 total'
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a pending rollup was reported ready"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  [ -z "$out" ] || fail "a pending rollup produced an actionable progress result: $out"

  set_no_checks_rollup "$FAKE_GH_DIR"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a PR with no configured checks was reported ready"
  assert_contains "$out" 'PR checks could not be read' "an absent rollup did not name the refusal"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  [ -z "$out" ] || fail "an absent rollup produced an actionable progress result: $out"
  pass "Fast Repair reads the PR rollup counts numerically for ready and the progress cadence"
}

# The eligibility record is this tool's own private, versioned evidence file, so
# the test writes one directly to prove the gate re-applies the intake rule to
# whatever the record actually holds.
test_stored_eligibility_uses_the_intake_rule() {
  local home id=stored-rule f tmp out status
  home=$(make_home stored-rule)
  intake "$home" "$id" >/dev/null
  run_fast "$home" eligible "$id" >/dev/null || fail "a complete stored record did not validate"
  write_fast_meta "$home" "$id"

  f="$home/data/$id/fast-repair-eligibility"
  tmp="$home/eligibility.tmp"
  sed 's/^reproduction=.*/reproduction=false/' "$f" > "$tmp" && mv -f "$tmp" "$f"
  out=$(run_fast "$home" eligible "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a stored fact intake refuses still passed the eligibility gate"
  assert_contains "$out" "eligibility evidence" "the eligibility gate did not name its refusal"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a stored fact intake refuses still reached the evidence gate"
  pass "every Fast Repair gate re-applies intake's own rule to the stored evidence record"
}

test_later_gates_revalidate_typed_eligibility() {
  local home id=later-gates f out status gate
  home=$(make_home later-gates)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id" https://github.com/acme/repo/pull/42
  write_regression_test "$home"
  write_focused_test "$home"
  write_broader_test "$home"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -eq 0 ] || fail "the later-gate fixture could not record focused evidence: $out"
  f="$home/data/$id/fast-repair-eligibility"
  sed 's/^isolation=.*/isolation=isolated-change/' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  printf 'Fast Repair fixture body.\n' > "$home/body.md"
  for gate in publish-pr broader progress ready; do
    case "$gate" in
      publish-pr) out=$(run_fast "$home" publish-pr "$id" --title fixture --body-file "$home/body.md") ;;
      broader) out=$(run_fast "$home" broader "$id" --test "$BROADER_TEST") ;;
      progress) out=$(run_fast "$home" progress "$id") ;;
      ready) out=$(run_fast "$home" ready "$id") ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "a later Fast Repair gate accepted tampered typed eligibility: $gate"
    assert_contains "$out" 'eligibility evidence' "a later Fast Repair gate did not name invalid eligibility: $gate"
  done
  pass "all later Fast Repair gates revalidate typed eligibility"
}

# The generated brief is firstmate's emitted worker interface, so the mandated
# command is extracted from it and executed in the environment a crewmate pane
# actually has: no FM_HOME and no state or data override.
test_brief_commands_reach_the_scaffolding_home() {
  local home id=brief-home brief line cmd prefix broader_cmd out status fakebin body
  home=$(make_home brief-home)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  write_regression_test "$home"
  write_focused_test "$home"
  write_broader_test "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" "$id" fixtureproj --mode fast-repair >/dev/null \
    || fail "the Fast Repair brief could not be scaffolded"

  brief="$home/data/$id/brief.md"
  line=$(grep -F " evidence $id " "$brief" | head -n 1)
  [ -n "$line" ] || fail "the Fast Repair brief mandates no evidence command"
  cmd=${line#*\`}
  cmd=${cmd%\`*}
  prefix=${cmd%% evidence *}
  [ "$prefix" != "$cmd" ] || fail "the mandated evidence command could not be read from the brief"

  out=$(cd "$home" && env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    bash -c "$prefix evidence $id --regression-test $REGRESSION_TEST --focused-test $FOCUSED_TEST" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the brief's own evidence command could not reach the task record: $out"
  assert_grep 'regression=passed' "$home/state/$id.fast-repair-tests" \
    "the brief's evidence command recorded its result outside the scaffolding home"

  write_fake_gh "$home"
  fakebin=$FAKE_GH_BIN
  printf '%s\n' "$(git -C "$home" rev-parse HEAD)" > "$FAKE_GH_DIR/pr-head"
  set_rollup "$FAKE_GH_DIR" '4 passed, 0 failed, 4 total'
  body="$TMP_ROOT/brief-body.md"
  printf 'Fast Repair brief body.\n' > "$body"
  out=$(cd "$home" && env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    PATH="$fakebin:$PATH" bash -c "$prefix publish-pr $id --title 'Brief Fast Repair' --body-file $body" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the brief's own publish command could not open the tested PR: $out"

  line=$(grep -F " broader $id " "$brief" | head -n 1)
  [ -n "$line" ] || fail "the Fast Repair brief mandates no broader-test command"
  cmd=${line#*\`}
  cmd=${cmd%\`*}
  broader_cmd=${cmd/"'<runner family broader than the focused one>'"/"$BROADER_TEST"}
  [ "$broader_cmd" != "$cmd" ] || fail "the brief's broader command carries no runner-family placeholder"
  out=$(cd "$home" && env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    PATH="$fakebin:$PATH" bash -c "$broader_cmd" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the brief's own broader-test command could not run: $out"
  assert_contains "$out" "fast-repair broader tests passed: $id" \
    "the brief's broader-test command did not use the typed test interface"
  pass "the Fast Repair brief's commands run against the home that scaffolded them"
}

# The evidence commands must see the environment the crewmate hands the helper,
# not a login profile's. The fixture HOME holds a profile that clobbers PATH,
# which is exactly the reported harm: a correct repair recorded as failed.
test_evidence_commands_ignore_a_login_profile() {
  local home id=login-profile out status loginhome toolbin
  home=$(make_home login-profile)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  loginhome="$TMP_ROOT/login-profile-home"
  toolbin="$TMP_ROOT/login-profile-bin"
  mkdir -p "$loginhome" "$toolbin"
  printf 'PATH=/nonexistent\nexport PATH\n' > "$loginhome/.bash_profile"
  cat > "$toolbin/fm-fixture-tool" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$toolbin/fm-fixture-tool"
  write_regression_test "$home"
  write_focused_test "$home"
  printf '#!/usr/bin/env bash\nfm-fixture-tool\n' > "$home/$FOCUSED_TEST"
  chmod +x "$home/$FOCUSED_TEST"
  commit_test_file "$home" "$FOCUSED_TEST"

  out=$(cd "$home" && HOME="$loginhome" PATH="$toolbin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$FAST" evidence "$id" --regression-test "$REGRESSION_TEST" \
    --focused-test "$FOCUSED_TEST" 2>&1)
  status=$?
  [ "$status" -eq 0 ] \
    || fail "a login profile's PATH reset decided the evidence result: $out
--- evidence log ---
$(cat "$home/state/$id.fast-repair-tests.log" 2>/dev/null)"
  assert_grep 'regression=passed' "$home/state/$id.fast-repair-tests" \
    "the evidence record did not come from the inherited environment"
  pass "Fast Repair evidence commands run with the worker's own environment, not a login profile's"
}

# The private records stay owner-only, while files the test suites create keep the
# permissions the caller's umask asks for.
test_private_records_do_not_impose_their_umask_on_tests() {
  local home id=umask-scope
  home=$(make_home umask-scope)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  write_regression_test "$home"
  write_focused_test "$home"

  ( umask 022
    run_fast "$home" evidence "$id" \
      --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" >/dev/null ) \
    || fail "the evidence gate refused its own passing fixture commands"

  [ "$(file_mode "$home/state/$id.fast-repair-tests")" = 600 ] \
    || fail "the evidence record is not owner-only: $(file_mode "$home/state/$id.fast-repair-tests")"
  [ "$(file_mode "$home/state/$id.fast-repair-tests.log")" = 600 ] \
    || fail "the evidence log is not owner-only: $(file_mode "$home/state/$id.fast-repair-tests.log")"
  pass "Fast Repair keeps its evidence records private without changing what the test commands create"
}

test_skipped_runner_family_cannot_satisfy_evidence() {
  local home id=skipped-family out status
  home=$(make_home skipped-family)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  write_regression_test "$home"
  write_focused_test "$home"
  sed 's/gate_skip=false/gate_skip=true/' "$home/bin/fm-test-run.sh" > "$home/bin/fm-test-run.sh.tmp" \
    && mv -f "$home/bin/fm-test-run.sh.tmp" "$home/bin/fm-test-run.sh"
  chmod +x "$home/bin/fm-test-run.sh"
  commit_test_file "$home" bin/fm-test-run.sh
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a skipped runner family satisfied Fast Repair evidence: $out"
  pass "Fast Repair evidence rejects skipped selected tests"
}

# Dispatch hands the crewmate a freshly pooled worktree at a detached HEAD sitting
# exactly on the commit the defect was reproduced at; the branch and the repair
# commit only exist later. The spawn gate must therefore accept that state while
# still refusing a worktree that is dirty, is not the task's repository root, or
# whose history does not carry the recorded reproduction commit.
test_spawn_eligibility_accepts_the_detached_task_worktree() {
  local home id=detached-spawn ahead=detached-ahead unknown=detached-unknown wt out status first second
  home=$(make_home detached-spawn)
  intake "$home" "$id" >/dev/null
  first=$(git -C "$home" rev-parse HEAD)
  wt="$TMP_ROOT/detached-spawn-worktree"
  git -C "$home" worktree add --quiet --detach "$wt" "$first" \
    || fail "the detached task worktree fixture could not be created"
  git -C "$wt" symbolic-ref --quiet --short HEAD >/dev/null 2>&1 \
    && fail "the fixture worktree is not at a detached HEAD"

  out=$(run_fast "$home" eligible "$id" --worktree "$wt")
  status=$?
  [ "$status" -eq 0 ] || fail "the real detached task worktree was refused at dispatch: $out"

  printf 'uncommitted\n' > "$wt/spawn-dirt"
  out=$(run_fast "$home" eligible "$id" --worktree "$wt")
  status=$?
  [ "$status" -ne 0 ] || fail "a dirty task worktree passed the dispatch eligibility proof"
  assert_contains "$out" 'no safe git worktree' "the dirty-worktree refusal was not actionable"
  rm -f "$wt/spawn-dirt"

  out=$(run_fast "$home" eligible "$id" --worktree "$wt/bin")
  status=$?
  [ "$status" -ne 0 ] || fail "a path below the worktree root passed the dispatch eligibility proof"
  assert_contains "$out" 'no safe git worktree' "the non-root refusal was not actionable"

  # A reproduction commit the worktree's own history does not carry yet is still
  # refused, so the spawn gate keeps binding the record to this task's history.
  git -C "$home" commit --quiet --allow-empty -m 'advance past the pooled worktree'
  second=$(git -C "$home" rev-parse HEAD)
  run_fast "$home" intake "$ahead" --request 'fast-repair: repair fixture' \
    --reproduction reproduced --reproduction-revision "$second" --root-cause confirmed \
    --isolation isolated --schema none --authentication none --authorization none \
    --secrets none --financial none --legal none --side-effects none >/dev/null \
    || fail "the ahead-revision fixture could not be recorded"
  out=$(run_fast "$home" eligible "$ahead" --worktree "$wt")
  status=$?
  [ "$status" -ne 0 ] || fail "a reproduction revision absent from the worktree history was accepted"
  assert_contains "$out" 'not an ancestor' "the non-ancestor refusal was not actionable"

  git -C "$wt" checkout --quiet --detach "$second"
  run_fast "$home" eligible "$ahead" --worktree "$wt" >/dev/null \
    || fail "a detached worktree sitting on the reproduction commit was refused"

  run_fast "$home" intake "$unknown" --request 'fast-repair: repair fixture' \
    --reproduction reproduced --reproduction-revision "$(printf '%040d' 0)" --root-cause confirmed \
    --isolation isolated --schema none --authentication none --authorization none \
    --secrets none --financial none --legal none --side-effects none >/dev/null \
    || fail "the unknown-revision fixture could not be recorded"
  out=$(run_fast "$home" eligible "$unknown" --worktree "$wt")
  status=$?
  [ "$status" -ne 0 ] || fail "a reproduction revision that is not a commit was accepted"
  pass "the Fast Repair dispatch gate proves the real detached task worktree without weakening its bindings"
}

# The proofs the dispatch gate cannot make yet are still mandatory once the
# tested head exists: evidence binds a named branch and requires the repair to
# sit strictly above the reproduction commit.
test_tested_head_proofs_stay_strict_after_dispatch() {
  local home id=head-proofs wt out status
  home=$(make_home head-proofs)
  intake "$home" "$id" >/dev/null
  write_regression_test "$home"
  write_focused_test "$home"

  wt="$TMP_ROOT/head-proofs-worktree"
  git -C "$home" worktree add --quiet --detach "$wt" HEAD \
    || fail "the detached evidence worktree fixture could not be created"
  write_fast_meta "$home" "$id" '' "$wt"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "evidence accepted a detached task worktree with no branch to bind"
  assert_contains "$out" 'no safe git worktree' "the detached-evidence refusal was not actionable"
  [ ! -e "$home/state/$id.fast-repair-tests" ] || fail "a branchless evidence run still wrote an evidence record"
  git -C "$home" worktree remove --force "$wt"

  # Re-record the reproduction at the branch tip: the repair commit no longer
  # sits above it, so the tested-head gate must refuse even though the same
  # record would satisfy the dispatch gate.
  write_fast_meta "$home" "$id"
  intake "$home" "$id" >/dev/null
  run_fast "$home" eligible "$id" --worktree "$home" >/dev/null \
    || fail "the dispatch gate refused a worktree sitting on its reproduction commit"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "evidence accepted a reproduction revision equal to the tested head"
  assert_contains "$out" 'reproduction revision is unknown, current, or not an ancestor' \
    "the current-reproduction refusal was not actionable"
  pass "Fast Repair still requires a bound branch and a strictly older reproduction commit at the tested head"
}

# Both halves of the regression proof reach the runner through a bare selector
# rather than --family, so the skip rule must be enforced on that argv shape too;
# a runner that reports the selector run as skipped can never prove a repair.
test_skipped_selector_run_cannot_satisfy_evidence() {
  local home id=skipped-selector out status
  home=$(make_home skipped-selector)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"
  write_regression_test "$home"
  write_focused_test "$home"
  # shellcheck disable=SC2016 # Literal fixture code expands only when its generated script runs.
  sed 's/gate_skip=false/gate_skip=$skip/' "$home/bin/fm-test-run.sh" > "$home/bin/fm-test-run.sh.tmp" \
    && mv -f "$home/bin/fm-test-run.sh.tmp" "$home/bin/fm-test-run.sh"
  # shellcheck disable=SC2016 # Literal fixture code expands only when its generated script runs.
  sed 's/^printf "FM_TEST_BEGIN/if [ "${1:-}" = --family ]; then skip=false; else skip=true; fi\nprintf "FM_TEST_BEGIN/' \
    "$home/bin/fm-test-run.sh" > "$home/bin/fm-test-run.sh.tmp" \
    && mv -f "$home/bin/fm-test-run.sh.tmp" "$home/bin/fm-test-run.sh"
  chmod +x "$home/bin/fm-test-run.sh"
  commit_test_file "$home" bin/fm-test-run.sh
  ( cd "$home" && ./bin/fm-test-run.sh --family "$FOCUSED_TEST" | grep -q 'gate_skip=false' ) \
    || fail "the fixture runner no longer reports an unskipped family run"
  ( cd "$home" && ./bin/fm-test-run.sh "tests/$REGRESSION_TEST.test.sh" | grep -q 'gate_skip=true' ) \
    || fail "the fixture runner no longer reports a skipped selector run"
  out=$(run_fast "$home" evidence "$id" --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST")
  status=$?
  [ "$status" -ne 0 ] || fail "a skipped selector run satisfied Fast Repair evidence: $out"
  assert_contains "$out" 'PR publication remains blocked' "a skipped selector run did not block publication"
  pass "Fast Repair applies one skip rule to family and selector runner invocations alike"
}

# The reproduction witness fills a private sandbox with a full object copy of the
# task repository, and every typed run writes a private output capture. Neither
# name carries a task id, so nothing else can ever reclaim them: a crewmate whose
# pane is killed mid-evidence would otherwise accumulate whole repository clones
# under firstmate's state directory.
test_interrupted_evidence_removes_its_temporary_artifacts() {
  local home id=interrupted-evidence block out pid status i live leftover
  home=$(make_home interrupted-evidence)
  intake "$home" "$id" >/dev/null
  write_regression_test "$home"
  write_focused_test "$home"
  write_fast_meta "$home" "$id"
  block="$TMP_ROOT/interrupted-evidence.block"
  out="$TMP_ROOT/interrupted-evidence.out"
  : > "$block"
  rm -f "$block.started"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FIXTURE_RUN_BLOCK="$block" "$FAST" evidence "$id" \
    --regression-test "$REGRESSION_TEST" --focused-test "$FOCUSED_TEST" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$block.started" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  if [ ! -e "$block.started" ]; then
    rm -f "$block"; kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    fail "the evidence run never reached a tracked runner invocation: $(cat "$out")"
  fi
  live=$(find "$home/state" -maxdepth 1 -name '.fast-repair-reproduction.*' -print -quit)
  if [ -z "$live" ]; then
    rm -f "$block"; kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    fail "the interrupted run was not holding a reproduction sandbox, so the fixture proves nothing"
  fi

  # The runner is a child of its own, so it never sees this signal; releasing the
  # block lets the interrupted script reach its handler exactly as a real one does.
  kill -TERM "$pid" 2>/dev/null || true
  rm -f "$block"
  wait "$pid" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "an interrupted evidence run reported success"
  leftover=$(find "$home/state" -maxdepth 1 \
    \( -name '.fast-repair-reproduction.*' -o -name '.fast-repair-test-output.*' \) -print | tr '\n' ' ')
  [ -z "$leftover" ] \
    || fail "an interrupted Fast Repair evidence run leaked unreclaimable temporaries: $leftover"
  [ ! -e "$home/state/$id.fast-repair-tests" ] \
    || fail "an interrupted evidence run still published an evidence record"
  rm -f "$block.started"
  pass "an interrupted Fast Repair evidence run removes its sandbox clone and output capture"
}

# A commit id is one concept with one shape, shared with the forge validator, so
# both object formats git can produce are accepted and anything else is refused
# before a task can enter the Fast Repair path.
test_reproduction_revision_accepts_every_commit_id_width() {
  local home id=revision-width out status bad
  home=$(make_home revision-width)
  run_fast "$home" intake "$id" --request 'fast-repair: repair fixture' \
    --reproduction reproduced --reproduction-revision "$(printf '%064d' 0)" --root-cause confirmed \
    --isolation isolated --schema none --authentication none --authorization none \
    --secrets none --financial none --legal none --side-effects none >/dev/null \
    || fail "a SHA-256 object-format commit id was refused at intake"
  run_fast "$home" eligible "$id" >/dev/null \
    || fail "a recorded SHA-256 commit id did not survive re-validation"

  for bad in "$(printf '%039d' 0)" "$(printf '%041d' 0)" "$(printf '%063d' 0)" \
    "$(printf '%065d' 0)" ABCDEF0123456789ABCDEF0123456789ABCDEF01 ''; do
    out=$(run_fast "$home" intake "$id-bad" --request 'fast-repair: repair fixture' \
      --reproduction reproduced --reproduction-revision "$bad" --root-cause confirmed \
      --isolation isolated --schema none --authentication none --authorization none \
      --secrets none --financial none --legal none --side-effects none)
    status=$?
    [ "$status" -ne 0 ] || fail "intake accepted '$bad' as a commit id"
    assert_contains "$out" 'reproduction-revision must be' "the malformed-revision refusal was not actionable"
  done
  [ ! -e "$home/data/$id-bad/fast-repair-eligibility" ] \
    || fail "a refused intake still recorded eligibility"
  pass "Fast Repair records the commit id shapes git produces and refuses everything else"
}

# Once the watcher has stopped polling the forge for a task it still needs the
# local half of the progress check, so --local-only must keep the broader-test
# branch and must reach no forge command at all.
test_local_only_progress_reads_no_forge() {
  local home id=local-only out status fakebin
  home=$(make_home local-only-progress)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id" https://github.com/acme/repo/pull/42
  write_fake_gh "$home"
  fakebin="$FAKE_GH_BIN"
  printf '%s\n' "$(git -C "$home" rev-parse HEAD)" > "$FAKE_GH_DIR/pr-head"
  set_rollup "$FAKE_GH_DIR" '4 passed, 0 failed, 4 total'

  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  assert_contains "$out" "fast-repair $id pr-checks-green" "the ordinary progress check did not read the PR rollup"
  assert_grep 'pr checks' "$FAKE_GH_DIR/gh-axi.args" "the ordinary progress check did not reach the forge"

  : > "$FAKE_GH_DIR/gh-axi.args"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id" --local-only)
  status=$?
  [ "$status" -eq 0 ] || fail "the local-only progress check refused: $out"
  [ -z "$out" ] || fail "the local-only progress check reported a forge state: $out"
  [ ! -s "$FAKE_GH_DIR/gh-axi.args" ] || fail "the local-only progress check reached the forge: $(cat "$FAKE_GH_DIR/gh-axi.args")"

  printf 'broader=failed\n' > "$home/state/$id.fast-repair-broader"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id" --local-only)
  assert_contains "$out" "fast-repair $id broader-tests-failed" "the local-only progress check hid a broader failure"
  [ ! -s "$FAKE_GH_DIR/gh-axi.args" ] || fail "the local-only broader branch reached the forge: $(cat "$FAKE_GH_DIR/gh-axi.args")"

  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id" --unknown-flag)
  status=$?
  [ "$status" -ne 0 ] || fail "progress accepted an unknown flag"
  pass "the local-only Fast Repair progress check keeps broader follow-up without reading the forge"
}

test_exact_prefix_only
test_interrupted_evidence_removes_its_temporary_artifacts
test_reproduction_revision_accepts_every_commit_id_width
test_eligibility_requires_every_typed_fact
test_spawn_eligibility_accepts_the_detached_task_worktree
test_tested_head_proofs_stay_strict_after_dispatch
test_skipped_selector_run_cannot_satisfy_evidence
test_stored_eligibility_uses_the_intake_rule
test_later_gates_revalidate_typed_eligibility
test_brief_commands_reach_the_scaffolding_home
test_evidence_commands_ignore_a_login_profile
test_private_records_do_not_impose_their_umask_on_tests
test_skipped_runner_family_cannot_satisfy_evidence
test_evidence_and_ready_gates
test_regression_selector_must_be_new_since_reproduction
test_regression_witness_requires_a_failing_reproduction
test_regression_witness_uses_the_tested_runner
test_evidence_requires_clean_bound_artifacts
test_pr_check_rollup_states
test_local_only_progress_reads_no_forge
echo "# all fm-fast-repair tests passed"
