#!/usr/bin/env bash
# tests/fm-lastverteilung.test.sh - the load balancer must take its seating
# order from the account ledger, not from literals:
#
#   1. The firstmate seat is excluded from every rank, wherever the ledger
#      puts it: moving the seat inside the fixture moves the exclusion. A seat
#      that is the ONLY well-filled storage is still not recommended.
#   2. `captain-handbetrieb` (basis) is never a target either - "nie Flotte".
#   3. basis IS read: it appears in the status report with its role, so the
#      ledger's full picture is visible even though it gets no work.
#   4. The hard weekly bar (SCHWELLE_WOCHE_HART) blocks an `offiziere-worker`
#      storage below the bar, but NOT a `restverbrauch` one (O-0085): with
#      only a 1%-week restverbrauch storage left, --worker recommends it
#      instead of refusing; flip that same row to offiziere-worker and the
#      refusal returns. That is the red/green pair for the exception.
#   5. An unreadable reading is never a number: a storage whose quota answer
#      is stale is skipped, and with nothing left --worker refuses loudly
#      (stderr + exit 1) instead of guessing.
#
# Isolation: fixture ledger, fixture HOME and wrapper dir under mktemp, and a
# PATH shim for quota-axi that answers from per-storage fixture files keyed by
# CLAUDE_CONFIG_DIR. No network, no real account, no real quota-axi.
# shellcheck disable=SC2016 # fixture ledgers store the literal text `$HOME`.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` is safe.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LB="$REPO/bin/fm-lastverteilung"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

H="$TMP/home"
SHIM="$TMP/shim"
WRAP="$TMP/wrapper"
QUOTA="$TMP/quota"
mkdir -p "$H" "$SHIM" "$WRAP" "$QUOTA"

for d in .claude .claude1 .claude2 .claude3; do
  mkdir -p "$H/$d"
  printf '{"claudeAiOauth":{"accessToken":"x"}}\n' > "$H/$d/.credentials.json"
  printf '{"hasCompletedOnboarding": true}\n' > "$H/$d/.claude.json"
done
for w in claude claude1 claude2 claude3; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WRAP/$w"
  chmod +x "$WRAP/$w"
done

# quota-axi shim: answers from $QUOTA/<basename of CLAUDE_CONFIG_DIR>.json.
cat > "$SHIM/quota-axi" <<'MOCK'
#!/usr/bin/env bash
datei="${FM_TEST_QUOTA_DIR:?}/$(basename "${CLAUDE_CONFIG_DIR:?}").json"
[ -f "$datei" ] || exit 1
cat "$datei"
MOCK
chmod +x "$SHIM/quota-axi"

lesung() { # lesung <speicherverzeichnis> <5h%> <woche% oder "keins"> [stale]
  local dir=$1 sess=$2 woche=$3 stale=${4:-}
  local w='' st='"status":"fresh"'
  [ "$woche" = keins ] || w=",{\"id\":\"seven_day\",\"kind\":\"subscription\",\"percentRemaining\":$woche}"
  [ -z "$stale" ] || st='"status":"stale","stale":true'
  cat > "$QUOTA/$dir.json" <<JSON
{"providers":[{"provider":"claude","state":{$st},
  "windows":[{"id":"five_hour","percentRemaining":$sess}$w]}]}
JSON
}

akte() { # akte <pfad> <rolle-basis> <rolle-1> <rolle-2> <rolle-3>
  {
    printf '# fixture ledger\n'
    printf 'basis\t$HOME/.claude\ta@example.org\t%s\tfixture\n' "$2"
    printf 'konto-1\t$HOME/.claude1\ta@example.org\t%s\tfixture\n' "$3"
    printf 'konto-2\t$HOME/.claude2\tb@example.org\t%s\tfixture\n' "$4"
    printf 'konto-3\t$HOME/.claude3\tc@example.org\t%s\tfixture\n' "$5"
  } > "$1"
}

lauf() { # lauf <akte> [args...]
  local a=$1; shift
  HOME="$H" PATH="$SHIM:$PATH" FM_TEST_QUOTA_DIR="$QUOTA" \
    FM_KONTEN_AKTE="$a" FM_LB_WRAPPER_DIR="$WRAP" \
    FM_LB_NM_CONFIG="$TMP/nm.yaml" "$LB" "$@"
}

printf 'claude: %s\n' "$WRAP/claude1" > "$TMP/nm.yaml"

# --- 1. the firstmate seat is excluded, wherever the ledger puts it ---------
A="$TMP/akte-sitz2.tsv"
akte "$A" captain-handbetrieb offiziere-worker firstmate offiziere-worker
lesung .claude   90 90        # basis: full, but never fleet
lesung .claude1  30 60        # ordinary worker storage
lesung .claude2  99 99        # the seat: fullest of all
lesung .claude3  50 50        # ordinary worker storage
GOT="$(lauf "$A" --worker 2>"$TMP/e")"
[ "$GOT" = "$H/.claude3" ] \
  && ok "the seat (konto-2, fullest) is excluded; the best non-seat storage wins" \
  || fail "expected $H/.claude3, got '$GOT' ($(cat "$TMP/e"))"

