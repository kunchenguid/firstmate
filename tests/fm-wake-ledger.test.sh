#!/usr/bin/env bash
# tests/fm-wake-ledger.test.sh - the wake-outcome ledger's contract:
# record format, the closed outcome vocabulary, sanitization, task attribution,
# drain integration, the never-block guarantee, concurrent-append safety, and
# the report's counts and coverage.
#
# The never-block guarantee is the safety-critical half. Two cases prove it:
# an unwritable ledger leaves the drain's raw rows and exit status untouched,
# and a deliberately slowed ledger phase never blocks a concurrent wake append.
#
# Teardown's terminal-record write is covered where teardown's own fixture
# lives, in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LEDGER="$ROOT/bin/fm-wake-ledger.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-ledger-tests)

# A sandboxed home for one case: echoes its dir, with state/ and data/ ready.
make_home() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data"
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

# Run the ledger against <home>.
ledger() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$LEDGER" "$@"
}

ledger_file() {
  printf '%s\n' "$1/data/wake-ledger.tsv"
}

# The value of <field> on the first line matching <record> kind, or empty.
field_of() {  # <file> <record> <field>
  LC_ALL=C awk -F '\t' -v want="$2" -v key="$3" '
    $1 == "v1" && $2 == want {
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0 && substr($i, 1, p - 1) == key) { print substr($i, p + 1); exit }
      }
      exit
    }
  ' "$1"
}


test_record_format_for_all_three_kinds() {
  local home file now
  home=$(make_home format)
  file=$(ledger_file "$home")
  now=$(date +%s)

  printf '%s\t7\tsignal\talpha.status\tsignal: alpha\n' "$((now - 12))" \
    | ledger "$home" drain-record || fail "format: drain-record failed"
  ledger "$home" outcome steered 7 || fail "format: outcome failed"
  ledger "$home" task alpha --outcome landed --harness pi --model sol --effort medium \
    || fail "format: task failed"

  [ "$(wc -l < "$file" | tr -d ' ')" -eq 3 ] || fail "format: expected three records"
  LC_ALL=C awk -F '\t' '$1 != "v1" || NF < 4 { bad = 1 } END { exit bad + 0 }' "$file" \
    || fail "format: a record was not a well-formed v1 line"

  [ "$(field_of "$file" wake seq)" = 7 ] || fail "format: wake seq not recorded"
  [ "$(field_of "$file" wake kind)" = signal ] || fail "format: wake kind not recorded"
  [ "$(field_of "$file" wake task)" = alpha ] || fail "format: wake task not attributed"
  [ "$(field_of "$file" wake latency)" = 12 ] || fail "format: wake latency not computed"
  [ "$(field_of "$file" wake queued)" = "$((now - 12))" ] || fail "format: queued epoch not recorded"

  [ "$(field_of "$file" outcome outcome)" = steered ] || fail "format: outcome token not recorded"
  [ "$(field_of "$file" outcome task)" = alpha ] || fail "format: outcome task not resolved from its wake"
  [ "$(field_of "$file" outcome queued)" = "$((now - 12))" ] \
    || fail "format: outcome queued not copied from its wake record"

  [ "$(field_of "$file" task harness)" = pi ] || fail "format: task harness not recorded"
  [ "$(field_of "$file" task model)" = sol ] || fail "format: task model not recorded"
  [ "$(field_of "$file" task escalated)" = unknown ] || fail "format: absent escalation must record unknown"
  # The wake count is computed from wake records, never serialized on the task.
  [ -z "$(field_of "$file" task wakes)" ] || fail "format: task record must not store a wake count"
  pass "each record kind writes a well-formed v1 line with its expected fields"
}

test_outcome_vocabulary_is_closed() {
  local home file token
  home=$(make_home vocabulary)
  file=$(ledger_file "$home")

  for token in absorbed inspected steered decided escalated repaired false-positive; do
    ledger "$home" outcome "$token" 1 >/dev/null 2>&1 \
      || fail "vocabulary: $token should be accepted"
  done
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 7 ] || fail "vocabulary: expected seven accepted records"

  for token in handled ignored '' STEERED steered-ish; do
    if ledger "$home" outcome "$token" 1 >/dev/null 2>&1; then
      fail "vocabulary: '$token' should have been refused"
    fi
  done
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 7 ] \
    || fail "vocabulary: a refused token still wrote a record"
  pass "the outcome vocabulary is closed and a refused token writes nothing"
}

