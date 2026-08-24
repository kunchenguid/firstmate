#!/usr/bin/env bash
# End-to-end tests for the board card completeness guard: every open captain
# hold of the main home and every registered officer home needs exactly one
# card named <id>.md under data/brett-karten/. Missing cards and orphan cards
# wake loudly with id and home, a card without a board-recognized answer way
# wakes on its own, closed rows and other hold kinds stay quiet, unreadable
# sources are their own finding instead of a silent skip, and silence means
# the supply matched. The check never writes cards or backlogs.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-brett-karten-vollstaendigkeit.sh"
TMP_ROOT=$(fm_test_tmproot fm-brett-karten-vollstaendigkeit)

make_home() {  # <name> -> home path on stdout
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/brett-karten" "$home/state" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

write_hold() {  # <home> <id> [hold-kind] [checkbox]
  local home=$1 id=$2 kind=${3:-captain} box=${4:- }
  printf -- '- [%s] %s - Testposten %s (repo: x) (hold: test) (hold-kind: %s)\n' \
    "$box" "$id" "$id" "$kind" >> "$home/data/backlog.md"
}

write_card() {  # <home> <id> : supplies a card WITH a board-recognized answer way
  {
    printf '# Karte %s · Test\n' "$2"
    printf '\n'
    printf '## Lage\n'
    printf '\n'
    printf 'Testlage.\n'
    printf '\n'
    printf '## A · Weg eins\n'
    printf '\n'
    printf 'Folge.\n'
  } > "$1/data/brett-karten/$2.md"
}

register_officer() {  # <main-home> <name> <officer-home>
  printf -- '- %s - Testoffizier (home: %s; scope: test; projects: x; added 2026-08-24)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

run_check() {  # <main-home> -> one sweep's stdout
  FM_HOME="$1" "$CHECK" check
}

# --- missing card: loud, named with id and home --------------------------------

H1=$(make_home h1)
write_hold "$H1" posten-mit-karte
write_hold "$H1" posten-ohne-karte
write_card "$H1" posten-mit-karte

out=$(run_check "$H1")
case $out in
  *"1 fehlt(posten-ohne-karte@haupt)"*) pass "ok - missing card named with id and haupt" ;;
  *) fail "expected fehlt finding, got: $out" ;;
esac
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "the sweep printed more than one line: $out"

# The matched card must not appear anywhere in the report.
case $out in *posten-mit-karte*) fail "the supplied card was reported anyway: $out" ;; esac

# --- silence when everything matches -------------------------------------------

write_card "$H1" posten-ohne-karte
out=$(run_check "$H1")
[ -z "$out" ] || fail "a complete supply was not silent: $out"

# Only OPEN captain holds need cards: closed rows, other hold kinds, and a
# title that merely mentions captains must never demand one.
write_hold "$H1" geschlossener-posten captain x
write_hold "$H1" geparkter-posten parked
write_hold "$H1" externer-posten external
write_hold "$H1" future-posten future
write_hold "$H1" trick-posten parked
printf -- '- [ ] kapitaen-trick - Titel nennt Captain und hold-kind: captain im Text nicht als Feld\n' >> "$H1/data/backlog.md"
out=$(run_check "$H1")
[ -z "$out" ] || fail "non-captain or closed rows demanded cards: $out"

# --- orphan card: loud even when the supply otherwise matches -------------------

H3=$(make_home h3)
write_hold "$H3" lebendiger-posten
write_card "$H3" lebendiger-posten
write_card "$H3" verwaiste-alte-karte

out=$(run_check "$H3")
case $out in
  *"1 waise(verwaiste-alte-karte)"*) pass "ok - orphan card named loudly" ;;
  *) fail "expected waise finding, got: $out" ;;
esac
case $out in *fehlt*) fail "the matched card was reported as missing: $out" ;; esac

