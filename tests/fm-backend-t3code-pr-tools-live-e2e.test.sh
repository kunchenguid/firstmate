#!/usr/bin/env bash
# Prompt-submitting live guard for the t3code backend's Claude pull-request
# tool boundary (bin/backends/t3code.sh FM_BACKEND_T3CODE_PR_TOOLS_VERIFIED_FROM).
# On the real T3 server a home is signed in to, it launches one scratch Claude
# thread in a throwaway git project, asks it to call link_pull_request (an old
# merged upstream PR, linked only to that scratch thread), then
# list_thread_pull_requests and unlink_pull_request, and fails naming the T3
# and Claude Code versions unless the run completes with all three tools
# answered. The thread is archived afterwards; the scratch T3 project stays,
# because T3 refuses to delete a project that still holds an archived thread.
# Opt-in (it spends model tokens): FM_T3CODE_PR_TOOLS_LIVE=1 or FM_LIVE=1.
# The credential is FM_T3CODE_LIVE_TOKEN_FILE, else FM_CONFIG_OVERRIDE's, else
# this checkout's own config/t3code-token; FM_T3CODE_LIVE_CLAUDE_INSTANCE and
# FM_T3CODE_LIVE_CLAUDE_MODEL choose the thread's Claude instance and model.
# Refresh: FM_T3CODE_PR_TOOLS_LIVE=1 FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-pr-tools-live-e2e.test.sh
# docs/verification/runtime-backends.md "Claude pull-request tools" records its result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_T3CODE_PR_TOOLS_LIVE node git

TOKEN=${FM_T3CODE_LIVE_TOKEN_FILE:-${FM_CONFIG_OVERRIDE:-$ROOT/config}/t3code-token}
HELPER="$ROOT/bin/fm-t3-mcp.mjs"
INSTANCE=${FM_T3CODE_LIVE_CLAUDE_INSTANCE:-claudeAgent}
MODEL=${FM_T3CODE_LIVE_CLAUDE_MODEL:-claude-haiku-5-5}
PR_URL=https://github.com/kunchenguid/firstmate/pull/1
[ -f "$TOKEN" ] || fail "FM_T3CODE_PR_TOOLS_LIVE was requested but there is no T3 credential at $TOKEN"

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}
mcp() { node "$HELPER" "$@" --token-file "$TOKEN" 2>/dev/null; }

status=$(mcp status) || fail "T3 status refused: $status"
version=$(field "$status" serverVersion)
claude_version=$(claude --version 2>/dev/null | head -1)
label="T3 $version with ${claude_version:-an unknown Claude Code} ($INSTANCE $MODEL)"

TMP_ROOT=$(fm_test_tmproot fm-t3code-pr-tools-live)
THREAD=
cleanup() {
  [ -z "$THREAD" ] || mcp archive --thread "$THREAD" >/dev/null || printf 'warning: archive the scratch T3 thread %s in T3 Code\n' "$THREAD" >&2
  fm_test_cleanup
}
trap cleanup EXIT
git init -q -b main "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
project=$(field "$(mcp project-ensure --root "$TMP_ROOT/project" --title fm-live-pr-tools)" projectId)
[ -n "$project" ] || fail "$label: could not create the scratch T3 project"
printf '%s\n' "This is a scratch check of the T3 Code host tools. Call link_pull_request once for this thread with the URL $PR_URL, then call list_thread_pull_requests once, then call unlink_pull_request once for that same PR, then reply with one line per call saying what it returned. Do not call any other tool and do not edit files." > "$TMP_ROOT/message"
launched=$(mcp launch --project "$project" --title fm-live-pr-tools \
  --model-selection "{\"instanceId\":\"$INSTANCE\",\"model\":\"$MODEL\"}" --message-file "$TMP_ROOT/message") \
  || fail "$label: the scratch Claude thread did not launch: $launched"
THREAD=$(field "$launched" threadId)
run=$(field "$launched" runId)
waited=$(mcp wait --thread "$THREAD" --run "$run" --timeout-ms 300000) || fail "$label: the run could not be awaited: $waited"
[ "$(field "$waited" status)" = completed ] || fail "$label: the Claude run calling T3's pull-request tools ended $(field "$waited" status), not completed"
activity=$(mcp capture --thread "$THREAD" --lines 40)
for tool in link_pull_request list_thread_pull_requests unlink_pull_request; do
  printf '%s\n' "$activity" | grep -F '[dynamic_tool/completed]' | grep -qF "__$tool\"" \
    || fail "$label: the Claude session never completed a $tool call"$'\n'"$activity"
done
pass "t3code live: $label ran link_pull_request, list_thread_pull_requests, and unlink_pull_request in a Claude thread without a crash"
