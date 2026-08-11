#!/usr/bin/env bash
# tests/fm-backend-orca-smoke.test.sh - real Orca readiness gate.
#
# Orca is macOS-only, so Ubuntu CI must preserve explicit typed unavailable
# evidence instead of treating the platform absence as a silent skip.
set -u

if ! command -v orca >/dev/null 2>&1; then
  printf 'FM_TEST_RUNTIME_GATE runtime=orca outcome=unavailable\n'
  printf 'skip: orca CLI not found (Orca is macOS-only)\n'
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  printf 'FM_TEST_RUNTIME_GATE runtime=orca outcome=unavailable\n'
  printf 'skip: jq not found (required to inspect Orca readiness)\n'
  exit 0
}

status=$(orca status --json 2>/dev/null) || {
  printf 'FM_TEST_RUNTIME_GATE runtime=orca outcome=unavailable\n'
  printf 'skip: Orca runtime is not reachable\n'
  exit 0
}

if printf '%s\n' "$status" | jq -e '.result.runtime.reachable == true and .result.runtime.state == "ready"' >/dev/null 2>&1; then
  printf 'ok - real Orca: status reports a reachable ready runtime\n'
  printf 'FM_TEST_RUNTIME_GATE runtime=orca outcome=exercised\n'
else
  printf 'FM_TEST_RUNTIME_GATE runtime=orca outcome=unavailable\n'
  printf 'skip: Orca runtime is installed but not ready\n'
fi
