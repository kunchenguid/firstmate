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
#   6. The summary-vs-full resume chooser is ANSWERED, never reported: the
#      measured harness wording (claude 2.1.246 bundle; seen live 26.08.2026,
#      journal data/umbau-2026-08/journal.md) is recognized, the default
#      (summary) gets a bounded number of Enters, exhaustion aborts loudly
#      without arming a kicker, and a healthy revival gets no stray Enter.
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

# --- 6. the summary-vs-full resume chooser is answered, never reported ------
# Fixture wording measured from the harness itself, not guessed: the question
# sentence and the three option labels are verbatim bundle strings of the
# installed claude 2.1.246 (strings extraction, 26.08.2026), and the 9h44m /
# 540k title values are the variant observed live in the journal entry of the
# same day. The numbered "N. label" row shape is the verified menu rendering
# already documented in bin/fm-anstoss.sh dialog_choice_pending.
CAP_DIALOG="$(cat <<'DIALOG'
This session is 9h44m old and 540k tokens.
Resuming the full session will consume a substantial portion of your usage limits. We recommend resuming from a summary.
1. Resume from summary (recommended)
2. Resume full session as-is
3. Don't ask me again
DIALOG
)"

"$LIB" fm_totmann_resume_dialog_pending "$CAP_DIALOG" \
  && ok "the measured resume-chooser wording is recognized" \
  || fail "the resume chooser fixture must be recognized as pending"

if "$LIB" fm_totmann_resume_dialog_pending "$CAP_OK" >/dev/null 2>&1; then
  fail "a healthy capture must not read as an open chooser"
else
  ok "a healthy capture is not an open chooser (no stray Enter)"
fi

if "$LIB" fm_totmann_resume_dialog_pending "$CAP_TRUST" >/dev/null 2>&1; then
  fail "the trust dialog must not read as the resume chooser"
else
  ok "other open dialogs are not mistaken for the resume chooser"
fi

if "$LIB" fm_totmann_resume_dialog_pending "" >/dev/null 2>&1; then
  fail "an empty capture must not read as an open chooser"
else
  ok "an empty capture is not an open chooser"
fi

OUT="$("$LIB" fm_totmann_resume_dialog_pending "$CAP_DIALOG" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 0 ] \
  && ok "the execute-mode CLI exposes the chooser predicate" \
  || fail "the lib CLI must whitelist fm_totmann_resume_dialog_pending (rc=$RC: $OUT)"

# End to end: a second tmux mock whose FIRST capture serves the open chooser
# and every later capture the healthy pane - the answer Enter visibly flips
# the pane. claw-notify falls through to the existing shim on PATH.
SHIM2="$TMP/shim-dialog"
mkdir -p "$SHIM2"
cat > "$SHIM2/tmux" <<'MOCK'
#!/usr/bin/env bash
# tmux mock (dialog variant): like the shim above, but the first capture-pane
# serves $MOCK_CAPTURE.offen and moves it away, so a later capture reads clean.
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
case "$1" in
  display-message) [ -n "${MOCK_PANE_PID:-}" ] && printf '%s\n' "$MOCK_PANE_PID"; exit 0 ;;
  has-session)     exit 0 ;;
  capture-pane)
    if [ -f "${MOCK_CAPTURE:?}.offen" ]; then
      cat "${MOCK_CAPTURE}.offen"
      mv "${MOCK_CAPTURE}.offen" "${MOCK_CAPTURE}.beantwortet"
    else
      cat "${MOCK_CAPTURE:?}"
    fi ;;
  send-keys)       shift 3; printf 'keys:%s\n' "$*" >> "$MOCK_LOG" ;;
  *)               exit 0 ;;
esac
MOCK
chmod +x "$SHIM2/tmux"

