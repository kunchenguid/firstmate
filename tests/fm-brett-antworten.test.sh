#!/usr/bin/env bash
# End-to-end tests for the captain-brett answer binding: a board card wakes,
# is recorded key-exactly at its captain-held post through the one keyed
# intake, and is receipted back onto the board - with replacement chains
# resolved to the newest word, officer-home posts reported instead of recorded
# abroad, unknown keys loud, and malformed cards never silently skipped.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-brett-antworten.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-brett-antworten)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

write_tasks_config() {  # <home>
  local home=$1
  sed 's/^done_keep = .*/done_keep = 100/' "$ROOT/.tasks.toml" > "$home/.tasks.toml" \
    || fail "could not write the fixture backlog config"
}

make_home() {  # <name> -> home path on stdout
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data/brett-antworten/quittungen" "$home/state" "$home/config"
  mkdir -p "$home/projects/captain-brett/bin"
  write_tasks_config "$home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The receipt contract this suite asserts against: quittungen/<id>.json under
# CAPTAIN_BRETT_ANTWORTEN, written by the brett tool and nothing else. One
# opt-in case at the end drives the real project tool instead of this stub.
install_quittung_stub() {  # <home>
  cat > "$1/projects/captain-brett/bin/brett-quittung" <<'SH'
#!/usr/bin/env bash
set -eu
id=
for a in "$@"; do
  case $a in
    --*) ;;
    *) [ -n "$id" ] || id=$a ;;
  esac
done
[ -n "$id" ] || { echo "stub: no answer id given" >&2; exit 1; }
d="$CAPTAIN_BRETT_ANTWORTEN/quittungen"
mkdir -p "$d"
printf '{"id": "%s", "stub": true}\n' "$id" > "$d/$id.json"
SH
  chmod +x "$1/projects/captain-brett/bin/brett-quittung"
}

ts_offset() {  # <date-d-arg> -> ISO timestamp with colon offset
  date -d "$1" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}

write_card() {  # <home> <antwort-id> <entscheid> <wort> [ersetz-id] [art] [schonfrist] [bemerkung]
  local home=$1 id=$2 entscheid=$3 wort=$4
  local repl=${5:--} art=${6:-wahl} grace=${7:-} bem=${8:-}
  [ -n "$grace" ] || grace=$(ts_offset '-120 seconds')
  {
    printf '# Captain-Antwort %s — test\n' "$entscheid"
    printf '\n'
    printf 'antwort-id: %s\n' "$id"
    printf 'entscheid: %s\n' "$entscheid"
    printf 'art: %s\n' "$art"
    printf 'option: A\n'
    printf 'vertagt-bis: -\n'
    printf 'gesendet: %s\n' "$(ts_offset '-125 seconds')"
    printf 'schonfrist-bis: %s\n' "$grace"
    printf 'ersetzt: %s\n' "$repl"
    printf 'quelle: test\n'
    printf '\n'
    printf '## Wort des Captains\n'
    printf '\n'
    printf '%s\n' "$wort"
    printf '\n'
    if [ -n "$bem" ]; then
      printf '## Bemerkung\n'
      printf '\n'
      printf '%s\n' "$bem"
      printf '\n'
    fi
    printf '## Zustellnachweis\n'
  } > "$home/data/brett-antworten/$id.md"
}

hold_task() {  # <home> <task-id>
  PATH="$(fm_fakebin "$1"):$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    "$HOLD" hold "$2" --reason "test-hold" --title "Testposten $2" >/dev/null \
    || fail "could not hold $2 in fixture home"
}

run_check() {  # <home> -> one sweep's stdout
  local home=$1
  PATH="$(fm_fakebin "$home"):$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CHECK" check
}

register_officer() {  # <main-home> <name> <officer-home>
  local main=$1 name=$2 ohome=$3
  printf -- '- %s - Testoffizier (home: %s; scope: test; projects: x; added 2026-08-24)\n' \
    "$name" "$ohome" >> "$main/data/secondmates.md"
}

receipt_exists() {  # <home> <antwort-id>
  [ -f "$1/data/brett-antworten/quittungen/$2.json" ]
}