A2="$TMP/akte-sitz3.tsv"
akte "$A2" captain-handbetrieb offiziere-worker offiziere-worker firstmate
GOT="$(lauf "$A2" --worker 2>"$TMP/e")"
[ "$GOT" = "$H/.claude2" ] \
  && ok "moving the seat to konto-3 moves the exclusion with it" \
  || fail "expected $H/.claude2 after the seat move, got '$GOT' ($(cat "$TMP/e"))"

# The seat as the ONLY well-filled storage must still not be recommended.
A3="$TMP/akte-nurseat.tsv"
akte "$A3" captain-handbetrieb firstmate offiziere-worker offiziere-worker
lesung .claude1  99 99        # now the seat
lesung .claude2   4  2        # below the hard weekly bar, ordinary role
lesung .claude3   4  1        # below the hard weekly bar, ordinary role
OUT="$(lauf "$A3" --worker 2>&1)" && RC=0 || RC=$?
[ "$RC" = 1 ] && ok "a full seat is never recommended - the balancer refuses instead" \
  || fail "the balancer must refuse rather than hand out the seat (rc=$RC, out=$OUT)"
printf '%s\n' "$OUT" | grep -q 'Captain fragen' \
  && ok "the refusal is loud and names the way out" \
  || fail "the refusal must name a way out: $OUT"

# --- 2./3. basis is read but never a target --------------------------------
lesung .claude   95 95
lesung .claude1  30 60
lesung .claude2  99 99
lesung .claude3  50 50
REPORT="$(lauf "$A" --pruefen 2>&1)"
printf '%s\n' "$REPORT" | grep -q 'basis \[captain-handbetrieb\]: 5h-Fenster 95%' \
  && ok "basis is read and reported with its role from the ledger" \
  || fail "the report must cover basis: $REPORT"
GOT="$(lauf "$A" --worker 2>/dev/null)"
[ "$GOT" != "$H/.claude" ] \
  && ok "basis (captain-handbetrieb) is never handed out as a worker account" \
  || fail "basis must never be a distribution target"
printf '%s\n' "$REPORT" | grep -q 'konto-2 \[firstmate\]' \
  && ok "the report names the seat's role from the ledger" \
  || fail "the report must show the firstmate role: $REPORT"

# --- 4. the restverbrauch exception to the hard weekly bar (O-0085) --------
# Only one candidate is left and it sits at 1% week - below SCHWELLE_WOCHE_HART.
A4="$TMP/akte-rest.tsv"
akte "$A4" captain-handbetrieb firstmate offiziere-worker restverbrauch
lesung .claude   95 95
lesung .claude1  99 99        # seat
lesung .claude2   3  2        # ordinary role, under the hard bar -> blocked
lesung .claude3  80  1        # restverbrauch, under the hard bar -> allowed
GOT="$(lauf "$A4" --worker 2>"$TMP/e")"
[ "$GOT" = "$H/.claude3" ] \
  && ok "a restverbrauch storage under the hard weekly bar is still handed out (O-0085)" \
  || fail "the restverbrauch exception must apply, got '$GOT' ($(cat "$TMP/e"))"

# Same numbers, same ledger, only the role flipped -> the bar applies again.
A5="$TMP/akte-norest.tsv"
akte "$A5" captain-handbetrieb firstmate offiziere-worker offiziere-worker
OUT="$(lauf "$A5" --worker 2>&1)" && RC=0 || RC=$?
[ "$RC" = 1 ] \
  && ok "the same storage as offiziere-worker is blocked by the hard weekly bar" \
  || fail "without the restverbrauch role the hard bar must block (rc=$RC, out=$OUT)"

# The exception is an exception, not a promotion: a healthy ordinary storage
# still outranks a restverbrauch one that is down to its last week percent.
A6="$TMP/akte-rangfolge.tsv"
akte "$A6" captain-handbetrieb firstmate offiziere-worker restverbrauch
lesung .claude2  70 70        # healthy ordinary storage
lesung .claude3  80  1        # restverbrauch, week nearly gone
GOT="$(lauf "$A6" --worker 2>/dev/null)"
[ "$GOT" = "$H/.claude2" ] \
  && ok "the exception does not promote: a healthy ordinary storage still wins" \
  || fail "expected the healthy storage $H/.claude2, got '$GOT'"

# --- 5. a stale reading is never a number ----------------------------------
A7="$TMP/akte-stale.tsv"
akte "$A7" captain-handbetrieb firstmate offiziere-worker offiziere-worker
lesung .claude2  90 90 stale
lesung .claude3  90 90 stale
OUT="$(lauf "$A7" --worker 2>&1)" && RC=0 || RC=$?
[ "$RC" = 1 ] && ok "stale readings never become numbers - the balancer refuses" \
  || fail "a stale-only fleet must refuse, got rc=$RC: $OUT"
REPORT="$(lauf "$A7" --pruefen 2>&1)"
printf '%s\n' "$REPORT" | grep -q 'konto-2 \[offiziere-worker\]: UNLESBAR' \
  && ok "the stale storage is reported as UNLESBAR, not as a percentage" \
  || fail "a stale reading must be reported as UNLESBAR: $REPORT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-lastverteilung.test.sh: all checks passed"
  exit 0
fi
echo "fm-lastverteilung.test.sh: $FAILS check(s) FAILED"
exit 1
