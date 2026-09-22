#!/usr/bin/env bash
# tests/fm-open-decisions-fold.test.sh - the single-pass awk statement of the
# open-decisions fold in bin/fm-classify-lib.sh (_fm_open_decisions_awk, reached
# through status_open_decisions and _fm_status_open_decision_origins) must produce
# byte-for-byte the same open-set and origins as the bash per-line fold rule it
# replaced, and it must fold a whole-lifetime log in milliseconds where the
# per-line fold cost grew past the watcher's 300s heartbeat grace on a large log
# and made the still-alive watcher report itself down.
#
# The reference oracle here is the historical whole-file loop rebuilt over the
# still-present bash _fm_decision_fold_line (the one owner of the per-line
# open/resolved rule). Keeping it executable - never asserting the fold's own
# source bytes - pins the awk statement to that rule across every documented shape
# and a large high-open-count log, and lets this test also demonstrate the
# algorithmic gap that motivated the change: one whole-file bash fold is slower
# than dozens of awk folds of the same log. The whole-file-vs-incremental
# agreement lives in tests/fm-classify-decision-key.test.sh; cross-drain cursor
# persistence lives in tests/fm-wake-drain-open-decisions-cursor.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-open-decisions-fold-tests)

# --- reference oracle: the pre-awk whole-file loops, over the still-present bash
#     _fm_decision_fold_line rule and its helpers. A future change to the fold
#     rule fails this test unless the awk statement is updated to match.
ref_open_decisions() {  # <status-file> [<kind>]
  local f=$1 kind=${2:-} line resolve held open='' verb
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  kind=$(_fm_status_kind "$f" "$kind")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    case "$verb" in
      needs-decision|blocked|done|failed|"$resolve"|"$held")
        open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind") ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

ref_origin_drop() {  # <origins> <key>
  local origin
  while IFS= read -r origin; do
    case "$origin" in "$2"$'\t'*) ;; *) [ -n "$origin" ] && printf '%s\n' "$origin" ;; esac
  done <<EOF
$1
EOF
}

ref_open_decision_origins() {  # <status-file> [<kind>]
  local f=$1 line open='' after key verb note number=0 origins='' resolve held kind
  kind=$(_fm_status_kind "$f" "${2:-}")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    after=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
    [ -n "$after" ] || origins=''
    key=$(_fm_decision_key "$line") || { open=$after; continue; }
    verb=$(status_line_verb "$line")
    note=$(status_line_note "$line")
    case "$verb" in
      needs-decision|blocked)
        if _fm_open_set_has "$after" "$key" \
          && [ "$(_fm_open_set_verb "$after" "$key")" = "$verb" ]; then
          case "$after" in
            "$key"$'\t'"$verb"$'\t'"$note"|*$'\n'"$key"$'\t'"$verb"$'\t'"$note")
              origins=$(ref_origin_drop "$origins" "$key")
              [ -n "$origins" ] && origins="${origins}"$'\n'
              origins="${origins}${key}"$'\t'"${number}" ;;
          esac
        fi ;;
      "$resolve"|"$held")
        _fm_open_set_has "$after" "$key" || origins=$(ref_origin_drop "$origins" "$key") ;;
    esac
    open=$after
  done < "$f"
  printf '%s' "$origins"
}

# Assert the awk open-set and origins equal the bash-rule oracle byte for byte,
# under each given task kind - the ship/scout done/failed terminal clears the set
# while a secondmate terminal never does, so they exercise a different fold path.
assert_equiv() {  # <status-file> <label> [<kind>...]
  local f=$1 label=$2; shift 2
  local kind ro rn go gn
  [ "$#" -gt 0 ] || set -- secondmate ship scout
  for kind in "$@"; do
    ro=$(ref_open_decisions "$f" "$kind"); rn=$(status_open_decisions "$f" "$kind")
    [ "$ro" = "$rn" ] \
      || fail "$label [$kind]: open fold diverged from the bash rule
--- bash rule ---
$ro
--- awk ---
$rn"
    go=$(ref_open_decision_origins "$f" "$kind"); gn=$(_fm_status_open_decision_origins "$f" "$kind")
    [ "$go" = "$gn" ] \
      || fail "$label [$kind]: origins fold diverged from the bash rule
--- bash rule ---
$go
--- awk ---
$gn"
  done
}

