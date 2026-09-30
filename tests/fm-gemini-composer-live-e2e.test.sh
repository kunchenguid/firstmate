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
target=${FM_GEMINI_COMPOSER_TARGET:?select an existing idle Gemini endpoint}
identity=$(fm_backend_herdr_composer_identity "$target")
case "$identity" in $'gemini\tidle'|$'gemini\tdone') ;; *) fail "Gemini $version: target is not natively idle: $identity" ;; esac
verdict=$(fm_backend_herdr_composer_state "$target")
[ "$verdict" = empty ] || fail "Gemini $version: real idle composer verdict=$verdict"
printf 'ok - Gemini %s: live Herdr idle composer empty; read-only guard\n' "$version"
