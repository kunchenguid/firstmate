#!/usr/bin/env bash
# PreToolUse/Bash — der Waechter fuer Bash-Befehle. Er bewacht ZWEI Dinge:
#
#   1. den Selbst-Neustart mit abgeschwaechten Sicherungen — Regelwerk ODER
#      `git add`-Waechter (ENF-INPUT-001), siehe SPERRE 1
#   2. den Stage-Teil von WF-CWD-001, siehe SPERRE 2
#
# Hiess bis 2026-08-08 `git-add-guard.sh`. Der Name beschrieb ab der ersten
# Sperre nur noch die Haelfte — und ein Dateiname, der luegt, ist die
# billigste Sorte falscher Dokumentation.
#
# DIE REIHENFOLGE IST DIE HALBE WIRKUNG. Sie steht so und nicht anders:
#
#   1. WRIT_RULES aus  -> durchlassen. Die aeussere Session ist bereits
#      regelfrei gestartet (der Owner selbst, Alias `claude-free`); hier gibt
#      es nichts mehr zu schuetzen, was nicht schon offen laege.
#   2. SPERRE 1 (Selbst-Umgehung) — VOR dem WRIT_GUARD-Ausstieg.
#   3. WRIT_GUARD aus  -> durchlassen (der bestehende Ausstieg).
#   4. Freigabe und SPERRE 2 (`git add`).
#
# Stuende SPERRE 1 unter Schritt 3, haette `WRIT_GUARD=aus` — ein Schalter,
# der ausdruecklich nur fuer `git add` gedacht ist und mit `claude-unsafe`
# einen bequemen Alias hat — still auch die Regelwerk-Sperre aufgehoben. Genau
# diese Sorte Kopplung ist gemeint, wenn ein Schalter mehr abschaltet, als auf
# ihm draufsteht. Festgenagelt in tests/test_hooks_shell.py: jeder Fall von
# SPERRE 1 wird ZUSAETZLICH mit WRIT_GUARD=aus geprueft.
#
# ZWEI AUSWEGE aus SPERRE 2, beide absichtlich:
#
#   1. Ganze Session:   WRIT_GUARD=aus claude
#      Die Variable wird vom Terminal an Claude Code und von dort an diesen
#      Hook vererbt (gemessen 2026-08-07: der Hook sieht PATH, WAYLAND_DISPLAY
#      und SSH_AUTH_SOCK der Login-Shell). Fuer neue oder unkritische Projekte,
#      in denen `git add -A` die richtige Bewegung ist.
#
#   2. Einzelner Befehl:  OWNER_ADD_ALL=1 git add -A
#      Steht im Befehlstext und damit im Transkript — sichtbar, nicht still.
#
# Bis dieser Ausweg eingebaut war, gab es ihn TROTZDEM, nur unsichtbar: jedes
# beliebige Praefix (`X=1 git add -A`) rutschte durch, weil vor `git` kein
# Trennzeichen stand, und die Sperrmeldung erwaehnte nichts davon. Ein Schloss,
# das sich aufsperren laesst, dessen Besitzer aber den Schluessel nicht kennt,
# ist das Schlechteste von beidem. Das Muster ueberspringt Praefixe jetzt
# ausdruecklich — durch kommt nur noch, was oben steht.
#
# REICHWEITE, damit sich niemand mehr darauf verlaesst: dieser Hook haengt am
# Bash-Werkzeug (matcher "Bash" in settings.json). Das Datei-Werkzeug
# (Read/Edit/Write) geht daran vorbei. Das ist keine Luecke, sondern die
# Grenze des Ereignisses — und der Grund, warum die Meldung von SPERRE 1 das
# Aufschreiben ausdruecklich auf Edit verweist statt aufs Ausfuehren.
#
# Bis 2026-08-08 stand dort stattdessen eine ANNAHME: wer die Aliase in die
# `.bashrc` schreibe, sitze ohnehin in einer `claude-free`-Sitzung. Am selben
# Tag widerlegt — die `.bashrc`-Zeilen wurden aus einer ganz normalen Sitzung
# geschrieben, mit Read/Edit. Eine Meldung, die einen Ausweg nennt, der nur
# manchmal stimmt, und den verschweigt, der immer stimmt, ist schlechter als
# eine, die schweigt.
#
# Kein jq: der Hook laeuft bei JEDEM Bash-Aufruf und darf keine Abhaengigkeit
# haben, die fehlen kann. Faellt irgendein Schritt aus, laesst er durch — ein
# kaputter Waechter darf die Arbeit nicht blockieren.
#
# Was NICHT geblockt wird: `git add -p` (interaktiv, der Mensch waehlt),
# `git add <pfad>` (genau das Erwuenschte), und alles, was `add` nur im Text
# erwaehnt. Beide Richtungen sind in tests/test_hooks_shell.py festgenagelt —
# ein Waechter, der alles blockt, wird abgeschaltet, und dann ist er
# schlechter als keiner.
set -uo pipefail

