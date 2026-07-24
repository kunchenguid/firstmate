# FIRSTMATE - sessiolukon P0/P1-korjauksen tilanne

Päivä: 2026-07-24.

Haara: `fm/lukko-korjauskierros` (pohjalla `fm/lukko-korjaus-p0` commitit `41423e0`, `17f28b7`, `2446877`).

Tila: koodityö valmis ja committoitu; no-mistakes/PR odottavat kapteenin päätöstä (käyttörajat estävät validointiputken).

## Valmista (kierros 1 - pohja)

- Tyypitetyt tulokset `OWNED`, `LIVE_OTHER`, `STALE_RECLAIMABLE`, `IDENTITY_UNAVAILABLE`.
- Vanhentuneen numeerisen omistajan atominen reclaim, Codex-thread-identiteetti, confirmed-closed.
- Ei-omistetun tilan mutaatio-ohjeiden pidätys; reclaim vain STALE-tilassa.
- Katso aiempi pohja commit-historiasta.

## Valmista (kierros 2 - P0 + kaksi P1)

### P0 - orpo `state/.lock-reclaim`
- Reclaim-mutexiin kirjoitetaan omistaja-PID ja `started`-aikaleima.
- Vain todistettavasti hylätty mutex saa vanhentua: elävä omistaja-PID ei koskaan ohiteta; kuollut PID voidaan poistaa; legacyn no-pid -hakemisto vain ikäkynnyksen jälkeen (`FM_RECLAIM_MUTEX_STALE_AFTER`, oletus 2 s, sama mid-acquire-ajatus kuin wake-libissä).
- Hätäpoisto-ohje skriptin headerissa.
- Ei `flock`:ia (macOS).

### P1 - tilapäinen varaus ≠ identity
- Uusi tulos `RECLAIM_BUSY` (exit 13).
- Status säilyttää pääriippumattoman `STALE_RECLAIMABLE`-luokituksen mutexin ollessa varattu.
- Session-start yrittää reclaimia lyhyesti uudelleen busy-tuloksella.
- Valvontaohje erottaa busy-retryn identity-palautuksesta.

### P1 - typettömät reclaim-exitit
- Jokainen reclaim-epäonnistumispolku emittoi `LOCK_RESULT=` ja uudelleenluokittelee todellisen tilan.

### Testit
- Orpo mutex + stale/free → toipuu.
- Elävä mutex-omistaja → ei vallata; tulos `RECLAIM_BUSY` ei `IDENTITY_UNAVAILABLE`.
- Reclaim-epäonnistumiset emittoivat aina `LOCK_RESULT=`.
- Aiemmat lukko-/session-start-/supervision-testit vihreinä.

## Todennettu 2026-07-24 (kierros 2)

- `tests/fm-lock.test.sh`: 14/14 ok.
- `tests/fm-session-start.test.sh`: ok.
- `tests/fm-supervision-instructions.test.sh`: ok (sis. RECLAIM_BUSY).
- `tests/fm-instruction-owners.test.sh`: ok.
- `bin/fm-lint.sh`: ShellCheck 0.11.0 ok.

## Tunnetut ympäristöpunaiset (eivät tämän työn vikoja)

- `tests/fm-calm-pi-extension.test.sh` vaatii Pi 0.81.1, koneella 0.80.10.
- `tests/fm-backend-orca.test.sh` / macOS Bash 3.2 (#886).

## Kesken

- No-mistakes-validointia ei ajeta: Codex-krediitit ja varapolun este.
- Haaraa ei ole pushattu eikä PR:ää avattu.

## Seuraava askel

Kapteeni päättää validoinnista ja PR:stä.
Kun korjaus on päähaarassa, päivitä `data/learnings.md`.
