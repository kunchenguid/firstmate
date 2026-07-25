#!/usr/bin/env bash
# Static regressions for the inline captain boundary and its conditional translation owner.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
CAPTAIN="$ROOT/.agents/skills/captain-communication/SKILL.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
AHOY="$ROOT/.agents/skills/ahoy/SKILL.md"
README="$ROOT/README.md"

section_9() {
  awk '
    /^## 9\. Captain communication$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

test_inline_boundary_points_to_translation_owner() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Talk in project outcomes, consequences, and decisions rather than orchestration mechanics." \
    "section 9 lost the always-loaded outcome-language boundary"
  assert_contains "$contract" "Never relay worker reports, event lines, tool output, internal labels, or decision records verbatim into captain chat" \
    "section 9 lost the verbatim-evidence boundary"
  assert_contains "$contract" '`captain-communication` owns conditional translation vocabulary and escalation shape.' \
    "section 9 does not point to the conditional owner"
  assert_grep '## Translate evidence into outcomes' "$CAPTAIN" \
    "captain-communication does not own translation procedure"
  pass "section 9 keeps the hard boundary and points to one conditional owner"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(<"$CAPTAIN")
  assert_contains "$contract" '`Scout` and `second mate` are accepted Firstmate vocabulary' \
    "captain-communication does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "captain-communication must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "captain-communication must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "captain-communication must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(<"$CAPTAIN")
  for phrase in \
    "Fail-closed" \
    "fails closed" \
    "Fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "captain-communication does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside when the optional check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(<"$CAPTAIN")
  for phrase in \
    "Worktree, checkout, primary checkout, or local-main becomes local copy" \
    "Teardown becomes cleanup" \
    "Wake, watcher, heartbeat, stale, signal, or check becomes notification" \
    "Hold, gate, ask-user, needs-decision, blocked, or paused becomes the concrete decision" \
    "Done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state becomes the concrete result" \
    "Brief becomes instructions" \
    "Crewmate becomes worker" \
    "Harness, backend, runtime, or adapter becomes worker runtime or tool" \
    "Status file, metadata, state, task id, or raw state path becomes durable record"; do
    assert_contains "$contract" "$phrase" "captain-communication mapping list is missing '$phrase'"
  done
  pass "captain-communication maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(<"$CAPTAIN")
  assert_contains "$contract" "Never paste a worker report, status line, tool output, validation label, or decision record into captain chat." \
    "captain-communication does not reject verbatim internal evidence"
  assert_contains "$contract" "Private reports may retain precise identifiers, paths, event labels, and runtime terms" \
    "captain-communication does not preserve private evidence precision"
  assert_contains "$contract" "the captain-facing summary that links them still follows this rule" \
    "captain-communication does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while private reports stay precise"
}

test_routine_no_action_response_is_event_scoped() {
  local contract
  contract=$(<"$CAPTAIN")
  assert_contains "$contract" 'reply exactly `Captain, shipshape.` without implying that unrelated visible-session decisions are resolved.' \
    "captain-communication does not require the exact event-scoped no-action response"
  assert_not_contains "$contract" 'Captain, no decision is needed.' \
    "captain-communication implies unrelated decisions are resolved"
  pass "routine no-action response is exact and scoped to its event"
}

test_outward_facing_skill_points_reference_translation_owner() {
  assert_grep 'use `captain-communication` to report' "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference captain-communication"
  assert_grep 'Acknowledge** through `captain-communication`' "$AFK" \
    "afk acknowledgement does not reference captain-communication"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "Bearings Captain's Call decisions through \`captain-communication\`" "$DECISION" \
    "decision relay does not reference captain-communication"
  assert_grep 'use `captain-communication` to report the plain failure' "$RECOVERY" \
    "stuck-worker failure does not reference captain-communication"
  assert_grep 'use `captain-communication` to report that the requested worker runtime is not verified' "$HARNESS" \
    "runtime fallback does not reference captain-communication"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep 'through `captain-communication`' "$CODEXAPP" \
    "Codex Desktop reporting does not reference captain-communication"
  assert_grep 'stricter public version of `captain-communication`' "$FMX" \
    "X reply safety does not supplement captain-communication"
  assert_grep 'Use `captain-communication` to summarize' "$UPDATE" \
    "Firstmate update reporting does not reference captain-communication"
  pass "outward-facing skill handoffs point to the conditional translation owner"
}

test_translation_owner_is_not_duplicated() {
  local duplicate_count file
  duplicate_count=0
  for file in "$AGENTS" "$CAPTAIN" "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE"; do
    if grep -Fq "Worktree, checkout, primary checkout, or local-main becomes" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 1 ] || fail "captain translation mapping must have exactly one owner"
  assert_grep 'Worktree, checkout, primary checkout, or local-main becomes' "$CAPTAIN" \
    "captain-communication is not the mapping owner"
  pass "captain-communication alone owns the mapping list"
}

