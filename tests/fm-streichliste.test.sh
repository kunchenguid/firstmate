#!/usr/bin/env bash
# tests/fm-streichliste.test.sh - the day-close strike-candidate list must
# judge each Tor and each rule from real log/rule fixtures, never from the
# live repo:
#
#   1. a Tor whose log is younger than 45 days is reported "zu jung fuer ein
#      Urteil" and never as a strike candidate, even when its one entry is a
#      real denial.
#   2. a Tor with a pure false-alarm profile (every rot escaped, never a Fang)
#      becomes a strike candidate naming the shadow-mode remedy.
#   3. a Tor with zero denials in the last 45 days becomes a strike candidate
#      for that reason alone.
#   4. a Tor with a real catch (a rot with no escape) inside the window is
#      never a candidate for either reason.
#   5. an expired rule (status=abgelaufen) becomes a strike candidate naming
#      `fm-regeln streich <id>`.
#   6. a kontext rule with neither a golden-retrieval row nor a delivery-hit
#      becomes a strike candidate; one covered by either becomes not.
#   7. a kern rule is never judged by the kontext delivery-evidence rule.
#   8. a missing python3 degrades to one loud line and exit 0, never a crash.
#
# Everything resolves under FM_ROOT_OVERRIDE/FM_HOME, so no case can touch the
# live repo's regeln/, tor-log, or writ-fm state.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STL="$ROOT/bin/fm-streichliste.sh"

tage_vor() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }

tor_zeile() { # <ts> <tor> <verdikt> <ausweg>
  printf '{"ts":"%s","tor":"%s","regel":"-","verdikt":"%s","ausweg":"%s","kontext":"fixture"}\n' \
    "$1" "$2" "$3" "$4"
}

baue_fixture() {
  local d="$1"
  mkdir -p "$d/regeln" "$d/tests" "$d/state/tor-log" "$d/state/writ-fm"

  cat > "$d/regeln/test.yaml" <<'YAML'
rules:
  - id: STL-EXPIRED-001
    geltung: firstmate
    verbindlichkeit: kontext
    anker: [L01]
    quelle: grundsatz:1
    leser: retrieval
    verfall: '2020-01-01'
    status: abgelaufen
    trigger: >
      A fixture trigger for the expired rule.
    statement: >
      A fixture statement for the expired rule.
  - id: STL-NOEVIDENCE-001
    geltung: firstmate
    verbindlichkeit: kontext
    anker: [L01]
    quelle: grundsatz:1
    leser: retrieval
    verfall: null
    trigger: >
      A fixture trigger for the unproven rule.
    statement: >
      A fixture statement for the unproven rule.
  - id: STL-COVERED-001
    geltung: firstmate
    verbindlichkeit: kontext
    anker: [L01]
    quelle: grundsatz:1
    leser: retrieval
    verfall: null
    trigger: >
      A fixture trigger for the golden-covered rule.
    statement: >
      A fixture statement for the golden-covered rule.
  - id: STL-DELIVERED-001
    geltung: firstmate
    verbindlichkeit: kontext
    anker: [L01]
    quelle: grundsatz:1
    leser: retrieval
    verfall: null
    trigger: >
      A fixture trigger for the delivered rule.
    statement: >
      A fixture statement for the delivered rule.
  - id: STL-KERN-001
    geltung: firstmate
    verbindlichkeit: kern
    anker: [L01]
    quelle: grundsatz:1
    leser: retrieval
    verfall: null
    trigger: >
      A fixture trigger for a kern rule, never judged by the kontext rule.
    statement: >
      A fixture statement for a kern rule.
YAML

  {
    printf '# fixture golden retrieval rows\n'
    printf 'irrelevanter Prompt\tSTL-COVERED-001\n'
  } > "$d/tests/regel-retrieval-golden.tsv"

  printf 'STL-DELIVERED-001\n' > "$d/state/writ-fm/.delivered-fixture-session"

  # jung-tor: one entry, 10 days old - too young to judge at all, even though
  # the single entry is a real catch (rot, no escape) that would otherwise
  # prove the gate healthy.
  tor_zeile "$(tage_vor 10)" jung-tor rot - > "$d/state/tor-log/jung-tor.jsonl"

  # fehlalarm-tor: old enough (earliest 60 days back), one rot inside the
  # 45-day window and it is the only rot ever - and it was escaped.
  {
    tor_zeile "$(tage_vor 60)" fehlalarm-tor gruen -
    tor_zeile "$(tage_vor 10)" fehlalarm-tor rot benutzt
  } > "$d/state/tor-log/fehlalarm-tor.jsonl"

  # keinerot-tor: old enough, never a single rot verdict.
  {
    tor_zeile "$(tage_vor 60)" keinerot-tor gruen -
    tor_zeile "$(tage_vor 5)" keinerot-tor gruen -
  } > "$d/state/tor-log/keinerot-tor.jsonl"

  # gesund-tor: old enough, a real catch (rot, no escape) inside the window -
  # must never be listed under either candidate reason.
  {
    tor_zeile "$(tage_vor 60)" gesund-tor gruen -
    tor_zeile "$(tage_vor 10)" gesund-tor rot -
  } > "$d/state/tor-log/gesund-tor.jsonl"
}