# A gap and an orphan land together on the one line.
rm -f "$H3/data/brett-karten/lebendiger-posten.md"
out=$(run_check "$H3")
case $out in
  *"1 fehlt(lebendiger-posten@haupt)"*"1 waise(verwaiste-alte-karte)"*|\
    *"1 waise(verwaiste-alte-karte)"*"1 fehlt(lebendiger-posten@haupt)"*)
    pass "ok - gap and orphan reported together" ;;
  *) fail "expected combined fehlt and waise, got: $out" ;;
esac

# --- answer way: a card the board cannot offer options on is loud ---------------

aw_probe() {  # <slug> <section-line> <ja|nein> : does the board recognize this heading?
  local slug=$1 line=$2 want=$3 h out
  h=$(make_home "aw-$slug")
  printf '# Karte kandidat · Test\n\n## Lage\nLage.\n\n%s\n\nFolge.\n' "$line" \
    > "$h/data/brett-karten/kandidat.md"
  out=$(run_check "$h")
  if [ "$want" = ja ]; then
    case $out in
      *karte-ohne-antwortweg*) fail "the board would recognize '$line', the guard did not: $out" ;;
      *) pass "ok - '$line' carries an answer way" ;;
    esac
  else
    case $out in
      *"karte-ohne-antwortweg(kandidat)"*) pass "ok - '$line' offers no answer way" ;;
      *) fail "expected karte-ohne-antwortweg for '$line', got: $out" ;;
    esac
  fi
}

H4A=$(make_home h4a)
write_hold "$H4A" frage-mit-weg
write_hold "$H4A" frage-ohne-weg
write_card "$H4A" frage-mit-weg
printf '# Karte frage-ohne-weg · Test\n\n## Lage\nNur Zahlenwege.\n\n## 1 · Erster Weg\nFolge.\n' \
  > "$H4A/data/brett-karten/frage-ohne-weg.md"

out=$(run_check "$H4A")
case $out in
  *"1 karte-ohne-antwortweg(frage-ohne-weg)"*) pass "ok - optionless card named loudly" ;;
  *) fail "expected karte-ohne-antwortweg finding, got: $out" ;;
esac
case $out in
  *frage-mit-weg* | *fehlt* | *waise*) fail "the supplied card was dragged into the finding: $out" ;;
esac

# Heading shapes, byte-for-byte against the board's own collector: recognized
# (silent) versus unrecognized (loud).
aw_probe kompakt '## A·OhneLeerzeichen' ja
aw_probe mehrfachleer '##   B · Mit Leerzeichen' ja
aw_probe empfehlung '## C · Nur Empfehlung [Empfehlung]' ja
aw_probe zahl '## 1 · Nummerierter Weg' nein
aw_probe klein '## a · Kleinbuchstabe' nein
aw_probe doppel '## AB · Doppelbuchstabe' nein
aw_probe ohneleer '##A · Kein Leerzeichen nach der Raute' nein

# --- officer homes: same contract, labeled with the registry name ---------------

M5=$(make_home m5)
O5=$(make_home o5)
write_hold "$O5" offizier-posten
register_officer "$M5" sm-test "$O5"

out=$(run_check "$M5")
case $out in
  *"1 fehlt(offizier-posten@sm-test)"*) pass "ok - officer-home gap named with its home" ;;
  *) fail "expected officer fehlt finding, got: $out" ;;
esac

write_card "$M5" offizier-posten
out=$(run_check "$M5")
[ -z "$out" ] || fail "an officer card satisfied the guard only partially: $out"

# An open captain hold in BOTH homes is one card keyed by the shared id.
DUP=dup-posten-id
write_hold "$M5" "$DUP"
out=$(run_check "$M5")
case $out in
  *"1 fehlt($DUP@haupt)"*) pass "ok - shared id reported per home" ;;
  *) fail "expected shared-id fehlt, got: $out" ;;
esac
write_card "$M5" "$DUP"
out=$(run_check "$M5")
[ -z "$out" ] || fail "one card did not satisfy both homes: $out"

