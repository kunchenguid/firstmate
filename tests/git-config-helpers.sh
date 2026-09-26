#!/usr/bin/env bash
# tests/git-config-helpers.sh - fixture Git isolation from the host's global and
# system configuration.
#
# Source this before a fixture's first Git operation:
#   # shellcheck source=tests/git-config-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"
#
# Fixture Git processes must not inherit host signing, hooks, or other global and
# system preferences: with commit.gpgsign=true set globally and no secret key for
# the fixture identities, every fixture commit fails before its assertion.
# Isolation is limited to those two layers on purpose, so repository-local config,
# inline `git -c`, GIT_CONFIG_COUNT, and a GIT_CONFIG_GLOBAL the caller supplies
# after sourcing all stay authoritative - the Git-config suites assert on them.
# The export reaches only the sourcing shell and its children, so the developer's
# own config files are never written and real project commits made outside the
# fixtures keep their configuration and signing.
#
# tests/lib.sh and tests/herdr-test-safety.sh source this for every suite that
# uses them, bin/fm-test-run.sh sources it per suite in run_script_bounded, and a
# suite reaching none of those sources it directly so a hand-run invocation is
# isolated too. tests/fm-test-fixtures.test.sh is the regression - it drives the
# shared helpers, the runner, and the standalone entry points that run without a
# live vendor - and the changed-file map selects it for a change to this file.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
