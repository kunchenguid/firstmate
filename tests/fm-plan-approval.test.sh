#!/usr/bin/env bash
# Behavior tests for the plan-approval gate on secondmate implementations.
#
# The captain's standing order is that an officer submits a plan before every
# implementation and starts only after the main firstmate's explicit approval,
# while investigation stays free. bin/fm-plan-approval.sh makes that mechanical:
# only the primary home holds the ed25519 private key, and a secondmate home
# refuses to start a ship task without a signature naming that exact task id.
#
# This file owns the gate's END-TO-END behavior - the spawn and the promotion
# that consult it. The v=2 payload itself (the 5-question Freigabenotiz, the
# class, the captain's wording, the tripwire, batch-approve, the v1 legacy exit)
# is pinned next door in tests/fm-plan-approval-v2.test.sh, so a refusal there
# can be read without a backend anywhere near it.
#
# WHY SOME CASES HERE WERE REWRITTEN FOR v=2. The old contract signed a hash of
# the WHOLE brief, so these cases used to assert that any edit to a brief - a
# typo fix included - withdrew the approval. v=2 signs the firstmate's own
# Freigabenotiz instead, and keeps exactly one byte binding: the brief's
# "## Abnahme (maschinenlesbar)" block, the bar the work is measured against.
# The tampering case below therefore now pins BOTH halves of that boundary
# (prose free, bar bound), and the forgery case builds a v=2 payload, because a
# v=1 one is answered as legacy rather than as the forgery it is meant to be.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPROVAL="$ROOT/bin/fm-plan-approval.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"

if ! command -v openssl >/dev/null 2>&1; then
  echo "skip: openssl is not installed, so ed25519 plan approvals cannot be exercised"
  exit 0
