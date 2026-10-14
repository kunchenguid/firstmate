# Plan: Spend-Obergrenze beim Eintritt in den Away-Modus aus der lebenden Worker-Zahl

## Annahme

Beim Eintritt in den Away-Modus können bereits gewöhnliche Worker in diesem Home laufen.
Ich setze voraus, dass "die Zahl, die gerade vorliegt" genau die Zahl ist, die die Spend-Sperre in `bin/fm-spawn.sh` später zählt: jede `state/*.meta` ohne `kind=secondmate`, ohne weitere Lebendigkeitsprüfung am Endpunkt.
Ich setze außerdem voraus, dass der bisherige Default 4 eine Untergrenze bleibt, also auch dann gilt, wenn gerade niemand läuft, und dass die Obergrenze nie 0 werden darf.
Das Feld `spend_max_concurrent_workers` wird in jeden Satz geschrieben, auch in einen Quiet-Satz, der es nicht anzeigt; die Berechnung läuft deshalb unabhängig vom Modus und ändert am Quiet-Verhalten nichts.

## Zwei Wege

Weg A (nicht aus dem Auftrag): `bin/fm-afk-launch.sh` zählt beim Eintritt selbst und reicht das Ergebnis als `--spend <n>` an `bin/fm-afk-contract.sh enter` weiter.
Den lasse ich.
Die Zahl sähe dann wie eine ausdrückliche Angabe des Captains aus, der Refresh-Hinweis "die mitgegebene Obergrenze wurde nicht angewendet" würde über eine Zahl sprechen, die niemand genannt hat, und der Besitzer des Satzes verlöre seinen eigenen Default.

Weg B (gewählt): `bin/fm-afk-contract.sh` bleibt Besitzer und löst die Obergrenze selbst auf, wenn `--spend` fehlt; die Zählung bekommt dort ein Unterkommando, das `bin/fm-spawn.sh` an der Stelle seiner bisherigen eigenen Schleife aufruft.
Damit gibt es genau eine Definition der Zahl, und der Eintritt kann sich nicht von der späteren Sperre unterscheiden.
`bin/fm-afk-launch.sh` reicht seine Argumente weiter wie bisher und braucht keine Änderung.

## Ablehnung

Ein erfahrener Kollege würde eine zweite, leicht abweichende Zählschleife im Eintritt ablehnen, weil Eintritt und Sperre dann auseinanderlaufen können, ohne dass ein Test das merkt.
Er würde ebenso ablehnen, wenn ein ausdrückliches `--spend` überschrieben würde, wenn die Obergrenze unter den bisherigen Default fallen könnte, oder wenn ein leeres Home 0 ergäbe und der Modus jede Arbeit blockierte.
Und er würde erwarten, dass im Kopf von `bin/fm-afk-contract.sh` steht, woher die Zahl kommt, statt dass sie nur im Code auftaucht.

## Nachweis

- `bash tests/fm-afk-contract.test.sh` mit zwei neuen Fällen: Eintritt ohne `--spend` bei mehr lebenden Worker-Sätzen als dem Default übernimmt die lebende Zahl; bei weniger bleibt es beim Default, und ein ausdrückliches `--spend` gewinnt weiterhin.
- `bash tests/fm-afk-launch.test.sh` und die vorhandenen Spawn-Tests für die Spend-Sperre, damit die gemeinsame Zählung auf beiden Seiten gleich bleibt.
- `bin/fm-lint.sh`.

## Grenze

Ich fasse das Satzschema, die Versionierung, den Lock, die Quiet-Ausgabe und den Rückkehrpfad nicht an.
In `bin/fm-spawn.sh` ändere ich nur die Herkunft der Zahl, nicht die Bedingung, die Ausnahmen oder den Wortlaut der Verweigerung.
Keine neue Konfigurationsdatei, kein zweiter Zähler, keine Änderung an `bin/fm-afk-return.sh` oder an der Zählung im Rückkehrbericht.
