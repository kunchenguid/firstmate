#!/usr/bin/env bash
# tests/fm-totmann-relaunch.test.sh - the dead-man's account half:
#
#   1. The relaunch default is DERIVED from the account ledger, not literal:
#      a fixture ledger seating `firstmate` on konto-3 yields `claude3
#      --continue`, and moving the seat inside the fixture moves the command.
#   2. A ledger without a firstmate seat is a loud refusal (status 2), never a
#      guessed wrapper - RED without the ledger read, GREEN with it.
#   3. FM_TOTMANN_RELAUNCH_CMD still overrides the derived default.
#   4. The result check reads the pane back: a capture holding `No conversation
#      found` (the measured failure after a seat move), the onboarding wizard
#      or the trust dialog is a failed start with a named reason and a named
#      way out; a normal capture is not.
#   5. End to end through bin/fm-totmann.sh with a mocked tmux on PATH: a dead
#      session whose pane answers `No conversation found` aborts the revival
#      episode (exit 3, loud message naming config/konten.tsv) and arms NO
#      kicker; the same run against a healthy pane revives and arms one.
#
# Isolation: fixture ledger, fixture HOME and FM_HOME under mktemp, tmux and
# the notifier replaced by PATH shims that only write log files. Nothing
# touches the live fleet, the real ledger or a real tmux server.
# shellcheck disable=SC2016 # fixture ledgers store the literal text `$HOME`.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` is safe.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/bin/fm-totmann-relaunch-lib.sh"
TOTMANN="$REPO/bin/fm-totmann.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

H="$TMP/home"
mkdir -p "$H"

akte_schreiben() { # akte_schreiben <pfad> <speicher-mit-firstmate-rolle|->
  local ziel=$1 sitz=$2 s rolle
  {
    printf '# fixture ledger\n'
    printf '# speicher\tpfad\tanthropic_konto\trolle\tbemerkung\n'
    for s in basis konto-1 konto-2 konto-3; do
      if [ "$s" = "$sitz" ]; then rolle=firstmate
      elif [ "$s" = basis ]; then rolle=captain-handbetrieb
      else rolle=offiziere-worker
      fi
      case $s in
        basis) printf 'basis\t$HOME/.claude\ta@example.org\t%s\tfixture\n' "$rolle" ;;
        *)     printf '%s\t$HOME/.%s\ta@example.org\t%s\tfixture\n' "$s" "claude${s#konto-}" "$rolle" ;;
      esac
    done
  } > "$ziel"
}

# --- 1. the default follows the seat in the ledger --------------------------
AKTE="$TMP/konten-3.tsv"
akte_schreiben "$AKTE" konto-3
GOT="$(HOME="$H" FM_KONTEN_AKTE="$AKTE" "$LIB" fm_totmann_relaunch_default 2>"$TMP/err1")"
[ "$GOT" = "claude3 --continue" ] \
  && ok "the relaunch default is derived from the ledger seat (konto-3 -> claude3 --continue)" \
  || fail "expected 'claude3 --continue' from the fixture ledger, got '$GOT' ($(cat "$TMP/err1"))"

AKTE2="$TMP/konten-1.tsv"
akte_schreiben "$AKTE2" konto-1
GOT2="$(HOME="$H" FM_KONTEN_AKTE="$AKTE2" "$LIB" fm_totmann_relaunch_default 2>/dev/null)"
[ "$GOT2" = "claude1 --continue" ] \
  && ok "moving the seat in the ledger moves the relaunch command" \
  || fail "a seat on konto-1 must yield 'claude1 --continue', got '$GOT2'"

AKTE_B="$TMP/konten-basis.tsv"
akte_schreiben "$AKTE_B" basis
GOT_B="$(HOME="$H" FM_KONTEN_AKTE="$AKTE_B" "$LIB" fm_totmann_relaunch_default 2>/dev/null)"
[ "$GOT_B" = "claude --continue" ] \
  && ok "a seat on basis yields the unnumbered wrapper" \
  || fail "a seat on basis must yield 'claude --continue', got '$GOT_B'"

# --- 2. no seat in the ledger -> loud refusal, never a guess ----------------
AKTE_NONE="$TMP/konten-none.tsv"
akte_schreiben "$AKTE_NONE" -
OUT="$(HOME="$H" FM_KONTEN_AKTE="$AKTE_NONE" "$LIB" fm_totmann_relaunch_default 2>&1)" && RC=0 || RC=$?
[ "$RC" = 2 ] && ok "a ledger without a firstmate seat exits 2" \
  || fail "a seatless ledger must exit 2, got rc=$RC ($OUT)"
