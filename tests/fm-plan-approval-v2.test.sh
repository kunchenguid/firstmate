#!/usr/bin/env bash
# Behavior tests for the v=2 plan-approval contract in bin/fm-plan-approval.sh.
#
# WHAT CHANGED, AND WHY THESE CASES EXIST
# v=1 signed a hash of the whole brief. That proved a file had not been edited;
# it never proved anyone had READ it, and it burned the approval on every
# harmless typo fix. v=2 signs the firstmate's own Freigabenotiz - his answers to
# five questions - plus the class he assigned the undertaking and the captain
# wording behind it (AGENTS.md, Roles: "the 5-question Freigabenotiz - content,
# minutes, never byte signatures"). The ed25519 mechanics are unchanged; only
# the thing being signed moved, so these cases pin the new payload, the new
# refusals, and the one byte binding that survived: the acceptance block.
#
# The sibling file tests/fm-plan-approval.test.sh keeps the gate's END-TO-END
# behavior (spawn and promotion in an officer home). This file stays on the tool
# itself, so a refusal can be read without a backend anywhere near it.
#
# Standalone: `bash tests/fm-plan-approval-v2.test.sh`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPROVAL="$ROOT/bin/fm-plan-approval.sh"

if ! command -v openssl >/dev/null 2>&1; then
  echo "skip: openssl is not installed, so ed25519 plan approvals cannot be exercised"
  exit 0
fi
if ! (
  probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-plan-approval-v2-probe.XXXXXX") || exit 1
  trap 'rm -rf "$probe"' EXIT
  printf 'probe\n' > "$probe/msg"
  openssl genpkey -algorithm ed25519 -out "$probe/k" >/dev/null 2>&1 \
    && openssl pkey -in "$probe/k" -pubout -out "$probe/k.pub" >/dev/null 2>&1 \
    && openssl pkeyutl -sign -inkey "$probe/k" -rawin -in "$probe/msg" -out "$probe/s" >/dev/null 2>&1 \
    && openssl pkeyutl -verify -pubin -inkey "$probe/k.pub" -rawin -in "$probe/msg" -sigfile "$probe/s" >/dev/null 2>&1
); then
  echo "skip: this openssl build cannot do ed25519 raw sign/verify"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-plan-approval-v2)

# One primary home plus one officer home bound to it, shaped enough for the real
# home validator. Echoes "<primary>|<officer>".
make_fleet() {  # <name> [<secondmate-id>]
  local name=$1 sid=${2:-sm-alpha} base primary officer
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  officer="$base/officer"
  mkdir -p "$primary/data" "$primary/state" "$primary/config" "$primary/bin" \
    "$officer/data" "$officer/state" "$officer/config" "$officer/bin"
  printf '# firstmate\n' > "$primary/AGENTS.md"
  printf '# firstmate\n' > "$officer/AGENTS.md"
  printf '%s\n' "$sid" > "$officer/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$primary" \
    > "$officer/.fm-secondmate-parent"
  printf -- '- %s - alpha domain (home: %s; scope: alpha work; projects: none; added 2026-08-25)\n' \
    "$sid" "$officer" > "$primary/data/secondmates.md"
  printf '%s\n' "$primary|$officer"
}

