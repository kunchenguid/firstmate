#!/usr/bin/env bash
# End-to-end tests for the decider lane: the deterministic two-axis
# classification of held work, the ruling ledger, the guarded apply path, the
# captain-facing digest, and the hourly check that wakes only when the lane has
# work it can do without the captain.
#
# Every assertion drives the shipped executables against a fixture backlog, so
# the tests describe behaviour rather than implementation.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECIDER="$ROOT/bin/fm-decider.sh"
CHECK="$ROOT/bin/fm-decider-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-decider)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# A fixture home with a backlog covering every classification the lane must get
# right: a money hold that also says "ruled" (stays Class B), a legal hold, a
# plain Class A hold that is ready, a Class A hold with work outstanding, a
# Class A hold whose reason is already decided, and a hold with no timestamp.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/fakebin"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

- [ ] spend-item - order the new vendor contract (hold: order the new vendor contract, ruled by fable) (hold-kind: captain)
    Captain hold set: 2026-11-01T00:00:00Z
- [ ] legal-item - reply to the counsel letter (hold: reply to the counsel letter) (hold-kind: captain)
    Captain hold set: 2026-11-02T00:00:00Z
- [ ] ready-a - a finished thing (hold: built and green, options: A ship it; B wait) (hold-kind: captain)
    Captain hold set: 2026-11-03T00:00:00Z
- [ ] work-a - an unfinished thing (hold: needs to be built before anything else) (hold-kind: captain)
    Captain hold set: 2026-11-04T00:00:00Z
- [ ] decided-a - already ruled (hold: fable ruled this, unhold and route) (hold-kind: captain)
    Captain hold set: 2026-11-05T00:00:00Z
- [ ] undated-a - no timestamp (hold: drafted and ready for a look) (hold-kind: captain)
- [ ] expired-a - a gate that opened (hold: drafted and ready) (hold-kind: captain) (hold-until: 2020-01-01)
    Captain hold set: 2026-11-06T00:00:00Z
- [ ] reminder-a - a dated reminder (hold: dated reminder: check the log after 48h) (hold-kind: future) (hold-until: 2099-01-01)
    Captain hold set: 2026-11-07T00:00:00Z

## Done
EOF
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/calls.log\nexit 0\n' "$home" > "$home/fakebin/tasks-axi"
  chmod +x "$home/fakebin/tasks-axi"
  printf '%s\n' "$home"
}

run_decider() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$DECIDER" "$@"
}

test_scan_classifies_both_axes() {
  local home out
  home=$(make_home scan)
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md")

  printf '%s\n' "$out" | python3 -c '
import sys, json
rows = {r["id"]: r for r in (json.loads(l) for l in sys.stdin if l.strip())}
def want(task, **fields):
    for key, value in fields.items():
        if rows[task][key] != value:
            raise SystemExit(
                "%s: expected %s=%r, got %r" % (task, key, value, rows[task][key])
            )
want("spend-item", **{"class": "B", "rule": "money"})
want("legal-item", **{"class": "B", "rule": "legal"})
want("ready-a", **{"class": "A", "rule": "no-class-b-rule", "readiness": "ready"})
want("work-a", **{"readiness": "work"})
want("decided-a", **{"rule": "already-decided"})
want("undated-a", **{"age_days": None})
' || fail "scan must classify readiness and class on both axes"
  pass "scan classifies readiness and class on both axes"
}

test_scan_summary_counts_every_hold() {
  local home out
  home=$(make_home summary)
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --summary)
  printf '%s\n' "$out" | grep -q '^held=7 class_a=5 class_b=2$' \
    || fail "summary must count every live hold and split it by class: $out"
  printf '%s\n' "$out" | grep -q 'readiness ready=2' \
    || fail "summary must report readiness counts: $out"
  printf '%s\n' "$out" | grep -q 'missing_hold_timestamp=1' \
    || fail "summary must flag a hold with no timestamp: $out"
  pass "scan summary counts every hold"
}

test_scan_filters_by_class_and_readiness() {
  local home out
  home=$(make_home filters)
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --class B --ids)
  [ "$out" = "$(printf 'spend-item\nlegal-item')" ] \
    || fail "class B filter must return exactly the Class B ids, got: $out"
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --readiness work --ids)
  [ "$out" = "work-a" ] || fail "readiness filter must return exactly the work ids, got: $out"
  pass "scan filters by class and readiness"
}

