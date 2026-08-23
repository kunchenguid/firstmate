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
