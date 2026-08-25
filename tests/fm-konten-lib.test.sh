#!/usr/bin/env bash
# tests/fm-konten-lib.test.sh - the account ledger reader must answer from the
# file and must refuse loudly rather than guess. Covers:
#
#   1. Ledger selection ($FM_KONTEN_AKTE) and `$HOME` expansion in the pfad
#      column, against a fixture HOME - never the captain's real ~/.claudeN.
#   2. Seat lookup: fm_konto_rolle, fm_konto_fuer_rolle, fm_firstmate_sitz.
#   3. Wrapper naming: basis -> claude, konto-N -> claudeN.
#   4. fm_konto_startfaehig, RED and GREEN in both directions: a storage with
#      onboarding done AND the project trusted is green; each half missing is
#      red with its own named reason; an unreadable/absent .claude.json and a
#      machine without a JSON parser are red too - never a silent yes.
#   5. Loudness: an unknown speicher exits 2, an unknown rolle in the file
#      exits 2, a role nobody holds exits 1.
#   6. The shipped config/konten.tsv itself: exactly one firstmate seat, every
#      role from the closed set, every storage key wrapper-nameable (read-only).
#
# Isolation: every mutable fixture lives under mktemp; the shipped ledger is
# only read.
# shellcheck disable=SC2016 # fixture ledgers store the literal text `$HOME`.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/fm-konten-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASH_BIN="$(command -v bash)"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

H="$TMP/home"
FMHOME="$TMP/fmhome"
mkdir -p "$H/.claude" "$H/.claude1" "$H/.claude2" "$H/.claude3" "$FMHOME"

AKTE="$TMP/konten.tsv"
{
  printf '# fixture ledger\n'
  printf '# speicher\tpfad\tanthropic_konto\trolle\tbemerkung\n'
  printf 'basis\t$HOME/.claude\ta@example.org\tcaptain-handbetrieb\tnie Flotte\n'
  printf 'konto-1\t$HOME/.claude1\ta@example.org\toffiziere-worker\tOx-Sitz\n'
  printf 'konto-2\t$HOME/.claude2\tb@example.org\tfirstmate\tSitz\n'
  printf 'konto-3\t$HOME/.claude3\tc@example.org\trestverbrauch\tReserve\n'
} > "$AKTE"

# konto-2: onboarding done and the project trusted -> startable.
cat > "$H/.claude2/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {"$FMHOME": {"hasTrustDialogAccepted": true}}}
JSON
# konto-1: onboarding done, project NOT trusted.
cat > "$H/.claude1/.claude.json" <<JSON
{"hasCompletedOnboarding": true, "projects": {"/somewhere/else": {"hasTrustDialogAccepted": true}}}
JSON
# konto-3: onboarding never finished.
cat > "$H/.claude3/.claude.json" <<JSON
{"hasCompletedOnboarding": false, "projects": {"$FMHOME": {"hasTrustDialogAccepted": true}}}
JSON
# basis: no .claude.json at all.

run() { HOME="$H" FM_KONTEN_AKTE="$AKTE" "$LIB" "$@"; }

# --- 1. ledger selection and $HOME expansion -------------------------------
[ "$(run fm_konten_akte)" = "$AKTE" ] || fail "fm_konten_akte must honour FM_KONTEN_AKTE"
if [ "$(run fm_konto_pfad konto-2)" = "$H/.claude2" ]; then
  ok "fm_konto_pfad expands the stored \$HOME prefix against the live HOME"
else
  fail "fm_konto_pfad must expand \$HOME (got '$(run fm_konto_pfad konto-2)')"
fi
[ "$(run fm_konten_speicher | tr '\n' ' ')" = "basis konto-1 konto-2 konto-3 " ] \
  || fail "fm_konten_speicher must list the storages in ledger order, comments skipped"