# --- main-home post: recorded key-exactly, receipted, replay-safe -------------

H1=$(make_home h1)
install_quittung_stub "$H1"
hold_task "$H1" brett-test-posten
ID1=20260824T100000-brett-test-posten-aaaa11
write_card "$H1" "$ID1" brett-test-posten "Option A - das Testwort des Captains"

out=$(run_check "$H1")
case $out in
  *"1 verbucht($ID1"*) pass "ok - main-home answer recorded and woken" ;;
  *) fail "expected verbucht report, got: $out" ;;
esac
grep -q "^- \[x\] brett-test-posten " "$H1/data/backlog.md" \
  || fail "held row was not closed by the answer"
grep -q "das Testwort des Captains" "$H1/data/backlog.md" \
  || fail "captain's words missing from the task body"
receipt_exists "$H1" "$ID1" || fail "recorded card was not receipted"

out=$(run_check "$H1")
[ -z "$out" ] || fail "a receipted card fired again: $out"

# Crash window between feeding and receipting: removing the receipt replays the
# same digest through the intake, which answers closed again, and only the
# receipt reruns - the task body must not grow a second resolution block.
rm -f "$H1/data/brett-antworten/quittungen/$ID1.json"
out=$(run_check "$H1")
case $out in
  *"1 verbucht("*) pass "ok - crash-window replay re-receipted without re-recording" ;;
  *) fail "replay sweep did not report verbucht, got: $out" ;;
esac
[ "$(grep -c "das Testwort des Captains" "$H1/data/backlog.md")" = 1 ] \
  || fail "replay wrote a second resolution block"
receipt_exists "$H1" "$ID1" || fail "replay did not restore the receipt"

# --- officer-home post: wake and meldung, never a foreign recording -----------

H2=$(make_home h2)
O2=$(make_home o2)
install_quittung_stub "$H2"
install_quittung_stub "$O2"
hold_task "$O2" offizier-test-posten
register_officer "$H2" sm-test "$O2"
ID2=20260824T101000-offizier-test-posten-bbbb22
write_card "$H2" "$ID2" offizier-test-posten "Option B - Wort fuer den Offizier"

out=$(run_check "$H2")
case $out in
  *"offizier-nicht-verbucht(offizier-test-posten@sm-test)"*) pass "ok - officer post reported, named home attached" ;;
  *) fail "expected officer meldung, got: $out" ;;
esac
receipt_exists "$H2" "$ID2" && fail "an unrecordable card was receipted anyway"
grep -q "^- \[ \] offizier-test-posten " "$O2/data/backlog.md" \
  || fail "the officer home's held row was touched"
grep -q "Wort fuer den Offizier" "$O2/data/backlog.md" \
  && fail "the answer was recorded in the foreign home"

# --- replacement chains: only the newest word lands ---------------------------

H3=$(make_home h3)
install_quittung_stub "$H3"
hold_task "$H3" kettentest-posten
IDA=20260824T102000-kettentest-posten-cccc33
IDB=20260824T102500-kettentest-posten-dddd44
IDC=20260824T103000-kettentest-posten-eeee55
write_card "$H3" "$IDA" kettentest-posten "Erstes Wort"
write_card "$H3" "$IDB" kettentest-posten "Zweites Wort" "$IDA"
write_card "$H3" "$IDC" kettentest-posten "Drittes und letztes Wort" "$IDB"

out=$(run_check "$H3")
case $out in
  *"1 verbucht($IDC"*) pass "ok - chain head recorded" ;;
  *) fail "expected only the chain head verbucht, got: $out" ;;
esac
grep -q "Drittes und letztes Wort" "$H3/data/backlog.md" \
  || fail "chain head words missing from the task body"
grep -q "Erstes Wort" "$H3/data/backlog.md" && fail "a superseded word was recorded"
grep -q "Zweites Wort" "$H3/data/backlog.md" && fail "a superseded middle word was recorded"
case $out in
  *"2 als ersetzt markiert($IDA,$IDB)"*|*"2 als ersetzt markiert($IDB,$IDA)"*) pass "ok - both superseded cards marked as evidence" ;;
  *) fail "expected both superseded cards marked, got: $out" ;;
