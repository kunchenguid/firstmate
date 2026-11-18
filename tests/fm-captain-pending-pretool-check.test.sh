#!/usr/bin/env bash
# Behavior tests for the captain-pending PreToolUse advisory
# (bin/fm-captain-pending-pretool-check.sh): which growth it announces, the
# one-announcement-per-span dedup, the transports, primary-scope inertness,
# fail-open behavior, and the tracked registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CHECK="$ROOT/bin/fm-captain-pending-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-pending-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

# Advance the watcher seen marker through the owner primitive so fixtures sit
# in the real steady state: the watcher classified everything before the turn.
mark_current() {
  ( cd "$ROOT" && . bin/fm-wake-lib.sh && fm_wake_status_mark_current "$STATE" "$STATE/$1.status" ) </dev/null >/dev/null 2>&1
}

# run_hook : Claude payload on stdin.
run_hook() {
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR"
  RC=$?
}

# run_cli [extra env...] : plain-text adapter mode, no stdin.
run_cli() {
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --check < /dev/null > "$OUT" 2> "$ERR"
  RC=$?
}

expect_silent() {
  local label=$1
  [ "$RC" -eq 0 ] || fail "$label must exit 0, got $RC: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label must stay silent, got: $(cat "$OUT")"
}

expect_announced() {
  local label=$1
  [ "$RC" -eq 0 ] || fail "$label must exit 0, got $RC: $(cat "$ERR")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | startswith("[captain-pending]") and contains("queued behind it") and contains("end this turn"))' "$OUT" >/dev/null \
    || fail "$label must announce with the Claude advisory object: $(cat "$OUT")"
}

# ---------------------------------------------------------------------------
# Mid-turn captain-relevant growth announces once, then stays quiet.
# ---------------------------------------------------------------------------

test_announces_captain_line_once_then_dedups() {
  printf 'working: started\n' > "$STATE/terp.status"
  mark_current terp
  printf 'status [at=1794993496]: captain rounds 85-86 approved: fabric-admin-spn granted\n' >> "$STATE/terp.status"
  run_hook
  expect_announced "a mid-turn captain answer"
  jq -e '.hookSpecificOutput.additionalContext | contains("captain rounds 85-86 approved") and contains("(terp)")' "$OUT" >/dev/null \
    || fail "the advisory must name the signal and task: $(cat "$OUT")"
  run_hook
  expect_silent "an already-announced span"
  [ "$(cat "$STATE/.captain-pending-announced")" = "terp:$(wc -c < "$STATE/terp.status" | tr -d ' ')" ] \
    || fail "the announce marker must hold the span key: $(cat "$STATE/.captain-pending-announced")"
}

test_reannounces_on_further_growth() {
  printf 'done [at=1794993600]: follow-up shipped\n' >> "$STATE/terp.status"
  run_hook
  expect_announced "further growth in the same file"
}

test_mixed_span_lists_first_captain_line() {
  rm -f "$STATE"/.captain-pending-announced "$STATE"/.captain-pending-announced.lock
  printf 'working: churn\n' > "$STATE/crew.status"
  printf 'done [at=2]: shipped\n' >> "$STATE/crew.status"
  run_hook
  expect_announced "a span mixing working and done lines"
  jq -e '.hookSpecificOutput.additionalContext | contains("done [at=2]: shipped") and contains("(crew)")' "$OUT" >/dev/null \
    || fail "the advisory must quote the captain-relevant line: $(cat "$OUT")"
}

# ---------------------------------------------------------------------------
# What must stay silent.
# ---------------------------------------------------------------------------

test_silent_for_non_captain_growth() {
  printf 'working: still going\n' >> "$STATE/terp.status"
  run_hook
  expect_silent "a working: line"
  printf 'captain-held: waiting for the captain\n' >> "$STATE/terp.status"
  printf 'resolved [at=3]: closed without action\n' >> "$STATE/terp.status"
  run_hook
  expect_silent "captain-held and resolved lines"
}

test_silent_when_watcher_already_classified() {
  mark_current terp
  mark_current crew
  run_hook
  expect_silent "content the watcher already classified at turn start"
}

test_silent_for_own_bookkeeping() {
  ( cd "$ROOT" && . bin/fm-wake-lib.sh && fm_wake_status_append_self_announced \
      "$STATE" "$STATE/terp.status" 'resolved [at=4]: pending reply closed' ) </dev/null >/dev/null 2>&1 \
    || fail "fixture: self-announced append failed"
  run_hook
  expect_silent "this home's own owned-append bookkeeping"
}

test_adapter_mode_matches_claude_mode() {
  printf 'needs-decision [at=5]: pick a lane\n' >> "$STATE/crew.status"
  run_cli
  [ "$RC" -eq 0 ] || fail "--check must exit 0, got $RC"
  grep -q '^\[captain-pending\].*needs-decision \[at=5\]' "$OUT" \
    || fail "--check must print the same advisory as plain text: $(cat "$OUT")"
  run_cli
  expect_silent "--check must honor the same dedup"
}

