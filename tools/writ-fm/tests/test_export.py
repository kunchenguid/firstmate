"""Export fuer die externe Pruefung — Inhalt, Ketten, Endpunkt."""

from __future__ import annotations

import json
import unittest

import yaml
from hilfe import REPO, TempDatenTest

from writ_light import export, ingest

VERFLOCHTEN = """
rules:
  - id: A-EINS-001
    domain: alpha
    severity: 3
    mandatory: true
    trigger: Erste Regel der Kette.
    statement: Sie steht am Anfang.
    tags: kette
  - id: A-ZWEI-001
    domain: alpha
    severity: 2
    trigger: Zweite Regel der Kette.
    statement: Sie haengt an der ersten.
    tags: kette
    relations:
      - {kind: DEPENDS_ON, dst: A-EINS-001}
  - id: B-DREI-001
    domain: beta
    severity: 2
    trigger: Dritte Regel, haengt an der zweiten.
    statement: Damit reicht die Kette ueber zwei Domains.
    tags: kette
    relations:
      - {kind: SUPPLEMENTS, dst: A-ZWEI-001}
  - id: C-ALLEIN-001
    domain: gamma
    severity: 1
    trigger: Regel ohne jede Beziehung.
    statement: Sie steht fuer sich.
    tags: einzeln
"""


class ExportTest(TempDatenTest):
    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(VERFLOCHTEN))
        self.ziel = self.tmp / "export"
        self.stat = export.schreiben(self.ziel, stand="2026-08-02")

    def lies(self, name: str) -> str:
        return (self.ziel / name).read_text(encoding="utf-8")


class TestDateien(ExportTest):
    def test_alle_dateien_entstehen(self):
        for name in ("README.md", "regeln.md", "ketten.md", "regeln.json", "regeln.yaml"):
            self.assertTrue((self.ziel / name).exists(), name)

    def test_json_ist_vollstaendig_und_gueltig(self):
        daten = json.loads(self.lies("regeln.json"))
        self.assertEqual(len(daten), 4)
        eins = next(r for r in daten if r["id"] == "A-EINS-001")
        self.assertIs(eins["mandatory"], True)
        zwei = next(r for r in daten if r["id"] == "A-ZWEI-001")
        self.assertEqual(zwei["relations"], [{"kind": "DEPENDS_ON", "dst": "A-EINS-001"}])

    def test_yaml_laesst_sich_wieder_einlesen(self):
        (self.ziel / "regeln.yaml").rename(self.tmp / "rueck" / "x.yaml") if False else None
        rueck = self.tmp / "rueck"
        rueck.mkdir()
        (rueck / "alle.yaml").write_text(self.lies("regeln.yaml"), encoding="utf-8")
        regeln, _ = ingest.collect(rueck)
        ingest.validate(regeln)
        self.assertEqual({r["id"] for r in regeln},
                         {"A-EINS-001", "A-ZWEI-001", "B-DREI-001", "C-ALLEIN-001"})

    def test_yaml_ist_syntaktisch_sauber(self):
        doc = yaml.safe_load(self.lies("regeln.yaml"))
        self.assertEqual(len(doc["rules"]), 4)

    def test_regeln_md_enthaelt_jede_regel(self):
        text = self.lies("regeln.md")
        for rid in ("A-EINS-001", "A-ZWEI-001", "B-DREI-001", "C-ALLEIN-001"):
            self.assertIn(f"`{rid}`", text)
        self.assertIn("VERBINDLICH", text)

    def test_readme_nennt_die_kennzahlen(self):
        text = self.lies("README.md")
        self.assertIn("2026-08-02", text)
        self.assertIn("`A-EINS-001`", text)  # die verbindliche Regel namentlich
        self.assertIn("Vorbehalte", text)


