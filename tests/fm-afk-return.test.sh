#!/usr/bin/env bash
# Deterministic return-catch-up gate and return-brief regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Bearings before Firstmate owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
# The brief cases pin the away-posture redesign's return: the brief is composed
# from the archived posture record, the outcome store, the held set, and the
# status logs, health first, and the gate shrinks to what the away session could
# not fix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  # The return brief's durable sources: the posture-record owner, the outcome
  # store owner, and the backlog reader with its tasks-axi probe.
  cp "$ROOT/bin/fm-afk-contract.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-branch-outcome.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-tasks-axi-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-backlog-transition-lib.sh" "$dir/bin/"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  # The fake stop mirrors the real one's ordering: the away flag goes, then the
  # posture record is archived through its owner.
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$FM_HOME/stop.log"
rm -f "$FM_HOME/state/.afk"
if [ -e "$FM_HOME/state/.fail-terminal-stop-once" ]; then
  rm -f "$FM_HOME/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$FM_HOME/state/.afk-daemon-terminal"
"$(dirname "$0")/fm-afk-contract.sh" archive >/dev/null
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
if [ "${1:-}" = --ack-through ]; then
  [ "${3:-}" = --recovery-generation ] && [ "${4:-}" = fixture-generation ] || exit 2
  printf '%s\n' "$2" >> "$FM_HOME/state/.fake-drain-acks"
  : > "$file"
  exit 0
fi
if [ -s "$file" ]; then
  cat "$file"
  sequence=$(awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }' "$file")
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation fixture-generation\n' "$sequence" >&2
fi
SH
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

ack_return() {  # <case-dir> <return-output>
  local dir=$1 output=$2 sequence generation
  sequence=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "return output lacked a generation-bound post-handling acknowledgement: $output"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation"
}

seed_live_blocker() {  # <case-dir> <backend> <key>
  local dir=$1 backend=$2 key=$3 target
  case "$backend" in
    tmux) target='synthetic:fm-repair-task' ;;
    herdr) target='fm-lab-synthetic:w1:p2' ;;
  esac
  cat > "$dir/home/state/repair-task.meta" <<EOF
window=$target
backend=$backend
kind=ship
EOF
  printf 'blocked [key=%s]: firstmate can refresh the synthetic token\n' "$key" > "$dir/home/state/repair-task.status"
}

test_return_gate_orders_catchup_before_bearings() {
  local dir out rc gate wake_count
  dir="$TMP_ROOT/ordering"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr synthetic-dependency
  date +%s > "$dir/home/state/.afk"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$dir/home/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n'
    printf 'wake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency\n'
  } > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'firstmate-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Firstmate"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency' "$gate" >/dev/null \
    || fail "the separate drain annotation was not retained as away-return evidence"
  grep -F $'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered' "$gate" >/dev/null || fail "wedge evidence was not retained in the durable gate"
  grep -F $'evidence\tescalation\trepair-task.status: blocked synthetic dependency' "$gate" >/dev/null || fail "buffered escalation evidence was not retained in the durable gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "return begin did not stop away mode exactly once"
  [ -s "$dir/home/state/.fake-drain" ] || fail "blocked return acknowledged its emitted wake before handling completed"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "blocked return crossed the post-handling acknowledgement boundary"

  # The exact incident regression: Bearings is an ordinary request and must
  # refuse before reading/rendering while this shared gate remains open.
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Bearings should refuse behind the return gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up is pending' "Bearings refusal did not point to the shared return owner"

  # Restart/re-entry is idempotent: no second stop, no duplicate catch-up line,
  # and the same unresolved blocker remains authoritative.
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated begin should preserve the unresolved gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "repeated begin stopped an already-stopped daemon twice"
  wake_count=$(grep -c $'^evidence\twake\t1784074271' "$gate" || true)
  [ "$wake_count" -eq 1 ] || fail "repeated begin duplicated retained wake evidence ($wake_count copies)"
  [ "$(grep -c $'^evidence\twedge\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained wedge evidence"
  [ "$(grep -c $'^evidence\tescalation\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained escalation evidence"

  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  assert_contains "$out" 'catch-up clear' "successful check did not announce that ordinary work may proceed"
  [ ! -e "$gate" ] || fail "successful check left the return gate behind"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] || fail "successful check left delivered escalation state behind"
  [ ! -e "$dir/home/state/.subsuper-inject-wedged" ] || fail "successful check left the wedge marker behind"
  [ -s "$dir/home/state/.fake-drain" ] || fail "successful return consumed its wake before handling completed"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "successful return acknowledged its wake inside evidence publication"
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes' "successful return did not hand acknowledgement to the handling turn"
  ack_return "$dir" "$out" || fail "post-handling acknowledgement failed"
  [ ! -s "$dir/home/state/.fake-drain" ] || fail "explicit post-handling acknowledgement left the handled wake durable"
  [ "$(cat "$dir/home/state/.fake-drain-acks" 2>/dev/null || true)" = 2 ] \
    || fail "explicit post-handling acknowledgement used the wrong wake sequence"

  out=$(run_return "$dir" check) || fail "an already-clear repeated check should be idempotent: $out"
  [ ! -e "$gate" ] || fail "idempotent clear check recreated a gate"
  pass "return catch-up precedes Bearings, owns live blocker remediation, preserves evidence once, and clears idempotently"
}

