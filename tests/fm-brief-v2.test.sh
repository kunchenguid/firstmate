#!/usr/bin/env bash
# Behavior tests for the v2 product layer of bin/fm-brief.sh and its owner
# library bin/fm-brief-product-lib.sh.
#
# What is under test is a contract, not prose: a ship brief cannot be scaffolded
# without naming the captain order it hangs from and the product goal it serves;
# the acceptance points, the verbatim no-gos, and the embedded rules land in the
# brief as machine-readable blocks; the no-go cap from regeln/VERFASSUNG.yaml is
# enforced hard rather than trimmed silently; and the secondmate charter carries
# the reversed initiative doctrine (the old "You do not generate your own work"
# ban is struck - regeln/ABGESCHAFFT.md, charter-eigeninitiative-verbot).
#
# The rule block is deliberately fail-open: bin/fm-regeln needs a venv, an
# embedding model, and an ingested index, none of which a test fixture has. The
# brief must still be written, with the gap visible as a comment line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-v2)

# A fresh home per case, so one scaffold's brief can never satisfy another's
# assertion.
v2_home() { # <name> -> path to a fresh fixture home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s' "$home"
}

ZIEL='Scans reach a card without a detour|lensclash/scan-zu-karte'

# Both halves of the order reference are mandatory on a ship brief, and so is
# the product goal. The refusal must name the flag AND show a usable example -
# a bare "missing argument" would just move the guessing to the caller.
test_ship_requires_order_and_goal() {
  local home out status brief
  home=$(v2_home ship-required)

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" no-order some-repo --mode local-only 2>&1) || status=$?
  expect_code 1 "$status" "a ship brief without --order/--no-order-reason must refuse"
  assert_contains "$out" "must state its order reference" "the order refusal does not say what is missing"
  assert_contains "$out" "--no-order-reason" "the order refusal does not name its way out"
  assert_contains "$out" "bin/fm-brief.sh" "the order refusal carries no usable example"
  assert_absent "$home/data/no-order/brief.md" "a refused ship scaffold still wrote a brief"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" no-ziel some-repo --mode local-only --order O-0083 2>&1) || status=$?
  expect_code 1 "$status" "a ship brief without --ziel must refuse"
  assert_contains "$out" "must name the product goal" "the goal refusal does not say what is missing"
  assert_absent "$home/data/no-ziel/brief.md" "a refused ship scaffold still wrote a brief"

  # --no-order-reason is a full substitute for --order, not a lesser one.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" reasoned some-repo --mode local-only \
    --no-order-reason 'strike list of the 2026-08-24 Tagesschluss' --ziel "$ZIEL" >/dev/null 2>&1 \
    || fail "--no-order-reason did not satisfy the ship order contract"
  brief="$home/data/reasoned/brief.md"
  assert_grep 'Order-Bezug: keiner (strike list of the 2026-08-24 Tagesschluss)' "$brief" \
    "--no-order-reason did not render the machine-readable no-order line"

  pass "fm-brief.sh: a ship brief refuses without an order reference and a product goal"
}

# The two halves are mutually exclusive and their values are validated, so a
# typo cannot be recorded as if it were an order id.
test_v2_flag_values_are_validated() {
  local home out status
  home=$(v2_home flag-values)

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bad-order some-repo --mode local-only \
    --order 0083 --ziel "$ZIEL" 2>&1) || status=$?
  expect_code 1 "$status" "a malformed order id must refuse"
  assert_contains "$out" "O-0083" "the order-id refusal does not show the expected shape"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" both some-repo --mode local-only \
    --order O-0083 --no-order-reason nope --ziel "$ZIEL" 2>&1) || status=$?
  expect_code 1 "$status" "--order together with --no-order-reason must refuse"
  assert_contains "$out" "mutually exclusive" "the double-order refusal does not say why"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bad-ziel some-repo --mode local-only \
    --order O-0083 --ziel 'just a sentence' 2>&1) || status=$?
  expect_code 1 "$status" "a --ziel without its repo/anchor half must refuse"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bad-beleg some-repo --mode local-only \
    --order O-0083 --ziel "$ZIEL" --abnahme 'A1::it works::vibes' 2>&1) || status=$?
  expect_code 1 "$status" "an unknown acceptance evidence kind must refuse"
  assert_contains "$out" "klickbeleg" "the evidence-kind refusal does not list the closed set"

  # A charter is not a brief: these flags must be refused, never accepted and dropped.
  status=0
  out=$(FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" charter-flags \
    --secondmate --no-projects --order O-0083 2>&1) || status=$?
  expect_code 1 "$status" "v2 brief flags on a secondmate charter must refuse"

  pass "fm-brief.sh: v2 flag values are validated, exclusive, and refused where they do not apply"
}