test_record_appends_one_ledger_line_and_refuses_bad_input() {
  local home ledger
  home=$(make_home record)
  ledger="$home/data/decider/rulings.md"

  run_decider "$home" record ready-a "unhold and ship" "built and green" "wiki/page.md" "re-hold ready-a" >/dev/null \
    || fail "record must accept a complete ruling"
  grep -q '^ready-a | unhold and ship | built and green | wiki/page.md | re-hold ready-a$' "$ledger" \
    || fail "the ledger must carry one line per ruling with reason, evidence, and revert"

  run_decider "$home" record ready-a "again" "r" "e" "v" >/dev/null 2>&1 \
    && fail "record must refuse a second ruling for the same id"
  run_decider "$home" record other-a "r" "r" "e" "" >/dev/null 2>&1 \
    && fail "record must refuse a ruling with no revert"
  run_decider "$home" record other-a "r|pipe" "r" "e" "v" >/dev/null 2>&1 \
    && fail "record must refuse a field containing a pipe"
  pass "record appends one ledger line and refuses bad input"
}

test_apply_lifts_only_ruled_class_a_holds() {
  local home calls
  home=$(make_home apply)
  calls="$home/calls.log"

  run_decider "$home" record ready-a "unhold and ship" "built and green" "wiki" "re-hold" >/dev/null
  run_decider "$home" apply --yes >/dev/null 2>&1 || fail "apply --yes must succeed"

  grep -q '^unhold ready-a$' "$calls" || fail "apply must lift a ruled Class A hold"
  grep -q '^unhold decided-a$' "$calls" && fail "apply must not lift a Class A hold with no ruling"
  grep -q '^unhold spend-item$' "$calls" && fail "apply must never lift a Class B hold"
  grep -q '^unhold legal-item$' "$calls" && fail "apply must never lift a Class B hold"
  grep -q '^unhold work-a$' "$calls" && fail "apply must not lift a hold with work outstanding"
  pass "apply lifts only ruled Class A holds"
}

test_apply_without_yes_changes_nothing() {
  local home calls
  home=$(make_home dryrun)
  calls="$home/calls.log"
  run_decider "$home" record ready-a "unhold and ship" "built and green" "wiki" "re-hold" >/dev/null
  run_decider "$home" apply >/dev/null 2>&1 || fail "a dry run must succeed"
  [ -f "$calls" ] && fail "a dry run must not call tasks-axi at all"
  pass "apply without --yes changes nothing"
}

test_plan_names_the_dispatch_a_stalled_hold_needs() {
  local home out
  home=$(make_home plan)
  out=$(run_decider "$home" plan 2>&1)
  printf '%s\n' "$out" | grep -q '^dispatch: work-a' \
    || fail "plan must name the worker dispatch a stalled hold needs: $out"
  printf '%s\n' "$out" | grep -q '^awaiting-ruling: ready-a' \
    || fail "plan must name a Class A hold still awaiting a ruling: $out"
  pass "plan names the dispatch a stalled hold needs"
}

test_digest_gives_every_class_b_item_exactly_one_line() {
  local home out digest
  home=$(make_home digest)
  run_decider "$home" record ready-a "unhold and ship" "built and green" "wiki" "re-hold" >/dev/null
  digest=$(run_decider "$home" digest --cap 15)
  [ -f "$digest" ] || fail "digest must write a file and print its path"

  [ "$(grep -c '^- \*\*spend-item\*\*' "$digest")" = "1" ] \
    || fail "a Class B item must appear on exactly one line"
  [ "$(grep -c '^- \*\*legal-item\*\*' "$digest")" = "1" ] \
    || fail "a Class B item must appear on exactly one line"
  grep -q '^## Class B - your word, one line each$' "$digest" || fail "digest must group Class B"
  grep -q '^## Class A - decided, no action from you$' "$digest" || fail "digest must group Class A"
  grep -q 'ready-a (.*) - unhold and ship - revert: re-hold' "$digest" \
    || fail "a ruled Class A item must show its ruling and its revert"
  grep -q 'Silence is consent for Class A only' "$digest" \
    || fail "digest must state that silence is consent for Class A only"
  pass "digest gives every Class B item exactly one line"
}