test_ahoy_is_an_internal_user_invocable_skill() {
  assert_present "$AHOY" "ahoy skill is missing"
  assert_grep 'name: ahoy' "$AHOY" "ahoy skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$AHOY" "ahoy skill is not user-invocable"
  assert_grep '  internal: true' "$AHOY" "ahoy skill is not internal"
  [ ! -e "$ROOT/skills/ahoy" ] || fail "ahoy must not exist in the public installer-facing skills directory"
  pass "ahoy is internal, user-invocable, and absent from public skills"
}

test_ahoy_readme_uses_cross_harness_convention() {
  assert_grep 'Claude and grok use the slash form shown here; codex uses the same names with `$`' "$README" \
    "README lost the cross-harness slash and dollar convention"
  assert_grep '| `/ahoy`' "$README" "README built-in skills table does not list /ahoy"
  pass "README lists ahoy under the shared cross-harness invocation convention"
}

test_ahoy_owns_only_the_visible_session_recap() {
  assert_grep '[`../bearings/SKILL.md`](../bearings/SKILL.md)' "$AHOY" \
    "first-message fallback does not delegate to Bearings by relative pointer"
  assert_grep 'If no prior real captain message exists' "$AHOY" \
    "ahoy does not limit Bearings fallback to the first real captain message"
  assert_grep 'Bearings alone owns its gathering, artifact, and response contract.' "$AHOY" \
    "ahoy first-message fallback does not delegate to Bearings alone"
  assert_grep 'A captain boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.' "$AHOY" \
    "ahoy lacks an explicit captain-authored boundary rule"
  assert_grep 'Exclude messages that begin with the current U+2063 `FIRSTMATE_OP:` injection prefix.' "$AHOY" \
    "ahoy does not exclude current marked operational injections"
  assert_grep 'Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.' "$AHOY" \
    "ahoy does not narrowly exclude the legacy away-mode injection shape"
  assert_grep 'Exclude the exact legacy unmarked session-start payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``' "$AHOY" \
    "ahoy does not exclude the legacy unmarked session-start payload"
  assert_grep 'quotes or embeds a current operational message after ordinary captain text' "$AHOY" \
    "ahoy lacks quoted-current near-miss protection"
  assert_grep 'Apply the current exclusion only when U+2063 `FIRSTMATE_OP:` begins at the first character of the whole message' "$AHOY" \
    "ahoy does not pin the current-prefix whole-message boundary"
  assert_grep 'contains ASCII `FIRSTMATE_OP:` without a leading U+2063' "$AHOY" \
    "ahoy lacks ASCII-only near-miss protection"
  assert_grep 'Apply the legacy startup exclusion as a literal whole-message match: ``Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` is a captain boundary.' "$AHOY" \
    "ahoy does not pin the altered-startup behavioral near miss"
  assert_grep 'System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not captain messages.' "$AHOY" \
    "ahoy incorrectly treats synthetic operational messages as captain messages"
  assert_grep 'The normal recap branch is session-history-only.' "$AHOY" \
    "later ahoy invocation is not explicitly session-history-only"
  assert_grep 'Do not call Bearings, shell commands, fleet snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.' "$AHOY" \
    "normal recap does not prohibit fresh fleet, file, and tool reads"
  assert_grep 'Create no report, persist nothing' "$AHOY" \
    "normal recap does not prohibit artifacts and storage"
  assert_grep 'do not guess current live state beyond the last visible event' "$AHOY" \
    "normal recap may falsely claim a live snapshot"
  assert_grep 'The current `/ahoy` message is outside the recap interval.' "$AHOY" \
    "current ahoy invocation is not excluded from the recap interval"
  assert_grep 'If context compaction makes the prior boundary unavailable' "$AHOY" \
    "ahoy does not disclose an unavailable compacted boundary"
  assert_grep 'summarize only visibly supported events' "$AHOY" \
    "compacted fallback may invent unsupported events"
  assert_no_grep 'fm-bearings-snapshot.sh' "$AHOY" \
    "ahoy copied Bearings gathering mechanics instead of referencing its owner"
  assert_no_grep "Captain's Call" "$AHOY" \
    "ahoy copied Bearings response contract instead of referencing its owner"
  pass "ahoy delegates first-message fallback and keeps later recaps visible-session-only"
}

