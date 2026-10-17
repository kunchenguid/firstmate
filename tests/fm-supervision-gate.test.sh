#!/usr/bin/env bash
# Behavior tests for the supervision host's repeat bound and pre-turn judge hook
# (bin/fm-supervision-gate.sh, docs/supervision-host.md "The repeat bound"),
# driven through the gate's own commands against real wake-queue rows and a
# real outcome store. tests/fm-supervision-host.test.sh covers the host
# recording a skip and consuming its rows.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GATE="$ROOT/bin/fm-supervision-gate.sh"
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-supervision-gate)

# A home whose task "demo" is idle: a status log, one silent outcome recorded
# after it, and one plain stale wake queued since.
make_gate_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'window=test:fm-demo\n' > "$home/state/demo.meta"
  printf 'working [at=1]: idle at its prompt\n' > "$home/state/demo.status"
  FM_HOME="$home" "$OUTCOME" append --task demo --verdict routine --silent true \
    --summary 'still idle at its prompt; nothing new; no action' >/dev/null \
    || fail "fixture: the silent outcome was not recorded"
  append_wake "$home/state" stale test:fm-demo 'stale: test:fm-demo' || fail "fixture: the stale wake was not queued"
  printf '%s\n' "$home"
}

queued_seqs() {  # <home> <kind>
  awk -F '\t' -v kind="$2" '$3 == kind { printf "%s%s", sep, $2; sep = " " }' "$1/state/.wake-queue"
}

decide() {  # <home> [rows] [extra decide args...]
  local home=$1 rows=${2:-}
  [ -n "$rows" ] || rows=$(queued_seqs "$home" stale)
  shift 2 2>/dev/null || shift
  FM_HOME="$home" "$GATE" decide --task demo --posture away --rows "$rows" "$@"
}

field() {  # <gate-output> <name>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

expect_decision() {  # <gate-output> <decision> <msg>
  [ "$(field "$1" decision)" = "$2" ] || fail "$3"$'\n'"$1"
}

# Records a skip's outcome the way the host does: the gate's own summary as a
# silent routine outcome.
record_skip() {  # <home> <gate-output>
  FM_HOME="$1" "$OUTCOME" append --task demo --verdict routine --silent true \
    --summary "$(field "$2" summary)" >/dev/null || fail "the skip's outcome was not recorded"
}

# A judge that records its input next to itself and answers with its name's
# behavior: skip, turn, garbage, slow (sleeps past the 10s bound), or fail.
make_judge() {  # <home> <behavior>
  local judge="$1/judge-$2"
  {
    printf '#!/usr/bin/env bash\ncat > "%s/judge-input.json"\n' "$1"
    case "$2" in
      skip) printf 'echo skip\n' ;;
      turn) printf 'echo turn\n' ;;
      garbage) printf 'echo "skip it, probably"\n' ;;
      slow) printf 'sleep 30\necho skip\n' ;;
      fail) printf 'echo skip\nexit 3\n' ;;
    esac
  } > "$judge"
  chmod +x "$judge"
  printf '%s\n' "$judge"
}

test_unchanged_repeat_of_a_silent_outcome_is_skipped() {
  local home out
  home=$(make_gate_home skip)
  out=$(decide "$home")
  expect_decision "$out" skip "an unchanged stale repeat of a silent outcome must skip"
  [ "$(field "$out" judge)" = none ] || fail "no judge file must mean no judge: $out"
  [ "$(field "$out" skips)" = 0 ] || fail "a first skip must report no prior skips: $out"
  assert_contains "$(field "$out" summary)" "demo unchanged since outcome 1" "the skip's outcome must name what it repeats"
  pass "gate: a plain stale wake whose task is unchanged since a recent silent outcome skips its turn"
}

test_any_new_evidence_takes_a_turn() {
  local home out
  home=$(make_gate_home status-grew)
  printf 'working [at=2]: a new line\n' >> "$home/state/demo.status"
  out=$(decide "$home")
  expect_decision "$out" turn "a status log that grew must take a turn"
  assert_contains "$(field "$out" why)" "status log changed" "the turn must say the status log changed"

  home=$(make_gate_home visible)
  FM_HOME="$home" "$OUTCOME" append --task demo --verdict routine --summary 'nudged the worker' >/dev/null
  expect_decision "$(decide "$home")" turn "a previous outcome that acted must take a turn"

  home=$(make_gate_home captain)
  FM_HOME="$home" "$OUTCOME" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null
  expect_decision "$(decide "$home")" turn "a previous captain outcome must take a turn"

  home=$(make_gate_home first-sight)
  FM_HOME="$home" "$GATE" decide --task other --posture away --rows "$(queued_seqs "$home" stale)" > "$home/out"
  expect_decision "$(cat "$home/out")" turn "a task with no previous outcome must take a turn"

  home=$(make_gate_home old)
  sed 's/"epoch":[0-9]*/"epoch":1/' "$home/state/branch-outcomes.jsonl" > "$home/store" \
    && mv "$home/store" "$home/state/branch-outcomes.jsonl"
  out=$(decide "$home")
  expect_decision "$out" turn "a previous outcome older than the window must take a turn"
  assert_contains "$(field "$out" why)" "older than 3600s" "the turn must name the window"
  pass "gate: a grown status log, an acting or captain outcome, no outcome, or an old one each takes a turn"
}

