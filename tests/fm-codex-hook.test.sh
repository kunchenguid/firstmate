#!/usr/bin/env bash
# Behavior tests for the tracked Codex hook transport, including cmd.exe's
# native Windows parsing path when that host is available.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-hook)
FIXTURE="$TMP_ROOT/firstmate root with spaces"
mkdir -p "$FIXTURE/bin" "$FIXTURE/.codex"
: > "$FIXTURE/AGENTS.md"
cp "$ROOT/.codex/hooks.json" "$FIXTURE/.codex/hooks.json"
cp "$ROOT/bin/fm-codex-hook.sh" "$FIXTURE/bin/fm-codex-hook.sh"
cp "$ROOT/bin/fm-codex-hook.cmd" "$FIXTURE/bin/fm-codex-hook.cmd"
chmod +x "$FIXTURE/bin/fm-codex-hook.sh"

for target in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-turnend-guard.sh; do
  cat > "$FIXTURE/bin/$target" <<'SH'
#!/usr/bin/env bash
printf 'target=%s\n' "$(basename "$0")"
cat
SH
  chmod +x "$FIXTURE/bin/$target"
done

exercise_hook() {  # <jq-path> <command-field> <expected-target>
  local query=$1 field=$2 expected=$3 command payload out status=0
  command=$(jq -r "$query.$field // empty" "$FIXTURE/.codex/hooks.json")
  [ -n "$command" ] || fail "$field is missing for $expected"
  payload=$(jq -cn --arg expected "$expected" '{hook_event_name:"fixture",expected:$expected}')
  if [ "$field" = commandWindows ]; then
    out=$(printf '%s' "$payload" | (cd "$FIXTURE" && MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /s /c "$command") 2>&1) || status=$?
  else
    out=$(printf '%s' "$payload" | (cd "$FIXTURE" && bash -c "$command") 2>&1) || status=$?
  fi
  [ "$status" -eq 0 ] || fail "$field transport for $expected exited $status: $out"
  assert_contains "$out" "target=$expected" "$field did not dispatch to $expected"
  assert_contains "$out" "$payload" "$field did not preserve stdin for $expected"
}

exercise_all() {  # <command-field>
  local field=$1
  exercise_hook '.hooks.SessionStart[0].hooks[0]' "$field" fm-sessionstart-run.sh
  exercise_hook '.hooks.PreToolUse[0].hooks[0]' "$field" fm-arm-pretool-check.sh
  exercise_hook '.hooks.PreToolUse[0].hooks[1]' "$field" fm-cd-pretool-check.sh
  exercise_hook '.hooks.Stop[0].hooks[0]' "$field" fm-turnend-guard.sh
}

exercise_all command
pass "Codex hook transport: POSIX commands dispatch all tracked hooks with stdin intact"

if command -v cmd.exe >/dev/null 2>&1; then
  exercise_all commandWindows
  pass "Codex hook transport: native Windows commands survive cmd.exe and preserve stdin"
else
  pass "Codex hook transport: native Windows command path skipped (cmd.exe unavailable)"
fi