# --- 2. seat lookup --------------------------------------------------------
[ "$(run fm_konto_rolle konto-2)" = "firstmate" ] || fail "fm_konto_rolle must read the rolle column"
[ "$(run fm_konto_fuer_rolle firstmate)" = "konto-2" ] || fail "fm_konto_fuer_rolle firstmate must find konto-2"
[ "$(run fm_firstmate_sitz)" = "konto-2" ] || fail "fm_firstmate_sitz must equal the firstmate row"
ok "seat lookup answers from the ledger"

# first row wins when a role is held more than once
AKTE_DOPPELT="$TMP/doppelt.tsv"
{
  printf 'konto-3\t$HOME/.claude3\tc@example.org\trestverbrauch\terste\n'
  printf 'konto-1\t$HOME/.claude1\ta@example.org\trestverbrauch\tzweite\n'
} > "$AKTE_DOPPELT"
if [ "$(HOME="$H" FM_KONTEN_AKTE="$AKTE_DOPPELT" "$LIB" fm_konto_fuer_rolle restverbrauch)" = "konto-3" ]; then
  ok "fm_konto_fuer_rolle returns the FIRST row holding the role"
else
  fail "fm_konto_fuer_rolle must return the first matching row"
fi

# --- 3. wrapper naming -----------------------------------------------------
[ "$(run fm_konto_wrapper basis)" = "claude" ] || fail "basis must map to wrapper claude"
[ "$(run fm_konto_wrapper konto-3)" = "claude3" ] || fail "konto-3 must map to wrapper claude3"
ok "wrapper naming follows the documented rule"

# --- 4. startability: RED without the condition, GREEN with it -------------
if out=$(run fm_konto_startfaehig konto-2 "$FMHOME" 2>&1); then
  ok "startfaehig is GREEN when onboarding is done and the project is trusted"
else
  fail "konto-2 must be startable (out=$out)"
fi

out=$(run fm_konto_startfaehig konto-1 "$FMHOME" 2>&1) && fail "konto-1 must be RED: project not trusted"
case $out in
  *"trust fehlt fuer $FMHOME"*) ok "missing trust dialog is RED and names the project path" ;;
  *) fail "missing trust must say 'trust fehlt fuer $FMHOME' (got: $out)" ;;
esac

out=$(run fm_konto_startfaehig konto-3 "$FMHOME" 2>&1) && fail "konto-3 must be RED: onboarding unfinished"
case $out in
  *"onboarding fehlt"*) ok "unfinished onboarding is RED and says so" ;;
  *) fail "unfinished onboarding must say 'onboarding fehlt' (got: $out)" ;;
esac

out=$(run fm_konto_startfaehig basis "$FMHOME" 2>&1) && fail "an absent .claude.json must be RED"
case $out in
  *"onboarding fehlt"*) ok "an absent .claude.json is RED, not an assumed yes" ;;
  *) fail "absent .claude.json must be RED with a reason (got: $out)" ;;
esac

printf 'kein json' > "$H/.claude3/.claude.json"
out=$(run fm_konto_startfaehig konto-3 "$FMHOME" 2>&1) && fail "an unparsable .claude.json must be RED"
case $out in
  *unlesbar*) ok "an unparsable .claude.json is RED" ;;
  *) fail "unparsable .claude.json must be RED with a reason (got: $out)" ;;
esac
cat > "$H/.claude3/.claude.json" <<JSON
{"hasCompletedOnboarding": false, "projects": {}}
JSON

# jq path: same verdicts without python3 on PATH.
if command -v jq >/dev/null 2>&1; then
  NOPY="$TMP/nopy"
  mkdir -p "$NOPY"
  ln -sf "$(command -v jq)" "$NOPY/jq"
  for tool in sed find sort head cut basename tr grep; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$NOPY/$tool"
  done
  if HOME="$H" FM_KONTEN_AKTE="$AKTE" PATH="$NOPY" "$BASH_BIN" "$LIB" fm_konto_startfaehig konto-2 "$FMHOME" >/dev/null 2>&1; then
    ok "the jq fallback reaches the same GREEN verdict without python3"
  else
    fail "the jq fallback must call konto-2 startable"
  fi
  out=$(HOME="$H" FM_KONTEN_AKTE="$AKTE" PATH="$NOPY" "$BASH_BIN" "$LIB" fm_konto_startfaehig konto-1 "$FMHOME" 2>&1) \
    && fail "the jq fallback must call konto-1 RED"
  case $out in
    *"trust fehlt fuer $FMHOME"*) ok "the jq fallback names the missing trust dialog" ;;
    *) fail "jq fallback must name the missing trust (got: $out)" ;;
  esac
