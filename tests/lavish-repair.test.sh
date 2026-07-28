#!/usr/bin/env bash
# Behavioral contract for the lavish-repair skill's routing, diagnosis order,
# fleet-wide kill guard, recovery sequence, and durable-state expectations.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/.agents/skills/lavish-repair/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_grep() {
  local pattern=$1
  local file=$2
  local message=$3
  grep -Fq -- "$pattern" "$file" || fail "$message"
}

test_internal_skill_and_trigger() {
  local section global_count section_count

  [ -f "$SKILL" ] || fail "lavish-repair SKILL.md is missing"
  assert_grep "name: lavish-repair" "$SKILL" "skill name is missing"
  assert_grep "user-invocable: false" "$SKILL" "skill must not be captain-invocable"
  assert_grep "metadata:" "$SKILL" "skill is missing internal metadata"
  assert_grep "internal: true" "$SKILL" "skill is not marked internal"

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  global_count=$(grep -Fc '`lavish-repair`' "$AGENTS")
  section_count=$(printf '%s\n' "$section" | grep -Fc '`lavish-repair`')
  [ "$global_count" -eq 1 ] || fail "AGENTS.md must reference lavish-repair exactly once"
  [ "$section_count" -eq 1 ] || fail "lavish-repair trigger must live in section 13"
  assert_grep "served Lavish board remains loading" "$AGENTS" "trigger must cover a visibly wedged surface"
  assert_grep "before restarting Lavish or browser processes" "$AGENTS" "trigger must fire before process repair"
  pass "lavish-repair is internal and has one conditional trigger"
}

test_cheapest_first_diagnosis() {
  local http_line leak_line listener_line browser_line

  http_line=$(grep -nF '### 1. HTTP serving' "$SKILL" | cut -d: -f1)
  leak_line=$(grep -nF '### 2. Live-channel listener leak' "$SKILL" | cut -d: -f1)
  listener_line=$(grep -nF '### 3. Listener presence' "$SKILL" | cut -d: -f1)
  browser_line=$(grep -nF '### 4. Browser boundary' "$SKILL" | cut -d: -f1)
  [ "$http_line" -lt "$leak_line" ] || fail "HTTP must be diagnosed before the live channel"
  [ "$leak_line" -lt "$listener_line" ] || fail "listener leak must be diagnosed before poll presence"
  [ "$listener_line" -lt "$browser_line" ] || fail "browser diagnosis must remain last"

  assert_grep "curl -s -o /dev/null -w '%{http_code} %{time_total}\\n'" "$SKILL" "HTTP probe is missing"
  assert_grep "grep -c MaxListenersExceededWarning ~/.lavish-axi/server.log" "$SKILL" "listener-leak probe is missing"
  assert_grep "pgrep -fl 'lavish-axi.*poll'" "$SKILL" "poll-listener probe is missing"
  assert_grep "A large Chrome, headless, or bridge process count is a lead, not proof" "$SKILL" "browser counts must not be treated as proof"
  pass "lavish-repair preserves cheapest-first layer diagnosis"
}

test_fleet_wide_kill_guard() {
  assert_grep '`pkill -f <pattern>` is a FLEET-WIDE DESTRUCTIVE COMMAND' "$SKILL" "fleet-wide pkill warning is missing"
  assert_grep "pgrep -fl '<candidate-pattern>'" "$SKILL" "candidate listing is missing"
  assert_grep 'ps -p <pid> -o pid=,ppid=,etime=,command=' "$SKILL" "candidate argv inspection is missing"
  assert_grep 'Signal only one verified explicit PID with `kill <pid>`' "$SKILL" "explicit-PID signaling is missing"
  assert_grep 'Never pipe unfiltered `pgrep` output into `kill`' "$SKILL" "unfiltered process signaling is not forbidden"
  assert_grep 'Fifteen of sixteen live crewmate panes died' "$SKILL" "the concrete fleet-loss counter-example is missing"
  assert_grep "pkill -f 'chrome-devtools-axi'" "$SKILL" "the dangerous concrete pattern is missing"
  assert_grep 'user-data-dir=/tmp/<opaque-id>' "$SKILL" "run-specific unavoidable-pattern guidance is missing"
  pass "lavish-repair retains the fleet-wide destructive-command guard"
}

test_repair_and_survival_contracts() {
  assert_grep "pgrep -fl 'lavish-axi/dist/cli.mjs server'" "$SKILL" "server candidate discovery is missing"
  assert_grep 'kill <server-pid>' "$SKILL" "verified server termination is missing"
  assert_grep "lavish-axi '<source-file>' --no-open" "$SKILL" "server re-serve command is missing"
  assert_grep "lavish-axi poll '<source-file>'" "$SKILL" "listener reattachment is missing"
  assert_grep 'Session URLs survive a server restart' "$SKILL" "stable session-URL behavior is missing"
  assert_grep 'Crewmate reports and completion artifacts under `data/<id>/` survive' "$SKILL" "report survival is missing"
  assert_grep 'Leased worktrees, their working files, and their commits survive' "$SKILL" "worktree survival is missing"
  assert_grep 'Pushed branches and PRs survive remotely' "$SKILL" "remote work survival is missing"
  assert_grep 'Only the live agent process and its in-memory session are lost' "$SKILL" "live-session loss boundary is missing"
  pass "lavish-repair retains the repair and durable-state contracts"
}

test_internal_skill_and_trigger
test_cheapest_first_diagnosis
test_fleet_wide_kill_guard
test_repair_and_survival_contracts