# A brief with a real acceptance block, which is the one part v=2 still binds
# byte-exactly. <abnahme> replaces the default acceptance point; <extra> appends
# ordinary prose AFTER the block. The block is closed by the next "## " heading,
# exactly as bin/fm-abnahme.sh reads it, so everything the cases append later
# lands outside the bar the work is measured against.
write_brief() {  # <home> <id> [<abnahme-point>] [<extra-prose>]
  local home=$1 id=$2 abnahme=${3:-'- [A1] the suite is green :: beleg=testlauf'} extra=${4:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Goal\nShip the thing.\n\n'
    printf '## Abnahme (maschinenlesbar)\n%s\n\n' "$abnahme"
    printf '## Definition of done\nDelivery contract: mode=local-only\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$home/data/$id/brief.md"
}

write_notiz() {  # <file> [<omit-question-number>]
  local file=$1 omit=${2:-0}
  : > "$file"
  [ "$omit" = 1 ] || printf 'F1 Praemissen: the officer home is the one bound to this primary.\n' >> "$file"
  [ "$omit" = 2 ] || printf 'F2 Abnahme: the acceptance block below is the whole bar.\n' >> "$file"
  [ "$omit" = 3 ] || printf 'F3 Vision: serves the fleet-order rebuild, no product frame.\n' >> "$file"
  [ "$omit" = 4 ] || printf 'F4 Budget: one afternoon, no spend.\n' >> "$file"
  [ "$omit" = 5 ] || printf 'F5 Betroffene: the officers, nobody outside the fleet.\n' >> "$file"
}

run_primary() {  # <primary> <args...>
  local primary=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_CONFIG_OVERRIDE="$primary/config" \
    "$APPROVAL" "$@" 2>&1
}

run_officer() {  # <officer> <args...>
  local officer=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$officer" "$APPROVAL" "$@" 2>&1
}

record_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1"
}

# --- the new payload --------------------------------------------------------

# The record signs the note, the class, the order, and the captain wording - not
# the brief's bytes - and verify reports every one of them at the point of use.
test_v2_record_signs_the_note_and_verifies() {
  local rec primary officer out record verify
  rec=$(make_fleet payload)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-a1
  write_notiz "$primary/notiz-a1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-a1 \
    --plan-file "$officer/data/ship-v2-a1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-a1.md") \
    || fail "a complete v2 approval should succeed: $out"
  assert_contains "$out" "klasse=routine" "approve did not report the class it signed"
  assert_contains "$out" "order=O-0042" "approve did not report the order it signed"

  record="$officer/state/ship-v2-a1.plan-approval"
  assert_present "$record" "approve wrote no record"
  [ "$(wc -l < "$record" | tr -d ' ')" = 12 ] \
    || fail "a v2 record must be exactly twelve lines, got $(wc -l < "$record")"
  assert_grep "v=2" "$record" "the record does not declare version 2"
  assert_grep "klasse=routine" "$record" "the record does not carry the class"
  assert_grep "order=O-0042" "$record" "the record does not carry the order"
  assert_grep "vorlage=-" "$record" "a routine approval should record no captain wording"
  assert_grep "begruendung=-" "$record" "an untripped approval should record no justification"
  assert_no_grep "plan_sha256=" "$record" "v2 must not carry the old whole-brief hash"
  assert_no_grep "plan_bytes=" "$record" "v2 must not carry the old brief byte count"

  # The note's hash is what got signed, so it must be the hash of the note.
  local notiz_sha expected
  notiz_sha=$(record_field "$record" notiz_sha256)
  if command -v shasum >/dev/null 2>&1; then
    expected=$(shasum -a 256 "$primary/notiz-a1.md" | awk '{print $1}')
  else
    expected=$(sha256sum "$primary/notiz-a1.md" | awk '{print $1}')
  fi
  [ "$notiz_sha" = "$expected" ] || fail "notiz_sha256 does not fingerprint the Freigabenotiz"

  verify=$(run_officer "$officer" verify ship-v2-a1) \
    || fail "verify should accept a fresh v2 approval: $verify"
  assert_contains "$verify" "ship-v2-a1 approved" "verify did not confirm the approval"
  assert_contains "$verify" "klasse=routine" "verify did not surface the class at the point of use"
  assert_contains "$verify" "order=O-0042" "verify did not surface the order at the point of use"
  assert_contains "$verify" "key=parent" \
    "verify should anchor the trusted key in the parent home"
  pass "a v2 approval signs the Freigabenotiz, the class, and the order, and verifies"
}