test_only_plain_stale_rows_are_ever_skipped() {
  local home stale
  home=$(make_gate_home signal)
  append_wake "$home/state" signal demo.status 'signal: demo.status' || fail "fixture: signal append failed"
  expect_decision "$(decide "$home" "$(queued_seqs "$home" signal)")" turn "a signal row must never skip"
  stale=$(queued_seqs "$home" stale)
  expect_decision "$(decide "$home" "$stale $(queued_seqs "$home" signal)")" turn "a stale row granted beside a signal must take a turn"

  home=$(make_gate_home decision)
  printf 'needs-decision [at=3] [key=merge]: merge or hold?\n' >> "$home/state/demo.status"
  append_wake "$home/state" signal demo.status 'needs-decision: signal: demo.status' || fail "fixture: decision append failed"
  expect_decision "$(decide "$home" "$(queued_seqs "$home" signal)")" turn "a decision row must never skip"

  home=$(make_gate_home wedge)
  : > "$home/state/.wake-queue"
  append_wake "$home/state" stale test:fm-demo 'stale: test:fm-demo (idle 900s, possible wedge, escalation 1)' \
    || fail "fixture: wedge append failed"
  expect_decision "$(decide "$home")" turn "a stale row carrying watcher detail must take a turn"

  home=$(make_gate_home missing)
  expect_decision "$(decide "$home" 999)" turn "a granted row no longer queued must take a turn"
  pass "gate: signal, decision, detailed stale, missing, and mixed rows always take a turn"
}

test_skips_in_a_row_stop_at_the_cap() {
  local home out n
  home=$(make_gate_home cap)
  for n in 0 1 2 3 4; do
    out=$(decide "$home")
    expect_decision "$out" skip "wake $((n + 1)) after $n skips in a row must skip"
    [ "$(field "$out" skips)" = "$n" ] || fail "the gate must report $n prior skips: $out"
    assert_contains "$(field "$out" summary)" "skip $((n + 1)) of at most 5" "the skip's outcome must carry its place in the run"
    record_skip "$home" "$out"
  done
  out=$(decide "$home")
  expect_decision "$out" turn "the sixth wake after five skips in a row must take a turn"
  assert_contains "$(field "$out" why)" "cap of 5" "the turn must name the cap"
  # A real turn's outcome ends the run.
  FM_HOME="$home" "$OUTCOME" append --task demo --verdict routine --silent true --summary 'engine: still idle' >/dev/null
  out=$(decide "$home")
  expect_decision "$out" skip "a real turn's silent outcome must restart the count"
  [ "$(field "$out" skips)" = 0 ] || fail "a real turn's outcome must read as no skips: $out"
  pass "gate: consecutive skips stop at the cap, and a real turn's outcome resets the count"
}

test_attended_skip_needs_a_feed_without_the_captain() {
  local home rows
  home=$(make_gate_home attended)
  rows=$(queued_seqs "$home" stale)
  printf '[main] the fleet is quiet\n' > "$home/feed"
  expect_decision "$(FM_HOME="$home" "$GATE" decide --task demo --posture attended --rows "$rows" --mirror-file "$home/feed")" \
    skip "an attended feed holding only main's words must allow a skip"
  printf '[captain] check on demo please\n' >> "$home/feed"
  expect_decision "$(FM_HOME="$home" "$GATE" decide --task demo --posture attended --rows "$rows" --mirror-file "$home/feed")" \
    turn "captain words in the feed must take a turn"
  expect_decision "$(FM_HOME="$home" "$GATE" decide --task demo --posture attended --rows "$rows")" \
    turn "an attended wake with no feed must take a turn"
  pass "gate: attended, a feed carrying the captain's words or no feed at all takes a turn"
}

