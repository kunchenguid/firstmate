# Bericht zur Zusammenführung von `upstream/main`

## Ergebnis

Die 87 gegenüber dem Fork neuen Template-Commits wurden als echter Merge in den Captain-Fork übernommen.
Die acht eigenen Commits bleiben vollständig erreichbar.
Die lokale SCM-Host-Auswahl und die menschenlesbaren Task-Labels wurden in die neue Upstream-Struktur portiert, statt alte Strukturen über die Upstream-Änderungen zu legen.
Der reale Merge meldete elf Konfliktdateien und damit eine mehr als der vorherige `merge-tree`-Trockenlauf.
Die zusätzliche Konfliktdatei war `tests/fm-watcher-lock.test.sh`.
Drei nachgestellte Tabs in einem neuen Upstream-Ausgabebeispiel unter `docs/gitlab-merge-watch.md` wurden ohne Inhaltsänderung entfernt, damit der vollständige staged Diff die Whitespace-Prüfung besteht.

```text
$ git rev-list --count ORIG_HEAD..upstream/main
87
$ git rev-list --count upstream/main..ORIG_HEAD
8
```

## Was du an neuen Fähigkeiten bekommst

### Stabilere Supervision

- Der Claude-Session-Lock löst eine zusammenhängende `claude`-Prozesskette jetzt bis zum äußersten Claude-Prozess auf, statt den kurzlebigen `bg-spare`-Prozess als Lock-Eigentümer zu missverstehen.
- Dadurch erkennt der Stop-Hook seine eigene primäre Session wieder und kann den Watcher-Auto-Arm tatsächlich starten.
- Ja, diese Änderung behebt plausibel das heute beobachtete Sterben der Watcher-Supervision zusammen mit ihrem Wrapper, wenn die eigentliche Ursache die dokumentierte `bg-spare`-Fehlzuordnung und der dadurch unterbliebene Auto-Arm war.
- Sie ist noch kein vollständiger Beweis für den konkreten Vorfall, weil ein unabhängiges Prozessgruppen- oder Signalproblem denselben sichtbaren Effekt erzeugen könnte.
- Der enthaltene Regressionstest baut eine echte zweistufige, zusammenhängende Claude-Ancestry auf und bestätigt, dass der äußere Lock-Eigentümer gefunden wird.

```text
ok - auto-arm: resolves the outermost pid of a nested contiguous claude ancestry (bg-spare chain)
```

- Ein dauerhaft als beschäftigt dargestellter Worker gilt nicht mehr unbegrenzt als gesund.
- Wenn seit dem letzten abgeschlossenen Turn standardmäßig 3.600 Sekunden vergangen sind, beginnt nun dieselbe mehrstufige Wedge-Eskalation wie bei anderen festhängenden Workern.
- Die Eskalation fordert eine menschliche Prüfung an und unterbricht, signalisiert oder startet den Worker nicht automatisch neu.
- Ein neuer `turn-ended`-Zeitstempel setzt das Altersfenster zurück.

```text
ok - a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound
ok - a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound
ok - touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation
ok - the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)
```

- Claude-Crewmates erhalten jetzt ein gesetztes `CLAUDE_CONFIG_DIR` aus der Firstmate-Session.
- Das verhindert, dass ein Worker hinter dem lang laufenden Backend-Daemon auf den falschen Standard-Credential-Store zurückfällt und unauthentifiziert hängen bleibt.
- Andere Harnesses bleiben von dieser Claude-spezifischen Weitergabe unberührt.

```text
ok - claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store
ok - claude omits the config-dir prefix when firstmate runs with the single-store default
ok - non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix
```

### Sichererer Worker-Start und robustere Flottenführung

- Markierte Secondmate-Anfragen erhalten eine parent-seitig persistierte Korrelation mit einmaliger Recovery und anschließender Eskalation, ohne den Secondmate-Chat auszulesen.
- Secondmate-Liveness unterscheidet sicher zwischen `live`, `dead`, `missing`, `ambiguous` und `unreadable` und startet nur bei belastbar toten oder fehlenden Endpunkten neu.
- Crew-Dispatch-Profilarrays werden aus aktuellem `quota-axi`-Headroom ausgewählt, wobei jede Kandidatenbeziehung erklärt oder als Blocker ausgewiesen werden muss.
- `pi-signed` und Kimi sind als verifizierte Harness-Identitäten hinzugekommen.
- Pi Calm kann operative Zwischenzeilen aus der Darstellung ausblenden, ohne die gespeicherte Historie oder Exporte zu verändern.
- Herdr kann optional pro Task einen wegwerfbaren Presentation Space anlegen und besitzt dafür streng gebundene Journale, sichere Cleanup-Grenzen und eine schnellere eventbasierte Wake-Route.
- GitLab-Merge-Requests können neben GitHub-Pull-Requests durch denselben gehärteten Merge-Poll überwacht werden.
- Der neue Test-Runner teilt 96 Tests in belegte Parallel-, Serial- und Herdr-Lanes auf und prüft seine eigene Isolationszuordnung.

