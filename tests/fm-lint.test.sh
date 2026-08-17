#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_list_files_reports_the_shell_inventory() {
  local listed expected
  # CI=true forces the full canonical set regardless of the ambient branch or
  # working-tree diff a local test run happens to have, so this stays a pure
  # inventory check independent of fm-lint.sh's own changed-file mode below.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh --list-files did not return the complete shell inventory"
  pass "fm-lint.sh --list-files reports the complete shell inventory"
}

# fm_lint_stub_git <fakebin-dir>: install a git stub for the changed-file mode
# tests below. Its answers are driven by env vars the caller sets before
# invoking fm-lint.sh, so those tests can steer git state without depending on
# this worktree's actual branch, remotes, or history:
#   FM_TEST_GIT_INSIDE_WORKTREE  1 (default) or 0
#   FM_TEST_GIT_BRANCH           branch name for `rev-parse --abbrev-ref HEAD`
#   FM_TEST_GIT_HAS_ORIGIN_MAIN  1 (default) or 0
#   FM_TEST_GIT_HAS_MAIN         1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE_OK    1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE       merge-base value to print when OK
#   FM_TEST_GIT_DIFF_FILE        path to a file of NUL-separated changed paths
fm_lint_stub_git() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree")
    [ "${FM_TEST_GIT_INSIDE_WORKTREE:-1}" = 1 ] || exit 1
    printf 'true\n'
    exit 0
    ;;
  "rev-parse --abbrev-ref HEAD")
    printf '%s\n' "${FM_TEST_GIT_BRANCH:-feature}"
    exit 0
    ;;
  "rev-parse --verify -q origin/main")
    [ "${FM_TEST_GIT_HAS_ORIGIN_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "rev-parse --verify -q main")
    [ "${FM_TEST_GIT_HAS_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "merge-base "*)
    if [ "${FM_TEST_GIT_MERGE_BASE_OK:-1}" = 1 ]; then
      printf '%s\n' "${FM_TEST_GIT_MERGE_BASE:-fakebase123}"
      exit 0
    fi
    exit 1
    ;;
  "diff --name-only --diff-filter=ACMR -z "*)
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      cat "$FM_TEST_GIT_DIFF_FILE"
    fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/git"
}

# fm_lint_write_diff_file <file> <path>...: writes NUL-separated changed paths
# in the shape `git diff --name-only -z` produces, for FM_TEST_GIT_DIFF_FILE.
fm_lint_write_diff_file() {
  local file=$1
  shift
  printf '%s\0' "$@" > "$file"
}

# fm_lint_stub_shellcheck <fakebin-dir> <log-file>: install a ShellCheck stub
# that answers --version with the pinned version and otherwise logs the file
# roots it was asked to check (one per line) instead of actually analyzing
# them, so changed-file mode tests can assert exactly which files fm-lint.sh
# selected without depending on real ShellCheck findings.
fm_lint_stub_shellcheck() {
  local fakebin=$1 log=$2
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
}

test_changed_mode_lints_only_the_changed_file() {
  local tmp fakebin log diff_file out target
  tmp=$(fm_test_tmproot fm-lint-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-install-shellcheck.sh"
  fm_lint_write_diff_file "$diff_file" "$target" "README.md"

  # Clear the ambient CI/GITHUB_ACTIONS signals so changed-file mode is actually
  # exercised: a CI run sets them and would otherwise force the full lint here.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) \
    || fail "changed-mode lint run failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "changed-mode lint did not run ShellCheck on exactly the changed file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh changed mode lints only the changed canonical file"
}

test_ci_forces_full_lint_even_with_empty_diff() {
  local listed expected
  # No git stub: CI=true must short-circuit fm-lint.sh's mode selection before
  # it ever consults git, so this proves CI wins regardless of local diff state.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "CI=true did not force the full canonical file set"
  pass "fm-lint.sh forces a full lint in CI even when the local diff would be empty"
}

test_main_branch_forces_full_lint() {
  local tmp fakebin listed expected
  tmp=$(fm_test_tmproot fm-lint-main-full)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"

  # Clear CI/GITHUB_ACTIONS so the on-main branch is what forces the full lint,
  # not the ambient CI signal a real CI run would otherwise supply.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' \
    FM_TEST_GIT_BRANCH=main "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh did not force a full lint when HEAD is on main"
  pass "fm-lint.sh forces a full lint when HEAD is on main"
}

test_explicit_path_bypasses_changed_logic() {
  local tmp fakebin log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-override)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  # The git stub reports a broken merge-base, which would force a full lint
  # under the no-args default. Clearing CI/GITHUB_ACTIONS keeps changed-file
  # selection live so this proves the explicit path bypasses it, not that CI
  # already forced full mode. An explicit path must never even consult git.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_MERGE_BASE_OK=0 \
    "$LINT" "$target" 2>&1) || fail "explicit-path lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "explicit path lint did not run on exactly the requested file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh explicit paths bypass changed-file mode selection"
}

test_zero_changed_files_exits_clean() {
  local tmp fakebin diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-zero-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  # Clear CI/GITHUB_ACTIONS so changed-file mode runs and can reach the empty
  # target set; a CI run would otherwise force a full lint instead.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "zero changed lint targets must exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck 0.11.0" "zero-changed run did not print the ShellCheck version line"
  assert_contains "$out" "no changed lint targets" "zero-changed run did not note the empty target set"
  assert_contains "$out" "workflow files valid" \
    "zero-changed run skipped workflow YAML validation"
  pass "fm-lint.sh exits 0 with a note when the local branch has no changed lint targets"
}

test_list_files_respects_changed_mode() {
  local tmp fakebin diff_file listed
  tmp=$(fm_test_tmproot fm-lint-list-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  # A real canonical file, a non-canonical file, and a canonical-looking path
  # that does not exist: only the first should survive into the listed set.
  fm_lint_write_diff_file "$diff_file" \
    "tests/fm-lint.test.sh" "docs/README.md" "bin/definitely-not-real-file.sh"

  # Clear CI/GITHUB_ACTIONS so --list-files reflects the changed set rather than
  # the full canonical set a CI run's ambient signals would otherwise force.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" --list-files)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "--list-files did not report the would-be changed set in changed mode"$'\n'"got: $listed"
  pass "fm-lint.sh --list-files reports the would-be changed set in changed mode"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
# Reproduce the CI incident: the release endpoint returned 503 for all three
# formerly configured attempts before recovering.
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
printf '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  %s\n' "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
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
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_seeded_module_boundary_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded source-boundary parity check"
    return
  fi
  local tmp rel adapter dispatcher dep owner test_root out rc
  tmp=$(mktemp -d "$ROOT/.fm-lint-parity.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$tmp")
  rel=${tmp#"$ROOT/"}
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$rel/owner-dep.sh
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2086 (info)')" -eq 1 ] \
    || fail "the dispatcher boundary re-imported the adapter diagnostic"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2164 (warning)')" -eq 1 ] \
    || fail "the test boundary re-imported the production-owner diagnostic"
  pass "seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

test_list_files_reports_the_shell_inventory
test_pins_an_explicit_version
test_installer_retries_transient_download_failure
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_jobs_are_deterministic_and_complete
test_worker_trees_stop_on_signal
test_seeded_module_boundary_parity
test_changed_mode_lints_only_the_changed_file
test_ci_forces_full_lint_even_with_empty_diff
test_main_branch_forces_full_lint
test_explicit_path_bypasses_changed_logic
test_zero_changed_files_exits_clean
test_list_files_respects_changed_mode
