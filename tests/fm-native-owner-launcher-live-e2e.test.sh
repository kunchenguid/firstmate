#!/usr/bin/env bash
# Actual native launcher. Default opt-out; model turns require a second opt-in.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_LIVE_NATIVE_LAUNCHER node powershell.exe codex docker
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) printf 'Native launcher tests require Windows\n' >&2; exit 1 ;; esac
args=()
if [ "${FM_LIVE_NATIVE_CODEX:-}" = 1 ]; then args+=(--live); fi
node "$ROOT/tests/fixtures/native-owner/Launcher.mjs" "${args[@]}"
