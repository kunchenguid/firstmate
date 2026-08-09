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
# It also covers the terminal-outcome definition: the derivation from a task's
# own declaration, the closed evidence vocabulary, and the sweep that records a
# failure no teardown will ever see. That last one is the case that matters -
# a task that fails and is never torn down was silent here, and silence is
# indistinguishable from a task that never failed, so covering only the
# torn-down path would miss the actual defect.
#
# Teardown's own terminal-record write is covered where teardown's fixture
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

# The value of <field> on the last line matching <record> kind, or empty. The
# outcome cases below assert on the record just written, which is the last one.
last_field_of() {  # <file> <record> <field>
  LC_ALL=C awk -F '\t' -v want="$2" -v key="$3" '
    $1 == "v1" && $2 == want {
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 0 && substr($i, 1, p - 1) == key) { v = substr($i, p + 1) }
      }
    }
    END { if (v != "") print v }
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

  # --allow-unjoined isolates the vocabulary from the join: this fixture has no
  # wake records, and an unjoinable sequence is refused on its own grounds.
  for token in absorbed inspected steered decided escalated repaired false-positive; do
    ledger "$home" outcome "$token" 1 --allow-unjoined >/dev/null 2>&1 \
      || fail "vocabulary: $token should be accepted"
  done
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 7 ] || fail "vocabulary: expected seven accepted records"

  for token in handled ignored '' STEERED steered-ish; do
    if ledger "$home" outcome "$token" 1 --allow-unjoined >/dev/null 2>&1; then
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

  # No wake records here on purpose: this case is about serialization, so the
  # join is waived rather than staged.
  ledger "$home" outcome steered 1 --allow-unjoined --note "$(printf 'first\tsecond\nthird\rfourth')" \
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
    ledger "$home" outcome steered "$i" --allow-unjoined --note "worker $i" &
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

  # An outcome whose wake record is unresolvable must say so explicitly. That
  # is the genuine wiped-state/ case, so it needs the explicit override.
  ledger "$home" outcome absorbed 9 --allow-unjoined || fail "seq reset: unmatched outcome failed"
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


test_a_bare_outcome_records_against_the_newest_unrecorded_wake() {
  local home file now
  home=$(make_home bare-outcome)
  file=$(ledger_file "$home")
  now=$(date +%s)

  printf '%s\t1\tsignal\talpha.status\tsignal: a\n%s\t2\tsignal\tbeta.status\tsignal: b\n%s\t3\tsignal\tgamma.status\tsignal: c\n' \
    "$((now - 30))" "$((now - 20))" "$((now - 10))" \
    | ledger "$home" drain-record || fail "bare outcome: drain-record failed"

  ledger "$home" outcome absorbed || fail "bare outcome: a bare outcome was refused"
  [ "$(last_field_of "$file" outcome seq)" = 3 ] \
    || fail "bare outcome: expected the newest unrecorded wake 3, got $(last_field_of "$file" outcome seq)"
  [ "$(last_field_of "$file" outcome queued)" = "$((now - 10))" ] \
    || fail "bare outcome: the resolved record lost the durable queued half of the join"

  # The second bare call must move on rather than recording the same wake twice.
  ledger "$home" outcome steered || fail "bare outcome: a second bare outcome was refused"
  [ "$(last_field_of "$file" outcome seq)" = 2 ] \
    || fail "bare outcome: a second bare call re-recorded wake $(last_field_of "$file" outcome seq)"
  [ "$(last_field_of "$file" outcome queued)" = "$((now - 20))" ] \
    || fail "bare outcome: the second resolved record lost its queued half"

  ledger "$home" outcome absorbed || fail "bare outcome: a third bare outcome was refused"
  [ "$(last_field_of "$file" outcome seq)" = 1 ] \
    || fail "bare outcome: the third bare call did not reach the oldest unrecorded wake"

  # Every wake is now recorded, so there is nothing left to name: that is a
  # loud refusal, never a guessed sequence.
  ledger "$home" outcome absorbed 2>/dev/null \
    && fail "bare outcome: a bare call with no unrecorded wake left was accepted"
  pass "a bare outcome records against the newest unrecorded wake and never repeats one"
}