# The whole block set, in one brief: header lines join the existing header, the
# acceptance/no-go/rule blocks land before "# Rules", and the no-go cap from
# regeln/VERFASSUNG.yaml is enforced hard on a sixth line.
test_full_ship_brief_carries_every_v2_block() {
  local home brief err deckel body
  home=$(v2_home ship-full)
  err="$TMP_ROOT/ship-full.err"
  deckel=$(sed -n 's/^nogo_zeilen_max_je_brief:[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$ROOT/regeln/VERFASSUNG.yaml")
  [ "$deckel" = 5 ] || fail "this test assumes nogo_zeilen_max_je_brief=5, VERFASSUNG.yaml says '$deckel'"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" full some-repo --mode no-mistakes \
    --order O-0083 \
    --ziel "$ZIEL" \
    --captain-flaeche \
    --abnahme 'A1::the order gate refuses an order-less brief::testlauf' \
    --abnahme 'A2::the captain surface renders unchanged::klickbeleg' \
    --no-go 'no automatic deletion of a user catalogue' \
    --no-go 'no paid API call without a stated budget' \
    --no-go 'no schema change without an export path' \
    --no-go 'no captain-facing copy change without his word' \
    --no-go 'no silent fallback when identification fails' \
    --no-go 'this sixth line must be cut' \
    >/dev/null 2>"$err" || fail "the fully specified ship scaffold failed: $(cat "$err")"
  brief="$home/data/full/brief.md"

  assert_grep 'Brief-Version: v2' "$brief" "the brief carries no v2 version line"
  assert_grep 'Order-Bezug: O-0083' "$brief" "the brief carries no machine-readable order reference"
  assert_grep 'Captain-Flaeche: ja' "$brief" "--captain-flaeche did not render the line bin/fm-abnahme.sh reads"
  assert_grep 'Dient Produktziel: Scans reach a card without a detour (lensclash/VISION.md#scan-zu-karte)' "$brief" \
    "the product goal line is missing or misrendered"

  assert_grep '## Abnahme (maschinenlesbar)' "$brief" "the acceptance block is missing"
  assert_grep '- [A1] the order gate refuses an order-less brief :: beleg=testlauf' "$brief" \
    "acceptance point A1 does not match the format bin/fm-abnahme.sh parses"
  assert_grep '- [A2] the captain surface renders unchanged :: beleg=klickbeleg' "$brief" \
    "acceptance point A2 does not match the format bin/fm-abnahme.sh parses"

  # Hard cap, loudly: five lines survive verbatim, the sixth is dropped and said so.
  assert_grep '## No-Gos (woertlich aus der Produktgrundlage)' "$brief" "the no-go block is missing"
  assert_grep '- no silent fallback when identification fails' "$brief" "the fifth no-go line was dropped"
  assert_no_grep 'this sixth line must be cut' "$brief" "the no-go cap did not cut the sixth line"
  assert_grep 'nogo_zeilen_max_je_brief' "$err" "the no-go cap cut a line without naming the cap it enforced"

  # Placement: every v2 block belongs ahead of the rules, not appended after them.
  body=$(cat "$brief")
  assert_contains "${body%%# Rules*}" '## Abnahme (maschinenlesbar)' "the acceptance block landed after # Rules"
  assert_contains "${body%%# Rules*}" '## No-Gos' "the no-go block landed after # Rules"
  assert_contains "${body%%# Rules*}" '## Regeln (eingebettet' "the embedded-rule block landed after # Rules"

  pass "fm-brief.sh: a fully specified ship brief carries every v2 block and caps its no-gos hard"
}

# The rule block is the brief's answer to harnesses without hooks. A cold or
# absent rule tool must not stop a brief from being written - the gap is
# recorded as a comment instead.
test_rule_block_is_fail_open() {
  local home brief
  home=$(v2_home rules-fail-open)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-brief.sh" cold some-repo --mode local-only \
    --order O-0083 --ziel "$ZIEL" >/dev/null 2>&1 \
    || fail "a home without bin/fm-regeln must still scaffold a brief"
  brief="$home/data/cold/brief.md"
  assert_grep '## Regeln (eingebettet' "$brief" "the rule section vanished when bin/fm-regeln was unavailable"
  assert_grep '<!-- regeln: nicht verfuegbar -->' "$brief" \
    "an unavailable bin/fm-regeln did not leave the visible fail-open marker"
  pass "fm-brief.sh: the embedded rule block fails open with a visible marker"
}

# A scout's deliverable is a report and its order is often the question itself,
# so neither flag is mandatory - but the brief still records that fact instead
# of leaving the reader to guess.
test_scout_order_and_goal_are_optional() {
  local home brief
  home=$(v2_home scout-optional)

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" plain some-repo --scout >/dev/null 2>&1 \
    || fail "a scout brief without --order must still scaffold"
  brief="$home/data/plain/brief.md"
  assert_grep 'Brief-Version: v2' "$brief" "the scout brief carries no v2 version line"
  assert_grep 'Order-Bezug: keiner (scout: report only, no order named)' "$brief" \
    "a scout brief without an order does not record why it has none"
  assert_no_grep 'Dient Produktziel:' "$brief" "a scout brief without --ziel invented a product goal line"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" anchored some-repo --scout \
    --order O-0042 --ziel "$ZIEL" >/dev/null 2>&1 \
    || fail "a scout brief must accept an order and a goal when they exist"
  brief="$home/data/anchored/brief.md"
  assert_grep 'Order-Bezug: O-0042' "$brief" "a scout brief dropped its explicit order reference"
  assert_grep 'Dient Produktziel: Scans reach a card without a detour (lensclash/VISION.md#scan-zu-karte)' "$brief" \
    "a scout brief dropped its explicit product goal"

  pass "fm-brief.sh: scout briefs take order and goal optionally and record their absence"
}

# The charter is where product knowledge enters the chain, and where the struck
# initiative ban must no longer appear.
test_charter_carries_product_section_and_reversed_initiative() {
  local home brief
  home=$(v2_home charter)
  FM_HOME="$home" FM_SECONDMATE_CHARTER='own the catalogue end to end' \
    "$ROOT/bin/fm-brief.sh" sm --secondmate alpha >/dev/null 2>&1 \
    || fail "the secondmate charter scaffold failed"
  brief="$home/data/sm/brief.md"

  assert_grep '# Product' "$brief" "the charter has no # Product section"
  assert_grep '{PRODUCT_LINES}' "$brief" "the charter's # Product section has no fill placeholder"
  assert_grep 'MANDAT.md' "$brief" "the charter's # Product section does not name the mandate boundary"
  assert_grep 'mechanically at merge' "$brief" "the charter does not say the mandate boundary is checked mechanically"
  assert_grep 'as its named personas' "$brief" "the charter does not carry the walkthrough duty"
  assert_grep 'becomes a backlog item' "$brief" "the charter does not turn walkthrough findings into backlog items"

  # The reversal, verbatim where it matters.
  assert_grep 'You DO generate your own work' "$brief" "the charter does not carry the reversed initiative doctrine"
  assert_grep 'You never start unplanned.' "$brief" "the charter does not keep the plan-before-start rule"
  assert_grep 'reportable condition, not a resting state' "$brief" \
    "the charter does not make an empty plan state reportable"
  assert_grep 'without a vision anchor remain unwanted' "$brief" \
    "the charter dropped the surviving half of the survey ban"

  # The struck ban (regeln/ABGESCHAFFT.md: charter-eigeninitiative-verbot).
  assert_no_grep 'You do not generate your own work' "$brief" "the struck initiative ban is still in the charter"
  assert_no_grep 'Act only on tasks the main firstmate routes to you' "$brief" \
    "the struck routed-work-only clause is still in the charter"
  assert_no_grep 'An empty queue is a healthy resting state' "$brief" \
    "the definition of done still calls an empty queue a resting state"

  # The plan-approval gate is what makes the reversal safe; it must survive.
  assert_grep '# Plan approval before an implementation' "$brief" \
    "the charter lost the plan-approval gate the reversal depends on"

  pass "fm-brief.sh: the charter carries # Product and the reversed initiative doctrine"
}

# {PRODUCT_LINES} is always scaffolded unfilled, and a charter grants a product
# mandate. An unannounced placeholder would hand a secondmate that mandate over
# documents it was never pointed at, so the scaffold must name it every time -
# including on the path where FM_SECONDMATE_CHARTER left no {TASK} to mention.
test_charter_announces_the_product_placeholder() {
  local home out
  home=$(v2_home charter-announce)

  out=$(FM_HOME="$home" FM_SECONDMATE_CHARTER='own the catalogue end to end' \
    "$ROOT/bin/fm-brief.sh" filled --secondmate alpha 2>&1) \
    || fail "the secondmate charter scaffold failed"
  assert_contains "$out" '{PRODUCT_LINES}' \
    "a charter with a filled-in text scaffolded {PRODUCT_LINES} without telling the caller to replace it"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" unfilled --secondmate alpha 2>&1) \
    || fail "the placeholder secondmate charter scaffold failed"
  assert_contains "$out" '{PRODUCT_LINES}' \
    "the {TASK} charter path does not name the product placeholder"
  assert_contains "$out" '{TASK}' "the {TASK} charter path stopped naming {TASK}"

  # The header is where a caller looks up what to put there, so the fill format
  # must be documented rather than inferred from the placeholder's name.
  out=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$out" '{PRODUCT_LINES}' "--help does not document the product placeholder"
  assert_contains "$out" 'success measures' "--help does not show the per-project fill format"

  pass "fm-brief.sh: the charter scaffold announces {PRODUCT_LINES} and documents its fill format"
}

# Bash 3.2 (macOS stock bash) runs this suite, and two constructs break there:
# a heredoc nested in a command substitution corrupts parsing of the whole file
# (issues #166/#958/#1069), and `${#arr[@]}` / `"${arr[@]}"` on an EMPTY array
# aborts under `set -u`. This library sidesteps both by construction - it emits
# every block with printf and never expands an array whole - so the guard is the
# absence of those constructs, checked directly rather than inferred from a
# Bash 5 parse.
test_product_lib_is_bash32_safe() {
  local out rc lib
  lib="$ROOT/bin/fm-brief-product-lib.sh"
  out=$(bash -n "$lib" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief-product-lib.sh must parse cleanly (got: $out)"
  if grep -n '<<' "$lib" >/dev/null; then
    fail "fm-brief-product-lib.sh introduced a heredoc; keep it printf-only so no heredoc can end up inside a command substitution (Bash 3.2 parse bug)"
  fi
  if grep -nE '\$\{#FM_BRIEF_(ABNAHME|NOGO)\[@\]\}|"\$\{FM_BRIEF_(ABNAHME|NOGO)\[@\]\}"' "$lib" >/dev/null; then
    fail "fm-brief-product-lib.sh expands a v2 array whole; on Bash 3.2 that aborts under set -u when the array is empty - use the FM_BRIEF_*_N counters"
  fi
  pass "fm-brief-product-lib.sh: parses cleanly and avoids both Bash 3.2 traps"
}

test_ship_requires_order_and_goal
test_v2_flag_values_are_validated
test_full_ship_brief_carries_every_v2_block
test_rule_block_is_fail_open
test_scout_order_and_goal_are_optional
test_charter_carries_product_section_and_reversed_initiative
test_charter_announces_the_product_placeholder
test_product_lib_is_bash32_safe
