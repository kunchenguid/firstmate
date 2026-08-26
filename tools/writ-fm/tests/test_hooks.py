"""Hook-Ausgaben: Rahmen je Laufzeitumgebung, Fehlerpfad, Eingabe-Parsing."""

from __future__ import annotations

import json
import unittest

from hilfe import MINI, TempDatenTest

from writ_light import hooks, ingest


class RahmenTest(TempDatenTest):
    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(MINI))


class TestSessionStart(RahmenTest):
    """Bis 2026-08-07 nahm `session_start` einen Parameter `runtime`.

    Er unterschied Claude Code von Kimi Code, das an dem Tag ausser Dienst
    ging. Mit ihm sind drei Tests entfallen: der Kimi-Zweig selbst, der
    Vergleich beider Umgebungen und der Rueckfall bei unbekanntem Wert. Sie
    haetten Verhalten abgesichert, das es nicht mehr gibt — ein gruener Test
    fuer einen toten Zweig ist keine Sicherheit, sondern Gewicht.
    """

    def test_verspricht_automatisches_nachreichen(self):
        text = hooks.session_start()
        self.assertIn("automatisch die passenden weiteren", text)
        self.assertIn("settings.json", text)

    def test_nennt_keinen_weg_einer_fremden_laufzeit_mehr(self):
        """Der Block hat den Owner zu einer Datei zu schicken, die es gibt."""
        text = hooks.session_start()
        self.assertNotIn("config.toml", text)
        self.assertNotIn("kimi", text.lower())

    def test_liefert_die_verbindlichen_regeln(self):
        text = hooks.session_start()
        self.assertIn("A-ZWEI-001", text)
        self.assertIn("--- ENDE REGELN ---", text)

    def test_nur_verbindliche_regeln_im_session_start(self):
        """Ein leerer Prompt wuerde ueber die Vektorsuche Nachbarn mitziehen."""
        text = hooks.session_start()
        self.assertIn("(0 Treffer + 1 mandatory)", text)
        self.assertNotIn("A-EINS-001", text)


class TestEingabeBlock(RahmenTest):
    """E1: der Eingabe-Block liefert gerankte Regeln, nicht nochmal die verbindlichen.

    Bis 2026-08-07 standen die verbindlichen Regeln im VOLLEN Wortlaut in
    JEDEM UserPromptSubmit-Block — und zahlten dort aus demselben
    Token-Budget wie die gerankten. Gemessen: 918 von 2000 Tokens, also 46 %
    fuer sieben Regeln, die im Session-Start-Block ohnehin schon stehen
    (belege/e1-budget-messung.md). Die gerankte Abdeckung halbierte sich
    dadurch.

    Dass das Streichen sicher ist, haengt an einer Messung: `SessionStart`
    feuert nach einer Verdichtung ERNEUT (`source=compact`, belegt in
    belege/t1-sessionstart-source.md). Sonst arbeiteten alle Turns nach dem
    ersten /compact ohne verbindliche Regeln.
    """

    def test_verbindliche_regeln_stehen_nur_noch_als_id_im_block(self):
        text = hooks.prompt_regeln("darf ich committen?")
        self.assertIn("A-ZWEI-001", text, "die ID muss praesent bleiben")
        self.assertNotIn("Meldung per claw-notify absetzen", text,
                         "der Wortlaut gehoert in den Session-Start-Block")

    def test_fusszeile_nennt_den_weg_zurueck_zum_wortlaut(self):
        """Eine Abkuerzung ohne Rueckweg ist eine Sackgasse."""
        text = hooks.prompt_regeln("darf ich committen?")
        self.assertIn("writ-light session-start", text)

    def test_gerankte_regeln_bekommen_das_volle_budget(self):
        """Der Kern von E1: verbindliche Regeln sind gesetzt, nicht gerankt —
        sie konkurrieren nicht um Plaetze."""
        from writ_light import retrieve

        e = retrieve.query("darf ich committen?", budget_tokens=60)
        self.assertGreaterEqual(len(e.gerankt), 1,
                                "mandatory frisst weiterhin das Ranking-Budget")

    def test_ausgewiesene_tokenzahl_zaehlt_beide_teile(self):
        """Die Kopfzeile darf nicht behaupten, der Block sei billiger als er ist."""
        from writ_light import retrieve

        e = retrieve.query("darf ich committen?")
        einzeln = sum(retrieve._tokens(t) for t in e.mandatory + e.gerankt)
        self.assertEqual(e.tokens, einzeln)