# Officer closed rows need no card either.
write_hold "$O5" offizier-erledigt captain x
out=$(run_check "$M5")
[ -z "$out" ] || fail "a closed officer row demanded a card: $out"

# --- unreadable sources: their own finding, never a silent skip -----------------

# A registered officer home that does not exist is loud, while a healthy
# sibling officer stays clean on the very same sweep.
M6=$(make_home m6)
O6=$(make_home o6)
write_hold "$O6" gesunder-offizier-posten
write_card "$M6" gesunder-offizier-posten
register_officer "$M6" sm-ok "$O6"
register_officer "$M6" sm-nirvana "$TMP_ROOT/nirgends-ein-heim"

out=$(run_check "$M6")
case $out in
  *"FEHLER(heim-fehlt-sm-nirvana)"*) pass "ok - missing officer home named loudly" ;;
  *) fail "expected heim-fehlt finding, got: $out" ;;
esac
case $out in *sm-ok*|*gesunder-offizier-posten*) fail "the healthy officer was dragged into the finding: $out" ;; esac

# An unreadable backlog is loud; a broken symlink fails readably everywhere,
# including as root.
M7=$(make_home m7)
O7=$(make_home o7)
rm "$O7/data/backlog.md"
ln -s nirgendwo-hin "$O7/data/backlog.md"
register_officer "$M7" sm-kaputt "$O7"

out=$(run_check "$M7")
case $out in
  *"FEHLER(backlog-unlesbar-sm-kaputt)"*) pass "ok - unreadable officer backlog named loudly" ;;
  *) fail "expected backlog-unlesbar finding, got: $out" ;;
esac

# A main backlog that cannot be read is loud too.
H8=$(make_home h8)
mv "$H8/data/backlog.md" "$H8/data/backlog.md.real"
ln -s nirgendwo-hin "$H8/data/backlog.md"
out=$(run_check "$H8")
case $out in
  *"FEHLER(backlog-unlesbar-haupt)"*) pass "ok - unreadable main backlog named loudly" ;;
  *) fail "expected haupt backlog-unlesbar finding, got: $out" ;;
esac

# A brett-karten path that exists but is no directory kills the comparison
# loudly instead of reporting every hold as missing.
H9=$(make_home h9)
write_hold "$H9" unsichtbarer-posten
rmdir "$H9/data/brett-karten"
printf 'kein ordner\n' > "$H9/data/brett-karten"

out=$(run_check "$H9")
case $out in
  *"FEHLER(karten-kein-ordner)"*) pass "ok - corrupt card path named loudly" ;;
  *) fail "expected karten-kein-ordner finding, got: $out" ;;
esac
case $out in *fehlt*|*waise*) fail "the comparison ran on an unusable directory: $out" ;; esac

# An unreadable card directory is loud as well (root reads everything, so the
# case is skipped there).
if [ "$(id -u)" = 0 ]; then
  echo "skip: chmod-Fall fuer unlesbaren Kartenordner gilt nicht als root"
else
  H10=$(make_home h10)
  write_hold "$H10" abgedunkelter-posten
  chmod 000 "$H10/data/brett-karten"
  out=$(run_check "$H10")
  case $out in
    *"FEHLER(karten-unlesbar)"*) pass "ok - unreadable card directory named loudly" ;;
    *) fail "expected karten-unlesbar finding, got: $out" ;;
  esac
  case $out in *fehlt*|*waise*) fail "findings were derived from an unreadable directory: $out" ;; esac
  chmod 755 "$H10/data/brett-karten"
fi

# --- arm, disarm, shim bytes, selftest ------------------------------------------

H11=$(make_home h11)
rm "$H11/data/backlog.md"
FM_HOME="$H11" "$CHECK" --selftest >/dev/null 2>&1 \
  && fail "selftest passed without any backlog present"
