# Totmann-Wiederanlauf vollautonom (`bin/fm-totmann.sh`)

Befund des Captains beim Erstlauf 24.08.2026 (O-0063-Nacht): nach dem Reboot
belebte der Totmann die Sitzung mit `claude4 --continue`, tippte aber keinen
Kick - die Sitzung lag mit altem Kontext am stillen Prompt, bis der Captain
selbst `/clear` + Anstoss ausloeste. Diese Seite dokumentiert die geschlossene
Kette vom Strom-an bis zum arbeitenden ersten Zug und die Probe fuer den
bevorstehenden Live-Test-Reboot.

## Kette im Vollautomatik-Lauf

1. Strom an, Firmware startet - kein LUKS, keine Passwortabfrage vor GDM.
2. GDM meldet den Nutzer automatisch an.
   Vorbedingung (bereits gesetzt auf ausdrueckliches Captain-Wort, nicht Teil
   dieses Skripts): `AutomaticLoginEnable = true` und `AutomaticLogin = <nutzer>`
   in `/etc/gdm3/custom.conf`. Tradeoff, vom Captain gebilligt: physischer
   Zugriff auf die Kiste genuegt dann fuers Sitzungs-Anmelden.
3. Die nutzer-Einheiten laufen dank `Linger=yes` (`loginctl show-user <nutzer>
   -p Linger`) auch ohne interaktive Anmeldung - Timer und tmux starten.
4. `fm-deadman.timer` ruft alle 5 Minuten `~/.local/bin/fm-deadman.sh`
   auf, der nach `$FM_HOME=/home/fridjof/firstmate` und
   `FM_TOTMANN_RELAUNCH_CMD='claude4 --continue'` in `bin/fm-totmann.sh check`
   verdrahtet.
5. Der Totmann stellt strukturell fest, dass die Fuehrungssitzung tot ist
   (keine lebende Sperr-PID, nacktes Shell-Fenster), entscheidet den Modus und
   belebt:
   - **Boot-Wiederanlauf** (Boot-Epoche aus `/proc/stat` neuer als
     `state/.totmann-last-restart`): Relaunch tippen, auf den ersten
     Startdigest warten, dann `/clear` tippen (fm-neustart-Mechanik), danach
     `fm-anstoss --hintergrund <pane> <stempel>` bewaffnen. Der Stempel wird
     vor dem `/clear` erzeugt, damit nur der nach dem Reset gedruckte Digest
     den Kick ausloest.
   - **Tages-Haenger** (Boot aelter als die letzte Wiederbelebung):
     `--continue` plus Anstoss, nie ein automatisches `/clear`.
   - Ohne lesbare Boot-Epoche: Tages-Haenger-Verhalten mit lauter Warnzeile.
6. `fm-anstoss` wartet auf den frischen Digest und den leeren Eingabestand und
   tippt eine als operativ markierte Startnachricht - das ist der erste Zug,
   der Wake-Queue und Morgenlauf abarbeitet ("Morgenlauf-Kick").

## Nachweis-Grenze der Unit-Level-Proben

Die Komponisten-Pruefung (`bin/fm-composer-lib.sh`) verlangt einen positiven
Leerbeweis der echten Claude-Eingabezeile. Gegen ein nacktes Bash-Fenster
tippt der Boot-Pfad Relaunch und `/clear` sichtbar ins Fenster (Beleg:
`.no-mistakes/totmann-revival-trockenprobe-2026-08-24.log`), aber der Anstoss
verweigert zu Recht das Nachtippen (`composer=unknown`). Den endgueltigen
Beweis "Reboot ohne Captain-Eingabe bis zum arbeitenden Zug" liefert nur der
Live-Reboot gegen die echte Sitzung.

## Live-Test-Reboot (offener Punkt)

Nur nach der Reservierungs-Regel (Eintrag unter `state/reservierungen/<ziel>.md`,
siehe `data/learnings.md` vom 24.08.) und ausserhalb der Captain-Fenster;
der Reboot selbst bleibt ein koordinierter Schritt mit anwesendem Firstmate,
kein Eigenmaechtigakt eines Workers.

Probe vor dem Neustart:

    printf '%s\n' "holder: firstmate  purpose: Test-Reboot Totmann-Kette  expiry: +2h" \
      > "$FM_HOME/state/reservierungen/reboot.md"

Erwartete Journal-Timeline nach dem Test-Reboot (alles ohne Captain-Eingabe):

    journalctl --list-boots --no-pager | tail -2        # neuer Boot-Eintrag
    journalctl -b -u gdm.service --no-pager | grep -iE 'automatic|session opened'
      # statt gdm-greeter/gdm-password: direkte Session fuer <nutzer> per Autologin
    journalctl --user -b -u fm-deadman.service --no-pager | tail
      # Starting/Finished innerhalb der ersten ~5 Minuten nach Boot
    tail "$FM_HOME/state/.fm-anstoss.log"
      # "start ... digest erkannt ... gesendet: verdict=empty" nach dem Boot

Akzeptanz: genau diese Timeline plus ein arbeitender erster Zug im
Fenster `firstmate:0`, ohne dass der Captain etwas tippt.

## Zustand und Stellschrauben

Der Skriptkopf von `bin/fm-totmann.sh` ist der einzige Owner der Felder;
Tests: `tests/fm-totmann.test.sh`. Wichtigste Umgebungsvariablen:
`FM_TOTMANN_TARGET`, `FM_TOTMANN_RELAUNCH_CMD`, `FM_TOTMANN_ANSTOSS`
(Stummel/Dummy moeglich, "" schaltet ab), `FM_TOTMANN_READY_SECS`,
`FM_TOTMANN_PROC_STAT` (synthetisch fuer Tests), `FM_TOTMANN_DEBOUNCE`.