class TestUmschlag(RahmenTest):
    def test_json_umschlag_ist_gueltig(self):
        d = json.loads(hooks.als_json(hooks.session_start(), "SessionStart"))
        self.assertEqual(d["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertIn("REGELWERK", d["hookSpecificOutput"]["additionalContext"])

    def test_notfalltext_nennt_die_diagnose(self):
        self.assertIn("writ-light doctor", hooks.NOTFALL_TEXT)
        self.assertIn("NICHT LADBAR", hooks.NOTFALL_TEXT)

    def test_aus_text_nennt_grund_und_folgen(self):
        """Das Gegenstueck zum Notfalltext — und sein Gegenteil.

        `NOTFALL_TEXT` heisst "kaputt, melden", `AUS_TEXT` heisst "gewollt,
        nicht melden". Waeren die beiden verwechselbar, ginge entweder ein
        Ausfall als Owner-Wunsch durch oder jeder gewollte regelfreie Start
        loeste eine Meldung aus — und eine Meldung, die immer kommt, liest
        nach der dritten niemand mehr.
        """
        self.assertIn("REGELWERK AUS", hooks.AUS_TEXT)
        self.assertIn("WRIT_RULES=aus", hooks.AUS_TEXT)
        self.assertIn("claude-free", hooks.AUS_TEXT)
        self.assertIn("KEIN Fehler", hooks.AUS_TEXT)
        self.assertNotIn("NICHT LADBAR", hooks.AUS_TEXT)
        self.assertNotIn("claw-notify", hooks.AUS_TEXT)

    def test_aus_text_trennt_regeln_von_mechanik(self):
        """Der Text ist das Einzige, was eine regelfreie Session ueber ihre
        Lage erfaehrt — er darf weder unter- noch uebertreiben.

        Der erste Entwurf zaehlte die "Commit- und Push-SPERREN" zu dem, was
        wegfaellt. Falsch in der gefaehrlichen Richtung: `pre-commit` und
        `pre-push` liegen unter `core.hooksPath`, kennen weder WRIT_RULES noch
        WRIT_GUARD und laufen unter `claude-free` unveraendert weiter. Weg ist
        die REGEL an das Modell, nicht die Mechanik.
        """
        weg, bleibt = hooks.AUS_TEXT.split("In Kraft bleiben")
        for regel in ("Secret-Regel", "eingeschleuste Anweisungen",
                      "Push-Regeln", "`git add`-Waechter"):
            with self.subTest(weg=regel):
                self.assertIn(regel, weg)
        for mechanik in ("pre-commit", "pre-push", "core.hooksPath"):
            with self.subTest(bleibt=mechanik):
                self.assertIn(mechanik, bleibt)
        # Die alte, falsche Formulierung darf nicht zurueckkommen.
        self.assertNotIn("Push-Sperren", hooks.AUS_TEXT)

    def test_override_nennt_beide_wege(self):
        """Ein Override, fuer den man eine Konfigurationsdatei aufmachen muss,
        wird umgangen statt benutzt — und eine Umgehung sieht niemand."""
        for stueck in ("WRIT_RULES=aus", "claude-free", "settings.json"):
            with self.subTest(stueck=stueck):
                self.assertIn(stueck, hooks.OVERRIDE)
        self.assertIn(hooks.OVERRIDE, hooks.session_start())

    def test_waechter_zeile_nur_bei_abgeschaltetem_waechter(self):
        """Sonst schweigt genau die Abschaltung, fuer die es einen Alias gibt."""
        import os

        alt = os.environ.pop("WRIT_GUARD", None)
        try:
            self.assertNotIn("claude-unsafe", hooks.session_start())
            for wert in hooks.AUS_WERTE:
                with self.subTest(wert=wert):
                    os.environ["WRIT_GUARD"] = wert
                    self.assertIn("claude-unsafe", hooks.session_start())
            os.environ["WRIT_GUARD"] = "quatsch"
            self.assertNotIn("claude-unsafe", hooks.session_start())
        finally:
            os.environ.pop("WRIT_GUARD", None)
            if alt is not None:
                os.environ["WRIT_GUARD"] = alt


class TestEingabeLesen(unittest.TestCase):
    def test_hook_json(self):
        prompt, cwd = hooks.eingabe_lesen('{"prompt":"hallo","cwd":"/tmp"}')
        self.assertEqual((prompt, cwd), ("hallo", "/tmp"))

    def test_rohtext_als_rueckfall(self):
        """Damit der Hook auch traegt, wenn eine Umgebung kein JSON schickt."""
        self.assertEqual(hooks.eingabe_lesen("einfach text"), ("einfach text", None))

    def test_leere_eingabe(self):
        self.assertEqual(hooks.eingabe_lesen("   "), ("", None))

    def test_alternative_feldnamen(self):
        prompt, cwd = hooks.eingabe_lesen(
            '{"user_prompt":"x","workingDirectory":"/y"}')
        self.assertEqual((prompt, cwd), ("x", "/y"))


if __name__ == "__main__":
    unittest.main()
