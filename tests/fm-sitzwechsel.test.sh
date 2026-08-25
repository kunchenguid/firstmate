#!/usr/bin/env bash
# tests/fm-sitzwechsel.test.sh - moving the firstmate seat must be one operation
# that either happens completely or refuses loudly. Covers:
#
#   1. RED without the conditions: target is already the seat; --alte-rolle
#      missing; --alte-rolle firstmate (two seats); target not startable
#      (trust dialog never accepted for $FM_HOME); no session file to carry
#      over; unknown speicher -> status 2. Every refusal must leave the ledger
#      and the target storage untouched.
#   2. --dry-run: full plan on stdout, nothing written.
#   3. GREEN: the newest .jsonl - not just any - lands under
#      <ziel>/projects/<slug of $FM_HOME>/, the ledger moves the firstmate role
#      to the target and stamps the vacated seat with --alte-rolle, comment
#      lines survive, and the output names the follow-ups the tool does NOT do
#      (restart command, unconverted consumers).
#   4. The auth freshness note is a WARNING, never a blocker.
#
# Isolation: fixture HOME with its own .claudeN directories, fixture ledger,
# fixture FM_HOME - all under mktemp. The captain's real storages and the
# shipped config/konten.tsv are never written.
# shellcheck disable=SC2016 # fixture ledgers store the literal text `$HOME`.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO/bin/fm-sitzwechsel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

H="$TMP/home"
FMHOME="$TMP/fmhome"
AUTH="$TMP/auth"
mkdir -p "$H/.claude1" "$H/.claude2" "$H/.claude3" "$H/.claude4" "$FMHOME" "$AUTH"
SLUG=$(printf '%s' "$FMHOME" | sed 's/[^A-Za-z0-9-]/-/g')

AKTE="$TMP/konten.tsv"
akte_schreiben() {
  {
    printf '# fixture ledger - the comment head must survive a rewrite\n'
    printf '# speicher\tpfad\tanthropic_konto\trolle\tbemerkung\n'
    printf 'konto-1\t$HOME/.claude1\ta@example.org\toffiziere-worker\tOx-Sitz\n'
    printf 'konto-2\t$HOME/.claude2\tb@example.org\tfirstmate\tSitz\n'
    printf 'konto-3\t$HOME/.claude3\tc@example.org\trestverbrauch\tReserve\n'
    printf 'konto-4\t$HOME/.claude4\td@example.org\trestverbrauch\truht\n'
  } > "$AKTE"
}
akte_schreiben

# konto-3 is the intended target: onboarded and trusting the project.
cat > "$H/.claude3/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {"$FMHOME": {"hasTrustDialogAccepted": true}}}
JSON
# konto-4 is onboarded but never accepted the trust dialog for this project.
cat > "$H/.claude4/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {}}
JSON
cat > "$H/.claude2/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {"$FMHOME": {"hasTrustDialogAccepted": true}}}
JSON

# The seat's session thread: two files, the older one deliberately larger, so a
# "newest" bug cannot pass by accident.
QUELLE="$H/.claude2/projects/$SLUG"
mkdir -p "$QUELLE"
printf 'alt alt alt alt alt\n' > "$QUELLE/alt.jsonl"
printf 'neu\n' > "$QUELLE/neu.jsonl"
touch -d '2026-08-01 10:00:00' "$QUELLE/alt.jsonl"
touch -d '2026-08-24 10:00:00' "$QUELLE/neu.jsonl"

lauf() {
  HOME="$H" FM_HOME="$FMHOME" FM_KONTEN_AKTE="$AKTE" FM_KONTO_AUTH_STATE="$AUTH" \
    FM_TOTMANN_TARGET="firstmate:0" "$TOOL" "$@"
}
rolle_von() {  # <speicher>
  HOME="$H" FM_KONTEN_AKTE="$AKTE" "$REPO/bin/fm-konten-lib.sh" fm_konto_rolle "$1"
}
akte_unveraendert() {  # <label>
  [ "$(rolle_von konto-2)" = "firstmate" ] && [ "$(rolle_von konto-3)" = "restverbrauch" ] \
    || fail "$1 must leave the ledger untouched"
  [ ! -d "$H/.claude3/projects/$SLUG" ] || fail "$1 must not create the target session dir"
}

# --- 1. RED without the conditions ----------------------------------------
out=$(lauf konto-2 --alte-rolle restverbrauch 2>&1) && fail "moving the seat onto itself must refuse"
case $out in
  *"already holds the firstmate seat"*) ok "target == current seat refuses and says so" ;;
  *) fail "self-move must name the reason (got: $out)" ;;
esac
akte_unveraendert "the self-move refusal"

out=$(lauf konto-3 2>&1) && fail "a missing --alte-rolle must refuse"
case $out in
  *--alte-rolle*) ok "a missing --alte-rolle refuses and names the way out" ;;
  *) fail "missing --alte-rolle must name --alte-rolle in the refusal (got: $out)" ;;
esac
akte_unveraendert "the missing --alte-rolle refusal"

out=$(lauf konto-3 --alte-rolle firstmate 2>&1) && fail "--alte-rolle firstmate must refuse"
case $out in
  *"two seats"*) ok "--alte-rolle firstmate refuses: the seat is exclusive" ;;
  *) fail "--alte-rolle firstmate must refuse with a reason (got: $out)" ;;
esac

out=$(lauf konto-3 --alte-rolle quatsch 2>&1) && fail "an unknown --alte-rolle must refuse"
case $out in
  *"unknown --alte-rolle 'quatsch'"*) ok "an unknown --alte-rolle refuses and lists the known set" ;;
  *) fail "unknown --alte-rolle must be named (got: $out)" ;;