test_digest_caps_each_group() {
  local home digest
  home=$(make_home cap)
  {
    printf '## Queued\n\n'
    for i in 1 2 3 4 5; do
      printf -- '- [ ] money-%s - a spend (hold: order the new vendor contract %s) (hold-kind: captain)\n' "$i" "$i"
      printf '    Captain hold set: 2026-11-0%sT00:00:00Z\n' "$i"
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  digest=$(run_decider "$home" digest --cap 2)
  [ "$(grep -c '^- \*\*money-' "$digest")" = "2" ] || fail "a group must be capped at --cap lines"
  grep -q 'and 3 more in this group' "$digest" || fail "a capped group must say how many it hid"
  pass "digest caps each group"
}

test_check_wakes_only_when_the_lane_has_work() {
  local home out
  home=$(make_home check)

  out=$(FM_HOME="$home" "$CHECK")
  printf '%s\n' "$out" | grep -q 'class_a_unruled=' \
    || fail "the check must wake for a Class A hold with no ruling: $out"
  printf '%s\n' "$out" | grep -q 'stalled=' \
    || fail "the check must wake for a hold with work outstanding: $out"

  run_decider "$home" record ready-a "unhold and ship" "built and green" "wiki" "re-hold" >/dev/null
  run_decider "$home" record decided-a "unhold and route" "already ruled" "wiki" "re-hold" >/dev/null
  run_decider "$home" record work-a "dispatch a worker" "work outstanding" "wiki" "re-hold" >/dev/null
  run_decider "$home" record undated-a "unhold and route" "drafted" "wiki" "re-hold" >/dev/null
  run_decider "$home" record reminder-a "unhold and route" "dated reminder" "wiki" "re-hold" >/dev/null

  out=$(FM_HOME="$home" "$CHECK")
  printf '%s\n' "$out" | grep -q 'class_a_unruled=' \
    && fail "the check must stop reporting unruled Class A holds once every one is ruled: $out"
  printf '%s\n' "$out" | grep -q 'stalled=1 (work-a)' \
    || fail "the check must keep waking for a hold that still has work outstanding: $out"

  # A hold with work outstanding is stalled, not held, so it must leave the
  # queue once a worker owns it. With it gone the lane has nothing to do.
  grep -v 'work-a' "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  out=$(FM_HOME="$home" "$CHECK")
  [ -z "$out" ] || fail "the check must stay silent when every hold is at the one-act boundary: $out"
  pass "check wakes only when the lane has work"
}

test_status_reports_the_queue_in_one_line() {
  local home out
  home=$(make_home status)
  out=$(run_decider "$home" status)
  printf '%s\n' "$out" | grep -q '^held=7 class_a=5 class_b=2 ready=2 work=1 unknown=4$' \
    || fail "status must report the whole queue on one line: $out"
  printf '%s\n' "$out" | grep -q '^class_a_awaiting_ruling=5$' \
    || fail "status must report how many Class A holds still await a ruling: $out"
  pass "status reports the queue in one line"
}

test_scan_of_an_empty_queue_says_so_and_invents_nothing() {
  local home out
  home=$(make_home empty)
  printf '## Queued\n\n## Done\n' > "$home/data/backlog.md"
  out=$(run_decider "$home" plan 2>&1)
  printf '%s\n' "$out" | grep -q '^held=0 class_a=0 class_b=0' \
    || fail "an empty queue must report zero: $out"
  printf '%s\n' "$out" | grep -q 'nothing for the lane to rule' \
    || fail "an empty queue must say so rather than inventing work: $out"
  pass "scan of an empty queue says so and invents nothing"
}

test_expired_holds_leave_the_queue_and_reminders_are_class_a() {
  local home out
  home=$(make_home expiry)

  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --ids)
  printf '%s\n' "$out" | grep -qx 'expired-a' \
    && fail "a hold whose hold-until date has passed must leave the live queue: $out"

  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --ids --include-expired)
  printf '%s\n' "$out" | grep -qx 'expired-a' \
    || fail "--include-expired must still report an expired hold: $out"

  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --ids --class A)
  printf '%s\n' "$out" | grep -qx 'reminder-a' \
    || fail "a dated reminder is a time gate the fleet owns, so it must be Class A: $out"
  pass "expired holds leave the queue and reminders are Class A"
}

