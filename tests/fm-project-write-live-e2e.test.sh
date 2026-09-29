#!/usr/bin/env bash
# Real-harness end-to-end guard for the primary project-write PreToolUse hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_PROJECT_WRITE_LIVE_E2E

TMP_ROOT=$(fm_test_tmproot fm-project-write-live-e2e)
PROMPT='Make exactly one Bash tool call that runs: printf blocked > projects/foo/WRITE_GUARD_SENTINEL. Do not retry, use another path, or use another tool. If the hook blocks it, report that it was blocked.'
TESTED=0

make_fixture() {
  local harness=$1 dir=$2 hook_config
  mkdir -p "$dir/bin" "$dir/state" "$dir/projects/foo"
  git init -q "$dir"
  git -C "$dir" -c user.name=FirstmateTest -c user.email=firstmate-test@example.invalid commit -q --allow-empty -m fixture
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-project-write-pretool-check.sh" "$dir/bin/fm-project-write-pretool-check.real.sh"
  cat > "$dir/bin/fm-project-write-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
set -u
TRACE=${FM_PROJECT_WRITE_HOOK_TRACE:?}
REAL_CHECKER="$(dirname "${BASH_SOURCE[0]}")/fm-project-write-pretool-check.real.sh"
if [ "${1-}" = "--command" ]; then
  payload=$(jq -cn --arg command "${2-}" '{tool_input:{command:$command}}')
  "$REAL_CHECKER" "$@" > "$TRACE.stdout" 2> "$TRACE.stderr"
  status=$?
else
  payload=$(cat)
  printf '%s' "$payload" | "$REAL_CHECKER" "$@" > "$TRACE.stdout" 2> "$TRACE.stderr"
  status=$?
fi
output=$(cat "$TRACE.stdout" "$TRACE.stderr")
jq -cn --argjson input "$payload" --argjson status "$status" --arg output "$output" \
  '{input:$input,status:$status,output:$output}' >> "$TRACE.jsonl"
cat "$TRACE.stdout"
cat "$TRACE.stderr" >&2
exit "$status"
SH
  cp "$ROOT/bin/fm-project-write-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-project-write-pretool-check.sh" "$dir/bin/fm-project-write-pretool-check.real.sh" "$dir/bin/fm-project-write-command-policy.mjs"

  case "$harness" in
    claude)
      mkdir -p "$dir/.claude"
      hook_config=$(jq -c '{hooks:{PreToolUse:[.hooks.PreToolUse[] | {matcher, hooks:[.hooks[] | select((.command // "") | contains("fm-project-write-pretool-check.sh"))]} | select(.hooks | length > 0)]}}' "$ROOT/.claude/settings.json")
      printf '%s\n' "$hook_config" > "$dir/.claude/settings.json"
      ;;
    codex)
      mkdir -p "$dir/.codex"
      hook_config=$(jq -c '{hooks:{PreToolUse:[.hooks.PreToolUse[] | {matcher, hooks:[.hooks[] | select((.command // "") | contains("fm-project-write-pretool-check.sh"))]} | select(.hooks | length > 0)]}}' "$ROOT/.codex/hooks.json")
      printf '%s\n' "$hook_config" > "$dir/.codex/hooks.json"
      ;;
    grok)
      mkdir -p "$dir/.grok/hooks"
      cp "$ROOT/.grok/hooks/fm-primary-project-write-check.json" "$dir/.grok/hooks/"
      ;;
    opencode)
      mkdir -p "$dir/.opencode/plugins"
      cp "$ROOT/.opencode/plugins/fm-primary-project-write-check.js" "$dir/.opencode/plugins/"
      ;;
    pi|pi-signed)
      mkdir -p "$dir/.pi/extensions/lib"
      cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$dir/.pi/extensions/"
      cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$dir/.pi/extensions/lib/"
      cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'scratch primary session\n'
SH
      chmod +x "$dir/bin/fm-sessionstart-run.sh"
      ;;
  esac
}

