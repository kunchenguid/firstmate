#!/usr/bin/env bash
# Behavior tests for the read-only terminal kanban dashboard.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FIXTURE=$TMP_ROOT/snapshot.json
cat > "$FIXTURE" <<'EOF'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-10-08T12:00:00Z","fm_home":"/homes/flagship",
 "backlog":{"present":true,"records":[
  {"state":"in_flight","structured":true,"id":"ship-task","title":"Ship Task","repo":"alpha","kind":"ship"},
  {"state":"queued","structured":true,"id":"queued-task","title":"Queued Task","repo":"beta","kind":"scout","blocked_by":"ship-task","captain_actionable":false},
  {"state":"queued","structured":true,"id":"held-task","title":"Pick API shape","repo":"beta","kind":"ship","captain_actionable":true,"hold_reason":"choose REST or gRPC"},
  {"state":"in_flight","structured":true,"id":"paused-task","title":"Paused Task","repo":"alpha","kind":"ship","captain_actionable":true,"hold_reason":"needs budget call"},
  {"state":"done","structured":true,"id":"new-done","title":"New Done","repo":"alpha","kind":"ship","pr_url":"https://github.com/o/r/pull/7"},
  {"state":"done","structured":true,"id":"old-done","title":"Old Done","repo":"alpha","kind":"ship","pr_url":"https://github.com/o/r/pull/1"}]},
 "tasks":[
  {"id":"pr-task","kind":"ship","mode":"no-mistakes","project":"alpha","current_state":{"state":"done","detail":"checks green"},"pr":{"url":"https://github.com/o/r/pull/9"},"hints":{"pending_decision":false},"backlog":{"title":"PR Task","repo":"alpha"}},
  {"id":"ship-task","kind":"ship","mode":"direct-PR","project":"alpha","current_state":{"state":"working","detail":"run-step review"},"pr":{"url":null},"hints":{"pending_decision":false},"backlog":{"title":"Ship Task","repo":"alpha"}},
  {"id":"paused-task","kind":"ship","mode":"direct-PR","project":"alpha","current_state":{"state":"paused","detail":"awaiting go"},"pr":{"url":null},"hints":{"pending_decision":false},"backlog":{"title":"Paused Task","repo":"alpha"}},
  {"id":"ask-task","kind":"scout","mode":"scout","project":"gamma","current_state":{"state":"blocked","detail":""},"pr":{"url":null},"hints":{"pending_decision":true},"backlog":null}]}
EOF

# section_of <stacked-output> <needle>: print the column heading the needle sits under.
section_of() {
  printf '%s\n' "$1" | awk -v n="$2" '
    /^(QUEUED|IN FLIGHT|WAITING ON CAPTAIN|DONE)$/ { col = $0 }
    index($0, n) { print col; exit }'
}

test_wide_board_lays_columns_side_by_side() {
  local out
  out=$(COLUMNS=160 "$DASH" --once --snapshot "$FIXTURE")
  assert_contains "$out" "flagship" "header names the fleet"
  assert_contains "$out" "1 under sail · 1 in the hold · 4 awaiting the captain · 2 made port" "header summarises counts"
  assert_contains "$out" "logged 2026-10-08T12:00:00Z" "header shows the refresh timestamp"
  assert_not_contains "$out" "q to quit" "--once frame has no quit hint"
  printf '%s\n' "$out" | grep -q 'QUEUED .* IN FLIGHT .* WAITING ON CAPTAIN .* DONE' \
    || fail "wide board must put all four columns on one row"$'\n'"$out"
  assert_not_contains "$out" $'\033[' "non-TTY output carries no ANSI colour"
  pass "wide board renders header and four side-by-side columns"
}

