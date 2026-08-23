#!/usr/bin/env bash
# Generated-interface coverage for exact-worker NoMistakes ownership.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-ownership)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
printf '%s\n' '- sample [direct-PR] - fixture' > "$HOME_DIR/data/projects.md"

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" owned-run sample --no-mistakes >/dev/null
BRIEF="$HOME_DIR/data/owned-run/brief.md"

assert_grep "$ROOT/bin/fm-no-mistakes.sh run owned-run" "$BRIEF" \
  "explicit brief does not assign run startup to the bounded worker interface"
assert_grep "$ROOT/bin/fm-no-mistakes.sh respond owned-run" "$BRIEF" \
  "explicit brief does not return decisions to the same bounded worker interface"
assert_grep 'Firstmate returns the answer to this exact worker' "$BRIEF" \
  "generated ownership contract permits a general Firstmate session to impersonate the worker"
assert_grep 'needs-decision [key=nm-owned-run-<finding-id>]' "$BRIEF" \
  "generated ownership contract lost keyed decision routing"
# shellcheck disable=SC2016 # Backticks are literal generated-brief text.
assert_grep 'Do not invoke `no-mistakes axi run`, `axi respond`, or /no-mistakes directly' "$BRIEF" \
  "generated ownership contract permits bypassing the bounded lifecycle"
pass "explicit NoMistakes brief assigns decisions and drive calls to the exact owning worker"
