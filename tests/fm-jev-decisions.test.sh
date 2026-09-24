#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-decisions.sh: appending decision records,
# recording the supervisor's outcome from a spawn or by hand, and the per-class
# report. Drives only the public argv interface against an isolated FM_HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-decisions.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-decisions)
HOME_DIR="$TMP_ROOT/home"
JEV_LOG="$HOME_DIR/state/jev-decisions.jsonl"
mkdir -p "$HOME_DIR/state"
umask 022

jev() { FM_HOME="$HOME_DIR" "$TOOL" "$@"; }

decision() { # <id> <task> <status> <choice_when> [<profile json>]
  jq -c -n --arg id "$1" --arg task "$2" --arg status "$3" --arg when "$4" --argjson profile "${5:-null}" '
    {schema_version: 1, kind: "decision", decision_id: $id, at: 1, surface: "dispatch-resolve",
     question_id: "dispatch.rule", task: $task, choice_when: $when, status: $status,
     tokens: {input_tokens: 900, output_tokens: 60}, profile: $profile}'
}

E1='Escalation E1, bounded adjudication: one lane, two clear options'
BUG='A simple bug fix with a stated root cause.'

# --- append validates and appends ----------------------------------------------
decision jd-1 fix-a clear "$BUG" '{"harness":"claude","model":"sonnet","effort":"high"}' | jev append
expect_code 0 "$?" "a decision record appends"
printf '%s\n' '{"schema_version":1,"kind":"outcome","decision_id":"x"}' | jev append 2>/dev/null
expect_code 1 "$?" "append refuses a record that is not a decision"
printf 'not json\n' | jev append 2>/dev/null
expect_code 1 "$?" "append refuses malformed input"
assert_equals '1' "$(wc -l < "$JEV_LOG" | tr -d ' ')" "only the valid decision was written"
assert_equals '600' "$(stat -c %a "$JEV_LOG")" "the log is private despite a permissive umask"
pass "append writes only well-formed decision records"

# --- spawned records what the dispatch actually launched -----------------------
jev spawned fix-a claude sonnet high
expect_code 0 "$?" "spawned exits 0"
outcome=$(tail -n 1 "$JEV_LOG")
assert_equals 'outcome|jd-1|spawn|dispatched|true' "$(jq -r '[.kind, .decision_id, .source, .took, .followed] | join("|")' <<<"$outcome")" "a spawn matching the resolver profile is recorded as followed"
jev spawned fix-a claude sonnet high
assert_equals '2' "$(wc -l < "$JEV_LOG" | tr -d ' ')" "a second spawn for one decision is not double-counted"

decision jd-2 fix-b clear "$BUG" '{"harness":"claude","model":"sonnet","effort":"high"}' | jev append
jev spawned fix-b claude opus -
assert_equals 'false|{"harness":"claude","model":"opus","effort":null}' "$(tail -n 1 "$JEV_LOG" | jq -c -r '[(.followed | tostring), (.profile | tojson)] | join("|")')" "a spawn with a different profile is recorded as overridden, with - meaning unset"

lines=$(wc -l < "$JEV_LOG" | tr -d ' ')
jev spawned no-such-task claude opus -
expect_code 0 "$?" "a spawn with no decision exits 0"
assert_equals "$lines" "$(wc -l < "$JEV_LOG" | tr -d ' ')" "a spawn with no decision writes nothing"
pass "spawned records the dispatched profile against the newest decision for that task"

# --- manual outcomes ----------------------------------------------------------
decision jd-3 adj-1 escalate "$E1" | jev append
decision jd-4 adj-2 ambiguous "$E1" | jev append
decision jd-5 adj-3 clear "$E1" '{"harness":"muse","model":"muse-spark-1.3","effort":"xhigh"}' | jev append
jev outcome jd-3 --took held --note "rule requires approval"
expect_code 0 "$?" "a held outcome is recorded"
assert_equals 'supervisor|held|null|rule requires approval' "$(tail -n 1 "$JEV_LOG" | jq -r '[.source, .took, (.followed | tostring), .note] | join("|")')" "a held outcome carries no profile"
jev outcome jd-4 --took dispatched --harness muse --model muse-spark-1.3 --effort xhigh
assert_equals 'null' "$(tail -n 1 "$JEV_LOG" | jq -c .followed)" "an outcome for a decision without a profile has no followed verdict"
jev outcome jd-5 --took declined
jev outcome jd-missing --took held 2>/dev/null
expect_code 1 "$?" "an outcome for an unknown decision fails"
jev outcome jd-3 --took dispatched 2>/dev/null
expect_code 2 "$?" "dispatched without a harness is a usage error"
jev outcome jd-3 --took held --harness claude 2>/dev/null
expect_code 2 "$?" "only dispatched carries a profile"
jev outcome jd-3 --took maybe 2>/dev/null
expect_code 2 "$?" "an unknown outcome word is a usage error"
lines=$(wc -l < "$JEV_LOG" | tr -d ' ')
jev spawned adj-1 claude sonnet high
jev spawned adj-2 claude sonnet high
jev spawned adj-3 claude sonnet high
assert_equals "$lines" "$(wc -l < "$JEV_LOG" | tr -d ' ')" "a later spawn cannot overwrite a held, dispatched, or declined fate"
pass "outcome records the supervisor's own fate for a decision"