test_explicit_reclassification_requires_durable_reason() {
  local backend dir out rc
  for backend in tmux herdr; do
    dir="$TMP_ROOT/reclassify-$backend"
    install_runner "$dir"
    seed_live_blocker "$dir" "$backend" vendor-release
    date +%s > "$dir/home/state/.afk"
    : > "$dir/home/state/.fake-drain"
    set +e
    out=$(run_return "$dir" begin)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend blocker did not open the return gate"

    # A pause alone cannot mask the keyed blocker. The old concern must be
    # explicitly resolved with the durable reclassification reason first.
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    set +e
    out=$(run_return "$dir" check)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend pause silently masked an unresolved blocked key"

    printf 'resolved [key=vendor-release]: reclassified as an external wait because the synthetic vendor owns the next event\n' >> "$dir/home/state/repair-task.status"
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    out=$(run_return "$dir" check) || fail "$backend durable reclassification did not clear the return gate: $out"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$backend reclassification left a gate behind"
  done
  pass "tmux and Herdr blockers require the same explicit durable reclassification before ordinary work"
}

test_captain_decision_does_not_masquerade_as_firstmate_blocker() {
  local dir out
  dir="$TMP_ROOT/captain-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:fm-decision-task
backend=tmux
kind=ship
EOF
  printf 'needs-decision [key=api-shape]: captain must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "approval decision should not be treated as a firstmate blocker: $out"
  assert_contains "$out" 'catch-up wake:' "approval decision notification was not surfaced in catch-up"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "approval decision incorrectly opened a firstmate blocker gate"
  pass "needs-decision remains reportable without masquerading as a firstmate-actionable blocker"
}

test_evidence_publication_failure_preserves_wake_for_redrain() {
  local dir out rc gate
  dir="$TMP_ROOT/evidence-publication-failure"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  printf '1784074271\t7\tsignal\trecovery-task.status\tsignal: recover after output failure\n' \
    > "$dir/home/state/.fake-drain"
  : > "$dir/read-only-output"

  set +e
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-afk-return.sh" begin 3< "$dir/read-only-output" >&3 2> "$dir/failed.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "evidence publication failure should retain catch-up (rc=$rc)"
  [ -s "$dir/home/state/.fake-drain" ] || fail "publication failure removed the unhandled durable wake"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "publication failure acknowledged the wake before delivery"
  [ -s "$gate" ] || fail "publication failure did not retain the catch-up gate"

  out=$(run_return "$dir" check) || fail "publication retry did not complete catch-up: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "publication retry did not re-drain the durable wake"
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes' "publication retry did not return acknowledgement to the handling turn"
  [ -s "$dir/home/state/.fake-drain" ] || fail "successful evidence publication consumed the wake before handling"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "successful evidence publication acknowledged the wake before handling"
  [ ! -e "$gate" ] || fail "successful publication retry left the catch-up gate pending"

  out=$(run_return "$dir" check) || fail "return did not recover after interruption before acknowledgement: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "interrupted handling did not re-drain the published wake"
  [ -s "$dir/home/state/.fake-drain" ] || fail "interrupted handling lost the published wake"
  ack_return "$dir" "$out" || fail "explicit acknowledgement after replay failed"
  [ ! -s "$dir/home/state/.fake-drain" ] || fail "explicit acknowledgement did not consume the replayed wake"
  [ "$(cat "$dir/home/state/.fake-drain-acks" 2>/dev/null || true)" = 7 ] \
    || fail "explicit acknowledgement after replay used the wrong wake sequence"
  pass "AFK return re-drains published wakes until handling acknowledges"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}

