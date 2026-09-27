#!/usr/bin/env bash
# Execute the maintained selection boundary and preserve historical task work.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-support)
mkdir -p "$TMP_ROOT/home/config" "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/project"
trap 'rm -rf "$TMP_ROOT"' EXIT
# Refusal regressions must never reach a real multiplexer or worktree allocator.
mkdir -p "$TMP_ROOT/fakebin"
for tool in herdr tmux treehouse; do
  printf '#!/bin/sh\nexit 99\n' > "$TMP_ROOT/fakebin/$tool"
  chmod +x "$TMP_ROOT/fakebin/$tool"
done
export PATH="$TMP_ROOT/fakebin:$PATH" FM_BACKEND=herdr
HARNESS="$ROOT/bin/fm-harness.sh"
REMOVED='claude opencode grok kimi cursor gemini muse rovo omp agy pi-signed'
for harness in pi codex traex; do
  out=$("$HARNESS" validate "$harness" 2>&1); rc=$?
  expect_code 0 "$rc" "supported identity $harness must validate: $out"
  printf '%s\n' "$harness" > "$TMP_ROOT/home/config/crew-harness"
  out=$(FM_HOME="$TMP_ROOT/home" "$HARNESS" crew)
  [ "$out" = "$harness" ] || fail "configured $harness resolved as $out"
done
pass 'selection preserves all three exact supported identities'
for harness in $REMOVED; do
  printf '%s\n' "$harness" > "$TMP_ROOT/home/config/crew-harness"
  out=$(FM_HOME="$TMP_ROOT/home" "$HARNESS" crew 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported crew-harness=$harness silently accepted"
  assert_contains "$out" 'unsupported harness' 'config refusal must be actionable'
  out=$(FM_HOME="$TMP_ROOT/home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" rejected "$TMP_ROOT/project" --harness "$harness" --scout 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "removed launch $harness accepted"
  assert_contains "$out" "unsupported harness" "launch refusal must identify the unsupported selection"
  assert_absent "$TMP_ROOT/home/state/rejected.meta" 'refusal must not publish a task'
done
pass 'removed configured and explicit selections refuse without publishing work'
for command in "claude --model example" "bash -lc 'grok;'" 'env X=1 /opt/old/opencode run' 'bash -lc "pi-signed"'; do
  out=$(FM_HOME="$TMP_ROOT/home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" rejected "$TMP_ROOT/project" "$command" --scout 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "removed raw command accepted: $command"
  assert_contains "$out" 'removed harness command' 'raw refusal must identify the excluded command'
  assert_absent "$TMP_ROOT/home/state/rejected.meta" 'raw refusal must not publish a task'
done
pass 'ordinary shell wrapping cannot re-enable an excluded harness'

rm -f "$TMP_ROOT/home/config/crew-harness"
for harness in $REMOVED; do
  printf 'backend=herdr\nharness=%s\nkind=ship\nworktree=%s\nwindow=isolated:w1:p-history\nendpoint_task_id=history\n' "$harness" "$TMP_ROOT/project" > "$TMP_ROOT/home/state/history.meta"
  printf 'uncommitted historical work\n' > "$TMP_ROOT/project/work.txt"
  cp "$TMP_ROOT/home/state/history.meta" "$TMP_ROOT/before.meta"
  out=$(FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-crew-state.sh" history 2>&1); rc=$?
  expect_code 0 "$rc" "historical $harness should remain readable: $out"
  assert_contains "$out" 'historical harness' 'historical state must explain its support boundary'
  for verb in interrupt exit relaunch; do
    out=$(FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-control.sh" history "$verb" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "historical $harness $verb must refuse"
    cmp -s "$TMP_ROOT/before.meta" "$TMP_ROOT/home/state/history.meta" || fail 'control changed historical metadata'
  done
  out=$(FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-teardown.sh" history 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "historical $harness teardown must refuse"
  cmp -s "$TMP_ROOT/before.meta" "$TMP_ROOT/home/state/history.meta" || fail 'teardown changed historical metadata'
  [ "$(cat "$TMP_ROOT/project/work.txt")" = 'uncommitted historical work' ] || fail 'historical work was changed'
done
pass 'historical records remain readable and lifecycle refusals preserve records and uncommitted work'