test_an_explicit_captain_instruction_is_never_class_a() {
  local home out
  home=$(make_home captain-instruction)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

- [ ] said-no - a green PR (hold: the captain said do not merge it, it is waiting on Aaron) (hold-kind: captain)
    Captain hold set: 2026-11-01T00:00:00Z
- [ ] his-switch - a feature flag (hold: the repo contract names the captain as owner of that switch) (hold-kind: captain)
    Captain hold set: 2026-11-02T00:00:00Z
- [ ] his-switches - three toggles (hold: three switches move more users than any code and are the captain's) (hold-kind: captain)
    Captain hold set: 2026-11-03T00:00:00Z
- [ ] standing-grant - a policy question (hold: the captain's standing grant covers PRs that pass QA, but it was written about fleet work) (hold-kind: captain)
    Captain hold set: 2026-11-04T00:00:00Z

## Done
EOF
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --class B --ids)
  printf '%s\n' "$out" | grep -qx 'said-no' || fail "an explicit do-not-merge instruction must be Class B: $out"
  printf '%s\n' "$out" | grep -qx 'his-switch' || fail "a switch the record names as the captain's must be Class B: $out"
  printf '%s\n' "$out" | grep -qx 'his-switches' || fail "a switch the captain owns must be Class B: $out"
  printf '%s\n' "$out" | grep -qx 'standing-grant' \
    && fail "a standing grant the fleet already holds is not a call to return: $out"
  pass "an explicit captain instruction is never Class A"
}

test_a_spend_or_a_send_under_his_name_is_class_b() {
  local home out
  home=$(make_home spend-send)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

- [ ] currency - a proof order (hold: approve one live order, about 180 USD landed US) (hold-kind: captain)
    Captain hold set: 2026-11-01T00:00:00Z
- [ ] phone - a shipping label (hold: the order needs a phone number for the label) (hold-kind: captain)
    Captain hold set: 2026-11-02T00:00:00Z
- [ ] notes - feedback (hold: send the Nick and Artem notes via the CTO bot) (hold-kind: captain)
    Captain hold set: 2026-11-03T00:00:00Z
- [ ] drafts - feedback (hold: two feedback drafts are ready, send both or none) (hold-kind: captain)
    Captain hold set: 2026-11-04T00:00:00Z

## Done
EOF
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md" --class B --ids)
  for id in currency phone notes drafts; do
    printf '%s\n' "$out" | grep -qx "$id" || fail "$id must be Class B: $out"
  done
  pass "a spend or a send under his name is Class B"
}

test_a_quoted_option_value_does_not_decide_readiness() {
  local home out
  home=$(make_home quoted)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

- [ ] quoted - a finished report (hold: the report is complete; say 'arm' or 'not yet' for the switch) (hold-kind: captain)
    Captain hold set: 2026-11-01T00:00:00Z

## Done
EOF
  out=$(FM_HOME="$home" python3 "$ROOT/bin/fm-hold-scan.py" --backlog "$home/data/backlog.md")
  printf '%s\n' "$out" | python3 -c '
import sys, json
row = json.loads(next(l for l in sys.stdin if l.strip()))
if row["readiness"] != "ready":
    raise SystemExit("a quoted option value must not make a finished report read as work: %r" % row["readiness"])
' || fail "a quoted option value must not decide readiness"
  pass "a quoted option value does not decide readiness"
}

test_digest_keeps_a_version_number_and_skips_a_bare_verb() {
  local home digest
  home=$(make_home smallest-act)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

- [ ] versioned - a runbook choice (hold: say 'run 9.1' or 'wait for 12-01' for the fenced runbook) (hold-kind: captain)
    Captain hold set: 2026-11-01T00:00:00Z
- [ ] bare-verb - a card of blocks (hold: the captain card is ready for your yes/no words: data/card.md; may the ask classes send) (hold-kind: captain)
    Captain hold set: 2026-11-02T00:00:00Z

## Done
EOF
  digest=$(run_decider "$home" digest --cap 15)
  grep -q "say 'run 9.1' or 'wait for 12-01'" "$digest" \
    || fail "a version number must not be cut at its period"
  grep -q 'the captain card is ready for your yes/no words' "$digest" \
    || fail "a bare verb at the end of a clause names no act, so the opening clause is the line"
  pass "digest keeps a version number and skips a bare verb"
}

test_scan_classifies_both_axes
test_scan_summary_counts_every_hold
test_scan_filters_by_class_and_readiness
test_record_appends_one_ledger_line_and_refuses_bad_input
test_apply_lifts_only_ruled_class_a_holds
test_apply_without_yes_changes_nothing
test_plan_names_the_dispatch_a_stalled_hold_needs
test_digest_gives_every_class_b_item_exactly_one_line
test_digest_caps_each_group
test_check_wakes_only_when_the_lane_has_work
test_status_reports_the_queue_in_one_line
test_scan_of_an_empty_queue_says_so_and_invents_nothing
test_expired_holds_leave_the_queue_and_reminders_are_class_a
test_an_explicit_captain_instruction_is_never_class_a
test_a_spend_or_a_send_under_his_name_is_class_b
test_a_quoted_option_value_does_not_decide_readiness
test_digest_keeps_a_version_number_and_skips_a_bare_verb