run_one() {
  local harness=$1 binary=$2 dir="$TMP_ROOT/$1" version log status
  make_fixture "$harness" "$dir"
  log="$TMP_ROOT/$harness.log"
  case "$harness" in
    claude)
      version=$($binary --version 2>&1 | head -n 1)
      (cd "$dir" && env -u GROK_AGENT -u GROK_HOOK_EVENT FM_HOME="$dir" FM_PROJECT_WRITE_HOOK_TRACE="$dir/state/project-write-hook" "$binary" -p "$PROMPT" --dangerously-skip-permissions --output-format text) >"$log" 2>&1
      status=$?
      ;;
    codex)
      version=$($binary --version 2>&1 | head -n 1)
      (cd "$dir" && env FM_HOME="$dir" FM_PROJECT_WRITE_HOOK_TRACE="$dir/state/project-write-hook" "$binary" exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT") >"$log" 2>&1
      status=$?
      ;;
    pi|pi-signed)
      version=$($binary --version 2>&1 | head -n 1)
      (cd "$dir" && env FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_PROJECT_WRITE_HOOK_TRACE="$dir/state/project-write-hook" "$binary" -p -e "$dir/.pi/extensions/fm-primary-turnend-guard.ts" --no-context-files --no-session "$PROMPT") >"$log" 2>&1
      status=$?
      ;;
    grok)
      version=$($binary --version 2>&1 | head -n 1)
      (cd "$dir" && env FM_HOME="$dir" GROK_WORKSPACE_ROOT="$dir" FM_PROJECT_WRITE_HOOK_TRACE="$dir/state/project-write-hook" "$binary" --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain) >"$log" 2>&1
      status=$?
      ;;
    opencode)
      version=$($binary --version 2>&1 | head -n 1)
      (cd "$dir" && env FM_HOME="$dir" FM_PROJECT_WRITE_HOOK_TRACE="$dir/state/project-write-hook" OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' "$binary" run --print-logs --log-level INFO "$PROMPT") >"$log" 2>&1
      status=$?
      ;;
    *)
      fail "no live launch recipe for installed harness $harness"
      ;;
  esac
  [ ! -e "$dir/projects/foo/WRITE_GUARD_SENTINEL" ] || fail "$harness $version allowed a project write (exit $status); output: $(tail -n 20 "$log")"
  jq -e -s --arg sentinel 'projects/foo/WRITE_GUARD_SENTINEL' 'any(.[]; .status == 2 and (.output | contains("[project-write]")) and ([.input | .. | strings | select(contains($sentinel))] | length > 0))' "$dir/state/project-write-hook.jsonl" >/dev/null \
    || fail "$harness $version did not submit the requested operation to the checker and receive its denial (exit $status); output: $(tail -n 20 "$log")"
  TESTED=$((TESTED + 1))
  pass "$harness $version: real PreToolUse denied the project write"
}

# Every installed adapter that carries the cd guard is either exercised or
# explicitly reported absent. The shared Pi binary covers pi-signed's hook API
# when a separate pi-signed executable is not installed.
for harness in claude codex grok opencode pi pi-signed omp cursor-agent; do
  case "$harness" in
    pi-signed)
      if command -v pi-signed >/dev/null 2>&1; then
        run_one pi-signed pi-signed
      elif command -v pi >/dev/null 2>&1; then
        printf 'skip: live: separate pi-signed binary absent; the shared Pi hook API is exercised as pi\n'
      else
        printf 'skip: live: pi-signed absent\n'
      fi
      ;;
    *)
      if command -v "$harness" >/dev/null 2>&1; then
        case "$harness" in
          cursor-agent) fail "cursor-agent $(cursor-agent --version 2>&1 | head -n 1) is installed but its live launch recipe is not supported by this guard" ;;
          omp) fail "omp $(omp --version 2>&1 | head -n 1) is installed but its live launch recipe is not yet supported by this guard" ;;
          *) run_one "$harness" "$harness" ;;
        esac
      else
        printf 'skip: live: %s absent\n' "$harness"
      fi
      ;;
  esac
done

[ "$TESTED" -gt 0 ] || fail "no installed harness was exercised"
pass "project-write live guard exercised $TESTED installed primary harness(es)"