esac
receipt_exists "$H3" "$IDA" || fail "superseded card A has no evidence receipt"
receipt_exists "$H3" "$IDB" || fail "superseded card B has no evidence receipt"
receipt_exists "$H3" "$IDC" || fail "head card was not receipted"

# A late OLD card whose replacer was already recorded must be marked as
# evidence without feeding anything into the already-closed post.
IDL=20260824T101500-kettentest-posten-ffff66
write_card "$H3" "$IDL" kettentest-posten "Verspaetetes allererstes Wort"
write_card "$H3" "${IDL%-ffff66}-gggg77" kettentest-posten "Neueres Wort" "$IDL"

out=$(run_check "$H3")
case $out in
  *"schon-geschlossen("*) pass "ok - newer word for an answered post reported loudly" ;;
  *) fail "expected schon-geschlossen for the word over a closed post, got: $out" ;;
esac
receipt_exists "$H3" "${IDL%-ffff66}-gggg77" \
  && fail "the word over a closed post was receipted as if recorded"
case $out in
  *"1 als ersetzt markiert($IDL)"*) pass "ok - late old card marked as evidence only" ;;
  *) fail "expected late old card marked as evidence, got: $out" ;;
esac
receipt_exists "$H3" "$IDL" || fail "late old card has no evidence receipt"
grep -q "Verspaetetes allererstes Wort" "$H3/data/backlog.md" \
  && fail "a superseded late arrival was recorded anyway"

# --- unknown key: loud wake, no silent filing ----------------------------------

H4=$(make_home h4)
install_quittung_stub "$H4"
ID4=20260824T110000-nirgends-ein-posten-hhhh88
write_card "$H4" "$ID4" nirgends-ein-posten "Wort ohne Posten"

out=$(run_check "$H4")
case $out in
  *"unbekannt($ID4"*) pass "ok - unknown key wakes loudly" ;;
  *) fail "expected unbekannt finding, got: $out" ;;
esac
receipt_exists "$H4" "$ID4" && fail "an unrecordable unknown card was receipted"

# --- malformed cards: loud findings, never silent skips ------------------------

H5=$(make_home h5)
install_quittung_stub "$H5"
hold_task "$H5" formtest-posten
ID5=20260824T111000-formtest-posten-iiii99
write_card "$H5" "$ID5" formtest-posten "Wort in falscher Kunst" - zauberei

out=$(run_check "$H5")
case $out in
  *"FEHLER($ID5:unbekannte-art-zauberei)"*) pass "ok - unknown art named loudly" ;;
  *) fail "expected unknown-art finding, got: $out" ;;
esac
receipt_exists "$H5" "$ID5" && fail "a malformed card was receipted"
grep -q "^- \[ \] formtest-posten " "$H5/data/backlog.md" \
  || fail "a malformed card changed the held task"

mv "$H5/data/brett-antworten/$ID5.md" "$H5/data/brett-antworten/andere-datei.md"
sed -i 's/^antwort-id: .*/antwort-id: 20260824T111000-formtest-posten-iiii99/' \
  "$H5/data/brett-antworten/andere-datei.md"
out=$(run_check "$H5")
case $out in
  *FEHLER*datei-heisst-anders*) pass "ok - filename mismatch named loudly" ;;
  *) fail "expected filename-mismatch finding, got: $out" ;;
esac

# --- schonfrist: withdrawable words are deferred, then processed ---------------

H6=$(make_home h6)
install_quittung_stub "$H6"
hold_task "$H6" fristtest-posten
ID6=20260824T112000-fristtest-posten-jjjj00
write_card "$H6" "$ID6" fristtest-posten "Wort innerhalb der Frist" - wahl "$(ts_offset '+45 seconds')"

out=$(run_check "$H6")
[ -z "$out" ] || fail "a withdrawable card fired before its schonfrist ran out: $out"
receipt_exists "$H6" "$ID6" && fail "a withdrawable card was processed early"

write_card "$H6" "$ID6" fristtest-posten "Wort nach abgelaufener Frist"
out=$(run_check "$H6")
case $out in
  *"1 verbucht($ID6"*) pass "ok - deferred card processed once its grace expired" ;;
  *) fail "expected the expired-grace card to record, got: $out" ;;
