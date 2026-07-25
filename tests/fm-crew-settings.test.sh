#!/usr/bin/env bash
# Behavior tests for the crewmate .claude/settings.local.json contract
# (bin/fm-crew-settings-lib.sh).
#
# Two guarantees ride in one document because fm-spawn writes it with a single
# redirect, so these tests assert BOTH survive together: losing the busy-state
# hooks or the turn-end touch blinds supervision, and losing the merge block lets
# an unattended crewmate land its own work.
#
# The rule-syntax case is the load-bearing regression. Claude Code treats ":*"
# as prefix-match syntax that is legal only at the very end of a pattern, and it
# does not merely warn about a malformed rule - it SKIPS it. A rule like
# "Bash(gh api:*/merge*)" therefore fails twice over: it stops every fresh spawn
# on a blocking settings dialog AND silently removes the merge protection it
# looks like it is providing. These tests are hermetic and never invoke claude;
# docs/verification/crew-merge-block.md holds the live-binary evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The library is its own canonical lint root, so source analysis stops here.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-crew-settings-lib.sh"

TURNEND=/tmp/fm-crew-settings-test/state/some-task.turn-ended
BUSY_EVENT=/tmp/fm-crew-settings-test/bin/fm-busy-event.sh
STATE_DIR=/tmp/fm-crew-settings-test/state
TASK_ID=some-task
BUSY_GEN=17-1

settings_json() {
  fm_crew_settings_local_json "$TURNEND" "$BUSY_EVENT" "$STATE_DIR" "$TASK_ID" "$BUSY_GEN"
}

rules() {
  settings_json | jq -r '.permissions.ask[]'
}

# The document must parse. A crewmate whose settings file is malformed JSON gets
# neither guarantee, so this is asserted before anything reads fields out of it.
test_settings_are_valid_json() {
  settings_json | jq -e . >/dev/null 2>&1 \
    || fail "generated settings.local.json is not valid JSON"
  pass "generated settings.local.json parses as JSON"
}

# Guarantee 1: the turn-end Stop hook, carrying the exact task turn-end path.
test_stop_hook_survives() {
  local cmd
  cmd=$(settings_json | jq -r '.hooks.Stop[0].hooks[0].command')
  case "$cmd" in
    *"$TURNEND"*) : ;;
    *) fail "Stop hook lost the turn-end path (got: $cmd)" ;;
  esac
  settings_json | jq -e '.hooks.Stop[0].hooks[0].type == "command"' >/dev/null \
    || fail "Stop hook must be a command hook"
  pass "Stop hook is present and carries the turn-end path"
}

# Guarantee 1, the other half: the semantic busy-state lifecycle (bin/fm-busy-lib.sh).
# The turn-end touch is only a NOTIFICATION; these four events are what keep the
# busy record honest, and an abnormal end must still close the turn. They live in
# this document too, so adding the merge block must not cost any of them.
test_busy_state_hooks_survive() {
  local ev cmd doc
  doc=$(settings_json)
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    cmd=$(printf '%s' "$doc" | jq -r ".hooks[\"$ev\"][0].hooks[0].command")
    [ -n "$cmd" ] && [ "$cmd" != null ] \
      || fail "settings document lost the $ev busy-state hook"
    case "$cmd" in
      *"$BUSY_EVENT"*) : ;;
      *) fail "$ev hook does not invoke the busy-event script (got: $cmd)" ;;
    esac
    case "$cmd" in
      *"--gen '$BUSY_GEN'"*) : ;;
      *) fail "$ev hook lost its busy generation token (got: $cmd)" ;;
    esac
    # A refused (stale-gen) event must never break Claude's own lifecycle.
    case "$cmd" in
      *"|| true") : ;;
      *) fail "$ev hook must tolerate a refused event (got: $cmd)" ;;
    esac
  done
  pass "busy-state hooks (open on UserPromptSubmit, close on Stop/StopFailure/SessionEnd) all survive"
}

# Guarantee 2: the merge block rides in the SAME document as the hooks.
# This is the co-residency invariant a second writer would have truncated.
test_merge_block_rides_with_stop_hook() {
  settings_json | jq -e '(.hooks.Stop | length) > 0 and (.permissions.ask | length) > 0' >/dev/null \
    || fail "Stop hook and permissions.ask must both be present in one document"
  settings_json | jq -e '(.hooks | keys | length) == 4 and (.permissions.ask | length) > 0' >/dev/null \
    || fail "all four busy-state hooks and the merge block must share one document"
  pass "busy-state hooks and merge block share one settings document"
}

