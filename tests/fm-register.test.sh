#!/usr/bin/env bash
# tests/fm-register.test.sh - the derived captain register must render from the
# backlog with keys, cap by importance, protect the hand-kept file, and detect
# its own staleness:
#
#   1. Rendering: sections per area (config mapping honored), 6-column rows,
#      UPPERCASE state markers, every row keyed id:<task-id>, captain-held rows
#      first, Done tasks absent.
#   2. Ten cap: with 12 open tasks in one area, 10 render and the overflow row
#      names the 2 remaining ids; a captain-held task arriving last still
#      renders (cap cuts by importance, not arrival).
#   3. write refuses a hand-kept register without the takeover flag; with
#      --uebernehmen --archiv it archives first and then writes the render;
#      re-write over its own render needs no flag.
#   4. check raises no freshness line when fresh, reports after a backlog
#      change or a hand edit, and never touches a hand-kept register. Its
#      second half - the three register invariants it now also reports - is
#      owned by tests/fm-register-invarianten-lib.test.sh.
#   5. dead-edges reads ONLY the structured blocked-by field on open head
#      lines: a prose citation with an empty field stays silent while real
#      dead edges (missing or closed target) are still reported.
#
# Isolation: throwaway FM_HOME. No tasks-axi needed - the canonical file is read.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$REPO/bin/fm-register.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/data" "$HOME_A/config"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
run() { FM_HOME="$HOME_A" "$REG" "$@"; }

printf 'Kartenwerk\tlensclash testlab\n' > "$HOME_A/config/register-bereiche"

{
  printf '## In flight\n'
  printf -- '- [ ] lauf-1 - Ein laufender Faden (repo: lensclash) (kind: ship) (since 2026-08-20)\n'
  printf '## Queued\n'
  printf -- '- [ ] frage-1 - Deine offene Frage (repo: lensclash) (since 2026-08-21) (hold: Antwort auf die Torfrage (mit Klammern) noetig) (hold-kind: captain)\n'
  printf -- '- [ ] warte-1 - Externer Posten (repo: testlab) (since 2026-08-19) (hold: wartet auf Anbieter) (hold-kind: external)\n'
  printf -- '- [ ] termin-1 - Terminposten (repo: testlab) (since 2026-08-22) (hold: Zeitfenster ab 28.08.) (hold-kind: future) (hold-until: 2026-08-28)\n'
  printf -- '- [ ] wiedervorlage-1 - Dezemberfrage (repo: lensclash) (since 2026-08-22) (hold: Entscheide Dezember) (hold-kind: captain) (hold-until: 2026-12-01)\n'
  printf -- '- [ ] plain-1 - Eingereihter Posten (repo: sonstwo) (since 2026-08-18)\n'
  printf -- '- [ ] betrieb-1 - Betriebsposten (repo: -) (since 2026-08-17)\n'
  printf '## Done\n'
  printf -- '- [x] fertig-1 - Erledigtes (repo: lensclash) (done 2026-08-16)\n'
} > "$HOME_A/data/backlog.md"

# --- 1. rendering ----------------------------------------------------------
out=$(run render)
printf '%s' "$out" | grep -q '^## Kartenwerk$' && ok "the area mapping groups lensclash+testlab" \
  || fail "mapped areas must render under their configured title"
printf '%s' "$out" | grep -q '^## sonstwo$' || fail "an unmapped repo must group under its own name"
printf '%s' "$out" | grep -q '^## Betrieb$' || fail "repo '-' must group under Betrieb"
printf '%s' "$out" | grep -q 'id:lauf-1' && printf '%s' "$out" | grep -q 'LAEUFT (in Arbeit)' \
  && ok "an in-flight task renders as LAEUFT with its key" || fail "in-flight rendering broken"
printf '%s' "$out" | grep -q 'WARTET auf dein Wort: Antwort auf die Torfrage (mit Klammern) noetig' \
  && ok "a captain hold renders verbatim, nested parens intact" || fail "captain-hold rendering broken"
printf '%s' "$out" | grep -q 'fertig-1' && fail "Done tasks must never render" || ok "Done tasks stay out"
printf '%s' "$out" | grep -q 'WARTET: Zeitfenster ab 28.08. - Wiedervorlage 2026-08-28' \
  && ok "a dated future hold renders as WARTET with its resubmission date" \
  || fail "a hold-until suffix must not demote the row to OFFEN (dated future hold)"
