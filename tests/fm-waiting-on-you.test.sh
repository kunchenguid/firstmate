#!/usr/bin/env bash
# Behavior tests for the always-visible "Waiting on you" line
# (bin/fm-waiting-on-you.sh) and the primary turn-end surfaces that show it:
# the Claude Stop hook's systemMessage and the Pi turn-end footer status.
#
# 31 October 2026: a question asked five times in chat survived twelve hours
# because nothing recorded it as waiting on the captain. The line is computed
# from the same live captain holds Bearings' Captain's Call reads, so a live
# hold shows every turn and a turn with none shows a zero, never nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINE="$ROOT/bin/fm-waiting-on-you.sh"
TMP_ROOT=$(fm_test_tmproot fm-waiting-on-you)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A primary-shaped home: a plain git checkout with AGENTS.md, bin/, state/, and
# an empty markdown backlog - what bin/fm-primary-scope-lib.sh calls primary.
make_primary_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config"
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

run_line() {  # <home> [args...]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$LINE" "$@"
}

hold_in() {  # <home> <hold args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold "$@" >/dev/null
}

test_a_turn_with_no_hold_shows_a_zero() {
  local home out
  home=$(make_primary_home empty)
  out=$(run_line "$home") || fail "the line failed with no holds"
  assert_equals "$out" "Waiting on you: 0" "a turn with no live hold did not show a zero"
  out=$(run_line "$home" --claude) || fail "the Claude hook form failed with no holds"
  assert_equals "$(printf '%s' "$out" | jq -r '.systemMessage')" "Waiting on you: 0" \
    "the Claude Stop hook did not carry the zero line"
  pass "a turn end with no live captain hold shows Waiting on you: 0"
}

test_a_live_hold_shows_its_count_title_and_class() {
  local home out
  home=$(make_primary_home live)
  hold_in "$home" sample-rental --title "Spend on the rental" --class money \
    --reason "approve the rental spend" --repo sample || fail "could not hold the money call"
  hold_in "$home" sample-later --title "Revisit the cutover" --class deferred-by-captain \
    --until 2099-01-01 --reason "captain said later" --repo sample || fail "could not hold the deferred call"
  out=$(run_line "$home") || fail "the line failed with a live hold"
  assert_equals "$out" "Waiting on you: 1 - Spend on the rental [money]" \
    "a live hold did not show its count, title, and class (a dated deferral must not count)"
  out=$(run_line "$home" --claude) || fail "the Claude hook form failed with a live hold"
  assert_equals "$(printf '%s' "$out" | jq -r '.systemMessage')" "Waiting on you: 1 - Spend on the rental [money]" \
    "the Claude Stop hook did not carry the live-hold line"
  pass "a live captain hold shows its count, title, and class, and a dated deferral does not count"
}

test_many_holds_name_three_and_count_the_rest() {
  local home out n
  home=$(make_primary_home many)
  for n in 1 2 3 4 5; do
    hold_in "$home" "sample-call-$n" --title "Call $n" --class product-or-scope-expansion \
      --reason "captain must decide $n" --repo sample || fail "could not hold call $n"
  done
  out=$(run_line "$home") || fail "the line failed with many holds"
  case "$out" in
    "Waiting on you: 5 - Call "*"[product-or-scope-expansion]; Call "*" (+2 more)") ;;
    *) fail "five holds did not name three and count two more: $out" ;;
  esac
  pass "many live holds name three titles and count the rest"
}

test_an_unreadable_backlog_never_reads_as_zero() {
  local home out
  home=$(make_primary_home unreadable)
  chmod 000 "$home/data/backlog.md"
  if [ -r "$home/data/backlog.md" ]; then
    chmod 644 "$home/data/backlog.md"
    echo "skip: this user can read a mode-000 file, so an unreadable backlog cannot be staged"
    return 0
  fi
  out=$(run_line "$home") || fail "the line failed instead of reporting an unreadable backlog"
  chmod 644 "$home/data/backlog.md"
  assert_equals "$out" "Waiting on you: unknown - the captain holds could not be read" \
    "an unreadable backlog was shown as a count"
  pass "an unreadable backlog shows unknown, never a false zero"
}