test_narrow_board_stacks_and_places_cards() {
  local out
  out=$(COLUMNS=50 "$DASH" --once --snapshot "$FIXTURE")
  printf '%s\n' "$out" | grep -q 'QUEUED .* IN FLIGHT' && fail "narrow board must stack columns"
  assert_equals "QUEUED" "$(section_of "$out" "queued-task")" "queued card column"
  assert_equals "QUEUED" "$(section_of "$out" "awaits ship-task")" "queued card shows its blocker"
  assert_equals "IN FLIGHT" "$(section_of "$out" "ship-task ─")" "in-flight card column"
  assert_equals "IN FLIGHT" "$(section_of "$out" "⚑ working - run-step review")" "in-flight card shows live worker state"
  assert_equals "IN FLIGHT" "$(section_of "$out" "alpha · ship · direct-PR")" "card shows project, kind, and delivery mode"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "pr-task")" "ready PR waits on the captain"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "PR ready for review")" "ready PR is labelled"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "https://github.com/o/r/pull/9")" "ready PR shows its link"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "ask-task")" "open decision waits on the captain"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "held: choose REST or gRPC")" "captain hold shows its reason"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "held: needs budget call")" "held in-flight task waits on the captain with its reason"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "⚑ paused - awaiting go")" "held task keeps its live state"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c 'paused-task ─')" "held task with a live worker shows once"
  assert_equals "DONE" "$(section_of "$out" "new-done")" "done card column"
  pass "narrow board stacks columns and files every card in its column"
}

test_finished_task_with_pr_waits_despite_stale_run_state() {
  local snap=$TMP_ROOT/stale.json out
  jq '.tasks += [
    {"id":"stale-task","kind":"ship","mode":"no-mistakes","project":"alpha",
     "current_state":{"state":"unknown","detail":"unrecognized run status"},
     "pr":{"url":"https://github.com/o/r/pull/11"},"hints":{"pending_decision":false},
     "paths":{"status_log":{"last_event":{"state":"done"}}},"endpoint":{"status":"dead"},
     "backlog":{"title":"Stale Task","repo":"alpha"}},
    {"id":"live-task","kind":"ship","mode":"no-mistakes","project":"alpha",
     "current_state":{"state":"unknown","detail":"unrecognized run status"},
     "pr":{"url":"https://github.com/o/r/pull/12"},"hints":{"pending_decision":false},
     "paths":{"status_log":{"last_event":{"state":"done"}}},"endpoint":{"status":"alive"},
     "backlog":{"title":"Live Task","repo":"alpha"}}]' "$FIXTURE" > "$snap"
  out=$(COLUMNS=50 "$DASH" --once --snapshot "$snap")
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "stale-task")" "finished task with a PR waits on the captain"
  assert_equals "WAITING ON CAPTAIN" "$(section_of "$out" "https://github.com/o/r/pull/11")" "stale-state PR shows its link there"
  assert_equals "IN FLIGHT" "$(section_of "$out" "live-task")" "task with a live worker stays in flight"
  pass "finished task with an open PR waits on the captain despite stale run state"
}

test_done_limit_keeps_most_recent() {
  local out
  out=$(COLUMNS=50 "$DASH" --once --done 1 --snapshot "$FIXTURE")
  assert_contains "$out" "new-done" "most recent done card kept"
  assert_not_contains "$out" "old-done" "older done card dropped by --done"
  pass "--done bounds Done to the most recent cards"
}

test_live_snapshot_of_empty_home() {
  local home out
  home=$TMP_ROOT/home
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  out=$(FM_HOME="$home" COLUMNS=120 "$DASH" --once) || fail "live snapshot render failed: $out"
  assert_contains "$out" "0 under sail · 0 in the hold · 0 awaiting the captain · 0 made port" "empty fleet counts"
  assert_contains "$out" "calm waters" "empty columns say so"
  pass "dashboard renders a live snapshot of an empty home"
}

test_rejects_bad_interval() {
  local rc=0
  "$DASH" --once --interval 0 --snapshot "$FIXTURE" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "zero interval"
  pass "invalid --interval is refused"
}