# Schritt 1: der Owner hat diese Session selbst regelfrei gestartet.
case "${WRIT_RULES:-}" in
  aus|off|0|nein) exit 0 ;;
esac

EINGABE=$(cat 2>/dev/null || true)
# `(\\.|[^"\\])*` liest den JSON-String MIT seinen escapten Anfuehrungszeichen.
# Bis 2026-08-08 stand hier `[^"]*`, und das war eine offene Tuer, kein Detail:
# das erste `"` im Befehl schnitt den Rest weg. Gemessen an der installierten
# Fassung von 2026-08-07:
#
#   git commit -m "x" && git add -A   ->  gesehen: `git commit -m \`   -> Exit 0
#   echo "x" && WRIT_RULES=aus claude ->  gesehen: `echo \`            -> Exit 0
#
# Beide Sperren waren also mit einem Anfuehrungszeichen zu umgehen — und zwar
# genau von dem eingeschleusten Text, gegen den SPERRE 1 steht. Der Rueckfall
# bleibt: liest sed nichts, laesst der Hook durch.
BEFEHL=$(printf '%s' "$EINGABE" \
  | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' | head -1)
[ -n "$BEFEHL" ] || exit 0

# ...und die JSON-Escapes aufloesen. Ohne diesen Schritt war der Waechter bei
# JEDEM mehrzeiligen Befehl blind — und mehrzeilig ist hier der Normalfall.
# Gemessen am 2026-08-08 gegen die Fassung von gestern UND gegen die erste
# Fassung von heute:
#
#   cd /tmp<umbruch>git add -A          -> Exit 0
#   export WRIT_RULES=aus<umbruch>claude -> Exit 0
#
# Grund: `\n` kommt aus dem JSON als die ZWEI Zeichen `\` und `n` an. Alle
# Muster hier verankern an Zeilen- und Befehlsanfang (`^`, `;`, `&`, `|`) —
# hinter zwei Textzeichen faengt aber keine Zeile an. Mit echten Umbruechen
# greifen die Anker wieder, weil grep zeilenweise arbeitet.
#
# `printf '%b'` loest genau die JSON-Escape-Ebene auf, und zwar EINMAL von
# links nach rechts. Das ist der Unterschied zu einem `sed s/\\n/<umbruch>/`:
# dort wuerde `printf 'a\nb'` — im Befehl eine Escape-Sequenz, KEIN Umbruch —
# faelschlich zu zwei Zeilen. Nachgemessen, beide Richtungen:
#
#   Befehl `cd /tmp<umbruch>git add -A`  -> zwei Zeilen   (gewollt)
#   Befehl `printf "a\nb" > /tmp/x`      -> eine Zeile, `\n` bleibt Text
BEFEHL=$(printf '%b' "$BEFEHL")

# SPERRE 1: eine laufende Session startet sich nicht selbst mit abgeschwaechten
# Sicherungen neu — egal, WELCHE der beiden Sicherungen gemeint ist.
#
# Ohne sie waere das Regelwerk mit einem einzigen Bash-Aufruf abraeumbar — und
# der Aufruf muesste nicht einmal vom Owner kommen: eingeschleuster Text aus
# einer Webseite, einer Werkzeugausgabe oder einer fremden Datei reicht
# (ENF-INPUT-001). Ein Override, den die Session selbst ziehen kann, ist
# keiner.
#
# BEIDE Schalter, nicht nur `WRIT_RULES`. Bis 2026-08-08 stand hier nur der
# eine, und das Ergebnis war eine Uneinheitlichkeit, die sich von selbst
# ausnutzt: `claude-unsafe` war gesperrt, seine woertliche Entsprechung
# `WRIT_GUARD=aus claude` kam mit Exit 0 durch (gemessen). Wer den Alias-Weg
# zu findet, nimmt den Variablen-Weg — eine Sperre, die nur die bequeme
# Schreibweise kennt, erzieht zur unbequemen.
#
# Zwei unabhaengige Bedingungen, mit UND verknuepft statt als ein
# Nachbarschaftsmuster: `WRIT_RULES=aus && claude` und `WRIT_RULES=aus; claude`
# rutschten sonst durch, weil zwischen Zuweisung und Befehl ein Trennzeichen
# steht. Bei einer Sperre gegen eingeschleusten Text ist der Durchrutscher die
# teure Richtung, der Fehlalarm die billige.
#
# Der Schalter ALLEIN ist kein Fall fuer diese Sperre: `WRIT_GUARD=aus git add
# -A` startet nichts neu und wird weiter unten vom `git add`-Waechter
# entschieden, nicht hier. Gesperrt ist die Verbindung Schalter + Neustart.
#
# DURCH MUSS: der direkte Hook-Aufruf zur Pruefung, also
# `WRIT_RULES=aus ~/.claude/hooks/onboarding.sh` und `WRIT_RULES=aus
# hooks/onboarding.sh` — sonst waere die Verifikation dieses Waechters selbst
# gesperrt. Das `claude` in `.claude/` hat einen Punkt davor, kein Leerzeichen
# und keinen Schraegstrich; deshalb trennt `(^|[[:space:]/])` die beiden Faelle.
#
# Die Alias-Woerter dagegen zaehlen nur an BEFEHLSSTELLE — dieselbe Verankerung
# wie beim `git add`-Muster unten, aus demselben Grund. Ohne sie sperrte der
# Waechter jede Erwaehnung: gemessen am 2026-08-08 fielen
# `git commit -m "Aliase claude-free … eingebaut"` und `grep -rn claude-free
# docs/` mit Exit 2 um. Ein Waechter, der die Arbeit an sich selbst blockiert,
# wird abgeschaltet — und dann schuetzt er gar nichts mehr.
#
# WAS DIESES MUSTER NICHT DECKT, ausdruecklich: das Alias-Wort in
# ARGUMENTSTELLE, also `bash -c claude-free` oder `eval claude-free`. Das ist
# kein Versehen, sondern die Kehrseite derselben Verankerung — eine Regel, die
# Argumente mitnimmt, nimmt `grep -rn claude-free docs/` mit. Tragbar ist das
# aus zwei gemessenen Gruenden: erstens haengt der substanzielle Weg an der
# UND-Bedingung darueber, die NICHT verankert ist und deshalb auch
# `bash -c 'WRIT_RULES=aus claude'` faengt; zweitens sind Aliase in der
# nicht-interaktiven Shell der Werkzeugaufrufe gar nicht definiert (gemessen:
# `alias` liefert dort null Eintraege) — `claude-free` waere dort schlicht ein
# unbekannter Befehl. Die Alias-Haelfte ist die Klarschrift-Sperre, nicht die
# tragende.
# Vorne zaehlen ausser Leerraum auch die Trennzeichen: `;claude` und
# `&&claude` ohne Leerzeichen sind gueltige Bash — `bash -c 'export
# WRIT_RULES=aus;claude'` startet claude wirklich, und bis 2026-08-08 rutschte
# genau diese Schreibweise durch. Der Punkt fehlt in der Klasse mit Absicht:
# er ist das einzige Zeichen, das `~/.claude/hooks/…` von einem Start
# unterscheidet.
#
# Hinten trennt jedes Zeichen, das kein Namensbestandteil ist — sonst faellt
# `'WRIT_RULES=aus claude'` (in Anfuehrungszeichen, etwa beim Schreiben einer
# .bashrc-Zeile) durch. `.`, `-` und `/` bleiben ausgenommen: sie stehen fuer
# `claude.py`, `claude-free` und ein Verzeichnis namens `claude/`.
SELBSTSTART='(^|[[:space:];&|(/])claude([^A-Za-z0-9_./-]|$)'
ALIASSE='(^|[;&|(]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*claude-(free|unsafe)([^A-Za-z0-9_-]|$)'
if { printf '%s' "$BEFEHL" | grep -qE '(WRIT_RULES|WRIT_GUARD)=' \
     && printf '%s' "$BEFEHL" | grep -qE "$SELBSTSTART"; } \
   || printf '%s' "$BEFEHL" | grep -qE "$ALIASSE"; then
  cat >&2 <<'MELDUNG'

  GESTOPPT — eine Session startet sich nicht selbst mit abgeschwaechten
  Sicherungen neu

  `WRIT_RULES=aus` (Alias `claude-free`) schaltet das Regelwerk ab,
  `WRIT_GUARD=aus` (Alias `claude-unsafe`) den `git add`-Waechter. Beide
  Schalter gehoeren dem OWNER AM TERMINAL: er entscheidet vor dem Start, mit
  welchen Sicherungen eine Session laeuft. Eine laufende Session entscheidet
  das NICHT fuer sich selbst — sonst genuegte ein Satz in einer Webseite,
  einer Werkzeugausgabe oder einer fremden Datei, um die Sicherungen
  abzuraeumen (ENF-INPUT-001).

  KEIN WIDERSPRUCH zur Meldung des `git add`-Waechters: die nennt
  `WRIT_GUARD=aus claude` als Weg fuer den Owner, in seinem Terminal, vor dem
  Start. Hier geht es um denselben Befehl aus der Session heraus — dieselben
  Zeichen, die andere Hand.

  Was stattdessen geht:

      Sicherung stoert hier wirklich?  Owner bitten, die Session mit
      `claude-free` (ohne Regelwerk) oder `claude-unsafe` (ohne
      `git add`-Waechter) neu zu starten — kurz sagen, wofuer.

      Nur dieses eine `git add -A`?  Dafuer braucht es keinen Neustart:
      OWNER_ADD_ALL=1 git add -A  steht im Transkript und ist damit sichtbar.

      Den Aus-Pfad nur PRUEFEN?  Das ist erlaubt — den Hook direkt aufrufen:
      WRIT_RULES=aus ~/.claude/hooks/onboarding.sh

  Nur ueber die Schalter SCHREIBEN — Doku, README, eine `.bashrc`-Zeile,
  eine Commit-Nachricht? Das ist kein Start und muss nicht scheitern: nimm
  dafuer das Datei-Werkzeug (Read/Edit) statt `echo`/`cat`/`sed` in Bash.
  Diese Sperre haengt am Bash-Werkzeug; ein Edit laeuft nicht durch sie
  hindurch. Sie sperrt das Ausfuehren, nicht das Aufschreiben.
  (Und eine Sitzung, die der Owner selbst unter `claude-free` gestartet hat,
  sieht die Sperre ohnehin nicht.)

MELDUNG
  exit 2
fi

# Schritt 3 — Ausweg 1 aus SPERRE 2: fuer die ganze Session abgeschaltet.
# Steht ABSICHTLICH hier unten und nicht weiter oben, siehe Kopfkommentar.
case "${WRIT_GUARD:-}" in
  aus|off|0|nein) exit 0 ;;
