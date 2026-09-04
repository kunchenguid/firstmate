#!/usr/bin/env bash
# Behavior tests for bin/fm-preflight-gate.sh, the pre-dispatch admission gate
# (fleet engineering plan workstream 2: push path, delivery path, quota
# headroom, host concurrency - refused independently and named exactly).
#
# Each of the four checks gets a refuses-case and a passes-case, driven
# against a fake gh-axi/no-mistakes/quota-axi on PATH and a real hermetic git
# repo, never the network. Two integration tests drive the real
# bin/fm-spawn.sh wiring (with tests/lib.sh's FM_PREFLIGHT_GATE_BYPASS unset)
# to prove the gate actually sits in front of worker launch, not just that the
# standalone script works in isolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-preflight-gate.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-preflight-gate)
fm_git_identity fmtest fmtest@example.invalid

# --- fakes -------------------------------------------------------------------

# fake_gh_axi <fakebin>: `api repos/<owner>/<repo> --jq .permissions.push`
# answers FM_FAKE_GH_PUSH (true|false|fail, default true).
fake_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GH_PUSH:-true}" in
  fail) exit 1 ;;
  false) echo false ;;
  *) echo true ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
}

# fake_no_mistakes <fakebin>: `status` answers FM_FAKE_NM_STATUS
# (initialized|uninitialized, default initialized).
fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  if [ "${FM_FAKE_NM_STATUS:-initialized}" = uninitialized ]; then
    echo "repo not initialized (run 'no-mistakes init' first)"
  else
    printf '%s\n' "    repo:  /fake" "  remote:  https://github.com/fake/fake.git" "    gate:  /fake/.no-mistakes/repos/fake.git"
  fi
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fake_quota_axi <fakebin>: `--json` answers a one-provider payload from
# FM_FAKE_QUOTA_PROVIDER (default claude), FM_FAKE_QUOTA_STATE (default fresh),
# FM_FAKE_QUOTA_ERROR, FM_FAKE_QUOTA_PERCENT (default 80), FM_FAKE_QUOTA_RUNWAY
# (default ok). FM_FAKE_QUOTA_FAIL=1 makes the command itself fail.
fake_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_QUOTA_FAIL:-0}" != 1 ] || exit 1
provider=${FM_FAKE_QUOTA_PROVIDER:-claude}
state=${FM_FAKE_QUOTA_STATE:-fresh}
error=${FM_FAKE_QUOTA_ERROR:-boom}
percent=${FM_FAKE_QUOTA_PERCENT:-80}
runway=${FM_FAKE_QUOTA_RUNWAY:-ok}
printf '{"providers":[{"provider":"%s","state":{"status":"%s","error":"%s","reason":"%s"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' \
  "$provider" "$state" "$error" "$error" "$percent" "$runway"
SH
  chmod +x "$fakebin/quota-axi"
}

make_repo() {  # <dir> -> initializes a git repo with one commit, echoes path
  local dir=$1
  fm_git_init_commit "$dir"
  printf '%s\n' "$dir"
}

run_gate() {  # <project-dir> <mode> <harness> <fakebin>
  local dir=$1 mode=$2 harness=$3 fakebin=$4
  PATH="$fakebin:$PATH" "$GATE" "$dir" --mode "$mode" --harness "$harness" 2>&1
}

# --- check 1: push path -------------------------------------------------------

test_push_path_no_fork_no_access_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/pp-refuse")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/pp-refuse-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=false run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "no push access and no fork remote should refuse"
  assert_contains "$out" "error: preflight refused [push-path]:" "refusal must name push-path"
  assert_contains "$out" "no push access to origin" "reason should say no push access to origin"
  assert_contains "$out" "no 'fork' remote is configured" "reason should say no fork remote is configured"
  pass "push-path refuses when origin denies push and no fork remote exists (the exact incident this workstream targets)"
}

test_push_path_fork_remote_restores_access() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/pp-fork")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/pp-fork-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[push-path]" "a pushable fork remote must satisfy push-path"
  [ "$status" -ne 4 ] || fail "push-path alone should not refuse when the fork remote is pushable: $out"
  pass "push-path passes when a pushable fork remote is configured"
}

