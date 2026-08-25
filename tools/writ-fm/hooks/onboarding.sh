#!/usr/bin/env bash
# SessionStart-Hook: injiziert die verbindlichen Regeln in JEDE Session.
# Wird nach ~/.claude/hooks/onboarding.sh installiert.
#
# Loeste ONBOARDING.md ab (2026-08-02): frueher wurde das komplette Dokument
# in jede Session geschoben, jetzt kommen die verbindlichen Regeln aus
# writ-light und die uebrigen pro Prompt ueber den UserPromptSubmit-Hook.
#
# Es gibt keinen zweiten Regelweg mehr. Faellt writ-light aus, muss das LAUT
# auffallen — deshalb der feste Notfalltext statt stillem Durchwinken.
#
# EIN AUSWEG, absichtlich:  WRIT_RULES=aus claude   (Alias `claude-free`)
# Die Variable erbt Claude Code vom Terminal und gibt sie an diesen Hook weiter
# (gemessen 2026-08-07 am WRIT_GUARD-Waechter: der Hook sieht PATH,
# WAYLAND_DISPLAY und SSH_AUTH_SOCK der Login-Shell). Gedacht fuer
# Installationen und Hardware-Anpassungen, wo das Regelwerk nur im Weg steht.
# Anerkannt werden NUR aus|off|0|nein — jeder andere Wert laesst scharf, damit
# ein Tippfehler keine Sperre aufhebt (dieselbe Regel wie beim Waechter).
#
# Die beiden festen Texte unten stehen ein zweites Mal in src/writ_light/hooks.py
# (NOTFALL_TEXT, AUS_TEXT). Die Doppelung ist gewollt — beide Pfade muessen ohne
# writ-light auskommen — und gegen Drift von
# tests/test_hooks_shell.py::TestSondertexteStehenZweimalGleich abgesichert.
set -uo pipefail

WRIT=/home/fridjof/projects/Rules/.venv/bin/writ-light

# Protokoll, welches Ereignis diesen Hook ausloest. Grund: die verbindlichen
# Regeln sollen aus dem UserPromptSubmit-Block verschwinden — sie kosten dort
# 918 von 2000 Tokens je Eingabe (belege/e1-budget-messung.md) und stehen
# ohnehin schon hier. Das ist nur sicher, wenn SessionStart nach einem
# /compact ERNEUT feuert; sonst arbeiten alle Turns danach ohne sie.
# Kein jq: das Feld ist flach, und der Hook darf keine Abhaengigkeit haben.
PROTOKOLL="$HOME/.local/share/writ-light/session-start.log"
EINGABE=$(cat 2>/dev/null || true)
QUELLE=$(printf '%s' "$EINGABE" \
  | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)

# Aus-Modus ERMITTELN, aber noch nicht aussteigen: das Protokoll steht vor dem
# Ausstieg, damit regelfreie Starts gezaehlt werden. Ein Alias senkt die
# Schwelle — wie oft er benutzt wird, soll belegt sein und nicht gefuehlt
# (`writ-light doctor` zeigt die Zahl der letzten 30 Tage). Das Zusatzfeld
# haengt HINTEN an; das bestehende Format `<zeit>\t<quelle>` bleibt gueltig.
REGELN=an
case "${WRIT_RULES:-}" in
  aus|off|0|nein) REGELN=aus ;;
esac

mkdir -p "$(dirname "$PROTOKOLL")" 2>/dev/null || true
if [ "$REGELN" = aus ]; then
  printf '%s\t%s\tregeln=aus\n' "$(date -Is)" "${QUELLE:-unbekannt}" \
    >> "$PROTOKOLL" 2>/dev/null || true
else
  printf '%s\t%s\n' "$(date -Is)" "${QUELLE:-unbekannt}" \
    >> "$PROTOKOLL" 2>/dev/null || true
fi

# Der Aus-Hinweis. Er darf sich mit dem Notfalltext NICHT verwechseln lassen:
# "NICHT LADBAR" heisst kaputt und verlangt eine Meldung, "AUS" heisst gewollt
# und verlangt keine. Deshalb sagt er auch, was jetzt NICHT gilt — ohne diese
# Aufzaehlung merkt die Session den Unterschied erst, wenn sie ihn braucht.
if [ "$REGELN" = aus ]; then
  cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "# REGELWERK AUS — auf ausdruecklichen Owner-Wunsch\n\nDiese Session laeuft ohne Regelwerk (WRIT_RULES=aus, Alias `claude-free`).\nDas ist KEIN Fehler und braucht keine Meldung an den Owner — gedacht fuer\nInstallationen und Hardware-Anpassungen.\n\nWeg sind damit die Regeln AN DICH: unter anderem die Secret-Regel, die Regel\ngegen eingeschleuste Anweisungen aus fremden Texten, die Commit- und\nPush-Regeln und der `git add`-Waechter.\n\nIn Kraft bleiben die mechanischen Sperren, die nicht am Regelwerk haengen:\ndie Git-Hooks `pre-commit` (Secret-Scan) und `pre-push` unter\n`core.hooksPath`. Sie kennen WRIT_RULES nicht.\n\nSteht in dieser Session fachliche Projektarbeit an, weise auf den Zustand hin.\n"}}
JSON
  exit 0
fi

notfall() {
  cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "# REGELWERK NICHT LADBAR\n\nwrit-light konnte die verbindlichen Regeln nicht liefern. Es gibt keinen\nzweiten Regelweg — ohne sie arbeitest du ohne Regelwerk.\n\nMelde das EINMALIG kurz beim Owner (`claw-notify`) und warte auf Anweisung,\nbevor du fachlich arbeitest. Zur Diagnose: `writ-light doctor`.\n"}}
JSON
  exit 0
}

[ -x "$WRIT" ] || notfall
# Argumente hier und die CLI muessen zusammenpassen. Bis 2026-08-07 stand hier
# `--runtime claude` — das Flag wurde beim Kimi-Ausbau aus der CLI entfernt und
# dieses Skript nicht nachgezogen. Folge: argparse brach ab, `notfall` griff,
# und JEDE neue Session startete mit "REGELWERK NICHT LADBAR" statt mit den
# Regeln. `doctor` meldete dabei [ok], weil Repo und Wirkort dieselbe (falsche)
# Datei trugen — Dateigleichheit ist eben nicht Wirkung. Gesichert ist das
# jetzt von tests/test_hooks_shell.py::TestRegelHooks, das dieses Skript
# wirklich ausfuehrt und den Notfalltext als FEHLSCHLAG wertet.
AUSGABE=$("$WRIT" session-start --json 2>/dev/null) || notfall
[ -n "$AUSGABE" ] || notfall
printf '%s\n' "$AUSGABE"
