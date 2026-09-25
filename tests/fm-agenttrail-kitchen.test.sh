#!/usr/bin/env bash
# Pins Agenttrail Kitchen's 12-worktree selection and active-state priority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-agenttrail-kitchen.sh
. "$ROOT/bin/fm-agenttrail-kitchen.sh"

snapshot=$(jq -n '
  ([{id:"unknown",state:"unknown"},{id:"failed",state:"failed"},{id:"done",state:"done"}]
   + [range(0;6) | {id:("working-" + tostring),state:"working"}]
   + [range(0;6) | {id:("validating-" + tostring),state:"validating"}]) as $tasks
  | {in_flight:$tasks,paths:[$tasks[] | {id,worktree:("/fixture/" + .id)}]}
') || fail "could not build in-flight fixture"

selection=$(fm_agenttrail_select_json "$snapshot" 12) || fail "selection failed"
[ "$(jq '.selected | length' <<<"$selection")" -eq 12 ] \
  || fail "selection did not enforce the 12-project cap"
[ "$(jq -r '.selected[0].id' <<<"$selection")" = working-0 ] \
  || fail "working tasks did not precede earlier terminal rows"
[ "$(jq -r '.selected[1].id' <<<"$selection")" = working-1 ] \
  || fail "working task snapshot order was not stable"
[ "$(jq '[.selected[] | select(.state == "working" or .state == "validating")] | length' <<<"$selection")" -eq 12 ] \
  || fail "unknown, failed, or done tasks displaced active tasks"
[ "$(jq -r '[.omitted[].id] | sort | join(",")' <<<"$selection")" = "done,failed,unknown" ] \
  || fail "overflow did not identify every lower-priority task"
pass "Agenttrail Kitchen selection caps at 12 and prioritizes working/validating tasks"

dedup_snapshot=$(jq -n '{in_flight:[{id:"late",state:"queued"},{id:"best",state:"working"},{id:"missing",state:"working"},{id:"mate/child",state:"working"}],paths:[{id:"late",worktree:"/shared"},{id:"best",worktree:"/shared"},{id:"missing",worktree:null},{id:"mate/child",worktree:"/child-worktree"}] }') \
  || fail "could not build duplicate-path fixture"
dedup_selection=$(fm_agenttrail_select_json "$dedup_snapshot" 1) || fail "deduplicated selection failed"
[ "$(jq -r '.selected[0].id' <<<"$dedup_selection")" = best ] \
  || fail "duplicate path did not retain its highest-priority task"
[ "$(jq '.selected | length' <<<"$dedup_selection")" -eq 1 ] \
  || fail "missing or duplicate paths consumed selection slots"
pass "Agenttrail Kitchen selection filters empty paths and deduplicates after ranking"
[ "$(jq '.selected | any(.id == "mate/child" and .worktree == "/child-worktree")' <<<"$(fm_agenttrail_select_json "$dedup_snapshot" 3)")" = true ] \
  || fail "composite secondmate child ID did not resolve its worktree path"
pass "Agenttrail Kitchen selection resolves composite secondmate child IDs"