# --- report: per-class rates, no spend figure ----------------------------------
LONG_PREFIX=$(printf '%081d' 0)
decision jd-long-1 long-1 clear "${LONG_PREFIX}alpha" | jq --arg when "${LONG_PREFIX}alpha" '.resolved = "rule_1" | .resolved_when = $when' | jev append
decision jd-long-2 long-2 escalate "${LONG_PREFIX}alpha" | jq --arg when "${LONG_PREFIX}beta" '.resolved = "rule_2" | .resolved_when = $when' | jev append
printf 'garbage line\n' >> "$JEV_LOG"
out=$(jev report)
expect_code 0 "$?" "report exits 0"
assert_contains "$out" '  decisions: 7   with outcome: 5' "report counts decisions and joined outcomes, skipping malformed lines"
assert_contains "$out" "  class: $BUG   n=2   clear=100% ambiguous=0% escalate=0% error=0%   outcomes=2 followed=1 overridden=1 held=0 declined=0" "report gives the bug-fix class its own rates"
assert_contains "$out" "  class: $E1   n=3   clear=33.3% ambiguous=33.3% escalate=33.3% error=0%   outcomes=3 followed=0 overridden=0 held=1 declined=1" "report gives the escalation class its own rates"
assert_contains "$out" "  class: ${LONG_PREFIX}alpha   n=1   clear=100%" "the full resolved class is preserved"
assert_contains "$out" "  class: ${LONG_PREFIX}beta   n=1   clear=0% ambiguous=0% escalate=100%" "fallback groups under its resolved class"
assert_not_contains "$out" '900' "report makes no token-based figure"
assert_contains "$out" 'not a spend measure' "report says tokens are not a spend measure"
rm -f "$JEV_LOG"
assert_contains "$(jev report)" '  decisions: 0' "report on an absent log is empty, not an error"
pass "report prints clear/ambiguous/escalate/error rates per class"

jev bogus 2>/dev/null
expect_code 2 "$?" "unknown subcommand is a usage error"
jev spawned '../x' claude - - 2>/dev/null
expect_code 2 "$?" "a task id with a path is a usage error"
pass "usage errors exit 2"

# --- the real spawn records its launched profile --------------------------------
SPAWN_DIR="$TMP_ROOT/spawn"
SPAWN_HOME="$SPAWN_DIR/home"
SPAWN_TASK=spawn-t1
SPAWN_WT="$SPAWN_DIR/wt"
mkdir -p "$SPAWN_HOME/data/$SPAWN_TASK" "$SPAWN_HOME/projects" "$SPAWN_HOME/state" "$SPAWN_HOME/config" "$SPAWN_HOME/user-home"
printf '%s\n' "$$" > "$SPAWN_HOME/state/.lock"
touch "$SPAWN_HOME/state/.last-watcher-beat"
fm_git_worktree "$SPAWN_DIR/sample" "$SPAWN_WT" "fm/$SPAWN_TASK"
cat > "$SPAWN_HOME/data/$SPAWN_TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise the decision log for $SPAWN_TASK.

## Firstmate spec
Nothing to build.
EOF
SPAWN_FAKEBIN=$(fm_fakebin "$SPAWN_DIR")
cat > "$SPAWN_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
chmod +x "$SPAWN_FAKEBIN/tmux"
fm_fake_exit0 "$SPAWN_FAKEBIN" treehouse no-mistakes
decision jd-spawn "$SPAWN_TASK" clear "$BUG" '{"harness":"claude","model":"sonnet","effort":"high"}' \
  | FM_HOME="$SPAWN_HOME" "$TOOL" append
spawn_out=$(env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" \
  HOME="$SPAWN_HOME/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
  FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$SPAWN_WT" TMUX="fake,1,0" PATH="$SPAWN_FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$SPAWN_TASK" "$SPAWN_DIR/sample" --mode local-only --yolo off \
  --harness claude --model sonnet --effort high 2>&1) || fail "spawn failed: $spawn_out"
assert_equals 'jd-spawn|spawn|dispatched|true' \
  "$(tail -n 1 "$SPAWN_HOME/state/jev-decisions.jsonl" | jq -r '[.decision_id, .source, .took, .followed] | join("|")')" \
  "fm-spawn records the profile it launched against the task's decision"
pass "a real spawn records its outcome in the decision log"

printf '# all fm-jev-decisions tests passed\n'