class TestRundlauf(TempDatenTest):
    """Export -> Ingest -> Feldvergleich, gegen das ECHTE Regelwerk.

    Der Pruefbericht vom 2026-08-02 fand hier einen echten Bug: das
    Export-YAML enthielt weder `project` noch `quelle`. Ein Rueckspielen
    haette alle Projektbindungen lautlos aufgeloest — genau die Struktur, die
    das Anti-Vermischungs-Protokoll traegt. Dieser Test macht das unmoeglich.
    """

    VERGLEICH = ("id", "domain", "severity", "mandatory", "trigger", "statement",
                 "violation", "correct", "tags", "confidence", "project", "quelle")

    def setUp(self):
        super().setUp()
        ingest.run(source=REPO / "rules")
        self.vorher = {r["id"]: r for r in export.bestand()[0]}
        self.ziel = self.tmp / "export"
        export.schreiben(self.ziel, stand="2026-08-02")

        rueck = self.tmp / "rueck"
        rueck.mkdir()
        (rueck / "alle.yaml").write_text(
            (self.ziel / "regeln.yaml").read_text(encoding="utf-8"), encoding="utf-8")
        ingest.run(source=rueck)
        self.nachher = {r["id"]: r for r in export.bestand()[0]}

    def test_kein_feld_geht_verloren(self):
        self.assertEqual(set(self.vorher), set(self.nachher))
        abweichungen = []
        for rid, alt in self.vorher.items():
            neu = self.nachher[rid]
            for feld in self.VERGLEICH:
                if alt[feld] != neu[feld]:
                    abweichungen.append(f"{rid}.{feld}: {alt[feld]!r} -> {neu[feld]!r}")
        self.assertEqual(abweichungen, [], "\n" + "\n".join(abweichungen[:20]))

    def test_projektbindungen_ueberleben(self):
        """Der eigentliche Schaden des gefundenen Bugs."""
        alt = {r for r, v in self.vorher.items() if v["project"]}
        neu = {r for r, v in self.nachher.items() if v["project"]}
        self.assertEqual(alt, neu)
        self.assertGreater(len(neu), 60, "es gibt projektgebundene Regeln")
        for rid in alt:
            self.assertEqual(self.vorher[rid]["project"], self.nachher[rid]["project"], rid)

    def test_herkunft_ueberlebt(self):
        """Ohne quelle waere eine gezielte Entfernung nach Herkunft unmoeglich —
        die schmiede-Aufloesung lief genau darueber."""
        for rid, alt in self.vorher.items():
            self.assertEqual(alt["quelle"], self.nachher[rid]["quelle"], rid)
        self.assertGreater(len({v["quelle"] for v in self.nachher.values()}), 5)

    def test_beziehungen_ueberleben(self):
        vorher_kanten = {(r["src"], r["kind"], r["dst"]) for r in export.bestand()[1]}
        self.assertTrue(vorher_kanten)
        for kante in vorher_kanten:
            self.assertIn(kante, {(r["src"], r["kind"], r["dst"]) for r in export.bestand()[1]})

    def test_verbindliche_regeln_ueberleben(self):
        alt = {r for r, v in self.vorher.items() if v["mandatory"]}
        neu = {r for r, v in self.nachher.items() if v["mandatory"]}
        self.assertEqual(alt, neu)


class TestGeheimnisPruefung(unittest.TestCase):
    def _regel(self, statement: str) -> list[dict]:
        return [{"id": "X-001", "domain": "x", "severity": 2, "mandatory": False,
                 "trigger": "t", "statement": statement, "violation": "", "correct": "",
                 "tags": "", "project": None, "quelle": "x.yaml", "relations": []}]

    def test_bot_token_wird_gefunden(self):
        verboten, _ = export.geheimnis_pruefung(
            # gitleaks:allow — erfundener Token, damit die Pruefung anschlaegt
            self._regel("Token 1234567890:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"))
        self.assertIn("Telegram-Bot-Token", verboten)

    def test_hex_schluessel_wird_gefunden(self):
        verboten, _ = export.geheimnis_pruefung(
            self._regel("key " + "a1b2c3d4" * 5))
        self.assertIn("Hex-Schluessel (32+ Zeichen)", verboten)

    def test_openai_schluessel_wird_gefunden(self):
        verboten, _ = export.geheimnis_pruefung(
            self._regel("sk-abcdefghijklmnopqrstuvwxyz012345"))
        self.assertIn("OpenAI-artiger Schluessel", verboten)

    def test_variablenname_ist_kein_verstoss(self):
        verboten, bemerkt = export.geheimnis_pruefung(
            self._regel("Nur $KIMI_API_KEY als Namen nennen, nie den Wert."))
        self.assertEqual(verboten, [])
        arten = dict(bemerkt)
        self.assertIn("KIMI_API_KEY", arten["Variablennamen (erlaubt, Werte waeren es nicht)"])

    def test_readme_warnt_bei_fund(self):
        regeln = self._regel("sk-abcdefghijklmnopqrstuvwxyz012345")
        text = export.readme_md(regeln, [], "2026-01-01")
        self.assertIn("ACHTUNG", text)
        self.assertIn("OpenAI-artiger Schluessel", text)