### Begrenzter und konsolidierter Startup-Speicher

- `config/startup-memory-budget` begrenzt die zusammen geladenen Inhalte aus `data/captain.md`, `data/captain-shared.md` und `data/learnings.md`.
- Der Default von 7.500 geschätzten Tokens wird beim gelockten Bootstrap materialisiert und in Secondmate-Homes vererbt.
- `/stow` misst nun vor und nach dem Schreiben, konsolidiert veraltetes oder doppeltes Material und darf das Budget nicht durch ungeprüftes Anhängen überschreiten.

## Was sich an deiner Dienstanweisung ändert

- Eine konkrete, aktuelle Captain-Freigabe kann Firstmate jetzt eine genau bezeichnete Projektoperation direkt ausführen lassen, ohne daraus eine allgemeine Schreibberechtigung abzuleiten.
- Neue Projektaufnahme wird zuerst gegen die registrierten Secondmate-Scopes geroutet, damit ein zuständiger Secondmate statt einer doppelten Main-Home-Struktur übernimmt.
- Projekt-Entfernung bleibt an Preflight, Unlanded-Work-Schutz und die konkrete Captain-Freigabe gebunden.
- `yolo` erlaubt nur Routineentscheidungen innerhalb des bereits akzeptierten Produkt- und Engineering-Vertrags.
- Vor jeder Ask-User-Entscheidung muss `ask-user-authority` unterscheiden, ob es sich um eine Korrektur innerhalb des Auftrags oder um eine echte Vertragserweiterung handelt.
- Ein Implementierungsworker darf seine eigene Ask-User-Feststellung weiterhin nicht selbst beantworten.
- Bearings ist standardmäßig nur noch eine Chat-Antwort und schreibt erst mit der ausdrücklichen Variante `/bearings file` ein Statusdokument.
- Bestehende Berichte und Evidenz sollen vor einem neuen Scout geprüft werden, und begrenzte Recherche bleibt nach erteilter Implementierungsfreigabe möglichst im Ship-Task.
- Gleiche Dateien oder Subsysteme sind nur noch ein Risikosignal und kein automatischer Serialisierungsgrund, solange isolierte Umsetzung und spätere Konfliktauflösung sicher möglich sind.
- Profilarrays werden mit dem neuen quota-bewussten Auswahlvertrag statt nach Listenreihenfolge entschieden.
- Ein nicht verifizierbarer Session-Lock wird mit seiner konkreten Diagnose behandelt und nicht pauschal als Beweis für eine andere aktive Session interpretiert.
- Startup-Memory-Budget, Secondmate-Pending-Replies, neue Harness-Identitäten, Herdr-Presentation-Spaces und GitLab-Merge-Watches sind jetzt Teil des Betriebsvertrags.
- Die lokalen Zusätze `config/scm-host` und `label=` wurden in diese neue Dienstanweisung integriert.

## Wie die elf Konflikte aufgelöst wurden