test_push_path_no_mistakes_remote_is_the_real_target() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/pp-nm-target")
  # A pushable fork remote is configured, but a 'no-mistakes' remote (always a
  # local gate repo, never the real upstream) is ALSO configured, and its
  # reported delivery destination is a non-GitHub URL. The real target - not
  # the fork - must be what gets checked, so this must refuse as unverifiable
  # even though the fork remote itself would pass.
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  git -C "$dir" remote add no-mistakes "$TMP_ROOT/pp-nm-target-gate.git"
  fakebin=$(fm_fakebin "$TMP_ROOT/pp-nm-target-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '%s\n' "    repo:  /fake" "  remote:  https://gitlab.example.com/acme/widgets.git" "    gate:  /fake/.no-mistakes/repos/fake.git"
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "push-path must check the no-mistakes-configured delivery remote, not the pushable fork remote, when a no-mistakes remote exists"
  assert_contains "$out" "error: preflight refused [push-path]:" "refusal must name push-path"
  assert_contains "$out" "no-mistakes-configured delivery remote" "reason should name the actual no-mistakes delivery target, not the fork"
  pass "push-path uses the no-mistakes-configured delivery remote instead of a pushable fork/origin when no-mistakes is initialized"
}

test_push_path_non_github_remote_unverifiable() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/pp-nongh")
  git -C "$dir" remote add origin https://gitlab.example.com/acme/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/pp-nongh-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "a non-GitHub remote cannot be verified, so it must refuse rather than assume"
  assert_contains "$out" "error: preflight refused [push-path]:" "refusal must name push-path"
  assert_contains "$out" "not a github.com URL" "reason should say the check cannot inspect this forge"
  pass "push-path refuses (not silently passes) on a remote it has no permissions API for"
}

test_push_path_local_only_needs_no_remote() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/pp-local")
  fakebin=$(fm_fakebin "$TMP_ROOT/pp-local-bin")
  fake_quota_axi "$fakebin"
  out=$(run_gate "$dir" local-only pi "$fakebin")
  status=$?
  expect_code 0 "$status" "local-only has nothing to push, so it should be admitted with zero remotes: $out"
  pass "push-path and delivery-path are no-ops for local-only (nothing is ever pushed)"
}

# --- check 2: delivery path ---------------------------------------------------

test_delivery_path_no_mistakes_uninitialized_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-uninit")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-uninit-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_NM_STATUS=uninitialized run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "no-mistakes mode on an uninitialized repo should refuse"
  assert_contains "$out" "error: preflight refused [delivery-path]:" "refusal must name delivery-path"
  assert_contains "$out" "not initialized" "reason should say the repo is not initialized"
  pass "delivery-path refuses no-mistakes mode when the repo has no gate"
}

test_delivery_path_direct_pr_blocked_by_required_workflow_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-blocked")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/no-mistakes-required.yml" <<'YML'
on:
  pull_request:
    types: [opened]
jobs:
  check:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: |
          if ! printf '%s' "$PR_BODY" | grep -qF 'git push no-mistakes'; then
            echo "Contributions must be submitted via 'git push no-mistakes'." >&2
            exit 1
          fi
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-blocked-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  expect_code 4 "$status" "direct-PR should refuse when a required workflow demands the no-mistakes marker"
  assert_contains "$out" "error: preflight refused [delivery-path]:" "refusal must name delivery-path"
  assert_contains "$out" "git push no-mistakes" "reason should quote the marker the workflow requires"
  pass "delivery-path refuses direct-PR against the exact convention that blocked it on firstmate's own repo"
}

test_delivery_path_direct_pr_without_required_workflow_passes() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-ok")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  printf 'on:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
    > "$dir/.github/workflows/ci.yml"
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-ok-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "an ordinary CI workflow must not trip the no-mistakes-marker heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse without a no-mistakes-required workflow: $out"
  pass "delivery-path passes direct-PR when no workflow requires the no-mistakes marker"
}

test_delivery_path_direct_pr_unrelated_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-mention")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # Maintainers: contributions are normally submitted via 'git push no-mistakes'.
      - run: echo "building"
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-mention-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "a workflow that only mentions the marker in a comment must not trip the no-mistakes-body heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker is not tied to a PR-body check: $out"
  pass "delivery-path does not refuse direct-PR when 'git push no-mistakes' appears only in an unrelated comment, not a PR-body enforcement check"
}