test_check_retries_recorded_terminal_teardown() {
  local dir gate out rc
  dir="$TMP_ROOT/terminal-teardown"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  printf 'herdr\tsynthetic:pane\tsynthetic-workspace\n' > "$dir/home/state/.afk-daemon-terminal"
  touch "$dir/home/state/.fail-terminal-stop-once"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "failed terminal teardown should keep return catch-up gated (rc=$rc): $out"
  [ -e "$gate" ] || fail "failed terminal teardown cleared the return gate"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "failed terminal teardown discarded its durable record"
  [ ! -e "$dir/home/state/.afk" ] || fail "failed terminal teardown did not preserve stop ordering"

  out=$(run_return "$dir" check) || fail "check did not retry recorded terminal teardown: $out"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "successful check left the terminal teardown record behind"
  [ ! -e "$gate" ] || fail "successful terminal teardown retry left the return gate behind"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 2 ] || fail "check did not retry terminal teardown exactly once"
  pass "check retries recorded terminal teardown and keeps catch-up gated until success"
}

# --- the return brief -------------------------------------------------------
# Rendered from durable records only: the archived away-posture record, the
# outcome store, the held set, and the status logs. Health comes first, then
# the mandate, then what waits on the captain, then what could not be fixed;
# the blocker gate shrinks to what the away session could not fix.

contract_in() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-contract.sh" "$@"
}

outcome_in() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-branch-outcome.sh" "$@"
}

line_of() {  # <haystack> <needle> -> 1-based line number of the first match, or empty
  printf '%s\n' "$1" | grep -n -F -- "$2" | head -1 | cut -d: -f1
}