fi
if ! (
  probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-plan-approval-probe.XXXXXX") || exit 1
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

TMP_ROOT=$(fm_test_tmproot fm-plan-approval)

# One primary home plus one seeded secondmate home, both shaped enough for the
# real home validator, with a fake tmux that refuses so a spawn that clears the
# gate still creates nothing. Echoes "<primary>|<officer>|<fakebin>|<project>".
#
# The fixture also brings its own account ledger and a store that has finished
# onboarding for both paths a case spawns into. bin/fm-spawn-gate-lib.sh resolves
# the seat from config/konten.tsv BEFORE the plan gate runs and refuses a seat
# that would drop the agent into the setup wizard, so without this the cases
# below would never reach the gate they are about (see FM_KONTEN_AKTE in
# run_spawn).
make_fleet() {  # <name> [<secondmate-id>]
  local name=$1 sid=${2:-sm-alpha} base primary officer fakebin project store
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  officer="$base/officer"
  fakebin="$base/bin"
  project="$base/projects/proj"
  store="$base/store"
  mkdir -p "$primary/data" "$primary/state" "$primary/config" "$primary/bin" \
    "$officer/data" "$officer/state" "$officer/config" "$officer/bin" \
    "$fakebin" "$project" "$store"
  project=$(cd "$project" && pwd -P)
  printf '# firstmate\n' > "$primary/AGENTS.md"
  printf '# firstmate\n' > "$officer/AGENTS.md"
  printf '%s\n' "$sid" > "$officer/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$primary" \
    > "$officer/.fm-secondmate-parent"
  printf -- '- %s - alpha domain (home: %s; scope: alpha work; projects: none; added 2026-08-20)\n' \
    "$sid" "$officer" > "$primary/data/secondmates.md"
  printf '{"hasCompletedOnboarding":true,"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true}}}\n' \
    "$project" "$officer" > "$store/.claude.json"
  printf '# speicher\tpfad\tanthropic_konto\trolle\tbemerkung\n' > "$base/konten.tsv"
  printf 'basis\t%s\tfixture@example.invalid\toffiziere-worker\ttest fixture seat\n' \
    "$store" >> "$base/konten.tsv"
  printf '%s\n' "$primary|$officer|$fakebin|$project"
}

# A brief with a real acceptance block, which is the one part v=2 binds
# byte-exactly. The block is closed by the next "## " heading, exactly as
# bin/fm-abnahme.sh reads it, so <extra> lands OUTSIDE the bar.
write_brief() {  # <home> <id> [<extra-line>] [<abnahme-point>]
  local home=$1 id=$2 extra=${3:-} abnahme=${4:-'- [A1] the suite is green :: beleg=testlauf'}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Goal\nShip the thing.\n\n'
    printf '## Abnahme (maschinenlesbar)\n%s\n\n' "$abnahme"
    printf '## Definition of done\n'
    printf 'Delivery contract: mode=local-only\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$home/data/$id/brief.md"
}

# The Freigabenotiz v=2 signs: five questions, one answer each. What the answers
# SAY is firstmate's judgment and no tool grades it, so a fixture note is as
# valid as a considered one - only the five markers are mechanical.
write_notiz() {  # <file>
  {
    printf 'F1 Praemissen: the officer home is the one bound to this primary.\n'
    printf 'F2 Abnahme: the brief acceptance block is the whole bar.\n'
    printf 'F3 Vision: exercises the plan gate, not a product.\n'
    printf 'F4 Budget: one fixture run.\n'
    printf 'F5 Betroffene: nobody outside this temporary directory.\n'
  } > "$1"
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

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2 base
  shift 2
  # The ledger lives one level above both homes in the fixture, so an officer
  # and its primary read the same seat.
  base=$(dirname "$home")
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_KONTEN_AKTE="$base/konten.tsv" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The v=2 approval every case here needs: routine class, one order, one complete
# Freigabenotiz. The cases that are ABOUT the class, the order, or the note live
# in tests/fm-plan-approval-v2.test.sh; here the approval is a precondition.
approve() {  # <primary> <secondmate-id> <officer> <task-id>
  local primary=$1 sid=$2 officer=$3 task=$4 out
  write_notiz "$primary/freigabenotiz-$task.md"
  out=$(run_primary "$primary" approve "$sid" "$task" \
    --plan-file "$officer/data/$task/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/freigabenotiz-$task.md") \
    || fail "approve failed for $task: $out"
}

sha256_of() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

GATE_REFUSAL="cannot start here without the main firstmate's plan approval"

# (a) With no approval on file, an officer home cannot start a ship task at all,
# and the refusal names the procedure rather than just failing.
test_absent_approval_refuses_a_ship_spawn() {
  local rec primary officer fakebin project out status
  rec=$(make_fleet absent)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" ship-absent-a1

  out=$(run_spawn "$officer" "$fakebin" ship-absent-a1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unapproved ship spawn in an officer home should exit non-zero"
  assert_contains "$out" "$GATE_REFUSAL" "the refusal did not name the plan approval requirement"
  assert_contains "$out" "no approval recorded for ship-absent-a1" \
    "the refusal did not say what was missing"
  assert_contains "$out" "bin/fm-plan-approval.sh approve" \
    "the refusal did not name the approval procedure"
  assert_absent "$officer/state/ship-absent-a1.meta" "a refused spawn wrote task metadata"
  pass "an officer home cannot start a ship task without a recorded approval"
}

# (b) The primary signs the plan; the same spawn then clears the gate and fails
# only later, at the refusing tmux, so nothing before the endpoint blocked it.
test_valid_approval_clears_the_gate() {
  local rec primary officer fakebin project out verify
  rec=$(make_fleet valid)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" ship-valid-b1
  approve "$primary" sm-alpha "$officer" ship-valid-b1

  verify=$(run_officer "$officer" verify ship-valid-b1) \
    || fail "verify should accept a fresh approval: $verify"
  assert_contains "$verify" "ship-valid-b1 approved" "verify did not confirm the approval"
  assert_contains "$verify" "key=parent" \
    "verify should anchor the trusted key in the parent home, not this home's own copy"

  out=$(run_spawn "$officer" "$fakebin" ship-valid-b1 "$project" claude --mode local-only --yolo off)
  assert_not_contains "$out" "$GATE_REFUSAL" "an approved ship spawn was refused by the plan gate"
  assert_not_contains "$out" "no approval recorded" "an approved ship spawn still read as unapproved"
  pass "a primary-signed approval clears the officer home's ship spawn"
}

# (c) v=2 draws the line at the acceptance block rather than at the whole brief:
# prose may be sharpened after approval, the bar the work is measured against may
# not. This case pins both halves at the spawn, because "which edits burn an
# approval" is exactly the question an officer asks at the point of starting.
test_a_changed_acceptance_block_invalidates_the_approval() {
  local rec primary officer fakebin project out status
  rec=$(make_fleet tampered)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" ship-tamper-c1
  approve "$primary" sm-alpha "$officer" ship-tamper-c1

  # Prose: free. Under v=1 this appended line alone withdrew the approval, which
  # is the cost the captain's standing order was paying for a byte signature.
  printf 'A clearer sentence about the same work, added after approval.\n' \
    >> "$officer/data/ship-tamper-c1/brief.md"
  out=$(run_spawn "$officer" "$fakebin" ship-tamper-c1 "$project" claude --mode local-only --yolo off)
  assert_not_contains "$out" "$GATE_REFUSAL" "sharpening prose after approval withdrew the approval"
  assert_not_contains "$out" "changed after it was approved" \
    "an edit outside the acceptance block was treated as a change to the bar"

  # The bar: bound. Moving what the work is measured against withdraws it.
  write_brief "$officer" ship-tamper-c1 '' '- [A1] the suite is green, mostly :: beleg=testlauf'
  out=$(run_spawn "$officer" "$fakebin" ship-tamper-c1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn on a moved acceptance block should exit non-zero"
  assert_contains "$out" "changed after it was approved" \
    "the refusal did not explain that the approved acceptance block no longer matches"
  assert_absent "$officer/state/ship-tamper-c1.meta" "a refused spawn wrote task metadata"

  # Re-approving the current criteria clears it again, so the gate withdraws
  # authority rather than permanently burning the task.
  approve "$primary" sm-alpha "$officer" ship-tamper-c1
  out=$(run_spawn "$officer" "$fakebin" ship-tamper-c1 "$project" claude --mode local-only --yolo off)
  assert_not_contains "$out" "$GATE_REFUSAL" "a re-approved acceptance block was still refused"
  pass "prose stays free after approval; a changed acceptance block withdraws it until re-approved"
}

# (d) Investigation stays free and a launch is not an implementation, so scout
# spawns and secondmate launches are untouched, and so is the primary home.
test_scout_secondmate_and_primary_spawns_are_ungated() {
  local rec primary officer fakebin project out
  rec=$(make_fleet ungated)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" scout-ungated-d1
  out=$(run_spawn "$officer" "$fakebin" scout-ungated-d1 "$project" claude --scout)
  assert_not_contains "$out" "$GATE_REFUSAL" "a scout spawn in an officer home was gated"
  assert_not_contains "$out" "no approval recorded" "a scout spawn consulted the plan gate"

  # A secondmate launch from the officer home: refused for its own reasons long
  # before any plan gate could apply, and never for a missing approval.
  write_brief "$officer" sm-ungated-d2
  out=$(run_spawn "$officer" "$fakebin" sm-ungated-d2 "$officer" claude --secondmate)
  assert_not_contains "$out" "$GATE_REFUSAL" "a secondmate launch was gated"

  # The primary home's own dispatches are the approving instance's own.
  write_brief "$primary" ship-primary-d3
  out=$(run_spawn "$primary" "$fakebin" ship-primary-d3 "$project" claude --mode local-only --yolo off)
  assert_not_contains "$out" "$GATE_REFUSAL" "the primary home's own ship spawn was gated"
  assert_not_contains "$out" "no approval recorded" "the primary home consulted the plan gate"
  pass "scout spawns, secondmate launches, and primary dispatches stay ungated"
}

# (e) Everything needed to build a record is present in the officer home except
# the private key, so a record forged there must not verify. Two forgeries: one
# signed with a key the officer generated, and one that also replaces this
# home's own copy of the trusted public key.
test_a_forgery_built_in_the_officer_home_fails() {
  local rec primary officer fakebin project record forge out status key_sha abnahme_sha
  rec=$(make_fleet forged)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" ship-forge-e1
  approve "$primary" sm-alpha "$officer" ship-forge-e1
  record="$officer/state/ship-forge-e1.plan-approval"
  forge="$officer/state/forge"
  mkdir -p "$forge"

  # Forgery 1: re-sign the genuine payload with a key minted inside this home.
  # A v=2 record signs its first ELEVEN lines; taking any other count would
  # test the parser instead of the signature.
  openssl genpkey -algorithm ed25519 -out "$forge/key" >/dev/null 2>&1 \
    || fail "could not mint a forgery key"
  head -n 11 "$record" > "$forge/payload"
  openssl pkeyutl -sign -inkey "$forge/key" -rawin -in "$forge/payload" -out "$forge/sig" >/dev/null 2>&1 \
    || fail "could not sign the forged payload"
  chmod u+w "$record"
  { cat "$forge/payload"; printf 'sig=%s\n' "$(openssl base64 -A -in "$forge/sig")"; } > "$record"

  out=$(run_spawn "$officer" "$fakebin" ship-forge-e1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a self-signed approval should exit non-zero"
  assert_contains "$out" "does not carry a valid signature" \
    "a self-signed approval was not rejected on its signature"
  assert_absent "$officer/state/ship-forge-e1.meta" "a forged spawn wrote task metadata"

  # Forgery 2: also replace this home's own inherited public key and name that
  # key in the record, which is the strongest record an officer can build from
  # material it controls. The parent binding anchors the trusted key outside
  # this home, so it still fails. The forged payload is a well-formed v=2 one on
  # purpose: a v=1 payload would be answered as legacy, which would prove
  # nothing about the key binding this case is here for.
  openssl pkey -in "$forge/key" -pubout -out "$officer/config/plan-approval-key.pub" >/dev/null 2>&1 \
    || fail "could not publish the forged public key"
  key_sha=$(sha256_of "$officer/config/plan-approval-key.pub")
  abnahme_sha=$(sed -n 's/^abnahme_sha256=//p' "$record")
  {
    printf 'v=2\ntask=ship-forge-e1\nsecondmate=sm-alpha\n'
    printf 'klasse=routine\norder=O-0042\nvorlage=-\nbegruendung=-\n'
    printf 'notiz_sha256=%064d\nabnahme_sha256=%s\n' 0 "$abnahme_sha"
    printf 'approved_at=2026-08-20T00:00:00Z\nkey_sha256=%s\n' "$key_sha"
  } > "$forge/payload2"
  openssl pkeyutl -sign -inkey "$forge/key" -rawin -in "$forge/payload2" -out "$forge/sig2" >/dev/null 2>&1 \
    || fail "could not sign the second forged payload"
  chmod u+w "$record"
  { cat "$forge/payload2"; printf 'sig=%s\n' "$(openssl base64 -A -in "$forge/sig2")"; } > "$record"

  out=$(run_spawn "$officer" "$fakebin" ship-forge-e1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a fully self-issued approval should exit non-zero"
  assert_contains "$out" "signed with a key this home does not trust" \
    "a substituted trusted key was accepted"
  assert_absent "$officer/state/ship-forge-e1.meta" "a forged spawn wrote task metadata"
  pass "an approval forged inside the officer home never verifies"
}

# An approval names one officer home, so a record copied out of one home into
# another cannot authorize work there.
test_an_approval_cannot_be_replayed_into_another_home() {
  local rec primary officer fakebin project other out status
  rec=$(make_fleet replay sm-alpha)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  # A second officer home under the same primary, so only the home identity and
  # its marker differ between the two.
  other="$TMP_ROOT/replay/officer-beta"
  mkdir -p "$other/data" "$other/state" "$other/config" "$other/bin"
  printf '# firstmate\n' > "$other/AGENTS.md"
  printf 'sm-beta\n' > "$other/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$primary" \
    > "$other/.fm-secondmate-parent"
  write_brief "$officer" ship-replay-f1
  write_brief "$other" ship-replay-f1
  approve "$primary" sm-alpha "$officer" ship-replay-f1
  cp "$officer/state/ship-replay-f1.plan-approval" "$other/state/ship-replay-f1.plan-approval"

  out=$(run_spawn "$other" "$fakebin" ship-replay-f1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a replayed approval should exit non-zero"
  assert_contains "$out" "issued to secondmate sm-alpha, not this home (sm-beta)" \
    "a replayed approval was not rejected on its home binding"
  pass "an approval issued to one officer home cannot be replayed into another"
}

# Promotion is the other way a ship contract can begin in an officer home, so it
# carries the same gate: free investigation cannot be converted into an
# unapproved implementation.
test_promotion_is_gated_in_an_officer_home() {
  local rec primary officer fakebin project out status meta
  rec=$(make_fleet promote)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  write_brief "$officer" scout-promote-g1
  meta="$officer/state/scout-promote-g1.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-scout-promote-g1" \
    "endpoint_task_id=scout-promote-g1" \
    "worktree=$project" \
    "project=$project" \
    "harness=claude" \
    "kind=scout"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$officer" FM_STATE_OVERRIDE="$officer/state" \
    FM_DATA_OVERRIDE="$officer/data" FM_CONFIG_OVERRIDE="$officer/config" \
    PATH="$fakebin:$PATH" "$PROMOTE" scout-promote-g1 --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unapproved promotion should exit non-zero"
  assert_contains "$out" "cannot be promoted to an implementation here without the main firstmate's plan approval" \
    "the promotion refusal did not name the plan approval requirement"
  assert_grep "kind=scout" "$meta" "a refused promotion rewrote the task contract"
  assert_no_grep "kind=ship" "$meta" "a refused promotion flipped the task to ship"

  approve "$primary" sm-alpha "$officer" scout-promote-g1
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$officer" FM_STATE_OVERRIDE="$officer/state" \
    FM_DATA_OVERRIDE="$officer/data" FM_CONFIG_OVERRIDE="$officer/config" \
    PATH="$fakebin:$PATH" "$PROMOTE" scout-promote-g1 --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an approved promotion should succeed: $out"
  assert_grep "kind=ship" "$meta" "an approved promotion did not flip the task to ship"
  pass "promotion in an officer home needs the same approval a fresh ship spawn needs"
}

# The primary side of the contract: lazy key creation, revoke, list, and the
# refusal to mint an approval whose plan is not the brief the worker would follow.
test_primary_side_lifecycle() {
  local rec primary officer fakebin project out status
  rec=$(make_fleet lifecycle)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  assert_absent "$primary/config/plan-approval-key" "the primary key should not exist before it is needed"
  write_brief "$officer" ship-life-h1
  approve "$primary" sm-alpha "$officer" ship-life-h1
  assert_present "$primary/config/plan-approval-key" "approve did not create the primary private key"
  assert_present "$primary/config/plan-approval-key.pub" "approve did not create the primary public key"
  assert_absent "$officer/config/plan-approval-key" "the private key must never reach an officer home"

  out=$(run_primary "$primary" list --secondmate sm-alpha)
  assert_contains "$out" "ship-life-h1" "list did not report the approval"
  assert_contains "$out" "valid" "list did not report the approval as currently valid"

  out=$(run_primary "$primary" revoke ship-life-h1 --secondmate sm-alpha) \
    || fail "revoke failed: $out"
  assert_absent "$officer/state/ship-life-h1.plan-approval" "revoke did not remove the record"

  out=$(run_spawn "$officer" "$fakebin" ship-life-h1 "$project" claude --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a revoked approval should stop the spawn"
  assert_contains "$out" "$GATE_REFUSAL" "a revoked approval did not restore the refusal"

  # A plan whose acceptance block is not the one the worker would be held to is
  # refused at approval time rather than minted into an approval that could
  # never be used. Under v=2 the bar is the binding, so this is the shape the
  # refusal takes.
  write_brief "$primary" ship-life-h1 '' '- [A1] something else entirely :: beleg=diff'
  out=$(run_primary "$primary" approve sm-alpha ship-life-h1 \
    --plan-file "$primary/data/ship-life-h1/brief.md" \
    --klasse routine --order O-0042 --notiz "$primary/freigabenotiz-ship-life-h1.md")
  status=$?
  [ "$status" -ne 0 ] || fail "approving a plan that is not the worker's brief should exit non-zero"
  assert_contains "$out" "does not match" \
    "the refusal did not explain the acceptance-block binding"
  assert_absent "$officer/state/ship-life-h1.plan-approval" "a refused approval still wrote a record"
  pass "the primary side creates its key lazily, revokes, lists, and refuses an unusable approval"
}

# The public half is declared inherited material and the private half is not, in
# the one declaration every local and remote convergence point derives from.
test_only_the_public_key_is_inheritable() {
  local items
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" plan-approval-key.pub "*) ;;
    *) fail "config/plan-approval-key.pub must be inheritable so officer homes can verify approvals" ;;
  esac
  case " $FM_INHERITABLE_CONFIG " in
    *" plan-approval-key "*) fail "config/plan-approval-key must never be inheritable" ;;
  esac
  items=$(fm_config_inherit_items)
  assert_contains "$items" "config/plan-approval-key.pub" \
    "the declared inherited-material set must carry the public key"
  case $'\n'"$items"$'\n' in
    *$'\n'"config/plan-approval-key"$'\n'*) fail "the declared inherited-material set must never carry the private key" ;;
  esac
  # A verification key is not a default the agent may choose differently about,
  # so it converges without ever being inlined into a config-reread instruction.
  if fm_config_reread_is_allowlisted_item plan-approval-key.pub; then
    fail "the public key must not be inlined into the config-reread instruction"
  fi
  fm_config_reread_is_allowlisted_item crew-harness \
    || fail "ordinary config items must still be inlined into the config-reread instruction"
  pass "only the public half of the plan-approval key is declared inherited material"
}

# The propagation helper actually pushes the public key into a secondmate home
# and never carries the private one, so the declaration above is not just prose.
test_propagation_pushes_only_the_public_key() {
  local rec primary officer fakebin project out
  rec=$(make_fleet propagate)
  IFS='|' read -r primary officer fakebin project <<EOF
$rec
EOF
  out=$(run_primary "$primary" init) || fail "init failed: $out"
  (
    # shellcheck source=bin/fm-config-inherit-lib.sh
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    FM_HOME="$primary" propagate_secondmate_inheritance "$primary" "$officer" \
      "$primary/config" "$primary/data"
  ) || fail "propagation failed"
  cmp -s "$primary/config/plan-approval-key.pub" "$officer/config/plan-approval-key.pub" \
    || fail "the officer home did not receive the primary public key"
  assert_absent "$officer/config/plan-approval-key" "propagation carried the private key downstream"
  pass "propagation converges the public key into an officer home and never the private one"
}

test_absent_approval_refuses_a_ship_spawn
test_valid_approval_clears_the_gate
test_a_changed_acceptance_block_invalidates_the_approval
test_scout_secondmate_and_primary_spawns_are_ungated
test_a_forgery_built_in_the_officer_home_fails
test_an_approval_cannot_be_replayed_into_another_home
test_promotion_is_gated_in_an_officer_home
test_primary_side_lifecycle
test_only_the_public_key_is_inheritable
test_propagation_pushes_only_the_public_key
