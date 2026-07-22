#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# Canonical runs use two source-complete ShellCheck groups: toolbelt/backends and
# tests. --external-sources retains references across the group boundary, while
# each group's complete provider/consumer context prevents split-file unused
# symbol false positives. FM_LINT_JOBS may select one or two concurrent groups
# for local resource constraints without changing the file set or lint policy.
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. This script pins one exact
# version (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it,
# so CI and local run the identical rule set. This is not a CI relaxation: it
# adopts one upstream release consistently; the only difference from the old
# floating CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket exclude of checks - every still-supported
# finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Exit status is the first nonzero ShellCheck group status in canonical order,
# so a caller (CI or the gate) fails exactly when either complete group reports
# a finding; version mismatch or missing ShellCheck fails before linting.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the test suite reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  exec shellcheck --norc "$@"
fi

# Canonical file set and source-context groups: the ONE authoritative
# definition. Callers reference this script; they never re-spell these globs.
lint_toolbelt=(bin/*.sh bin/backends/*.sh)
lint_tests=(tests/*.sh)

jobs=${FM_LINT_JOBS:-2}
case "$jobs" in
  1|2) ;;
  *)
    printf 'fm-lint.sh: FM_LINT_JOBS must be 1 or 2, got %s.\n' "$jobs" >&2
    exit 2
    ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

run_group() {
  local name=$1
  shift
  shellcheck --norc --external-sources "$@" > "$tmp/$name.out" 2>&1
}

run_group toolbelt "${lint_toolbelt[@]}" &
toolbelt_pid=$!
if [ "$jobs" -eq 2 ]; then
  run_group tests "${lint_tests[@]}" &
  tests_pid=$!

  toolbelt_rc=0
  wait "$toolbelt_pid" || toolbelt_rc=$?
  tests_rc=0
  wait "$tests_pid" || tests_rc=$?
else
  toolbelt_rc=0
  wait "$toolbelt_pid" || toolbelt_rc=$?
  tests_rc=0
  run_group tests "${lint_tests[@]}" || tests_rc=$?
fi

cat "$tmp/toolbelt.out"
cat "$tmp/tests.out"
if [ "$toolbelt_rc" -ne 0 ]; then
  exit "$toolbelt_rc"
fi
exit "$tests_rc"
