#!/usr/bin/env bash
# A secondmate home with config/runtime-pin keeps its own crew-harness and
# crew-dispatch.json; a home without the pin still inherits them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-runtime-pin)

setup_pair() {
  local name=$1
  P="$TMP_ROOT/$name/primary/config"
  S="$TMP_ROOT/$name/second/config"
  mkdir -p "$P" "$S"
  printf 'kiro-cli\n' > "$P/crew-harness"
  printf '{"primary":true}\n' > "$P/crew-dispatch.json"
  printf 'herdr\n' > "$P/backend"
}

setup_pair pinned
printf 'pi\n' > "$S/crew-harness"
printf '{"own":true}\n' > "$S/crew-dispatch.json"
: > "$S/runtime-pin"
propagate_inheritable_config "$P" "$S" 2>/dev/null
[ "$(cat "$S/crew-harness")" = pi ] || fail "pinned home lost its crew-harness"
[ "$(cat "$S/crew-dispatch.json")" = '{"own":true}' ] || fail "pinned home lost its crew-dispatch.json"
[ "$(cat "$S/backend")" = herdr ] || fail "pinned home should still inherit unpinned items"

rm -f "$P/crew-harness" "$P/crew-dispatch.json"
propagate_inheritable_config "$P" "$S" 2>/dev/null
[ "$(cat "$S/crew-harness")" = pi ] || fail "primary absence removed the pinned crew-harness"
[ -f "$S/crew-dispatch.json" ] || fail "primary absence removed the pinned crew-dispatch.json"
pass "pinned home keeps its own crew-harness and crew-dispatch.json"

setup_pair unpinned
printf 'pi\n' > "$S/crew-harness"
propagate_inheritable_config "$P" "$S" 2>/dev/null
[ "$(cat "$S/crew-harness")" = kiro-cli ] || fail "unpinned home did not inherit crew-harness"
[ "$(cat "$S/crew-dispatch.json")" = '{"primary":true}' ] || fail "unpinned home did not inherit crew-dispatch.json"
pass "unpinned home still inherits crew-harness and crew-dispatch.json"

setup_pair remote
mkdir -p "$TMP_ROOT/remote/second/data"
printf 'pi\n' > "$S/crew-harness"
: > "$S/runtime-pin"
sha=$(printf 'kiro-cli\n' | sha256sum | awk '{print $1}')
out=$(printf 'kiro-cli\n' | FM_HOME="$TMP_ROOT/remote/second" "$ROOT/bin/fm-remote-inherit.sh" put config/crew-harness 9 "$sha" 1)
[ "$out" = "unchanged: config/crew-harness" ] || fail "remote receiver output: $out"
[ "$(cat "$S/crew-harness")" = pi ] || fail "remote receiver overwrote the pinned crew-harness"
pass "remote receiver keeps a pinned crew-harness"