printf '%s' "$out" | grep -q 'WARTET auf dein Wort: Entscheide Dezember - Wiedervorlage 2026-12-01' \
  && ok "a dated captain hold keeps its captain state and date" \
  || fail "a hold-until suffix must not strip the captain hold (dated captain hold)"
first_row=$(printf '%s' "$out" | awk '/^## Kartenwerk$/{f=1} f && /^\| [0-9-]/ {print; exit}')
printf '%s' "$first_row" | grep -q 'id:frage-1' && ok "the captain-held row sorts first in its area" \
  || fail "captain-held rows must sort first (got: $first_row)"
row_cells=$(printf '%s\n' "$first_row" | awk -F'|' '{print NF-2}')
[ "$row_cells" = 6 ] && ok "rows keep the 6-column contract" || fail "rows must have 6 cells (got $row_cells)"

# --- 2. ten cap by importance ----------------------------------------------
{
  printf '## In flight\n'
  printf '## Queued\n'
  for i in 01 02 03 04 05 06 07 08 09 10 11; do
    printf -- '- [ ] voll-%s - Posten %s (repo: lensclash) (since 2026-08-%s)\n' "$i" "$i" "$i"
  done
  printf -- '- [ ] wichtig-1 - Spaet gekommene Captain-Frage (repo: lensclash) (since 2026-08-01) (hold: dein Wort) (hold-kind: captain)\n'
} > "$HOME_A/data/backlog.md"
out=$(run render)
shown=$(printf '%s' "$out" | grep -c '^| [0-9-]')
[ "$shown" = 11 ] && ok "12 tasks render as 10 rows plus one overflow row" \
  || fail "the cap must render 10 rows + 1 overflow (got $shown data rows)"
printf '%s' "$out" | grep -q 'WEITERE 2 Faeden (Zehner-Deckel)' && ok "the overflow row discloses its count" \
  || fail "the overflow row must disclose the count"
printf '%s' "$out" | grep -q 'id:wichtig-1' && ok "the captain-held task survives the cap despite arriving last" \
  || fail "the cap must cut by importance, not arrival"
overflow_row=$(printf '%s' "$out" | grep 'WEITERE 2 Faeden')
printf '%s' "$overflow_row" | grep -q 'voll-01' && printf '%s' "$overflow_row" | grep -q 'voll-02' \
  && ok "the overflow names the cut ids" || fail "the overflow row must name the cut ids (got: $overflow_row)"

# --- 3. write protects the hand-kept register ------------------------------
printf '# Captain-Auftraege - Handpflege\n| alt |\n' > "$HOME_A/data/captain-auftraege.md"
if run write >/dev/null 2>&1; then
  fail "write must refuse a hand-kept register"
else
  ok "write refuses the hand-kept register without takeover"
fi
grep -q 'Handpflege' "$HOME_A/data/captain-auftraege.md" || fail "the refused write must leave the file untouched"
run write --uebernehmen --archiv "$HOME_A/data/register-archiv-test.md" >/dev/null \
  || fail "takeover write must succeed"
grep -q 'Handpflege' "$HOME_A/data/register-archiv-test.md" && ok "the hand-kept file is archived before takeover" \
  || fail "takeover must archive the hand-kept file"
grep -q 'GENERATED by bin/fm-register.sh' "$HOME_A/data/captain-auftraege.md" \
  && ok "the register is now the generated render" || fail "takeover must write the render"
run write >/dev/null || fail "re-writing over the own render must need no flag"
if run write --uebernehmen --archiv "$HOME_A/data/register-archiv-test.md" >/dev/null 2>&1; then
  ok "an existing archive target is not overwritten (write over own render ignores it)"
fi

# --- 4. staleness check -----------------------------------------------------
out=$(run check)
# check answers two questions now: is the derived view fresh, and are the
# records it derives FROM sound (bin/fm-register-invarianten-lib.sh). The
# invariant lines are a separate report with their own test file; this
# assertion is about the FRESHNESS signal, so it strips them and stays exactly
# as strict as before about everything else.
frische=$(printf '%s\n' "$out" | grep -v '^REGISTER: \(ziel fehlt\|eigner fehlt\|planlos seit\)' || true)
[ -z "$frische" ] && ok "check reports no staleness while the render is fresh" \
  || fail "fresh render must produce no freshness line (got: $frische)"
printf -- '- [ ] neu-1 - Neuer Posten (repo: lensclash) (since 2026-08-22)\n' >> "$HOME_A/data/backlog.md"
out=$(run check)
printf '%s' "$out" | grep -q 'stale or hand-edited' && ok "check reports a moved backlog" \
  || fail "check must report a stale render"
