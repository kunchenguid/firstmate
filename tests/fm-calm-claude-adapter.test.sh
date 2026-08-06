#!/usr/bin/env bash
# Public regression for the shared Calm preference and Claude SessionStart nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-calm-claude-adapter)
CALM="$ROOT/bin/fm-calm.sh"
NUDGE="$ROOT/bin/fm-claude-calm-nudge.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local root=$1
  mkdir -p "$root/bin" "$root/state" "$root/config"
  git init -q "$root"
  git -C "$root" commit -q --allow-empty -m init
  : > "$root/AGENTS.md"
}

run_calm() {
  local config=$1
  shift
  FM_CONFIG_OVERRIDE="$config" "$CALM" "$@"
}

run_nudge() {
  local root=$1
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_CONFIG_OVERRIDE="$root/config" "$NUDGE"
}

sessionstart_commands() {
  local source=$1
  node - "$ROOT/.claude/settings.json" "$source" <<'JS'
const fs = require("fs");

const settings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const source = process.argv[3];
for (const group of settings.hooks?.SessionStart ?? []) {
  if (group.matcher && !new RegExp(group.matcher).test(source)) continue;
  for (const hook of group.hooks ?? []) {
    const executable = hook.command?.match(/\/bin\/([^\s"]+)/)?.[1];
    if (executable) process.stdout.write(`${executable}\n`);
  }
}
JS
}

test_preference_commands() {
  local config="$TMP_ROOT/preference/config" home="$TMP_ROOT/preference/home" out status=0
  out=$(run_calm "$config" status) || status=$?
  expect_code 0 "$status" "absent preference status"
  [ "$out" = off ] || fail "absent preference must default off, got: $out"

  mkdir -p "$config"
  printf 'not-a-preference\n' > "$config/calm"
  [ "$(run_calm "$config" status)" = off ] || fail "unrecognized preference must default off"
  [ "$(run_calm "$config" toggle)" = on ] || fail "toggle did not activate Calm"
  [ "$(od -An -tx1 "$config/calm" | tr -d ' \n')" = 6f6e0a ] || fail "active preference was not persisted exactly"
  [ "$(run_calm "$config" off)" = off ] || fail "off command did not deactivate Calm"
  [ "$(od -An -tx1 "$config/calm" | tr -d ' \n')" = 6f66660a ] || fail "inactive preference was not persisted exactly"

  out=$(FM_HOME="$home" "$CALM" on) || status=$?
  expect_code 0 "$status" "FM_HOME preference write"
  [ "$out" = on ] || fail "FM_HOME preference write did not report on"
  [ "$(od -An -tx1 "$home/config/calm" | tr -d ' \n')" = 6f6e0a ] || fail "FM_HOME preference was not persisted exactly"

  "$CALM" bogus >/dev/null 2>&1 && status=0 || status=$?
  expect_code 2 "$status" "invalid public preference command"
  pass "fm-calm: public commands default safely, persist exact values, and reject invalid input"
}

test_claude_adapter_registration() {
  local source commands
  for source in startup resume clear; do
    commands=$(sessionstart_commands "$source")
    [ "$commands" = $'fm-sessionstart-nudge.sh\nfm-claude-calm-nudge.sh' ] \
      || fail "Claude $source SessionStart routing changed unexpectedly: $commands"
  done
  for source in compact fork; do
    commands=$(sessionstart_commands "$source")
    [ "$commands" = 'fm-claude-calm-nudge.sh' ] \
      || fail "Claude $source must reload Calm without running the operational digest: $commands"
  done
  grep -Fq 'disable-model-invocation: true' "$ROOT/.claude/commands/calm.md" \
    || fail "Claude Calm command must remain user invoked"
  grep -Fq "\"\${CLAUDE_PROJECT_DIR}/bin/fm-calm.sh\" toggle" "$ROOT/.claude/commands/calm.md" \
    || fail "Claude Calm command does not invoke the public toggle"
  grep -Fq 'name: Firstmate Calm' "$ROOT/.claude/output-styles/firstmate-calm.md" \
    || fail "Claude Calm output style is not registered"
  grep -Fq 'keep-coding-instructions: true' "$ROOT/.claude/output-styles/firstmate-calm.md" \
    || fail "Claude Calm output style must preserve coding instructions"
  pass "Claude Calm reloads on startup, resume, clear, compact, and fork without widening the operational digest"
  pass "Claude Calm registers its native command and safe output style"
}

test_claude_nudge_scope_and_preference() {
  local root="$TMP_ROOT/primary" out status=0
  make_primary "$root"

  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm-off nudge"
  [ "$out" = 'Firstmate Calm presentation is inactive for this home. This supersedes any earlier Calm-active instruction in the transcript; use ordinary captain-facing presentation.' ] \
    || fail "Calm-off Claude nudge changed unexpectedly: $out"

  run_calm "$root/config" on >/dev/null
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm-on nudge"
  [ "$out" = 'Firstmate Calm presentation is active for this home. Keep captain-facing updates outcome-first, concise, and free of incidental progress narration while preserving every operational instruction, safety boundary, and technical fact that matters.' ] \
    || fail "Calm-on Claude nudge changed unexpectedly: $out"

  run_calm "$root/config" off >/dev/null
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm on-to-off nudge"
  [ "$out" = 'Firstmate Calm presentation is inactive for this home. This supersedes any earlier Calm-active instruction in the transcript; use ordinary captain-facing presentation.' ] \
    || fail "Calm on-to-off Claude nudge did not supersede stale active context: $out"

  out=$(FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=1 run_nudge "$root") || status=$?
  expect_code 0 "$status" "gate nudge"
  [ -z "$out" ] || fail "gate Claude nudge must stay silent: $out"

  git -C "$root" worktree add -q -b fm/calm-linked "$TMP_ROOT/linked" HEAD
  mkdir -p "$TMP_ROOT/linked/bin" "$TMP_ROOT/linked/state" "$TMP_ROOT/linked/config"
  : > "$TMP_ROOT/linked/AGENTS.md"
  run_calm "$TMP_ROOT/linked/config" on >/dev/null
  out=$(run_nudge "$TMP_ROOT/linked") || status=$?
  expect_code 0 "$status" "linked worktree nudge"
  [ -z "$out" ] || fail "linked task worktree must not receive a Claude Calm nudge: $out"
  pass "Claude Calm nudge follows the persisted preference only in a genuine primary home"
}

test_preference_commands
test_claude_nudge_scope_and_preference
test_claude_adapter_registration