e2e_dialog() { # e2e_dialog <capture-file> <log> <notify-log>
  MOCK_LOG="$2" MOCK_NOTIFY="$3" MOCK_CAPTURE="$1" \
  PATH="$SHIM2:$SHIM:$PATH" HOME="$H" FM_HOME="$FMH" \
  FM_TOTMANN_TARGET="fmtest:0" FM_TOTMANN_DEBOUNCE=0 FM_TOTMANN_ERGEBNIS_SECS=1 \
  FM_TOTMANN_PROC_STAT="$TMP/procstat" FM_TOTMANN_ANSTOSS="$KICK" \
  FM_TOTMANN_NOTIFY="claw-notify" \
  "$TOTMANN" check
}

enter_count() { grep -c '^keys:Enter$' "$1" 2>/dev/null || true; }

# 6a. chooser opens right after the relaunch -> one default answer, revival completes
printf '%s\n' "$CAP_DIALOG" > "$TMP/cap-dialog.offen"
cp "$TMP/cap-ok" "$TMP/cap-dialog"
: > "$TMP/e2e-dlg.log"; : > "$TMP/e2e-dlg.notify"
OUT="$(e2e_dialog "$TMP/cap-dialog" "$TMP/e2e-dlg.log" "$TMP/e2e-dlg.notify" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 0 ] && ok "a revived session stopped at the chooser still completes (exit 0)" \
  || fail "answering the chooser must complete the revival, got rc=$RC: $OUT"
[ "$(enter_count "$TMP/e2e-dlg.log")" = 1 ] \
  && ok "exactly one answer Enter goes to the chooser" \
  || fail "the chooser must receive exactly one Enter, got $(enter_count "$TMP/e2e-dlg.log"): $(cat "$TMP/e2e-dlg.log")"
grep -q '^keys:claude3 --continue Enter$' "$TMP/e2e-dlg.log" \
  && ok "the relaunch is typed before the chooser answer" \
  || fail "the relaunch must precede the chooser answer: $(cat "$TMP/e2e-dlg.log")"
grep -q '^kicker:' "$TMP/e2e-dlg.log" \
  && ok "the answered chooser still arms the kicker" \
  || fail "a completed revival must arm the kicker: $(cat "$TMP/e2e-dlg.log")"

# 6b. chooser stays open despite Enters -> bounded attempts, loud abort, no kicker
printf '%s\n' "$CAP_DIALOG" > "$TMP/cap-stuck"
: > "$TMP/e2e-stuck.log"; : > "$TMP/e2e-stuck.notify"
OUT="$(e2e_dialog "$TMP/cap-stuck" "$TMP/e2e-stuck.log" "$TMP/e2e-stuck.notify" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 3 ] && ok "a chooser that survives every answer aborts with exit 3" \
  || fail "an unanswerable chooser must abort (exit 3), got rc=$RC: $OUT"
[ "$(enter_count "$TMP/e2e-stuck.log")" = 3 ] \
  && ok "the answer retries stay bounded (3 Enters)" \
  || fail "the retry budget must be 3, got $(enter_count "$TMP/e2e-stuck.log")"
if grep -q 'FEHLSTART' "$TMP/e2e-stuck.log" || printf '%s\n' "$OUT" | grep -q 'FEHLSTART'; then
  ok "the exhaustion is loud (FEHLSTART named)"
else
  fail "exhaustion must say FEHLSTART loudly: $OUT"
fi
grep -q '^kicker:' "$TMP/e2e-stuck.log" \
  && fail "no kicker may be armed while the chooser is stuck open" \
  || ok "an exhausted chooser arms no kicker"

# 6c. a healthy revival gets no stray Enter at all
: > "$TMP/e2e-clean.log"; : > "$TMP/e2e-clean.notify"
OUT="$(e2e_dialog "$TMP/cap-ok" "$TMP/e2e-clean.log" "$TMP/e2e-clean.notify" 2>&1)" && RC=0 || RC=$?
if [ "$RC" = 0 ] && [ "$(enter_count "$TMP/e2e-clean.log")" = 0 ]; then
  ok "a healthy revival types no bare Enter"
else
  fail "a healthy revival must not send a bare Enter (rc=$RC, ent=$(enter_count "$TMP/e2e-clean.log"))"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-totmann-relaunch.test.sh: all checks passed"
  exit 0
fi
echo "fm-totmann-relaunch.test.sh: $FAILS check(s) FAILED"
exit 1