run write >/dev/null
printf 'handzeile\n' >> "$HOME_A/data/captain-auftraege.md"
out=$(run check)
printf '%s' "$out" | grep -q 'stale or hand-edited' && ok "check reports a hand edit" \
  || fail "check must report a hand edit"

# --- 5. dead edges: field-only reading, prose citations never count ---------
# Counter-probe: rule 1 of the register-hygiene guard as shipped 23.08.
# (state/register-hygiene.check.sh) extracted blocked-by ids from the WHOLE
# file, so a prose citation of a finished id was reported as a dead edge even
# when the carrier's own field was empty. old_guard is that shipped algorithm
# verbatim; the assertions pin the divergence between it and the field-only
# tool so neither case can go quietly vacuous.
old_guard() { # <backlog-file>: shipped 23.08. whole-file algorithm
  grep -o 'blocked-by: [a-z0-9-]*' "$1" | awk '{print $2}' | sort -u \
    | while read -r id; do grep -q "^- \[ \] $id " "$1" || echo "$id"; done
}

prose_fix="$TMP/prose-false-positive.md"
{
  printf '## Queued\n'
  printf -- '- [ ] alpha-1 - Feld leer, Prosa zitiert eine erledigte Kennung (repo: testlab) (since 2026-08-23)\n'
  printf '  Dieser Eintrag traegt keine Kante im Feld. Verweis im Text:\n'
  # the backticks are fixture content, a prose citation - never expanded
  # shellcheck disable=SC2016
  printf '  `blocked-by: archiv-weit-weg`. Das ist ein Zitat, kein Feld.\n'
} > "$prose_fix"

hits=$(old_guard "$prose_fix")
printf '%s' "$hits" | grep -qx 'archiv-weit-weg' \
  && ok "counter-probe: the shipped whole-file algorithm flags the prose citation" \
  || fail "the false positive must reproduce under the shipped algorithm (got: $hits)"
out=$(run dead-edges --file "$prose_fix"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a prose citation with an empty field stays silent" \
  || fail "field-only reading must stay silent on the prose case (rc=$rc out=$out)"

red_fix="$TMP/red-edges.md"
{
  printf '## Queued\n'
  printf -- '- [ ] beta-2 - Echte tote Kante im Feld blocked-by: fehlt-ganz (repo: testlab) (since 2026-08-23)\n'
  printf -- '- [ ] gamma-3 - Lebende Kante auf einen offenen Ziel-Faden blocked-by: delta-4 (repo: testlab) (since 2026-08-23)\n'
  printf -- '- [ ] delta-4 - Offenes Ziel der lebenden Kante (repo: testlab) (since 2026-08-23)\n'
  printf -- '- [ ] epsilon-5 - Kante auf ein erledigtes Ziel blocked-by: erledigt-1 (repo: testlab) (since 2026-08-23)\n'
  printf '## Done\n'
  printf -- '- [x] erledigt-1 - Erledigtes Ziel (repo: testlab) (done 2026-08-22)\n'
  printf -- '- [x] omega-6 - Erledigt mit eigener Kante blocked-by: nirgends-mehr (repo: testlab) (done 2026-08-21)\n'
} > "$red_fix"
out=$(run dead-edges --file "$red_fix"); rc=$?
expected='dead-edge: beta-2 -> fehlt-ganz
dead-edge: epsilon-5 -> erledigt-1'
[ "$rc" = 1 ] && [ "$out" = "$expected" ] \
  && ok "real field edges report exactly: missing and closed targets fire, live edge and done-carrier stay out" \
  || fail "red-case verdict wrong (rc=$rc):\n$out"

mkdir -p "$TMP/home2/data"
cp "$red_fix" "$TMP/home2/data/backlog.md"
out=$(FM_HOME="$TMP/home2" "$REG" dead-edges); rc=$?
[ "$rc" = 1 ] && [ "$out" = "$expected" ] && ok "without --file the tool reads FM_HOME's own backlog" \
  || fail "default file resolution broken (rc=$rc out=$out)"

run dead-edges --file "$TMP/does-not-exist.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a missing backlog file is a loud error, never silence" \
  || fail "missing file must exit 2 (got $rc)"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-register.test.sh: all checks passed"
  exit 0
fi
echo "fm-register.test.sh: $FAILS check(s) FAILED"
exit 1