test_return_brief_composes_from_record_store_and_held_set() {
  local dir out rc gate health_line clauses_line waiting_line failed_line second
  dir="$TMP_ROOT/brief"
  install_runner "$dir"
  (cd "$dir/home" && tasks-axi add fix-windows 'Fix the windows lane' --file data/backlog.md >/dev/null \
    && tasks-axi hold fix-windows --reason 'awaiting the captain on the merge' --kind captain --file data/backlog.md >/dev/null) \
    || fail "could not seed the held backlog"
  contract_in "$dir" propose --words 'merge the windows fix when green, then cut a prerelease' \
    --action merge --object 'task fix-windows PR' --when 'checks green' \
    --action prerelease --object 'repo no-mistakes' --when 'after clause 1' \
    --action merge --object everything >/dev/null 2>&1 || true
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the away-posture record"
  # Two live blockers, one on a task with a captain-verdict outcome and one on a
  # task with a routine outcome. A third task failed outright.
  printf 'window=synthetic:fm-fix-windows\nbackend=tmux\nkind=ship\n' > "$dir/home/state/fix-windows.meta"
  printf 'blocked [key=token]: firstmate can refresh the token\n' > "$dir/home/state/fix-windows.status"
  printf 'window=synthetic:fm-other\nbackend=tmux\nkind=ship\n' > "$dir/home/state/other.meta"
  printf 'blocked [key=dep]: needs the upstream dependency\nneeds-decision [key=pick]: choose the target\n' > "$dir/home/state/other.status"
  printf 'window=synthetic:fm-dead\nbackend=tmux\nkind=scout\n' > "$dir/home/state/dead.meta"
  printf 'failed: the reproduction never compiled\n' > "$dir/home/state/dead.status"
  outcome_in "$dir" append --task fix-windows --verdict captain \
    --summary 'blocked on a token only the captain holds; held for return' --wake 'signal: fix-windows.status' >/dev/null \
    || fail "could not seed the captain outcome row"
  outcome_in "$dir" append --task other --verdict routine \
    --summary 'resent the steer; worker resumed' --wake 'stale: synthetic:fm-other' >/dev/null \
    || fail "could not seed the routine outcome row"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "the unreached blocker should still gate the return (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -e "$dir/home/state/afk-contracts" ] || fail "the return did not archive the away-posture record"
  [ ! -e "$dir/home/state/.afk-contract" ] || fail "the live away-posture record survived the return"
  assert_contains "$out" '=== Return brief (away ' "the brief did not open with the away window"
  assert_contains "$out" 'supervision ran through the away window with no detected gap' "health did not report the clean window"
  health_line=$(line_of "$out" 'Supervisor health:')
  clauses_line=$(line_of "$out" 'Mandate clauses:')
  waiting_line=$(line_of "$out" 'Waiting on you:')
  failed_line=$(line_of "$out" 'Tried and failed, or could not be fixed:')
  [ -n "$health_line" ] && [ -n "$clauses_line" ] && [ -n "$waiting_line" ] && [ -n "$failed_line" ] \
    || fail "the brief is missing a section: $out"
  [ "$health_line" -lt "$clauses_line" ] && [ "$clauses_line" -lt "$waiting_line" ] && [ "$waiting_line" -lt "$failed_line" ] \
    || fail "the brief sections are out of order (health $health_line, clauses $clauses_line, waiting $waiting_line, failed $failed_line)"
  assert_contains "$out" '1. merge task fix-windows PR when checks green - recorded, not executed by this release' "the accepted clause was not listed as recorded-only"
  assert_contains "$out" '2. prerelease repo no-mistakes when after clause 1 - recorded, not executed by this release' "the second clause was not listed"
  assert_contains "$out" '3. "action=merge object=everything when=(none)" - refused at entry: missing when' "the refused clause was not listed with its missing part"
  assert_contains "$out" 'merge the windows fix when green, then cut a prerelease' "the captain's verbatim words were not carried into the brief"
  assert_contains "$out" 'fix-windows,queued,task' "the held backlog item was not listed under waiting on you"
  assert_contains "$out" 'awaiting the captain on the merge' "the hold reason was not listed"
  assert_contains "$out" 'other [key=pick] needs your decision: choose the target' "the open decision was not listed under waiting on you"
  assert_contains "$out" 'fix-windows: blocked on a token only the captain holds; held for return' "the captain-verdict outcome was not listed"
  assert_contains "$out" 'fix-windows [key=token] still blocked, firstmate remediates before ordinary work' "the blocker sharing a task with a captain outcome was exempted"
  assert_contains "$out" 'other [key=dep] still blocked, firstmate remediates before ordinary work' "the unreached blocker was not listed as could-not-fix"
  assert_contains "$out" 'dead: failed: the reproduction never compiled' "the failed task was not listed"
  assert_contains "$out" '1 routine outcome(s) recorded' "the routine outcome count was not reported"
  assert_contains "$out" 'other: resent the steer; worker resumed' "the routine outcome was not listed"
  assert_contains "$out" 'Cost: 2 supervision outcome(s) recorded (1 routine, 1 captain); 3 task(s) live at return.' "the cost line is wrong"
  assert_contains "$out" 'firstmate-actionable blocker: other [key=dep]' "the unreached blocker did not gate"
  assert_contains "$out" 'firstmate-actionable blocker: fix-windows [key=token]' "a captain outcome incorrectly exempted an open blocker"
  grep -F "$(printf 'contract\t')" "$gate" >/dev/null || fail "the gate did not retain the posture-record window"
  grep -F "$(printf 'evidence\thealth\t')" "$gate" >/dev/null || fail "the gate did not retain the health snapshot"

  # Remediate both blockers; the check re-renders the same brief from the
  # archived record and clears.
  printf 'resolved [key=dep]: the upstream dependency landed\n' >> "$dir/home/state/other.status"
  printf 'resolved [key=token]: the token was refreshed\n' >> "$dir/home/state/fix-windows.status"
  second=$(run_return "$dir" check) || fail "the remediated return did not clear: $second"
  assert_contains "$second" '1. merge task fix-windows PR when checks green - recorded, not executed by this release' "check did not re-render the mandate from the archived record"
  assert_contains "$second" 'supervision ran through the away window with no detected gap' "check lost the health snapshot taken at begin"
  assert_contains "$second" 'catch-up clear' "check did not clear the gate"
  [ ! -e "$gate" ] || fail "the cleared check left the gate behind"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" guard \
    || fail "guard still refused after the record was archived and the gate cleared"
  pass "the return brief renders health, mandate, waiting, could-not-fix, handled, and cost from durable records, and the gate shrinks to what the away session could not fix"
}

