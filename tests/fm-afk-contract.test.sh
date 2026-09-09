#!/usr/bin/env bash
# tests/fm-afk-contract.test.sh - the away-posture record owner
# (bin/fm-afk-contract.sh): the mandate-clause fields, the structural refusal
# naming the missing part, the never-set scan, the read-back rendering, the entry announcement (hold-for-
# return only), the propose/confirm lifecycle with verbatim words, the refresh
# and replace rules, the archive at return, and the read subcommands every
# consumer uses instead of parsing the file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRACT="$ROOT/bin/fm-afk-contract.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-contract-tests)

make_home() {  # <name> -> prints the home dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

contract() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" "$@"
}

# compile_refusal <expected-missing-fragment> <label> <field flags...>
compile_refusal() {
  local expected=$1 label=$2 home out rc
  shift 2
  home=$(make_home "refuse-$RANDOM-$$")
  set +e
  out=$(contract "$home" compile "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "$label: expected exit 3 for a refused clause, got $rc: $out"
  assert_contains "$out" "refused: missing $expected" "$label: the refusal did not name the missing part"
  assert_contains "$out" '    (none)' "$label: a refused-only compile should list no accepted clause"
}

# compile_accept <expected-readback-line> <label> <field flags...>
compile_accept() {
  local expected=$1 label=$2 home out rc
  shift 2
  home=$(make_home "accept-$RANDOM-$$")
  set +e
  out=$(contract "$home" compile "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label: expected exit 0 for an accepted clause, got $rc: $out"
  assert_contains "$out" "$expected" "$label: the accepted clause was not read back as given"
}

# The structural check refuses only a missing field, an unlisted verb, or a
# never-set concept, and names the missing part every time.
test_fields_refuse_each_missing_part_by_name() {
  compile_refusal "action - 'fix' is not a mandate verb" 'unknown verb' --action fix --object 'whatever breaks' --when 'it breaks'
  compile_refusal 'action - the clause names no action' 'empty verb' --action '' --object 'task x PR' --when 'checks green'
  compile_refusal 'object - the clause names no thing to act on' 'no object' --action merge --when 'checks green'
  compile_refusal 'object - the clause names no thing to act on' 'blank object' --action merge --object '   ' --when 'checks green'
  compile_refusal 'when - the clause states no precondition' 'no when' --action merge --object 'task x PR'
  compile_refusal 'when - the clause states no precondition' 'blank when' --action merge --object 'task x PR' --when ' '
  compile_refusal 'object - the never-set refuses it' 'never-set: credentials' --action answer --object 'the credential prompt on task q' --when asked
  compile_refusal 'object - the never-set refuses it' 'never-set: legal' --action answer --object 'the legal acceptance on task q' --when asked
  compile_refusal 'object - the never-set refuses it' 'never-set: attended prompt' --action answer --object 'the attended prompt on task q' --when asked
  compile_refusal 'object - the never-set refuses it' 'never-set: credential compound' --action answer --object 'task q credential-prompt' --when 'prompt starts'
  compile_refusal 'object - the never-set refuses it' 'never-set: credential punctuation' --action answer --object 'task q credentials/keys' --when 'prompt starts'
  compile_refusal 'object - the never-set refuses it' 'never-set: attended compound' --action answer --object 'task q attended-prompt' --when 'prompt starts'
  compile_refusal 'object - the never-set refuses it' 'never-set: payment prefix' --action answer --object 'task q payments' --when 'prompt starts'
  compile_refusal 'object - the never-set refuses it' 'never-set: in the precondition' --action merge --object 'task x PR' --when 'after the Login/2FA prompt clears'
  compile_refusal 'object - the never-set refuses it' 'never-set: in the stop' --action merge --object 'task x PR' --when 'checks green' --stop 'if a PASSWORD is asked'
  pass "every malformed clause is refused with its missing part named, and the never-set holds across punctuation and compounds"
}

# No parser reads the object or precondition: any text the captain gives is
# recorded verbatim, including wording a grammar would have judged.
test_fields_record_the_captain_wording_verbatim() {
  compile_accept '1. merge task nm-windows-fix-r1 PR when checks green' 'green merge' \
    --action merge --object 'task nm-windows-fix-r1 PR' --when 'checks green'
  compile_accept "1. merge task x's PR when checks green" 'possessive PR role' \
    --action merge --object "task x's PR" --when 'checks green'
  compile_accept '1. merge task y PR when red on nm-ci-windows' 'red merge with the failing check named' \
    --action Merge --object 'task y PR' --when 'red on nm-ci-windows'
  compile_accept '1. merge task y PR when even if nm-ci-windows is red stop the captain returns' 'stop field' \
    --action merge --object 'task y PR' --when 'even if nm-ci-windows is red' --stop 'the captain returns'
  compile_accept '1. abort-run no-mistakes run for task nm-ci-windows-git-shard-split-r1 when install deadlocks' 'named event' \
    --action abort-run --object 'no-mistakes run for task nm-ci-windows-git-shard-split-r1' --when 'install deadlocks'
  compile_accept '1. wake-me task fix-windows when at 2026-09-08T08:00Z' 'time precondition' \
    --action wake-me --object 'task fix-windows' --when 'at 2026-09-08T08:00Z'
  compile_accept '1. discard the worktree of task w when its rerun fails twice' 'named discard' \
    --action discard --object 'the worktree of task w' --when 'its rerun fails twice'
  compile_accept '1. merge task x PR when looks red enough, honestly' 'wording is recorded, never judged' \
    --action merge --object 'task x PR' --when 'looks red enough, honestly'
  compile_accept '1. dispatch these queued items when the windows lane is green' 'dispatch' \
    --action dispatch --object 'these queued items' --when 'the windows lane is green'
  pass "clause fields are recorded verbatim, and no static parser judges the wording"
}

test_clause_ids_are_input_ordinals_across_accepted_and_refused() {
  local home out rc
  home=$(make_home ordinals)
  set +e
  out=$(contract "$home" compile \
    --action merge --object 'task a PR' --when 'checks green' \
    --action merge --object regardless \
    --action prerelease --object 'repo r' --when 'after clause 1' \
    --action install --object 'the prerelease on mini' --when 'after clause 3' \
    --action rerun --object 'task t' --when 'after clause 4' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a mixed compile should exit 3 (rc=$rc): $out"
  assert_contains "$out" '1. merge task a PR when checks green' 'clause 1 accepted'
  assert_contains "$out" '2. "action=merge object=regardless when=(none)" - refused: missing when - the clause states no precondition' 'clause 2 refused for its missing precondition'
  assert_contains "$out" '3. prerelease repo r when after clause 1' 'clause 3 keeps its input ordinal'
  assert_contains "$out" '4. install the prerelease on mini when after clause 3' 'clause 4 keeps its input ordinal'
  assert_contains "$out" '5. rerun task t when after clause 4' 'clause 5 keeps its input ordinal'
  [ "$(contract "$home" compile --action merge --object 'task a PR' --when 'checks green' --action merge --object regardless --action rerun --object 'task t' --when 'after clause 1' 2>/dev/null | grep -c '^    [0-9]')" -eq 3 ] \
    || fail "the read-back did not list every clause once"
  pass "clause ids are input ordinals across accepted and refused clauses"
}

test_readback_renders_words_verbatim_and_both_lists() {
  local home out words
  home=$(make_home readback)
  words="$home/words.txt"
  printf 'drive the windows fix to green and merge it,\n  cut a prerelease; then re-run "nm-ci-windows"\n\tif the install deadlocks abort the competing pipeline\n' > "$words"
  out=$(contract "$home" propose --words-file "$words" --expected-return 2026-09-08T08:00Z --spend 3 \
    --action merge --object 'task nm-windows-fix-r1 PR' --when 'checks green' \
    --action merge --object 'regardless of checks' 2>&1) || true
  assert_contains "$out" 'Away posture read-back (proposed, not yet confirmed):' 'read-back title'
  assert_contains "$out" 'expected return: 2026-09-08T08:00Z' 'expected return rendered'
  assert_contains "$out" 'spend cap: 3 concurrent workers' 'spend cap rendered'
  assert_contains "$out" 'reach: hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'reach rendered'
  assert_contains "$out" '    drive the windows fix to green and merge it,' 'words line 1'
  assert_contains "$out" '      cut a prerelease; then re-run "nm-ci-windows"' 'words line 2 keeps its own indentation and quotes'
  assert_contains "$out" "$(printf '    \tif the install deadlocks')" 'words line 3 keeps its tab'
  assert_contains "$out" '  accepted clauses:' 'accepted list header'
  assert_contains "$out" '    1. merge task nm-windows-fix-r1 PR when checks green' 'accepted clause'
  assert_contains "$out" '  refused clauses:' 'refused list header'
  assert_contains "$out" '    2. "action=merge object=regardless of checks when=(none)" - refused: missing when' 'refused clause'
  assert_contains "$out" 'every clause expires at return' 'the never-set reminder'
  assert_contains "$out" 'recorded clauses are held for the return brief and are not executed by this release' 'the not-executed notice'
  assert_contains "$out" 'Say go to confirm' 'confirmation prompt'
  # The verbatim words survive the record byte for byte, trailing newline included.
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$words"; printf x)" ] || fail "the proposal did not keep the words verbatim"
  pass "the read-back renders the words verbatim beside the accepted and refused lists"
}

test_propose_confirm_writes_the_record_and_announces_hold_for_return() {
  local home out record proposed_epoch
  home=$(make_home lifecycle)
  contract "$home" propose --words 'merge it when green' --action merge --object 'task a PR' --when 'checks green' \
    --action merge --object everything >/dev/null 2>&1 || true
  [ -f "$home/state/.afk-contract.proposed" ] || fail "propose did not write the proposal"
  proposed_epoch=$(contract "$home" field entered_epoch --proposal)
  contract "$home" present && fail "a proposal alone must not count as the posture"
  sleep 1
  out=$(contract "$home" confirm 2>&1) || fail "confirm failed: $out"
  record="$home/state/.afk-contract"
  [ -f "$record" ] || fail "confirm did not write the record"
  [ ! -f "$home/state/.afk-contract.proposed" ] || fail "confirm left the proposal behind"
  contract "$home" present || fail "present did not see the confirmed record"
  assert_contains "$out" 'Away posture confirmed at ' 'announcement opens with the confirmation time'
  assert_contains "$out" 'hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'announcement says hold-for-return only, aloud'
  assert_contains "$out" '1 mandate clause(s) recorded and 1 refused; recorded clauses are held for the return brief and are not executed by this release.' 'announcement counts clauses and says they are not executed'
  assert_contains "$out" 'Expected return: not given. Spend cap: 4 concurrent workers.' 'announcement carries the defaults'
  [ "$(contract "$home" announce)" = "$out" ] || fail "announce did not reproduce the confirmation announcement"
  [ "$(contract "$home" field version)" = 1 ] || fail "record version is not 1"
  [ "$(contract "$home" field reach_channels)" = none ] || fail "reach channels are not none"
  case "$(contract "$home" field confirmed_epoch)" in ''|*[!0-9]*) fail "confirmed_epoch is not numeric" ;; esac
  case "$(contract "$home" field entered_epoch)" in ''|*[!0-9]*) fail "entered_epoch is not numeric" ;; esac
  [ "$(contract "$home" field entered_epoch)" -gt "$proposed_epoch" ] || fail "entry time was not stamped at confirmation"
  [ "$(contract "$home" words)" = 'merge it when green' ] || fail "words did not round-trip"
  [ "$(contract "$home" clauses)" = "$(printf '1\tmerge\ttask a PR\tchecks green\t-')" ] || fail "clauses TSV is wrong: $(contract "$home" clauses)"
  [ "$(contract "$home" refused | cut -f1,2)" = "$(printf '2\taction=merge object=everything when=(none)')" ] || fail "refused TSV is wrong: $(contract "$home" refused)"
  pass "propose then confirm writes the record, announces hold-for-return only, and every read subcommand reflects it"
}