test_ahoy_scans_visible_history_for_open_decisions() {
  assert_grep 'preserve the ordinary recap interval: recap what happened after that message and before the current invocation.' "$AHOY" \
    "ahoy no longer preserves its ordinary recap interval"
  assert_grep 'inspect the entire session history visible to the current first mate before the current invocation for every explicit captain decision that remains unanswered' "$AHOY" \
    "ahoy does not scan globally visible session history for open decisions"
  assert_grep 'including decisions raised before the ordinary recap boundary.' "$AHOY" \
    "ahoy does not include open decisions from before the recap boundary"
  assert_grep 'A later unrelated captain message establishes a recap boundary but does not close an earlier decision.' "$AHOY" \
    "ahoy lets unrelated captain messages close earlier decisions"
  assert_grep 'Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses that decision.' "$AHOY" \
    "ahoy lacks substantive-answer closure semantics"
  assert_grep 'Include every visibly supported open decision once, and deduplicate by the decision' "$AHOY" \
    "ahoy does not include and deduplicate visibly open decisions"
  assert_grep "substance when the ordinary interval recap already represents it or its wording differs." "$AHOY" \
    "ahoy deduplicates decisions by wording instead of substance"
  assert_grep 'If no ordinary events occurred after the previous captain message but an older visibly open decision exists, report that decision instead of claiming nothing happened.' "$AHOY" \
    "ahoy can incorrectly claim nothing happened while an older decision is open"
  assert_grep 'Compacted history supports an open decision only when both its request and its still-unanswered status are visible' "$AHOY" \
    "ahoy does not limit compacted decision reporting to visible support"
  assert_grep 'report uncertainty instead of reconstructing hidden requests or answers.' "$AHOY" \
    "ahoy may reconstruct hidden decision history after compaction"
  pass "ahoy adds visibly open decisions without changing the ordinary recap boundary"
}

test_ahoy_user_role_injections_share_one_marker() {
  local daemon grok_guard opencode_guard opencode_watch pi_guard pi_watch owner sessionstart spawn
  daemon=$(cat "$ROOT/bin/fm-supervise-daemon.sh")
  grok_guard=$(cat "$ROOT/bin/fm-turnend-guard-grok.sh")
  opencode_guard=$(cat "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js")
  opencode_watch=$(cat "$ROOT/.opencode/plugins/fm-primary-watch-arm.js")
  pi_guard=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  pi_watch=$(cat "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
  owner=$(cat "$ROOT/bin/fm-operational-input.sh")
  sessionstart=$(cat "$ROOT/bin/fm-sessionstart-nudge.sh")
  spawn=$(cat "$ROOT/bin/fm-spawn.sh")

  assert_contains "$owner" 'FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "' \
    "canonical owner lost the landed Ahoy prefix"
  assert_contains "$sessionstart" 'fm_operational_input_encode session-start' \
    "session-start does not use the canonical typed constructor"
  assert_contains "$daemon" 'fm_operational_input_encode away-supervisor' \
    "away-mode does not use the canonical typed constructor"
  assert_contains "$grok_guard" 'fm_operational_input_encode turn-end-guard' \
    "Grok guard does not use the canonical typed constructor"
  assert_contains "$opencode_guard" 'encodeFirstmateOperationalInput(' \
    "OpenCode guard does not use the cross-language constructor"
  assert_contains "$opencode_guard" '"turn-end-guard"' \
    "OpenCode guard does not retain its exact current kind"
  assert_contains "$opencode_watch" 'encodeFirstmateOperationalInput(paths.root, "watcher"' \
    "OpenCode watcher does not retain its exact current kind"
  assert_contains "$pi_guard" 'encodeFirstmateOperationalInput(' \
    "Pi guard does not use the cross-language constructor"
  assert_contains "$pi_guard" '"turn-end-guard"' \
    "Pi guard does not retain its exact current kind"
  assert_contains "$pi_watch" '"watcher"' \
    "Pi watcher does not retain its exact current kind"
  assert_contains "$spawn" 'encode launch-brief' \
    "cross-harness launches do not use the canonical launch-instruction kind"
  for producer in "$daemon" "$grok_guard" "$opencode_guard" "$opencode_watch" "$pi_guard" "$pi_watch" "$sessionstart" "$spawn"; do
    assert_not_contains "$producer" 'FIRSTMATE_OP: ' \
      "a current producer copied the canonical marker grammar"
  done
  pass "ahoy: one canonical owner constructs typed operational input for every Firstmate-controlled user-role producer"
}

test_inline_boundary_points_to_translation_owner
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_routine_no_action_response_is_event_scoped
test_outward_facing_skill_points_reference_translation_owner
test_translation_owner_is_not_duplicated
test_ahoy_is_an_internal_user_invocable_skill
test_ahoy_readme_uses_cross_harness_convention
test_ahoy_owns_only_the_visible_session_recap
test_ahoy_scans_visible_history_for_open_decisions
test_ahoy_user_role_injections_share_one_marker
