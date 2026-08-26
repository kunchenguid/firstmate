#!/usr/bin/env bash
# tests/fm-reservierung.test.sh - a reservation on a shared environment must be
# ASKABLE by the tool that is about to touch that environment. Covers
# bin/fm-reservierung-lib.sh:
#
#   1. RED with the blocking condition / GREEN without it: a `blocks:` line shuts
#      its gate for a full match and prints
#      "reservierung:<file><TAB><holder>: <purpose>"; a context the reservation
#      never names passes. Both directions asserted.
#   2. The holder is not blocked by his own reservation - including when the
#      holder field carries a trailing note ("sm-x (Bahn ...)").
#   3. An expired reservation blocks nothing (and stays on disk); an unreadable
#      or missing expiry warns loudly and counts as HOLDING (never a silent pass).
#   4. A legacy reservation without any `blocks:` line is inert for every gate -
#      the existing fleet files keep working unchanged.
#   5. Unknown gate and unknown context key abort loudly (exit 2); the archiv/
#      subdirectory is never read.
#   6. Every decision writes its Tor-Log line to state/tor-log/reservierung.jsonl.
#
# Isolation: fixture reservations under a throwaway FM_HOME. Nothing touches the
# live reservations or the live tor-log.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
RES="$HOME_A/state/reservierungen"
mkdir -p "$RES/archiv"
LOG="$HOME_A/state/tor-log/reservierung.jsonl"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

export FM_HOME="$HOME_A"
# shellcheck source=bin/fm-reservierung-lib.sh
. "$REPO/bin/fm-reservierung-lib.sh"

check() { # check <gate> [k=v]... -> sets RC and OUT
  OUT="$(fm_reservierung_check "$@" 2>&1)"
  RC=$?
}

cat > "$RES/gex-api.md" <<'EOF'
holder: sm-lensclash (Bahn lensclash-katalog-uebernahme)
purpose: Rollout lensclash-api auf e7235ee, Nachbar-Adressen vorher/nachher
expiry: 2099-08-25T18:30Z
set-by: fixture
blocks: rollout project=lensclash-api
EOF

# --- 1. red with the condition, green without -------------------------------
check rollout project=lensclash-api
[ "$RC" -eq 1 ] && ok "a held environment blocks its gate (exit 1)" \
  || fail "the reservation must block (rc=$RC out=$OUT)"
printf '%s' "$OUT" | grep -q '^reservierung:state/reservierungen/gex-api\.md	sm-lensclash (Bahn lensclash-katalog-uebernahme): Rollout lensclash-api' \
  && ok "the refusal names file, holder, and purpose" \
  || fail "refusal must be 'reservierung:<file><TAB><holder>: <purpose>' (got: $OUT)"
check rollout project=hplan
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "another project passes the same gate" \
  || fail "an unnamed project must pass (rc=$RC out=$OUT)"
check merge project=lensclash-api
[ "$RC" -eq 0 ] && ok "another gate is unaffected by this reservation" \
  || fail "the block must bind only its own gate (rc=$RC out=$OUT)"

# --- 2. the holder passes his own reservation -------------------------------
check rollout project=lensclash-api holder=sm-lensclash
[ "$RC" -eq 0 ] && ok "the holder is not blocked by his own reservation" \
  || fail "holder exception must free the gate (rc=$RC out=$OUT)"
check rollout project=lensclash-api holder=sm-hplan
[ "$RC" -eq 1 ] && ok "a foreign holder is still blocked" \
  || fail "a foreign holder must stay blocked (rc=$RC)"

# --- 3. expiry ---------------------------------------------------------------
cat > "$RES/gex-alt.md" <<'EOF'
holder: sm-alt
purpose: alte Bahn
expiry: 2020-01-01T10:00Z
blocks: rollout project=hplan
EOF
check rollout project=hplan
[ "$RC" -eq 0 ] && ok "an expired reservation blocks nothing" \
  || fail "expired reservation must not block (rc=$RC out=$OUT)"
[ -f "$RES/gex-alt.md" ] || fail "an expired reservation must stay on disk"
cat > "$RES/gex-kaputt.md" <<'EOF'
holder: sm-kaputt
purpose: Bahn mit unlesbarem Ablauf
expiry: irgendwann bald
blocks: rollout project=snacksuite
EOF
check rollout project=snacksuite
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'unreadable expiry' \
  && ok "an unreadable expiry warns loudly and counts as HOLDING" \
  || fail "an unreadable expiry must warn and hold (rc=$RC out=$OUT)"
rm -f "$RES/gex-kaputt.md"

# --- 4. a reservation without blocks is inert -------------------------------
cat > "$RES/gex-bestand.md" <<'EOF'
holder: sm-bestand
purpose: Bestandsformat ohne blocks-Zeile
expiry: 2099-01-01T10:00Z
set-by: fixture
EOF
for g in spawn plan-approval merge rollout brief; do
  check "$g" project=lensclash-api holder=niemand
  [ "$RC" -eq 1 ] && [ "$g" = "rollout" ] && continue   # the gex-api reservation, not this one
  [ "$RC" -eq 0 ] || fail "a reservation without blocks must be inert for gate $g (rc=$RC out=$OUT)"
done
ok "a legacy reservation without a blocks line binds no gate"
rm -f "$RES/gex-bestand.md"

# --- 5. loud on unknown values, archiv is never read ------------------------
check quatsch project=lensclash-api
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'unknown gate' \
  && ok "an unknown gate aborts loudly (exit 2)" || fail "unknown gate must exit 2 (rc=$RC out=$OUT)"
check rollout konto=2
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'unknown context key' \
  && ok "an unknown context key aborts loudly (exit 2)" || fail "unknown key must exit 2 (rc=$RC out=$OUT)"
cp "$RES/gex-api.md" "$RES/archiv/gex-alt-2.md"
mv "$RES/gex-api.md" "$TMP/gex-api.md"
check rollout project=lensclash-api
[ "$RC" -eq 0 ] && ok "the archiv/ subdirectory is never read" \
  || fail "an archived reservation must not block (rc=$RC out=$OUT)"
mv "$TMP/gex-api.md" "$RES/gex-api.md"

# --- 6. the Tor-Log carries every decision ---------------------------------
[ -f "$LOG" ] || fail "the check must write state/tor-log/reservierung.jsonl"
grep -q '"regel":"state/reservierungen/gex-api.md","verdikt":"rot"' "$LOG" \
  && ok "a refusal is logged with the deciding reservation file" \
  || fail "rot line must name the reservation file"
grep -q '"verdikt":"gruen"' "$LOG" && ok "green passages are logged too" || fail "gruen lines must be logged"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$LOG" >/dev/null 2>&1 && ok "every log line is valid JSON" || fail "the tor-log must be valid JSONL"
fi
lines_before="$(wc -l < "$LOG")"
check rollout project=lensclash-api
lines_after="$(wc -l < "$LOG")"
[ "$lines_after" -eq $((lines_before + 1)) ] && ok "one decision appends exactly one line" \
  || fail "each decision must append exactly one line ($lines_before -> $lines_after)"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-reservierung.test.sh: all checks passed"
  exit 0
fi
echo "fm-reservierung.test.sh: $FAILS check(s) FAILED"
exit 1