test_terminal_outcome_and_escalation_are_validated() {
  local home file
  home=$(make_home terminal-validation)
  file=$(ledger_file "$home")

  ledger "$home" task alpha --outcome shipped >/dev/null 2>&1 \
    && fail "terminal: an unknown terminal outcome should be refused"
  ledger "$home" task alpha --escalated maybe >/dev/null 2>&1 \
    && fail "terminal: an unknown escalation value should be refused"
  ledger "$home" task alpha --findings lots >/dev/null 2>&1 \
    && fail "terminal: a non-numeric findings count should be refused"
  ledger "$home" task ../escape >/dev/null 2>&1 \
    && fail "terminal: an unsafe task id should be refused"
  [ ! -s "$file" ] || fail "terminal: a refused terminal record still wrote a line"

  ledger "$home" task alpha --outcome abandoned --escalated yes --findings 3 \
    || fail "terminal: a valid terminal record should be accepted"
  [ "$(field_of "$file" task outcome)" = abandoned ] || fail "terminal: outcome not recorded"
  [ "$(field_of "$file" task escalated)" = yes ] || fail "terminal: escalation not recorded"
  [ "$(field_of "$file" task findings)" = 3 ] || fail "terminal: findings not recorded"
  pass "terminal outcome, escalation, findings, and task id are validated"
}

test_sanitization_keeps_one_record_per_line() {
  local home file lines project
  home=$(make_home sanitize)
  file=$(ledger_file "$home")

  ledger "$home" outcome steered 1 --note "$(printf 'first\tsecond\nthird\rfourth')" \
    || fail "sanitize: outcome with control characters should still record"
  lines=$(wc -l < "$file" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "sanitize: embedded newline split the record into $lines lines"
  LC_ALL=C awk -F '\t' 'NF != 9 { bad = 1 } END { exit bad + 0 }' "$file" \
    || fail "sanitize: embedded tabs added fields to the record"
  grep -q "note=first second third fourth" "$file" \
    || fail "sanitize: control characters were not collapsed to spaces"

  : > "$file"
  ledger "$home" task alpha --note-unsupported 2>/dev/null && fail "sanitize: unknown flag should be refused"
  ledger "$home" task alpha --model "$(head -c 400 < /dev/zero | tr '\0' 'm')" \
    || fail "sanitize: an over-long model should still record"
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 1 ] || fail "sanitize: over-long field split the record"
  [ "$(awk 'END { print length($0) }' "$file")" -le 1024 ] \
    || fail "sanitize: record exceeded the atomic-append line cap"

  : > "$file"
  ledger "$home" task alpha --project /home/somebody/projects/demo || fail "sanitize: project record failed"
  project=$(field_of "$file" task project)
  [ "$project" = demo ] || fail "sanitize: project recorded as '$project', not its basename"
  pass "sanitization keeps one record per line, caps fields, and keeps paths out"
}