esac
grep -q "Wort nach abgelaufener Frist" "$H6/data/backlog.md" \
  || fail "expired-grace words missing from the task body"

# --- withdrawn answers are receipted, never fed --------------------------------

H7=$(make_home h7)
install_quittung_stub "$H7"
hold_task "$H7" rueckzug-posten
ID7=20260824T113000-rueckzug-posten-kkkk11
write_card "$H7" "$ID7" rueckzug-posten "-" - zurueckgenommen

out=$(run_check "$H7")
case $out in
  *"1 zurueckgenommen($ID7)"*) pass "ok - withdrawn card receipted as withdrawn" ;;
  *) fail "expected zurueckgenommen handling, got: $out" ;;
esac
grep -q "^- \[ \] rueckzug-posten " "$H7/data/backlog.md" \
  || fail "a withdrawn answer changed the held task"

# --- captain remark (O-0054): booked, marked loudly, never silently done ------
# The captain's free text is often more important than the clicked answer.
# A non-empty "## Bemerkung" must land verbatim in the booking, stand loudly
# in the wake line, and keep a durable routing marker until a hand retires it.

HB=$(make_home hb)
install_quittung_stub "$HB"
hold_task "$HB" bemerkung-posten
IDB=20260824T115000-bemerkung-posten-mmmm33
BEM_TEXT="A und C, wenn wir Quellen finden dann nutzen sonst leer lassen, quelle: https://example.test/kalender reicht das?"
write_card "$HB" "$IDB" bemerkung-posten "Option C - so lassen" - wahl '' "$BEM_TEXT"

out=$(run_check "$HB")
case $out in
  *"bemerkung-vorhanden($IDB)"*) pass "ok - non-empty remark marked loudly in the wake line" ;;
  *) fail "expected bemerkung-vorhanden token, got: $out" ;;
esac
case $out in
  *"1 verbucht($IDB"*) pass "ok - remark card still recorded" ;;
  *) fail "expected verbucht alongside the remark token, got: $out" ;;
esac
grep -qF "Bemerkung des Captains: $BEM_TEXT" "$HB/data/backlog.md" \
  || fail "the captain's remark is missing from the booking"
grep -qF "Option C - so lassen" "$HB/data/backlog.md" \
  || fail "the clicked answer is missing from the booking"
MARKER="$HB/state/brett-bemerkungen/$IDB.md"
[ -f "$MARKER" ] || fail "no durable remark marker under state/"
grep -q "^verbleib: verbucht$" "$MARKER" || fail "marker does not record where the answer went"
grep -qF "bemerkung: $BEM_TEXT" "$MARKER" || fail "marker does not carry the remark text"

# The marker survives the sweep that consumed its card (and any restart, being
# a plain file under state/): the wake line keeps standing until a hand routes
# the remark, even though the card itself is receipted and quiet.
out=$(run_check "$HB")
case $out in
  *"bemerkung-vorhanden($IDB)"*) pass "ok - unrouted remark keeps standing on the next sweep" ;;
  *) fail "expected the remark to keep standing, got: $out" ;;
esac
case $out in
  *verbucht*) fail "a receipted remark card was recorded again: $out" ;;
  *) : ;;
esac

# Crash window: replaying the fed-but-unreceipted card keeps the digest stable
# (single resolution block) and does not duplicate the remark.
rm -f "$HB/data/brett-antworten/quittungen/$IDB.json"
out=$(run_check "$HB")
case $out in
  *"1 verbucht($IDB"*) pass "ok - remark-card crash replay re-receipted" ;;
  *) fail "remark replay sweep did not report verbucht, got: $out" ;;
esac
[ "$(grep -cF "Bemerkung des Captains: $BEM_TEXT" "$HB/data/backlog.md")" = 1 ] \
  || fail "the remark replay wrote a second resolution block"

# Routing the remark is an explicit hand act with a mandatory note; the marker
# retires into erledigt/ as durable evidence and the wake line falls silent.
FM_HOME="$HB" FM_STATE_OVERRIDE="$HB/state" "$CHECK" bemerkung-erledigt "$IDB" >/dev/null 2>&1 \
  && fail "bemerkung-erledigt accepted a resolution without a note"