FM_HOME="$H11" "$CHECK" --selftest 2>&1 | grep -q "SELFTEST FAIL" \
  || fail "selftest failure did not name itself"

register_officer "$H11" sm-leer "$TMP_ROOT/nirvana-selftest"
FM_HOME="$H11" "$CHECK" --selftest >/dev/null 2>&1 \
  && fail "selftest passed with a missing officer home"
FM_HOME="$H11" "$CHECK" --selftest 2>&1 | grep -q "Offiziers-Heim.*fehlt" \
  || fail "selftest did not name the missing officer home"
sed -i '/sm-leer/d' "$H11/data/secondmates.md"
cat > "$H11/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
FM_HOME="$H11" "$CHECK" --selftest >/dev/null \
  || fail "selftest failed with all sources present"

# The selftest also guards the answer way: an optionless card is a red case.
printf '# Karte rote-karte · Test\n\n## Lage\nLage.\n\n## 1 · Zahlweg\nFolge.\n' \
  > "$H11/data/brett-karten/rote-karte.md"
FM_HOME="$H11" "$CHECK" --selftest >/dev/null 2>&1 \
  && fail "selftest passed with an optionless card present"
FM_HOME="$H11" "$CHECK" --selftest 2>&1 | grep -q "rote-karte.*Antwortweg" \
  || fail "selftest did not name the optionless card"
rm "$H11/data/brett-karten/rote-karte.md"
FM_HOME="$H11" "$CHECK" --selftest >/dev/null \
  || fail "selftest failed after the optionless card was removed"

out=$(FM_HOME="$H11" "$CHECK" arm)
[ "$out" = "armed: state/brett-karten-vollstaendigkeit.check.sh" ] \
  || fail "unexpected arm output: $out"
SHIM="$H11/state/brett-karten-vollstaendigkeit.check.sh"
[ -f "$SHIM" ] && [ ! -L "$SHIM" ] || fail "arm left no regular shim"
[ "$(stat -c %a "$SHIM")" = 700 ] || fail "shim is not mode 0700"
grep -q "export FM_HOME=$H11\$" "$SHIM" || fail "shim does not pin the resolved home"
TRUST="$H11/state/brett-karten-vollstaendigkeit.check-trust"
[ -f "$TRUST" ] || fail "arm wrote no trust binding"
hash=$(shasum -a 256 "$SHIM" 2>/dev/null | awk '{print $1}') \
  || hash=$(sha256sum "$SHIM" | awk '{print $1}')
grep -q "$hash" "$TRUST" || fail "trust binding does not match the shim bytes"

out=$(FM_HOME="$H11" "$CHECK" arm)
[ "$out" = "armed: state/brett-karten-vollstaendigkeit.check.sh" ] \
  || fail "re-arm was not idempotent: $out"

# The armed shim really runs this check against the pinned home: a held task
# without a card comes out of the shim itself.
write_hold "$H11" shim-sichtbarer-posten
shim_out=$(FM_STATE_OVERRIDE="$H11/state" bash "$SHIM")
case $shim_out in
  *"1 fehlt(shim-sichtbarer-posten@haupt)"*) pass "ok - armed shim reports through to its check" ;;
  *) fail "armed shim did not run the completeness check, got: $shim_out" ;;
esac

out=$(FM_HOME="$H11" "$CHECK" disarm)
[ "$out" = "disarmed: state/brett-karten-vollstaendigkeit.check.sh" ] \
  || fail "unexpected disarm output: $out"
[ ! -e "$SHIM" ] && [ ! -e "$TRUST" ] || fail "disarm left check artifacts behind"

# --- help surface ----------------------------------------------------------------

"$CHECK" --help >/dev/null || fail "--help failed"
"$CHECK" --help | grep -q "arm" || fail "--help does not mention arming"
"$CHECK" --help | grep -q "brett-karten" || fail "--help does not name its subject"

pass "ok - alle brett-karten-vollstaendigkeit Faelle bestanden"
