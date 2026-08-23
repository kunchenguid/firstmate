#!/usr/bin/env bash
# Behavior tests for bin/fm-inbox.sh's capture path.
#
# The bar every test here holds to is the one the capture surface exists for:
# a `note` that reports success must have left a record `list` can read back,
# and a `note` that cannot write must say so and exit non-zero. Asserting only
# the exit status would have passed against the GNU-only `sed -i` that lost
# every note on macOS, because that failure was already non-zero - it was
# unreadable and it left a half-written staging file behind, which is a
# different defect from a wrong exit code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)

# A fresh operational home. Each test gets its own so the wake queue, the inbox
# and the ack directory never carry over.
new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" || return 1
  printf '%s\n' "$home"
}

inbox_run() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" "$@"
}

# The id fm-inbox.sh reported on its own stdout, from the `queued <id>` line.
queued_id() {  # <output>
  printf '%s\n' "$1" | awk '$1 == "queued" { print $2; exit }'
}

test_note_writes_a_record_list_reads_back() {
  local home out id record listing
  home=$(new_home note-roundtrip) || fail "could not build a test home"

  out=$(inbox_run "$home" note 'ship the mooring lines' 2>&1) \
    || fail "note failed on a writable home"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "queued " "note did not report a queued id"

  id=$(queued_id "$out")
  [ -n "$id" ] || fail "note reported no id on its queued line"

  # The record exists under the id the command reported, not some other name.
  record="$home/state/inbox/$id.note"
  assert_present "$record" "note reported id $id but wrote no $id.note record"
  assert_grep "ship the mooring lines" "$record" "the record lost the note body"

  # `list` is the captain's read-back path: the note is only captured if it
  # shows up here.
  listing=$(inbox_run "$home" list 2>&1) || fail "list failed after a successful note"
  assert_contains "$listing" "$id" "list did not show the queued note $id"
  assert_contains "$listing" "ship the mooring lines" "list did not show the note body"
  assert_not_contains "$listing" "(inbox empty)" "list reported an empty inbox after a queued note"

  pass "fm-inbox.sh: note writes a record that list reads back"
}

# The regression that mattered: the id was written as a PENDING placeholder and
# patched afterwards with GNU-only `sed -i`, which is a no-op-then-error on
# BSD/macOS sed. Pin the substituted value itself, not just the exit status.
test_record_carries_the_reported_id_not_a_placeholder() {
  local home out id record id_line
  home=$(new_home note-id-substitution) || fail "could not build a test home"

  out=$(inbox_run "$home" note 'the id must be real' 2>&1) \
    || fail "note failed on a writable home"$'\n'"--- output ---"$'\n'"$out"
  id=$(queued_id "$out")
  [ -n "$id" ] || fail "note reported no id on its queued line"

  record="$home/state/inbox/$id.note"
  assert_present "$record" "no record was written for id $id"

  id_line=$(awk -F= '$1 == "id" { print $2; exit }' "$record")
  [ "$id_line" = "$id" ] \
    || fail "record id field is '$id_line' but the command reported '$id'"
  assert_no_grep "PENDING" "$record" "the record still carries an unsubstituted id placeholder"

  # The wake payload has to name the same id, or firstmate is woken for a note
  # it cannot find.
  assert_present "$home/state/.wake-queue" "note appended no wake"
  assert_grep "inbox:$id" "$home/state/.wake-queue" "the wake does not name the queued note id"

  pass "fm-inbox.sh: the record carries the reported id, not a placeholder"
}

test_multiline_body_survives_the_round_trip() {
  local home out id listing
  home=$(new_home note-multiline) || fail "could not build a test home"

  out=$(printf 'premiere ligne & / \\ %%\nseconde "ligne"\n' \
    | inbox_run "$home" note - 2>&1) \
    || fail "note - failed on a writable home"$'\n'"--- output ---"$'\n'"$out"
  id=$(queued_id "$out")
  [ -n "$id" ] || fail "note - reported no id"

  listing=$(inbox_run "$home" list 2>&1) || fail "list failed after a multiline note"
  assert_contains "$listing" 'premiere ligne & / \ %' "list lost the first body line"
  assert_contains "$listing" 'seconde "ligne"' "list lost the second body line"

  pass "fm-inbox.sh: a multiline body with shell metacharacters survives the round trip"
}

# A capture surface that loses what it was handed is worse than one that
# refuses: an unwritable inbox must be loud, non-zero, and leave nothing behind.
test_unwritable_inbox_fails_visibly_and_publishes_nothing() {
  local home out code listing staging
  home=$(new_home note-unwritable) || fail "could not build a test home"
  mkdir -p "$home/state/inbox" || fail "could not create the inbox directory"
  chmod 0500 "$home/state/inbox" || fail "could not make the inbox read-only"

  out=$(inbox_run "$home" note 'must not vanish' 2>&1)
  code=$?
  chmod 0700 "$home/state/inbox" || fail "could not restore inbox permissions"

  [ "$code" -ne 0 ] || fail "note exited 0 against an unwritable inbox"$'\n'"--- output ---"$'\n'"$out"
  # Readable, and attributed to this command rather than to whatever tool broke.
  assert_contains "$out" "fm-inbox:" "the failure carried no fm-inbox diagnostic"
  assert_contains "$out" "nothing was queued" "the failure did not say the note was not queued"

  listing=$(inbox_run "$home" list 2>&1) || fail "list failed after a refused note"
  assert_contains "$listing" "(inbox empty)" "a refused note left a record behind"

  # Nothing half-published: no staging file survives the failure either.
  staging=$(find "$home/state/inbox" -maxdepth 1 -name '.staging-*' | wc -l | tr -d ' ')
  [ "$staging" = 0 ] || fail "a refused note left $staging staging file(s) in the inbox"

  # A failed capture must not have woken firstmate for a note that does not exist.
  assert_absent "$home/state/.wake-queue" "a refused note still appended a wake"

  pass "fm-inbox.sh: an unwritable inbox fails visibly and publishes nothing"
}