out=$(FM_HOME="$HB" FM_STATE_OVERRIDE="$HB/state" "$CHECK" bemerkungen)
case $out in
  *"$IDB"*) pass "ok - bemerkungen lists the open remark" ;;
  *) fail "bemerkungen does not list the open remark: $out" ;;
esac
out=$(FM_HOME="$HB" FM_STATE_OVERRIDE="$HB/state" "$CHECK" bemerkung-erledigt "$IDB" --vermerk "an Testoffizier weitergegeben")
[ "$out" = "erledigt: $IDB" ] || fail "unexpected bemerkung-erledigt output: $out"
[ ! -f "$MARKER" ] || fail "resolved marker still open"
grep -qF "vermerk: an Testoffizier weitergegeben" "$HB/state/brett-bemerkungen/erledigt/$IDB.md" \
  || fail "retired marker lost the routing note"
out=$(run_check "$HB")
[ -z "$out" ] || fail "a routed remark still wakes: $out"
out=$(FM_HOME="$HB" FM_STATE_OVERRIDE="$HB/state" "$CHECK" bemerkung-erledigt "$IDB" --vermerk "nochmal")
[ "$out" = "schon erledigt: $IDB" ] || fail "re-resolution was not idempotent: $out"
FM_HOME="$HB" FM_STATE_OVERRIDE="$HB/state" "$CHECK" bemerkung-erledigt 20260824T120500-nie-gesehen-zzzz99 --vermerk x >/dev/null 2>&1 \
  && fail "resolving an unknown remark id succeeded"
pass "ok - remark routing retires the marker with its note"

# Officer-home post with a remark: the forwarding evidence must carry it too.
HBO=$(make_home hbo)
OBO=$(make_home obo)
install_quittung_stub "$HBO"
install_quittung_stub "$OBO"
hold_task "$OBO" bemerkung-offizier-posten
register_officer "$HBO" sm-test "$OBO"
IDBO=20260824T121000-bemerkung-offizier-posten-nnnn44
write_card "$HBO" "$IDBO" bemerkung-offizier-posten "Option B - Offizierswort" - wahl '' \
  "Der Offizier soll die Quelle direkt einbauen."
out=$(run_check "$HBO")
case $out in
  *"offizier-nicht-verbucht(bemerkung-offizier-posten@sm-test)"*) : ;;
  *) fail "expected officer meldung for the remark card, got: $out" ;;
esac
case $out in
  *"bemerkung-vorhanden($IDBO)"*) pass "ok - officer-post remark marked loudly" ;;
  *) fail "expected the officer-post remark marked, got: $out" ;;
esac
grep -q "^verbleib: offizier:sm-test$" "$HBO/state/brett-bemerkungen/$IDBO.md" \
  || fail "officer-post marker does not name the routed home"
grep -q "Der Offizier soll die Quelle direkt einbauen." "$OBO/data/backlog.md" \
  && fail "the remark was recorded in the foreign home"

# Negative case: a card without a remark behaves exactly as before - no token,
# no marker, no remark line in the booking.
HBN=$(make_home hbn)
install_quittung_stub "$HBN"
hold_task "$HBN" ohne-vermerk-posten
IDBN=20260824T122000-ohne-vermerk-posten-oooo55
write_card "$HBN" "$IDBN" ohne-vermerk-posten "Option A - schlichtes Wort"
out=$(run_check "$HBN")
case $out in
  *bemerkung*) fail "a remark-less card produced a remark finding: $out" ;;
  *"1 verbucht($IDBN"*) pass "ok - remark-less card recorded unchanged" ;;
  *) fail "expected plain verbucht for the remark-less card, got: $out" ;;
esac
grep -q "Bemerkung des Captains:" "$HBN/data/backlog.md" \
  && fail "a remark-less booking grew a remark line"
[ -e "$HBN/state/brett-bemerkungen" ] && fail "a remark-less sweep created marker state"

