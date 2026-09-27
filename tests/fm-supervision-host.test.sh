#!/usr/bin/env bash
# Behavior tests for the supervision host (bin/fm-supervision-host.sh,
# docs/supervision-host.md): its report surface (bin/fm-branch-report.sh), its
# dispatch entry (bin/fm-branch-dispatch.mjs), and the host loop itself.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

HOST="$ROOT/bin/fm-supervision-host.sh"
REPORT="$ROOT/bin/fm-branch-report.sh"
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
LEASE="$ROOT/bin/fm-lease.sh"

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'skip: perl absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-supervision-host)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The stub engine. It records its environment and arguments, then acts like a
# branch turn through the real scripts according to $FM_HOME/stub-mode:
#   handle      drain, claim the task's lease, report, acknowledge, release
#   captain     the same as handle, but report verdict captain naming the rows
#               the drain presented
#   hold-lease  the same, but leave the lease held (the host must release it)
#   return      handle, but the captain returns (the record is archived) before
#               the turn ends
#   return-fail the same, then exit nonzero without a result
#   return-first the captain returns first, then handle, then block until the
#               host is stopped (an owner killing its host at the turn's end)
#   noack       the same as handle, but skip the acknowledgement
#   held        handle, but first block reading the $FM_HOME/stub-release FIFO
#               until the test writes to it, so the test chooses when the turn
#               ends
#   emptyresult the same as handle, but print {} as its result
#   noreport    drain and exit cleanly without a report
#   go-away     the captain goes away (the record is written) mid-turn, then
#               the turn reports verdict captain
#   fail        exit nonzero at once, with no result and no report (an engine
#               error the latch counts)
#   hang        before anything else, start a descendant in a process group of
#               its own, then block
STUB="$TMP_ROOT/engine-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
mode=$(cat "$FM_HOME/stub-mode" 2>/dev/null || echo handle)
n=$(( $(ls "$FM_HOME"/engine-call.* 2>/dev/null | wc -l) + 1 ))
{
  printf 'actor=%s\nholder=%s\nprimary=%s\nturn=%s\n' "${FM_SUPERVISION_ACTOR:-}" \
    "${FM_LEASE_HOLDER_PID:-}" "${FM_SUPERVISION_PRIMARY_HARNESS:-}" "${FM_BRANCH_REPORT_TURN:-}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FM_HOME/engine-call.$n"
# Like Claude, the reported cost is the conversation's running total.
result() {
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":%s,' "$(awk -v n="$n" 'BEGIN { print n * 0.25 }')"
  printf '"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20},"session_id":"stub"}\n'
}
if [ "$mode" = hang ]; then
  perl -e 'setpgrp(0, 0); exec "sleep", $ARGV[0]' "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
  printf '%s\n' "$!" > "$FM_HOME/orphan-pid"
  sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
  exit 0
fi
drain=$("$FM_REPO/bin/fm-wake-drain.sh" 2>&1)
printf '%s\n' "$drain" > "$FM_HOME/engine-drain.$n"
ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
task=$(sed -n 's/^tasks=//p' "$STATE/.supervision-host-turn" | awk '{ print $1 }')
[ -n "$task" ] || task=fleet
verdict=routine
[ "$mode" != go-away ] || verdict=captain
case "$mode" in
  fail) exit 3 ;;
  handle|captain|held|hold-lease|return|return-fail|return-first|noack|emptyresult|go-away)
    [ "$mode" != held ] || read -r _ < "$FM_HOME/stub-release"
    [ "$mode" != return-first ] || "$FM_REPO/bin/fm-afk-contract.sh" archive >> "$FM_HOME/engine-return.log" 2>&1
    [ "$mode" != go-away ] || "$FM_REPO/bin/fm-afk-contract.sh" enter --words 'gone mid-turn' >> "$FM_HOME/engine-return.log" 2>&1
    "$FM_REPO/bin/fm-lease.sh" claim "$task" >> "$FM_HOME/engine-lease.log" 2>&1
    if [ "$mode" = captain ]; then
      "$FM_REPO/bin/fm-branch-report.sh" --task "$task" --verdict captain \
        --summary "stub escalated: $(printf '%s\n' "$drain" | grep -v '^WAKE_' | tr '\n' ' ' | cut -c1-400)" \
        >> "$FM_HOME/engine-report.log" 2>&1
    else
      "$FM_REPO/bin/fm-branch-report.sh" --task "$task" --verdict "$verdict" --summary "stub handled $task" \
        >> "$FM_HOME/engine-report.log" 2>&1
    fi
    # shellcheck disable=SC2086 # the printed acknowledgement arguments
    [ -z "$ack" ] || [ "$mode" = noack ] || "$FM_REPO/bin/fm-wake-drain.sh" $ack >> "$FM_HOME/engine-ack.log" 2>&1
    [ "$mode" = hold-lease ] || "$FM_REPO/bin/fm-lease.sh" release "$task" >> "$FM_HOME/engine-lease.log" 2>&1
    case "$mode" in
      return|return-fail) "$FM_REPO/bin/fm-afk-contract.sh" archive >> "$FM_HOME/engine-return.log" 2>&1 ;;
    esac
    [ "$mode" != return-fail ] || exit 3
    [ "$mode" != return-first ] || sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
    [ "$mode" != emptyresult ] || { printf '{}\n'; exit 0; }
    result
    ;;
  noreport) result ;;
esac
SH
chmod +x "$STUB"

export FM_REPO="$ROOT"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$STUB"
export FM_SUPERVISION_HOST_PRIMARY=claude
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_ARM_CONFIRM_TIMEOUT=30
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID PI_CODING_AGENT