test_a_task_worktree_prints_nothing() {
  local base wt out
  base="$TMP_ROOT/wt-base"
  wt="$TMP_ROOT/wt-child"
  fm_git_worktree "$base" "$wt" fm/waiting-on-you-child
  mkdir -p "$wt/bin" "$wt/state"
  : > "$wt/AGENTS.md"
  out=$(run_line "$wt") || fail "the line failed in a task worktree"
  assert_equals "$out" "" "a crewmate worktree printed a waiting line"
  pass "a crewmate or scout worktree prints nothing"
}

# The Pi turn-end extension refreshes the line into a footer status on every
# agent_settled, beside the existing guard, and never blocks on it.
test_pi_turn_end_sets_the_footer_status() {
  local home out
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (Pi footer status)"; return 0; }
  home=$(make_primary_home pi)
  out=$(EXT="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    HOLD="$ROOT/bin/fm-captain-hold.sh" node --input-type=module 2>&1 <<'EOF'
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  async sendUserMessage() {},
  sendMessage() {},
};
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
const settle = async () => {
  const statuses = [];
  const ctx = { ui: { setStatus(key, text) { statuses.push({ key, text }); } } };
  await handlers.get("agent_settled")({ type: "agent_settled" }, ctx);
  for (let i = 0; i < 200 && statuses.length === 0; i += 1) await new Promise((r) => setTimeout(r, 50));
  return statuses;
};
const zero = await settle();
if (zero.length !== 1 || zero[0].key !== "fm-waiting-on-you" || zero[0].text !== "Waiting on you: 0") {
  throw new Error(`a Pi turn end with no hold did not show the zero line: ${JSON.stringify(zero)}`);
}
const held = spawnSync(process.env.HOLD, ["hold", "sample-flash", "--title", "Flash the handset", "--class",
  "exploit-kernel-security-flash", "--reason", "approve flashing", "--repo", "sample"], { encoding: "utf8" });
if (held.status !== 0) throw new Error(`could not hold the flash call: ${held.stderr}`);
const live = await settle();
if (live.length !== 1 || live[0].text !== "Waiting on you: 1 - Flash the handset [exploit-kernel-security-flash]") {
  throw new Error(`a Pi turn end with a live hold did not show it: ${JSON.stringify(live)}`);
}
process.stdout.write("ok\n");
EOF
  ) || fail "the Pi turn-end footer check failed: $out"
  assert_contains "$out" "ok" "the Pi turn-end footer check did not finish: $out"
  pass "a Pi turn end refreshes the footer status to the live waiting line, zero included"
}

# The tracked Claude settings run the line at every Stop; executing that exact
# registered command must yield the hook's systemMessage.
test_claude_stop_hook_runs_the_line() {
  local home command out
  home=$(make_primary_home claude-hook)
  command=$(jq -r '[.hooks.Stop[]?.hooks[]? | select(.type == "command") | .command
    | select(test("fm-waiting-on-you\\.sh --claude$"))][0] // empty' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail "the tracked Claude settings register no Stop hook for the waiting line"
  hold_in "$home" sample-login --title "Sign in to the store" --class physical-or-credential \
    --reason "needs the captain's login" --repo sample || fail "could not hold the login call"
  out=$(CLAUDE_PROJECT_DIR="$ROOT" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" bash -c "$command" </dev/null) \
    || fail "the registered Claude Stop hook failed"
  assert_equals "$(printf '%s' "$out" | jq -r '.systemMessage')" "Waiting on you: 1 - Sign in to the store [physical-or-credential]" \
    "the registered Claude Stop hook did not show the live hold"
  pass "the registered Claude Stop hook shows the waiting line as its systemMessage"
}

fm_test_run \
  test_a_turn_with_no_hold_shows_a_zero \
  test_a_live_hold_shows_its_count_title_and_class \
  test_many_holds_name_three_and_count_the_rest \
  test_an_unreadable_backlog_never_reads_as_zero \
  test_a_task_worktree_prints_nothing \
  test_claude_stop_hook_runs_the_line \
  test_pi_turn_end_sets_the_footer_status
