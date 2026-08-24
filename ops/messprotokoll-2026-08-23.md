# Messprotokoll — Konto-Auth-Frischhalter, 23.08.2026

Alle Zeiten UTC bzw. lokal (CEST=UTC+2) wie angegeben. Kein Secret wurde
ausgegeben oder geloggt; nur Ablaufdaten und Ja/Nein-Felder.

## Frage 1: Was erneuert die Auth wirklich — ohne Modellaufruf?

**Methode:** Binary-Leseanalyse der installierten Claude-Code-Version
(`~/.local/share/claude/versions/2.1.241`, ELF/Bun-Bundle):

- `TOKEN_URL:"https://platform.claude.com/v1/oauth/token"`
- Client-ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (oeffentliche
  Claude-Code-ID, Bestandteil jeder Auslieferung)
- Aufrufform im Code:
  `{grant_type:"refresh_token", refresh_token:e,
    client_id:n??ol().CLIENT_ID, scope:(…gespeicherte Scopes…).join(" ")}`
  mit Headern `Content-Type: application/json` und User-Agent
  `claude-cli/<version> …`
- Antwortverarbeitung im Code:
  `access_token`, `refresh_token` (optional; sonst alter bleibt),
  `expires_in`, `refresh_token_expires_in`, `scope`.
- quota-axi (`dist/src/providers/claude.js`): fragt nur
  `https://api.anthropic.com/api/oauth/usage` mit dem gespeicherten
  Access-Token — **kein Refresh-Weg vorhanden**. Dasselbe gilt für den alten
  Nutzungsbericht. Die CLI selbst refreshed beim Start/bei Nutzung; genau
  dieser Schritt wurde automatisiert.

## Frage 2: Beleg stale→fresh an einem echten Konto (Konto 3, keine laufende Session)