# Homes are registered in a file: make_home runs in a command substitution,
# whose variables never reach this shell.
HOMES_FILE="$TMP_ROOT/homes"
# Stop whatever a case left running, by the exact pids its home recorded.
stop_home_processes() {  # <home>
  local home=$1 pid
  if [ -f "$home/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    sleep 1
  fi
  pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  for pid in $(cat "$home/claude-pids" 2>/dev/null) $(cat "$home/orphan-pid" 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
suite_cleanup() {
  local home
  while IFS= read -r home; do
    [ -n "$home" ] && stop_home_processes "$home"
  done < <(cat "$HOMES_FILE" 2>/dev/null)
  fm_test_cleanup
}
trap suite_cleanup EXIT

make_home() {  # <name> <attended|away> [config line]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  # An unreachable backend: the watcher reads no endpoint as dead, so the only
  # wakes are the status appends each case makes.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  make_fake_crew_state "$home/fakebin" >/dev/null
  printf '%s\n' "${3:-}" > "$home/config/supervision-host"
  [ -n "${3:-}" ] || : > "$home/config/supervision-host"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  echo handle > "$home/stub-mode"
  # The captain has spoken in this session, so an attended wake has a mirror.
  [ "$2" != attended ] \
    || printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  if [ "$2" = away ]; then
    FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
      || fail "fixture: could not record the away posture"
  fi
  printf '%s\n' "$home" >> "$HOMES_FILE"
  printf '%s\n' "$home"
}

# A git checkout that passes the primary-scope check, so the dialog-mirror
# writer runs from a linked worktree too; its bin is this repo's bin.
MIRROR_ROOT="$TMP_ROOT/mirror-root"
mkdir -p "$MIRROR_ROOT"
git init -q "$MIRROR_ROOT"
: > "$MIRROR_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$MIRROR_ROOT/bin"

# Run the host under the fake harness that holds the home's session lock.
# Every hook payload in $home/mirror-seed.* is first written to the dialog
# mirror by that same session, as its prompt and Stop hooks would.
start_host() {  # <home> [park options...]
  local home=$1
  shift
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      rm -f "$FM_HOME/host.rc"
      for seed in "$FM_HOME"/mirror-seed.*; do
        [ -f "$seed" ] || continue
        FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$seed"
      done
      "$0" park "$@" > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" "$@" 2>> "$home/claude.err" &
}

# Extended-regex twins of tests/lib.sh's fixed-string assert_grep pair.
assert_re() {  # <regex> <file> <msg>
  grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}
assert_no_re() {  # <regex> <file> <msg>
  ! grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

watcher_live() {  # <home>
  local pid
  pid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
host_exited() { [ -s "$1/host.rc" ]; }
engine_calls() { find "$1" -maxdepth 1 -name 'engine-call.*' 2>/dev/null | wc -l | tr -d ' '; }
handled_count() { local n; n=$(grep -c '	handled	' "$1/state/.supervision-host.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }
handled_at_least() { [ "$(handled_count "$1")" -ge "$2" ]; }
append_status() {  # <home> <text>
  printf '%s [at=%s]: %s\n' "${3:-working}" "$(date +%s)" "$2" >> "$1/state/demo.status"
}

# --- report surface -----------------------------------------------------------

test_report_surface_enforces_actor_turn_and_scope() {
  local home state out rc
  home="$TMP_ROOT/report"
  state="$home/state"
  mkdir -p "$state"
  printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' > "$state/.supervision-host-turn"

  out=$(FM_HOME="$home" "$REPORT" --task alpha --verdict routine --summary ok 2>&1); rc=$?
  expect_code 3 "$rc" "a report outside the branch actor must be refused"
  assert_contains "$out" "only the supervision branch reports outcomes" "actor refusal must say why"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t0 "$REPORT" --task alpha --verdict routine --summary ok 2>&1); rc=$?
  expect_code 3 "$rc" "a report for an ended turn must be refused"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task beta --verdict captain --summary 'from memory' 2>&1); rc=$?
  expect_code 3 "$rc" "a report for a task the wake did not name must be refused"
  assert_contains "$out" "names alpha, not beta" "scope refusal must name the wake's task"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task fleet --verdict routine --summary quiet 2>&1); rc=$?
  expect_code 3 "$rc" "a fleet report on a task-scoped wake must be refused"
  [ ! -e "$state/branch-outcomes.jsonl" ] || fail "a refused report touched the outcome store"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict routine --summary quiet --silent true 2>&1); rc=$?
  expect_code 2 "$rc" "--silent true on a task outcome is a usage error"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict captain --summary 'PR ready' 2>&1); rc=$?
  expect_code 0 "$rc" "an in-scope report must be recorded"
  assert_contains "$out" "recorded seq 1 [captain]" "the report must name its store sequence"
  assert_grep '"task":"alpha"' "$state/branch-outcomes.jsonl" "the outcome store did not receive the report"
  assert_grep '"wake":"signal: alpha.status"' "$state/branch-outcomes.jsonl" "the report did not default its wake to the turn's wake"
  [ "$(cat "$state/.supervision-host-receipts")" = "$(printf 't1\t1\tcaptain\talpha')" ] \
    || fail "the host receipt was not written: $(cat "$state/.supervision-host-receipts")"

  printf 'turn=t2\nrows=5\ntasks=\nunscoped=1\nwake=heartbeat\n' > "$state/.supervision-host-turn"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t2 "$REPORT" --task fleet --verdict routine --summary quiet --silent true 2>&1); rc=$?
  expect_code 0 "$rc" "an unscoped heartbeat turn must accept a silent fleet report"
  pass "report surface: only the branch actor's current turn may report, and only on the tasks its wake names"
}

# The return brief is rendered after the record is archived, so a report made
# after that may be missing from it: the report itself queues the relay for
# main, durably, while a report made during the away window only waits for the
# brief.
test_report_after_the_return_is_queued_for_main() {
  local home state out rc drained
  home="$TMP_ROOT/report-return"
  state="$home/state"
  mkdir -p "$state"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet' >/dev/null 2>&1 || fail "fixture: could not record the away posture"
  printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' > "$state/.supervision-host-turn"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict routine --summary 'steered while away' 2>&1); rc=$?
  expect_code 0 "$rc" "a report during the away window must be recorded"
  assert_contains "$out" "it waits in the outcome store for MAIN" "a report during the away window waits for the return brief"
  ! grep -qs 'supervision-host-return' "$state/.wake-queue" || fail "a report during the away window must not be queued for main"

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$REPORT" --task alpha --verdict captain --summary 'PR ready for review' 2>&1); rc=$?
  expect_code 0 "$rc" "a report after the return must be recorded"
  assert_contains "$out" "recorded seq 2 [captain]; the captain has returned, so it is queued for MAIN to relay" \
    "a report after the return must say it is queued for main"
  assert_re $'\tcheck\tsupervision-host-return:2\tcheck: supervision-host outcome 2 for alpha \\[captain\\] was recorded after the captain returned.*relay it to the captain: PR ready for review$' \
    "$state/.wake-queue" "the late outcome must be a durable check wake for main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 2 for alpha [captain] was recorded after the captain returned" \
    "main's drain must present the late outcome"
  pass "report surface: an outcome recorded after the captain returned is queued durably for main"
}

# --- dispatch entry -----------------------------------------------------------

test_dispatch_entry_scopes_rows_and_renders_the_away_tail() {
  local home state out rc
  home="$TMP_ROOT/dispatch"
  state="$home/state"
  mkdir -p "$state"
  printf 'project=demo\nwindow=fm-demo\n' > "$state/demo.meta"
  append_wake "$state" signal demo.status "signal: $state/demo.status"
  append_wake "$state" check merge "check: merge landed: fixture"

  out=$(FM_HOME="$home" node "$DISPATCH" scope)
  assert_contains "$out" "status=safe" "an attended scan with a resolvable row must be safe"
  assert_contains "$out" "rows=1" "an attended scan must leave the check row to main"
  assert_contains "$out" "tasks=demo" "the signal row must resolve to its task"
  assert_contains "$out" "unscoped=0" "a task-local claim must be scoped"

  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" "rows=1 2" "an away scan must claim the check row too"
  assert_contains "$out" "unscoped=1" "a claimed check row names no task, so the claim is unscoped"

  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=0" "an attended check trigger must stay main's"
  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer --afk)
  assert_contains "$out" "eligible=1" "an away check trigger must be the branch's"
  out=$(printf 'signal: %s\n' "$state/demo.status" | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=1" "an attended signal trigger with a claimable row must be the branch's"
  assert_contains "$out" "rows=1" "the offer must carry the scope it judged"

  printf '[captain] keep it small\n[main] Will do.\n' > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_contains "$out" "MAIN DIALOG MIRROR (read-only context" "an attended wake prompt must open with the mirror header"
  assert_contains "$out" "[captain] keep it small" "the mirror must carry the captain's words"
  assert_not_contains "$out" "POSTURE: AWAY" "an attended wake prompt must carry no away tail"
  : > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_not_contains "$out" "MAIN DIALOG MIRROR" "an empty feed must add nothing"
  rm -f "$home/mirror"
  rc=0
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror" 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "a supplied mirror feed that cannot be read must exit 3, got $rc"
  [ -z "$out" ] || fail "a supplied mirror feed that cannot be read must render no prompt: $out"

  printf 'Away posture (recorded):\n  your words (verbatim):\n    merge nothing\n' > "$home/readback"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --away --readback-file "$home/readback")
  assert_contains "$out" "FIRSTMATE SUPERVISION WAKE: signal: demo.status" "the wake prompt must carry the reason"
  assert_contains "$out" "finish with the bin/fm-branch-report.sh command." "the wake prompt must name the host's report surface"
  assert_contains "$out" "POSTURE: AWAY." "an away wake prompt must carry the posture tail"
  assert_contains "$out" "    merge nothing" "the away tail must carry the record's read-back verbatim"
  pass "dispatch entry: the host reads branch eligibility, the offer rule, and the wake prompt from the Pi branch's own owner"
}

