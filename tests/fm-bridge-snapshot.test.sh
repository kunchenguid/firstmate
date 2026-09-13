#!/usr/bin/env bash
# Behavior tests for the read-only bridge snapshot collector.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-bridge-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge-snapshot)
HOME_DIR="$TMP_ROOT/home"
WORKTREE="$TMP_ROOT/worktree"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CLAUDE_HOME="$TMP_ROOT/claude-home"
PROCESS_FIXTURE="$TMP_ROOT/processes.json"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$WORKTREE" \
  "$CLAUDE_HOME/.claude/projects/-tmp--treehouse-claude-work" "$CLAUDE_HOME/.codex/sessions/2026/09/13"

cat > "$FAKEBIN/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-09-13T00:00:00Z",
  "fm_home": "__HOME__",
  "backlog": {"records": [
    {"state":"in_flight"},
    {"state":"queued","id":"ready"},
    {"state":"queued","id":"held","hold_kind":"captain"},
    {"state":"queued","id":"blocked","unresolved_blocker_ids":["x"]}
  ]},
  "tasks": [
    {
      "id":"claude-task",
      "kind":"ship",
      "harness":"claude",
      "backend":"herdr",
      "project":"demo",
      "paths":{
        "meta":{"path":"__HOME__/state/claude-task.meta","present":true},
        "status_log":{"last_event":{"state":"working","note":"building the thing","raw":"working: building the thing"}},
        "worktree":{"path":"/tmp/.treehouse/claude-work","present":true},
        "home":{"path":null,"present":false}
      },
      "current_state":{"state":"working"},
      "endpoint":{"status":"alive"},
      "pr":{"url":null}
    },
    {
      "id":"codex-task",
      "kind":"scout",
      "harness":"codex",
      "backend":"herdr",
      "project":"demo",
      "paths":{
        "meta":{"path":"__HOME__/state/codex-task.meta","present":true},
        "status_log":{"last_event":{"state":"done","note":"finished","raw":"done: finished"}},
        "worktree":{"path":"__WORKTREE__","present":true},
        "home":{"path":null,"present":false}
      },
      "current_state":{"state":"done"},
      "endpoint":{"status":"unknown"},
      "pr":{"url":"https://example.test/pr/1"}
    },
    {
      "id":"mate-one",
      "kind":"secondmate",
      "paths":{"meta":{"path":null,"present":false},"status_log":{"last_event":null},"worktree":{"path":null,"present":false},"home":{"path":"__MATE_HOME__","present":true}},
      "current_state":{"state":"working"},
      "endpoint":{"status":"alive"}
    }
  ]
}
JSON
SH
python3 - "$FAKEBIN/fm-fleet-snapshot.sh" "$HOME_DIR" "$WORKTREE" "$TMP_ROOT/mate-home" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace("__HOME__", sys.argv[2]).replace("__WORKTREE__", sys.argv[3]).replace("__MATE_HOME__", sys.argv[4])
path.write_text(text)
PY
chmod +x "$FAKEBIN/fm-fleet-snapshot.sh"

cat > "$HOME_DIR/state/claude-task.meta" <<'EOF'
model=claude-sonnet-4
effort=high
EOF
cat > "$HOME_DIR/state/codex-task.meta" <<EOF
model=gpt-5.5
effort=high
worktree=$WORKTREE
spawn_gen=s1700000000.123.1
EOF

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2026-09-13T00:00:01Z",
  "providers": [{
    "provider": "claude",
    "state": {"status": "fresh"},
    "windows": [{"id":"seven_day","resetsAt":"2026-09-14T00:00:00Z"}],
    "quotaSemantics": {"effectiveAvailability": [{
      "scope": "all_models",
      "effectivePercentRemaining": 5,
      "limitingWindowIds": ["seven_day"],
      "runway": {"status":"through_reset"},
      "selection": {"spendPriority": 2.88}
    }]}
  }]
}
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$PWD" in
  */worktree)
    cat <<'EOF'
current_run:
  id: "run-codex"
  branch: fm/example
  status: running
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,100
    test,running,1,200
EOF
    ;;
  *)
    printf 'No run exists for this branch\n'
    ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

cat > "$FAKEBIN/fm-upstream-sync.sh" <<'SH'
#!/usr/bin/env bash
printf 'upstream: 3 new commits not in origin/main\n'
SH
chmod +x "$FAKEBIN/fm-upstream-sync.sh"