# A lone dash body means "no remark", like the board's other empty fields.
hold_task "$HBN" strich-vermerk-posten
IDBS=20260824T122500-strich-vermerk-posten-pppp66
write_card "$HBN" "$IDBS" strich-vermerk-posten "Option A - Wort mit Strich" - wahl '' "-"
out=$(run_check "$HBN")
case $out in
  *bemerkung*) fail "a dash remark produced a remark finding: $out" ;;
  *"1 verbucht($IDBS"*) pass "ok - dash remark treated as empty" ;;
  *) fail "expected plain verbucht for the dash remark, got: $out" ;;
esac

# An oversize remark is refused loudly rather than truncated; the card stays
# pending and the held task is untouched.
hold_task "$HBN" lang-vermerk-posten
IDBL=20260824T123000-lang-vermerk-posten-qqqq77
write_card "$HBN" "$IDBL" lang-vermerk-posten "Option A - Wort mit Riesenvermerk" - wahl '' \
  "$(printf 'y%.0s' $(seq 1 4001))"
out=$(run_check "$HBN")
case $out in
  *"FEHLER($IDBL:bemerkung-zu-lang)"*) pass "ok - oversize remark refused loudly" ;;
  *) fail "expected bemerkung-zu-lang finding, got: $out" ;;
esac
receipt_exists "$HBN" "$IDBL" && fail "an oversize-remark card was receipted anyway"
grep -q "^- \[ \] lang-vermerk-posten " "$HBN/data/backlog.md" \
  || fail "an oversize remark consumed the held task"

# --- chat messages (art nachricht): own kind, no booking, closed by answer ----
# A captain message is conversational freight, not a card answer: it books
# nothing against any hold, stands as chat-nachricht(<id>) until a
# format-valid answer file closes it, and only then gets its receipt.

write_antwort_datei() {  # <home> <bezug> <dateiname>
  mkdir -p "$1/data/chat-antworten"
  {
    printf '# Antwort des Firstmate\n'
    printf 'antwort-auf: %s\n' "$2"
    printf 'von: firstmate\n'
    printf 'gesendet: %s\n' "$(ts_offset '-10 seconds')"
    printf '\n'
    printf '## Wort\n'
    printf 'Erledigt, das Wort steht im Bericht.\n'
    printf '\n'
  } > "$1/data/chat-antworten/$3"
}

HC=$(make_home hc)
install_quittung_stub "$HC"
IDCHAT=20260825T140000-chat-aaaa21
write_card "$HC" "$IDCHAT" chat "Captain hier: wie steht es um die Lieferung?" - nachricht

out=$(run_check "$HC")
case $out in
  *"chat-nachricht($IDCHAT)"*) pass "ok - chat message presented as its own kind" ;;
  *) fail "expected chat-nachricht token, got: $out" ;;
esac
case $out in
  *unbekannt*) fail "a chat message was reported as unknown: $out" ;;
  *FEHLER*) fail "a well-formed chat message raised a finding: $out" ;;
  *) : ;;
esac
receipt_exists "$HC" "$IDCHAT" && fail "an unanswered message was receipted"
[ -f "$HC/state/brett-chat-nachrichten/$IDCHAT.md" ] || fail "no durable chat marker under state/"
grep -q "^verbleib: offen$" "$HC/state/brett-chat-nachrichten/$IDCHAT.md" \
  || fail "chat marker does not stand open"
grep -qF "wort: Captain hier: wie steht es um die Lieferung?" \
  "$HC/state/brett-chat-nachrichten/$IDCHAT.md" || fail "chat marker lost the message text"
out=$(FM_HOME="$HC" FM_STATE_OVERRIDE="$HC/state" "$CHECK" nachrichten)
case $out in
  *"$IDCHAT"*) pass "ok - nachrichten lists the open message" ;;
  *) fail "nachrichten does not list the open message: $out" ;;
esac

