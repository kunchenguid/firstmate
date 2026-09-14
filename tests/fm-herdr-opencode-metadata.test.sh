#!/usr/bin/env bash
# Unit test for bin/fm-herdr-opencode-metadata.sh model name shortening.
# Exercises the shorten_model function against the known OpenCode model IDs
# and verifies the helper script exits cleanly when herdr is absent.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-herdr-opencode-metadata.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

[ -x "$SCRIPT" ] || fail "script not executable: $SCRIPT"

# Source the shorten_model function from the script.
# The function is self-contained so we can eval it in isolation.
shorten_model_src=$(sed -n '/^shorten_model() {$/,/^}$/p' "$SCRIPT")
[ -n "$shorten_model_src" ] || fail "could not extract shorten_model function"
eval "$shorten_model_src" || fail "could not eval shorten_model function"

assert_short() {
  local input=$1 expected=$2 actual
  actual=$(shorten_model "$input")
  [ "$actual" = "$expected" ] \
    || fail "shorten_model '$input': expected '$expected', got '$actual'"
}

# Known OpenCode model IDs from opencode models output.
assert_short "muse-spark-1.3-contributor-free" "muse 1.3 free"
assert_short "muse-spark-1.2-contributor-free" "muse 1.2 free"
assert_short "big-pickle" "big pickle"
assert_short "nemotron-3-ultra-free" "nemotron 3 ultra free"
assert_short "nemotron-3.5-lightning-free" "nemotron 3.5 free"
assert_short "ling-3.0-flash-fin-free" "ling 3.0 flash free"
assert_short "mimo-v2.5-free" "mimo v2.5 free"

# Empty input should not crash.
assert_short "" ""

# Verify the script exits cleanly when called with no pane (no herdr call).
output=$("$SCRIPT" "" "muse-spark-1.3-contributor-free" 2>&1) || true
[ -z "$output" ] || fail "script with empty pane should produce no output, got: $output"

# Verify the script exits cleanly when called with no model.
output=$("$SCRIPT" "fake:pane" "" 2>&1) || true
[ -z "$output" ] || fail "script with empty model should produce no output, got: $output"

printf 'ok - fm-herdr-opencode-metadata model shortening and edge cases\n'