[ -z "$(HOME="$H" FM_KONTEN_AKTE="$AKTE_NONE" "$LIB" fm_totmann_relaunch_default 2>/dev/null)" ] \
  && ok "a seatless ledger prints no guessed command" \
  || fail "a seatless ledger must print nothing on stdout"

MISSING="$TMP/gibt-es-nicht.tsv"
OUT="$(HOME="$H" FM_KONTEN_AKTE="$MISSING" "$LIB" fm_totmann_relaunch_default 2>&1)" && RC=0 || RC=$?
[ "$RC" = 2 ] && ok "a missing ledger file exits 2 as well" \
  || fail "a missing ledger must exit 2, got rc=$RC ($OUT)"

# --- 4. the result check names the failure ---------------------------------
CAP_TOT="$(printf 'fridjof@box:~/firstmate$ claude3 --continue\nNo conversation found\nfridjof@box:~/firstmate$ \n')"
G="$("$LIB" fm_totmann_fehlstart_grund "$CAP_TOT")" && RC=0 || RC=$?
[ "$RC" = 0 ] && ok "a 'No conversation found' capture is recognized as a failed start" \
  || fail "'No conversation found' must be a failed start"
case "$G" in *"--continue ins Leere"*) ok "the failure is named, not just flagged" ;;
  *) fail "expected the empty --continue reason, got '$G'" ;; esac
A="$("$LIB" fm_totmann_fehlstart_ausweg "$G")"
[ -n "$A" ] && ok "the failed start carries a way out: $A" || fail "a failed start must name a way out"

CAP_TRUST="$(printf 'Do you trust the files in this folder?\n 1. Yes, proceed\n')"
"$LIB" fm_totmann_fehlstart_grund "$CAP_TRUST" >/dev/null \
  && ok "an open trust dialog is a failed start" \
  || fail "the trust dialog must count as a failed start"
CAP_ONB="$(printf 'Welcome to Claude Code\nChoose the text style that looks best\n')"
"$LIB" fm_totmann_fehlstart_grund "$CAP_ONB" >/dev/null \
  && ok "an open onboarding wizard is a failed start" \
  || fail "the onboarding wizard must count as a failed start"

CAP_OK="$(printf '> Try "how does the ledger work"\n  esc to interrupt\n')"
if "$LIB" fm_totmann_fehlstart_grund "$CAP_OK" >/dev/null 2>&1; then
  fail "a healthy capture must NOT read as a failed start"
else
  ok "a healthy capture is not a failed start (no false alarm)"
fi

# --- 5. end to end through fm-totmann.sh with a mocked tmux ----------------
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<'MOCK'
#!/usr/bin/env bash
# tmux mock: answers only what the dead-man asks, records send-keys, and serves
# the pane capture from $MOCK_CAPTURE. Never talks to a tmux server.
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
case "$1" in
  display-message) [ -n "${MOCK_PANE_PID:-}" ] && printf '%s\n' "$MOCK_PANE_PID"; exit 0 ;;
  has-session)     exit 0 ;;
  capture-pane)    cat "${MOCK_CAPTURE:?}" ;;
  send-keys)       shift 3; printf 'keys:%s\n' "$*" >> "$MOCK_LOG" ;;
  *)               exit 0 ;;
esac
MOCK
cat > "$SHIM/claw-notify" <<'MOCK'
#!/usr/bin/env bash
printf 'notify:%s\n' "$1" >> "${MOCK_NOTIFY:?}"
MOCK
chmod +x "$SHIM/tmux" "$SHIM/claw-notify"

FMH="$TMP/fmhome"
mkdir -p "$FMH/state" "$FMH/config"
cp "$AKTE" "$FMH/config/konten.tsv"   # seat on konto-3, `$HOME` expanded on read
KICK="$TMP/kicker"
cat > "$KICK" <<'MOCK'
#!/usr/bin/env bash
printf 'kicker:%s\n' "$*" >> "${MOCK_LOG:?}"
MOCK
chmod +x "$KICK"
printf 'not-a-procstat\n' > "$TMP/procstat"   # pins day-hang mode