# The note is firstmate's judgment: it stays in the primary home where it can be
# read back, and only its hash travels to the officer.
test_the_note_is_archived_in_the_primary_and_never_travels() {
  local rec primary officer out
  rec=$(make_fleet archive)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-b1
  write_notiz "$primary/notiz-b1.md"
  out=$(run_primary "$primary" approve sm-alpha ship-v2-b1 \
    --plan-file "$officer/data/ship-v2-b1/brief.md" \
    --klasse routine --no-order --notiz "$primary/notiz-b1.md") \
    || fail "approve failed: $out"

  assert_present "$primary/data/freigaben/sm-alpha/ship-v2-b1.md" \
    "the Freigabenotiz was not archived in the primary home"
  assert_grep "F3 Vision" "$primary/data/freigaben/sm-alpha/ship-v2-b1.md" \
    "the archived note is not the note that was signed"
  assert_absent "$officer/data/freigaben" "the Freigabenotiz must never travel to the officer home"

  # An approval that serves no order says so explicitly; "keine" is a choice on
  # the record, never an omission.
  assert_grep "order=keine" "$officer/state/ship-v2-b1.plan-approval" \
    "--no-order did not record the absence of an order"
  pass "the Freigabenotiz is archived in the primary home and only its hash travels"
}

# --- the one byte binding that survived -------------------------------------

# The headline change: prose may be sharpened after approval, the bar may not.
test_prose_may_change_after_approval_but_the_acceptance_block_may_not() {
  local rec primary officer out status verify
  rec=$(make_fleet abnahme)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-c1
  write_notiz "$primary/notiz-c1.md"
  out=$(run_primary "$primary" approve sm-alpha ship-v2-c1 \
    --plan-file "$officer/data/ship-v2-c1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-c1.md") \
    || fail "approve failed: $out"

  # Sharpening the prose is exactly what v1 punished and v2 permits.
  printf '\nA clearer sentence about the same work, added after approval.\n' \
    >> "$officer/data/ship-v2-c1/brief.md"
  verify=$(run_officer "$officer" verify ship-v2-c1) \
    || fail "editing prose outside the acceptance block must not withdraw the approval: $verify"
  assert_contains "$verify" "ship-v2-c1 approved" "verify did not still confirm the approval"

  # Moving the bar the work is measured against does withdraw it.
  write_brief "$officer" ship-v2-c1 '- [A1] the suite is green, except where it is not :: beleg=testlauf'
  out=$(run_officer "$officer" verify ship-v2-c1)
  status=$?
  [ "$status" -ne 0 ] || fail "an edited acceptance block should withdraw the approval"
  assert_contains "$out" "changed after it was approved" \
    "the refusal did not explain that the acceptance block moved"
  assert_contains "$out" "Abnahme (maschinenlesbar)" \
    "the refusal did not name the block that changed"

  # Removing the block entirely is as much a change as editing it: the record
  # keeps a hash, and a blockless brief fingerprints as something else.
  mkdir -p "$officer/data/ship-v2-c1"
  printf 'You are a crewmate.\n\n# Goal\nShip the thing.\n' > "$officer/data/ship-v2-c1/brief.md"
  out=$(run_officer "$officer" verify ship-v2-c1)
  status=$?
  [ "$status" -ne 0 ] || fail "deleting the acceptance block should withdraw the approval"
  assert_contains "$out" "changed after it was approved" \
    "removing the acceptance block was not treated as a change"
  pass "prose may be sharpened after approval; the acceptance block may not"
}

# An approval whose acceptance block already disagrees with the officer's brief
# could never be used, so it is refused instead of minted.
test_an_unusable_approval_is_refused_rather_than_minted() {
  local rec primary officer out status
  rec=$(make_fleet unusable)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-d1 '- [A1] the suite is green :: beleg=testlauf'
  write_brief "$primary" ship-v2-d1 '- [A1] something else entirely :: beleg=diff'
  write_notiz "$primary/notiz-d1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-d1 \
    --plan-file "$primary/data/ship-v2-d1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-d1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "approving a plan whose acceptance block is not the worker's should fail"
  assert_contains "$out" "does not match" \
    "the refusal did not explain the acceptance-block disagreement"
  assert_absent "$officer/state/ship-v2-d1.plan-approval" "a refused approval still wrote a record"
  pass "an approval whose acceptance block could never be used is refused at approval time"
}