| Schritt | Befund |
|---|---|
| Vorher-Zustand | Access-Token gültig bis 2026-08-23 15:45 UTC (**abgelaufen**), Refresh-Token bis 2026-09-13 20:56 UTC |
| Leseversuch Usage-API mit altem Token | **HTTP 429** → Konto unlesbar („nicht verfügbar"-Zustand) |
| Erneuerungslauf 17:21 UTC | `erneuert: gueltig bis 2026-08-24 01:21 UTC (vorher 15:45), Refresh-Token rotiert: ja` |
| Leseversuch danach | **HTTP 200**, echte Zahlen: 5h-Fenster 0 %, Woche 94 % |
| Bedarfscheck direkt danach | „gesund" → kein unnötiger Request (Hammer-Schutz wirkt) |

Kosten: **0 Modellaufrufe, 0 €** — reine Token-Endpunkt-Aufrufe mit den je
Konto lokal gespeicherten OAuth-Credentials (`~/.claudeN/.credentials.json`);
kein externer Key nötig.

## Frage 3: Verlängert automatische Erneuerung die Refresh-Token-Lebenszeit?

Erneuter Zwangs-Lauf (--force) auf Konto 3:

```
17:23:32 konto3: erneuert: gueltig bis 2026-08-24 01:23 UTC
          (vorher 01:21), Refresh-Token bis 2026-09-13 20:56 UTC
          (vorher 20:56), Refresh-Token rotiert: ja,
          Refresh-Laufzeit verlaengert: ja
```

Trotz geliefertem `refresh_token_expires_in` blieb das Ablaufdatum
**sekundengleich unverändert** (Server liefert Restlaufzeit aufs feste Datum).
Kreuzprobe aller vier Konten: jedes `refreshTokenExpiresAt` liegt ~28 Tage
nach der letzten echten Anmeldung:

| Konto | Refresh-Token gültig bis | entspricht Login +28d um |
|---|---|---|
| 1 | 2026-09-12 21:18 | ~15.08. (Umzugstag) |
| 2 | 2026-09-11 21:00 | ~14.08. |
| 3 | 2026-09-13 20:56 | ~16.08. (Rückzug als Hauptkonto) |
| 4 | 2026-09-17 02:53 | 20.08. (Anlagedatum) |

**Modell:** Access-Token-Erneuerung ist unbegrenzt automatisierbar und hält
die Konten dauerhaft lesbar; die Refresh-Token-Lebenszeit startet nur bei
echter Anmeldung neu → je Konto **eine Neu-Anmeldung pro ~4 Wochen** bleibt
(aktuelles Fenster: 11.–17.09.2026), danach meldet der Bericht
handlungsableitend statt unlesbar.

## Frage 4: Erster echter Timer-Lauf (Journal)

```
19:24 systemd[2005]: Starting fm-konto-auth.service …
19:24 fm-konto-auth-refresh[2470411]: konto1: uebersprungen: 18 laufende Session(s)
19:24 fm-konto-auth-refresh[2470411]: konto2: uebersprungen: 1 laufende Session(s)
19:24 fm-konto-auth-refresh[2470411]: konto3: gesund: gueltig bis 2026-08-24 01:23 UTC
19:24 fm-konto-auth-refresh[2470411]: konto4: uebersprungen: 1 laufende Session(s)
19:24 systemd[2005]: Finished fm-konto-auth.service …
```

Timer aktiv, nächste Auslösung 23:14 CEST, Takt 6h (`Persistent=true`).

## Frage 5: Tot-Pfad und Genesung (Sandkasten, echte Konten unberührt)

Simuliertes Konto mit totem Refresh-Token (`FM_KONTO_AUTH_STATE_DIR` +
`FM_KONTO_AUTH_DIR_MAP` nach /tmp):

- Lauf 1+2: neutral „Netz oder Konto unklar - Anmeldung prüfen"
- Lauf 3 (Abbruchgrenze): Marker gesetzt,
  `<b>Konto 3:</b> Neu-Anmeldung noetig (claude3 oeffnen)` — exakter Wortlaut
- Simulierte Neuanmeldung (Dateiänderung): Marker entfällt, Konto wird wieder
  normal bewertet.

## Nachweis Tot-Verhalten im echten Bericht

Siehe `ops/fm-usage-bericht.py`: Recheck vor jeder Unlesbar-Meldung; nur
nachweislich tote Refresh-Tokens erhalten den handlungsableitenden Text plus
EINMAL eine gesonderte Warnung je Verfall (Zustand in state.json).

## Echte Telegram-Zustellung des neuen Berichts (20:23 Uhr)

`~/.local/share/claw-notify/history.jsonl`, Eintrag 381:

```
2026-08-23T20:23:02+0200 | bot TELEGRAM_BOT_TOKEN | status "ok @Kimi_Cool_fst_bot"
<b>Nutzungsbericht</b> 20:23
Konto 1: 5h 34%, Woche 9%, Fable 3%
Konto 2: 5h 1%, Woche 85%, Fable 7%
Konto 3: 5h 0%, Woche 94%, Fable 86%   <- heute Morgen noch unlesbar ('?')
Konto 4: 5h 23%, Woche 56%, Fable 9%
```

Alle vier Konten mit echten Zahlen, kein „nicht abrufbar". Konto 3 ist
dasselbe, das der Captain heute öffnen musste, damit es wieder lesbar wird —
seit 17:21 UTC erledigt das die Erneuerung selbstständig.

## Nebenbefund (repariert): Probelauf verschob den Stundentakt

Der alte Bericht schrieb seinen Zustand auch im Probelauf (`--dry-run`)
zurück — darunter den Zeitstempel der letzten Volllieferung. Ein Probelauf
verzögerte also die nächste echte Stunde zustellungsfrei um seine eigene
Laufzeit (heute 20:07/20:22 unschädlich beobachtet, 20:23 dann regulär
gesendet). Repariert: Probelauf schreibt jetzt gar nichts mehr.