# Elapsed wall seconds (float, C locale) of running the given command once.
time_seconds() {  # <cmd> [args...]
  local t
  t=$( { LC_ALL=C TIMEFORMAT='%R'; time "$@" >/dev/null 2>&1; } 2>&1 )
  printf '%s' "$t"
}

run_n() {  # <count> <cmd> [args...]
  local n=$1; shift
  local i
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1; done
}

# --- the documented shapes: keyed and unkeyed, colon-first, reopened, resolved,
#     captain-held, ship/scout done and failed terminals, reserved pending-reply
#     keys, correlation tokens, and readable/placeholder [at=...] stamps.
test_matches_the_bash_rule_on_every_documented_shape() {
  local f="$TMP_ROOT/shapes.status"
  cat > "$f" <<'EOF'
working [at=1700000000]: starting up
needs-decision [key=api-shape]: pick REST or RPC
needs-decision: [key=colon-first] pick queue backend
blocked [key=env-missing]: cannot find SDK
resolved [key=api-shape]: chose REST
needs-decision: plain default question
resolved: closed the default question
needs-decision [key=re-open]: first ask
resolved [key=re-open]: answered once
needs-decision [key=re-open]: asked again with a new note
blocked corr=0123456789abcdef [key=texte-du-mur]: remote blocker
resolved corr=fedcba9876543210 [key=texte-du-mur]: remote resolved
needs-decision corr=0011223344556677 corr=8899aabbccddeeff [key=double-corr]: two tokens
blocked [key=pending-reply-42]: pending-reply-missed: owner escalation
blocked [key=pending-reply-42]: some note that does not speak the reserved vocab
resolved [key=pending-reply-42]: pending-reply-cleared: owner closes
needs-decision [key=BAD SLUG]: an invalid slug is skipped, never folded as default
needs-decision [key=still-open-1]: kept open A
needs-decision [key=still-open-2]: kept open B
working: an ordinary line mentioning [key=still-open-1] in prose only
needs-decision [at=10:30] [key=stamp-colon]: a readable stamp with a colon
blocked [key=has-note-tag] [at=1700000200]: blocked note here
captain-held [key=still-open-2]: handed to a durable captain-held task
done: a terminal line (clears every open decision on a ship or scout)
needs-decision [key=after-terminal]: opened after the terminal line
failed: another terminal
resolved [key=never-opened]: closing a key that was never opened
needs-decision [key=trailing]: the last open decision standing
EOF
  assert_equiv "$f" "documented shapes"
  pass "the awk fold matches the bash rule byte for byte on every documented shape"
}

test_matches_the_bash_rule_on_an_empty_and_absent_log() {
  local empty="$TMP_ROOT/empty.status"
  : > "$empty"
  assert_equiv "$empty" "empty log"
  [ -z "$(status_open_decisions "$TMP_ROOT/does-not-exist.status" secondmate)" ] \
    || fail "an absent log folded to a non-empty open set"
  [ -z "$(_fm_status_open_decision_origins "$TMP_ROOT/does-not-exist.status" secondmate)" ] \
    || fail "an absent log folded to non-empty origins"
  pass "the awk fold matches on an empty log and yields nothing for an absent one"
}