test_an_unjoinable_sequence_is_refused_without_the_override() {
  local home file now before
  home=$(make_home unjoinable)
  file=$(ledger_file "$home")
  now=$(date +%s)
  printf '%s\t4\tsignal\talpha.status\tsignal: a\n' "$((now - 10))" \
    | ledger "$home" drain-record || fail "unjoinable: drain-record failed"
  before=$(wc -l < "$file" | tr -d ' ')

  # The incident in one line: a hand-supplied placeholder that joins no wake
  # record used to store queued=unknown, which is indistinguishable from a
  # legitimate wiped-state record.
  ledger "$home" outcome absorbed 999999 2>/dev/null \
    && fail "unjoinable: a sequence matching no wake record was accepted"
  [ "$(wc -l < "$file" | tr -d ' ')" -eq "$before" ] \
    || fail "unjoinable: a refused outcome still appended a record"

  ledger "$home" outcome absorbed 999999 --allow-unjoined \
    || fail "unjoinable: the explicit override was refused"
  [ "$(wc -l < "$file" | tr -d ' ')" -eq "$((before + 1))" ] \
    || fail "unjoinable: the override did not append exactly one record"
  [ "$(last_field_of "$file" outcome queued)" = unknown ] \
    || fail "unjoinable: an overridden outcome must still record queued=unknown"
  pass "an unjoinable wake sequence is refused unless the override is explicit"
}

test_an_explicit_joinable_sequence_records_unchanged() {
  local home file now after
  home=$(make_home explicit-seq)
  file=$(ledger_file "$home")
  now=$(date +%s)
  printf '%s\t5\tsignal\talpha.status\tsignal: a\n%s\t6\tsignal\tbeta.status\tsignal: b\n%s\t7\tsignal\tgamma.status\tsignal: c\n' \
    "$((now - 30))" "$((now - 20))" "$((now - 10))" \
    | ledger "$home" drain-record || fail "explicit seq: drain-record failed"

  ledger "$home" outcome steered 6 || fail "explicit seq: a joinable sequence was refused"
  [ "$(last_field_of "$file" outcome seq)" = 6 ] \
    || fail "explicit seq: an explicit sequence was not honored"
  [ "$(last_field_of "$file" outcome queued)" = "$((now - 20))" ] \
    || fail "explicit seq: the (seq, queued) join was not resolved from the wake record"
  [ "$(last_field_of "$file" outcome task)" = beta ] \
    || fail "explicit seq: task attribution was lost"
  after=$(last_field_of "$file" outcome after)
  case "$after" in
    ''|*[!0-9]*) fail "explicit seq: after must resolve to a number, got '$after'" ;;
  esac

  # Multiple sequences in one invocation stay supported.
  ledger "$home" outcome inspected 5 7 || fail "explicit seq: a multi-sequence invocation was refused"
  [ "$(grep -c "outcome=inspected" "$file")" -eq 2 ] \
    || fail "explicit seq: a multi-sequence invocation did not append one record per sequence"
  pass "an explicit joinable sequence, including several at once, records exactly as before"
}

test_the_terminal_outcome_derivation_reads_the_task_declaration() {
  local home status
  home=$(make_home derive)
  status="$home/state/alpha.status"

  [ "$(ledger "$home" derive "$home/state/absent.status")" = "landed assumed" ] \
    || fail "derive: a task with no status log must yield the unevidenced default"

  printf 'working: started\n' > "$status"
  [ "$(ledger "$home" derive "$status")" = "landed assumed" ] \
    || fail "derive: progress alone is not evidence of an outcome"

  # An open state is not an outcome. A blocked or parked task that is later
  # released normally landed its work; treating either as failure would invent
  # failures out of ordinary supervision traffic.
  printf 'blocked: needs a credential\nneeds-decision: which base\n' >> "$status"
  [ "$(ledger "$home" derive "$status")" = "landed assumed" ] \
    || fail "derive: blocked and needs-decision are open states, not outcomes"

  printf 'failed: the approach does not work\n' >> "$status"
  [ "$(ledger "$home" derive "$status")" = "failed declared" ] \
    || fail "derive: a declared failure must derive failed, with the declaration as its evidence"

  # Last declaration wins: a task that failed, was recovered and then shipped
  # is a landed task, not a permanent failure.
  printf 'done: PR merged\n' >> "$status"
  [ "$(ledger "$home" derive "$status")" = "landed declared" ] \
    || fail "derive: a later done: must supersede an earlier failed:"

  pass "the terminal outcome derives from the task's own last declaration"
}

