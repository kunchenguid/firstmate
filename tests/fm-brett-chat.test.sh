#!/usr/bin/env bash
# Tests for the firstmate side of the Brett-Chat round trip: the shared
# format contract reader (fm-brett-chat-lib.sh), the answer helper that
# writes format-valid files or refuses loudly (fm-brett-chat-antwort.sh),
# and the gex mirror with deletion semantics plus its listing probe
# (fm-brett-chat-nachschub.sh). The receiver-side art:nachricht handling
# lives in tests/fm-brett-antworten.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-brett-chat-lib.sh"
HELPER="$ROOT/bin/fm-brett-chat-antwort.sh"
MIRROR="$ROOT/bin/fm-brett-chat-nachschub.sh"
TMP_ROOT=$(fm_test_tmproot fm-brett-chat)

# --- shared contract reader -----------------------------------------------------
# Sourced library; its functions are its public interface.

# shellcheck source=bin/fm-brett-chat-lib.sh
# shellcheck disable=SC1091
. "$LIB"

CHAT_DIR="$TMP_ROOT/chat-antworten"
mkdir -p "$CHAT_DIR"

write_antwort() {  # <name> <bezug> [gesendet] [wort] [zusaetzliche-abschnitte]
  local name=$1 bezug=$2 gesendet=${3:-2026-08-25T10:22:31+02:00}
  local wort=${4-Klar und in ganzen Saetzen.}
  {
    printf '# Antwort des Firstmate\n'
    printf 'antwort-auf: %s\n' "$bezug"
    printf 'von: firstmate\n'
    printf 'gesendet: %s\n' "$gesendet"
    printf '\n'
    printf '## Wort\n'
    printf '%s\n' "$wort"
    if [ -n "${5:-}" ]; then
      printf '## %s\n' "$5"
      printf '\n'
    fi
  } > "$CHAT_DIR/$name"
}

fehler_fuer() {  # <name> -> rejection lines of one file
  chat_antwort_fehler "$CHAT_DIR/$1"
}

write_antwort gut.md 20260825T101500-chat-1a2b3c
[ -z "$(fehler_fuer gut.md)" ] || fail "the contract's own example shape was rejected: $(fehler_fuer gut.md)"
pass "ok - valid answer accepted by the shared reader"

printf '# Antwort des Firstmate\nvon: firstmate\ngesendet: 2026-08-25T10:22:31+02:00\n\n## Wort\nx\n' \
  > "$CHAT_DIR/ohne-bezug.md"
fehler_fuer ohne-bezug.md | grep -q "antwort-auf fehlt" || fail "missing reference not named"
printf '# Antwort des Firstmate\nantwort-auf: zuender!\n\n## Wort\nx\n' > "$CHAT_DIR/bad-id.md" \
  && fehler_fuer bad-id.md | grep -q "keine Antwort-ID" \
  || fail "malformed reference id not named"
write_antwort bad-zeit.md 20260825T101500-chat-1a2b3c "25.08.2026 10:22"
fehler_fuer bad-zeit.md | grep -q "kein ISO-Zeitstempel" || fail "non-ISO timestamp not named"
write_antwort kalender.md 20260825T101500-chat-1a2b3c 2026-02-30T00:00:00+02:00
fehler_fuer kalender.md | grep -q "kein ISO-Zeitstempel" || fail "impossible calendar date not named"
write_antwort leer-wort.md 20260825T101500-chat-1a2b3c 2026-08-25T10:22:31+02:00 ""
fehler_fuer leer-wort.md | grep -q "fehlt oder ist leer" || fail "empty word section not named"
write_antwort fremd.md 20260825T101500-chat-1a2b3c 2026-08-25T10:22:31+02:00 "Wort." "Fremdes"
fehler_fuer fremd.md | grep -q "unbekannte Abschnitte" || fail "foreign section not named"
pass "ok - every board rejection reason has a loud counterpart here"

chat_antwort_fuer "$CHAT_DIR" 20260825T101500-chat-1a2b3c > "$TMP_ROOT/treffer" \
  || fail "no answer found for an existing reference"
grep -qx "gut.md" "$TMP_ROOT/treffer" || fail "wrong answer file matched"
mv "$CHAT_DIR/gut.md" "$CHAT_DIR/kaputt.md"
sed -i 's/^von: .*/von:/' "$CHAT_DIR/kaputt.md"
chat_antwort_fuer "$CHAT_DIR" 20260825T101500-chat-1a2b3c >/dev/null \
  && fail "an invalid answer was treated as the closing one"
chat_antwort_fuer "$CHAT_DIR" 20260825T999999-chat-nirgends >/dev/null \
  && fail "a nonexistent reference matched something"
pass "ok - only a format-valid answer closes its message"

# --- the helper -------------------------------------------------------------------