test_delivery_path_direct_pr_cross_job_conflation_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-crossjob")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # Neither job, on its own, enforces a no-mistakes PR body: one job merely
  # logs the PR body's length for an unrelated reason, and a completely
  # different, unrelated job's step happens to mention the marker phrase in a
  # comment. Matching each phrase anywhere in the file independently would
  # wrongly conflate these two unrelated steps into an enforcement check.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  log-body-length:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - name: Log PR body length
        run: echo "body length: ${#PR_BODY}"
  unrelated:
    runs-on: ubuntu-latest
    steps:
      # Docs: contributions are normally submitted via 'git push no-mistakes'.
      - run: echo "building"
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-crossjob-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "an unrelated PR-body read in one job plus an unrelated marker mention in another job must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the PR-body read and the marker mention are in different, unrelated steps: $out"
  pass "delivery-path does not conflate an unrelated job's PR-body read with a different unrelated job's marker mention"
}

test_delivery_path_direct_pr_same_job_incidental_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-samejob-mention")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # A single job reads pull_request.body for an unrelated purpose (logging its
  # length) and, in that same job, a different step's echo merely mentions the
  # marker phrase in passing. Neither step checks the body against the marker,
  # so this job does not actually enforce a no-mistakes PR body - matching the
  # two phrases anywhere in the same job would wrongly treat an incidental
  # echo as enforcement.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - name: Log PR body length
        run: echo "body length: ${#PR_BODY}"
      - name: Print contribution instructions
        run: echo "Contributions are normally submitted via git push no-mistakes."
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-samejob-mention-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "an unrelated PR-body read plus an incidental echo mention in the same job must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker only appears in an unrelated echo, not a PR-body enforcement check: $out"
  pass "delivery-path does not conflate an unrelated PR-body read with an incidental same-job echo mention of the marker"
}

test_delivery_path_direct_pr_variable_indirected_marker_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-varindirect")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The exact shape of firstmate's own .github/workflows/no-mistakes-required.yml:
  # the marker text is assigned to a shell variable first, and the comparison
  # line references that variable ($marker) rather than spelling the marker
  # out itself. A detector that only looks for the marker's literal text on
  # the same line as the comparison would miss this - the real case this
  # workstream targets.
  cat > "$dir/.github/workflows/no-mistakes-required.yml" <<'YML'
on:
  pull_request:
jobs:
  check:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: |
          marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
          if printf '%s' "${PR_BODY:-}" | grep -qF -- "$marker"; then
            exit 0
          fi
          exit 1
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-varindirect-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  expect_code 4 "$status" "direct-PR should refuse against the real firstmate-shaped workflow where the marker is compared via a variable, not a literal on the comparison line"
  assert_contains "$out" "error: preflight refused [delivery-path]:" "refusal must name delivery-path"
  pass "delivery-path refuses direct-PR when the marker is checked through a variable indirection, matching firstmate's own workflow shape"
}

test_delivery_path_direct_pr_step_name_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-stepname")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The job genuinely reads the PR body (for an unrelated purpose), and a
  # DIFFERENT step's name field happens to mention the marker phrase. Neither
  # step compares the body against the marker.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - name: Log PR body length
        run: echo "body length: ${#PR_BODY}"
      - name: Remind contributors to use git push no-mistakes
        run: echo done
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-stepname-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "a step name mentioning the marker must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker only appears in a step name: $out"
  pass "delivery-path does not conflate a step name's marker mention with a PR-body enforcement check"
}

test_delivery_path_direct_pr_env_value_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-envvalue")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The job reads the PR body, and an unrelated env value (YAML "NAME: value"
  # form, not a shell assignment) happens to contain the marker phrase. That
  # env value is never compared against anything.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
      HINT: "contributions normally arrive via git push no-mistakes"
    steps:
      - run: echo "body length: ${#PR_BODY}"
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-envvalue-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "an unrelated env value mentioning the marker must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker only appears in an unrelated env value: $out"
  pass "delivery-path does not conflate an unrelated env value's marker mention with a PR-body enforcement check"
}

test_delivery_path_direct_pr_printf_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-printf")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The job reads the PR body, and a separate step prints a plain message
  # containing the marker phrase via printf - never comparing it to anything.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: echo "body length: ${#PR_BODY}"
      - run: printf 'Contributions normally arrive via git push no-mistakes\n'
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-printf-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "a plain printf mentioning the marker must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker only appears in a printf message: $out"
  pass "delivery-path does not conflate a plain printf's marker mention with a PR-body enforcement check"
}

