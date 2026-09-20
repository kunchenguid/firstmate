#!/usr/bin/env bash
# Explicitly opt-in, two-turn Codex test of the consolidated native core.
# Uses a disposable home only; no sandbox changes or provider installation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_LIVE_NATIVE_CODEX node powershell.exe codex docker
: "${FM_NATIVE_TEST_JQ_IMAGE:?Set FM_NATIVE_TEST_JQ_IMAGE to an existing local image with jq and GNU timeout}"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) printf '%s\n' 'Native Codex ownership test requires Windows' >&2; exit 1 ;;
esac
export FM_LIVE_NATIVE_CODEX=1
fixture="$ROOT/tests/fixtures/native-owner"
powershell.exe -NoProfile -NonInteractive -File "$(cygpath -w "$fixture/Build.ps1")"
node "$fixture/Run-Cycle.mjs" --dry
node "$fixture/Run-Cycle.mjs" --dry --startup-queued
node "$fixture/Run-Cycle.mjs" --dry --fault=partial
node "$fixture/Run-Cycle.mjs" --dry --fault=complete
node "$fixture/Run-Cycle.mjs" --dry --fault=zero-missing
node "$fixture/Run-Cycle.mjs" --dry --fault=zero-malformed
node "$fixture/Run-Cycle.mjs" --dry --fault=zero-mismatched
node "$fixture/Run-Cycle.mjs" --dry --fault=zero-unproven
node "$fixture/Run-Cycle.mjs"
node "$fixture/Verify-Cycle.mjs"
