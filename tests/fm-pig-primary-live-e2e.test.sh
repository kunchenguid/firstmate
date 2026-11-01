#!/usr/bin/env bash
# Token-free live validation that supported PiG releases accept the Firstmate Go extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PIG_EXTENSION_LIVE_E2E pig jq go

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

version=$(pig --version 2>/dev/null | head -1)
case "$version" in
  0.4.1+*|0.5.3+*) ;;
  *) fail "expected PiG v0.4.1 or v0.5.3, found '${version:-no version output}'" ;;
esac

result=$(pig install --validate-only --json "$ROOT/.pig/extensions/firstmate" 2>&1) || \
  fail "PiG $version rejected the Firstmate Go extension: $result"
if ! printf '%s\n' "$result" | jq -e \
  --arg source "$ROOT/.pig/extensions/firstmate" \
  '.valid == true and .registered == true and .source == $source and .definition.language == "go" and .definition.sdk == "github.com/MichaelKinsy/PiG/extensions/sdk" and .definition.package == "github.com/MichaelKinsy/firstmate-pig-extension"' \
  >/dev/null; then
  fail "PiG $version returned an unexpected extension validation result: $result"
fi

pass "PiG $version validates and registers the Firstmate Go extension without a model prompt"