# The same contract one step later, where the staging file DOES exist when the
# step fails. This is the shape the GNU-only `sed -i` produced on macOS: a
# staging file written, the publish never reached, and litter left in the inbox.
test_a_failed_publish_leaves_no_staging_file() {
  local home fakebin out code listing staging
  home=$(new_home note-publish-fails) || fail "could not build a test home"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
echo "mv: simulated publish failure" >&2
exit 1
EOF
  chmod +x "$fakebin/mv" || fail "could not install the failing mv shim"

  out=$(PATH="$fakebin:$PATH" inbox_run "$home" note 'must not be half published' 2>&1)
  code=$?

  [ "$code" -ne 0 ] || fail "note exited 0 when publishing failed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "fm-inbox:" "the publish failure carried no fm-inbox diagnostic"
  assert_contains "$out" "nothing was queued" "the publish failure did not say the note was not queued"

  # The staging file is the whole point of this case: it existed, and the
  # failure path has to remove it rather than leave a stray record behind.
  staging=$(find "$home/state/inbox" -maxdepth 1 -name '.staging-*' | wc -l | tr -d ' ')
  [ "$staging" = 0 ] || fail "a failed publish left $staging staging file(s) in the inbox"

  listing=$(inbox_run "$home" list 2>&1) || fail "list failed after a failed publish"
  assert_contains "$listing" "(inbox empty)" "a failed publish left a readable record behind"
  assert_absent "$home/state/.wake-queue" "a failed publish still appended a wake"

  pass "fm-inbox.sh: a failed publish leaves no staging file and no wake"
}

# Cleanup is secondary to reporting the capture failure. Even if both publish
# and staging cleanup fail, the captain still needs the script-owned explanation
# that the note was not queued.
test_a_failed_publish_with_failed_cleanup_still_explains_the_loss() {
  local home fakebin out code
  home=$(new_home note-publish-and-cleanup-fail) || fail "could not build a test home"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
echo "mv: simulated publish failure" >&2
exit 1
EOF
  cat > "$fakebin/rm" <<'EOF'
#!/usr/bin/env bash
echo "rm: simulated cleanup failure" >&2
exit 1
EOF
  chmod +x "$fakebin/mv" "$fakebin/rm" || fail "could not install failure shims"

  out=$(PATH="$fakebin:$PATH" inbox_run "$home" note 'must report the loss' 2>&1)
  code=$?

  [ "$code" -ne 0 ] || fail "note exited 0 when publish and cleanup failed"
  assert_contains "$out" "fm-inbox:" \
    "cleanup failure suppressed the fm-inbox diagnostic"
  assert_contains "$out" "nothing was queued" \
    "cleanup failure suppressed the explanation that nothing was queued"
  assert_absent "$home/state/.wake-queue" \
    "a failed publish with failed cleanup still appended a wake"

  pass "fm-inbox.sh: cleanup failure cannot suppress the capture failure diagnostic"
}

test_drain_ack_moves_the_note_out_of_the_inbox() {
  local home out id listing
  home=$(new_home note-drain-ack) || fail "could not build a test home"

  out=$(inbox_run "$home" note 'acknowledge me' 2>&1) || fail "note failed"
  id=$(queued_id "$out")
  [ -n "$id" ] || fail "note reported no id"

  out=$(inbox_run "$home" drain --ack "$id" 2>&1) || fail "drain --ack failed"
  assert_contains "$out" "acked $id" "drain --ack did not report the acked id"

  assert_present "$home/state/inbox/handled/$id.note" "the acked note was not moved to handled/"
  assert_absent "$home/state/inbox/$id.note" "the acked note is still pending"
  listing=$(inbox_run "$home" list 2>&1) || fail "list failed after an ack"
  assert_contains "$listing" "(inbox empty)" "list still shows an acked note"

  pass "fm-inbox.sh: drain --ack moves the note out of the pending inbox"
}

test_empty_note_is_refused() {
  local out code
  local home
  home=$(new_home note-empty) || fail "could not build a test home"

  out=$(inbox_run "$home" note '   ' 2>&1)
  code=$?
  [ "$code" -ne 0 ] || fail "an all-whitespace note was accepted"
  assert_contains "$out" "refusing to queue an empty note" "the refusal was not explained"
  assert_absent "$home/state/.wake-queue" "a refused empty note still appended a wake"

  pass "fm-inbox.sh: an empty note is refused without a wake"
}

test_note_writes_a_record_list_reads_back
test_record_carries_the_reported_id_not_a_placeholder
test_multiline_body_survives_the_round_trip
test_unwritable_inbox_fails_visibly_and_publishes_nothing
test_a_failed_publish_leaves_no_staging_file
test_a_failed_publish_with_failed_cleanup_still_explains_the_loss
test_drain_ack_moves_the_note_out_of_the_inbox
test_empty_note_is_refused
