#!/usr/bin/env bash
# Behavioral regressions for fm_dod_block's generated Definition of done.
# The no-mistakes arm must send the worker straight from its implementation
# commit into the pipeline: no pre-validation done instruction, and exactly one
# terminal `done:` form (`done: PR {url} checks green`). The direct-PR and
# local-only arms are pinned against fixtures so a no-mistakes-arm change
# cannot silently drift them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)

test_no_mistakes_arm_has_no_pre_validation_done() {
  local block="$TMP_ROOT/no-mistakes.block"
  fm_dod_block no-mistakes dod-fixture > "$block" \
    || fail "fm_dod_block refused the no-mistakes mode"
  grep -qx 'Delivery contract: mode=no-mistakes' "$block" \
    || fail "no-mistakes arm lost its machine-readable contract line"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_no_grep 'done: {summary}' "$block" \
    "no-mistakes arm still tells the worker to report done before validation"
  assert_no_grep 'Firstmate will then instruct' "$block" \
    "no-mistakes arm still parks the worker to wait for a firstmate instruction"
  [ "$(grep -c 'done:' "$block")" -eq 1 ] \
    || fail "no-mistakes arm must carry exactly one terminal done: form"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'append `done: PR {url} checks green` and stop' "$block" \
    "no-mistakes arm lost its terminal CI-green done: form"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'pass `--intent`' "$block" \
    "no-mistakes arm no longer carries the --intent contract in the same block"
  pass "no-mistakes arm goes straight into validation with one terminal done: form"
}

test_direct_pr_and_local_only_arms_are_unchanged() {
  local block="$TMP_ROOT/arm.block" expect="$TMP_ROOT/arm.expected"

  fm_dod_block direct-PR dod-fixture > "$block" \
    || fail "fm_dod_block refused the direct-PR mode"
  cat > "$expect" <<'EOF'
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
  diff -u "$expect" "$block" >&2 || fail "direct-PR arm drifted from its fixture"

  fm_dod_block local-only dod-fixture > "$block" \
    || fail "fm_dod_block refused the local-only mode"
  cat > "$expect" <<'EOF'
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/dod-fixture`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/dod-fixture` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
EOF
  diff -u "$expect" "$block" >&2 || fail "local-only arm drifted from its fixture"

  pass "direct-PR and local-only arms match their pinned fixtures"
}

test_no_mistakes_arm_has_no_pre_validation_done
test_direct_pr_and_local_only_arms_are_unchanged
