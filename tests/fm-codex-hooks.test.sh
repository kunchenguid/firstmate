#!/usr/bin/env bash
# Executable-interface regression for the tracked Codex lifecycle hooks.
#
# Each target script owns stdin acquisition, host and checkout scoping, policy
# evaluation, and fail-open behavior.
# The hook registration must therefore invoke that script directly.
# Starting a nested login shell first sources operator profiles, which can block
# on unrelated credential or network setup and exhaust a hook timeout before
# either safety policy runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-hooks)
LAB="$TMP_ROOT/lab"
FAKEBIN="$TMP_ROOT/fakebin"
TRACE="$TMP_ROOT/trace"
LOGIN_TRACE="$TMP_ROOT/login-shell-trace"
mkdir -p "$LAB/.codex" "$LAB/bin" "$FAKEBIN"
cp "$ROOT/.codex/hooks.json" "$LAB/.codex/hooks.json"

make_target() {
  local script=$1
  cat > "$LAB/bin/$script" <<'SH'
#!/bin/sh
payload=$(cat)
printf '%s\t%s\n' "${0##*/}" "$payload" >> "${FM_CODEX_HOOK_TEST_TRACE:?}"
exit 0
SH
  chmod +x "$LAB/bin/$script"
}

for script in fm-sessionstart-run.sh fm-arm-pretool-check.sh \
  fm-cd-pretool-check.sh fm-turnend-guard.sh; do
  make_target "$script"
done

# Any nested bash is a regression.
# This deterministic trap represents the login-shell profile path that caused
# the production timeout without relying on a real profile or network.
cat > "$FAKEBIN/bash" <<'SH'
#!/bin/sh
printf 'nested bash invoked: %s\n' "$*" >> "${FM_CODEX_HOOK_LOGIN_TRACE:?}"
exit 97
SH
chmod +x "$FAKEBIN/bash"

run_hook() {
  local event=$1 index=$2 expected_script=$3 payload command out rc line
  payload=$(printf '{"hook_event_name":"%s","case":%s}' "$event" "$index")
  command=$(jq -er --arg event "$event" --argjson index "$index" \
    '.hooks[$event][0].hooks[$index].command | select(type == "string" and length > 0)' \
    "$LAB/.codex/hooks.json") \
    || fail "$event hook $index has no executable command"

  out=$(
    cd "$LAB" &&
      printf '%s' "$payload" |
        PATH="$FAKEBIN:$PATH" \
          FM_CODEX_HOOK_TEST_TRACE="$TRACE" \
          FM_CODEX_HOOK_LOGIN_TRACE="$LOGIN_TRACE" \
          /bin/sh -c "$command" 2>&1
  )
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "$event hook $index exited $rc instead of invoking $expected_script directly: $out"
  [ -z "$out" ] || fail "$event hook $index produced unexpected output: $out"
  [ ! -e "$LOGIN_TRACE" ] \
    || fail "$event hook $index started a nested shell before $expected_script: $(cat "$LOGIN_TRACE")"

  line=$(tail -n 1 "$TRACE" 2>/dev/null) \
    || fail "$event hook $index did not invoke $expected_script"
  [ "$line" = "$expected_script"$'\t'"$payload" ] \
    || fail "$event hook $index did not forward stdin unchanged to $expected_script: $line"
  pass "$event hook $index invokes $expected_script directly and preserves stdin"
}

run_hook SessionStart 0 fm-sessionstart-run.sh
run_hook PreToolUse 0 fm-arm-pretool-check.sh
run_hook PreToolUse 1 fm-cd-pretool-check.sh
run_hook Stop 0 fm-turnend-guard.sh

[ "$(wc -l < "$TRACE" | tr -d ' ')" -eq 4 ] \
  || fail "the four Codex lifecycle hooks did not each invoke exactly one target"

echo "# fm-codex-hooks.test.sh: all assertions passed"
