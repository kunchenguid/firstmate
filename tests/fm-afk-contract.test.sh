#!/usr/bin/env bash
# tests/fm-afk-contract.test.sh - the away-posture record owner
# (bin/fm-afk-contract.sh): the captain's away words recorded verbatim as the
# whole mandate, the read-back rendering, the entry announcement (hold-for-
# return only), the propose/confirm lifecycle, the refresh and replace rules,
# the archive at return, the version 2 record with version 1 still readable,
# the retired clause and merge-grant apparatus refusing by name, and the read
# subcommands every consumer uses instead of parsing the file.
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

# A confirmed record in the retired version 1 shape, exactly as the clause
# model wrote it: scalar fields, a merge-grant list, the words block, then the
# clauses and refused sections. A live away window may still hold one of these
# when this version lands, so it must validate, read, and archive unchanged.
write_v1_record() {  # <home> <words-line>
  local home=$1 words=$2
  cat > "$home/state/.afk-contract" <<EOF
version: 1
entered: 2026-09-20T01:00:00Z
entered_epoch: 1789600000
expected_return: 2026-09-20T09:00:00Z
reach_channels: none
reach_announced: No phone channel is configured; anything that needs you waits for your return.
spend_max_concurrent_workers: 3
merge_grants:
  - task-x1
confirmed: 2026-09-20T01:00:05Z
confirmed_epoch: 1789600005
words: |-
  $words
clauses:
  - id: 1
    action: merge
    object: e:task x1 PR
    when: e:checks green
    stop: -
    flag: -
refused:
  - id: 2
    text: e:action=merge object=everything when=(none)
    missing: when - the clause states no precondition
EOF
}

# No parser reads the words: any text the captain gives is recorded verbatim,
# including wording a grammar would have judged, and the read-back mirrors it.
test_readback_renders_words_verbatim_with_the_record_scalars() {
  local home out words
  home=$(make_home readback)
  words="$home/words.txt"
  printf 'drive the windows fix to green and merge it,\n  cut a prerelease; then re-run "nm-ci-windows"\n\tif the install deadlocks abort the competing pipeline\nmerge task y even if nm-ci-windows looks red enough, honestly\n' > "$words"
  out=$(contract "$home" propose --words-file "$words" --expected-return 2026-09-08T08:00Z --spend 3 2>&1) \
    || fail "proposal with words failed: $out"
  assert_contains "$out" 'Away posture read-back (proposed, not yet confirmed):' 'read-back title'
  assert_contains "$out" 'expected return: 2026-09-08T08:00Z' 'expected return rendered'
  assert_contains "$out" 'spend cap: 3 concurrent workers' 'spend cap rendered'
  assert_contains "$out" 'reach: hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'reach rendered'
  assert_contains "$out" '  your words (verbatim):' 'words header'
  assert_contains "$out" '    drive the windows fix to green and merge it,' 'words line 1'
  assert_contains "$out" '      cut a prerelease; then re-run "nm-ci-windows"' 'words line 2 keeps its own indentation and quotes'
  assert_contains "$out" "$(printf '    \tif the install deadlocks')" 'words line 3 keeps its tab'
  assert_contains "$out" '    merge task y even if nm-ci-windows looks red enough, honestly' 'wording is recorded, never judged'
  assert_contains "$out" 'Say go to confirm' 'confirmation prompt'
  assert_not_contains "$out" 'clause' 'the read-back must carry no clause apparatus'
  assert_not_contains "$out" 'task ids' 'the read-back must carry no merge-grant list'
  # The verbatim words survive the record byte for byte, trailing newline included.
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$words"; printf x)" ] || fail "the proposal did not keep the words verbatim"
  pass "the read-back renders the words verbatim beside the expected return, spend cap, and reach line"
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
  assert_contains "$out" $'    first line\n    \nSay go to confirm' \
    "read-back dropped a trailing blank line from the captain's words"
  [ "$(contract "$home" words --proposal; printf x)" = "$(cat "$trailing"; printf x)" ] \
    || fail "trailing blank lines did not round-trip byte-exact"
  pass "words preserve their final newline shape in storage and read-back"
}