test_return_brief_keeps_refresh_history() {
  local dir out first_epoch
  dir="$TMP_ROOT/brief-refresh"
  install_runner "$dir"
  contract_in "$dir" propose --words 'first mandate' \
    --action merge --object 'task first PR' --when 'checks green' >/dev/null 2>&1 || fail "could not propose the first mandate"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the first mandate"
  first_epoch=$(contract_in "$dir" field entered_epoch)
  outcome_in "$dir" append --task first --verdict routine \
    --summary 'completed before the mandate refresh' --wake 'signal: first.status' >/dev/null \
    || fail "could not seed the pre-refresh outcome"
  contract_in "$dir" propose --words $'replacement mandate\n\n' \
    --action wake-me --object 'task second' --when 'at 2026-09-08T08:00Z' >/dev/null 2>&1 || fail "could not propose the replacement mandate"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the replacement mandate"
  [ "$(contract_in "$dir" field entered_epoch)" = "$first_epoch" ] || fail "refresh changed the away-window boundary"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "refreshed posture return did not clear: $out"
  assert_contains "$out" 'merge task first PR when checks green - superseded at ' "the superseded mandate was omitted"
  assert_contains "$out" 'wake-me task second when at 2026-09-08T08:00Z - recorded' "the final mandate was omitted"
  assert_contains "$out" 'first: completed before the mandate refresh' "the pre-refresh outcome was omitted"
  assert_contains "$out" $'    replacement mandate\n    \nWaiting on you:' "the return brief dropped a trailing blank line from the final words"
  [ -f "$dir/home/state/afk-contracts/$first_epoch.afk-contract" ] || fail "return did not archive the final session record at the canonical path"
  pass "a refreshed posture keeps its original window, superseded mandate, and earlier outcomes"
}

test_malformed_posture_record_keeps_catchup_gated() {
  local dir out rc gate record before
  dir="$TMP_ROOT/malformed-posture-record"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  record="$dir/home/state/.afk-contract"
  printf 'version: 1\nentered: 2026-09-08T08:00:00Z\nentered_epoch: 123\nwords: |-\n  captain words survive\n' > "$record"
  before=$(cat "$record"; printf x)
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a malformed posture record should keep catch-up gated (rc=$rc): $out"
  [ -f "$gate" ] || fail "a malformed posture record did not retain the return gate"
  [ -f "$record" ] || fail "a malformed posture record was archived or deleted"
  [ "$(cat "$record"; printf x)" = "$before" ] || fail "a malformed posture record lost its captain words"
  [ ! -e "$dir/home/state/afk-contracts/123.afk-contract" ] || fail "a malformed posture record was archived"
  assert_contains "$out" "away-posture record unreadable: $record; catch-up stays gated" "return did not name the malformed posture record"
  pass "a malformed posture record stays live and gates return catch-up"
}