# Every rule must be syntactically valid Claude Code permission syntax: ":*" is
# prefix-match and is legal ONLY at the very end of the pattern. This is the
# exact defect that made the gh api rules silently non-functional.
test_every_rule_is_valid_syntax() {
  local rule inner rest
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    case "$rule" in
      "Bash("*")") : ;;
      *) fail "rule is not a well-formed Bash(...) rule: $rule" ;;
    esac
    inner=${rule#Bash(}
    inner=${inner%)}
    # Strip one legal trailing ":*", then no ":*" may remain anywhere.
    rest=${inner%:\*}
    case "$rest" in
      *:\**) fail "invalid rule '$rule': ':*' must be at the end, use '*' for wildcard matching" ;;
    esac
  done <<< "$(rules)"
  pass "every permission rule uses valid ':*'-at-the-end syntax"
}

# The verbs that must be blocked. Landing is the captain's call, so both the
# gh porcelain and the gh api merge endpoints have to be covered - blocking only
# `gh pr merge` leaves `gh api --method PUT .../pulls/N/merge` wide open.
test_blocks_every_merge_verb() {
  local all row label pattern
  all=$(rules)
  while IFS='|' read -r label pattern; do
    [ -n "$label" ] || continue
    printf '%s\n' "$all" | grep -qF "$pattern" \
      || fail "merge block is missing the $label rule ($pattern)"
  done <<'ROWS'
gh porcelain merge|Bash(gh pr merge:*)
gh api pull-request merge endpoint|Bash(gh api *pulls/*/merge*)
gh api branch merges endpoint|Bash(gh api *repos/*/merges*)
tk-feature land|Bash(tk-feature land:*)
tk-feature-land|Bash(tk-feature-land:*)
ROWS
  # Guard the count so a future edit cannot quietly drop one.
  row=$(printf '%s\n' "$all" | grep -c .)
  [ "$row" -eq 5 ] || fail "expected 5 merge-block rules, found $row"
  pass "every merge verb is blocked (gh porcelain, gh api endpoints, tk-feature)"
}

# The block must stay narrow. A crewmate needs ordinary `gh api` reads and must
# be able to push its branch and open a PR; gating those would break delivery
# rather than protect it.
test_does_not_overblock_delivery_verbs() {
  local rule inner
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    inner=${rule#Bash(}
    inner=${inner%)}
    # A wholesale `gh api` or `gh` prefix gate would swallow legitimate reads.
    case "$inner" in
      'gh api:*'|'gh:*'|'gh api *'|'git push'*|'gh pr create'*)
        fail "rule '$rule' over-blocks a verb the crewmate needs" ;;
    esac
  done <<< "$(rules)"
  pass "delivery verbs (gh api reads, git push, gh pr create) stay ungated"
}

# permissions.ask, not deny/allow: a crewmate launches with
# --dangerously-skip-permissions, and ask is the control that still stops an
# agent with no approver behind it.
test_uses_ask_not_allow_or_deny() {
  settings_json | jq -e 'has("permissions") and (.permissions | has("ask"))' >/dev/null \
    || fail "merge block must be expressed under permissions.ask"
  pass "merge block uses permissions.ask"
}

# fm-spawn must actually use the library rather than re-rolling the JSON inline,
# which is how the two guarantees drifted apart before.
test_spawn_delegates_to_the_library() {
  # shellcheck disable=SC2016  # single quotes are deliberate: this is source text to match, not an expansion
  grep -qF 'fm_crew_settings_local_json "$TURNEND"' "$ROOT/bin/fm-spawn.sh" \
    || fail "fm-spawn.sh must write settings.local.json via fm_crew_settings_local_json"
  grep -q 'fm-crew-settings-lib.sh' "$ROOT/bin/fm-spawn.sh" \
    || fail "fm-spawn.sh must source fm-crew-settings-lib.sh"
  # The inline heredoc is the shape the two guarantees drifted apart in: a second
  # writer here would truncate whatever the library just wrote.
  # shellcheck disable=SC2016  # source text to match, not an expansion
  grep -qF 'cat > "$WT/.claude/settings.local.json"' "$ROOT/bin/fm-spawn.sh" \
    && fail "fm-spawn.sh must not re-roll settings.local.json inline alongside the library"
  pass "fm-spawn.sh delegates settings generation to the library"
}

test_settings_are_valid_json
test_stop_hook_survives
test_busy_state_hooks_survive
test_merge_block_rides_with_stop_hook
test_every_rule_is_valid_syntax
test_blocks_every_merge_verb
test_does_not_overblock_delivery_verbs
test_uses_ask_not_allow_or_deny
test_spawn_delegates_to_the_library