test_propose_confirm_writes_a_v2_record_and_announces_hold_for_return() {
  local home out record proposed_epoch
  home=$(make_home lifecycle)
  contract "$home" propose --words 'merge it when green' >/dev/null || fail "propose failed"
  [ -f "$home/state/.afk-contract.proposed" ] || fail "propose did not write the proposal"
  proposed_epoch=$(contract "$home" field entered_epoch --proposal)
  [ ! -f "$home/state/.afk-contract" ] || fail "a proposal alone must not count as the posture"
  sleep 1
  out=$(contract "$home" confirm 2>&1) || fail "confirm failed: $out"
  record="$home/state/.afk-contract"
  [ -f "$record" ] || fail "confirm did not write the record"
  [ ! -f "$home/state/.afk-contract.proposed" ] || fail "confirm left the proposal behind"
  assert_contains "$out" 'Away posture confirmed at ' 'announcement opens with the confirmation time'
  assert_contains "$out" 'hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'announcement says hold-for-return only, aloud'
  assert_contains "$out" 'Your away instructions are recorded verbatim; the away session will carry them out where it can, and anything it is unsure of, or that needs you, waits for your return.' 'announcement says the words will be carried out'
  assert_contains "$out" 'Destructive, irreversible, and security-sensitive actions are never pre-authorizable, whatever the words say.' 'announcement states the never-set'
  assert_contains "$out" 'Expected return: not given. Spend cap: 4 concurrent workers.' 'announcement carries the defaults'
  assert_not_contains "$out" 'not executed' 'the announcement must not call the words inert'
  assert_not_contains "$out" 'clause' 'the announcement must carry no clause apparatus'
  [ "$(contract "$home" field version)" = 2 ] || fail "record version is not 2: $(contract "$home" field version)"
  [ "$(contract "$home" field reach_channels)" = none ] || fail "reach channels are not none"
  case "$(contract "$home" field confirmed_epoch)" in ''|*[!0-9]*) fail "confirmed_epoch is not numeric" ;; esac
  case "$(contract "$home" field entered_epoch)" in ''|*[!0-9]*) fail "entered_epoch is not numeric" ;; esac
  [ "$(contract "$home" field entered_epoch)" -gt "$proposed_epoch" ] || fail "entry time was not stamped at confirmation"
  [ "$(contract "$home" words)" = 'merge it when green' ] || fail "words did not round-trip"
  [ -z "$(contract "$home" field merge_grants)" ] || fail "a version 2 record carries a merge_grants field"
  [ -z "$(contract "$home" field clauses)" ] || fail "a version 2 record carries a clauses section"
  contract "$home" validate || fail "the confirmed record does not validate"
  out=$(contract "$home" readback) || fail "readback of the confirmed record failed"
  assert_contains "$out" 'Away posture (confirmed):' 'confirmed read-back title'
  assert_contains "$out" '    merge it when green' 'confirmed read-back carries the words'
  pass "propose then confirm writes a version 2 record, announces hold-for-return only, and every read subcommand reflects it"
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
  out=$(contract "$home" propose) || fail "plain proposal failed"
  assert_contains "$out" '  your words: (none)' 'a plain proposal reads back no words'
  out=$(contract "$home" confirm 2>&1) || fail "plain confirmation failed: $out"
  assert_contains "$out" 'No away instructions were recorded; the away session acts on standing authority only, and anything that needs you waits for your return.' 'plain announcement'
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
  contract "$home" propose --words 'first words' >/dev/null 2>&1 || fail "first propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "first confirm failed"
  first_epoch=$(contract "$home" field entered_epoch)
  sleep 1
  contract "$home" propose --words 'replacement words' >/dev/null 2>&1 || fail "second propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "second confirm failed"
  archived=$(find "$home/state/afk-contracts" -name "$first_epoch-superseded-*.afk-contract" -print -quit)
  [ -f "$archived" ] || fail "the superseded record was not archived"
  [ "$(contract "$home" words --path "$archived")" = 'first words' ] || fail "the archived record lost the superseded words"
  [ "$(contract "$home" field entered_epoch)" = "$first_epoch" ] || fail "replacement changed the away session start"
  [ "$(contract "$home" words)" = 'replacement words' ] || fail "the new record does not carry the new words"
  pass "a replacement archives the old words and keeps the session start"
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