test_confirm_requires_readback_and_refresh_is_a_no_op() {
  local home out first rc
  home=$(make_home defaults)
  set +e
  out=$(contract "$home" confirm 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "confirm without a proposal wrote a record"
  assert_contains "$out" 'run propose before confirm' 'confirm refusal names the required read-back step'
  [ ! -e "$home/state/.afk-contract" ] || fail "confirm without a proposal created posture state"
  contract "$home" propose >/dev/null || fail "plain proposal failed"
  out=$(contract "$home" confirm 2>&1) || fail "plain confirmation failed: $out"
  assert_contains "$out" 'No mandate clauses recorded.' 'plain announcement'
  assert_contains "$out" 'hold-for-return only.' 'plain announcement says hold-for-return'
  first=$(cat "$home/state/.afk-contract")
  sleep 1
  out=$(contract "$home" confirm 2>&1) || fail "refresh confirm failed: $out"
  assert_contains "$out" 'already recorded at' 'refresh names the standing record'
  [ "$(cat "$home/state/.afk-contract")" = "$first" ] || fail "a refresh rewrote the standing record"
  pass "confirmation requires a read-back, and refresh leaves the standing record untouched"
}

test_confirming_a_new_proposal_archives_the_standing_record() {
  local home first_epoch archived
  home=$(make_home replace)
  contract "$home" propose >/dev/null 2>&1 || fail "first propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "first confirm failed"
  first_epoch=$(contract "$home" field entered_epoch)
  sleep 1
  contract "$home" propose --action merge --object 'task a PR' --when 'checks green' >/dev/null 2>&1 || fail "second propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "second confirm failed"
  archived=$(find "$home/state/afk-contracts" -name "$first_epoch-superseded-*.afk-contract" -print -quit)
  [ -f "$archived" ] || fail "the superseded record was not archived"
  [ "$(contract "$home" field entered_epoch)" = "$first_epoch" ] || fail "replacement changed the away session start"
  [ "$(contract "$home" clauses | cut -f2)" = merge ] || fail "the new record does not carry the new clause"
  pass "a replacement archives the old mandate and keeps the session start"
}

test_failed_replacement_keeps_the_standing_record() {
  local home before out rc
  home=$(make_home replace-failure)
  contract "$home" propose --words 'original posture' >/dev/null || fail "first propose failed"
  contract "$home" confirm >/dev/null || fail "first confirm failed"
  before=$(cat "$home/state/.afk-contract")
  contract "$home" propose --words 'replacement posture' >/dev/null || fail "replacement propose failed"
  printf 'not a directory\n' > "$home/state/afk-contracts"
  set +e
  out=$(contract "$home" confirm 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "replacement succeeded without an archive destination"
  [ "$(cat "$home/state/.afk-contract")" = "$before" ] || fail "failed replacement removed or changed the standing posture"
  [ -f "$home/state/.afk-contract.proposed" ] || fail "failed replacement discarded the pending proposal"
  pass "a failed replacement keeps the standing posture live"
}

test_archive_moves_the_record_aside_and_is_idempotent() {
  local home epoch path
  home=$(make_home archive)
  contract "$home" propose >/dev/null 2>&1 || fail "propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "confirm failed"
  epoch=$(contract "$home" field entered_epoch)
  path=$(contract "$home" archive) || fail "archive failed"
  [ "$path" = "$home/state/afk-contracts/$epoch.afk-contract" ] || fail "archive path is not keyed by entered_epoch: $path"
  [ -f "$path" ] || fail "archived record missing"
  contract "$home" present && fail "the record still stands after archive"
  contract "$home" archive || fail "a second archive with no record must succeed as a no-op"
  [ "$(contract "$home" archived "$epoch")" = "$path" ] || fail "archived lookup did not find the record"
  [ "$(contract "$home" words --path "$path")" = '' ] || fail "reading an archived record by path failed"
  pass "archive keys the record by its entry time, empties the posture, and is idempotent"
}

test_inputs_are_validated() {
  local home out rc
  home=$(make_home inputs)
  set +e
  out=$(contract "$home" propose --expected-return 'tomorrow morning' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a non-ISO expected return should be a usage error (rc=$rc): $out"
  assert_contains "$out" '--expected-return must be UTC ISO 8601' 'expected-return refusal wording'
  set +e
  out=$(contract "$home" propose --spend 0 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a zero spend cap should be a usage error (rc=$rc): $out"
  set +e
  out=$(contract "$home" propose --object 'task x PR' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an empty clause should be a usage error, not a silent skip (rc=$rc): $out"
  assert_contains "$out" '--object must follow the --action that opens its clause' 'a field with no open clause is a usage error'
  [ ! -f "$home/state/.afk-contract.proposed" ] || fail "an invalid proposal was written"
  set +e
  out=$(contract "$home" announce 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "announce with no record should fail"
  printf 'version: 9\nentered_epoch: 1\nclauses:\nrefused:\n' > "$home/state/.afk-contract"
  set +e
  out=$(contract "$home" announce 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a foreign record version must be refused"
  assert_contains "$out" "carries version '9', expected 1" 'version refusal wording'
  pass "malformed inputs and foreign record versions are refused rather than guessed"
}

test_fields_refuse_each_missing_part_by_name
test_fields_record_the_captain_wording_verbatim
test_clause_ids_are_input_ordinals_across_accepted_and_refused
test_readback_renders_words_verbatim_and_both_lists
test_propose_confirm_writes_the_record_and_announces_hold_for_return
test_confirm_requires_readback_and_refresh_is_a_no_op
test_confirming_a_new_proposal_archives_the_standing_record
test_failed_replacement_keeps_the_standing_record
test_archive_moves_the_record_aside_and_is_idempotent
test_inputs_are_validated