test_task_attribution_across_wake_kinds() {
  local home file
  home=$(make_home attribution)
  file=$(ledger_file "$home")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "backend=tmux"
  fm_write_meta "$home/state/bravo.meta" "terminal=orca-term-9" "backend=orca"
  : > "$home/state/charlie.meta"

  {
    printf '1000\t1\tsignal\talpha.status\tsignal\n'
    printf '1000\t2\tsignal\tbravo.turn-ended\tsignal\n'
    printf '1000\t3\tcheck\t%s/state/charlie.check.sh\tcheck\n' "$home"
    printf '1000\t4\tstale\tfirstmate:fm-alpha\tstale\n'
    printf '1000\t5\tstale\torca-term-9\tstale\n'
    printf '1000\t6\tstale\tfm-charlie\tstale\n'
    printf '1000\t7\tstale\tunknown-window\tstale\n'
    printf '1000\t8\theartbeat\theartbeat\theartbeat\n'
  } | ledger "$home" drain-record || fail "attribution: drain-record failed"

  local seq expected actual
  # seq -> expected task
  while read -r seq expected; do
    actual=$(LC_ALL=C awk -F '\t' -v want="seq=$seq" '
      $2 == "wake" {
        hit = 0; t = ""
        for (i = 4; i <= NF; i++) {
          if ($i == want) hit = 1
          else if (substr($i, 1, 5) == "task=") t = substr($i, 6)
        }
        if (hit) { print t; exit }
      }' "$file")
    [ "$actual" = "$expected" ] \
      || fail "attribution: wake $seq resolved to '$actual', expected '$expected'"
  done <<EOF
1 alpha
2 bravo
3 charlie
4 alpha
5 bravo
6 charlie
7 -
8 -
EOF
  # A check key is a path; only its basename belongs in durable evidence.
  grep -q "key=charlie.check.sh" "$file" || fail "attribution: check key kept its absolute path"
  pass "task attribution covers status, turn-end, check, window, terminal, and unresolvable keys"
}

test_drain_records_one_wake_per_deduped_row() {
  local home file out state
  home=$(make_home drain)
  file=$(ledger_file "$home")
  state="$home/state"
  out="$home/drain.out"

  append_wake "$state" signal "alpha.status" "signal: alpha"
  append_wake "$state" signal "alpha.status" "signal: alpha again"
  append_wake "$state" heartbeat heartbeat heartbeat

  FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    "$DRAIN" > "$out" 2>/dev/null || fail "drain: drain failed"

  [ "$(grep -c . "$out")" -eq 2 ] || fail "drain: expected two deduped rows on stdout"
  [ "$(LC_ALL=C awk -F '\t' '$2 == "wake" { n++ } END { print n + 0 }' "$file")" -eq 2 ] \
    || fail "drain: expected one wake record per deduped row"
  grep -q "kind=signal" "$file" || fail "drain: signal wake not recorded"
  grep -q "kind=heartbeat" "$file" || fail "drain: heartbeat wake not recorded"
  pass "the drain records one wake per deduped row it hands the coordinator"
}

test_unwritable_ledger_cannot_change_the_drain() {
  local home state out_ok out_blocked rc_ok rc_blocked
  home=$(make_home drain-unwritable)
  state="$home/state"
  out_ok="$home/ok.out"
  out_blocked="$home/blocked.out"

  append_wake "$state" signal "alpha.status" "signal: alpha"
  FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    "$DRAIN" > "$out_ok" 2>/dev/null
  rc_ok=$?

  # Same wake, but the ledger cannot be written at all.
  append_wake "$state" signal "alpha.status" "signal: alpha"
  FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" \
  FM_WAKE_LEDGER="/dev/null/impossible/wake-ledger.tsv" \
    "$DRAIN" > "$out_blocked" 2>/dev/null
  rc_blocked=$?

  [ "$rc_ok" -eq 0 ] || fail "unwritable: baseline drain exited $rc_ok"
  [ "$rc_blocked" -eq 0 ] \
    || fail "unwritable: an unwritable ledger changed the drain's exit status to $rc_blocked"
  # Only the queue epoch/sequence differ between the two runs; the wake payload must not.
  cut -f 3,4,5 < "$out_ok" > "$home/ok.fields"
  cut -f 3,4,5 < "$out_blocked" > "$home/blocked.fields"
  cmp -s "$home/ok.fields" "$home/blocked.fields" \
    || fail "unwritable: an unwritable ledger changed the drained wake payload"
  pass "an unwritable ledger changes neither the drain's raw rows nor its exit status"
}

test_slow_ledger_never_blocks_a_wake_append() {
  local home state out started elapsed drain_pid
  home=$(make_home drain-slow)
  state="$home/state"
  out="$home/drain.out"

  append_wake "$state" signal "alpha.status" "signal: alpha"
  # The ledger phase runs far longer than any wake append should ever wait. The
  # drain reaches it only after releasing the queue lock, so an append stays free.
  FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
  FM_WAKE_LEDGER_TEST_DELAY=5 \
    "$DRAIN" > "$out" 2>/dev/null &
  drain_pid=$!

  # Let the drain reach its slow best-effort phase, then append a wake.
  sleep 1
  started=$(date +%s)
  append_wake "$state" signal "bravo.status" "signal: bravo" \
    || fail "slow ledger: the wake append itself failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 2 ] \
    || fail "slow ledger: a wake append waited ${elapsed}s behind the ledger phase"

  wait "$drain_pid" || fail "slow ledger: drain failed"
  grep -q "bravo.status" "$state/.wake-queue" \
    || fail "slow ledger: the concurrent wake was not durably queued"
  pass "a slowed ledger phase never delays or blocks a concurrent wake append"
}

test_concurrent_appends_stay_whole_lines() {
  local home file pids pid i
  home=$(make_home concurrent)
  file=$(ledger_file "$home")
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    ledger "$home" outcome steered "$i" --note "worker $i" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent: an append failed"
  done
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 30 ] || fail "concurrent: expected 30 records"
  LC_ALL=C awk -F '\t' '$1 != "v1" || $2 != "outcome" || NF != 9 { bad = 1 } END { exit bad + 0 }' "$file" \
    || fail "concurrent: appends interleaved into a malformed record"
  pass "concurrent appends from many writers stay whole, well-formed lines"
}