H=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
SB=$TMP_ROOT/sandbox
mkdir -p "$SB" "$H/data/chat-antworten"
cp "$LIB" "$HELPER" "$MIRROR" "$SB/"
# The sibling boundary is stubbed in the sandbox copy so no test run ever
# reaches for the gex; the recording stub proves invocation instead.
cat > "$SB/fm-brett-chat-nachschub.sh" <<SH
#!/usr/bin/env bash
echo "nachschub aufgerufen mit \$*" >> "\${NACHSCHUB_LOG:?}"
exit "\${NACHSCHUB_EXIT:-0}"
SH
chmod +x "$SB/fm-brett-chat-nachschub.sh"

run_helfer() {  # <args...> -> stdout; NACHSCHUB_LOG must be set
  FM_HOME="$H" "$SB/fm-brett-chat-antwort.sh" "$@"
}

out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub.log" run_helfer 20260825T110000-chat-ab12cd "Erste Antwort, klar formuliert.")
case $out in
  *"antwort geschrieben: $H/data/chat-antworten/"*) : ;;
  *) fail "helper did not report the written path: $out" ;;
esac
DATEI=$(printf '%s\n' "$out" | sed -n 's/^antwort geschrieben: //p')
basename "$DATEI" | grep -Eq '^20[0-9]{6}T[0-9]{6}-20260825T110000-chat-ab12cd\.md$' \
  || fail "filename does not carry timestamp and reference id: $DATEI"
grep -q "^antwort-auf: 20260825T110000-chat-ab12cd$" "$DATEI" || fail "reference field wrong"
grep -q "^von: firstmate$" "$DATEI" || fail "sender field wrong"
grep -Eq "^gesendet: 20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\+[0-9]{2}:[0-9]{2}$" "$DATEI" \
  || fail "timestamp field not ISO with offset"
grep -q "^## Wort$" "$DATEI" && grep -A1 "^## Wort$" "$DATEI" | tail -1 | grep -q "Erste Antwort" \
  || fail "word section missing the text"
[ -z "$(chat_antwort_fehler "$DATEI")" ] || fail "helper wrote a file its own contract reader rejects"
grep -q "nachschub aufgerufen" "$TMP_ROOT/nachschub.log" || fail "helper skipped the immediate mirror run"
pass "ok - helper writes a contract-valid file, reports the path, runs the mirror"

out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub.log" run_helfer 20260825T110000-chat-ab12cd \
  "Erste Zeile."$'\n'"## Eigene Ueberschrift"$'\n'"Weitere Zeile." 2>&1) \
  && fail "a line-initial heading was written anyway"
grep -q "Ueberschrift" <<<"$out" || fail "heading refusal did not name itself"
# The board only treats line-initial headings as structure: a mid-line
# "##" stays prose there, so refusing it here would overstep the contract.
before=$(ls "$H/data/chat-antworten" | wc -l)
out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub.log" run_helfer --ohne-nachschub 20260825T110000-chat-ab12cd \
  "Text mit ## mitten in der Zeile ist erlaubt.") || fail "mid-line hash rejected beyond the contract"
after=$(ls "$H/data/chat-antworten" | wc -l)
[ "$((before + 1))" = "$after" ] || fail "mid-line-hash answer missing"
gueltig=$after
out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub.log" run_helfer 20260825T110000-chat-ab12cd "" 2>&1) \
  && fail "an empty word was written anyway"
after=$(ls "$H/data/chat-antworten" | wc -l)
[ "$gueltig" = "$after" ] || fail "an empty-word refusal left files behind"
out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub.log" run_helfer "nicht/ein/id" "x" 2>&1) \
  && fail "a malformed reference id was accepted"
[ "$(ls "$H/data/chat-antworten" | wc -l)" = "$gueltig" ] || fail "id refusal left files behind"
pass "ok - helper refuses heading text, empty word, malformed id - nothing written"

# A failing immediate mirror is loud but never fails the delivered answer.
count_before=$(ls "$H/data/chat-antworten" | wc -l)
rm -f "$TMP_ROOT/nachschub2.log"
out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub2.log" NACHSCHUB_EXIT=3 run_helfer 20260825T111500-chat-ef34ab "Zweite Antwort.") \
  || fail "mirror failure failed the whole delivery"
grep -q "antwort geschrieben:" <<<"$out" || fail "path not reported despite mirror failure"
count_after=$(ls "$H/data/chat-antworten" | wc -l)
[ "$((count_before + 1))" = "$count_after" ] || fail "delivered answer missing after mirror failure"
rm -f "$TMP_ROOT/nachschub3.log"
out=$(NACHSCHUB_LOG="$TMP_ROOT/nachschub3.log" run_helfer --ohne-nachschub 20260825T112000-chat-ef34ab "Dritte.")
[ ! -e "$TMP_ROOT/nachschub3.log" ] || fail "--ohne-nachschub still invoked the mirror"
pass "ok - mirror failure stays loud without unshipping the answer; --ohne-nachschub skips it"