esac

out=$(lauf konto-4 --alte-rolle restverbrauch 2>&1) && fail "an unstartable target must refuse"
case $out in
  *"trust fehlt fuer $FMHOME"*|*"not startable"*) ok "an unstartable target refuses, naming trust/onboarding" ;;
  *) fail "unstartable target must refuse with the startability reason (got: $out)" ;;
esac
case $out in
  *"claude4 in $FMHOME"*) ok "the refusal names the way out: open a session there by hand" ;;
  *) fail "the unstartable refusal must name the manual way out (got: $out)" ;;
esac
akte_unveraendert "the unstartable-target refusal"

out=$(lauf konto-9 --alte-rolle restverbrauch 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "unknown speicher 'konto-9'"; then
  ok "an unknown speicher aborts with status 2"
else
  fail "unknown speicher must abort 2 (rc=$rc out=$out)"
fi

# no thread to carry over -> refuse, naming --ohne-verlauf
LEER_HOME="$TMP/fmhome-leer"
mkdir -p "$LEER_HOME"
cat > "$H/.claude3/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {"$FMHOME": {"hasTrustDialogAccepted": true},
 "$LEER_HOME": {"hasTrustDialogAccepted": true}}}
JSON
out=$(HOME="$H" FM_HOME="$LEER_HOME" FM_KONTEN_AKTE="$AKTE" FM_KONTO_AUTH_STATE="$AUTH" \
  "$TOOL" konto-3 --alte-rolle restverbrauch 2>&1) && fail "a missing session file must refuse"
case $out in
  *--ohne-verlauf*) ok "a missing session file refuses and names --ohne-verlauf" ;;
  *) fail "missing session file must name --ohne-verlauf (got: $out)" ;;
esac
akte_unveraendert "the missing-session refusal"

# --- 2. --dry-run writes nothing ------------------------------------------
out=$(lauf konto-3 --alte-rolle restverbrauch --dry-run 2>&1) || fail "--dry-run must succeed"
case $out in
  *"Sitzwechsel: konto-2 -> konto-3"*) ok "--dry-run prints the planned move" ;;
  *) fail "--dry-run must print the planned move (got: $out)" ;;
esac
printf '%s' "$out" | grep -q "neu.jsonl" || fail "--dry-run must name the session file it would copy"
printf '%s' "$out" | grep -q -- "--dry-run: nichts geschrieben" || fail "--dry-run must say it wrote nothing"
akte_unveraendert "--dry-run"

# --- 4. the auth note warns, it does not block ----------------------------
printf '{"count": 3, "last": 0}' > "$AUTH/konto3.failures"
printf '2026-08-24T10:00:00Z konto3: Erneuerung fehlgeschlagen (http 403)\n' > "$AUTH/verlauf.log"
out=$(lauf konto-3 --alte-rolle restverbrauch --dry-run 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "WARNUNG.*konto-3"; then
  ok "a stale auth record warns but never blocks the move"
else
  fail "auth freshness must warn, not block (rc=$rc out=$out)"
fi
rm -f "$AUTH/konto3.failures" "$AUTH/verlauf.log"

# --- 3. GREEN: the real move ----------------------------------------------
out=$(lauf konto-3 --alte-rolle restverbrauch 2>&1) || fail "the real move must succeed (out=$out)"

ZIELDIR="$H/.claude3/projects/$SLUG"
[ -f "$ZIELDIR/neu.jsonl" ] || fail "the newest session file must be copied to $ZIELDIR"
[ ! -f "$ZIELDIR/alt.jsonl" ] || fail "only the newest session file may be copied"
[ -f "$QUELLE/neu.jsonl" ] || fail "the source session file must stay in place (copy, not move)"
ok "the newest session file is carried over into the target storage"

[ "$(rolle_von konto-3)" = "firstmate" ] || fail "the target must hold rolle firstmate after the move"
[ "$(rolle_von konto-2)" = "restverbrauch" ] || fail "the vacated seat must take --alte-rolle"
[ "$(rolle_von konto-1)" = "offiziere-worker" ] || fail "untouched rows must keep their role"
[ "$(HOME="$H" FM_KONTEN_AKTE="$AKTE" "$REPO/bin/fm-konten-lib.sh" fm_firstmate_sitz)" = "konto-3" ] \
  || fail "fm_firstmate_sitz must report the new seat"
grep -q '^# fixture ledger' "$AKTE" || fail "the rewrite must keep the ledger comment head"
grep -q 'Sitz$' "$AKTE" || fail "the rewrite must keep the bemerkung column"
grep -q '\$HOME/.claude2' "$AKTE" || fail "the rewrite must keep the literal \$HOME in the pfad column"
ok "the ledger is re-stamped and otherwise unchanged"

case $out in
  *"claude3 --continue"*) ok "the output names the restart command to type" ;;
  *) fail "the output must name '<wrapper> --continue' (got: $out)" ;;
esac
printf '%s' "$out" | grep -q "fm-totmann" || fail "the output must name the unconverted totmann relaunch default"
printf '%s' "$out" | grep -q "FM_LB_FIRSTMATE_KONTO" || fail "the output must name the unconverted load balancer"
ok "the follow-ups this tool does NOT perform are spelled out"

# the move is not repeatable in the same direction
out=$(lauf konto-3 --alte-rolle restverbrauch 2>&1) && fail "a second move onto the new seat must refuse"
case $out in
  *"already holds the firstmate seat"*) ok "after the move, konto-3 is the seat and refuses a self-move" ;;
  *) fail "the repeated move must refuse as a self-move (got: $out)" ;;
esac

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all sitzwechsel checks passed"