test_rows_clip_to_viewport_with_position_marker() {
  local out n
  out=$(COLUMNS=160 "$DASH" --once --rows 14 --snapshot "$FIXTURE")
  n=$(printf '%s\n' "$out" | wc -l)
  [ "$n" -le 14 ] || fail "clipped frame must not exceed --rows, got $n lines"$'\n'"$out"
  assert_contains "$out" "cards 1-1 of 4" "tall column shows its position"
  assert_contains "$out" "cards 1-1 of 2" "short column shows its position"
  assert_contains "$out" "▶ QUEUED" "focused column is marked"
  assert_not_contains "$out" "ask-task" "cards past the viewport are scrolled out"
  out=$(COLUMNS=160 "$DASH" --once --rows 20 --focus 2 --scroll 2 --snapshot "$FIXTURE")
  assert_contains "$out" "cards 3-4 of 4" "scrolling moves the window"
  assert_contains "$out" "▶ WAITING ON CAPTAIN" "focus follows --focus"
  assert_contains "$out" "ask-task" "scrolled card appears"
  out=$(COLUMNS=160 "$DASH" --once --rows 20 --focus 2 --scroll 99 --snapshot "$FIXTURE")
  assert_contains "$out" "cards 4-4 of 4" "scroll clamps to the last card"
  out=$(COLUMNS=50 "$DASH" --once --rows 18 --focus 1 --snapshot "$FIXTURE")
  assert_contains "$out" "[IN FLIGHT]" "narrow board shows the focused column"
  assert_contains "$out" "cards 1-1 of 1" "narrow board shows position"
  pass "--rows clips each column to a scrollable viewport with a position marker"
}

# live_keys <keys-during-refresh> <keys-after-draw>: run the live loop on a pty
# whose snapshot takes 1.5s; print the raw output, a marker line, then the
# terminal's echo flag after exit.
live_keys() {
  local bin=$TMP_ROOT/livebin
  mkdir -p "$bin"
  cp "$DASH" "$bin/fm-dashboard.sh"
  printf '#!/usr/bin/env bash\nsleep 1.5\ncat %q\n' "$FIXTURE" > "$bin/fm-fleet-snapshot.sh"
  chmod +x "$bin/fm-fleet-snapshot.sh"
  python3 -I - "$bin/fm-dashboard.sh" "$1" "$2" <<'PY'
import os, pty, select, sys, termios, time
script, early, late = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(NO_COLOR="1", LINES="14", COLUMNS="160", TERM="xterm")
    os.execv("/usr/bin/env", ["env", "bash", script, "--interval", "30"])
out = b""
def pump(secs):
    global out
    end = time.time() + secs
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try: out += os.read(fd, 65536)
            except OSError: return
time.sleep(0.3)
for k in early.split(","):
    if k: os.write(fd, k.encode().decode("unicode_escape").encode())
pump(2.5)
os.write(fd, late.encode().decode("unicode_escape").encode())
pump(0.8)
os.write(fd, b"q")
pump(0.5)
echo = bool(termios.tcgetattr(fd)[3] & termios.ECHO)
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace") + "\nECHO_AFTER_EXIT=" + str(echo) + "\n")
PY
}

test_live_keys_never_echo_during_refresh() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local out
  out=$(live_keys '\x1b[C,\x1b[C' '') || fail "live run failed"
  assert_not_contains "$out" "^[" "keys typed during a refresh are not echoed"
  assert_not_contains "$out" "[C" "arrow sequences never print as text"
  assert_contains "$out" "▶ WAITING ON CAPTAIN" "arrows typed during the refresh still moved focus"
  assert_contains "$out" "ECHO_AFTER_EXIT=True" "terminal echo is restored on exit"
  pass "live board never echoes keys typed during a refresh and restores the tty"
}

test_live_key_burst_applies_every_step() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local out
  out=$(live_keys '\x1b[C,\x1b[C' '\x1b[B\x1b[B\x1b[B') || fail "live run failed"
  assert_contains "$out" "cards 4-4 of 4" "three down arrows in one burst scroll three cards"
  pass "a burst of held arrow keys applies every step"
}

test_wide_board_lays_columns_side_by_side
test_live_keys_never_echo_during_refresh
test_live_key_burst_applies_every_step
test_rows_clip_to_viewport_with_position_marker
test_narrow_board_stacks_and_places_cards
test_finished_task_with_pr_waits_despite_stale_run_state
test_done_limit_keeps_most_recent
test_live_snapshot_of_empty_home
test_rejects_bad_interval