# A stored line that lost its two-space prefix is damage, not the end of the
# words: reading must refuse rather than hand back the mandate truncated at the
# damage, because a dropped tail can take a hold or condition with it. Version 2
# words run to the end of the record; a version 1 record's words end only at one
# of its legacy sections.
test_a_damaged_words_line_never_truncates_the_mandate() {
  local home record out rc

  home=$(make_home truncated-v2)
  contract "$home" propose --words $'merge A when green\nhold B until I return' >/dev/null \
    || fail "the multi-line v2 proposal failed"
  contract "$home" confirm >/dev/null || fail "the multi-line v2 confirmation failed"
  record="$home/state/.afk-contract"
  [ "$(contract "$home" words)" = $'merge A when green\nhold B until I return' ] \
    || fail "the intact v2 record lost a words line"
  sed 's/^  hold B until I return$/hold B until I return/' "$record" > "$home/damaged"
  mv "$home/damaged" "$record"
  assert_words_read_refuses_the_damage "$home" "$record" 'version 2'

  home=$(make_home truncated-v1)
  write_v1_record "$home" $'merge A when green\n  hold B until I return'
  record="$home/state/.afk-contract"
  contract "$home" validate || fail "the intact multi-line v1 record must still validate"
  [ "$(contract "$home" words)" = $'merge A when green\nhold B until I return' ] \
    || fail "the intact v1 record lost a words line before its clauses section"
  sed 's/^  hold B until I return$/hold B until I return/' "$record" > "$home/damaged"
  mv "$home/damaged" "$record"
  assert_words_read_refuses_the_damage "$home" "$record" 'version 1'

  pass "a words line that lost its record prefix fails validate, read, read-back, and archive instead of truncating the mandate"
}