class TestAbgelaufeneDaten(unittest.TestCase):
    """Befund der externen Pruefung: zeitgebundene Regeln haben keinen Waechter.

    Der Waechter muss zwischen FRIST und HERKUNFTSANGABE unterscheiden — am
    echten Bestand waeren sonst 3 von 4 Funden Fehlalarm gewesen.
    """

    def _regel(self, statement: str, rid: str = "X-001") -> dict:
        return {"id": rid, "trigger": "t", "statement": statement,
                "violation": "", "correct": ""}

    def test_frist_in_der_vergangenheit_wird_gemeldet(self):
        funde = export.abgelaufene_daten(
            [self._regel("Der Vertragstermin 2026-09-02 rueckt naeher.")], "2026-09-03")
        self.assertEqual(len(funde), 1)
        self.assertEqual(funde[0][1], "2026-09-02")

    def test_frist_in_der_zukunft_wird_nicht_gemeldet(self):
        self.assertEqual(export.abgelaufene_daten(
            [self._regel("Der Vertragstermin 2026-09-02 rueckt naeher.")], "2026-08-02"), [])

    def test_herkunftsangabe_ist_keine_frist(self):
        for text in ("Dauer-Freigabe (Owner, 2026-07-27): committet selbstständig.",
                     "Budget sind 50 Credits (Owner-Freigabe 2026-08-01).",
                     "Owner-Entscheid 2026-08-02: eigene Domain.",
                     "Gemessen 2026-08-01: setMyName ist begrenzt.",
                     "Stand 2026-07-31: M0 fertig."):
            with self.subTest(text=text[:40]):
                self.assertEqual(export.abgelaufene_daten([self._regel(text)], "2027-01-01"), [])

    def test_datum_im_dateinamen_ist_keine_frist(self):
        self.assertEqual(export.abgelaufene_daten(
            [self._regel("Beleg unter shots/2026-08-02-overlay.png")], "2027-01-01"), [])

    def test_deutsches_datumsformat(self):
        funde = export.abgelaufene_daten(
            [self._regel("Testmiete laeuft bis 02.09.2026.")], "2026-10-01")
        self.assertEqual(funde[0][1], "2026-09-02")

    def test_echter_bestand_ist_heute_ohne_fehlalarm(self):
        """Kalibrierung gegen die Wirklichkeit, nicht gegen Testdaten."""
        regeln, _ = export.bestand()
        self.assertEqual(export.abgelaufene_daten(regeln, "2026-08-02"), [])

    def test_echter_bestand_meldet_den_vertragstermin_danach(self):
        regeln, _ = export.bestand()
        funde = export.abgelaufene_daten(regeln, "2026-09-03")
        self.assertEqual([f[0] for f in funde], ["TRP-VERTRAG-001"])


class TestKetten(ExportTest):
    def test_zusammenhang_ueber_domains_hinweg(self):
        regeln, rel = export.bestand()
        k = export.ketten(regeln, rel)
        self.assertEqual(len(k), 1)
        self.assertEqual(k[0], ["A-EINS-001", "A-ZWEI-001", "B-DREI-001"])

    def test_regel_ohne_beziehung_ist_keine_kette(self):
        regeln, rel = export.bestand()
        self.assertNotIn("C-ALLEIN-001", [i for kette in export.ketten(regeln, rel) for i in kette])
        self.assertIn("C-ALLEIN-001", self.lies("ketten.md"))
        self.assertIn("Ohne Beziehungen (1)", self.lies("ketten.md"))

    def test_diagramm_enthaelt_beide_kanten(self):
        text = self.lies("ketten.md")
        self.assertIn("```mermaid", text)
        self.assertIn("setzt voraus", text)
        self.assertIn("ergaenzt", text)

    def test_bindestriche_werden_fuer_mermaid_ersetzt(self):
        """Regel-IDs mit Bindestrich sind keine gueltigen Mermaid-Knoten-IDs."""
        text = self.lies("ketten.md")
        self.assertIn("A_ZWEI_001[\"A-ZWEI-001\"]", text)

    def test_statistik_stimmt(self):
        self.assertEqual(self.stat["regeln"], 4)
        self.assertEqual(self.stat["beziehungen"], 2)
        self.assertEqual(self.stat["ketten"], 1)


class TestEchtesRegelwerk(TempDatenTest):
    """Gegen den tatsaechlichen Bestand, nicht nur gegen Testdaten."""

    def setUp(self):
        super().setUp()
        ingest.run(source=REPO / "rules")
        self.ziel = self.tmp / "export"
        self.stat = export.schreiben(self.ziel, stand="2026-08-02")

    def test_jede_regel_taucht_im_lesbaren_export_auf(self):
        regeln, _ = export.bestand()
        text = (self.ziel / "regeln.md").read_text(encoding="utf-8")
        fehlend = [r["id"] for r in regeln if f"`{r['id']}`" not in text]
        self.assertEqual(fehlend, [])

    def test_jede_beziehung_taucht_in_den_ketten_auf(self):
        _, rel = export.bestand()
        text = (self.ziel / "ketten.md").read_text(encoding="utf-8")
        for r in rel:
            with self.subTest(kante=f"{r['src']}->{r['dst']}"):
                self.assertIn(r["src"].replace("-", "_") + "[", text)

    def test_echtes_regelwerk_enthaelt_keine_zugangsdaten(self):
        """Der Export verlaesst den Rechner — Variablennamen ja, Werte nein."""
        regeln, _ = export.bestand()
        verboten, _ = export.geheimnis_pruefung(regeln)
        self.assertEqual(verboten, [])

    def test_readme_weist_die_betriebsdaten_aus(self):
        text = (self.ziel / "README.md").read_text(encoding="utf-8")
        self.assertIn("keine Treffer", text)
        self.assertIn("ENF-SECRET-001", text)
        self.assertIn("`KIMI_API_KEY`", text)

    def test_leere_datenbank_wird_abgewiesen(self):
        from writ_light import paths, schema
        conn = schema.connect(paths.db_path())
        conn.execute("DELETE FROM relations")
        conn.execute("DELETE FROM rules")
        conn.commit()
        conn.close()
        with self.assertRaises(ValueError):
            export.schreiben(self.tmp / "leer")


if __name__ == "__main__":
    unittest.main()