# --- host loop ----------------------------------------------------------------


# BRANCH OUTCOMES belongs to an opted-in home off Pi: without the file the drain
# and the store's markers are exactly as before, and on Pi the branch extension
# owns the same outcomes.
test_branch_outcomes_only_on_an_opted_in_home_off_pi() {
  local home drained fakepi
  home="$TMP_ROOT/drain-scope"
  mkdir -p "$home/state" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a home without config/supervision-host must not present branch outcomes"
  assert_absent "$home/state/.branch-outcomes-cursor" "a home without config/supervision-host must keep the store's read cursor untouched"

  : > "$home/config/supervision-host"
  fakepi="$TMP_ROOT/fakepi"
  mkdir -p "$fakepi"
  ln -sf /bin/bash "$fakepi/pi"
  drained=$(FM_HOME="$home" "$fakepi/pi" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Pi primary's drain must leave captain outcomes to the branch extension"
  assert_absent "$home/state/.branch-outcomes-cursor" "a Pi primary's drain must not advance the store's read cursor"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: PR ready for review" "an opted-in home off Pi must present the captain outcome"
  pass "drain: BRANCH OUTCOMES runs only on an opted-in home whose primary is not Pi"
}

# A fresh captain outcome is never hidden behind older routine outcomes: the
# captain rows come first whatever the routine backlog, the newest routine
# outcomes that fit the byte cap follow, and the older overflow collapses into
# a count that is marked read, so one drain clears the whole backlog.
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow() {
  local home drained pad n
  home="$TMP_ROOT/drain-cap"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  pad=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "x" }')
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record the captain outcome"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 13] demo: PR ready for review" "the captain outcome must be presented despite the routine backlog"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 13" "the captain outcome must carry its acknowledgement"
  [ "$(printf '%s\n' "$drained" | grep -n 'PR ready for review' | cut -d: -f1)" -lt "$(printf '%s\n' "$drained" | grep -n 'routine 12' | cut -d: -f1)" ] \
    || fail "the captain outcome must come before the routine outcomes: $drained"
  assert_contains "$drained" "[seq 12] demo: routine 12" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 " "the oldest routine outcome must collapse into the count"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the routine overflow must collapse into one count"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 \
    || fail "main's acknowledgement of the presented captain outcome was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "one drain must clear the routine backlog, and an acknowledged store must present nothing"
  pass "drain: captain outcomes come first, and routine overflow collapses into a count one drain clears"
}

# Repeated captain outcomes for one task collapse to its newest, one line per
# task; when the byte cap holds rows back, the section shows only the oldest
# contiguous run its acknowledgement covers - a shown task's newer row that
# follows a held-back one waits too, so no presented situation repeats - and
# the next drain shows the rest.
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task() {
  local home drained pad n task
  home="$TMP_ROOT/drain-collapse"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  for n in 1 2 3; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still blocked $n" >/dev/null \
      || fail "fixture: could not record alpha outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 3, newest of 3 for this task] alpha: alpha still blocked 3" "repeated outcomes for one task must collapse to its newest"
  assert_not_contains "$drained" "alpha still blocked 1" "an older outcome for the same task must not be repeated"
  assert_contains "$drained" "[seq 4] beta: beta ready to merge" "another task's outcome must keep its own line"
  assert_contains "$drained" "mark-processed --through 4;" "one acknowledgement must cover every presented task"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 4 >/dev/null 2>&1 || fail "the acknowledgement was refused"

  pad=$(awk 'BEGIN { for (i = 0; i < 560; i++) printf "y" }')
  for n in 1 2 3 4 5 6 7 8; do
    task=task-$n
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "$task" --verdict captain --summary "$task $pad" >/dev/null \
      || fail "fixture: could not record $task"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task task-1 --verdict captain --summary 'task-1 changed again' >/dev/null \
    || fail "fixture: could not record the later task-1 outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES: 3 newer captain outcome(s) are held back (byte cap); they follow on the next drain once these are acknowledged" \
    "the section must count every held-back captain row"
  assert_contains "$drained" "[seq 5] task-1: task-1 $pad" "the first task must show its newest outcome the acknowledgement covers"
  assert_not_contains "$drained" "task-1 changed again" "a row after a held-back one must wait, since the acknowledgement cannot cover it"
  assert_not_contains "$drained" "task-7:" "the cap must hold back the rows past the contiguous run"
  assert_contains "$drained" "mark-processed --through 10;" "the acknowledgement must cover exactly the presented run"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 10 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "task-8: task-8" "a held-back task must follow once the shown tasks are acknowledged"
  assert_contains "$drained" "[seq 13] task-1: task-1 changed again" "the held-back row of a shown task must follow once the run is acknowledged"
  assert_not_contains "$drained" "held back" "the rest must fit once the run is acknowledged"
  assert_contains "$drained" "mark-processed --through 13;" "the acknowledgement must cover the rest"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged situation must not be presented again"
  pass "drain: repeated captain outcomes collapse per task, and the byte cap presents only the run its acknowledgement covers"
}

