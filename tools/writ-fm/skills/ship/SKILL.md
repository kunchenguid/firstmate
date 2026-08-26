---
name: ship
description: Ziellinie eines Arbeitsschritts — verifizieren, committen, melden, aufräumen; nennt je Schritt die zuständige Regel-ID statt Regelinhalt nachzuerzählen
whenToUse: Wenn ein Meilenstein fertig scheint und committet werden soll
---

# Ziellinie

Dieser Skill ist eine **Reihenfolge**, kein Regeltext. Jeder Schritt nennt die
zuständige Regel-ID; den Wortlaut holt die Session bei Bedarf über
`writ-light query "<stichwort>"`.

Das ist Absicht und folgt REG-SKILL-001: ein Skill hat keine Tests, die ihn
beim Driften erwischen. Der gelöschte Onboarding-Skill erzählte einen
Override-Weg, einen Nachreich-Zustand und eine Blocker-Reaktion nach — alle
drei Aussagen waren zuletzt falsch, und niemandem ist es aufgefallen. Wer hier
Regelinhalt hineinschreibt, baut dieselbe Falle neu.

## Die Schritte

1. **Arbeitsverzeichnis belegen** — `pwd && git rev-parse --show-toplevel`,
   gegen die Aufgabe prüfen (WF-CWD-001)
2. **Selbstprüfung gegen Auslassungen** — jede berührte Datei einmal ganz
   lesen, Befunde als Liste sammeln, dann korrigieren (LEK-SELBSTPRUEFUNG-001)
3. **Suite vollständig** — Zahlen nennen, nicht „grün" (TEST-BASELINE-001,
   ENF-GIT-001)
4. **Gegenprobe** — belegen, dass die Änderung wirklich greift: der Test war
   vorher rot, der Hook hat wirklich geblockt (LEK-VERIFY-001)
5. **Gezielt stagen** — explizite Pfade, kein `-A`, kein `.` (WF-CWD-001)
6. **Commit** — Granularität und Stil aus dem `git log` des Repos
   (GIT-COMMIT-001, GIT-STYLE-001)
7. **Inbox lesen** — `claw-inbox <projekt>` (COMM-INBOX-001)
8. **Melden** — `claw-notify --projekt <projekt> "<text>"`; das Flag ist
   vorgeschrieben, nicht optional (COMM-NOTIFY-001, COMM-ROUTING-001)
9. **Aufräumen** — nur die selbst notierten PIDs beenden, Rest melden
   (WF-PROZESS-001)

Rot an einer Stelle heißt **Halt**, nicht Notiz. Push gehört ausdrücklich
nicht auf diese Liste (ENF-GIT-002).

## Wenn ein Schritt nicht passt

Übersprungene Schritte werden benannt, nicht stillschweigend gelassen — ein
Bericht, der neun Schritte behauptet und sieben gegangen ist, ist der Fehler,
den REPORT-HONEST-001 meint.
