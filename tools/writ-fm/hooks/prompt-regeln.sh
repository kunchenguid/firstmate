#!/usr/bin/env bash
# UserPromptSubmit-Hook: liefert pro Eingabe die dazu passenden Regeln.
# Wird nach ~/.claude/hooks/prompt-regeln.sh installiert.
#
# Modus A der Spezifikation: das Skript wird je Prompt aufgerufen, laedt
# Modell und Indizes KALT und gibt den Regelblock auf stdout aus. Claude Code
# uebernimmt stdout als Kontext.
#
# Laufzeit, gemessen 2026-08-07: 2,3 bis 2,9 s je Eingabe. Davon 1,9 s
# Modellladen, 0,2 s Importe, 0,12 s die eigentliche Suche — der Rest ist
# Python-Start. Hier stand bis zu diesem Tag "rund eine Sekunde"; die Zahl
# war aus einer frueheren Messung und niemand hat sie nachgezogen. Deshalb
# steht sie jetzt mit Datum da und mit dem Befehl, der sie erneuert:
#
#   belege/e1-budget-messung.md, Abschnitt "Laufzeit"
#
# Die Kaltladezeit ist der Preis dafuer, dass kein Daemon laeuft. Das ist
# eine Entwurfsentscheidung (regel-retrieval-light.md), keine Nachlaessigkeit.
#
# Anders als beim Session-Start wird hier NICHT gewarnt: ein Ausfall kostet
# nur die gerankten Zusatzregeln — die verbindlichen hat der Session-Start
# gesetzt, und seit 2026-08-07 stehen sie in diesem Block ohnehin nur als
# ID-Zeile (E1, belege/e1-budget-messung.md). Eine Warnung bei jeder Eingabe
# waere nur Laerm.
set -uo pipefail

# Regelwerk fuer diese Session abgeschaltet (WRIT_RULES=aus, Alias
# `claude-free`)? Dann OHNE Ausgabe aussteigen — und zwar schweigend.
# Der Session-Start hat den Zustand bereits angesagt; eine Wiederholung bei
# JEDER Eingabe waere nur Laerm, genauso wie die hier bewusst unterlassene
# Ausfallwarnung (siehe Kopf). Dieselben vier Werte wie ueberall: ein
# Tippfehler darf das Regelwerk nicht abschalten.
case "${WRIT_RULES:-}" in
  aus|off|0|nein) exit 0 ;;
esac

WRIT=/home/fridjof/projects/Rules/.venv/bin/writ-light
[ -x "$WRIT" ] || exit 0

"$WRIT" prompt-regeln --json 2>/dev/null || exit 0
