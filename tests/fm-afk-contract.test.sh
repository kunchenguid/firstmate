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
  out=$(contract "$home" propose "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "$label: expected exit 3 for a refused clause, got $rc: $out"
  assert_contains "$out" "refused: missing $expected" "$label: the refusal did not name the missing part"
  assert_contains "$out" '    (none)' "$label: a refused-only proposal should list no accepted clause"
}

# compile_accept <expected-readback-line> <label> <field flags...>
compile_accept() {
  local expected=$1 label=$2 home out rc
  shift 2
  home=$(make_home "accept-$RANDOM-$$")
  set +e
  out=$(contract "$home" propose "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label: expected exit 0 for an accepted clause, got $rc: $out"
  assert_contains "$out" "$expected" "$label: the accepted clause was not read back as given"
}

# compile_flagged <concept> <label> <field flags...>: the clause is recorded
# (exit 0, listed as accepted) and carries the best-effort never-set flag.
compile_flagged() {
  local concept=$1 label=$2 home out rc
  shift 2
  home=$(make_home "flag-$RANDOM-$$")
  set +e
  out=$(contract "$home" propose "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label: a flagged clause must still be recorded (exit 0), got $rc: $out"
  assert_contains "$out" "flagged: names '$concept', a never-set concept that is never pre-authorizable; recorded, judged at execution" "$label: the read-back did not show the flag"
  assert_not_contains "$out" 'refused: missing object' "$label: a never-set match must flag, never refuse"
  [ "$(contract "$home" flags --proposal | cut -f2)" = "$concept" ] || fail "$label: flags did not name the concept: $(contract "$home" flags --proposal)"
}

# compile_unflagged <label> <field flags...>: an ordinary name is neither
# refused nor flagged.
compile_unflagged() {
  local label=$1 home out rc
  shift
  home=$(make_home "plain-$RANDOM-$$")
  set +e
  out=$(contract "$home" propose "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label: an ordinary clause was refused: $out"
  assert_not_contains "$out" 'flagged:' "$label: an ordinary name was flagged"
  [ -z "$(contract "$home" flags --proposal)" ] || fail "$label: flags listed an ordinary clause"
}

# The structural check refuses only a missing field or an unlisted verb, and
# names the missing part every time.
test_fields_refuse_each_missing_part_by_name() {
  compile_refusal "action - 'fix' is not a mandate verb" 'unknown verb' --action fix --object 'whatever breaks' --when 'it breaks'
  compile_refusal 'action - the clause names no action' 'empty verb' --action '' --object 'task x PR' --when 'checks green'
  compile_refusal 'object - the clause names no thing to act on' 'no object' --action merge --when 'checks green'
  compile_refusal 'object - the clause names no thing to act on' 'blank object' --action merge --object '   ' --when 'checks green'
  compile_refusal 'when - the clause states no precondition' 'no when' --action merge --object 'task x PR'
  compile_refusal 'when - the clause states no precondition' 'blank when' --action merge --object 'task x PR' --when ' '
  compile_refusal 'stop - --stop was given with no text' 'blank explicit stop' --action merge --object 'task x PR' --when 'checks green' --stop ' '
  pass "structural refusals name their missing part"
}

test_omitted_stop_confirms_as_no_stop() {
  local home row out
  home=$(make_home omitted-stop)
  contract "$home" propose --action merge --object 'task x PR' --when 'checks green' >/dev/null || fail "proposal without stop failed"
  row=$(contract "$home" clauses --proposal)
  [ "$(printf '%s' "$row" | cut -f5)" = - ] || fail "an omitted stop was not serialized as the no-stop marker"
  out=$(contract "$home" confirm 2>&1) || fail "confirmation without stop failed: $out"
  assert_contains "$out" '1 mandate clause(s) recorded, 0 refused' "confirmation did not accept the omitted stop"
  pass "an omitted stop uses the no-stop marker and confirms"
}

# The never-set is a coarse best-effort flag: a listed concept, exact or plainly
# inflected, across punctuation boundaries, flags the clause without refusing it;
# an unrelated name never matches; joined compounds are a documented miss.
test_never_set_flags_without_refusing_and_never_over_matches() {
  compile_flagged credential 'credentials' --action answer --object 'the credential prompt on task q' --when asked
  compile_flagged legal 'legal' --action answer --object 'the legal acceptance on task q' --when asked
  compile_flagged 'attended prompt' 'attended prompt' --action answer --object 'the attended prompt on task q' --when asked
  compile_flagged credential 'credential compound' --action answer --object 'task q credential-prompt' --when 'prompt starts'
  compile_flagged credential 'credential plural with punctuation' --action answer --object 'task q credentials/keys' --when 'prompt starts'
  compile_flagged 'attended prompt' 'attended plural compound' --action answer --object 'task q attended-prompts' --when 'it appears'
  compile_flagged payment 'payment plural' --action answer --object 'task q payments' --when 'prompt starts'
  compile_flagged 'one time code' 'one-time code' --action answer --object 'task q one-time-code prompt' --when 'it appears'
  compile_flagged 'one time code' 'one-time codes plural' --action answer --object 'task q one-time-codes prompt' --when 'it appears'
  compile_flagged 'api key' 'api keys plural' --action answer --object 'task q api-keys prompt' --when 'it appears'
  compile_flagged login 'in the precondition' --action merge --object 'task x PR' --when 'after the Login/2FA prompt clears'
  compile_flagged password 'in the stop' --action merge --object 'task x PR' --when 'checks green' --stop 'if a PASSWORD is asked'
  compile_unflagged 'ping-service is not pin' --action merge --object 'task ping-service PR' --when 'checks green'
  compile_unflagged 'tokenize-worker is not token' --action rerun --object 'task tokenize-worker' --when 'after clause 1'
  compile_unflagged 'pinned is not pin' --action merge --object 'task pinned-deps PR' --when 'checks green'
  compile_unflagged 'legally is not legal' --action rerun --object 'task legally-named' --when 'after clause 1'
  compile_unflagged 'joined compound is a documented miss' --action answer --object 'task q oneTimeCode prompt' --when 'it appears'
  pass "the never-set flags listed concepts and their inflections without refusing, and never fires on unrelated names"
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

test_clause_fields_round_trip_reversible_whitespace() {
  local home rows out object when stop expected
  home=$(make_home clause-whitespace)
  object='task  x PR'
  when=$'checks\tgreen\nthen done'
  stop=$'stop\\literal\n'
  contract "$home" propose --action merge --object "$object" --when "$when" --stop "$stop" >/dev/null \
    || fail "proposal with whitespace-bearing clause fields failed"
  rows=$(contract "$home" clauses --proposal)
  expected=$(printf '1\tmerge\ttask  x PR\tchecks\\tgreen\\nthen done\tstop\\\\literal\\n')
  [ "$rows" = "$expected" ] || fail "clause TSV did not reversibly preserve whitespace: $rows"
  out=$(contract "$home" readback --proposal; printf x)
  out=${out%x}
  assert_contains "$out" $'1. merge task  x PR when checks\tgreen\nthen done stop stop\\literal' \
    "read-back did not render clause fields verbatim"
  pass "clause fields preserve repeated spaces, tabs, newlines, and backslashes"
}

test_clause_ids_are_input_ordinals_across_accepted_and_refused() {
  local home out rc
  home=$(make_home ordinals)
  set +e
  out=$(contract "$home" propose \
    --action merge --object 'task a PR' --when 'checks green' \
    --action merge --object regardless \
    --action prerelease --object 'repo r' --when 'after clause 1' \
    --action install --object 'the prerelease on mini' --when 'after clause 3' \
    --action rerun --object 'task t' --when 'after clause 4' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a mixed proposal should exit 3 (rc=$rc): $out"
  assert_contains "$out" '1. merge task a PR when checks green' 'clause 1 accepted'
  assert_contains "$out" '2. "action=merge object=regardless when=(none)" - refused: missing when - the clause states no precondition' 'clause 2 refused for its missing precondition'
  assert_contains "$out" '3. prerelease repo r when after clause 1' 'clause 3 keeps its input ordinal'
  assert_contains "$out" '4. install the prerelease on mini when after clause 3' 'clause 4 keeps its input ordinal'
  assert_contains "$out" '5. rerun task t when after clause 4' 'clause 5 keeps its input ordinal'
  [ "$(contract "$home" propose --action merge --object 'task a PR' --when 'checks green' --action merge --object regardless --action rerun --object 'task t' --when 'after clause 1' 2>/dev/null | grep -c '^    [0-9]')" -eq 3 ] \
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
  assert_contains "$out" 'forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text; no recorded clause is authority by itself' 'the hard authority invariant'
  assert_contains "$out" 'Say go to confirm' 'confirmation prompt'
  # The verbatim words survive the record byte for byte, trailing newline included.
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$words"; printf x)" ] || fail "the proposal did not keep the words verbatim"
  pass "the read-back renders the words verbatim beside the accepted and refused lists"
}

test_words_preserve_final_newline_shape() {
  local home without with trailing out
  home=$(make_home words-newline-shape)
  without="$home/without.txt"
  with="$home/with.txt"
  trailing="$home/trailing.txt"
  printf 'merge when green' > "$without"
  printf 'merge when green\n' > "$with"
  printf 'first line\n\n' > "$trailing"
  contract "$home" propose --words-file "$without" >/dev/null || fail "proposal without a final newline failed"
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$without"; printf x)" ] \
    || fail "words without a final newline did not round-trip byte-exact"
  contract "$home" propose --words-file "$with" >/dev/null || fail "proposal with a final newline failed"
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$with"; printf x)" ] \
    || fail "words with a final newline did not round-trip byte-exact"
  out=$(contract "$home" propose --words-file "$trailing"; printf x) || fail "proposal with trailing blank lines failed"
  out=${out%x}
  assert_contains "$out" $'    first line\n    \n  accepted clauses:' \
    "read-back dropped a trailing blank line from the captain's words"
  pass "words preserve their final newline shape in storage and read-back"
}

test_propose_confirm_writes_the_record_and_announces_hold_for_return() {
  local home out record proposed_epoch
  home=$(make_home lifecycle)
  contract "$home" propose --words 'merge it when green' --action merge --object 'task a PR' --when 'checks green' \
    --action merge --object everything >/dev/null 2>&1 || true
  [ -f "$home/state/.afk-contract.proposed" ] || fail "propose did not write the proposal"
  proposed_epoch=$(contract "$home" field entered_epoch --proposal)
  [ ! -f "$home/state/.afk-contract" ] || fail "a proposal alone must not count as the posture"
  sleep 1
  out=$(contract "$home" confirm 2>&1) || fail "confirm failed: $out"
  record="$home/state/.afk-contract"
  [ -f "$record" ] || fail "confirm did not write the record"
  [ ! -f "$home/state/.afk-contract.proposed" ] || fail "confirm left the proposal behind"
  [ -f "$record" ] || fail "the confirmed posture record is absent"
  assert_contains "$out" 'Away posture confirmed at ' 'announcement opens with the confirmation time'
  assert_contains "$out" 'hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'announcement says hold-for-return only, aloud'
  assert_contains "$out" '1 mandate clause(s) recorded, 1 refused, and 0 flagged as naming a never-set concept; recorded clauses are held for the return brief and are not executed by this release; forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text, and no recorded clause is authority by itself.' 'announcement counts clauses and states the hard authority invariant'
  assert_contains "$out" 'Expected return: not given. Spend cap: 4 concurrent workers.' 'announcement carries the defaults'
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

test_failed_final_replacement_rolls_back_the_superseded_archive() {
  local home before out rc
  home=$(make_home replace-final-move-failure)
  contract "$home" propose --words 'original posture' >/dev/null || fail "first propose failed"
  contract "$home" confirm >/dev/null || fail "first confirm failed"
  before=$(cat "$home/state/.afk-contract")
  contract "$home" propose --words 'replacement posture' >/dev/null || fail "replacement propose failed"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  *.afk-contract.confirming.*:*/.afk-contract) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$home/fakebin/mv"
  set +e
  out=$(PATH="$home/fakebin:$PATH" contract "$home" confirm 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "replacement succeeded after its final publication failed"
  [ "$(cat "$home/state/.afk-contract")" = "$before" ] || fail "failed final publication changed the standing posture"
  [ -f "$home/state/.afk-contract.proposed" ] || fail "failed final publication discarded the pending proposal"
  [ -z "$(find "$home/state/afk-contracts" -name '*-superseded-*.afk-contract' -print -quit)" ] \
    || fail "failed final publication left a duplicate superseded mandate"
  pass "a failed final replacement publication rolls back its superseded archive"
}

test_validation_rejects_incomplete_clause_rows() {
  local home record out rc
  home=$(make_home malformed-clause-row)
  contract "$home" propose --action merge --object 'task a PR' --when 'checks green' >/dev/null || fail "proposal failed"
  contract "$home" confirm >/dev/null || fail "confirmation failed"
  record="$home/state/.afk-contract"
  grep -v '^    object: ' "$record" > "$home/truncated"
  mv "$home/truncated" "$record"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "validation accepted a clause row without its object field"
  assert_contains "$out" 'malformed clauses row 1: missing or invalid object' "validation did not name the malformed clause row"
  set +e
  out=$(contract "$home" archive 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "archive accepted a clause row without its object field"
  [ -f "$record" ] || fail "archive moved the malformed clause record"
  pass "validation and archive refuse incomplete clause rows by name"
}

test_validation_rejects_blank_decoded_clause_fields() {
  local field home record out rc
  for field in object when; do
    home=$(make_home "blank-$field-row")
    contract "$home" propose --action merge --object 'task a PR' --when 'checks green' >/dev/null || fail "$field proposal failed"
    contract "$home" confirm >/dev/null || fail "$field confirmation failed"
    record="$home/state/.afk-contract"
    sed "s/^    $field: e:.*/    $field: e:/" "$record" > "$home/damaged"
    mv "$home/damaged" "$record"
    set +e
    out=$(contract "$home" validate 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "validation accepted a blank decoded $field"
    assert_contains "$out" "malformed clauses row 1: missing or invalid $field" "validation did not name the blank $field"
    set +e
    contract "$home" archive >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "archive accepted a blank decoded $field"
    [ -f "$record" ] || fail "archive moved the record with a blank $field"
  done
  pass "validation and archive refuse blank decoded clause fields"
}

test_validation_rejects_blank_stop_and_refused_text() {
  local kind home record out rc
  for kind in stop refused-text; do
    home=$(make_home "blank-$kind")
    if [ "$kind" = stop ]; then
      contract "$home" propose --action merge --object 'task a PR' --when 'checks green' --stop 'captain returns' >/dev/null || fail "stop proposal failed"
    else
      contract "$home" propose --action merge --object 'task a PR' >/dev/null 2>&1 || true
    fi
    contract "$home" confirm >/dev/null || fail "$kind confirmation failed"
    record="$home/state/.afk-contract"
    if [ "$kind" = stop ]; then
      sed 's/^    stop: e:.*/    stop: e:/' "$record" > "$home/damaged"
    else
      sed 's/^    text: e:.*/    text: e:/' "$record" > "$home/damaged"
    fi
    mv "$home/damaged" "$record"
    set +e
    out=$(contract "$home" validate 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "validation accepted blank $kind data"
    if [ "$kind" = stop ]; then
      assert_contains "$out" 'malformed clauses row 1: missing or invalid stop' "validation did not name the blank stop"
    else
      assert_contains "$out" 'malformed refused row 1: missing or invalid text' "validation did not name the blank refused text"
    fi
    set +e
    contract "$home" archive >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "archive accepted blank $kind data"
    [ -f "$record" ] || fail "archive moved the record with blank $kind data"
  done
  pass "validation and archive refuse blank stop and refused text"
}

test_validation_rejects_damaged_words_blocks() {
  local mode home record out rc
  for mode in unindented empty; do
    home=$(make_home "damaged-words-$mode")
    contract "$home" propose --words 'captain words' >/dev/null || fail "$mode words proposal failed"
    contract "$home" confirm >/dev/null || fail "$mode words confirmation failed"
    record="$home/state/.afk-contract"
    if [ "$mode" = unindented ]; then
      sed 's/^  captain words$/captain words/' "$record" > "$home/damaged"
    else
      grep -v '^  captain words$' "$record" > "$home/damaged"
    fi
    mv "$home/damaged" "$record"
    set +e
    out=$(contract "$home" validate 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "validation accepted the $mode words block"
    assert_contains "$out" 'invalid words block:' "validation did not name the damaged words block"
    set +e
    contract "$home" archive >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "archive accepted the $mode words block"
    [ -f "$record" ] || fail "archive moved the record with $mode words"
  done
  pass "validation and archive refuse damaged words blocks"
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
  [ ! -f "$home/state/.afk-contract" ] || fail "the record still stands after archive"
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
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "validate with no record should fail"
  printf 'version: 9\nentered_epoch: 1\nclauses:\nrefused:\n' > "$home/state/.afk-contract"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a foreign record version must be refused"
  assert_contains "$out" "carries version '9', expected 1" 'version refusal wording'
  pass "malformed inputs and foreign record versions are refused rather than guessed"
}

test_merge_grants_round_trip_and_read_back() {
  local home out
  home=$(make_home grants-roundtrip)
  out=$(contract "$home" propose --grant task-x1 --grant task-y2 --words 'merge those two when green') || fail "grant proposal failed: $out"
  assert_contains "$out" 'merge when green (task ids): task-x1, task-y2' 'read-back did not list the granted ids'
  [ "$(contract "$home" grants --proposal)" = "$(printf 'task-x1\ntask-y2')" ] \
    || fail "proposal grants subcommand: $(contract "$home" grants --proposal)"
  contract "$home" confirm >/dev/null || fail "grant confirm failed"
  [ "$(contract "$home" grants)" = "$(printf 'task-x1\ntask-y2')" ] \
    || fail "confirmed grants subcommand: $(contract "$home" grants)"
  grep -q '^merge_grants:$' "$home/state/.afk-contract" || fail "confirmed record lacks merge_grants list"
  grep -q '  - task-x1' "$home/state/.afk-contract" || fail "confirmed record dropped task-x1"
  pass "merge grants round-trip through propose, confirm, read-back, and grants"
}

test_merge_grants_empty_form_and_usage_errors() {
  local home out rc
  home=$(make_home grants-empty)
  contract "$home" propose >/dev/null || fail "empty grant proposal failed"
  grep -qxF 'merge_grants: -' "$home/state/.afk-contract.proposed" \
    || fail "empty grants did not write merge_grants: -"
  [ -z "$(contract "$home" grants --proposal)" ] || fail "empty grants subcommand was not empty"
  set +e
  out=$(contract "$home" propose --grant 'bad id' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid grant id should be usage error (rc=$rc): $out"
  set +e
  out=$(contract "$home" propose --grant task-x1 --grant task-x1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "duplicate grant id should be usage error (rc=$rc): $out"
  pass "empty grants write the scalar form, and invalid or duplicate ids are usage errors"
}

test_legacy_record_without_merge_grants_reads_empty() {
  local home record
  home=$(make_home grants-legacy)
  contract "$home" propose >/dev/null || fail "legacy proposal failed"
  contract "$home" confirm >/dev/null || fail "legacy confirm failed"
  record="$home/state/.afk-contract"
  awk '!/^merge_grants/' "$record" > "$home/legacy" || fail "could not strip merge_grants"
  mv "$home/legacy" "$record"
  contract "$home" validate >/dev/null || fail "a pre-field v1 record must still validate"
  [ -z "$(contract "$home" grants)" ] || fail "a missing merge_grants field must read as an empty list"
  pass "a pre-field v1 record reads as empty grants rather than skipping the field"
}

test_malformed_merge_grants_refuse_validation() {
  local home record out rc
  home=$(make_home grants-malformed-scalar)
  contract "$home" propose >/dev/null || fail "malformed scalar proposal failed"
  contract "$home" confirm >/dev/null || fail "malformed scalar confirm failed"
  record="$home/state/.afk-contract"
  awk '{ print; if ($0 == "merge_grants: -") print "  - task-x1" }' "$record" > "$home/malformed"
  mv "$home/malformed" "$record"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "indented data attached to scalar merge_grants validated"
  assert_contains "$out" 'invalid merge_grants field' 'attached scalar data refusal wording'

  home=$(make_home grants-malformed-duplicate)
  contract "$home" propose --grant task-x1 >/dev/null || fail "duplicate field proposal failed"
  contract "$home" confirm >/dev/null || fail "duplicate field confirm failed"
  record="$home/state/.afk-contract"
  printf 'merge_grants: -\n' >> "$record"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate merge_grants fields validated"
  assert_contains "$out" 'invalid merge_grants field' 'duplicate field refusal wording'
  pass "malformed and duplicate merge-grant fields fail record validation"
}

test_archive_drops_live_grants() {
  local home rc
  home=$(make_home grants-archive)
  contract "$home" propose --grant task-x1 >/dev/null || fail "archive grant proposal failed"
  contract "$home" confirm >/dev/null || fail "archive grant confirm failed"
  contract "$home" archive >/dev/null || fail "archive failed"
  [ ! -f "$home/state/.afk-contract" ] || fail "archive left the live record"
  set +e
  contract "$home" grants >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "grants on the live path succeeded after archive"
  pass "archive removes live grants so archived copies are not consulted"
}

test_fields_refuse_each_missing_part_by_name
test_omitted_stop_confirms_as_no_stop
test_never_set_flags_without_refusing_and_never_over_matches
test_fields_record_the_captain_wording_verbatim
test_clause_fields_round_trip_reversible_whitespace
test_clause_ids_are_input_ordinals_across_accepted_and_refused
test_readback_renders_words_verbatim_and_both_lists
test_words_preserve_final_newline_shape
test_propose_confirm_writes_the_record_and_announces_hold_for_return
test_confirm_requires_readback_and_refresh_is_a_no_op
test_confirming_a_new_proposal_archives_the_standing_record
test_failed_replacement_keeps_the_standing_record
test_failed_final_replacement_rolls_back_the_superseded_archive
test_validation_rejects_incomplete_clause_rows
test_validation_rejects_blank_decoded_clause_fields
test_validation_rejects_blank_stop_and_refused_text
test_validation_rejects_damaged_words_blocks
test_archive_moves_the_record_aside_and_is_idempotent
test_inputs_are_validated
test_merge_grants_round_trip_and_read_back
test_merge_grants_empty_form_and_usage_errors
test_legacy_record_without_merge_grants_reads_empty
test_malformed_merge_grants_refuse_validation
test_archive_drops_live_grants