test_delivery_path_direct_pr_incidental_grep_word_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-grepword")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The job reads the PR body and assigns the marker to a variable (both
  # tracked operands), but the only line mentioning both variables is a plain
  # echo whose quoted message happens to contain the word "grep" as prose,
  # not an invocation of the grep command. Treating any occurrence of "grep"
  # on a line with both operands as a comparison construct - even inside a
  # quoted string - would wrongly treat this as PR-body enforcement.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: |
          marker='git push no-mistakes'
          echo "note: not using grep here, just mentioning $PR_BODY and $marker in this message"
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-grepword-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "the word 'grep' inside a quoted echo message must not count as a comparison construct"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when 'grep' only appears as prose inside a quoted string: $out"
  pass "delivery-path does not treat the word 'grep' inside a quoted string as an actual comparison construct"
}

test_delivery_path_direct_pr_pull_request_target_trigger_out_of_scope() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-prtarget")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # This workflow genuinely compares a PR-body-derived value against the
  # marker, but it is triggered by pull_request_target, not pull_request.
  # The header comment scopes detection to "a pull_request-triggered
  # workflow" specifically; a substring search for "pull_request" anywhere in
  # the file also matches "pull_request_target" (and the
  # github.event.pull_request.body context expression that any such workflow
  # necessarily contains), which would wrongly pull this out-of-scope trigger
  # into the same refusal.
  cat > "$dir/.github/workflows/no-mistakes-required.yml" <<'YML'
on:
  pull_request_target:
jobs:
  check:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: |
          marker='git push no-mistakes'
          if printf '%s' "$PR_BODY" | grep -qF -- "$marker"; then
            exit 0
          fi
          exit 1
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-prtarget-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "a pull_request_target trigger is out of the stated pull_request-only scope"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse for a pull_request_target-triggered workflow: $out"
  pass "delivery-path does not match a pull_request_target trigger (or its pull_request.body context field) as the pull_request trigger"
}

test_delivery_path_direct_pr_heredoc_body_mention_does_not_refuse() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/dp-directpr-heredoc")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  mkdir -p "$dir/.github/workflows"
  # The job reads the PR body, and a separate step's heredoc body (documentation
  # text, not a comparison) mentions the marker phrase.
  cat > "$dir/.github/workflows/ci.yml" <<'YML'
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      PR_BODY: ${{ github.event.pull_request.body }}
    steps:
      - run: echo "body length: ${#PR_BODY}"
      - run: |
          cat <<DOC
          Contributions normally arrive via git push no-mistakes.
          DOC
YML
  fakebin=$(fm_fakebin "$TMP_ROOT/dp-directpr-heredoc-bin")
  fake_gh_axi "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=true run_gate "$dir" direct-PR claude "$fakebin")
  status=$?
  assert_not_contains "$out" "[delivery-path]" "a heredoc body mentioning the marker must not trip the heuristic"
  [ "$status" -ne 4 ] || fail "direct-PR should not refuse when the marker only appears in a heredoc body: $out"
  pass "delivery-path does not conflate a heredoc body's marker mention with a PR-body enforcement check"
}

# --- check 3: quota headroom ---------------------------------------------------

test_quota_stale_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/q-stale")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/q-stale-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_QUOTA_PROVIDER=claude FM_FAKE_QUOTA_STATE=stale FM_FAKE_QUOTA_ERROR=keychain_prompt_required \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "stale/unmeasured quota should refuse rather than assume headroom"
  assert_contains "$out" "error: preflight refused [quota-headroom]:" "refusal must name quota-headroom"
  assert_contains "$out" "keychain_prompt_required" "reason should carry the underlying quota-axi error"
  pass "quota-headroom refuses on a stale/keychain-required measurement (the real, currently-observed claude state)"
}

test_quota_exhausted_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/q-exhausted")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/q-exhausted-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_QUOTA_PROVIDER=codex FM_FAKE_QUOTA_STATE=fresh FM_FAKE_QUOTA_PERCENT=0 FM_FAKE_QUOTA_RUNWAY=exhausted_now \
    run_gate "$dir" no-mistakes codex "$fakebin")
  status=$?
  expect_code 4 "$status" "0%/exhausted_now quota should refuse"
  assert_contains "$out" "error: preflight refused [quota-headroom]:" "refusal must name quota-headroom"
  assert_contains "$out" "exhausted_now" "reason should carry the runway status"
  pass "quota-headroom refuses on a fresh-but-exhausted measurement (the real, currently-observed codex state)"
}