# Same-second collision gets a numbered suffix (frozen clock via PATH stub).
FAKE=$(fm_fakebin "$H")
cat > "$FAKE/date" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = '+%Y%m%dT%H%M%S' ] && { echo 20260825T120000; exit 0; }
exec /bin/date "$@"
SH
chmod +x "$FAKE/date"
touch "$H/data/chat-antworten/20260825T120000-20260825T120000-chat-kollision.md"
out=$(PATH="$FAKE:$PATH" FM_HOME="$H" NACHSCHUB_LOG="$TMP_ROOT/n4.log" \
  "$SB/fm-brett-chat-antwort.sh" 20260825T120000-chat-kollision "Kollision.") || fail "collision write failed"
grep -q -- "-1.md" <<<"$out" || fail "same-second collision not numbered: $out"
pass "ok - same-second collision numbered instead of overwritten"

# --- the mirror -------------------------------------------------------------------
# A faithful mini-rsync: copies non-dot entries, applies deletions, records the
# invocation. The ssh stub answers the listing probe from the same store.

FAKE_GEX_ROOT=$TMP_ROOT/gex
GEX_STORE=$FAKE_GEX_ROOT/root/captain-brett/data/chat-antworten
LOG=$TMP_ROOT/rsync-aufrufe.log
MH=$TMP_ROOT/mirror-home
Q=$MH/data/chat-antworten

install_mirror_stubs() {  # <verzeichnis>; MIRROR_SSH_MODE=junk lets the probe diverge
  local fake=$1
  cat > "$fake/rsync" <<SH
#!/usr/bin/env bash
args=(\$@)
src=\${args[\${#args[@]}-2]}
dst=\${args[\${#args[@]}-1]}
ziel="\${MIRROR_GEX_ROOT}\${dst#*:}"
mkdir -p "\$ziel"
(
  cd "\$src" || exit 1
  for f in *; do
    [ -e "\$f" ] || continue
    cp -a "\$f" "\$ziel/"
  done
)
for f in "\$ziel"/*; do
  [ -e "\$f" ] || continue
  b=\$(basename "\$f")
  [ -e "\$src/\$b" ] || rm -f "\$f"
done
printf '%s\n' "\$*" >> "\${MIRROR_RSYNC_LOG:?}"
exit 0
SH
  cat > "$fake/ssh" <<SH
#!/usr/bin/env bash
if [ "\${MIRROR_SSH_MODE:-ok}" = junk ]; then
  printf 'falsch.md\nnirgends.md\n'
  exit 0
fi
cd "\${MIRROR_GEX_ROOT}/root/captain-brett/data/chat-antworten" 2>/dev/null || exit 1
ls
SH
  chmod +x "$fake/rsync" "$fake/ssh"
}

FAKE=$(fm_fakebin "$MH")
install_mirror_stubs "$FAKE"
run_spiegel() {  # <weitere args...>
  PATH="$FAKE:$PATH" FM_HOME="$MH" MIRROR_RSYNC_LOG="$LOG" \
    MIRROR_GEX_ROOT="$FAKE_GEX_ROOT" \
    "$MIRROR" "$@"
}

rm -f "$LOG"
out=$(run_spiegel)
grep -q "fehlt - nichts zu spiegeln" <<<"$out" || fail "absent source dir misbehaved: $out"
[ ! -e "$LOG" ] || fail "rsync ran against an absent source directory"
pass "ok - absent source directory means nothing to mirror, never a wipe order"

mkdir -p "$Q"
printf 'Erste Datei.\n' > "$Q/20260825T130000-chat-aaa.md"
printf 'Zweite Datei.\n' > "$Q/20260825T130100-chat-bbb.md"
out=$(run_spiegel) || fail "mirror run failed: $out"
grep -q "ok (" <<<"$out" || fail "mirror did not report success: $out"
[ -f "$GEX_STORE/20260825T130000-chat-aaa.md" ] || fail "answer did not reach the gex store"
[ -f "$GEX_STORE/20260825T130100-chat-bbb.md" ] || fail "second answer did not reach the gex store"
tail -1 "$LOG" | grep -q -- "--delete" || fail "mirror ran without deletion semantics"
pass "ok - answers land on the gex store, deletions armed"

rm -f "$Q/20260825T130100-chat-bbb.md"
out=$(run_spiegel) || fail "deletion mirror run failed: $out"
[ ! -e "$GEX_STORE/20260825T130100-chat-bbb.md" ] \
  || fail "locally deleted answer still sits on the gex store"
pass "ok - locally deleted answer disappears from the gex store"

FAKE2=$(fm_fakebin "$MH")
install_mirror_stubs "$FAKE2" junk
out=$(PATH="$FAKE2:$PATH" FM_HOME="$MH" MIRROR_GEX_ROOT="$FAKE_GEX_ROOT" MIRROR_RSYNC_LOG="$LOG" \
  MIRROR_SSH_MODE=junk \
  "$MIRROR" 2>&1) && fail "listing divergence passed silently"
grep -q "Spiegelprobe" <<<"$out" || fail "divergence not named by the probe: $out"
pass "ok - listing divergence fails loudly through the probe"

"$MIRROR" --help >/dev/null || fail "mirror --help failed"
FM_HOME="$H" "$HELPER" --help >/dev/null || fail "helper --help failed"
pass "ok - alle brett-chat Faelle bestanden"
