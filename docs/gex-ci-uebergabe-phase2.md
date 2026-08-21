# Uebergabe: CI-Laeufe auf den eigenen Laeufer umstellen

Phase 2 des Auftrags vom 21.08.2026.
Der Laeufer auf gex44 steht, ist belegt und gruen - siehe [`gex-ci-laeufer.md`](gex-ci-laeufer.md).
**Diese Umstellung gehoert den jeweiligen Bahnen, nicht der Laeufer-Bahn.**

## Was zu tun ist

In der CI-Datei des Repos jedes Vorkommen von

```yaml
    runs-on: ubuntu-latest
```

ersetzen durch

```yaml
    runs-on: [self-hosted, gex]
```

Das Label ist `gex`. `self-hosted`, `Linux` und `X64` vergibt GitHub selbst.

**Vorher pruefen: hat das Repo einen Platz?** Ein Laeufer bedient ausschliesslich das Repo, auf das er registriert ist - swippipp ist ein Nutzerkonto, und persoenliche Konten kennen keine Laeufergruppen.
Ohne Platz bleibt der Auftrag liegen, bis einer da ist.
Das Anlegen steht in [`gex-ci-laeufer.md`](gex-ci-laeufer.md#ein-repo-anbinden) und ist Sache der Laeufer-Bahn, nicht der Repo-Bahn.

## Die Falle: es ist nicht immer eine Zeile

GitHubs `ubuntu-latest` bringt hunderte Werkzeuge vorinstalliert mit.
Der eigene Laeufer bringt mit, was die Workflows ausdruecklich anfordern.
**Ein Job, der ein Werkzeug benutzt, ohne es einzurichten, faellt nach der Umstellung mit `command not found` um.**

Im Testlauf traf das `lensclash/citation-anchors`: der Job ruft `node scripts/check-branch-commit-citations.mjs`, ohne je `setup-node` aufzurufen.
Gehostet lief das, weil node vorinstalliert ist. Auf dem eigenen Laeufer nicht.

Also **vor** der Umstellung jeden Job durchgehen: benutzt er ein Werkzeug, das kein Setup-Schritt im selben Job bereitstellt?
Dann diesen Schritt ergaenzen - so, wie es fuer `citation-anchors` aussah:

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      # Auf ubuntu-latest ist node vorinstalliert, auf einem eigenen Laeufer
      # nicht. Dieser Schritt macht die Abhaengigkeit ausdruecklich.
      - uses: actions/setup-node@v4
        with:
          node-version: 24
      - name: Zitierte Commits sind nicht zweiglokal
        run: node scripts/check-branch-commit-citations.mjs
```

Den Schritt ergaenzen ist die richtige Korrektur, nicht das Werkzeug ins Laeufer-Bild backen: der Workflow wird dadurch unabhaengig davon, wo er laeuft.
Nur fuer allgemeine Werkzeuge ohne Setup-Action (`shellcheck` und Verwandte) ist der Weg ueber das Bild richtig; das ist dann ein Auftrag an die Laeufer-Bahn.

## Reihenfolge

Nach gemessenem Verbrauch der letzten 30 Tage (Wanduhr, aus der Actions-API summiert, Stand 21.08.2026) **und** Umstellrisiko:

| # | Repo | Minuten/30d | Laeufe | Was zu beachten ist |
|---|---|---:|---:|---|
| 1 | **lensclash** | 485 | 199 | Belegt und gruen gemessen. `citation-anchors` braucht den `setup-node`-Schritt oben. Zwei Plaetze stehen bereit. |
| 2 | **GEX_GATEWAY** | 46 | 68 | node + uv/python, beide mit Setup-Schritt vorhanden. Erwartet unauffaellig. |
| 3 | **LensclashDB** | 41 | 71 | reines uv/python mit `setup-uv`. Erwartet unauffaellig. |
| 4 | **Quiz-Web** | 13 | 16 | node mit `setup-node`. Mitnahme. |
| 5 | **Bietkompass** | 28 | 6 | uv/python, aber **blockiert**: der Workflow installiert `poppler-utils` per `sudo apt-get`, und im Container gibt es kein sudo. `poppler-utils` muss ins Bild, dann faellt der Installationsschritt weg. Auftrag an die Laeufer-Bahn. |
| 6 | **SnackSuite** | **958** | 207 | **Zuletzt.** Groesster Hebel, groesste Arbeit: Playwright/Chromium braucht eine zweite Bildvariante (`playwright install --with-deps` ruft `sudo apt-get` und faellt im Container um). Ausserdem laeuft dort gerade der Umzug - erst wenn der steht. |

Der Rest (`Homepage`, `Lernplattform`, `wimmel`, `rag-digital`, `trooper_ai`, `testlab`) liegt zusammen unter 15 Minuten in 30 Tagen und lohnt die Umstellung nicht.

SnackSuite und lensclash sind zusammen 91 % des Verbrauchs.
Wer nur eines umstellt, stelle lensclash um - es ist der groesste Anteil, der ohne Zusatzarbeit laeuft.

**Die beiden oeffentlichen Repos (`LocalizerServer5`, `PogoLocationFeeder`) bleiben aussen vor.**
Ein selbstgehosteter Laeufer an einem oeffentlichen Repo fuehrt fremden PR-Code auf gex aus.
Beide haben ohnehin keine Workflows. Die Positivliste auf gex sperrt sie zusaetzlich.

## Zwei Beobachtungen am Rande

* **lensclashs Standardzweig ist `r26-referenz-v2`, nicht `main`.** Die CI-Datei filtert aber `push: branches: [main]`. Pushes auf den tatsaechlichen Standardzweig loesen also gar keine CI aus; nur PRs tun es. Das ist keine Folge der Umstellung, faellt aber jedem auf, der hier arbeitet - gehoert der lensclash-Bahn.
* **`sudo apt-get` im Workflow funktioniert nicht.** Der Container laeuft als Nicht-Root ohne sudo - bewusst, das ist eine der Sicherheitsauflagen. Wer im Workflow ein Systempaket nachinstalliert (Bietkompass tut es, SnackSuite ueber `playwright install --with-deps` auch), braucht das Paket stattdessen im Laeufer-Bild.
* **Kein Repo hat `workflow_dispatch`.** Ein Lauf laesst sich deshalb nicht von Hand ausloesen; fuer eine Probe braucht es einen PR. Wer das oefter braucht, ergaenze `workflow_dispatch:` im `on:`-Block - es muss auf dem Standardzweig stehen, um zu wirken.

## Rueckweg

Wenn nach der Umstellung etwas klemmt: `runs-on` zurueck auf `ubuntu-latest`, fertig.
Der Laeufer bleibt stehen und stoert nicht; der naechste Lauf geht wieder gehostet.
Ein ergaenzter `setup-node`-Schritt darf und soll dabei stehen bleiben - er ist auch gehostet richtig.