# --- the five questions -----------------------------------------------------

# The note is the substance of the review, so an unanswered question stops the
# approval and the refusal names which one.
test_an_incomplete_note_stops_the_approval() {
  local rec primary officer out status
  rec=$(make_fleet notiz)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-e1

  write_notiz "$primary/notiz-e1.md" 3
  out=$(run_primary "$primary" approve sm-alpha ship-v2-e1 \
    --plan-file "$officer/data/ship-v2-e1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-e1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a note that leaves F3 unanswered must not be signed"
  assert_contains "$out" "F3 Vision" "the refusal did not name the unanswered question"
  assert_absent "$officer/state/ship-v2-e1.plan-approval" "a refused approval still wrote a record"
  assert_absent "$primary/data/freigaben/sm-alpha/ship-v2-e1.md" \
    "a refused approval still archived a note"

  # No note at all is the same refusal, and it names the five questions so the
  # firstmate can write one without looking anything up.
  out=$(run_primary "$primary" approve sm-alpha ship-v2-e1 \
    --plan-file "$officer/data/ship-v2-e1/brief.md" --klasse routine --order O-0042)
  status=$?
  [ "$status" -ne 0 ] || fail "an approval without a Freigabenotiz must fail"
  assert_contains "$out" "--notiz" "the refusal did not name the missing flag"
  assert_contains "$out" "F3 Vision" "the refusal did not spell out the five questions"

  # Completing the note clears it, so the gate withholds authority rather than
  # burning the task.
  write_notiz "$primary/notiz-e1.md"
  out=$(run_primary "$primary" approve sm-alpha ship-v2-e1 \
    --plan-file "$officer/data/ship-v2-e1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-e1.md") \
    || fail "a completed note should be signable: $out"
  pass "an unanswered question stops the approval and names itself"
}

# The order is a decision, never an omission: one of --order/--no-order is
# required and the two may not be given together.
test_the_order_must_be_stated_one_way_or_the_other() {
  local rec primary officer out status
  rec=$(make_fleet order)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-f1
  write_notiz "$primary/notiz-f1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-f1 \
    --plan-file "$officer/data/ship-v2-f1/brief.md" \
    --klasse routine --notiz "$primary/notiz-f1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "an approval that names no order at all must fail"
  assert_contains "$out" "--no-order" "the refusal did not offer the explicit way to say there is none"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-f1 \
    --plan-file "$officer/data/ship-v2-f1/brief.md" \
    --klasse routine --order O-0042 --no-order --notiz "$primary/notiz-f1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "--order and --no-order together must fail"
  assert_contains "$out" "contradict" "the refusal did not say the two flags contradict each other"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-f1 \
    --plan-file "$officer/data/ship-v2-f1/brief.md" \
    --klasse routine --order 42 --notiz "$primary/notiz-f1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed order id must fail"
  assert_contains "$out" "O-0007" "the refusal did not show what an order id looks like"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-f1 \
    --plan-file "$officer/data/ship-v2-f1/brief.md" \
    --klasse erfunden --order O-0042 --notiz "$primary/notiz-f1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown class must fail"
  assert_contains "$out" "vocabulary is closed" "the refusal did not say the class vocabulary is closed"
  pass "the order and the class are stated explicitly or the approval does not happen"
}

# --- the captain's wording --------------------------------------------------

# destruktiv and produkt may not rest on the fleet's own judgment.
test_destructive_and_product_classes_demand_the_captains_wording() {
  local rec primary officer out status record
  rec=$(make_fleet vorlage)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-g1
  write_notiz "$primary/notiz-g1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-g1 \
    --plan-file "$officer/data/ship-v2-g1/brief.md" \
    --klasse destruktiv --order O-0042 --notiz "$primary/notiz-g1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a destruktiv approval without a captain wording must fail"
  assert_contains "$out" "--captain-vorlage" "the refusal did not name the required flag"
  assert_contains "$out" "not the fleet's to mint" \
    "the refusal did not say whose decision this is"
  assert_absent "$officer/state/ship-v2-g1.plan-approval" "a refused approval still wrote a record"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-g1 \
    --plan-file "$officer/data/ship-v2-g1/brief.md" \
    --klasse produkt --order O-0042 --notiz "$primary/notiz-g1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a produkt approval without a captain wording must fail"
  assert_contains "$out" "--captain-vorlage" "the produkt refusal did not name the required flag"

  # With the wording named, the approval is minted and the record carries the
  # order the captain's words live in, so the trail is followable later.
  out=$(run_primary "$primary" approve sm-alpha ship-v2-g1 \
    --plan-file "$officer/data/ship-v2-g1/brief.md" \
    --klasse destruktiv --order O-0042 --captain-vorlage O-0083 \
    --notiz "$primary/notiz-g1.md") \
    || fail "a destruktiv approval with a captain wording should succeed: $out"
  record="$officer/state/ship-v2-g1.plan-approval"
  assert_grep "klasse=destruktiv" "$record" "the record does not carry the destructive class"
  assert_grep "vorlage=O-0083" "$record" "the record does not carry the captain wording"
  out=$(run_officer "$officer" verify ship-v2-g1) || fail "verify rejected a destruktiv approval: $out"
  assert_contains "$out" "vorlage=O-0083" "verify did not surface the captain wording at the point of use"
  pass "destruktiv and produkt approvals carry the captain's recorded wording or do not exist"
}

# --- the tripwire -----------------------------------------------------------

# "routine" is a claim that nothing irreversible is in play. When the brief
# itself contradicts it, the tool refuses to let the contradiction pass quietly.
test_the_tripwire_stops_a_routine_class_the_brief_contradicts() {
  local rec primary officer out status record verify
  rec=$(make_fleet tripwire)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v2-h1 '- [A1] den Cache leeren :: beleg=testlauf' \
    'Run rm -rf /var/cache/app before the rebuild.'
  write_notiz "$primary/notiz-h1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-h1 \
    --plan-file "$officer/data/ship-v2-h1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-h1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "a routine class on a destructive brief must trip the tripwire"
  assert_contains "$out" "TRIPWIRE" "the refusal was not loud about being a tripwire"
  assert_contains "$out" "rm -rf" "the refusal did not name the marker it found"
  assert_contains "$out" "Ausweg:" "the refusal did not offer a way out"
  assert_contains "$out" "--klasse-begruendung" "the way out did not name the flag that takes it"
  assert_absent "$officer/state/ship-v2-h1.plan-approval" "a tripped approval still wrote a record"

  # Re-classifying is one way past.
  out=$(run_primary "$primary" approve sm-alpha ship-v2-h1 \
    --plan-file "$officer/data/ship-v2-h1/brief.md" \
    --klasse destruktiv --order O-0042 --captain-vorlage O-0083 \
    --notiz "$primary/notiz-h1.md") \
    || fail "re-classifying a destructive brief should succeed: $out"
  assert_grep "klasse=destruktiv" "$officer/state/ship-v2-h1.plan-approval" \
    "the re-classified approval did not record the new class"

  # Standing by routine is the other, and the claim is signed into the record
  # rather than merely spoken, so whoever starts the work reads it too.
  out=$(run_primary "$primary" approve sm-alpha ship-v2-h1 \
    --plan-file "$officer/data/ship-v2-h1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-h1.md" \
    --klasse-begruendung 'the cache is regenerated on the next request') \
    || fail "an overridden tripwire should mint the approval: $out"
  assert_contains "$out" "tripwire noted" "the override was not stated out loud at approval time"
  record="$officer/state/ship-v2-h1.plan-approval"
  assert_grep "klasse=routine" "$record" "the overridden approval did not record the routine class"
  assert_grep "begruendung=the cache is regenerated on the next request" "$record" \
    "the record does not carry the justification that was signed"
  verify=$(run_officer "$officer" verify ship-v2-h1) || fail "verify rejected the override: $verify"
  assert_contains "$verify" "carries a klasse-begruendung" \
    "the override was not restated where the work starts"

  # A non-routine class is not second-guessed: the tripwire exists to test the
  # routine CLAIM, and a brief already classed destruktiv makes no such claim.
  write_brief "$officer" ship-v2-h2 '- [A1] den Cache leeren :: beleg=testlauf' \
    'Run rm -rf /var/cache/app before the rebuild.'
  out=$(run_primary "$primary" approve sm-alpha ship-v2-h2 \
    --plan-file "$officer/data/ship-v2-h2/brief.md" \
    --klasse destruktiv --order O-0042 --captain-vorlage O-0083 \
    --notiz "$primary/notiz-h1.md") \
    || fail "a destruktiv class on a destructive brief should not trip anything: $out"
  assert_not_contains "$out" "TRIPWIRE" "the tripwire fired on a class that makes no routine claim"
  pass "a routine class the brief contradicts is refused, and any override is signed into the record"
}

# --- the transition off v=1 -------------------------------------------------

# A v=1 record is not a forgery and must not read as one. It gets its own exit
# status so a caller can tell "never approved" from "approved under a contract
# that no longer exists".
test_a_v1_record_is_answered_as_legacy_not_as_a_forgery() {
  local rec primary officer out status record
  rec=$(make_fleet legacy)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  write_brief "$officer" ship-v1-i1

  # A record in the shape the old contract wrote. No signature is needed: the
  # version is read before anything else, which is the point of the case.
  record="$officer/state/ship-v1-i1.plan-approval"
  {
    printf 'v=1\ntask=ship-v1-i1\nsecondmate=sm-alpha\n'
    printf 'plan_sha256=%064d\nplan_bytes=123\n' 0
    printf 'approved_at=2026-08-20T00:00:00Z\nkey_sha256=%064d\n' 0
    printf 'sig=AAAA\n'
  } > "$record"

  out=$(run_officer "$officer" verify ship-v1-i1)
  status=$?
  [ "$status" -eq 4 ] || fail "a v1 record should exit 4, got $status: $out"
  assert_contains "$out" "v1 legacy - re-approve needed" \
    "the refusal did not say the record is legacy"
  assert_contains "$out" "batch-approve" "the refusal did not name the fleet-wide way out"
  assert_not_contains "$out" "valid signature" "a legacy record must not read as a forgery"

  out=$(run_primary "$primary" list --secondmate sm-alpha)
  assert_contains "$out" "legacy" "list did not report the v1 record as legacy"
  pass "a v1 record is answered as legacy with its own exit status, not as a forgery"
}

# The transition path: one routine v2 record per task in a list, under one order
# and one note, so a running fleet does not stop for a contract change the
# captain never asked to stop it for.
test_batch_approve_mints_one_routine_record_per_task() {
  local rec primary officer out verify id
  rec=$(make_fleet batch)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  for id in ship-batch-j1 ship-batch-j2 ship-batch-j3; do
    write_brief "$officer" "$id"
  done
  write_notiz "$primary/notiz-j.md"
  {
    printf '# the tasks already running when the contract changed\n'
    printf 'ship-batch-j1\n'
    printf '\n'
    printf 'ship-batch-j2\n'
    printf 'ship-batch-j3\n'
  } > "$primary/tasks.txt"

  out=$(run_primary "$primary" batch-approve --heim "$officer" --order O-0100 \
    --notiz "$primary/notiz-j.md" --tasks "$primary/tasks.txt") \
    || fail "batch-approve failed: $out"
  assert_contains "$out" "3 records written" "batch-approve did not report the record count"

  for id in ship-batch-j1 ship-batch-j2 ship-batch-j3; do
    assert_present "$officer/state/$id.plan-approval" "batch-approve wrote no record for $id"
    assert_grep "v=2" "$officer/state/$id.plan-approval" "$id did not get a v2 record"
    assert_grep "klasse=routine" "$officer/state/$id.plan-approval" \
      "batch-approve must mint only the routine class"
    assert_grep "order=O-0100" "$officer/state/$id.plan-approval" \
      "$id does not carry the rebuild order"
    verify=$(run_officer "$officer" verify "$id") \
      || fail "a batch-minted approval should verify: $verify"
  done

  # An empty list is a mistake worth naming rather than a silent success.
  printf '# nothing here\n' > "$primary/empty.txt"
  out=$(run_primary "$primary" batch-approve --heim "$officer" --order O-0100 \
    --notiz "$primary/notiz-j.md" --tasks "$primary/empty.txt") \
    && fail "an empty task list should not report success: $out"
  assert_contains "$out" "no task ids" "the refusal did not say the list named nothing"

  # The batch path carries the same note bar as `approve`: a fleet-wide
  # transition is still a review, not a rubber stamp.
  write_notiz "$primary/notiz-thin.md" 5
  out=$(run_primary "$primary" batch-approve --heim "$officer" --order O-0100 \
    --notiz "$primary/notiz-thin.md" --tasks "$primary/tasks.txt") \
    && fail "batch-approve should refuse an incomplete note: $out"
  assert_contains "$out" "F5 Betroffene" "the batch refusal did not name the unanswered question"
  pass "batch-approve mints one routine v2 record per listed task, under one order and one note"
}

# --- the merge that will hold ------------------------------------------------

# A missing mandate does not stop the plan; it stops the merge (HR2'). Hearing
# it at approval time beats discovering it at landing time.
test_approve_warns_when_the_repo_has_no_mandate() {
  local rec primary officer out
  rec=$(make_fleet mandat)
  IFS='|' read -r primary officer <<EOF
$rec
EOF
  mkdir -p "$primary/projects/lensclash" "$officer/data/ship-v2-k1"
  write_brief "$officer" ship-v2-k1
  printf 'repo: lensclash\n' >> "$officer/data/ship-v2-k1/brief.md"
  write_notiz "$primary/notiz-k1.md"

  out=$(run_primary "$primary" approve sm-alpha ship-v2-k1 \
    --plan-file "$officer/data/ship-v2-k1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-k1.md") \
    || fail "a missing mandate must not refuse the approval: $out"
  assert_contains "$out" "HINWEIS" "approve did not warn about the missing mandate file"
  assert_contains "$out" "merge will hold everything" \
    "the warning did not say what the missing mandate will actually do"

  printf '# Mandat\n' > "$primary/projects/lensclash/MANDAT.md"
  out=$(run_primary "$primary" approve sm-alpha ship-v2-k1 \
    --plan-file "$officer/data/ship-v2-k1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/notiz-k1.md") \
    || fail "approve failed: $out"
  assert_not_contains "$out" "HINWEIS" "a present mandate must silence the warning"
  pass "approve warns when the brief's repo carries no mandate, and never refuses over it"
}

test_v2_record_signs_the_note_and_verifies
test_the_note_is_archived_in_the_primary_and_never_travels
test_prose_may_change_after_approval_but_the_acceptance_block_may_not
test_an_unusable_approval_is_refused_rather_than_minted
test_an_incomplete_note_stops_the_approval
test_the_order_must_be_stated_one_way_or_the_other
test_destructive_and_product_classes_demand_the_captains_wording
test_the_tripwire_stops_a_routine_class_the_brief_contradicts
test_a_v1_record_is_answered_as_legacy_not_as_a_forgery
test_batch_approve_mints_one_routine_record_per_task
test_approve_warns_when_the_repo_has_no_mandate