# The reference experience after a long away window: the drain is the only
# presenter, so the first drain once the away record is gone shows the window
# once - each task's captain outcomes collapsed to one line, routine ones past
# the section's limit as a count - and once main acknowledges them, a second
# drain shows nothing from the window.
test_branch_outcomes_present_a_long_away_window_once() {
  local home drained pad n target
  home="$TMP_ROOT/drain-away-window"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  pad=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf "z" }')
  for n in $(seq 1 40); do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "task-$((n % 4))" --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
    case "$n" in
      10|20|30)
        FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still needs review $n" >/dev/null \
          || fail "fixture: could not record alpha outcome $n" ;;
    esac
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a drain while away must leave the window's outcomes for the return"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 33, newest of 3 for this task] alpha: alpha still needs review 30" "a task's repeated captain outcomes must collapse to its newest"
  [ "$(printf '%s\n' "$drained" | grep -c '] alpha: ')" -eq 1 ] || fail "a task's captain outcomes must take one line: $drained"
  assert_contains "$drained" "[seq 44] beta: beta ready to merge" "another task's captain outcome must keep its own line"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the window's routine overflow must collapse into one count"
  assert_contains "$drained" "routine 40 $pad" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 $pad" "the oldest routine outcome must collapse into the count"
  [ "${#drained}" -lt 8000 ] || fail "a long away window must cost one short drain, got ${#drained} bytes"
  target=$(printf '%s\n' "$drained" | sed -n 's/.*mark-processed --through \([0-9]*\);.*/\1/p')
  [ "$target" = 44 ] || fail "one acknowledgement must cover every captain outcome of the window, got '${target:-none}'"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$target" >/dev/null 2>&1 || fail "the acknowledgement was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a second drain must show nothing from the window"
  pass "drain: a long away window costs one short drain, captain outcomes collapsed per task and routine overflow counted, and nothing from it is shown again"
}

# The section's budgets count bytes: a multibyte summary is cut by whole
# characters so each item and the routine list stay inside their byte caps.
test_branch_outcomes_budgets_count_bytes() {
  local home drained wide n routine_block locale
  wide=$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "\342\234\223" }')
  for locale in '' C; do
    home="$TMP_ROOT/drain-bytes-${locale:-inherited}"
    mkdir -p "$home/state" "$home/config"
    : > "$home/config/supervision-host"
    for n in 1 2 3 4 5 6; do
      FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "wide-$n" --verdict routine --summary "$wide" >/dev/null \
        || fail "fixture: could not record routine outcome $n"
    done
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task wide-cap --verdict captain --summary "$wide" >/dev/null \
      || fail "fixture: could not record the captain outcome"
    drained=$(LC_ALL=$locale FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
    assert_contains "$drained" "wide-cap: " "the captain outcome must be presented (locale '$locale')"
    printf '%s\n' "$drained" | LC_ALL=C awk '/^\[seq [0-9]+\] wide-/ && length($0) > 599 { bad = 1 } END { exit bad }' \
      || fail "an item exceeded its 599-byte cap (locale '$locale'): $drained"
    printf '%s\n' "$drained" | grep '^\[seq [0-9]*\] wide-' | grep -qv ' \[truncated\]$' \
      && fail "an over-long multibyte item was not cut with the truncation marker (locale '$locale'): $drained"
    printf '%s\n' "$drained" | grep '^\[seq [0-9]*\] wide-' | perl -ne 'utf8::decode($_) or exit 1' \
      || fail "an item was cut inside a character (locale '$locale')"
    routine_block=$(printf '%s\n' "$drained" | sed -n '/^BRANCH OUTCOMES, ROUTINE/,$p' | grep '^\[seq [0-9]*\] wide-[0-9]')
    [ "$(printf '%s\n' "$routine_block" | LC_ALL=C wc -c | tr -d ' ')" -le 2000 ] \
      || fail "the routine list exceeded its 2000-byte budget (locale '$locale'): $routine_block"
    assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
      "the routine rows past the byte budget must collapse into a count (locale '$locale')"
  done
  pass "drain: the BRANCH OUTCOMES budgets count bytes, cutting multibyte summaries by whole characters in any locale"
}