test_terminal_outcome_source_is_closed_and_defaults_to_assumed() {
  local home file src
  home=$(make_home outcome-source)
  file=$(ledger_file "$home")

  ledger "$home" task alpha --outcome failed --source declared \
    || fail "outcome-source: a declared failure should be accepted"
  [ "$(last_field_of "$file" task outcome_source)" = declared ] \
    || fail "outcome-source: the evidence was not recorded"

  # An absent --source must never imply evidence nobody produced.
  ledger "$home" task beta --outcome landed || fail "outcome-source: default source failed"
  [ "$(last_field_of "$file" task outcome_source)" = assumed ] \
    || fail "outcome-source: an unstated evidence must record assumed"

  for src in declared discarded unreleased assumed; do
    ledger "$home" task "src-$src" --outcome landed --source "$src" >/dev/null \
      || fail "outcome-source: $src should be accepted"
  done
  for src in observed guessed '' DECLARED declared-ish; do
    if ledger "$home" task rejected --outcome landed --source "$src" >/dev/null 2>&1; then
      fail "outcome-source: '$src' should have been refused"
    fi
  done
  if grep -q 'task=rejected' "$file"; then
    fail "outcome-source: a refused evidence token still wrote a record"
  fi
  pass "the outcome-source vocabulary is closed and an unstated evidence records assumed"
}

# The defect this whole increment exists for: only teardown wrote a terminal
# line, so a task that failed and was NEVER torn down left the ledger silent,
# and that silence is indistinguishable from a task that never failed. A test
# that covers only the torn-down case misses exactly this.
test_a_failure_that_is_never_torn_down_is_recorded_not_silent() {
  local home file out before
  home=$(make_home sweep)
  file=$(ledger_file "$home")

  printf 'window=fm:alpha\n' > "$home/state/alpha.meta"
  printf 'working: running\n' > "$home/state/alpha.status"
  printf 'harness=pi\nmodel=sol\neffort=high\nkind=ship\nmode=no-mistakes\nbackend=tmux\n' \
    > "$home/state/beta.meta"
  printf 'working: running\nfailed: the approach does not work\n' > "$home/state/beta.status"

  # Negative control first: with no failure declared anywhere, the sweep must
  # record nothing, so the positive result below cannot be the sweep firing
  # indiscriminately over every task in state/.
  mv "$home/state/beta.status" "$home/state/beta.status.held"
  out=$(ledger "$home" sweep) || fail "sweep: control run failed"
  [ -z "$out" ] || fail "sweep: recorded something with no declared failure:"$'\n'"$out"
  [ ! -f "$file" ] || fail "sweep: wrote a record with no declared failure"
  mv "$home/state/beta.status.held" "$home/state/beta.status"

  out=$(ledger "$home" sweep --dry-run) || fail "sweep: dry run failed"
  printf '%s\n' "$out" | grep -q 'unreleased failure: beta' \
    || fail "sweep: dry run did not name the unreleased failure:"$'\n'"$out"
  [ ! -f "$file" ] || fail "sweep: a dry run wrote a record"
  [ ! -e "$home/state/beta.terminal-recorded" ] || fail "sweep: a dry run left a receipt"

  ledger "$home" sweep >/dev/null || fail "sweep: recording run failed"
  [ "$(last_field_of "$file" task task)" = beta ] || fail "sweep: the failed task was not recorded"
  [ "$(last_field_of "$file" task outcome)" = failed ] || fail "sweep: outcome not recorded as failed"
  [ "$(last_field_of "$file" task outcome_source)" = unreleased ] \
    || fail "sweep: the record did not say it came from an unreleased task"
  # The profile join is the reason the record is worth writing now rather than
  # inferring it later: the metadata that carries it is still on disk.
  [ "$(last_field_of "$file" task harness)" = pi ] || fail "sweep: harness not captured"
  [ "$(last_field_of "$file" task model)" = sol ] || fail "sweep: model not captured"
  if grep -q 'task=alpha' "$file"; then
    fail "sweep: a task with no declared failure was recorded"
  fi
  [ -e "$home/state/beta.terminal-recorded" ] || fail "sweep: no receipt was written"

  # Idempotence, with its own negative control: removing the receipt must make
  # the sweep record again, so the quiet rerun below proves the receipt works
  # rather than proving the sweep stopped finding anything.
  before=$(wc -l < "$file" | tr -d ' ')
  ledger "$home" sweep >/dev/null || fail "sweep: rerun failed"
  [ "$(wc -l < "$file" | tr -d ' ')" -eq "$before" ] \
    || fail "sweep: a rerun appended a second record for the same task"
  rm -f "$home/state/beta.terminal-recorded"
  ledger "$home" sweep >/dev/null || fail "sweep: post-control run failed"
  [ "$(wc -l < "$file" | tr -d ' ')" -eq $((before + 1)) ] \
    || fail "sweep: removing the receipt did not make the sweep record again"
  pass "a declared failure that is never torn down is recorded once, not silent"
}