lauf() {
  local root="$1"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$STL" 2>&1
}

ROOT1="$(fm_test_tmproot fm-streichliste)"
baue_fixture "$ROOT1"
OUT="$(lauf "$ROOT1")"

# --- 1./4. Tore --------------------------------------------------------------
assert_contains "$OUT" "jung: Tor jung-tor zu jung fuer ein Urteil (seit " \
  "a Tor younger than the window must be reported as too young to judge"
assert_not_contains "$OUT" "streichkandidat: Tor jung-tor" \
  "a too-young Tor must never be listed as a strike candidate"

# --- 2. false-alarm profile --------------------------------------------------
assert_contains "$OUT" "streichkandidat: Tor fehlalarm-tor - reines Fehlalarm-Profil" \
  "a Tor whose only denials were all escaped must be a strike candidate"
assert_contains "$OUT" "Schattenmodus: Flag state/.tor-fehlalarm-tor-scharf entfernen + 30 Tage Log beobachten" \
  "the false-alarm candidate must name the shadow-mode remedy"
assert_not_contains "$OUT" "streichkandidat: Tor fehlalarm-tor - keine Verweigerung" \
  "the false-alarm Tor has a recent denial, so the zero-denial reason must not also fire"

# --- 3. zero denials in the window -------------------------------------------
assert_contains "$OUT" "streichkandidat: Tor keinerot-tor - keine Verweigerung (rot) in den letzten 45 Tagen" \
  "a Tor with no denial at all in the window must be a strike candidate"
assert_not_contains "$OUT" "streichkandidat: Tor keinerot-tor - reines Fehlalarm-Profil" \
  "a Tor with zero denials ever has no false-alarm profile to report"

# --- 4. a real catch clears the Tor entirely ---------------------------------
assert_not_contains "$OUT" "Tor gesund-tor" \
  "a Tor with a real, unescaped catch must not appear anywhere in the list"

pass "fm-streichliste.sh judges Tore correctly (young / false-alarm / zero-denial / healthy)"

# --- 5. expired rule ----------------------------------------------------------
assert_contains "$OUT" "streichkandidat: Regel STL-EXPIRED-001 (regeln/test.yaml) - status=abgelaufen. fm-regeln streich STL-EXPIRED-001" \
  "an expired rule must be a strike candidate naming fm-regeln streich"

# --- 6. delivery evidence -----------------------------------------------------
assert_contains "$OUT" "streichkandidat: Regel STL-NOEVIDENCE-001 (regeln/test.yaml) - kontext ohne Golden-Row und ohne Zustell-Treffer-Beleg. fm-regeln streich STL-NOEVIDENCE-001" \
  "a kontext rule with neither golden row nor delivery hit must be a strike candidate"
assert_not_contains "$OUT" "streichkandidat: Regel STL-COVERED-001" \
  "a rule named in the golden retrieval file must not be a strike candidate"
assert_not_contains "$OUT" "streichkandidat: Regel STL-DELIVERED-001" \
  "a rule with a delivery-hit in a .delivered-* file must not be a strike candidate"

# --- 7. kern rules are exempt -------------------------------------------------
assert_not_contains "$OUT" "STL-KERN-001" \
  "a kern rule must never be judged by the kontext delivery-evidence rule"

pass "fm-streichliste.sh judges Regeln correctly (expired / delivery evidence / kern exemption)"

# --- 8. missing python3 degrades loudly, never crashes -----------------------
TMP8="$(fm_test_tmproot fm-streichliste-nopy)"
FAKEBIN="$(fm_fakebin "$TMP8")"
for tool in bash dirname; do
  ln -s "$(command -v "$tool")" "$FAKEBIN/$tool"
done
rc=0
out8=$(PATH="$FAKEBIN" FM_ROOT_OVERRIDE="$ROOT1" FM_HOME="$ROOT1" "$STL" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "a missing python3 must not fail the script (exit $rc)"
assert_contains "$out8" "python3 not found" \
  "a missing python3 must print a loud, named note instead of crashing"
pass "fm-streichliste.sh degrades loudly (never crashes) when python3 is missing"

echo "fm-streichliste.test.sh: all checks passed"