test_report_counts_coverage_and_the_model_join() {
  local home file out
  home=$(make_home report)
  file=$(ledger_file "$home")
  fm_write_meta "$home/state/alpha.meta" "window=fm-alpha" "backend=tmux"

  {
    printf '1000\t1\tsignal\talpha.status\tsignal\n'
    printf '1000\t2\tstale\tfm-alpha\tstale\n'
    printf '1000\t3\theartbeat\theartbeat\theartbeat\n'
  } | ledger "$home" drain-record || fail "report: drain-record failed"
  # A replayed wake: the drain's at-least-once boundary can duplicate a record.
  printf '1000\t1\tsignal\talpha.status\tsignal\n' | ledger "$home" drain-record \
    || fail "report: replay drain-record failed"

  ledger "$home" outcome steered 1 || fail "report: outcome failed"
  # A heartbeat is fleet-wide, so its outcome carries no task to attribute.
  ledger "$home" outcome absorbed 3 || fail "report: outcome failed"
  ledger "$home" task alpha --outcome landed --harness pi --model sol --effort medium \
    || fail "report: task failed"

  out=$(ledger "$home" report) || fail "report: report failed"
  printf '%s\n' "$out" | grep -q "wakes: 3 total" \
    || fail "report: a replayed wake was counted twice:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "2 with a recorded outcome, 1 unrecorded" \
    || fail "report: coverage was not reported:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "1 not attributable to a task" \
    || fail "report: unattributable outcomes were not reported:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "tasks: 1 terminal (landed 1)" \
    || fail "report: terminal tasks were not reported:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "pi/sol/medium" \
    || fail "report: the per-profile model join is missing:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "steered 1" \
    || fail "report: per-profile outcome counts are missing:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "coordinator response latency" \
    || fail "report: response latency was not reported:"$'\n'"$out"

  # An absent ledger reports its absence rather than failing.
  rm -f "$file"
  out=$(ledger "$home" report) || fail "report: an absent ledger should not fail"
  printf '%s\n' "$out" | grep -q "absent" || fail "report: absence was not reported"
  pass "the report counts distinct wakes, states coverage, and joins outcomes to profiles"
}

test_seq_reuse_across_a_state_reset_never_collapses_records() {
  local home file out
  home=$(make_home seq-reset)
  file=$(ledger_file "$home")

  # An outcome whose wake record is unresolvable must say so explicitly.
  ledger "$home" outcome absorbed 9 || fail "seq reset: unmatched outcome failed"
  [ "$(field_of "$file" outcome queued)" = unknown ] \
    || fail "seq reset: an unmatched outcome must record queued=unknown"
  : > "$file"

  # A state wipe restarts the wake-queue sequence while the ledger survives,
  # so the same seq arrives twice with different queue epochs.
  printf '1000\t1\tsignal\talpha.status\tsignal\n' | ledger "$home" drain-record \
    || fail "seq reset: first drain-record failed"
  ledger "$home" outcome steered 1 || fail "seq reset: first outcome failed"
  printf '2000\t1\tsignal\talpha.status\tsignal\n' | ledger "$home" drain-record \
    || fail "seq reset: second drain-record failed"
  ledger "$home" outcome absorbed 1 || fail "seq reset: second outcome failed"

  out=$(ledger "$home" report) || fail "seq reset: report failed"
  printf '%s\n' "$out" | grep -q "wakes: 2 total" \
    || fail "seq reset: distinct wakes sharing a seq were collapsed:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "2 with a recorded outcome, 0 unrecorded" \
    || fail "seq reset: coverage did not join on the (seq, queued) pair:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "outcomes: 2 recorded" \
    || fail "seq reset: distinct outcomes sharing a seq were collapsed:"$'\n'"$out"
  pass "a reused wake-queue sequence never collapses distinct wakes or outcomes"
}


test_record_format_for_all_three_kinds
test_outcome_vocabulary_is_closed
test_terminal_outcome_and_escalation_are_validated
test_sanitization_keeps_one_record_per_line
test_task_attribution_across_wake_kinds
test_drain_records_one_wake_per_deduped_row
test_unwritable_ledger_cannot_change_the_drain
test_slow_ledger_never_blocks_a_wake_append
test_concurrent_appends_stay_whole_lines
test_report_counts_coverage_and_the_model_join
test_seq_reuse_across_a_state_reset_never_collapses_records