test_the_report_names_evidence_and_refuses_a_rate() {
  local home file out
  home=$(make_home terminal-report)
  file=$(ledger_file "$home")

  ledger "$home" task alpha --outcome landed --source declared || fail "report: task failed"
  ledger "$home" task beta --outcome failed --source declared || fail "report: task failed"
  # A record written before this field existed. It must read as assumed rather
  # than needing an append-only file rewritten.
  printf 'v1\ttask\t%s\ttask=gamma\toutcome=landed\tharness=pi\tmodel=sol\teffort=low\n' \
    "$(date +%s)" >> "$file"

  out=$(ledger "$home" report) || fail "report: failed"
  printf '%s\n' "$out" | grep -q 'tasks: 3 terminal (landed 2  failed 1)' \
    || fail "report: terminal counts wrong:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q 'by evidence:.*declared 2' \
    || fail "report: declared evidence not counted:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q 'by evidence:.*assumed 1' \
    || fail "report: a record predating outcome_source must count as assumed:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q 'DIAGNOSTIC ONLY - not a success rate' \
    || fail "report: terminal counts printed without their diagnostic-only qualifier:"$'\n'"$out"
  printf '%s\n' "$out" | grep -q 'known, named, unreconciled gap' \
    || fail "report: the fleet/pipeline divergence was not named:"$'\n'"$out"
  # The certification is the absence of a ratio, so assert it directly: the
  # only permitted mention of a success rate is the refusal to print one, and
  # no percentage may appear anywhere in the terminal-outcome section.
  if printf '%s\n' "$out" | grep -o 'success rate' | grep -qv '^success rate$'; then
    fail "report: unexpected success-rate text:"$'\n'"$out"
  fi
  if [ "$(printf '%s\n' "$out" | grep -c 'not a success rate')" \
       -ne "$(printf '%s\n' "$out" | grep -c 'success rate')" ]; then
    fail "report: printed a success rate over unreconciled counts:"$'\n'"$out"
  fi
  if printf '%s\n' "$out" | sed -n '/^tasks:/,/^$/p' | grep -q '%'; then
    fail "report: printed a ratio in the terminal-outcome section:"$'\n'"$out"
  fi
  pass "the report breaks outcomes down by evidence and refuses to print a rate"
}

test_reconcile_counts_outcomes_that_join_no_wake_record() {
  local home out now
  home=$(make_home reconcile)
  now=$(date +%s)
  printf '%s\t8\tsignal\talpha.status\tsignal: a\n' "$((now - 10))" \
    | ledger "$home" drain-record || fail "reconcile: drain-record failed"

  [ "$(ledger "$home" reconcile --count)" = 0 ] \
    || fail "reconcile: a ledger with no outcome records is not unreconciled"

  ledger "$home" outcome steered 8 || fail "reconcile: joinable outcome failed"
  [ "$(ledger "$home" reconcile --count)" = 0 ] \
    || fail "reconcile: a joined outcome was counted as unreconciled"

  ledger "$home" outcome absorbed 999999 --allow-unjoined || fail "reconcile: override failed"
  ledger "$home" outcome absorbed 999998 --allow-unjoined || fail "reconcile: override failed"
  [ "$(ledger "$home" reconcile --count)" = 2 ] \
    || fail "reconcile: expected 2 unreconciled outcome records, got $(ledger "$home" reconcile --count)"

  out=$(ledger "$home" reconcile) || fail "reconcile: summary failed"
  printf '%s\n' "$out" | grep -q '2' \
    || fail "reconcile: the summary did not name the unreconciled count:"$'\n'"$out"

  # An absent ledger is a real zero; a ledger that cannot be read is not. Both
  # would otherwise print 0, and the second one is a silent all-clear over an
  # instrument nobody could read.
  [ "$(FM_WAKE_LEDGER="$home/data/absent.tsv" ledger "$home" reconcile --count)" = 0 ] \
    || fail "reconcile: an absent ledger should count zero unreconciled records"
  chmod 000 "$(ledger_file "$home")"
  if FM_WAKE_LEDGER="$(ledger_file "$home")" ledger "$home" reconcile --count >/dev/null 2>&1; then
    chmod 644 "$(ledger_file "$home")"
    fail "reconcile: an unreadable ledger reported a count instead of refusing"
  fi
  chmod 644 "$(ledger_file "$home")"
  pass "reconcile counts exactly the outcome records that join no wake record"
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
test_a_bare_outcome_records_against_the_newest_unrecorded_wake
test_an_unjoinable_sequence_is_refused_without_the_override
test_an_explicit_joinable_sequence_records_unchanged
test_reconcile_counts_outcomes_that_join_no_wake_record
test_the_terminal_outcome_derivation_reads_the_task_declaration
test_terminal_outcome_source_is_closed_and_defaults_to_assumed
test_a_failure_that_is_never_torn_down_is_recorded_not_silent
test_the_report_names_evidence_and_refuses_a_rate