test_quota_healthy_passes() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/q-healthy")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/q-healthy-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_QUOTA_PROVIDER=claude FM_FAKE_QUOTA_STATE=fresh FM_FAKE_QUOTA_PERCENT=80 FM_FAKE_QUOTA_RUNWAY=ok \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 0 "$status" "fresh, healthy quota should admit: $out"
  pass "quota-headroom passes on a fresh, non-exhausted measurement"
}

test_quota_unmapped_harness_is_skipped_not_refused() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/q-unmapped")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/q-unmapped-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"
  # Deliberately no quota-axi on PATH: pi has no quota-axi provider concept at
  # all, so the check must not even try to run the (absent) command.
  out=$(run_gate "$dir" no-mistakes pi "$fakebin")
  status=$?
  expect_code 0 "$status" "a harness with no quota-axi provider must not be refused for it: $out"
  pass "quota-headroom skips (not refuses) a harness quota-axi has no provider for"
}

# --- check 4: concurrency / host capacity -------------------------------------

test_concurrency_load_ceiling_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/c-load")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/c-load-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_PREFLIGHT_CORES_OVERRIDE=4 FM_PREFLIGHT_LOAD_OVERRIDE=100 FM_PREFLIGHT_MEM_FREE_PERCENT_OVERRIDE=90 \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "a load average far past the per-core ceiling should refuse"
  assert_contains "$out" "error: preflight refused [concurrency]:" "refusal must name concurrency"
  assert_contains "$out" "load average" "reason should mention load average"
  pass "concurrency refuses when host load average is mutated past the safe ceiling"
}

test_concurrency_memory_floor_refuses() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/c-mem")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/c-mem-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_PREFLIGHT_CORES_OVERRIDE=4 FM_PREFLIGHT_LOAD_OVERRIDE=0.1 FM_PREFLIGHT_MEM_FREE_PERCENT_OVERRIDE=2 \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "available memory far under the safe floor should refuse"
  assert_contains "$out" "error: preflight refused [concurrency]:" "refusal must name concurrency"
  assert_contains "$out" "available memory" "reason should mention available memory"
  pass "concurrency refuses when host available memory is mutated below the safe floor"
}

test_concurrency_healthy_passes() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/c-healthy")
  git -C "$dir" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/c-healthy-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_PREFLIGHT_CORES_OVERRIDE=8 FM_PREFLIGHT_LOAD_OVERRIDE=1.0 FM_PREFLIGHT_MEM_FREE_PERCENT_OVERRIDE=60 \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 0 "$status" "healthy host load/memory should admit: $out"
  pass "concurrency passes when host load/memory are within the safe ceiling"
}

# --- multiple simultaneous failures -------------------------------------------

test_multiple_failures_all_named() {
  local dir fakebin out status
  dir=$(make_repo "$TMP_ROOT/multi")
  git -C "$dir" remote add origin https://github.com/acme/widgets.git
  fakebin=$(fm_fakebin "$TMP_ROOT/multi-bin")
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  out=$(FM_FAKE_GH_PUSH=false FM_FAKE_QUOTA_STATE=stale FM_FAKE_QUOTA_ERROR=keychain_prompt_required \
    run_gate "$dir" no-mistakes claude "$fakebin")
  status=$?
  expect_code 4 "$status" "two independent failures should still refuse once, not partially"
  assert_contains "$out" "[push-path]" "both failing preconditions must be named: push-path"
  assert_contains "$out" "[quota-headroom]" "both failing preconditions must be named: quota-headroom"
  pass "a spawn failing two preconditions at once gets both named, not just the first"
}

# --- integration: the real fm-spawn.sh wiring ---------------------------------

