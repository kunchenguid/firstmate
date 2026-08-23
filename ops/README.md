# ops/ — Konto-Auth-Frischhalter (2026-08-23)

Automatische OAuth-Erneuerung fuer die vier Claude-Konten (`~/.claude1..4`)
und handlungsableitende Meldungen im Telegram-Nutzungsbericht.
Auftrag: Captain, 23.08.2026 — "wenn die Konten lange nicht benutzt werden,
baut sich die Auth ab … automatisiert … Neu-Anmeldung bleibt meine Sache."

## Bestandteile (dieses Verzeichnis ist die Wiederherstellungskopie)

| Datei | Installationsort (maschinen-lokal) |
|---|---|
| `fm-konto-auth-refresh` | `~/.local/bin/fm-konto-auth-refresh` |
| `systemd/fm-konto-auth.service` | `~/.config/systemd/user/fm-konto-auth.service` |
| `systemd/fm-konto-auth.timer` | `~/.config/systemd/user/fm-konto-auth.timer` |
| `fm-usage-bericht.py` | `~/.local/bin/fm-usage-bericht.py` (Vorher-Fassung: `~/.local/bin/fm-usage-bericht.py.vor-konto-auth-20260823`) |

Wiederherstellen = Dateien an die Orte kopieren (`chmod +x` beim Refresh-Skript),
danach `systemctl --user daemon-reload && systemctl --user enable --now fm-konto-auth.timer`.

## Wie die Erneuerung funktioniert (gemessen, nicht geraten)

- Endpunkt und Aufrufform wurden am 23.08.2026 direkt aus der installierten
  Claude-Code-Binary 2.1.241 gelesen: `POST https://platform.claude.com/v1/oauth/token`
  mit `{grant_type:"refresh_token", refresh_token, client_id, scope}` und
  User-Agent `claude-cli/<version>`. Client-ID ist die oeffentliche
  Claude-Code-ID aus der Binary. **Kein Modellaufruf, keine Kosten.**
- Access-Token leben ~8h; das Skript erneuert bei <=2h Restlauf oder wenn der
  Refresh-Token binnen 7 Tagen verfaellt. Timer-Takt 6h (`Persistent=true`
  holt Rechner-aus-Zeiten nach).
- Der Server ROTIERT den Refresh-Token bei jeder Erneuerung — das Skript
  schreibt ihn zurueck (atomar, 0600). Ohne Rueckschreiben wuerde man sich
  selbst aussperren.
- `refresh_token_expires_in` ist als Restlaufzeit auf ein FIXES Ablaufdatum
  gemessen (3 Erneuerungen, sekundengleich): Refreshs VERLAENGERN die
  Refresh-Token-Lebenszeit NICHT — sie startet neu nur bei echter Anmeldung.
  Folge: ~4 Wochen nach dem letzten echten Login wird je Konto EINE
  Neu-Anmeldung noetig (Fenster nach heutigem Stand: 11.-17.09.2026).

## Sicherheitseigenschaften

- Token erscheinen in keinem Log und keiner Ausgabe; nur Ablaufdaten,
  Ja/Nein-Felder, HTTP-Codes.
- Konten mit laufenden Claude-Sessions (Prozess `comm == claude`, gleiche
  `CLAUDE_CONFIG_DIR`) werden uebersprungen — keine Rotation hinter dem Ruecken
  einer Live-Session. Shells & andere Erben der Env-Zaehlen nicht mehr
  (erster Entwurf tat das fälschlich und wurde korrigiert).
- Pro Konto flock; Timer und Berichts-Recheck koennen sich nicht ueberholen.
- Abbruchgrenze 3 Fehlversuche, dann Marker `<state>/kontoN.tot`; erst eine
  Veraenderung der Credentials (echte Anmeldung) entkraeftigt ihn.
- Hermetische Tests ohne Beruehrung des echten Zustands:
  `FM_KONTO_AUTH_STATE_DIR=<dir> FM_KONTO_AUTH_DIR_MAP="3=/tmp/xyz" …`

## Zusammenspiel

- `fm-usage-bericht.py`: liest sich ein Konto nicht, versucht es EINMAL
  Refresh + Nachlesen. Nur bei totem Refresh-Token erscheint
  `Konto N: Neu-Anmeldung noetig (claudeN oeffnen)` (zusaetzlich einmal je
  Verfall als gesonderte Warnung); sonst neutrale Netz-/Konto-Formulierung.