# A drain whose projection of the store fails has rendered nothing it can
# vouch for, so it marks nothing read and exits nonzero for the return's gate.
test_branch_outcomes_stay_unread_when_a_projection_fails() {
  local home drained rc
  home="$TMP_ROOT/drain-projection"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  : > "$home/config/supervision-host"
  printf '#!/usr/bin/env bash\ncase "$*" in *"newest of"*) exit 5 ;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$home/bin/jq"
  chmod +x "$home/bin/jq"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task cap --verdict captain --summary 'needs your merge call' >/dev/null \
    || fail "fixture: could not record the captain outcome"
  rc=0
  drained=$(PATH="$home/bin:$PATH" FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain whose projection failed must exit nonzero: $drained"
  assert_contains "$drained" "BRANCH OUTCOMES SKIPPED: the outcome store could not be projected safely" \
    "a failed projection must be reported"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "a routine outcome behind a failed projection must follow on the next drain"
  assert_contains "$drained" "[seq 2] cap: needs your merge call" "a captain outcome behind a failed projection must follow on the next drain"
  pass "drain: branch outcomes stay unread when a projection of the store fails"
}

# Without jq the drain cannot present the store, so it marks nothing read and
# exits nonzero for the return's gate.
test_branch_outcomes_stay_unread_without_jq() {
  local home drained rc dir entry path=''
  home="$TMP_ROOT/drain-no-jq"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/jq" ]; then
      mkdir -p "$home/no-jq$dir"
      for entry in "$dir"/*; do
        [ "${entry##*/}" = jq ] || ln -s "$entry" "$home/no-jq$dir/" 2>/dev/null || true
      done
      dir="$home/no-jq$dir"
    fi
    path="${path:+$path:}$dir"
  done <<DIRS
$(printf '%s\n' "$PATH" | tr ':' '\n')
DIRS
  PATH="$path" command -v jq >/dev/null 2>&1 && fail "fixture: jq is still reachable"
  rc=0
  drained=$(PATH="$path" FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain without jq over a non-empty store must exit nonzero: $drained"
  assert_contains "$drained" "BRANCH OUTCOMES SKIPPED: jq is not installed" "a drain without jq must say it could not present the store"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "an outcome a drain without jq could not present must follow on the next drain"
  pass "drain: branch outcomes stay unread and the drain fails when jq is missing"
}

# A drain that cannot print the section, because its output is already
# closed, has presented nothing, so the rows stay unread for the next drain.
test_branch_outcomes_stay_unread_when_the_drain_cannot_print() {
  local home drained
  home="$TMP_ROOT/drain-closed"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" >&- 2>/dev/null' "$ROOT/bin/fm-wake-drain.sh" || true
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "a routine outcome a drain could not print must follow on the next drain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "merged the docs fix" "a routine outcome a drain printed must not repeat"
  pass "drain: branch outcomes stay unread when the drain cannot print them"
}

test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main() {
  local home first drained
  home=$(make_home attended-routine attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "attended: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the attended engine must run as the branch actor"
  assert_no_re '^POSTURE: AWAY' "$first" "an attended wake must carry no away tail"
  assert_re '^(arg=)?FIRSTMATE SUPERVISION WAKE: signal: ' "$first" "the attended wake must carry the close"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "the engine's routine report did not reach the store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended report must queue no return wake for main"
  assert_grep 'it waits in the outcome store for MAIN' "$home/engine-report.log" "an attended routine report must say it stays in the store"
  [ ! -s "$home/host.rc" ] || fail "a routine attended outcome reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a routine attended outcome printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor after an attended wake"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain" \
    "main's next drain must list the routine outcome for awareness"
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "the routine listing must carry the outcome"
  assert_not_contains "$drained" "mark-processed" "a routine outcome must ask for no acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "[seq 1]" "a routine outcome must be listed only once"
  pass "host: an attended wake the branch may take is handled on the engine, and its routine outcome never wakes main"
}

test_attended_captain_outcome_reaches_main_through_branch_outcomes() {
  local home drained
  home=$(make_home attended-captain attended)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "captain: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until 250 host_exited "$home" || fail "captain: the captain outcome did not wake main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a captain-outcome exit must exit 0 for the owner to deliver"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row and send main to its drain"
  assert_no_re '^signal:' "$home/host.out" "the close the engine handled must not reach main as a wake"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "an attended captain report must say main processes it"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended captain report must queue no return wake"
  watcher_live "$home" && fail "the host left its successor cycle running when it woke main"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome"
  assert_contains "$drained" "[seq 1] demo: stub escalated: " "the section must carry the outcome's row, task, and summary"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 1" "the section must print its exact acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: stub escalated: " "an unacknowledged captain outcome must be presented again"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null \
    || fail "main's acknowledgement of the presented outcome was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged captain outcome must not be presented again"
  pass "host: an attended captain outcome wakes main once and stays in its drain until main acknowledges it"
}

test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return() {
  local home drained
  home=$(make_home attended-go-away attended)
  echo go-away > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "go-away: the host never started a watcher cycle"
  append_status "$home" 'finished while the captain left'
  wait_until 250 handled_at_least "$home" 1 || fail "go-away: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  [ -f "$home/state/.afk-contract" ] || fail "fixture: the stub did not record the away posture"
  [ ! -s "$home/host.rc" ] || fail "a captain outcome recorded after the captain left woke main: $(cat "$home/host.out")"
  assert_grep '"verdict":"captain"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "captain outcomes must wait for the return while the away record exists"
  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "after the return the drain must present the away window's captain outcome"
  pass "host: a captain outcome recorded after the captain left waits for the return, then reaches main's drain"
}

test_attended_main_only_close_passes_straight_to_main() {
  local home
  home=$(make_home attended-main-only attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "main-only: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  pass "host: an attended decision close stays main's exactly as the plain arm delivers it"
}

# The session-lock holder's process identity cannot be read (its proc entry
# is truncated), so no main-session key exists: the close reaches main exactly
# as the arm printed it, before any mirror feed or engine turn.
test_attended_close_with_unidentified_main_session_passes_to_main() {
  local home
  home=$(make_home attended-unidentified attended)
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s (claude) S\n" "$$" > "$FM_HOME/proc/$$/stat"
      printf "claude\0" > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc"
      "$0" park > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "unidentified: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "unidentified: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close for an unidentified main session must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "unidentified: the engine ran without a main-session key"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_re '	pass-through	attended	the main session could not be identified	signal:' "$home/state/.supervision-host.log" \
    "the ledger must record why the close went to main"
  pass "host: an attended close whose main session cannot be identified reaches main and runs no engine turn"
}

# The close is accepted attended as routine, then its task turns main-only (a
# decision is recorded) while the successor starts: the turn meets the offer
# rule again, so the close reaches main exactly as the arm printed it and no
# engine turn runs on the stale offer.
test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home real_node
  home=$(make_home attended-turns-main-only attended)
  real_node=$(command -v node)
  # Change the task immediately before the second offer computation, rather
  # than racing the successor startup. The first offer accepts the close; the
  # turn-boundary offer must see the new main-owned decision.
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
case "\$*" in
  *fm-branch-dispatch.mjs\ offer*)
    count=\$(cat "\$FM_HOME/offer-count" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$FM_HOME/offer-count"
    if [ "\$count" -eq 2 ]; then
      printf 'needs-decision [at=%s]: which export format?\n' "\$(date +%s)" >> "\$FM_HOME/state/demo.status"
    fi ;;
esac
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" && fail "the pass-through left the successor watcher running"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
}

# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.
test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" && fail "the pass-through left the successor watcher running"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.
test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until 200 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.
test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}

# Park again after a host was stopped mid-park: the new cycle's first close is
# the watcher's downtime resurface, which main drains before the next park.
# That close can end the park before its cycle is ever seen live, so this
# waits for the exit itself.
park_after_stop() {  # <home>
  rm -f "$1/host.rc"
  : > "$1/park.go"
  wait_until 150 host_exited "$1" || fail "the watcher's downtime resurface did not reach main: $(cat "$1/host.out")"
  assert_re '^check: rearm-resurface' "$1/host.out" "fixture: the first close after the watcher stopped was not its resurface"
  main_drain_and_ack "$1"
  park_again "$1"
}

# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.
test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then sleep 25; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  FM_SUPERVISION_HOST_PARK_SECONDS=40 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  wait_until 250 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  wait_until 250 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  wait_until 250 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}

# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.
test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  wait_until 250 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main() {
  local home handled
  home=$(make_home attended-latch attended)
  echo fail > "$home/stub-mode"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 host_exited "$home" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$home/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$home/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'second'
  wait_until 250 host_exited "$home" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' "$home/host.out" \
    "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$home/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "a close inside the cooldown must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_re '	pass-through	attended	the supervision session is cooling down' "$home/state/.supervision-host.log" \
    "the ledger must record the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  handled=$(handled_count "$home")
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" $((handled + 1)) \
    || fail "latch: the successful probe was not handled: $(cat "$home/host.out"; tail -n 5 "$home/state/.supervision-host.log")"
  assert_re '	recovered	after a successful probe$' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  ! wait_until 20 host_exited "$home" || fail "a routine probe's recovery reached main: $(cat "$home/host.out")"
  assert_no_re '^supervision-host' "$home/host.out" "a recovery must stay off main"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  pass "host: attended, two engine errors latch the session, main keeps every close unchanged in the cooldown, a failed probe doubles it up to its cap, and a routine probe's recovery stays in the ledger, off main"
}

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until 250 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}

# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until 250 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}

# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.
test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until 250 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  wait_until 250 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until 250 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_restarted_host_stops_what_a_killed_predecessor_left() {
  local home first_host arm watcher
  home=$(make_home away-crash away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "crash: the host never started a watcher cycle"
  first_host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$first_host"
  sleep 1
  kill -0 "$arm" 2>/dev/null || fail "crash: fixture error: the arm died with its host, so this case proves nothing"
  start_host "$home"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$arm" "$watcher" \
    || fail "a restarted host left its killed predecessor's arm or watcher running"
  wait_until 100 sh -c 'grep -q "	start	gen=host-" "$1" && [ "$(grep -c "	start	" "$1")" -ge 2 ]' _ "$home/state/.supervision-host.log" \
    || fail "the restarted host did not start"
  pass "host: a restarted host stops, by recorded identity, the cycle a killed predecessor left running"
}

test_park_boundary_ends_the_park_before_the_hook_timeout() {
  local home token
  home=$(make_home boundary attended)
  FM_SUPERVISION_HOST_PARK_SECONDS=3 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary: the host never started a watcher cycle"
  wait_until 150 host_exited "$home" || fail "boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the park boundary must publish downtime for the owner's rewake, got: $token" ;;
  esac
  pass "host: the park ends itself with a boundary wake and a stopped watcher"
}

# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed.
test_park_boundary_holds_under_back_to_back_closes() {
  # The turn bound is the one wall-clock bound left: it must cover the stub's
  # report work after release, so the product never kills the held turn.
  local home park=36 turn=19 grace=1
  home=$(make_home boundary-busy away)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  echo 0 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-busy: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'the first of many'
  wait_until 450 sh -c '[ -e "$1/engine-call.1" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-busy: the host never started the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -e "$home/engine-call.1" ] \
    || fail "boundary-busy: the host exited without starting the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  append_status "$home" 'queued while the first close is still handled'
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/stub-release"
  printf 'release\n' >&3
  wait_until 450 host_exited "$home" \
    || fail "the host kept handling back-to-back closes past its park boundary: $(cat "$home/state/.supervision-host.log")"
  exec 3>&-
  ! grep -q '	failed	' "$home/state/.supervision-host.log" \
    || fail "the held turn hit its turn bound or failed: $(cat "$home/state/.supervision-host.log")"
  [ "$(handled_count "$home")" -eq 1 ] || fail "the held turn did not complete once released: $(cat "$home/state/.supervision-host.log")"
  [ ! -e "$home/engine-call.2" ] || fail "a close waiting at the boundary still got an engine turn"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "a close read at the boundary must be printed ahead of the boundary line: $(cat "$home/host.out")"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close waiting at the boundary must stay queued for main"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  pass "host: waiting closes cannot carry the park past its boundary"
}

# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards.
test_park_boundary_rechecked_just_before_the_engine_turn() {
  local home real_node pid park=14 turn=3 grace=1
  home=$(make_home boundary-late away)
  real_node=$(command -v node)
  mkfifo "$home/render-release"
  echo 0 > "$home/park-clock"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ]; then
  cp "\$FM_HOME/state/.supervision-host" "\$FM_HOME/host-record-at-render" 2>/dev/null
  read -r _ < "\$FM_HOME/render-release"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-late: the host never started a watcher cycle"
  append_status "$home" 'arrives with just enough margin'
  wait_until 300 sh -c '[ -s "$1/host-record-at-render" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-late: the host neither reached the wake render nor exited: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -s "$home/host-record-at-render" ] \
    || fail "the close was stopped before the successor started: $(cat "$home/host.out")"
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/render-release"
  printf 'release\n' >&3
  wait_until 300 host_exited "$home" || fail "boundary-late: the host did not end its park"
  exec 3>&-
  assert_re '^signal: .*demo.status' "$home/host.out" "the close read at the boundary must reach main"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "the close must be printed ahead of the boundary line: $(cat "$home/host.out")"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "an engine turn started that could run past the boundary"
  assert_no_re '	(handled|failed)	turn=' "$home/state/.supervision-host.log" "no engine turn may be logged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close refused at the boundary must stay queued for main"
  while IFS= read -r pid; do
    kill -0 "$pid" 2>/dev/null && fail "the boundary left the successor arm $pid running"
  done < <(awk -F '\t' '$1 == "arm" { print $2 }' "$home/host-record-at-render")
  watcher_live "$home" && fail "the boundary left the watcher running"
  pass "host: a close whose margin runs out while the successor starts reaches main at the boundary without a turn"
}

# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.
test_park_test_clock_requires_the_marker() {
  local home
  home=$(make_home clock-armed away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 host_exited "$home" || fail "clock-armed: the marked test clock did not end the park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the marked test clock must drive the boundary"

  home=$(make_home clock-unmarked away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SEAM='' FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "clock-unmarked: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'handled on the wall clock'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "a test clock without FM_TEST_SEAM changed the park: $(cat "$home/host.out" "$home/state/.supervision-host.log")"
  [ ! -s "$home/host.rc" ] || fail "a test clock without FM_TEST_SEAM ended the park: $(cat "$home/host.out")"
  assert_no_re 'cycle boundary' "$home/host.out" "a test clock without FM_TEST_SEAM reached the boundary"
  pass "host: the park's test clock is inert without the test marker"
}

# A park at or beyond the hook registration is refused for the default. The
# default is observable through the pre-turn margin: a turn bound plus grace of
# 27000 seconds crosses a 27000-second park, so the close goes to main at the
# boundary, while under a 28799-second park the same turn runs.
park_outcome() {  # <name> <park-seconds>; sets PARK_OUTCOME to boundary or handled
  local home
  home=$(make_home "$1" away)
  FM_SUPERVISION_HOST_PARK_SECONDS=$2 FM_SUPERVISION_HOST_TURN_TIMEOUT=26990 FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "$1: the host never started a watcher cycle"
  append_status "$home" 'one close'
  wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
    || fail "$1: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
  if host_exited "$home"; then
    grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$1: the host exited without the boundary: $(cat "$home/host.out")"
    ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "$1: an engine turn ran before the boundary exit"
    PARK_OUTCOME=boundary
  else
    kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
    wait_until 200 host_exited "$home" || fail "$1: the host did not stop on TERM"
    PARK_OUTCOME=handled
  fi
}

test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default() {
  park_outcome park-28799 28799
  [ "$PARK_OUTCOME" = handled ] || fail "a park just under the registration must be honored"
  park_outcome park-28800 28800
  [ "$PARK_OUTCOME" = boundary ] || fail "a park at the registration must fall back to the default"
  park_outcome park-huge 100000000000000000000
  [ "$PARK_OUTCOME" = boundary ] || fail "a park far beyond the registration must fall back to the default"
  pass "host: a park at or beyond the Stop-hook registration falls back to the default boundary"
}

# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.
test_park_limit_lets_a_turn_outlive_the_boundary() {
  local cases name limit want home
  cases='limit-later:28000:handled limit-earlier:50:boundary limit-registration:28800:boundary limit-absent::boundary'
  for c in $cases; do
    name=${c%%:*}; limit=${c#*:}; want=${limit#*:}; limit=${limit%%:*}
    home=$(make_home "$name" away)
    FM_SUPERVISION_HOST_PARK_SECONDS=100 FM_SUPERVISION_HOST_PARK_LIMIT=$limit FM_SUPERVISION_HOST_TURN_TIMEOUT=200 \
      FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$name: the host never started a watcher cycle"
    append_status "$home" 'one close'
    wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
      || fail "$name: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
    if host_exited "$home"; then
      grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$name: the host exited without the boundary: $(cat "$home/host.out")"
      [ "$want" = boundary ] || fail "$name: a turn inside the owner's limit was refused at the boundary"
    else
      [ "$want" = handled ] || fail "$name: a turn past the boundary ran without a later limit"
      kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
      wait_until 200 host_exited "$home" || fail "$name: the host did not stop on TERM"
    fi
  done
  pass "host: an owner's later park limit lets a turn outlive the boundary, and no other limit does"
}

# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.
test_first_cycle_status_streams_and_owner_options_reach_it() {
  local home stale fresh generation predecessor
  home=$(make_home stream attended pi)
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" \
    || fail "stream: the first cycle's status did not reach the owner before a close: $(cat "$home/host.out")"
  host_exited "$home" && fail "stream: the host exited before any close: $(cat "$home/host.out")"
  append_status "$home" 'fixture finished' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the attended close did not reach main"
  [ "$(grep -c '^watcher: ' "$home/host.out")" -eq 1 ] || fail "stream: the status line must be printed once: $(cat "$home/host.out")"
  [ "$(sed -n '1p' "$home/host.out" | cut -c1-17)" = 'watcher: started ' ] || fail "stream: the status line must come first"
  assert_re '^signal: .*demo.status' "$home/host.out" "stream: the close must follow the status line"
  # Main handles that close, so the next cycle has no episode to resurface.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$home/drain.err" || fail "stream: main's drain failed"
  ack_drain_err "$home/state" "$home/drain.err" >/dev/null 2>&1 || fail "stream: main's acknowledgement failed: $(cat "$home/drain.err")"

  # A watcher a dead arm left behind, holding this home's watcher lock.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-watch-arm.sh" \
    > "$home/stale-arm.out" 2>&1 &
  wait_until 150 watcher_live "$home" || fail "stream: the fixture watcher never started"
  kill -KILL "$!" 2>/dev/null || true
  wait "$!" 2>/dev/null || true
  stale=$(cat "$home/state/.watch.lock/pid")
  rm -f "$home/host.out" "$home/host.rc"
  start_host "$home" --restart
  # Stopping the old watcher opens a downtime episode, so the fresh cycle may
  # close on its resurface before the arm confirms it, and the arm then prints
  # only that close (bin/fm-watch-arm.sh): either order is the owner's cycle.
  wait_until 150 sh -c 'grep -qs "^watcher: started pid=" "$1/host.out" || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "stream: the restarting host never reported its cycle: $(cat "$home/host.out" "$home/claude.err" 2>/dev/null)"
  fresh=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$home/host.out")
  [ "$fresh" != "$stale" ] || fail "stream: --restart attached to the watcher it should have replaced"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$stale" || fail "stream: --restart left the old watcher running"
  wait_until 200 host_exited "$home" || append_status "$home" 'second close' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the restarting host's close did not reach main"
  assert_re '^(signal: .*demo.status|check: rearm-resurface)$' "$home/host.out" "stream: the restarting host's close must reach main"

  # That close left an unacknowledged downtime episode; a host the owner starts
  # as the closed arm's successor takes it over as a handling successor
  # instead of re-announcing it.
  generation=$(sed -n 's/^[a-z]*:[a-z]*://p' "$home/state/.watcher-down")
  [ -n "$generation" ] || fail "fixture: the close left no downtime episode: $(cat "$home/state/.watcher-down")"
  predecessor=$(sed -n '1p' "$home/claude-pids")
  rm -f "$home/host.out" "$home/host.rc"
  FM_WATCH_PREDECESSOR_ARM_PID=$predecessor start_host "$home" --restart
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" || fail "stream: the successor host never reported its cycle"
  assert_re "^watcher: started pid=[0-9]+ \\(beacon fresh\\) recovery-generation=$generation\$" "$home/host.out" \
    "the owner's predecessor must make the first cycle a handling successor of the pending generation"
  sleep 3
  host_exited "$home" && fail "a handling successor re-announced the pending episode: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "stream: the successor host did not stop on TERM"
  pass "host: the first cycle's status streams once, --restart replaces a stale watcher, and an owner predecessor makes a handling successor"
}

# Main's side of a handed-back wake: drain, then run the printed acknowledgement.
main_drain_and_ack() {  # <home>
  local out ack
  out=$(FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$ack" ] || FM_HOME="$1" "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1 || fail "main's acknowledgement failed: $ack"
}

# One main session across several parks, as a primary's arm owner runs the host
# again at each turn end: the session lock stays this one fake harness, so the
# host's per-session state (the latch, the engine conversation) carries
# across its parks; the mirror seeds are written before each park, as in
# start_host.
start_session() {  # <home>
  local home=$1
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      while [ ! -e "$FM_HOME/session.stop" ]; do
        if [ -e "$FM_HOME/park.go" ]; then
          rm -f "$FM_HOME/park.go"
          for seed in "$FM_HOME"/mirror-seed.*; do
            [ -f "$seed" ] || continue
            FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$seed"
          done
          "$0" park > "$FM_HOME/host.out" 2>&1
          printf "%s\n" "$?" > "$FM_HOME/host.rc"
        fi
        sleep 0.1
      done
    ' "$HOST" 2>> "$home/claude.err" &
}

park_again() {  # <home>
  rm -f "$1/host.rc"
  : > "$1/park.go"
  wait_until 150 watcher_live "$1" \
    || fail "the next park never started a watcher cycle: $(cat "$1/host.out"; tail -n 5 "$1/state/.supervision-host.log" 2>/dev/null)"
}

# Let the latch's cooldown pass, as the clock would, by moving its persisted
# probe time into the past, optionally with a cooldown already grown to
# <seconds>; the next close then probes the engine.
end_cooldown() {  # <home> [seconds]
  local health="$1/state/.supervision-host-health" tmp
  grep -q '^retry_after=[1-9]' "$health" 2>/dev/null || fail "the latch recorded no probe time"
  tmp=$(mktemp "$health.XXXXXX")
  if ! { sed -e 's/^retry_after=.*/retry_after=1/' ${2:+-e "s/^cooldown=.*/cooldown=$2/"} "$health" > "$tmp" \
    && mv -f "$tmp" "$health"; }; then
    fail "fixture: could not move the latch's probe time"
  fi
}

# Two consecutive engine errors in one main session: the second trips the latch.
trip_latch() {  # <home>
  echo fail > "$1/stub-mode"
  start_session "$1"
  park_again "$1"
  append_status "$1" 'first'
  wait_until 250 host_exited "$1" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$1/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$1"
  park_again "$1"
  append_status "$1" 'second'
  wait_until 250 host_exited "$1" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the tripping handback must still say why"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' \
    "$1/host.out" "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$1/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$1"
}

test_latch_trips_after_two_engine_errors_then_probes_and_recovers() {
  local home
  home=$(make_home away-latch away)
  trip_latch "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_re '^supervision-host: the away session is paused after repeated engine errors until .*; this wake is yours$' \
    "$home/host.out" "a close inside the cooldown must say why main has it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close inside the cooldown must stay durable for main"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" 1 || fail "latch: the successful probe was not handled: $(cat "$home/host.out")"
  [ "$(engine_calls "$home")" -eq 5 ] || fail "the cooldown's end did not let the recovering wake probe the engine"
  host_exited "$home" && fail "an away recovery must not reach main: $(cat "$home/host.out")"
  assert_re '	recovered	after a successful probe' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  watcher_live "$home" || fail "the recovered host is not parked on a live successor cycle"
  pass "host: two engine errors latch the session, main keeps every away wake in the cooldown, a failed probe doubles it up to its cap, and a report recovers it silently"
}

# The latch lives only in the opted-in host's away path: an attended close in a
# latched session and a home that dropped config/supervision-host both reach
# main exactly as they do without it.
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes() {
  local home health
  home=$(make_home latch-scope away)
  trip_latch "$home"
  health=$(cat "$home/state/.supervision-host-health")

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  park_again "$home"
  append_status "$home" 'attended while latched'
  wait_until 250 host_exited "$home" || fail "latch scope: the attended close did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "an attended close in a latched session must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "an attended close in a latched session must reach main exactly as the arm printed it"
  [ "$(cat "$home/state/.supervision-host-health")" = "$health" ] || fail "an attended close changed the latch"
  main_drain_and_ack "$home"

  rm -f "$home/config/supervision-host"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture again"
  park_again "$home"
  append_status "$home" 'away without the file'
  wait_until 250 host_exited "$home" || fail "latch scope: the close without the file did not reach main"
  assert_re '^supervision-host: the home no longer opts into the supervision host$' "$home/host.out" \
    "a home without the file must hand the close back as the opt-out, not the latch"
  assert_no_re 'paused' "$home/host.out" "a home without the file must not read the latch"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "an engine ran after the latch tripped"
  pass "host: an attended close in a latched session reaches main as the arm printed it and leaves the latch as it was, and a home without config/supervision-host never reads it"
}

# The 2026-09-25 away-window flood: a held, green PR on a finished task was
# re-escalated on every inactive-outcome cadence, because the branch
# acknowledgement consumed the check row but left its terminal-outcome receipt
# pending, so each later scan re-queued the same fingerprint. Through the real
# watcher cadence, host, report surface, and drain, that unchanged situation
# now reaches the captain exactly once, and a new event on the same task - a
# decision - still reaches the captain path afterwards.
scan_marker_age() {  # <home> -> seconds since the last inactive-outcome scan
  perl -e 'my @s = stat $ARGV[0] or exit 1; print time - $s[9]' "$1/state/.inactive-outcome-reconcile"
}
scan_ran() { [ "$(scan_marker_age "$1" 2>/dev/null || echo 999999)" -lt 60 ]; }
captain_rows() {  # <home>
  local rows
  rows=$(grep -c '"verdict":"captain"' "$1/state/branch-outcomes.jsonl" 2>/dev/null)
  printf '%s\n' "${rows:-0}"
}
captain_rows_at_least() { [ "$(captain_rows "$1")" -ge "$2" ]; }
flood_signal() {  # <home>
  captain_rows_at_least "$1" 2 || grep -qs '	inactive-outcome:' "$1/state/.wake-queue"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    ! wait_until 30 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}

test_host_outside_the_lock_owner_stands_down() {
  local home out rc other
  home=$(make_home not-owner attended)
  "$FAKE_CLAUDE" -c 'sleep 30' &
  other=$!
  printf '%s\n' "$other" >> "$home/claude-pids"
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$home/fakebin:$PATH" "$HOST" park 2>&1); rc=$?
  expect_code 0 "$rc" "a host that does not own supervision exits 0"
  assert_contains "$out" "supervision-host stood down: this session does not own supervision" "the stand-down must say why"
  watcher_live "$home" && fail "a host that does not own supervision started a watcher"
  kill -TERM "$other" 2>/dev/null || true
  pass "host: a host outside the session-lock owner stands down without arming"
}

test_superseded_host_leaves_the_owner_untouched() {
  local home owner watcher lock_pid
  home=$(make_home superseded away)
  # One fake harness runs the owner host, then, on a signal file, a second host
  # under an auto-arm generation the ledger has already superseded.
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      "$0" park > "$FM_HOME/host.out" 2>&1 &
      while [ ! -e "$FM_HOME/go-second" ]; do sleep 0.1; done
      FM_SUPERVISION_HOST_AUTOARM_GEN=1 FM_SUPERVISION_HOST_OWNER_PID=$$ "$0" park > "$FM_HOME/host2.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host2.rc"
      wait
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "superseded: the owner host never started a watcher cycle"
  owner=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  lock_pid=$(cat "$home/state/.lock")
  printf 'epoch=2 owner_pid=%s outcome=arming\n' "$lock_pid" > "$home/state/.claude-autoarm-epoch"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$lock_pid" "$LEASE" claim demo >/dev/null 2>&1 \
    || fail "fixture: could not hold a branch lease"
  : > "$home/go-second"
  wait_until 200 sh -c '[ -s "$1" ]' _ "$home/host2.rc" || fail "superseded: the second host did not return"
  expect_code 0 "$(cat "$home/host2.rc")" "a superseded host exits 0"
  assert_grep 'supervision-host stood down: this session does not own supervision' "$home/host2.out" "the stand-down must say why"
  kill -0 "$owner" 2>/dev/null || fail "a superseded host stopped the owner host"
  [ "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")" = "$owner" ] \
    || fail "a superseded host took the owner's host record"
  if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
    fail "a superseded host stopped the owner's watcher"
  fi
  FM_HOME="$home" "$LEASE" check demo 2>/dev/null | grep -q '^branch ' || fail "a superseded host released the owner's branch leases"
  kill -TERM "$owner"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$owner" "$watcher" \
    || fail "superseded: the owner host did not stop on TERM"
  pass "host: a host under a superseded auto-arm generation stands down without touching the owner"
}

test_report_surface_enforces_actor_turn_and_scope
test_report_after_the_return_is_queued_for_main
test_dispatch_entry_scopes_rows_and_renders_the_away_tail
test_branch_outcomes_only_on_an_opted_in_home_off_pi
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task
test_branch_outcomes_present_a_long_away_window_once
test_branch_outcomes_budgets_count_bytes
test_branch_outcomes_stay_unread_when_a_projection_fails
test_branch_outcomes_stay_unread_without_jq
test_branch_outcomes_stay_unread_when_the_drain_cannot_print
test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main
test_attended_captain_outcome_reaches_main_through_branch_outcomes
test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return
test_attended_main_only_close_passes_straight_to_main
test_attended_close_with_unidentified_main_session_passes_to_main
test_close_accepted_away_that_turns_attended_passes_to_main
test_attended_close_that_turns_main_only_before_its_turn_passes_to_main
test_primary_without_a_verified_mirror_runs_away_only
test_attended_wake_carries_the_dialog_mirror
test_dialog_bearing_files_are_owner_only
test_undelivered_dialog_is_fed_again_on_the_next_turn
test_attended_wake_with_an_unreadable_mirror_reaches_main
test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_report_without_acknowledgement_hands_the_wake_to_main
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_latch_trips_after_two_engine_errors_then_probes_and_recovers
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes
test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_park_boundary_ends_the_park_before_the_hook_timeout
test_park_boundary_holds_under_back_to_back_closes
test_park_boundary_rechecked_just_before_the_engine_turn
test_park_test_clock_requires_the_marker
test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
test_park_limit_lets_a_turn_outlive_the_boundary
test_first_cycle_status_streams_and_owner_options_reach_it
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
test_host_outside_the_lock_owner_stands_down
test_superseded_host_leaves_the_owner_untouched