test_foreign_and_degenerate_payloads_fail_open() {
  printf '{"cursor_version":"2026.08.11","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  [ ! -s "$OUT" ] || fail "a foreign-host payload must stand down: $(cat "$OUT")"
  printf '{"tool_name":"Read","tool_input":{}}' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  [ ! -s "$OUT" ] || fail "a non-Bash tool must stay silent: $(cat "$OUT")"
  printf 'not json' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  [ ! -s "$OUT" ] || fail "malformed stdin must fail open: $(cat "$OUT")"
  printf '' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  [ ! -s "$OUT" ] || fail "empty stdin must fail open: $(cat "$OUT")"
}

test_off_mode_is_silent() {
  printf 'done [at=6]: another ship\n' >> "$STATE/terp.status"
  run_cli FM_CAPTAIN_PENDING_GUARD=off
  expect_silent "off mode"
}

# ---------------------------------------------------------------------------
# Scope: inert outside a genuine primary home.
# ---------------------------------------------------------------------------

test_inert_in_linked_worktree() {
  printf 'done [at=7]: shipped from elsewhere\n' >> "$STATE/crew.status"
  fm_git_identity
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  local wt="$TMP_ROOT/crew-worktree"
  git -C "$PRIMARY" worktree add -q "$wt"
  [ -d "$wt" ] || fail "fixture: linked worktree was not created"
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env FM_ROOT_OVERRIDE="$wt" FM_STATE_OVERRIDE="$STATE" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  [ ! -s "$OUT" ] || fail "a linked worktree must be inert even with pending content: $(cat "$OUT")"
  git -C "$PRIMARY" worktree remove --force "$wt"
}

test_active_in_secondmate_marker_home() {
  local mate="$TMP_ROOT/mate-home" mstate="$TMP_ROOT/mate-state"
  mkdir -p "$mate/bin" "$mstate"
  printf '# fixture\n' > "$mate/AGENTS.md"
  printf 'crew-1\n' > "$mate/.fm-secondmate-home"
  printf 'done [at=8]: shipped for the mate\n' > "$mstate/terp.status"
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env FM_ROOT_OVERRIDE="$mate" FM_STATE_OVERRIDE="$mstate" "$CHECK" --claude > "$OUT" 2> "$ERR" || true
  jq -e '.hookSpecificOutput.additionalContext | contains("(terp)")' "$OUT" >/dev/null \
    || fail "a marked secondmate home runs its own primary session: $(cat "$OUT")"
}

# ---------------------------------------------------------------------------
# The fast path must agree with the owner's marker format.
# ---------------------------------------------------------------------------

test_fast_path_agrees_with_seen_marker_offset() {
  local marker raw owner_offset field
  marker=$( (cd "$ROOT" && . bin/fm-wake-lib.sh && fm_wake_signal_seen_path "$STATE" "$STATE/terp.status") </dev/null )
  raw=''
  [ -f "$marker" ] && IFS= read -r raw < "$marker"
  [ -n "$raw" ] || fail "fixture: terp seen marker missing"
  owner_offset=$( (cd "$ROOT" && . bin/fm-wake-lib.sh && fm_wake_signal_seen_size "$STATE" "$STATE/terp.status") </dev/null )
  # The guard's inline parse of the same marker bytes must match the owner.
  field=${raw##*$'\t'}
  case "$field" in *'@'*) field=${field%%@*} ;; *) field='' ;; esac
  [ "$field" = "$owner_offset" ] \
    || fail "fast-path offset '$field' must equal the owner's '$owner_offset' for marker: $raw"
}

# ---------------------------------------------------------------------------
# The tracked registration.
# ---------------------------------------------------------------------------

test_tracked_settings_registration() {
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | contains("fm-captain-pending-pretool-check.sh --claude")' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "tracked Claude settings must register the guard on the Bash matcher"
  # shellcheck disable=SC2016 # the literal guard text must not expand
  jq -r '.hooks.PreToolUse[] | .hooks[].command' "$ROOT/.claude/settings.json" \
    | grep -F 'fm-captain-pending-pretool-check.sh --claude' \
    | grep -qF '[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0' \
    || fail "the registration must keep the standard GROK marker guard"
}

test_announces_captain_line_once_then_dedups
test_reannounces_on_further_growth
test_mixed_span_lists_first_captain_line
test_silent_for_non_captain_growth
test_silent_when_watcher_already_classified
test_silent_for_own_bookkeeping
test_adapter_mode_matches_claude_mode
test_foreign_and_degenerate_payloads_fail_open
test_off_mode_is_silent
test_inert_in_linked_worktree
test_active_in_secondmate_marker_home
test_fast_path_agrees_with_seen_marker_offset
test_tracked_settings_registration

pass "fm-captain-pending-pretool-check.sh announces mid-turn captain signals once, dedups, scopes, fails open, and is registered"
echo "all fm-captain-pending-pretool-check tests passed"
