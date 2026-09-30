#!/usr/bin/env bash
# Read-only live Gemini/Herdr composer guard. Set FM_GEMINI_COMPOSER_TARGET
# to an existing idle worker endpoint; no prompt, key, spawn or exit is sent.
# This is opt-in because it attaches to an operator-selected live endpoint.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_GEMINI_COMPOSER_LIVE herdr
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/bin/fm-composer-lib.sh"
. "$ROOT/bin/backends/herdr.sh"
# A local Gemini binary cannot attest the selected endpoint's version.
# This guard verifies the pinned rendered layout and native identity only;
# endpoint release provenance remains operator-supplied verification evidence.
label='Gemini 0.62.0 layout (endpoint version unverified)'
target=${FM_GEMINI_COMPOSER_TARGET:?select an existing idle Gemini endpoint}
fm_backend_herdr_parse_target "$target" || fail "$label: invalid target"
identity=$(fm_backend_herdr_composer_identity "$target") \
  || fail "$label: target identity unavailable"
case "$identity" in $'gemini\tidle'|$'gemini\tdone') ;; *) fail "$label: target is not natively idle: $identity" ;; esac
# Do not use the adapter's capture helpers: target_ready ensures the server
# and can restart it if it disappears after the identity query.
[ "$(fm_backend_herdr_server_running_state "$FM_BACKEND_HERDR_SESSION")" = running ] \
  || fail "$label: Herdr server is unavailable"
screen=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source visible --format ansi) \
  || fail "$label: read-only viewport capture failed"
identity=$(fm_backend_herdr_composer_identity "$target") \
  || fail "$label: identity unavailable after capture"
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=0\nidentity=1' "$screen" '' "$identity")
[ "$verdict" = empty ] || fail "$label: real idle composer verdict=$verdict"
printf 'ok - %s: live Herdr idle composer empty; read-only guard\n' "$label"