e2e() { # e2e <capture-file> <log> <notify-log>
  MOCK_LOG="$2" MOCK_NOTIFY="$3" MOCK_CAPTURE="$1" \
  PATH="$SHIM:$PATH" HOME="$H" FM_HOME="$FMH" \
  FM_TOTMANN_TARGET="fmtest:0" FM_TOTMANN_DEBOUNCE=0 FM_TOTMANN_ERGEBNIS_SECS=1 \
  FM_TOTMANN_PROC_STAT="$TMP/procstat" FM_TOTMANN_ANSTOSS="$KICK" \
  FM_TOTMANN_NOTIFY="claw-notify" \
  "$TOTMANN" check
}

# The mock reports NO pane pid at all -> the verdict is "dead: no live lock
# holder and no pane", which is exactly the reboot path the revival must take.
printf 'fridjof@box:~$ claude3 --continue\nNo conversation found\nfridjof@box:~$ \n' > "$TMP/cap-tot"
printf '> ready\n  esc to interrupt\n' > "$TMP/cap-ok"

: > "$TMP/e2e-tot.log"; : > "$TMP/e2e-tot.notify"
OUT="$(e2e "$TMP/cap-tot" "$TMP/e2e-tot.log" "$TMP/e2e-tot.notify" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 3 ] && ok "a failed start aborts the revival episode with exit 3" \
  || fail "a failed start must exit 3, got rc=$RC: $OUT"
grep -q 'keys:claude3 --continue' "$TMP/e2e-tot.log" \
  && ok "the seat derived from FM_HOME/config/konten.tsv was typed (claude3 --continue)" \
  || fail "the ledger-derived relaunch must be typed: $(cat "$TMP/e2e-tot.log")"
printf '%s\n' "$OUT" | grep -q 'konten.tsv' \
  && ok "the refusal names its source (config/konten.tsv)" \
  || fail "the loud refusal must name config/konten.tsv: $OUT"
printf '%s\n' "$OUT" | grep -qi 'ausweg' \
  && ok "the refusal names a way out" || fail "the refusal must name a way out: $OUT"
grep -q '^notify:' "$TMP/e2e-tot.notify" \
  && ok "the failed start reaches the notifier" \
  || fail "a failed start must notify the captain"
grep -q '^kicker:' "$TMP/e2e-tot.log" \
  && fail "a failed start must NOT arm the kicker" \
  || ok "no kicker is armed into a dead shell"

: > "$TMP/e2e-ok.log"; : > "$TMP/e2e-ok.notify"
OUT="$(e2e "$TMP/cap-ok" "$TMP/e2e-ok.log" "$TMP/e2e-ok.notify" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 0 ] && ok "a healthy start completes the revival (exit 0)" \
  || fail "a healthy revival must exit 0, got rc=$RC: $OUT"
grep -q '^kicker:--hintergrund fmtest:0 ' "$TMP/e2e-ok.log" \
  && ok "a healthy revival arms the kicker" \
  || fail "the healthy revival must arm the kicker: $(cat "$TMP/e2e-ok.log")"

# --- 3. the explicit override still wins -----------------------------------
: > "$TMP/e2e-ov.log"; : > "$TMP/e2e-ov.notify"
MOCK_LOG="$TMP/e2e-ov.log" MOCK_NOTIFY="$TMP/e2e-ov.notify" MOCK_CAPTURE="$TMP/cap-ok" \
PATH="$SHIM:$PATH" HOME="$H" FM_HOME="$FMH" FM_TOTMANN_TARGET="fmtest:0" \
FM_TOTMANN_DEBOUNCE=0 FM_TOTMANN_ERGEBNIS_SECS=0 FM_TOTMANN_PROC_STAT="$TMP/procstat" \
FM_TOTMANN_ANSTOSS="$KICK" FM_TOTMANN_NOTIFY="" \
FM_TOTMANN_RELAUNCH_CMD="eigener-start --jetzt" "$TOTMANN" check >/dev/null 2>&1
grep -q 'keys:eigener-start --jetzt' "$TMP/e2e-ov.log" \
  && ok "FM_TOTMANN_RELAUNCH_CMD still overrides the ledger default" \
  || fail "the explicit override must win: $(cat "$TMP/e2e-ov.log")"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-totmann-relaunch.test.sh: all checks passed"
  exit 0
fi
echo "fm-totmann-relaunch.test.sh: $FAILS check(s) FAILED"
exit 1