assert_words_read_refuses_the_damage() {  # <home> <record> <label>
  local home=$1 record=$2 label=$3 out rc
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "validation accepted the truncated $label words block"
  assert_contains "$out" 'invalid words block:' "the $label truncation was not named as a damaged words block"
  set +e
  out=$(contract "$home" words 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "words read the truncated $label block"
  assert_not_contains "$out" 'merge A when green' "the damaged $label record handed back a truncated mandate"
  set +e
  out=$(contract "$home" readback 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "readback rendered the truncated $label mandate"
  assert_not_contains "$out" 'your words (verbatim)' "the damaged $label record still rendered its words"
  set +e
  contract "$home" archive >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "archive accepted the truncated $label words block"
  [ -f "$record" ] || fail "the refused archive still moved the damaged $label record"
}

test_archive_moves_the_record_aside_and_is_idempotent() {
  local home epoch path
  home=$(make_home archive)
  contract "$home" propose --words 'archived words' >/dev/null 2>&1 || fail "propose failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "confirm failed"
  epoch=$(contract "$home" field entered_epoch)
  path=$(contract "$home" archive) || fail "archive failed"
  [ "$path" = "$home/state/afk-contracts/$epoch.afk-contract" ] || fail "archive path is not keyed by entered_epoch: $path"
  [ -f "$path" ] || fail "archived record missing"
  [ ! -f "$home/state/.afk-contract" ] || fail "the record still stands after archive"
  contract "$home" archive || fail "a second archive with no record must succeed as a no-op"
  [ "$(contract "$home" archived "$epoch")" = "$path" ] || fail "archived lookup did not find the record"
  [ "$(contract "$home" words --path "$path")" = 'archived words' ] || fail "reading an archived record by path failed"
  if contract "$home" words >/dev/null 2>&1; then
    fail "words on the live path succeeded after archive"
  fi
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
  out=$(contract "$home" propose --words-file "$home/absent.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a missing words file should be a usage error (rc=$rc): $out"
  [ ! -f "$home/state/.afk-contract.proposed" ] || fail "an invalid proposal was written"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "validate with no record should fail"
  printf 'version: 9\nentered_epoch: 1\nwords: -\n' > "$home/state/.afk-contract"
  set +e
  out=$(contract "$home" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a foreign record version must be refused"
  assert_contains "$out" "carries version '9', expected one of 1, 2" 'version refusal wording'
  pass "malformed inputs and foreign record versions are refused rather than guessed"
}

# The clause fields and the merge-grant list are retired with the words model.
# A stale caller that still passes them is told so by name, and no proposal is
# written from a refused command line.
test_retired_clause_and_grant_inputs_are_usage_errors_by_name() {
  local home flag out rc
  home=$(make_home retired-inputs)
  for flag in --action --object --when --stop --grant; do
    set +e
    out=$(contract "$home" propose --words 'merge it when green' "$flag" merge 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "$flag should be a usage error (rc=$rc): $out"
    assert_contains "$out" "$flag was retired" "$flag refusal did not name the retirement"
    assert_contains "$out" "away words are the whole mandate" "$flag refusal did not point at the words"
    [ ! -f "$home/state/.afk-contract.proposed" ] || fail "$flag wrote a proposal despite the refusal"
  done
  set +e
  out=$(contract "$home" propose --grant=task-x1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--grant= should be a usage error (rc=$rc): $out"
  contract "$home" propose --words 'merge it when green' >/dev/null || fail "a words-only proposal failed"
  contract "$home" confirm >/dev/null || fail "confirm failed"
  for cmd in clauses flags refused grants; do
    set +e
    out=$(contract "$home" "$cmd" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "$cmd should be a usage error (rc=$rc): $out"
    assert_contains "$out" "'$cmd' was retired" "$cmd refusal did not name the retirement"
  done
  pass "retired clause fields, --grant, and the clause and grant subcommands are refused by name"
}

# A live away window may still hold a version 1 record when this version lands.
# It validates, every read subcommand reads it, the read-back shows the words
# (and nothing of the ignored clause and grant sections), and it archives.
test_version_1_record_still_validates_reads_and_archives() {
  local home out path
  home=$(make_home v1-live)
  write_v1_record "$home" 'merge the windows fix when green'
  contract "$home" validate || fail "a version 1 record must still validate"
  [ "$(contract "$home" field version)" = 1 ] || fail "field did not read the version 1 record"
  [ "$(contract "$home" field spend_max_concurrent_workers)" = 3 ] || fail "field did not read the v1 spend cap"
  [ "$(contract "$home" field expected_return)" = 2026-09-20T09:00:00Z ] || fail "field did not read the v1 expected return"
  [ "$(contract "$home" words; printf x)" = 'merge the windows fix when greenx' ] \
    || fail "words did not read the v1 words block bounded by its clauses section: $(contract "$home" words)"
  out=$(contract "$home" readback) || fail "readback of a version 1 record failed"
  assert_contains "$out" 'Away posture (confirmed):' 'v1 read-back title'
  assert_contains "$out" 'spend cap: 3 concurrent workers' 'v1 read-back spend cap'
  assert_contains "$out" 'expected return: 2026-09-20T09:00:00Z' 'v1 read-back expected return'
  assert_contains "$out" '    merge the windows fix when green' 'v1 read-back words'
  assert_not_contains "$out" 'task x1 PR' 'the ignored v1 clauses leaked into the read-back'
  assert_not_contains "$out" 'task-x1' 'the ignored v1 merge grants leaked into the read-back'
  assert_not_contains "$out" 'refused' 'the ignored v1 refused section leaked into the read-back'
  out=$(contract "$home" confirm 2>&1) || fail "refresh of a version 1 record failed: $out"
  assert_contains "$out" 'already recorded at 2026-09-20T01:00:00Z' 'refresh did not keep the v1 record'
  [ "$(contract "$home" field version)" = 1 ] || fail "a refresh rewrote the version 1 record"
  path=$(contract "$home" archive) || fail "archive of a version 1 record failed"
  [ "$path" = "$home/state/afk-contracts/1789600000.afk-contract" ] || fail "v1 archive path is wrong: $path"
  [ "$(contract "$home" words --path "$path")" = 'merge the windows fix when green' ] || fail "the archived v1 record lost its words"
  pass "a version 1 record validates, reads its words and scalars with the clause and grant sections ignored, refreshes untouched, and archives"
}

test_version_1_record_is_replaced_by_a_version_2_record() {
  local home archived
  home=$(make_home v1-replace)
  write_v1_record "$home" 'first words, version 1'
  contract "$home" propose --words 'new words after the upgrade' >/dev/null || fail "replacement propose over a v1 record failed"
  contract "$home" confirm >/dev/null 2>&1 || fail "replacement confirm over a v1 record failed"
  [ "$(contract "$home" field version)" = 2 ] || fail "the replacement did not write a version 2 record"
  [ "$(contract "$home" field entered_epoch)" = 1789600000 ] || fail "the replacement changed the v1 session start"
  [ "$(contract "$home" words)" = 'new words after the upgrade' ] || fail "the replacement lost the new words"
  archived=$(find "$home/state/afk-contracts" -name '1789600000-superseded-*.afk-contract' -print -quit)
  [ -f "$archived" ] || fail "the superseded v1 record was not archived"
  contract "$home" validate --path "$archived" >/dev/null 2>&1 || fail "the archived v1 record no longer validates"
  [ "$(contract "$home" words --path "$archived")" = 'first words, version 1' ] || fail "the archived v1 record lost its words"
  pass "new words over a live version 1 record archive it and write version 2 with the same session start"
}

# The record-mutating commands share one lock with the subsystems that read this
# record's authority and then act on it (bin/fm-pr-merge.sh reads the record
# and merges). While a reader holds that lock, confirm and archive must refuse
# and change nothing, so no publication, replacement, or archive can land inside
# the window between that read and the action it authorized.
test_record_changes_refuse_while_a_reader_holds_the_lock() {
  local home lock holder_pid i rc out before
  home=$(make_home lock-contended)
  contract "$home" propose --words 'standing words' >/dev/null || fail "lock-contended: proposal failed"
  contract "$home" confirm >/dev/null || fail "lock-contended: confirm failed"
  before=$(cat "$home/state/.afk-contract")
  lock="$home/state/.afk-contract.lock"

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$home/holder.ready" "$home/release" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$home/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$home/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: the fixture never took the lock"; }

  set +e
  out=$(FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1 contract "$home" archive 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: archive ran while the record was locked"; }
  assert_contains "$out" 'locked by live process' "lock-contended: the archive refusal did not name the live holder"
  [ -f "$home/state/.afk-contract" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: the refused archive still moved the record"; }

  contract "$home" propose --words 'replacement words' >/dev/null || fail "lock-contended: replacement proposal failed"
  set +e
  out=$(FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1 contract "$home" confirm 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: confirm replaced the record while it was locked"; }
  assert_contains "$out" 'locked by live process' "lock-contended: the confirm refusal did not name the live holder"
  [ "$(cat "$home/state/.afk-contract")" = "$before" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: the refused confirm changed the standing record"; }
  [ "$(contract "$home" words)" = 'standing words' ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "lock-contended: a read subcommand did not see the unchanged words"; }

  : > "$home/release"
  wait "$holder_pid" || fail "lock-contended: the fixture holder did not release cleanly"
  contract "$home" confirm >/dev/null 2>&1 || fail "lock-contended: confirm failed once the lock cleared"
  [ "$(contract "$home" words)" = 'replacement words' ] \
    || fail "lock-contended: the released replacement did not take effect"
  contract "$home" archive >/dev/null || fail "lock-contended: archive failed once the lock cleared"
  pass "confirm and archive refuse while the record is locked, and proceed once it clears"
}

test_readback_renders_words_verbatim_with_the_record_scalars
test_words_preserve_final_newline_shape
test_propose_confirm_writes_a_v2_record_and_announces_hold_for_return
test_confirm_requires_readback_and_refresh_is_a_no_op
test_confirming_a_new_proposal_archives_the_standing_record
test_failed_replacement_keeps_the_standing_record
test_failed_final_replacement_rolls_back_the_superseded_archive
test_validation_rejects_damaged_words_blocks
test_a_damaged_words_line_never_truncates_the_mandate
test_archive_moves_the_record_aside_and_is_idempotent
test_inputs_are_validated
test_retired_clause_and_grant_inputs_are_usage_errors_by_name
test_version_1_record_still_validates_reads_and_archives
test_version_1_record_is_replaced_by_a_version_2_record
test_record_changes_refuse_while_a_reader_holds_the_lock