# A broken answer file must not close the message: the board would reject it
# red, so the checker treats it as no answer at all.
mkdir -p "$HC/data/chat-antworten"
{
  printf '# Antwort des Firstmate\n'
  printf 'antwort-auf: %s\n' "$IDCHAT"
  printf 'von: firstmate\n'
  printf '\n'
  printf '## Wort\n'
  printf 'x\n'
} > "$HC/data/chat-antworten/kaputt.md"
out=$(run_check "$HC")
case $out in
  *"chat-nachricht($IDCHAT)"*) pass "ok - a format-broken answer leaves the message open" ;;
  *) fail "broken answer closed the message, got: $out" ;;
esac
receipt_exists "$HC" "$IDCHAT" && fail "the broken answer triggered a receipt"

rm -f "$HC/data/chat-antworten/kaputt.md"
write_antwort_datei "$HC" "$IDCHAT" 20260825T140500-antwort.md
out=$(run_check "$HC")
case $out in
  *"chat-beantwortet($IDCHAT)"*) pass "ok - valid answer closed the message and was reported" ;;
  *) fail "expected chat-beantwortet token, got: $out" ;;
esac
receipt_exists "$HC" "$IDCHAT" || fail "the answered message was not receipted"
grep -qF "beantwortet: 20260825T140500-antwort.md" \
  "$HC/state/brett-chat-nachrichten/erledigt/$IDCHAT.md" \
  || fail "retired marker lost the answer filename as evidence"
[ ! -e "$HC/state/brett-chat-nachrichten/$IDCHAT.md" ] || fail "closed marker still open"
out=$(run_check "$HC")
[ -z "$out" ] || fail "an answered message kept waking: $out"

# The withdraw window holds for messages too: nothing fires inside it.
HS=$(make_home hs)
install_quittung_stub "$HS"
IDS=20260825T141000-chat-bbbb32
write_card "$HS" "$IDS" chat "Noch frisch, noch zurueckziehbar" - nachricht "$(ts_offset '+45 seconds')"
out=$(run_check "$HS")
[ -z "$out" ] || fail "a withdrawable message fired early: $out"
[ ! -e "$HS/state/brett-chat-nachrichten" ] || fail "a withdrawable message created marker state"
pass "ok - chat schonfrist defers like any other card"

# Answer arriving before the first sweep: one sweep closes everything.
HR=$(make_home hr)
install_quittung_stub "$HR"
IDR=20260825T142000-chat-cccc43
write_card "$HR" "$IDR" chat "Sofort beantwortet" - nachricht
write_antwort_datei "$HR" "$IDR" 20260825T142100-antwort.md
out=$(run_check "$HR")
case $out in
  *"chat-beantwortet($IDR)"*) : ;;
  *) fail "expected immediate chat-beantwortet, got: $out" ;;
esac
case $out in
  *"chat-nachricht($IDR)"*) fail "the pre-answered message stood open anyway: $out" ;;
  *) : ;;
esac
[ -f "$HR/state/brett-chat-nachrichten/erledigt/$IDR.md" ] \
  || fail "pre-answered message has no retired evidence marker"
receipt_exists "$HR" "$IDR" || fail "pre-answered message not receipted"

# Receipt path down while an answer exists: the marker may not vanish while
# the card could still nag - the sweep reports the broken receipt loudly and
# replays the whole closure once the tool is back.
HQ=$(make_home hq)
IDQ=20260825T143000-chat-dddd54
write_card "$HQ" "$IDQ" chat "Antwort ohne Quittungswerkzeug da" - nachricht
write_antwort_datei "$HQ" "$IDQ" 20260825T143100-antwort.md
out=$(run_check "$HQ")
case $out in
  *FEHLER*brett-quittung-fehlt*) pass "ok - missing receipt tool named loudly on closure" ;;
  *) fail "expected brett-quittung-fehler finding, got: $out" ;;
esac
install_quittung_stub "$HQ"
out=$(run_check "$HQ")
case $out in
  *"chat-beantwortet($IDQ)"*) pass "ok - closure replayed cleanly once receipts work again" ;;
  *) fail "expected replayed chat-beantwortet, got: $out" ;;
esac

# --- arm, disarm, shim bytes, selftest -----------------------------------------

H8=$(make_home h8)
FM_HOME="$H8" "$CHECK" --selftest >/dev/null 2>&1 \
  && fail "selftest passed without any brett-quittung present"
