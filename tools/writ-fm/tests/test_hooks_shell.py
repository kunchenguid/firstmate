"""Die Shell-Hooks — beide Richtungen, dauerhaft.

Ein Hook, der nur bei der gewuenschten Eingabe geprueft wird, beweist nichts:
er koennte alles blocken. Jeder Fall hier hat deshalb ein Gegenstueck.

Die Gegenproben standen bis 2026-08-07 nur im Beleg
(belege/t5-hook-gegenproben.md) — also im Transkript eines Tages. Ein
Suchmuster, das niemand nachprueft, franst aus; das ist derselbe Drift, gegen
den REG-SKILL-001 geschrieben wurde.
"""

from __future__ import annotations

import subprocess
import unittest

from hilfe import REPO

GUARD = REPO / "hooks/bash-guard.sh"
LEDGER = REPO / "hooks/prozess-ledger.sh"
ONBOARDING = REPO / "hooks/onboarding.sh"
PROMPTREGELN = REPO / "hooks/prompt-regeln.sh"

# Die beiden Schalter werden fuer JEDEN Lauf hier aus der Umgebung genommen und
# nur gesetzt, wo ein Test sie ausdruecklich will. Ohne das haenge diese Datei
# davon ab, wie das Terminal gestartet wurde: liefe die Suite selbst unter
# `claude-free`, erbten die Hooks WRIT_RULES=aus — und saemtliche Sperrtests
# waeren still gruen, weil der Waechter im ersten Schritt aussteigt. Ein Test,
# der von einer geerbten Variablen abhaengt, prueft an manchen Tagen nichts.
SCHALTER = ("WRIT_RULES", "WRIT_GUARD")


def umgebung(**gesetzt) -> dict:
    """Die echte Umgebung, aber ohne die Schalter — ausser den genannten."""
    import os

    env = {k: v for k, v in os.environ.items() if k not in SCHALTER}
    env.update({k: v for k, v in gesetzt.items() if v is not None})
    return env


