#!/usr/bin/env bash
# GitHub workflow lint gate owned by bin/fm-lint-workflows.sh.
#
# A malformed .github/workflows/*.yml, including a self-broken ci.yml, must fail
# in the local/no-mistakes lint path before merge. Regression origin: #2512 put
# a column-0 heredoc body inside a `run: |` block in ci.yml; there was no
# workflow YAML lint, and the broken workflow could not report its own breakage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT_WF="$ROOT/bin/fm-lint-workflows.sh"
LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-actionlint.sh"
REQUIRED=$("$LINT_WF" --required-version)

write_valid_workflow() {
  local path=$1
  cat > "$path" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -eu
          echo ok
YAML
}

# #2512-class breakage: a heredoc body at column 0 inside a `run: |` block.
write_col0_heredoc_workflow() {
  local path=$1
  cat > "$path" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: Compatibility pointers must stay intact
        run: |
          set -eu
          cmp -s CLAUDE.md - <<'EOF' || exit 1
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
          echo ok
YAML
}

test_current_workflows_pass() {
  local out rc
  rc=0
  out=$("$LINT_WF" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "current workflows must parse, got $rc"$'\n'"$out"
  assert_contains "$out" "workflow files valid" \
    "current-workflow lint did not report a valid count"
  pass "current .github/workflows YAML files parse"
}

test_col0_heredoc_fails_with_clear_error() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-col0)
  mkdir -p "$tmp/.github/workflows"
  write_col0_heredoc_workflow "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "column-0 heredoc workflow unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "column-0 heredoc failure did not report actionlint's YAML syntax error"
  assert_contains "$out" "ci.yml" \
    "column-0 heredoc failure did not name the workflow file"
  pass "column-0 heredoc workflow fails validation with a clear error"
}

test_valid_fixture_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-ok)
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "valid fixture workflow failed"$'\n'"$out"
  assert_contains "$out" "1 workflow files valid" \
    "valid fixture did not report one valid file"
  pass "valid fixture workflow passes"
}

test_empty_workflows_dir_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-empty)
  mkdir -p "$tmp/.github/workflows"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "empty workflows dir unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "no GitHub workflow files found" \
    "empty workflows dir did not report the missing files"
  pass "empty workflows directory fails closed"
}

test_explicit_broken_path_fails() {
  local tmp broken out rc
  tmp=$(fm_test_tmproot fm-lint-wf-path)
  broken="$tmp/broken.yml"
  write_col0_heredoc_workflow "$broken"
  rc=0
  out=$("$LINT_WF" "$broken" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "explicit broken path unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "explicit broken path did not report actionlint's YAML syntax error"
  pass "explicit malformed workflow path fails validation"
}

test_non_mapping_root_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-scalar)
  mkdir -p "$tmp/.github/workflows"
  printf 'just-a-string\n' > "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "scalar YAML root unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "mapping node is expected" \
    "scalar YAML root did not report actionlint's mapping-node error"
  pass "non-mapping workflow YAML root fails"
}

test_missing_actionlint_fails_closed() {
  local tmp fakebin out rc tool
  tmp=$(fm_test_tmproot fm-lint-wf-noactionlint)
  fakebin=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  for tool in bash dirname find sort awk; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  rc=0
  out=$(PATH="$fakebin" "$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 127 ] || fail "missing actionlint expected exit 127, got $rc"$'\n'"$out"
  assert_contains "$out" "actionlint not found" \
    "missing actionlint did not name the required linter"
  assert_contains "$out" "$REQUIRED" \
    "missing actionlint did not name the pinned version"
  pass "missing actionlint fails closed"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint-workflows.sh --required-version printed nothing"
  assert_contains "$REQUIRED" "1.7.12" "fm-lint-workflows.sh must pin actionlint 1.7.12"
  pass "fm-lint-workflows.sh pins an explicit actionlint version ($REQUIRED)"
}

test_rejects_wrong_actionlint_version() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-wf-ver)
  fakebin=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  cat > "$fakebin/actionlint" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-version" ]; then
  printf '0.0.0\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/actionlint"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint-workflows.sh accepted an actionlint version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint-workflows.sh did not name the required version on mismatch"
  assert_contains "$out" "0.0.0" "fm-lint-workflows.sh did not report the resolved (wrong) version"
  pass "fm-lint-workflows.sh refuses to lint under a non-pinned actionlint version"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-actionlint-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 3 ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  %s\n' "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    cat > "$2/actionlint" <<'EOF'
#!/usr/bin/env bash
printf '1.7.12\n'
EOF
    chmod +x "$2/actionlint"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/sleep"

  out=$(CURL_COUNT="$tmp/curl-count" PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/actionlint" ] || fail "installer did not install actionlint after retrying"
  pass "actionlint installer retries a transient download failure"
}

# Prove the no-mistakes/local owner (bin/fm-lint.sh with no paths) catches a
# self-broken ci.yml. Copy the lint scripts into a fake repo so the default
# workflow root is the fixture, not this worktree.
test_fm_lint_default_path_catches_broken_ci_yml() {
  local tmp fakebin log diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-wf-default)
  mkdir -p "$tmp/bin" "$tmp/.github/workflows"
  cp "$LINT" "$tmp/bin/fm-lint.sh"
  cp "$LINT_WF" "$tmp/bin/fm-lint-workflows.sh"
  chmod +x "$tmp/bin/fm-lint.sh" "$tmp/bin/fm-lint-workflows.sh"
  write_col0_heredoc_workflow "$tmp/.github/workflows/ci.yml"

  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree") printf 'true\n'; exit 0 ;;
  "rev-parse --abbrev-ref HEAD") printf 'feature\n'; exit 0 ;;
  "rev-parse --verify -q origin/main") exit 0 ;;
  "merge-base "*) printf 'fakebase123\n'; exit 0 ;;
  "diff --name-only --diff-filter=ACMR -z fakebase123 --")
    [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && cat "${FM_TEST_GIT_DIFF_FILE}"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/git"
  : > "$log"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
shift 3
printf '%s\n' "\$@" >> "$log"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$tmp/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh default path missed a broken ci.yml"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "fm-lint.sh default path did not surface the workflow YAML error"
  assert_contains "$out" "ci.yml" \
    "fm-lint.sh default path did not name the broken workflow"
  pass "fm-lint.sh default path catches a self-broken ci.yml"
}

test_pins_an_explicit_version
test_current_workflows_pass
test_col0_heredoc_fails_with_clear_error
test_valid_fixture_passes
test_empty_workflows_dir_fails
test_explicit_broken_path_fails
test_non_mapping_root_fails
test_missing_actionlint_fails_closed
test_rejects_wrong_actionlint_version
test_installer_retries_transient_download_failure
test_fm_lint_default_path_catches_broken_ci_yml
