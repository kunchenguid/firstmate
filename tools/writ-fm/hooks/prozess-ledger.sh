#!/usr/bin/env bash
# SessionEnd — meldet Hintergrundprozesse, die diese Session hinterlaesst.
#
# WARUM SessionEnd und nicht Stop: `Stop` feuert am Ende JEDES Turns. Ein
# Melder, der bei jedem Turn eine Liste ausgibt, waehrend ein Dev-Server ganz
# legitim laeuft, wird nach dem dritten Mal ueberlesen — dasselbe Dauerrot,
# das `writ-light doctor` bis zum 2026-08-07 unbrauchbar machte. `SessionEnd`
# feuert einmal je Session und trifft genau den Wortlaut von WF-PROZESS-001
# ("oder eine Session geht zu Ende").
#
# WARUM MELDEN UND NICHT TOETEN: Der Hook sieht das Ergebnis, nicht die
# Absicht. Welche PIDs diese Session gestartet hat, weiss nur sie. Ein
# pauschales `pkill -f node` hat schon einmal die eigene Shell erwischt
# (Exit 144) — genau deshalb gibt es WF-PROZESS-001.
#
# ADRESSAT ist der OWNER im Terminal, nicht das Modell: am Session-Ende ist
# das Modell nicht mehr da. Exit 0, kein Blockieren. Begruendung zum nicht
# gemessenen Exit-2-Pfad: belege/t1-stop-hook-sichtbarkeit.md.
set -uo pipefail

# Nur Prozesse, die eine SESSION hinterlaesst. Zwei Ausschluesse, beide von
# der Gegenprobe erzwungen:
#   * kein nacktes "node" — darunter faellt halb Claude Code selbst
#   * kein `ttyd` — das ist ein Dauerdienst aus ~/projects/INFRASTRUKTUR.md,
#     kein Ueberbleibsel. Er stand im ersten Entwurf drin, und der erste
#     Probelauf meldete ihn prompt. Ein Melder, der bei JEDEM Session-Ende
#     denselben legitimen Dienst zeigt, wird ueberlesen — und dann faellt der
#     echte Fund nicht mehr auf. Dieselbe Lehre wie beim dauerroten `doctor`.
MUSTER='vite|webpack|metro|next dev|nodemon|ng serve|emulator -avd'

TREFFER=$(pgrep -af "$MUSTER" 2>/dev/null | grep -v 'prozess-ledger' | head -20 || true)
[ -n "$TREFFER" ] || exit 0

ANZAHL=$(printf '%s\n' "$TREFFER" | wc -l)
{
  echo
  echo "  $ANZAHL Entwicklungsprozess(e) laufen nach dem Session-Ende weiter:"
  echo
  printf '%s\n' "$TREFFER" | sed 's/^/    /'
  echo
  echo "  Nur die beenden, die zu dieser Session gehoerten — gezielt per PID,"
  echo "  kein pauschales pkill (das hat schon die eigene Shell erwischt)."
  echo "  Regel WF-PROZESS-001:  writ-light query \"verwaiste prozesse\""
  echo
} >&2
exit 0