# A large log that accumulates many still-open decisions is exactly the shape
# that made the per-line bash fold exceed the watcher's grace. Fold it under the
# oracle too, so equivalence is proven at scale and the oracle's cost stands in
# for the reproduced symptom.
gen_high_open_log() {  # <path> <lines>
  awk -v lines="$2" 'BEGIN {
    for (i = 1; i <= lines; i++) {
      r = i % 13
      if (r == 0)       print "resolved [key=d" (i - 5) "]: closing an earlier decision " i
      else if (r == 3)  print "blocked corr=0123456789abcdef [key=d" i "]: remote blocker " i
      else if (r == 5)  print "needs-decision: [key=d" i "] colon-first open " i
      else if (r == 7)  print "needs-decision [key=d" (i - 2) "] [at=" (1700000000 + i) "]: reopened with a stamp " i
      else if (r == 9)  print "blocked [key=pending-reply-" i "]: pending-reply-missed: escalation " i
      else if (r == 11) print "working: routine progress mentioning [key=d" i "] in prose " i
      else              print "needs-decision [key=d" i "]: plain open " i
    }
    print "done: a ship/scout terminal in the middle of the log"
    print "needs-decision [key=post-terminal]: reopened after the terminal"
  }' > "$1"
}

test_matches_the_bash_rule_on_a_large_high_open_log() {
  local hi="$TMP_ROOT/high-open.status"
  gen_high_open_log "$hi" 180
  # Guard the fixture actually holds many open decisions, or the scale claim is
  # vacuous.
  local n
  n=$(status_open_decisions "$hi" secondmate | grep -c "$(printf '\t')")
  [ "$n" -ge 100 ] || fail "the high-open fixture held only $n open decisions"
  # secondmate keeps the whole set open (the slow shape); ship folds through the
  # terminal clear at scale. scout matches ship and is covered by the shape test.
  assert_equiv "$hi" "large high-open log" secondmate ship
  pass "the awk fold matches the bash rule on a $n-open, 180-line log"
}

# Regression guard: the new fold must stay near-linear. An O(n*k) reintroduction
# on a 5000-line log with hundreds of open decisions would run for minutes; awk
# folds it in a fraction of a second, so a generous absolute bound catches a
# regression without wall-clock flakiness.
test_new_fold_stays_fast_on_a_5000_line_log() {
  local big="$TMP_ROOT/big.status"
  gen_high_open_log "$big" 5000
  local open_t orig_t
  open_t=$(time_seconds status_open_decisions "$big" secondmate)
  orig_t=$(time_seconds _fm_status_open_decision_origins "$big" secondmate)
  awk -v o="$open_t" -v g="$orig_t" 'BEGIN { exit !(o + 0 < 10 && g + 0 < 10) }' \
    || fail "folding a 5000-line log took open=${open_t}s origins=${orig_t}s (bound 10s each)"
  pass "the awk fold holds a 5000-line log under the 10s bound (open=${open_t}s, origins=${orig_t}s)"
}

# The symptom that motivated the change: the per-line bash fold's cost. One whole
# -file bash fold of the high-open log must be slower than folding the same log
# thirty times with the awk statement - a CPU-independent statement of the
# algorithmic gap, non-vacuous because thirty awk folds take a measurable while.
test_new_fold_far_outpaces_the_per_line_bash_fold() {
  local hi="$TMP_ROOT/high-open.status"
  [ -f "$hi" ] || gen_high_open_log "$hi" 180
  local old_1x new_30x
  old_1x=$(time_seconds ref_open_decision_origins "$hi" secondmate)
  new_30x=$(time_seconds run_n 30 _fm_status_open_decision_origins "$hi" secondmate)
  awk -v o="$old_1x" -v n="$new_30x" 'BEGIN { exit !(o + 0 >= n + 0) }' \
    || fail "one per-line bash fold (${old_1x}s) was not slower than 30 awk folds (${new_30x}s)"
  pass "one per-line bash fold (${old_1x}s) outweighs 30 awk folds (${new_30x}s)"
}

test_matches_the_bash_rule_on_every_documented_shape
test_matches_the_bash_rule_on_an_empty_and_absent_log
test_matches_the_bash_rule_on_a_large_high_open_log
test_new_fold_stays_fast_on_a_5000_line_log
test_new_fold_far_outpaces_the_per_line_bash_fold
