#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with the same complete inventory.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Local:    contributors invoke this script directly before pushing.
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
#   fm-lint.sh                    lint the canonical complete file set
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (focused CI and pre-push lint pass exact paths)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or the gate)
# fails exactly when ShellCheck reports a finding; a version mismatch or a
# missing ShellCheck fails before linting with a distinct message.
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
  exec shellcheck --norc -x "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs.
files=(bin/*.sh bin/backends/*.sh tests/*.sh)

# Lint in batches rather than one invocation over the whole set. ShellCheck holds
# every input's AST for the life of the run, so a single invocation grew with the
# repo until its resident set was measured in gigabytes; two lanes linting at once
# then thrash against each other. Batching bounds peak memory to one batch.
#
# -x is required for batching, not a relaxation: 82 of these scripts source a
# sibling, and ShellCheck resolves a sourced file either from the input list or,
# with -x, from disk. Without it a sourced file landing in another batch would
# raise SC1091 that the single invocation never saw, so -x is what keeps a batched
# run reporting the same findings as an unbatched one. It applies to the explicit
# -path form above for the same reason: one rule set, no drift between callers.
#
# Progress goes to stderr before each batch because this script otherwise prints
# nothing between its version banner and its exit. Supervisors that read silence
# as a wedged process have repeatedly misjudged this step; now the quiet gap is
# one batch rather than the whole run.
BATCH=25
total=${#files[@]}
batches=$(( (total + BATCH - 1) / BATCH ))
status=0
index=0
number=0
while [ "$index" -lt "$total" ]; do
  number=$((number + 1))
  chunk=("${files[@]:index:BATCH}")
  printf 'fm-lint.sh: batch %d/%d (%d scripts)\n' \
    "$number" "$batches" "${#chunk[@]}" >&2
  rc=0
  shellcheck --norc -x "${chunk[@]}" || rc=$?
  # Every batch runs even after a failure, so one run reports every finding
  # exactly as the single invocation did. The worst status wins.
  if [ "$rc" -gt "$status" ]; then
    status=$rc
  fi
  index=$((index + BATCH))
done
printf 'fm-lint.sh: linted %d scripts in %d batches\n' "$total" "$batches" >&2
exit "$status"