test_missing_epoch_record_stays_required_after_disappearing() {
  local dir out rc gate record backup epoch entered
  dir="$TMP_ROOT/missing-epoch-posture-record"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  record="$dir/home/state/.afk-contract"
  backup="$dir/valid-record.backup"
  contract_in "$dir" propose --words 'captain words survive' \
    --action merge --object 'task restored PR' --when 'checks green' >/dev/null || fail "could not propose the posture record"
  contract_in "$dir" confirm >/dev/null || fail "could not confirm the posture record"
  epoch=$(contract_in "$dir" field entered_epoch)
  entered=$(contract_in "$dir" field entered)
  cp "$record" "$backup"
  grep -v '^entered_epoch: ' "$record" > "$dir/damaged-record"
  mv "$dir/damaged-record" "$record"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a malformed record without an epoch should retain catch-up (rc=$rc): $out"
  [ -f "$gate" ] || fail "the malformed record without an epoch did not retain the gate"
  assert_contains "$out" "away-posture record unreadable: $record; catch-up stays gated" "begin did not retain the unreadable record path"
  rm "$record"
  set +e
  out=$(run_return "$dir" check)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "deleting the malformed epochless record cleared catch-up (rc=$rc): $out"
  assert_contains "$out" "away-posture record missing: $record; catch-up stays gated" "check did not name the missing retained record"
  [ -f "$gate" ] || fail "the missing retained record did not preserve the gate"
  cp "$backup" "$record"
  out=$(run_return "$dir" check) || fail "check did not clear after the retained record was restored valid: $out"
  assert_contains "$out" "=== Return brief (away $entered ->" "the restored record did not recover its away window"
  assert_contains "$out" 'merge task restored PR when checks green - recorded' "the restored clause was omitted from the brief"
  assert_contains "$out" 'captain words survive' "the restored captain words were omitted from the brief"
  [ -f "$dir/home/state/afk-contracts/$epoch.afk-contract" ] || fail "the restored record was not archived under its recovered epoch"
  assert_contains "$out" 'catch-up clear' "the restored valid record did not clear catch-up"
  [ ! -e "$gate" ] || fail "the restored valid record left the gate behind"
  pass "an epochless malformed record remains required until restored valid"
}

test_unreadable_outcome_store_keeps_catchup_gated() {
  local dir out rc gate
  dir="$TMP_ROOT/unreadable-outcome-store"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  printf '{malformed json\n' > "$dir/home/state/branch-outcomes.jsonl"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an unreadable outcome store should keep catch-up gated (rc=$rc): $out"
  [ -f "$gate" ] || fail "an unreadable outcome store did not retain the return gate"
  assert_contains "$out" 'outcome store unreadable, catch-up stays gated' "the partial brief did not disclose its unreadable store"
  : > "$dir/home/state/branch-outcomes.jsonl"
  out=$(run_return "$dir" check) || fail "catch-up did not clear after the outcome store was repaired: $out"
  assert_contains "$out" 'catch-up clear' "the repaired outcome store did not clear catch-up"
  assert_not_contains "$out" 'outcome store unreadable' "the repaired store retained stale failure evidence"
  [ ! -e "$gate" ] || fail "the repaired outcome store left the return gate behind"
  pass "an unreadable outcome store gates catch-up until a successful reread"
}

test_failed_held_listing_keeps_catchup_gated() {
  local dir out waiting rc gate
  dir="$TMP_ROOT/held-list-failure"
  install_runner "$dir"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'synthetic held backlog failure\n' >&2
exit 1
SH
  chmod +x "$dir/fakebin/tasks-axi"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  gate="$dir/home/state/.afk-return-catchup"
  set +e
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-afk-return.sh" begin 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a failed held-set read should keep catch-up gated (rc=$rc): $out"
  [ -f "$gate" ] || fail "a failed held-set read did not retain the return gate"
  waiting=$(printf '%s\n' "$out" | awk '/^Waiting on you:/{show=1} /^Tried and failed, or could not be fixed:/{show=0} show')
  assert_contains "$waiting" "held listing unavailable: $dir/home/data/backlog.md: synthetic held backlog failure; catch-up stays gated" "the failed held listing was not disclosed"
  assert_not_contains "$waiting" '(nothing)' "an unavailable held set was also reported as empty"
  out=$(run_return "$dir" check) || fail "catch-up did not clear after the held-set reader recovered: $out"
  assert_contains "$out" 'catch-up clear' "the recovered held-set reader did not clear catch-up"
  [ ! -e "$gate" ] || fail "the recovered held-set reader left the return gate behind"
  pass "an unavailable held listing gates catch-up until a successful reread"
}