- `fm-lastverteilung` blieb unveraendert: es liest dieselben Credentials via
  quota-axi und heilt sich damit automatisch, solange der Frischhalter läuft.

## Bekannte Grenzen

- Rechner aus > ~2h kann den Access-Token verfallen lassen, bis der naechste
  Timer-Lauf (`Persistent`) nachholt — der Bericht-Recheck schliesst diese
  Luecke beim naechsten Lesen sofort.
- Die Live-Session-Erkennung schuetzt vor Rotations-Rennen; ein Konto, dessen
  einzige Session tagelang haengt, erneuert nicht, bis sie endet.

---

# fm-lastverteilung — Blindempfehlungs-Sperre (23.08.2026)

Auftrag `fm-lastverteilung-blindempfehlung` (Befund sm-snacksuite 23.08.):
`fm-lastverteilung --worker` empfahl wiederholt `.claude2`, waehrend dessen
Lesung zeitweise `'?'` war und der echte Wochenrest dort gegen 0 lief.

## Bestandteile (Wiederherstellungskopie)

| Datei | Installationsort (maschinen-lokal) |
|---|---|
| `fm-lastverteilung.vor-blindempfehlungs-sperre-20260823` | Vorher-Fassung von `~/.local/bin/fm-lastverteilung` (Stand 17:18, inkl. Sitz-Umzug O-0006) |

Wiederherstellen = Datei nach `~/.local/bin/fm-lastverteilung` kopieren
(`chmod +x`). Die gesperrte Fassung lebt nur maschinen-lokal; dieser Zweig
haelt die Vorher-Kopie als Rueckholpunkt.

## Was die Sperre macht (am echten Werkzeug nachgestellt und geprueft)

`konto_lesen` stuft eine Lesung jetzt genau dann als unlesbar aus (Zeile
`N ? ? -`, Anzeige "UNLESBAR", in JEDEM Rang von `ziel_bestimmen`
uebergangen), wenn:

- quota-axi fehlschlaegt oder keine gueltige JSON-Antwort liefert (bisher schon),
- die Antwort keinen oder mehrere `claude`-Anbieter-Eintraege enthaelt,
- **der Zustand nicht eindeutig frisch ist** (`state.stale: true` oder
  `state.status` weder `fresh` noch `ok`) — NEU. quota-axi kann bei
  gescheitertem Abruf den Zwischenstand aus `~/.cache/quota-axi/quotas.json`
  mit Zahlen liefern; genau solche Zahlen wurden bisher wie frische gerankt
  (roter Fall, im Sandkasten am echten Werkzeug reproduziert),
- `percentRemaining` fehlt, keine ganze Zahl ist oder ausserhalb 0..100 liegt,
- das Wochenfenster in der Antwort fehlt (18.08.-Regel, unverändert:
  Teilantwort ist unbekannt, nie "ohne Wochenfenster").

Bleibt kein startfaehiges Konto uebrig, verweigert die `--worker`-Weiche laut
(stderr + Exit 1, Weiche vom 20.08., unveraendert). Gesunde Konten werden
unveraendert empfohlen (Gegenprobe am echten Lauf: Konto 1 bei 54 %/88 %).

Die Sperre wirkt auch OHNE den Frischhalter-Timer: schlaegt eine Erneuerung
fehl, liefert quota-axi Zwischenstand- oder Auth-Zustaende — beides faellt
nun unter "unlesbar" statt unter "Empfehlung".

## Randbefund (nicht hier behoben, Captain-Vorentscheid)

Nachstellung des Befund-Morgens: mit Sitz auf Konto 3, Konto 1 hart gegrenzt
(Woche 3 %) und Konto 2 bei GENAU 15 % Wochenrest und vollem 5h-Fenster
waehlt die Regel Konto 2 — `SCHWELLE_WOCHE=15` meint "unter diesem Wert",
15 selbst bleibt also reguläres Rang-2-Ziel, und der Rang folgt dann dem
groessten 5h-Fenster. Das erklaert einen Teil der Morgen-Empfehlungen ohne
jede Unlesbarkeit. Ob die Wochenschwelle inklusiv greifen soll, entscheidet
der Captain (ein ENV-Wert, keine Codeaenderung).