fake_tmux_minimal() {  # <fakebin> <wt> <launchlog>
  local fakebin=$1 wt=$2 launchlog=$3
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for a in "\$@"; do
      if [ "\$prev" = "-l" ]; then printf '%s\n' "\$a" >> "$launchlog"; fi
      prev=\$a
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

run_spawn_with_gate_live() {  # <home> <wt> <fakebin> <launchlog> <id> <proj> <mode> <harness>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6 mode=$7 harness=$8
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    PATH="$fakebin:$PATH" FM_PREFLIGHT_GATE_BYPASS='' \
    "$SPAWN" "$id" "$proj" --mode "$mode" --yolo off --harness "$harness" 2>&1
}

test_spawn_wiring_refuses_before_launch() {
  local case_dir home proj wt fakebin launchlog id out status
  case_dir="$TMP_ROOT/wiring-refuse"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; launchlog="$case_dir/launch.log"
  id=preflight-wiring-refuse-z1
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fakebin=$(fm_fakebin "$case_dir/fake")
  # fm_git_worktree's origin is a local file:// bare clone (not github.com), so
  # push-path is genuinely unverifiable here - a real refusal, not a rigged one.
  mkdir -p "$home/data/$id" "$home/state" "$home/projects" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  out=$(run_spawn_with_gate_live "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" no-mistakes claude)
  status=$?
  expect_code 4 "$status" "fm-spawn.sh must itself refuse when the admission gate fails"
  assert_contains "$out" "error: preflight refused [push-path]:" "fm-spawn's refusal must carry the named precondition"
  assert_absent "$home/state/$id.meta" "a refused spawn must never write task metadata"
  [ ! -s "$launchlog" ] || fail "a refused spawn must never reach the launch step: $(cat "$launchlog")"
  pass "fm-spawn.sh wiring: a failed admission check refuses before any endpoint or metadata is created"
}

test_spawn_wiring_admits_and_launches_normally() {
  local case_dir home proj wt fakebin launchlog id out status
  case_dir="$TMP_ROOT/wiring-admit"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; launchlog="$case_dir/launch.log"
  id=preflight-wiring-admit-z1
  fm_git_worktree "$proj" "$wt" "wt-$id"
  git -C "$proj" remote add fork https://github.com/me/widgets.git
  fakebin=$(fm_fakebin "$case_dir/fake")
  fake_tmux_minimal "$fakebin" "$wt" "$launchlog"
  fm_fake_exit0 "$fakebin" treehouse
  fake_gh_axi "$fakebin"; fake_no_mistakes "$fakebin"; fake_quota_axi "$fakebin"
  mkdir -p "$home/data/$id" "$home/state" "$home/projects" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  out=$(FM_FAKE_GH_PUSH=true FM_FAKE_QUOTA_PROVIDER=claude FM_FAKE_QUOTA_STATE=fresh \
    FM_FAKE_QUOTA_PERCENT=80 FM_FAKE_QUOTA_RUNWAY=ok \
    run_spawn_with_gate_live "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" no-mistakes claude)
  status=$?
  expect_code 0 "$status" "a fully healthy admission should let the spawn proceed as before: $out"
  assert_contains "$out" "spawned $id harness=claude" "a passed gate must still launch normally"
  assert_present "$home/state/$id.meta" "an admitted spawn must still write task metadata"
  [ -s "$launchlog" ] || fail "an admitted spawn must still reach the launch step"
  pass "fm-spawn.sh wiring: a fully healthy admission launches exactly as it did before this gate existed"
}

test_push_path_no_fork_no_access_refuses
test_push_path_fork_remote_restores_access
test_push_path_no_mistakes_remote_is_the_real_target
test_push_path_non_github_remote_unverifiable
test_push_path_local_only_needs_no_remote
test_delivery_path_no_mistakes_uninitialized_refuses
test_delivery_path_direct_pr_blocked_by_required_workflow_refuses
test_delivery_path_direct_pr_without_required_workflow_passes
test_delivery_path_direct_pr_unrelated_mention_does_not_refuse
test_delivery_path_direct_pr_cross_job_conflation_does_not_refuse
test_delivery_path_direct_pr_same_job_incidental_mention_does_not_refuse
test_delivery_path_direct_pr_variable_indirected_marker_refuses
test_delivery_path_direct_pr_step_name_mention_does_not_refuse
test_delivery_path_direct_pr_env_value_mention_does_not_refuse
test_delivery_path_direct_pr_printf_mention_does_not_refuse
test_delivery_path_direct_pr_incidental_grep_word_does_not_refuse
test_delivery_path_direct_pr_pull_request_target_trigger_out_of_scope
test_delivery_path_direct_pr_heredoc_body_mention_does_not_refuse
test_quota_stale_refuses
test_quota_exhausted_refuses
test_quota_healthy_passes
test_quota_unmapped_harness_is_skipped_not_refused
test_concurrency_load_ceiling_refuses
test_concurrency_memory_floor_refuses
test_concurrency_healthy_passes
test_multiple_failures_all_named
test_spawn_wiring_refuses_before_launch
test_spawn_wiring_admits_and_launches_normally