- `.agents/skills/bootstrap-diagnostics/SKILL.md`: Die neuen Upstream-Diagnosen einschließlich Startup-Memory blieben erhalten, und `SCM_HOST_INVALID` sowie die hostabhängige Authentifizierungsanweisung wurden ergänzt.
- `.gitignore`: Die neue Upstream-Regel `config/` wurde übernommen, wodurch `config/scm-host` und alle künftigen lokalen Konfigurationsdateien ohne fragile Einzeleinträge abgedeckt sind.
- `AGENTS.md`: Der stark überarbeitete Upstream-Betriebsvertrag wurde übernommen, und `config/scm-host`, selektierte SCM-Voraussetzungen sowie das optionale `label=`-Metafeld wurden in seine neuen Eigentümerstellen eingepasst.
- `bin/backends/herdr.sh`: Upstreams neue Presentation-, Event-, Recovery- und Cleanup-Sicherheiten blieben erhalten, während Human-Labels über Metadaten auf stabile `fm-<id>`-Identitäten zurückgeführt werden.
- `bin/fm-config-inherit-lib.sh`: Upstreams neue Vererbungsmenge für Backend, Presentation Spaces und Startup-Memory wurde beibehalten und um `scm-host` erweitert.
- `bin/fm-spawn.sh`: Upstreams neue Start-, Lock-, Presentation- und `CLAUDE_CONFIG_DIR`-Logik blieb erhalten, und `--label` wurde in Parsing, Sanitizing, Eindeutigkeit, Metadaten, Respawn sowie beide Herdr-Darstellungswege portiert.
- `docs/architecture.md`: Upstreams neue Supervisions-, Secondmate- und Startup-Memory-Architektur blieb maßgeblich, und die SCM-Host-Vererbung wurde an der neuen Konfigurationsgrenze ergänzt.
- `docs/configuration.md`: Upstreams neue Home-, Backend-, Memory- und Metadatenbeschreibung blieb erhalten, und SCM-Host-Schema sowie `label=`-Vertrag wurden in die aktuelle Referenz aufgenommen.
- `docs/herdr-backend.md`: Upstreams gestraffter aktueller Backend-Vertrag und die optionalen Presentation Spaces blieben erhalten, während Human-Label-Verhalten und Identitätsgrenzen ergänzt und die empirischen Details in die Verification-Dokumentation verschoben wurden.
- `tests/fm-secondmate-harness.test.sh`: Upstreams neue Backend-, Presentation- und Startup-Memory-Vererbungstests blieben erhalten, und `scm-host` wird zusätzlich für Kopie, Rekonvergenz, Entfernung und Reread geprüft.
- `tests/fm-watcher-lock.test.sh`: Die stärkere Upstream-Fassung mit vollständiger PID-Identität, Heartbeat und längerem Acquisition-Wait wurde genommen, weil sie den lokalen Race-Fix vollständig einschließt und erweitert.

## Der Erhaltungsnachweis

### 1. `config/scm-host` steuert die GitHub-Voraussetzungen

Der Verhaltenstest erzeugt isolierte Bootstrap-Homes und prüft die tatsächliche Ausgabe.
Ohne Datei beziehungsweise mit GitHub und fehlgeschlagenem `gh auth status` lautet sie `NEEDS_GH_AUTH`.
Mit `forgejo` oder `local-only` fehlen `gh` und `gh-axi` vollständig im Fake-PATH, und Bootstrap bleibt trotzdem ohne Diagnose.
Ein unbekannter Wert scheitert geschlossen mit `SCM_HOST_INVALID: mystery (known: github forgejo local-only)`.

```text
$ tests/fm-bootstrap.test.sh
ok - bootstrap scopes GitHub prerequisites to the selected SCM host
```

Damit ist der für diesen Fork entscheidende Fall belegt, dass `forgejo` weder GitHub CLI noch GitHub-Authentifizierung verlangt.

### 2. `fm-spawn --label` bleibt vollständig erhalten

Die öffentliche Hilfe zeigt den portierten Vertrag.

```text
$ bin/fm-spawn.sh --help
Usage: fm-spawn.sh <task-id> <project-dir> [--label <text>] ...
  --label <text> records an optional human-readable task label in meta.
  Whitespace/control runs collapse to one space, leading/trailing whitespace
  is removed, and the result is capped at 64 characters. A label may not
  begin with fm- (that namespace is reserved for stable fm-<id> task
  identity), and a Herdr spawn refuses a label already recorded by another
  task in the same home ...
```

Die Tests prüfen Sanitizing, 64-Zeichen-Limit, Metadaten, Respawn, Eindeutigkeit, Batch-Ablehnung, Namespace-Schutz, Recovery-Mapping und pane-id-basierten Teardown.

```text
ok - fm-spawn.sh --label: records sanitized meta, reuses it on respawn, and leaves tmux's name-addressed fm-<id> identity unchanged
ok - fm-spawn.sh --label: a label in the reserved fm- identity namespace is refused
ok - fm-spawn.sh batch dispatch: a shared --label is refused because a display label names one task
ok - fm-spawn.sh herdr: a label already recorded by another task in the same home is refused before spawn
ok - human task labels: control whitespace is sanitized, length is capped, Herdr list-live recovers fm-<id> through meta, and a control-embedding label cannot forge a recovery line
ok - fm_backend_herdr_kill: a labeled task tears down by its recorded pane id, unaffected by the display label
```

### 3. Testsuite