else
  ok "jq absent - fallback path skipped"
fi

# no parser at all: RED and loud, never an assumed yes.
LEER="$TMP/leer"
mkdir -p "$LEER"
out=$(HOME="$H" FM_KONTEN_AKTE="$AKTE" PATH="$LEER" "$BASH_BIN" "$LIB" fm_konto_startfaehig konto-2 "$FMHOME" 2>&1) \
  && fail "without any JSON parser startability must NOT be assumed"
case $out in
  *"kein Parser"*) ok "a machine without python3/jq is RED and says why" ;;
  *) fail "missing parser must be RED with a reason (got: $out)" ;;
esac

# --- 5. loudness -----------------------------------------------------------
for fn in fm_konto_pfad fm_konto_rolle fm_konto_wrapper; do
  out=$(run "$fn" konto-9 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "unknown speicher 'konto-9'"; then
    ok "$fn aborts with status 2 on an unknown speicher"
  else
    fail "$fn must abort 2 and name the unknown speicher (rc=$rc out=$out)"
  fi
done
out=$(run fm_konto_startfaehig konto-9 "$FMHOME" 2>&1)
[ $? -eq 2 ] || fail "fm_konto_startfaehig must abort 2 on an unknown speicher (out=$out)"

AKTE_KAPUTT="$TMP/kaputt.tsv"
printf 'konto-2\t$HOME/.claude2\tb@example.org\tquatsch\tTippfehler\n' > "$AKTE_KAPUTT"
out=$(HOME="$H" FM_KONTEN_AKTE="$AKTE_KAPUTT" "$LIB" fm_konto_rolle konto-2 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "unknown rolle 'quatsch'"; then
  ok "an unknown rolle in the ledger aborts 2 instead of defaulting"
else
  fail "unknown rolle must abort 2 (rc=$rc out=$out)"
fi

out=$(HOME="$H" FM_KONTEN_AKTE="$AKTE_DOPPELT" "$LIB" fm_konto_fuer_rolle firstmate 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no speicher carries rolle 'firstmate'"; then
  ok "a role nobody holds exits 1 with a named reason"
else
  fail "an unheld role must exit 1 (rc=$rc out=$out)"
fi

out=$(run fm_konto_fuer_rolle grossadmiral 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "an unknown rolle argument must abort 2 (rc=$rc out=$out)"

# --- 6. the shipped ledger -------------------------------------------------
SHIPPED="$REPO/config/konten.tsv"
if [ -f "$SHIPPED" ]; then
  sitze=$(FM_KONTEN_AKTE="$SHIPPED" "$LIB" fm_konten_speicher)
  firstmates=0
  for s in $sitze; do
    FM_KONTEN_AKTE="$SHIPPED" "$LIB" fm_konto_wrapper "$s" >/dev/null \
      || fail "shipped ledger: $s has no wrapper naming rule"
    r=$(FM_KONTEN_AKTE="$SHIPPED" "$LIB" fm_konto_rolle "$s") \
      || fail "shipped ledger: $s carries an unknown rolle"
    [ "$r" = "firstmate" ] && firstmates=$((firstmates + 1))
  done
  if [ "$firstmates" -eq 1 ]; then
    ok "the shipped ledger has exactly one firstmate seat"
  else
    fail "the shipped ledger must carry exactly one firstmate seat (found $firstmates)"
  fi
else
  fail "config/konten.tsv is missing"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all konten-lib checks passed"