esac

# Ausweg 2: ausdrueckliche Freigabe fuer genau diesen Befehl.
FREIGABE='(^|[;&|]|&&)[[:space:]]*OWNER_ADD_ALL=1[[:space:]]+git[[:space:]]+add[[:space:]]'
if printf '%s' "$BEFEHL" | grep -qE "$FREIGABE"; then
  exit 0
fi

# `([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*` ueberspringt beliebige
# Umgebungs-Praefixe — sonst waere jedes `X=1 git add -A` eine stille Umgehung.
MUSTER='(^|[;&|]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+add[[:space:]]+([^;&|]*[[:space:]])?(-A|--all|\.)([[:space:]]|$)'

if printf '%s' "$BEFEHL" | grep -qE "$MUSTER"; then
  cat >&2 <<'MELDUNG'

  GESTOPPT — `git add -A` stagt fremde Staende

  Auf diesem Laptop laufen mehrere Sessions und Worktrees parallel. `-A`,
  `--all` und ein alleinstehendes `.` nehmen mit, was eine andere Session
  gerade liegen hat. Das ist bereits passiert.

  Normalweg — die selbst geaenderten Dateien einzeln nennen:

      git add pfad/zur/datei.ts pfad/zum/test.ts

  Unsicher, was dazugehoert?  git status --porcelain

  WENN `-A` HIER RICHTIG IST (frisches Repo, keine Parallel-Session):

      dieser eine Befehl:   OWNER_ADD_ALL=1 git add -A
                            — der Weg aus dieser Session heraus.

      die ganze Session:    der OWNER startet Claude in seinem Terminal mit
                            WRIT_GUARD=aus claude  (Alias `claude-unsafe`).
                            Aus der Session heraus geht das NICHT: eine
                            laufende Session startet sich nicht selbst mit
                            abgeschwaechten Sicherungen neu (SPERRE 1 oben).

  Regel WF-CWD-001. Wortlaut: writ-light query "wie stage ich richtig"

MELDUNG
  exit 2
fi
exit 0