Die Coverage-Zuordnung kennt alle 96 Testskripte.

```text
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=96 parallel=24 serial=62 herdr=10
```

Die sechs konflikt- und feature-nahen Skripte liefen vollständig grün.

```text
FM_TEST_SUMMARY total=6 failed=0 skipped_gate=0 duration_ms=479802
```

Die gesamte portable Serial-Lane lief ohne Fehler durch.

```text
FM_TEST_SUMMARY total=62 failed=0 skipped_gate=10 duration_ms=2030030
```

Die zehn Skips dieser Lane sind erwartete Opt-in- oder optionale-Binary-Gates.
Die separate Herdr-Lifecycle-Lane mit zehn Skripten wurde nicht gestartet, weil dieser Auftrag Herdr-Lifecycle-Steuerung ausdrücklich nicht freigibt.
`bin/fm-lint.sh` einschließlich ShellCheck 0.11.0 und `git diff --check` beendeten sich mit Exitcode 0.

Die proven-isolated Parallel-Lane hat genau einen Fehler und einen Tool-Gate-Skip gemeldet.

```text
FM_TEST_SUMMARY total=24 failed=1 skipped_gate=1 duration_ms=136832
not ok - jobs=2 must refill the first completed slot
```

Der fehlgeschlagene Test ist `tests/fm-test-run.test.sh`.
Der Gate-Skip ist `tests/fm-pi-primary-types.test.sh`, weil das optionale `tsc` in dieser Umgebung fehlt.
Der Captain hat denselben Scheduler-Fehler an einer sauberen Kopie von `upstream/main` ohne diese Zusammenführung reproduziert.
Er ist damit ein Vorbefund des Templates und keine Merge-Regression.
Er wurde gemäß Anweisung weder repariert noch umgangen.

### 4. Die acht eigenen Commits bleiben erreichbar

Nach Erzeugung des Merge-Commits zeigt `git log upstream/main..HEAD` zuerst den neuen Merge-Commit und danach die acht fork-eigenen Commits.
Die folgende Ausgabe überspringt nur diesen neuen ersten Eintrag.

```text
$ git log --oneline --skip=1 upstream/main..HEAD
cca0912 Merge pull request 'feat: add human-readable task labels for herdr via fm-spawn --label' (#1) from fm/herdr-task-labels into main
bf4fc65 no-mistakes(document): docs: record optional label= meta field in AGENTS.md inventory
6535f35 no-mistakes(test): test(watcher-lock): wait for completed acquisition before simulated takeover
6ae02a2 no-mistakes(test): test(brief): align secondmate charter assertion with house vocabulary
0f4292b no-mistakes(review): enforce herdr label uniqueness, fm- namespace, batch and framing safety
45f3fd4 feat: add human-readable task labels
178d509 fix: keep SCM host configuration local
df667f8 feat: make SCM prerequisites host-aware
```

Zusätzlich bestätigt die Ancestry-Prüfung jeden einzelnen SHA gegen den Merge-`HEAD`.

```text
cca0912 reachable
bf4fc65 reachable
6535f35 reachable
6ae02a2 reachable
0f4292b reachable
45f3fd4 reachable
178d509 reachable
df667f8 reachable
```

## Was du prüfen solltest

- Nach dem Landing sollte eine reale Firstmate-Session mit lokalem `config/scm-host=forgejo` einmal bestätigen, dass im echten Credential- und PATH-Umfeld kein GitHub-Login-Hinweis erscheint.
- Ein echter Herdr-Spawn mit `--label` sollte sowohl im normalen Home-Workspace als auch bei aktivierten Presentation Spaces visuell geprüft werden.
- Der konkrete heutige Claude-Vorfall sollte nach dem Landing über mindestens einen echten Stop-Hook- und Wrapper-Exit beobachtet werden, weil der Session-Lock-Fix sehr plausibel, aber nicht beweisgleich für jede mögliche Wrapper-Todesursache ist.
- Der neue Default von einer Stunde für einen beschäftigten Turn sollte gegen legitime besonders lange Builds oder Tool-Aufrufe geprüft und bei Bedarf lokal über `FM_BUSY_TURN_MAX_SECS` angepasst werden.
- Die zehn echten Herdr-Lifecycle-Tests bleiben für einen separat mit `--herdr-lab` freigegebenen Auftrag offen.
- Der vorbestehende Scheduler-Fehler in `tests/fm-test-run.test.sh` und das fehlende optionale `tsc` sollten unabhängig von dieser Zusammenführung verfolgt werden.