class TestRegelHooks(unittest.TestCase):
    """Die beiden Hooks, die das Regelwerk zustellen — wirklich ausgefuehrt.

    Bis 2026-08-07 pruefte NICHTS diese Skripte. Sie waren getestet, soweit
    ihr Python-Teil getestet war, und `doctor` verglich Repo mit Wirkort.
    Beides ging an der Sache vorbei:

    Beim Kimi-Ausbau fiel `--runtime` aus der CLI, und `onboarding.sh` rief
    weiter `session-start --runtime claude` auf. argparse brach ab, der
    Notfallpfad griff — und JEDE neue Session startete mit "REGELWERK NICHT
    LADBAR" statt mit den Regeln. `doctor` meldete [ok], weil beide Kopien
    dieselbe falsche Datei waren.

    Der Notfalltext ist deshalb hier ein FEHLSCHLAG, kein gueltiges Ergebnis:
    er ist die Meldung, dass das Regelwerk nicht geliefert werden konnte.
    Diese Tests laufen gegen den echten Bestand unter ~/.local/share — sie
    pruefen die Zustellung auf diesem Rechner, nicht eine Attrappe.
    """

    def lauf(self, skript, eingabe: str, **env) -> subprocess.CompletedProcess:
        return subprocess.run([str(skript)], input=eingabe, capture_output=True,
                              text=True, timeout=60, env=umgebung(**env))

    def heim(self) -> "Path":
        """Ein Wegwerf-$HOME fuer die Laeufe im Aus-Modus.

        Zwei Gruende. Erstens schreibt der Hook sein Protokoll nach
        `$HOME/.local/share/writ-light/session-start.log` — ohne eigenes Heim
        traegt jeder Testlauf regelfreie Starts in das echte Protokoll ein und
        faelscht damit genau die Zahl, die `writ-light doctor` seit
        2026-08-08 ausweist. Zweitens wird die Protokollzeile so ueberhaupt
        pruefbar: dass sie VOR dem Ausstieg geschrieben wird, sieht man nur,
        wenn man nachsehen kann, wo sie gelandet ist.

        Nur fuer den Aus-Pfad brauchbar: er steigt vor `$WRIT` aus. Die Laeufe
        MIT Regelwerk brauchen das echte Heim, dort liegt der Bestand.
        """
        import tempfile
        from pathlib import Path

        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        return Path(d.name)

    def protokollzeilen(self, heim) -> list[str]:
        p = heim / ".local/share/writ-light/session-start.log"
        return p.read_text(encoding="utf-8").splitlines() if p.exists() else []

    def test_sessionstart_liefert_regeln_statt_notfalltext(self):
        r = self.lauf(ONBOARDING, '{"source":"startup"}')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("NICHT LADBAR", r.stdout,
                         "SessionStart faellt auf den Notfallpfad — CLI-Aufruf pruefen")
        self.assertIn("REGELWERK", r.stdout)
        self.assertIn("MANDATORY", r.stdout)

    def test_sessionstart_gibt_gueltiges_hook_json(self):
        import json

        r = self.lauf(ONBOARDING, '{"source":"startup"}')
        d = json.loads(r.stdout)
        self.assertEqual(d["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertTrue(d["hookSpecificOutput"]["additionalContext"].strip())

    def test_userpromptsubmit_liefert_gerankte_regeln(self):
        import json

        r = self.lauf(PROMPTREGELN,
                      '{"prompt":"darf ich committen?","cwd":"' + str(REPO) + '"}')
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        text = d["hookSpecificOutput"]["additionalContext"]
        self.assertIn("--- REGELN", text)
        self.assertIn("Verbindlich", text, "die ID-Zeile aus E1 fehlt")

    def test_aus_modus_liefert_den_aus_hinweis_statt_der_regeln(self):
        """`claude-free`: Regelwerk aus, aber sichtbar aus.

        Der Aus-Hinweis muss vom Notfalltext unterscheidbar bleiben — sonst
        meldet eine Session, die der Owner absichtlich regelfrei gestartet
        hat, jedes Mal einen Ausfall (oder, schlimmer, ein echter Ausfall
        geht als Owner-Wunsch durch).
        """
        for wert in ("aus", "off", "0", "nein"):
            with self.subTest(wert=wert):
                r = self.lauf(ONBOARDING, '{"source":"startup"}',
                              WRIT_RULES=wert, HOME=str(self.heim()))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("REGELWERK AUS", r.stdout)
                self.assertNotIn("NICHT LADBAR", r.stdout,
                                 "Aus-Modus darf nicht wie ein Ausfall aussehen")
                self.assertNotIn("MANDATORY", r.stdout, "Regeln trotz WRIT_RULES=aus")

    def test_aus_hinweis_ist_gueltiges_hook_json(self):
        """Gegenstueck zu test_sessionstart_gibt_gueltiges_hook_json.

        Ein kaputtes Heredoc liefert weder Regeln noch Hinweis — und das ist
        schlimmer als jeder der beiden Zweige, weil die Session dann gar
        nichts erfaehrt.
        """
        import json

        r = self.lauf(ONBOARDING, '{"source":"startup"}',
                      WRIT_RULES="aus", HOME=str(self.heim()))
        d = json.loads(r.stdout)
        self.assertEqual(d["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertIn("REGELWERK AUS",
                      d["hookSpecificOutput"]["additionalContext"])

    def test_unbekannter_wert_laesst_das_regelwerk_scharf(self):
        """Ein Tippfehler darf keine Sperre aufheben — wie beim Waechter."""
        r = self.lauf(ONBOARDING, '{"source":"startup"}', WRIT_RULES="quatsch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("REGELWERK AUS", r.stdout)
        self.assertIn("MANDATORY", r.stdout)

    def test_regelfreier_start_wird_protokolliert(self):
        """Die Reihenfolge im Skript, nachgemessen statt geglaubt.

        Stdin lesen und protokollieren stehen VOR dem Ausstieg. Sonst waere
        der bequeme Alias der einzige Vorgang im System, der keine Spur
        hinterlaesst — und `writ-light doctor` zaehlte dauerhaft null.
        """
        heim = self.heim()
        self.lauf(ONBOARDING, '{"source":"startup"}', WRIT_RULES="aus",
                  HOME=str(heim))
        zeilen = self.protokollzeilen(heim)
        self.assertEqual(len(zeilen), 1, zeilen)
        felder = zeilen[0].split("\t")
        self.assertEqual(felder[1], "startup", "Quelle fehlt oder Format gekippt")
        self.assertEqual(felder[2:], ["regeln=aus"])

    def test_normaler_start_protokolliert_ohne_zusatzfeld(self):
        """Rueckwaertskompatibel: `<zeit>\\t<quelle>` bleibt, das Feld haengt hinten.

        Geprueft wird hier nur die Protokollzeile; die Ausgabe faellt mit
        fremdem $HOME auf den Notfallpfad, weil dort kein Bestand liegt.
        """
        heim = self.heim()
        self.lauf(ONBOARDING, '{"source":"compact"}', HOME=str(heim))
        zeilen = self.protokollzeilen(heim)
        self.assertEqual(len(zeilen), 1, zeilen)
        self.assertEqual(zeilen[0].split("\t")[1:], ["compact"])

    def test_doctor_zaehlt_genau_das_was_der_hook_schreibt(self):
        """Die beiden Haelften muessen sich ueber das Format einig sein.

        Der Hook schreibt ohne Python, `doctor` liest mit — ein Test je
        Haelfte wuerde nicht auffallen lassen, dass sie aneinander vorbeireden.
        """
        from writ_light import cli

        heim = self.heim()
        for wert in ("aus", "nein"):
            self.lauf(ONBOARDING, '{"source":"startup"}', WRIT_RULES=wert,
                      HOME=str(heim))
        self.lauf(ONBOARDING, '{"source":"startup"}', HOME=str(heim))
        protokoll = heim / ".local/share/writ-light/session-start.log"
        self.assertEqual(cli.regelfreie_starts(protokoll), 2)

    def test_waechter_zeile_steht_nur_bei_abgeschaltetem_waechter(self):
        """Eine Session mit abgeschaltetem Waechter saehe sonst aus wie jede andere."""
        mit = self.lauf(ONBOARDING, '{"source":"startup"}', WRIT_GUARD="aus")
        self.assertIn("claude-unsafe", mit.stdout)
        self.assertIn("WRIT_GUARD=aus", mit.stdout)
        ohne = self.lauf(ONBOARDING, '{"source":"startup"}')
        self.assertNotIn("claude-unsafe", ohne.stdout)

    def test_prompt_hook_schweigt_im_aus_modus(self):
        """Schweigen ist hier richtig: der Session-Start hat es schon angesagt.

        Eine Wiederholung bei JEDER Eingabe waere Laerm — und Laerm wird
        weggelesen, auch der Teil, der zaehlt.
        """
        for wert in ("aus", "off", "0", "nein"):
            with self.subTest(wert=wert):
                r = self.lauf(PROMPTREGELN, '{"prompt":"darf ich committen?"}',
                              WRIT_RULES=wert)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout, "")

    def test_prompt_hook_liefert_bei_unbekanntem_wert_weiter_regeln(self):
        r = self.lauf(PROMPTREGELN,
                      '{"prompt":"darf ich committen?","cwd":"' + str(REPO) + '"}',
                      WRIT_RULES="quatsch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--- REGELN", r.stdout)

    def test_beide_hooks_sind_ausfuehrbar(self):
        import os

        for p in (ONBOARDING, PROMPTREGELN):
            with self.subTest(hook=p.name):
                self.assertTrue(p.exists(), p)
                self.assertTrue(os.access(p, os.X_OK), "nicht ausfuehrbar")

    def test_kein_hook_nennt_ein_flag_das_die_cli_nicht_kennt(self):
        """Der Fehler von 2026-08-07, an der Wurzel gefasst.

        Statt einzelne Flags aufzuzaehlen: jedes `writ-light <befehl> --flag`
        aus den Skripten gegen die tatsaechliche CLI halten. Ein entferntes
        Flag faellt damit auf, ohne dass jemand daran denken muss.

        Der Aufruf steht in den Skripten als `"$WRIT"`, nicht ausgeschrieben —
        die erste Fassung dieses Tests suchte nur nach `writ-light` und war
        deshalb zahnlos. Aufgefallen ist das nur, weil die Gegenprobe zeigte,
        dass er beim echten Fehler NICHT umfiel. Ein Test, der die Wurzel zu
        fassen behauptet und es nicht tut, ist schlimmer als keiner.
        """
        import re

        from writ_light import cli

        parser = cli.build_parser()
        # Die Unterbefehle und ihre erlaubten Optionen aus dem Parser ziehen.
        unterbefehle = {}
        for aktion in parser._actions:
            if hasattr(aktion, "choices") and isinstance(aktion.choices, dict):
                for name, unter in aktion.choices.items():
                    unterbefehle[name] = {s for a in unter._actions
                                          for s in a.option_strings}

        # Erfasst beide Schreibweisen: den ausgeschriebenen Namen und die
        # Variable, hinter der er in den Skripten steckt.
        AUFRUF = re.compile(
            r'(?:writ-light|"?\$\{?WRIT\}?"?)\s+(\w[\w-]*)'
            r'((?:\s+(?:--?[\w-]+|[\w./-]+))*)')

        gefunden = 0
        for skript in (ONBOARDING, PROMPTREGELN, GUARD, LEDGER):
            text = skript.read_text(encoding="utf-8")
            for befehl, rest in AUFRUF.findall(text):
                if befehl not in unterbefehle:
                    continue
                gefunden += 1
                for flag in re.findall(r"--?[\w-]+", rest):
                    with self.subTest(skript=skript.name, befehl=befehl, flag=flag):
                        self.assertIn(flag, unterbefehle[befehl],
                                      f"`writ-light {befehl} {flag}` kennt die CLI nicht")

        # Ohne das koennte der Test gruen sein, weil er NICHTS gefunden hat —
        # genau der Zustand seiner ersten Fassung.
        self.assertGreaterEqual(gefunden, 2,
                                "keine writ-light-Aufrufe erkannt; Suchmuster kaputt")


def guard(befehl: str, schalter: dict | None = None) -> subprocess.CompletedProcess:
    """Den Hook so fuettern, wie Claude Code es tut: Hook-JSON auf stdin."""
    import json

    eingabe = json.dumps({"tool_name": "Bash", "tool_input": {"command": befehl}})
    return subprocess.run([str(GUARD)], input=eingabe, capture_output=True,
                          text=True, timeout=10, env=umgebung(**(schalter or {})))


class TestSelbstumgehung(unittest.TestCase):
    """SPERRE 1: eine laufende Session startet sich nicht selbst mit
    abgeschwaechten Sicherungen neu.

    Ohne sie waere das ganze Regelwerk mit einem einzigen Bash-Aufruf
    abraeumbar — und der Aufruf muesste nicht vom Owner kommen: eingeschleuster
    Text aus einer Webseite, einer Werkzeugausgabe oder einer fremden Datei
    reicht (ENF-INPUT-001). Ein Override, den die Session selbst ziehen kann,
    ist keiner.

    BEIDE Schalter, nicht nur `WRIT_RULES`. Die erste Fassung vom 2026-08-08
    sperrte `claude-unsafe`, liess aber seine woertliche Entsprechung
    `WRIT_GUARD=aus claude` mit Exit 0 durch — eine Sperre, die nur die
    bequeme Schreibweise kennt, erzieht zur unbequemen.
    """

    SPERREN = [
        "WRIT_RULES=aus claude",
        "WRIT_RULES=aus claude --resume",
        "WRIT_RULES=0 WRIT_GUARD=aus claude",
        "export WRIT_RULES=aus && claude",          # Trennzeichen dazwischen
        "WRIT_RULES=aus; claude",
        'echo "x" && WRIT_RULES=aus claude',        # Anfuehrungszeichen davor
        "echo alias claude-free='WRIT_RULES=aus claude' >> ~/.bashrc",
        "claude-free",                              # setzt selbst keine Variable
        "claude-unsafe",
        "cd /tmp && claude-free",
        "WRIT_GUARD=aus claude-unsafe",             # Praefix ist keine Freigabe
        # Die woertliche Entsprechung der Aliase — der Fall, der die
        # Uneinheitlichkeit ausmachte:
        "WRIT_GUARD=aus claude",
        "export WRIT_GUARD=aus && claude",
        "WRIT_GUARD=nein claude --resume",
        # MEHRZEILIG — der Normalfall in dieser Umgebung, und bis 2026-08-08
        # der blinde Fleck: `\n` kam aus dem JSON als die zwei Zeichen `\` und
        # `n` an, hinter denen keine Zeile anfaengt. Alle Listen hier
        # enthielten ausschliesslich Einzeiler; deshalb fiel es niemandem auf.
        "export WRIT_RULES=aus\nclaude -p hallo",
        "cd /tmp\nWRIT_GUARD=aus claude",
        "echo start\n\tclaude-free\necho ende",       # eingerueckt, mit Tab
        # Ohne Leerzeichen nach dem Trennzeichen — gueltige Bash:
        "export WRIT_RULES=aus;claude -p hallo",
        "cd /tmp&&WRIT_RULES=aus claude",
        # Alias an Trennzeichen statt an Leerraum (Punkt 4 der Gegenpruefung):
        "claude-free; echo x",
        "claude-free|cat",
        "(claude-free)",
    ]

    # Die Alias-Woerter zaehlen nur an Befehlsstelle. Ohne diese Grenze sperrte
    # der Waechter die Arbeit an sich selbst: gemessen am 2026-08-08 fielen
    # beide Zeilen unten mit Exit 2 um — ein Commit ueber diese Aenderung und
    # eine Suche nach ihr. Ein Waechter, der das tut, wird abgeschaltet.
    ERWAEHNUNGEN = [
        "git commit -m 'Aliase claude-free und claude-unsafe eingebaut'",
        "grep -rn claude-free docs/",
        "echo claude-free > /tmp/notiz",
        'grep -rn "claude-free" docs/',
    ]

    DURCHLASSEN = [
        # Ohne diese Zeile waere die Verifikation dieses Waechters selbst
        # gesperrt — der Aus-Pfad muss von Hand pruefbar bleiben.
        "WRIT_RULES=aus ~/.claude/hooks/onboarding.sh",
        "WRIT_RULES=aus hooks/onboarding.sh",
        "WRIT_RULES=aus /home/fridjof/.claude/hooks/onboarding.sh",
        "WRIT_RULES=aus ./hooks/onboarding.sh <<<'{}'",
        "WRIT_GUARD=aus ~/.claude/hooks/onboarding.sh",
        "ls ~/.claude/hooks",
        "claude --version",                         # ohne Schalter kein Fall
        # Mehrzeilig, und trotzdem harmlos — die Entescapung darf nicht
        # umgekehrt zum Scharfmacher werden:
        "cd /tmp\nWRIT_RULES=aus ./hooks/onboarding.sh",
        "cd /tmp\ngit status\nls ~/.claude/hooks",
        # `\n` als TEXT im Befehl, nicht als Umbruch: `printf` bekommt hier
        # eine Escape-Sequenz. Wuerde die Entescapung daraus einen echten
        # Umbruch machen, staende `claude` ploetzlich am Zeilenanfang.
        "printf 'WRIT_RULES=aus\\nclaude ist der Alias' > /tmp/notiz",
    ]

    def test_selbststart_ohne_regelwerk_wird_gesperrt(self):
        for befehl in self.SPERREN:
            with self.subTest(befehl=befehl):
                r = guard(befehl)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("GESTOPPT", r.stderr)

    def test_sperre_haelt_auch_bei_abgeschaltetem_git_add_waechter(self):
        """Der Fall, den die REIHENFOLGE absichert — ohne ihn ist sie ungeprueft.

        `WRIT_GUARD` ist der Schalter fuer den `git add`-Waechter und sonst
        nichts. Stuende SPERRE 1 unter seinem Ausstieg, haette `claude-unsafe`
        still auch das Regelwerk freigegeben — ein Schalter, der mehr
        abschaltet, als auf ihm draufsteht.
        """
        for befehl in self.SPERREN:
            for wert in ("aus", "off", "0", "nein"):
                with self.subTest(befehl=befehl, WRIT_GUARD=wert):
                    r = guard(befehl, {"WRIT_GUARD": wert})
                    self.assertEqual(r.returncode, 2,
                                     "WRIT_GUARD hebt die Regelwerk-Sperre auf")

    def test_hookaufruf_zur_pruefung_und_harmlose_befehle_kommen_durch(self):
        for befehl in self.DURCHLASSEN:
            with self.subTest(befehl=befehl):
                r = guard(befehl)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, "")

    def test_die_blosse_erwaehnung_eines_alias_ist_kein_start(self):
        """Die wichtigere Haelfte, wie beim `git add`-Muster: ein Waechter, der
        das Reden ueber ihn verbietet, blockiert seine eigene Wartung."""
        for befehl in self.ERWAEHNUNGEN:
            with self.subTest(befehl=befehl):
                r = guard(befehl)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, "")

    def test_erwaehnung_MIT_startendem_claude_bleibt_gesperrt(self):
        """Die Gegenprobe zur Lockerung: sobald `WRIT_RULES` und ein startendes
        `claude` zusammen im Befehl stehen, greift die UND-Bedingung weiter —
        auch in Anfuehrungszeichen, etwa beim Schreiben einer .bashrc-Zeile."""
        for befehl in ("printf '%s' 'WRIT_RULES=aus claude' > /tmp/x",
                       "WRIT_RULES=aus claude;"):
            with self.subTest(befehl=befehl):
                self.assertEqual(guard(befehl).returncode, 2)

    def test_owner_modus_laesst_den_ganzen_waechter_aus(self):
        """Schritt 1: die aeussere Session ist bereits regelfrei — hier ist
        nichts mehr zu schuetzen, was nicht schon offen laege."""
        for befehl in ("WRIT_RULES=aus claude", "claude-free", "git add -A"):
            for wert in ("aus", "off", "0", "nein"):
                with self.subTest(befehl=befehl, WRIT_RULES=wert):
                    r = guard(befehl, {"WRIT_RULES": wert})
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(r.stderr, "")

    def test_schalter_ohne_neustart_ist_kein_fall_fuer_sperre_1(self):
        """`WRIT_GUARD=aus git add -A` startet nichts neu.

        Ueber diesen Befehl entscheidet der `git add`-Waechter weiter unten,
        nicht SPERRE 1 — sonst haette die neue Sperre still den bestehenden
        Weg (`OWNER_ADD_ALL=1`, Schalter in der Umgebung) mit uebernommen und
        die alte Meldung zeigte ins Leere.
        """
        # Unterschieden wird an `ENF-INPUT-001` — die Regel-ID steht nur in
        # der Meldung von SPERRE 1. Der Satz "startet sich nicht selbst" taugt
        # nicht als Kennzeichen: er steht seit dem Nachziehen der Meldungen in
        # BEIDEN, und genau das ist ja der Zweck (sie sollen sich nicht
        # widersprechen).
        r = guard("WRIT_GUARD=aus git add -A")
        self.assertNotIn("ENF-INPUT-001", r.stderr, "SPERRE 1 greift zu weit")
        self.assertIn("stagt fremde Staende", r.stderr, "falscher Waechter")
        # Und mit dem Schalter in der UMGEBUNG kommt derselbe Befehl durch:
        # der bestehende Ausweg 1 aus SPERRE 2 bleibt unangetastet.
        durch = guard("WRIT_GUARD=aus git add -A", {"WRIT_GUARD": "aus"})
        self.assertEqual(durch.returncode, 0, durch.stderr)

    def test_meldung_nennt_den_weg_fuers_blosse_aufschreiben(self):
        """Bis 2026-08-08 stand hier eine ANNAHME statt eines Auswegs.

        Der Absatz behauptete, wer die Aliase in die `.bashrc` schreibe, sitze
        ohnehin in einer `claude-free`-Sitzung. Am selben Tag widerlegt: die
        Zeilen wurden aus einer ganz normalen Sitzung geschrieben — mit
        Read/Edit, und der Hook haengt am Bash-Werkzeug (matcher "Bash"),
        nicht am Datei-Werkzeug. Die Meldung nannte damit einen Ausweg, der
        nur manchmal stimmt, und verschwieg den, der immer stimmt.
        """
        r = guard("claude-free")
        self.assertIn("Datei-Werkzeug", r.stderr)
        self.assertIn("Read/Edit", r.stderr)
        self.assertIn("sperrt das Ausfuehren, nicht das Aufschreiben", r.stderr)
        self.assertNotIn("laeuft diese Sitzung ohnehin", r.stderr,
                         "die widerlegte Annahme ist zurueck")
        # Der Hinweis waere sinnlos, wenn der Bash-Weg nicht wirklich zu waere:
        ueber_bash = guard("echo alias claude-free='WRIT_RULES=aus claude' >> ~/.bashrc")
        self.assertEqual(ueber_bash.returncode, 2)

    def test_meldung_nennt_was_stattdessen_geht(self):
        """Eine Sperre ohne Ausweg erzieht dazu, sie zu umgehen."""
        r = guard("claude-free")
        self.assertIn("Owner", r.stderr)
        self.assertIn("claude-free", r.stderr)
        self.assertIn("ENF-INPUT-001", r.stderr)
        self.assertIn("WRIT_RULES=aus ~/.claude/hooks/onboarding.sh", r.stderr)

    def test_beide_meldungen_widersprechen_sich_nicht(self):
        """Die `git add`-Meldung empfiehlt `WRIT_GUARD=aus claude` — SPERRE 1
        verbietet es. Beides stimmt nur, wenn beide Meldungen sagen, WER
        gemeint ist: der Owner am Terminal gegen die laufende Session. Ohne
        diesen Satz liest die eine Meldung wie ein Dementi der anderen, und
        eine Sperre, die man fuer einen Fehler haelt, wird umgangen.
        """
        sperre1 = guard("WRIT_GUARD=aus claude").stderr
        gitadd = guard("git add -A").stderr
        self.assertIn("OWNER AM TERMINAL", sperre1)
        self.assertIn("KEIN WIDERSPRUCH", sperre1)
        self.assertIn("claude-unsafe", sperre1)
        self.assertIn("OWNER startet Claude in seinem Terminal", gitadd)
        self.assertIn("nicht selbst mit", gitadd)
        # Der bestehende Test auf beide Auswege darf davon nicht kippen.
        self.assertIn("WRIT_GUARD=aus", gitadd)
        self.assertIn("OWNER_ADD_ALL=1", gitadd)


class TestSondertexteStehenZweimalGleich(unittest.TestCase):
    """Notfalltext und Aus-Hinweis liegen zweimal — das muss abgesichert sein.

    Beide Pfade muessen ohne writ-light auskommen, deshalb traegt
    `hooks/onboarding.sh` eigene Kopien. Bis 2026-08-08 pruefte das NIEMAND:
    die Shell-Kopie des Notfalltexts hatte bereits Backticks und einen
    Schlusspunkt verloren, ohne dass etwas umfiel. Genau dieser Drift hat hier
    schon zweimal zugeschlagen (`--runtime claude`, `/plugins disable
    onboarding`) — beide Male war die Datei fuer sich in Ordnung und stimmte
    nur mit der anderen Seite nicht mehr ueberein.
    """

    def test_jede_zeile_beider_sondertexte_steht_auch_im_shellskript(self):
        from writ_light import hooks

        skript = ONBOARDING.read_text(encoding="utf-8")
        for name in ("AUS_TEXT", "NOTFALL_TEXT"):
            zeilen = [z for z in getattr(hooks, name).splitlines() if z.strip()]
            self.assertGreaterEqual(len(zeilen), 4, f"{name} unerwartet kurz")
            for zeile in zeilen:
                with self.subTest(konstante=name, zeile=zeile):
                    self.assertIn(zeile, skript,
                                  f"hooks.{name} und hooks/onboarding.sh laufen "
                                  f"auseinander")


class TestGitAddGuard(unittest.TestCase):
    SPERREN = [
        "git add -A",
        "git add --all",
        "git add .",
        "cd /tmp && git add -A",
        "git status && git add .",
        "git add -v -A",
        # Bis 2026-08-08 kamen die beiden durch: die Befehlserkennung schnitt
        # am ersten Anfuehrungszeichen ab und sah nur `git commit -m \`.
        'git commit -m "wip" && git add -A',
        'echo "a" ; git add --all',
        # Und diese hier kamen durch, weil `\n` als zwei Textzeichen ankam:
        # hinter ihnen fing keine Zeile an, also griff kein Anker. Mehrzeilige
        # Befehle sind in dieser Umgebung der Normalfall — die Sperre war
        # damit fuer den haeufigsten Fall wirkungslos.
        "cd /tmp\ngit add -A\ngit status",
        "git status\n\tgit add .",                   # eingerueckt, mit Tab
        "cd /tmp;git add --all",                     # ohne Leerzeichen
    ]

    DURCHLASSEN = [
        "git add src/datei.py",
        "git add -- src/a.py src/b.py",
        "git status",
        "git add -p",                        # interaktiv, der Mensch waehlt
        "echo git add -A ist verboten",      # nur erwaehnt, nicht ausgefuehrt
        "git commit -m 'add . nicht vergessen'",
        'git commit -m "add . nicht vergessen"',
        # Mehrzeilig und richtig: die Entescapung macht die Sperre schaerfer,
        # sie darf die Gegenrichtung nicht mitreissen.
        "cd /tmp\ngit add pfad/datei.py\ngit status",
        'echo "git add -A"\ngit status',             # nur Text, nicht ausgefuehrt
        "git status\ngit add -p",
        "git addremote",                     # kein Wortende nach add
        "git log --all",
    ]

    def test_hook_ist_ausfuehrbar(self):
        self.assertTrue(GUARD.exists(), GUARD)
        import os
        self.assertTrue(os.access(GUARD, os.X_OK), "nicht ausfuehrbar")

    def test_pauschales_stagen_wird_gesperrt(self):
        for befehl in self.SPERREN:
            with self.subTest(befehl=befehl):
                r = guard(befehl)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("GESTOPPT", r.stderr)
                self.assertIn("WF-CWD-001", r.stderr)

    def test_gezieltes_stagen_und_harmlose_befehle_kommen_durch(self):
        """Die wichtigere Haelfte: ein Waechter, der alles blockt, wird abgeschaltet."""
        for befehl in self.DURCHLASSEN:
            with self.subTest(befehl=befehl):
                r = guard(befehl)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, "")

    def test_leere_und_kaputte_eingabe_blockieren_nicht(self):
        """Ein kaputter Waechter darf die Arbeit nicht anhalten."""
        for roh in ("", "kein json", "{}", '{"tool_input":{}}'):
            with self.subTest(eingabe=roh):
                r = subprocess.run([str(GUARD)], input=roh, capture_output=True,
                                   text=True, timeout=10)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_meldung_nennt_den_konkreten_ersatz(self):
        """Eine Sperre ohne Ausweg erzieht dazu, sie zu umgehen."""
        r = guard("git add -A")
        self.assertIn("git add pfad/zur/datei.ts", r.stderr)
        self.assertIn("git status --porcelain", r.stderr)

    def test_meldung_nennt_beide_auswege(self):
        """Ein Ausweg, den nur der Autor kennt, ist keiner.

        Bis 2026-08-07 gab es die Umgehung bereits — jedes Praefix `X=1`
        rutschte durch, weil vor `git` kein Trennzeichen stand — und die
        Meldung schwieg dazu. Ein Schloss, das sich aufsperren laesst, dessen
        Besitzer aber den Schluessel nicht kennt, ist das Schlechteste von
        beidem.
        """
        r = guard("git add -A")
        self.assertIn("OWNER_ADD_ALL=1", r.stderr)
        self.assertIn("WRIT_GUARD=aus", r.stderr)

    def test_session_schalter_haelt_den_waechter_an(self):
        """Ausweg 1: fuer neue oder unkritische Projekte die ganze Session."""
        for wert in ("aus", "off", "0", "nein"):
            with self.subTest(wert=wert):
                r = guard("git add -A", {"WRIT_GUARD": wert})
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, "")

    def test_unbekannter_schalterwert_laesst_den_waechter_scharf(self):
        """Ein Tippfehler in der Variablen darf die Sperre nicht aufheben."""
        for wert in ("an", "ja", "1", "vielleicht", ""):
            with self.subTest(wert=wert):
                self.assertEqual(guard("git add -A", {"WRIT_GUARD": wert}).returncode, 2)

    def test_ausdrueckliche_freigabe_fuer_einen_befehl(self):
        """Ausweg 2: steht im Befehlstext und damit im Transkript."""
        for befehl in ("OWNER_ADD_ALL=1 git add -A", "OWNER_ADD_ALL=1 git add ."):
            with self.subTest(befehl=befehl):
                self.assertEqual(guard(befehl).returncode, 0)

    def test_beliebiges_praefix_ist_KEINE_freigabe(self):
        """Die geschlossene Hintertuer.

        Vor der Korrektur kam jedes dieser Kommandos durch, weil das
        Suchmuster ein Trennzeichen vor `git` verlangte. Damit war die
        Sperre fuer jeden umgehbar, der es zufaellig ausprobierte — und fuer
        niemanden, der sie brauchte.
        """
        for befehl in ("X=1 git add -A", "FOO=bar BAZ=1 git add .",
                       "OWNER_ADD_ALL=0 git add -A", "OWNER_PUSH_OK=1 git add -A"):
            with self.subTest(befehl=befehl):
                self.assertEqual(guard(befehl).returncode, 2,
                                 "Praefix umgeht den Waechter")