cat > "$CLAUDE_HOME/.claude/projects/-tmp--treehouse-claude-work/session.jsonl" <<'EOF'
{"timestamp":"2026-09-13T00:00:02Z","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":7}}}
{"timestamp":"2026-09-13T00:00:03Z","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40,"output_tokens":8}}}
EOF

cat > "$CLAUDE_HOME/.codex/sessions/2026/09/13/session.jsonl" <<EOF
{"type":"event_msg","timestamp":"2026-09-13T00:00:00Z","payload":{"type":"task_started","model_context_window":1000}}
{"type":"event_msg","timestamp":"2026-09-13T00:00:01Z","payload":{"state":{"cwd":"$WORKTREE"}}}
{"type":"event_msg","timestamp":"2026-09-13T00:00:04Z","payload":{"type":"token_count","info":{"model_context_window":1000,"last_token_usage":{"input_tokens":250},"total_token_usage":{"total_tokens":900,"output_tokens":50}}}}
EOF

cat > "$PROCESS_FIXTURE" <<EOF
[
  {"pid":111,"ppid":1,"elapsed_seconds":15,"comm":"codex","command":"codex gpt-5.6-terra","cwd":"$TMP_ROOT/outside"},
  {"pid":112,"ppid":1,"elapsed_seconds":16,"comm":"codex","command":"codex recorded","cwd":"$WORKTREE"},
  {"pid":113,"ppid":1,"elapsed_seconds":17,"comm":"claude","command":"claude nm","cwd":"$CLAUDE_HOME/.no-mistakes/run"},
  {"pid":114,"ppid":111,"elapsed_seconds":18,"comm":"codex","command":"codex native child","cwd":"$TMP_ROOT/outside"},
  {"pid":115,"ppid":1,"elapsed_seconds":19,"comm":"bg-pty-host","command":"claude bg-pty-host --bg-pty-host","cwd":"$TMP_ROOT/outside"}
]
EOF

run_snapshot() {
  PATH="$FAKEBIN:$PATH" HOME="$CLAUDE_HOME" FM_HOME="$HOME_DIR" \
    FM_BRIDGE_FLEET_SNAPSHOT_BIN="$FAKEBIN/fm-fleet-snapshot.sh" \
    FM_BRIDGE_UPSTREAM_SYNC_BIN="$FAKEBIN/fm-upstream-sync.sh" \
    FM_BRIDGE_PROCESS_FIXTURE="$PROCESS_FIXTURE" \
    "$SNAPSHOT" "$@"
}

out=$(run_snapshot --json) || fail "bridge snapshot failed"
printf '%s\n' "$out" > "$TMP_ROOT/out.json"
jq -e --arg home "$HOME_DIR" '
  .schema == "fm-bridge-snapshot.v1"
  and .fm_home == $home
  and .quota.ok == true
  and .quota.providers[0].percent_remaining == 5
  and .backlog == {"in_flight":1,"held":1,"ready":1,"blocked":1}
  and (.agents | length) == 4
  and (.agents[] | select(.id == "primary" and .kind == "primary"))
  and (.agents[] | select(.id == "claude-task").context.current_tokens == 90)
  and (.agents[] | select(.id == "claude-task").context.peak_tokens == 90)
  and (.agents[] | select(.id == "claude-task").tokens.output == 15)
  and (.agents[] | select(.id == "codex-task").context.current_tokens == 250)
  and (.agents[] | select(.id == "codex-task").context.percent == 25)
  and (.agents[] | select(.id == "codex-task").started_at == "2023-11-14T22:13:20Z")
  and (.agents[] | select(.id == "codex-task").validation.current_step == "test")
  and (.agents[] | select(.id == "mate-one" and .kind == "secondmate" and .current_state == "working"))
  and (.unrecorded_agents | length) == 1
  and .unrecorded_agents[0].pid == 111
  and .upstream.status == "behind"
' "$TMP_ROOT/out.json" >/dev/null || fail "snapshot schema or measured fields were wrong"
pass "bridge snapshot emits contract fields from fixture sources"

out=$(run_snapshot --json --no-network) || fail "bridge snapshot --no-network failed"
printf '%s\n' "$out" > "$TMP_ROOT/no-network.json"
jq -e '.upstream.status == "skipped" and (.sources[] | select(.name == "fm-upstream-sync").error == "skipped")' \
  "$TMP_ROOT/no-network.json" >/dev/null || fail "--no-network did not skip upstream"
pass "bridge snapshot skips upstream on request"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'quota exploded\n' >&2
exit 17
SH
chmod +x "$FAKEBIN/quota-axi"

out=$(run_snapshot --json --no-network) || fail "bridge snapshot should isolate quota failure"
printf '%s\n' "$out" > "$TMP_ROOT/quota-fail.json"
jq -e '
  .quota.ok == false
  and .quota.error != null
  and (.agents | length) == 4
  and (.sources[] | select(.name == "quota-axi").ok == false)
' "$TMP_ROOT/quota-fail.json" >/dev/null || fail "failing quota source was not isolated"
pass "bridge snapshot isolates a failing source"
