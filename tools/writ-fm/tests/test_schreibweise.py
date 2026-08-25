"""B6 — Schreibweisen-Aufraeumen: ae/oe/ue zu Umlauten in den Anzeigetexten."""

from __future__ import annotations

import re
import unittest

from hilfe import REPO

from writ_light import ingest, schema, schreibweise


class TestWortliste(unittest.TestCase):
    def test_ausnahmen_und_ersetzungen_ueberschneiden_sich_nicht(self):
        self.assertEqual(set(schreibweise.ERSETZUNGEN) & schreibweise.AUSNAHMEN, set())

    def test_ersetzungen_aendern_wirklich_etwas(self):
        for alt, neu in schreibweise.ERSETZUNGEN.items():
            self.assertNotEqual(alt, neu, alt)

    def test_falsche_freunde_bleiben_stehen(self):
        """Eine Zeichenregel wuerde diese Woerter zerlegen."""
        for wort in ("bauen", "Quelle", "Sequenz", "neue", "Steuerung",
                     "vertrauen", "aktuell", "zuerst", "teuerste", "Maestro"):
            with self.subTest(wort=wort):
                self.assertEqual(schreibweise.umschreiben(wort), wort)

    def test_nur_das_gemeinte_vorkommen_wird_ersetzt(self):
        """'primaerquelle' -> 'primärquelle', nicht 'primärqülle'."""
        self.assertEqual(schreibweise.umschreiben("Primaerquelle"), "Primärquelle")

    def test_scharfes_s_wo_noetig(self):
        self.assertEqual(schreibweise.umschreiben("groesserer"), "größerer")
        self.assertEqual(schreibweise.umschreiben("ausschliesslich"), "ausschließlich")
        self.assertEqual(schreibweise.umschreiben("mittelmaessig"), "mittelmäßig")

    def test_korrektes_ss_bleibt(self):
        for wort in ("Session", "Prozess", "Klasse", "muss", "lassen",
                     "gemessen", "Adresse", "Dossier"):
            with self.subTest(wort=wort):
                self.assertEqual(schreibweise.umschreiben(wort), wort)

    def test_grossschreibung_bleibt_erhalten(self):
        self.assertEqual(schreibweise.umschreiben("Aenderung"), "Änderung")
        self.assertEqual(schreibweise.umschreiben("aenderung"), "änderung")

    def test_versalien_bleiben_unberuehrt(self):
        """ENV-Namen und Auszeichnungen wie VERSTOSS-VERBOT."""
        self.assertEqual(schreibweise.umschreiben("VERSTOSS"), "VERSTOSS")
        self.assertEqual(schreibweise.umschreiben("TG_POOL_10"), "TG_POOL_10")

    def test_code_in_backticks_bleibt_unberuehrt(self):
        text = "Die Datei `docs/ueberblick.md` gibt einen Ueberblick."
        self.assertEqual(schreibweise.umschreiben(text),
                         "Die Datei `docs/ueberblick.md` gibt einen Überblick.")

    def test_umschreiben_ist_idempotent(self):
        text = "Aenderungen muessen ausdruecklich geprueft werden."
        einmal = schreibweise.umschreiben(text)
        self.assertEqual(schreibweise.umschreiben(einmal), einmal)


class TestBestand(unittest.TestCase):
    def setUp(self):
        self.dateien = sorted((REPO / "rules").rglob("*.yaml"))
        self.texte = {p: p.read_text(encoding="utf-8") for p in self.dateien}

    def test_alle_regeldateien_sind_aufgeraeumt(self):
        offen = [p.name for p, t in self.texte.items()
                 if schreibweise.umschreiben(t) != t]
        self.assertEqual(offen, [], f"noch nicht umgeschrieben: {offen}")

    def test_keine_unentschiedenen_kandidaten_mehr(self):
        offen = set()
        for t in self.texte.values():
            offen |= schreibweise.offene_kandidaten(t)
        self.assertEqual(offen, set(), f"weder ersetzt noch Ausnahme: {sorted(offen)}")

    def test_gold_datei_wurde_vom_aufraeumen_nicht_beruehrt(self):
        """Ihre ae/oe/ue-Woerter sind alle falsche Freunde (aufbauen, dauer,
        known_issues, maestro, neue, neues, zuerst) — B6 musste sie nicht
        anfassen. Spaetere Aenderungen (B3) sind davon unberuehrt."""
        gold = (REPO / "rules" / "onboarding.yaml").read_text(encoding="utf-8")
        self.assertEqual(schreibweise.umschreiben(gold), gold)
        self.assertEqual(schreibweise.offene_kandidaten(gold), set())

    def test_bestand_bleibt_ingestierbar(self):
        regeln, _ = ingest.collect(REPO / "rules")
        ingest.validate(regeln)
        self.assertGreater(len(regeln), 140)


class TestRetrievalUnberuehrt(unittest.TestCase):
    """Die Normalisierung aus P3 macht die Umstellung ueberhaupt erst gefahrlos."""

    def test_beide_schreibweisen_normalisieren_gleich(self):
        for a, b in (("Loesung", "Lösung"), ("pruefen", "prüfen"),
                     ("groesser", "größer"), ("ausschliesslich", "ausschließlich")):
            with self.subTest(paar=(a, b)):
                self.assertEqual(schema.normalisieren(a), schema.normalisieren(b))

    def test_umgeschriebener_text_bleibt_suchbar(self):
        alt = "Aenderungen muessen geprueft werden"
        neu = schreibweise.umschreiben(alt)
        self.assertNotEqual(alt, neu)
        self.assertEqual(schema.normalisieren(alt), schema.normalisieren(neu))


if __name__ == "__main__":
    unittest.main()
