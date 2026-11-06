#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-droid-afk-approval)
root="$TMP_ROOT/home"
mkdir -p "$root/bin" "$root/state"
printf '# fixture\n' >"$root/AGENTS.md"
printf 'fixture\n' >"$root/.fm-secondmate-home"
date +%s >"$root/state/.afk"

run_guard() {
  printf '%s' '{"tool_name":"AskUser","tool_input":{"questionnaire":"Approve?"}}' |
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
      bash "$ROOT/bin/fm-droid-afk-askuser-check.sh" >"$root/out" 2>"$root/err"
}

rc=0
run_guard || rc=$?
[ "$rc" -eq 2 ] || fail "AskUser must be denied while away: $rc"
[ ! -s "$root/out" ] || fail 'away denial wrote stdout'
jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("Do not retry")) and (.systemMessage | contains("ask the captain in plain text")) and (.systemMessage | contains("bin/fm-captain-hold.sh hold")) and (.systemMessage | contains("creating a new held task if needed")) and (.systemMessage | contains("continue other independently authorized work"))' "$root/err" >/dev/null || fail 'away denial omitted the decision procedure'
rm "$root/state/.afk"
rc=0
run_guard || rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$root/out" ] && [ ! -s "$root/err" ] || fail 'AskUser guard was not inert after return'
pass 'AskUser is denied while away and inert after return'