test_judge_on_decides_only_a_bound_skip() {
  local home out judge
  home=$(make_gate_home judge-on)
  make_judge "$home" skip >/dev/null
  printf 'on judge-skip\n' > "$home/config/supervision-judge"
  out=$(decide "$home")
  expect_decision "$out" skip "an on judge answering skip must skip"
  [ "$(field "$out" judge)" = skip ] || fail "the judge's answer must be reported: $out"
  [ "$(jq -r '[.version, .mode, .task, .wake.kind, .previousOutcome.seq, .previousOutcome.silent, .consecutiveSkips, .latestStatusLine] | @tsv' "$home/judge-input.json")" \
    = "$(printf '1\ton\tdemo\tstale\t1\ttrue\t0\tworking [at=1]: idle at its prompt')" ] \
    || fail "the judge must receive the wake's state as JSON: $(cat "$home/judge-input.json")"
  assert_contains "$(jq -r '.wake.rows[0].reason' "$home/judge-input.json")" 'stale: test:fm-demo' "the judge must see the wake reason"

  rm -f "$home/judge-input.json"
  printf 'working [at=2]: moved on\n' >> "$home/state/demo.status"
  out=$(decide "$home")
  expect_decision "$out" turn "a judge must never widen a turn the bound takes"
  [ "$(field "$out" judge)" = none ] || fail "the judge must not be asked when the bound takes a turn: $out"
  assert_absent "$home/judge-input.json" "the judge ran for a wake the bound already sent to a turn"

  for judge in turn garbage fail; do
    home=$(make_gate_home "judge-$judge")
    make_judge "$home" "$judge" >/dev/null
    printf 'on %s\n' "$home/judge-$judge" > "$home/config/supervision-judge"
    out=$(decide "$home")
    expect_decision "$out" turn "an on judge that answered $judge must take a turn"
  done
  [ "$(field "$out" judge)" = exit-3 ] || fail "a failing judge must be reported by its exit status: $out"
  home=$(make_gate_home judge-slow)
  make_judge "$home" slow >/dev/null
  printf 'on judge-slow\n' > "$home/config/supervision-judge"
  out=$(decide "$home")
  expect_decision "$out" turn "a judge past its bound must take a turn"
  [ "$(field "$out" judge)" = timeout ] || fail "a judge past its bound must be reported as a timeout: $out"
  pass "gate: an on judge decides only wakes the bound would skip, and any answer but skip, a failure, or a timeout takes a turn"
}

test_unusable_judge_file_takes_a_turn() {
  local home line out n=0
  for line in 'sometimes judge-skip' 'on' 'on judge-missing' 'on not-executable'; do
    n=$((n + 1))
    home=$(make_gate_home "judge-invalid-$n")
    make_judge "$home" skip >/dev/null
    : > "$home/not-executable"
    printf '%s\n' "$line" > "$home/config/supervision-judge"
    out=$(decide "$home")
    expect_decision "$out" turn "judge file '$line' must take a turn"
    [ "$(field "$out" judge)" = invalid ] || fail "judge file '$line' must be reported invalid: $out"
  done
  pass "gate: a judge file with an unknown mode, no executable, or an unrunnable one takes a turn"
}

test_shadow_judge_never_skips_but_records_its_verdict() {
  local home out
  home=$(make_gate_home shadow-skip)
  make_judge "$home" skip >/dev/null
  printf '# measure first\nshadow judge-skip\n' > "$home/config/supervision-judge"
  out=$(decide "$home")
  expect_decision "$out" turn "a shadow judge must never skip"
  [ "$(field "$out" judge)" = skip ] || fail "a shadow judge's answer must be reported: $out"
  assert_contains "$(field "$out" why)" "would skip" "the shadow turn must record what would have happened"
  home=$(make_gate_home shadow-turn)
  make_judge "$home" turn >/dev/null
  printf 'shadow judge-turn\n' > "$home/config/supervision-judge"
  out=$(decide "$home")
  expect_decision "$out" turn "a shadow judge answering turn must take a turn"
  assert_contains "$(field "$out" why)" "would turn" "the shadow turn must record the judge's turn"
  pass "gate: a shadow judge never skips and records what it would have decided"
}

test_unchanged_repeat_of_a_silent_outcome_is_skipped
test_any_new_evidence_takes_a_turn
test_only_plain_stale_rows_are_ever_skipped
test_skips_in_a_row_stop_at_the_cap
test_attended_skip_needs_a_feed_without_the_captain
test_judge_on_decides_only_a_bound_skip
test_unusable_judge_file_takes_a_turn
test_shadow_judge_never_skips_but_records_its_verdict