class TestProzessLedger(unittest.TestCase):
    def lauf(self) -> subprocess.CompletedProcess:
        return subprocess.run([str(LEDGER)], capture_output=True, text=True,
                              timeout=15)

    def test_hook_ist_ausfuehrbar(self):
        self.assertTrue(LEDGER.exists(), LEDGER)
        import os
        self.assertTrue(os.access(LEDGER, os.X_OK), "nicht ausfuehrbar")

    def test_ledger_endet_immer_mit_null(self):
        """SessionEnd meldet, blockiert nie — der Hook sieht das Ergebnis,
        nicht die Absicht (WF-PROZESS-001)."""
        self.assertEqual(self.lauf().returncode, 0)

    def test_dauerdienste_werden_nicht_gemeldet(self):
        """`ttyd` ist ein Dienst aus INFRASTRUKTUR.md, kein Ueberbleibsel.

        Er stand im ersten Entwurf im Suchmuster, und der erste Probelauf
        meldete ihn prompt. Ein Melder, der bei JEDEM Session-Ende denselben
        legitimen Dienst zeigt, wird ueberlesen — und dann faellt der echte
        Fund nicht mehr auf.
        """
        text = LEDGER.read_text(encoding="utf-8")
        muster = next(z for z in text.splitlines() if z.startswith("MUSTER="))
        self.assertNotIn("ttyd", muster)
        self.assertNotIn("|node|", muster)

    def test_meldet_einen_passenden_prozess(self):
        """Gegenprobe zur Stille: ohne sie wuerde ein Hook, der nie etwas
        findet, als 'sauber' durchgehen."""
        import os
        import signal
        import time

        # Prozessname enthaelt 'vite' — sleep, damit nichts Echtes laeuft.
        p = subprocess.Popen(["bash", "-c", 'exec -a "vite-pruefprozess" sleep 20'])
        try:
            time.sleep(1.0)
            r = self.lauf()
            self.assertEqual(r.returncode, 0)
            self.assertIn("vite-pruefprozess", r.stderr)
            self.assertIn("WF-PROZESS-001", r.stderr)
        finally:
            try:
                os.kill(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            p.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
