#!/usr/bin/env bash
# Read-only live Gemini/Herdr composer guard. Set FM_GEMINI_COMPOSER_TARGET
# to an existing idle worker endpoint; no prompt, key, spawn or exit is sent.
# This is opt-in because it attaches to an operator-selected live endpoint.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_GEMINI_COMPOSER_LIVE gemini herdr
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/bin/fm-composer-lib.sh"
. "$ROOT/bin/backends/herdr.sh"
version=$(gemini --version)
[ "$version" = 0.62.0 ] \
  || fail "Gemini $version: rendered-surface adapter is pinned to 0.62.0; reverify before upgrading"
target=${FM_GEMINI_COMPOSER_TARGET:?select an existing idle Gemini endpoint}
fm_backend_herdr_parse_target "$target" || fail "Gemini $version: invalid target"
identity=$(fm_backend_herdr_composer_identity "$target") \
  || fail "Gemini $version: target identity unavailable"
case "$identity" in $'gemini\tidle'|$'gemini\tdone') ;; *) fail "Gemini $version: target is not natively idle: $identity" ;; esac
# Do not use the adapter's capture helpers: target_ready ensures the server
# and can restart it if it disappears after the identity query.
[ "$(fm_backend_herdr_server_running_state "$FM_BACKEND_HERDR_SESSION")" = running ] \
  || fail "Gemini $version: Herdr server is unavailable"
screen=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source visible --format ansi) \
  || fail "Gemini $version: read-only viewport capture failed"
identity=$(fm_backend_herdr_composer_identity "$target") \
  || fail "Gemini $version: identity unavailable after capture"
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=0\nidentity=1' "$screen" '' "$identity")
[ "$verdict" = empty ] || fail "Gemini $version: real idle composer verdict=$verdict"
printf 'ok - Gemini %s: live Herdr idle composer empty; read-only guard\n' "$version"
