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

# An undated hold left unanswered past the aged threshold is still waiting on
# the captain, so it stays on the count, marked with the date it was set
# (oracle: the firstmate decision's own example shape, "Waiting on you: 2
# (1 unanswered since 14 Oct)"). Dropping it would print a false 1.
test_an_aged_hold_still_counts_and_is_marked() {
  local home out
  home=$(make_primary_home aged)
  hold_in "$home" sample-rental --title "Spend on the rental" --class money \
    --reason "approve the rental spend" --repo sample || fail "could not hold the money call"
  sed -i.bak 's/^  Captain hold set: .*/  Captain hold set: 2020-10-14T00:00:00Z/' "$home/data/backlog.md" \
    || fail "could not backdate the money call"
  hold_in "$home" sample-login --title "Sign in to the store" --class physical-or-credential \
    --reason "needs the captain's login" --repo sample || fail "could not hold the login call"
  grep -q '^  Captain hold set: 2020-10-14' "$home/data/backlog.md" || fail "the backdated hold lost its date"
  out=$(run_line "$home") || fail "the line failed with an aged hold"
  case "$out" in
    "Waiting on you: 2 (1 unanswered since 14 Oct) - "*) ;;
    *) fail "an aged hold dropped off the count or was not marked: $out" ;;
  esac
  assert_contains "$out" "Spend on the rental [money, unanswered since 14 Oct]" "the aged hold was not named as aged: $out"
  assert_contains "$out" "Sign in to the store [physical-or-credential]" "the live hold was not named: $out"
  assert_not_contains "$out" "physical-or-credential, unanswered" "the live hold was marked aged: $out"
  pass "an aged unanswered hold still counts and is marked with its hold date"
}

# A registered secondmate's holds are not read by this line, so the line says
# so instead of a bare zero the captain would read as nothing waiting anywhere.
test_a_registered_secondmate_says_its_holds_are_not_counted() {
  local home out
  home=$(make_primary_home with-mate)
  printf '%s\n' "- mate-one - sample mate (home: $TMP_ROOT/mate-one-home; scope: sample work; projects: sample; added 2026-10-01)" \
    > "$home/data/secondmates.md"
  out=$(run_line "$home") || fail "the line failed with a registered secondmate"
  assert_equals "$out" "Waiting on you: 0 (secondmate holds not counted)" \
    "a registered secondmate left the zero looking complete"
  pass "a registered secondmate makes the line say its holds are not counted"
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

# A Beads home keeps its holds in Beads, so its data/backlog.md is absent or a
# stale leftover from before a migration. The line reads only the markdown
# backlog, so on such a home it must say the holds are not counted rather than
# claim a zero while live Beads holds wait.
test_a_non_markdown_backend_never_prints_a_zero() {
  local home out
  home=$(make_primary_home beads-toml)
  printf 'backend = "beads"\n' > "$home/.tasks.toml"
  out=$(run_line "$home") || fail "the line failed on a beads home"
  assert_equals "$out" "Waiting on you: unknown - captain holds on the beads backlog are not counted" \
    "a beads home with a stale empty markdown backlog showed a count"
  rm -f "$home/data/backlog.md"
  out=$(run_line "$home" --claude) || fail "the Claude hook form failed on a beads home"
  assert_equals "$(printf '%s' "$out" | jq -r '.systemMessage')" \
    "Waiting on you: unknown - captain holds on the beads backlog are not counted" \
    "a beads home with no markdown backlog showed a count in the Claude Stop hook"
  home=$(make_primary_home beads-env)
  out=$(TASKS_AXI_BACKEND=beads run_line "$home") || fail "the line failed with a beads backend override"
  assert_equals "$out" "Waiting on you: unknown - captain holds on the beads backlog are not counted" \
    "a TASKS_AXI_BACKEND=beads override still counted the markdown backlog"
  pass "a home on a non-markdown backlog backend never prints a zero"
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
  out=$(GROK_AGENT=1 CLAUDE_PROJECT_DIR="$ROOT" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" bash -c "$command" </dev/null) \
    || fail "the registered Claude Stop hook failed under Grok"
  assert_equals "$out" "" "the Claude Stop hook rendered the line for a Grok session that reads the same settings"
  pass "the registered Claude Stop hook shows the waiting line as its systemMessage, and only for Claude"
}

# docs/turnend-guard.md says only the Claude Stop hook and the Pi footer render
# the line. Every tracked JSON hook registry is parsed and the set of
# registries whose hook commands run the line must be exactly the Claude
# settings; the Pi footer is proven by test_pi_turn_end_sets_the_footer_status.
test_only_the_claude_hook_registry_runs_the_line() {
  local file runners=''
  while IFS= read -r file; do
    jq -e . "$ROOT/$file" >/dev/null 2>&1 || fail "a tracked hook registry is not JSON: $file"
    if jq -e '[.. | strings | select(test("(^|[/\"[:space:]])fm-waiting-on-you\\.sh([[:space:]]|$)"))] | length > 0' \
      "$ROOT/$file" >/dev/null; then
      runners="$runners$file "
    fi
  done < <(git -C "$ROOT" ls-files -- .claude/settings.json '.agents/hooks.json' '.codex/hooks.json' \
    '.cursor/hooks.json' '.grok/hooks/*.json')
  assert_equals "$runners" ".claude/settings.json " "the hook registries that run the waiting line drifted from the documented coverage"
  pass "only the Claude Stop hook registry runs the waiting line among the tracked JSON hook registries"
}

fm_test_run \
  test_a_turn_with_no_hold_shows_a_zero \
  test_a_live_hold_shows_its_count_title_and_class \
  test_many_holds_name_three_and_count_the_rest \
  test_an_aged_hold_still_counts_and_is_marked \
  test_a_registered_secondmate_says_its_holds_are_not_counted \
  test_an_unreadable_backlog_never_reads_as_zero \
  test_a_non_markdown_backend_never_prints_a_zero \
  test_a_task_worktree_prints_nothing \
  test_claude_stop_hook_runs_the_line \
  test_only_the_claude_hook_registry_runs_the_line \
  test_pi_turn_end_sets_the_footer_status