test_unreadable_status_file_keeps_catchup_gated() {
  local dir out rc gate status
  dir="$TMP_ROOT/unreadable-status"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  status="$dir/home/state/unreadable.status"
  printf 'window=synthetic:fm-unreadable\nbackend=tmux\nkind=ship\n' > "$dir/home/state/unreadable.meta"
  printf 'needs-decision [key=hidden]: private captain decision\nfailed: private failure detail\n' > "$dir/status-source"
  ln -s "$dir/status-source" "$status"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an unreadable status should keep catch-up gated (rc=$rc): $out"
  [ -f "$gate" ] || fail "an unreadable status did not retain the return gate"
  assert_contains "$out" "status file unreadable: $status; catch-up stays gated" "the partial brief did not name the unreadable status"
  assert_not_contains "$out" 'private captain decision' "the brief followed the refused status symlink for a decision"
  assert_not_contains "$out" 'private failure detail' "the brief followed the refused status symlink for a failure"
  rm "$status"
  : > "$status"
  out=$(run_return "$dir" check) || fail "catch-up did not clear after the status file was repaired: $out"
  assert_contains "$out" 'catch-up clear' "the repaired status did not clear catch-up"
  assert_not_contains "$out" 'status file unreadable:' "the repaired status retained stale failure evidence"
  [ ! -e "$gate" ] || fail "the repaired status left the return gate behind"
  pass "an unreadable status stays private and gates until a successful reread"
}

test_return_guard_refuses_while_the_record_exists() {
  local dir out rc
  dir="$TMP_ROOT/guard-record"
  install_runner "$dir"
  contract_in "$dir" propose >/dev/null 2>&1 || fail "could not propose the away-posture record"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not write the away-posture record"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" guard 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "guard should refuse while the away-posture record exists (rc=$rc): $out"
  assert_contains "$out" 'away mode is still active' "guard did not name the away posture"
  [ ! -e "$dir/home/state/.afk" ] || fail "fixture error: the legacy flag should be absent in this case"
  pass "the read-only guard treats the away-posture record as active away mode without the legacy flag"
}

test_return_brief_health_leads_with_a_gap() {
  local dir out gap_line clean_line
  dir="$TMP_ROOT/brief-gap"
  install_runner "$dir"
  contract_in "$dir" propose >/dev/null 2>&1 || fail "could not propose the away-posture record"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not write the away-posture record"
  : > "$dir/home/state/.watcher-down"
  # A beacon older than the grace, on either date flavor.
  touch "$dir/home/state/.last-watcher-beat"
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$(( $(date +%s) - 900 ))" '+%Y%m%d%H%M.%S')" "$dir/home/state/.last-watcher-beat"
  else touch -m -d "@$(( $(date +%s) - 900 ))" "$dir/home/state/.last-watcher-beat"; fi
  : > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "a clean fleet with a supervision gap should still clear the gate: $out"
  assert_contains "$out" 'GAP: watcher downtime was detected during the away window' "the downtime marker was not reported as a gap"
  assert_contains "$out" 'GAP: the watcher beat was ' "the stale beacon was not reported as a gap"
  assert_not_contains "$out" 'no detected gap' "a gap window was reported as clean"
  gap_line=$(line_of "$out" 'GAP: watcher downtime')
  clean_line=$(line_of "$out" 'Mandate clauses:')
  [ "$gap_line" -lt "$clean_line" ] || fail "the gap was not reported before the mandate"
  pass "the return brief leads with supervisor health and names every detected gap"
}

test_return_brief_without_a_record_reports_the_legacy_flag() {
  local dir out
  dir="$TMP_ROOT/brief-legacy"
  install_runner "$dir"
  printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "a legacy-flag return with no blockers should clear: $out"
  assert_contains "$out" '(no away-posture record for this window; legacy away flag only)' "the legacy window was not named"
  assert_contains "$out" ', 2h00m) ===' "the away window was not measured from the legacy flag's own timestamp"
  [ ! -e "$dir/home/state/.afk" ] || fail "the legacy flag survived the return"
  pass "a return with only the legacy away flag still renders the brief and measures the window from the flag"
}



