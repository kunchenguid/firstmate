# Git-Hooks — zwei Regeln, die keine Regeln mehr sind

Diese beiden Hooks machen aus Bitten an das Modell Eigenschaften der Umgebung.
Sie gelten für **jedes** Repo auf diesem Laptop und unabhängig davon, welche
Runtime oder welcher Agent gerade läuft.

| Hook | ersetzt den mechanischen Teil von | Verhalten |
|---|---|---|
| `pre-push` | `ENF-GIT-002` | Push nur mit `OWNER_PUSH_OK=1` |
| `pre-commit` | `ENF-SECRET-001` (nur der Repo-Teil) | gitleaks über den gestageten Stand |

## Installation

```bash
mkdir -p ~/.config/git/hooks
install -m 755 hooks/git/pre-push   ~/.config/git/hooks/pre-push
install -m 755 hooks/git/pre-commit ~/.config/git/hooks/pre-commit
git config --global core.hooksPath ~/.config/git/hooks
```

Geprüft vor dem Setzen: **kein Repo auf diesem Laptop hatte eigene Hooks**, ein
globaler `core.hooksPath` schaltet also nichts ab. Vor einer Wiederholung erneut
prüfen — der Pfad überschreibt repo-eigene Hooks stillschweigend:

```bash
for d in ~/projects/*/; do
  find "$d.git/hooks" -type f ! -name "*.sample" 2>/dev/null
done
```

## gitleaks

Nicht aus apt: die Distribution liefert 8.16.0 von 2023, und bei einem
Secret-Scanner zählen aktuelle Muster. Stattdessen das offizielle Release nach
`~/.local/bin` — kein `sudo`, kein Systemeingriff:

```bash
V=8.30.1
curl -sSLO https://github.com/gitleaks/gitleaks/releases/download/v$V/gitleaks_${V}_linux_x64.tar.gz
curl -sSLO https://github.com/gitleaks/gitleaks/releases/download/v$V/gitleaks_${V}_checksums.txt
grep "gitleaks_${V}_linux_x64.tar.gz$" gitleaks_${V}_checksums.txt | sha256sum -c -
tar xzf gitleaks_${V}_linux_x64.tar.gz gitleaks && install -m 755 gitleaks ~/.local/bin/
```

Die Prüfsumme ist nicht Zierde — `WF-DEP-001` verlangt sie. Fehlt gitleaks, läuft
der Hook durch und schreibt einen Hinweis; er blockiert nicht.

## Was die Hooks NICHT leisten

- **`pre-commit` deckt nur den Weg ins Repo ab.** `ENF-SECRET-001` verbietet
  Secrets auch in **Logs und im Chat** — dafür gibt es keine Mechanik. Genau dort
  lagen beide dokumentierten Vorfälle in `trooper_ai`: einmal in einem Log,
  einmal in einer `ps aux`-Ausgabe. Die Regel bleibt für diese Wege bestehen.
- **Es wird nur der gestagete Stand geprüft, nicht die Historie.** Das ist
  Absicht: schnell genug für jeden Commit, und die vorhandenen Fehlalarme in der
  Historie blockieren so keinen künftigen Commit.
- **`--no-verify` umgeht beides.** Ein Hook ist eine Hürde, kein Gefängnis. Wer
  ihn umgeht, tut es bewusst.

## Fehlalarm markieren

`# gitleaks:allow` an die Zeile — sichtbar im Diff, nicht still in einer
Allowlist versteckt. Beispiel im Repo: `tests/test_export.py`, wo ein erfundener
Bot-Token steht, damit die Prüfung überhaupt anschlagen kann.

## Baseline-Lauf 2026-08-02

14 Funde über alle Repos, **alle Fehlalarme** — Belege und Einzelbewertung in
`belege/a3-gitleaks-baseline.md`. Deshalb keine Baseline-Datei: es gibt nichts
zu unterdrücken.