FM_HOME="$H8" "$CHECK" --selftest 2>&1 | grep -q "SELFTEST FAIL" \
  || fail "selftest failure did not name itself"

install_quittung_stub "$H8"
FM_HOME="$H8" "$CHECK" --selftest >/dev/null || fail "selftest failed with all sources present"

out=$(FM_HOME="$H8" "$CHECK" arm)
[ "$out" = "armed: state/brett-antworten.check.sh" ] || fail "unexpected arm output: $out"
SHIM="$H8/state/brett-antworten.check.sh"
[ -f "$SHIM" ] && [ ! -L "$SHIM" ] || fail "arm left no regular shim"
[ "$(stat -c %a "$SHIM")" = 700 ] || fail "shim is not mode 0700"
grep -q "export FM_HOME=$H8\$" "$SHIM" || fail "shim does not pin the resolved home"
grep -q "exec .*fm-brett-antworten\.sh\" check\|exec .*fm-brett-antworten\.sh check" "$SHIM" \
  || fail "shim does not exec this script's check"
TRUST="$H8/state/brett-antworten.check-trust"
[ -f "$TRUST" ] || fail "arm wrote no trust binding"
hash=$(shasum -a 256 "$SHIM" 2>/dev/null | awk '{print $1}') \
  || hash=$(sha256sum "$SHIM" | awk '{print $1}')
grep -q "$hash" "$TRUST" || fail "trust binding does not match the shim bytes"

out=$(FM_HOME="$H8" "$CHECK" arm)
[ "$out" = "armed: state/brett-antworten.check.sh" ] || fail "re-arm was not idempotent: $out"

out=$(FM_HOME="$H8" "$CHECK" disarm)
[ "$out" = "disarmed: state/brett-antworten.check.sh" ] || fail "unexpected disarm output: $out"
[ ! -e "$SHIM" ] && [ ! -e "$TRUST" ] || fail "disarm left check artifacts behind"

# --- the real project tool, opt-in ---------------------------------------------

if [ -n "${BRETT_CHECKOUT:-}" ] && [ -x "$BRETT_CHECKOUT/bin/brett-quittung" ]; then
  H9=$(make_home h9)
  # make_home pre-created the project dir; the checkout link must replace it,
  # not nest inside it.
  rmdir "$H9/projects/captain-brett/bin" "$H9/projects/captain-brett"
  ln -s "$BRETT_CHECKOUT" "$H9/projects/captain-brett"
  hold_task "$H9" echt-quittung-posten
  ID9=20260824T114000-echt-quittung-posten-lmmm22
  write_card "$H9" "$ID9" echt-quittung-posten "Echtes Wort fuer das echte Werkzeug"
  cat >> "$H9/data/brett-antworten/journal.jsonl" <<EOF
{"id": "$ID9", "entscheid": "echt-quittung-posten", "art": "wahl", "option": "A",
 "option_titel": null, "vertagt_bis": null, "bemerkung": "", "gesendet":
 "$(ts_offset '-125 seconds')", "schonfrist_bis": "$(ts_offset '-120 seconds')",
 "ersetzt": null, "quittung": null}
EOF
  tr -d '\n' < "$H9/data/brett-antworten/journal.jsonl" > "$H9/data/brett-antworten/journal.jsonl.tmp"
  mv "$H9/data/brett-antworten/journal.jsonl.tmp" "$H9/data/brett-antworten/journal.jsonl"
  out=$(run_check "$H9")
  case $out in
    *"1 verbucht($ID9"*) pass "ok - real brett-quittung receipted the recorded answer" ;;
    *) fail "real-tool sweep did not report verbucht, got: $out" ;;
  esac
  grep -q "firstmate" "$H9/data/brett-antworten/quittungen/$ID9.json" \
    || fail "real receipt does not name its receiver"
else
  echo "skip: kein captain-brett checkout (BRETT_CHECKOUT setzen fuer den Echtwerkzeug-Fall)"
fi

# --- help surface ----------------------------------------------------------------

"$CHECK" --help >/dev/null || fail "--help failed"
"$CHECK" --help | grep -q "arm" || fail "--help does not mention arming"

pass "ok - alle brett-antworten Faelle bestanden"