test_unreadable_superseded_archive_keeps_return_gated() {
  local dir out rc epoch archive backup
  dir="$TMP_ROOT/superseded-unreadable"
  install_runner "$dir"
  contract_in "$dir" propose --words 'first mandate' \
    --action merge --object 'task first PR' --when 'checks green' >/dev/null 2>&1 || fail "could not propose the first mandate"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the first mandate"
  epoch=$(contract_in "$dir" field entered_epoch)
  contract_in "$dir" propose --words 'replacement mandate' \
    --action wake-me --object 'task second' --when 'at 2026-09-08T08:00Z' >/dev/null 2>&1 || fail "could not propose the replacement mandate"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the replacement mandate"
  archive=""
  for archive in "$dir/home/state/afk-contracts/$epoch-superseded-"*.afk-contract; do break; done
  [ -f "$archive" ] || fail "no superseded archive was written"
  backup="$dir/superseded.backup"
  cp "$archive" "$backup"
  printf 'version: 1\n' > "$archive"
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an unreadable superseded archive must keep catch-up gated (rc=$rc): $out"
  assert_contains "$out" 'superseded away-posture record unreadable' "the gate did not name the unreadable superseded archive"
  [ -e "$dir/home/state/.afk-return-catchup" ] || fail "the gate was not retained"
  rm -f "$archive"
  set +e
  out=$(run_return "$dir" check)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "deleting the named superseded archive cleared catch-up (rc=$rc): $out"
  assert_contains "$out" "superseded away-posture record missing: $archive" "check did not retain the exact missing archive"
  cp "$backup" "$archive"
  out=$(run_return "$dir" check) || fail "check did not clear once the superseded archive was restored: $out"
  assert_contains "$out" 'catch-up clear' "check did not clear the gate"
  pass "an unreadable superseded mandate stays required until its record validates"
}

test_missing_final_archive_keeps_retained_contract_gated() {
  local dir out rc epoch archive backup
  dir="$TMP_ROOT/final-archive-missing"
  install_runner "$dir"
  contract_in "$dir" propose --words 'durable mandate' \
    --action merge --object 'task final PR' --when 'checks green' >/dev/null 2>&1 || fail "could not propose the mandate"
  contract_in "$dir" confirm >/dev/null 2>&1 || fail "could not confirm the mandate"
  epoch=$(contract_in "$dir" field entered_epoch)
  seed_live_blocker "$dir" tmux repair-final
  touch "$dir/home/state/.last-watcher-beat"
  : > "$dir/home/state/.fake-drain"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "the live blocker did not retain catch-up (rc=$rc): $out"
  archive="$dir/home/state/afk-contracts/$epoch.afk-contract"
  [ -f "$archive" ] || fail "return did not archive the final posture record"
  backup="$dir/final.backup"
  cp "$archive" "$backup"
  rm "$archive"
  printf 'resolved [key=repair-final]: repaired the synthetic blocker\n' >> "$dir/home/state/repair-task.status"
  set +e
  out=$(run_return "$dir" check)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "check cleared after the retained final archive disappeared (rc=$rc): $out"
  assert_contains "$out" "archived away-posture record missing for entered_epoch $epoch; catch-up stays gated" "check did not name the missing final archive"
  [ -f "$dir/home/state/.afk-return-catchup" ] || fail "the missing final archive did not retain the gate"
  cp "$backup" "$archive"
  out=$(run_return "$dir" check) || fail "check did not clear after the final archive was restored: $out"
  assert_contains "$out" 'catch-up clear' "a valid restored final archive did not clear catch-up"
  pass "the retained contract epoch requires its final archive on every check"
}

test_return_gate_orders_catchup_before_bearings
test_explicit_reclassification_requires_durable_reason
test_captain_decision_does_not_masquerade_as_firstmate_blocker
test_evidence_publication_failure_preserves_wake_for_redrain
test_away_reentry_refuses_pending_return_gate
test_check_retries_recorded_terminal_teardown
test_unreadable_superseded_archive_keeps_return_gated
test_missing_final_archive_keeps_retained_contract_gated
test_return_brief_composes_from_record_store_and_held_set
test_return_brief_keeps_refresh_history
test_malformed_posture_record_keeps_catchup_gated
test_missing_epoch_record_stays_required_after_disappearing
test_unreadable_outcome_store_keeps_catchup_gated
test_failed_held_listing_keeps_catchup_gated
test_unreadable_status_file_keeps_catchup_gated
test_return_guard_refuses_while_the_record_exists
test_return_brief_health_leads_with_a_gap
test_return_brief_without_a_record_reports_the_legacy_flag
