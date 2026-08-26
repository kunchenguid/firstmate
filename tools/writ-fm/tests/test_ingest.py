"""M1 — Schema, Ingest, FTS5, Beziehungs-Integritaet."""

from __future__ import annotations

import unittest

from hilfe import MINI, REPO, TempDatenTest

from writ_light import ingest, paths, schema


class TestSchema(TempDatenTest):
    def test_tabellen_werden_angelegt(self):
        conn = schema.connect(paths.db_path())
        schema.create(conn)
        namen = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','index')")}
        for erwartet in ("rules", "rules_fts", "relations", "projects",
                         "meta", "idx_rel_src", "idx_rules_project"):
            self.assertIn(erwartet, namen)
        conn.close()

    def test_relations_kind_ist_eingeschraenkt(self):
        conn = schema.connect(paths.db_path())
        schema.create(conn)
        conn.execute("INSERT INTO rules (id) VALUES ('X-001')")
        with self.assertRaises(Exception):
            conn.execute("INSERT INTO relations VALUES ('X-001','X-001','ERFUNDEN')")
        conn.close()


class TestIngest(TempDatenTest):
    def test_lauf_erzeugt_db_und_index(self):
        quelle = self.schreibe_regeln(MINI)
        stat = ingest.run(source=quelle)
        self.assertEqual(stat["regeln"], 2)
        self.assertEqual(stat["mandatory"], 1)
        self.assertEqual(stat["beziehungen"], 1)
        self.assertEqual(stat["indexiert"], 2)
        self.assertTrue(paths.db_path().exists())
        self.assertTrue(paths.index_path().exists())

    def test_ingest_ist_idempotent(self):
        quelle = self.schreibe_regeln(MINI)
        erst = ingest.run(source=quelle)
        zweit = ingest.run(source=quelle)
        self.assertEqual(erst["regeln"], zweit["regeln"])
        conn = schema.connect(paths.db_path())
        self.assertEqual(conn.execute("SELECT count(*) FROM rules").fetchone()[0], 2)
        self.assertEqual(conn.execute("SELECT count(*) FROM relations").fetchone()[0], 1)
        conn.close()

    def test_fts5_findet_ueber_statement_und_tags(self):
        quelle = self.schreibe_regeln(MINI)
        ingest.run(source=quelle)
        conn = schema.connect(paths.db_path())
        treffer = conn.execute(
            "SELECT r.id FROM rules_fts f JOIN rules r ON r.rowid = f.rowid "
            "WHERE rules_fts MATCH 'testsuite'").fetchall()
        self.assertEqual([t["id"] for t in treffer], ["A-EINS-001"])
        ueber_tag = conn.execute(
            "SELECT r.id FROM rules_fts f JOIN rules r ON r.rowid = f.rowid "
            "WHERE rules_fts MATCH 'telegram'").fetchall()
        self.assertEqual([t["id"] for t in ueber_tag], ["A-ZWEI-001"])
        conn.close()

    def test_projekt_metadaten_landen_in_der_tabelle(self):
        quelle = self.schreibe_regeln(
            "project: beispiel\nrepo: ~/projects/Beispiel\n" + MINI)
        ingest.run(source=quelle)
        conn = schema.connect(paths.db_path())
        row = conn.execute("SELECT * FROM projects").fetchone()
        self.assertEqual(row["id"], "beispiel")
        self.assertTrue(row["repo_path"].endswith("/projects/Beispiel"))
        self.assertNotIn("~", row["repo_path"])
        self.assertEqual(
            conn.execute("SELECT count(*) FROM rules WHERE project='beispiel'").fetchone()[0], 2)
        conn.close()

    def test_ingest_laesst_den_memory_zaehler_stehen(self):
        """`meta` gehoert beiden Bestaenden — der Ingest darf nur seinen Teil raeumen.

        Bis 2026-08-07 loeschte `schema.reset` die ganze Tabelle. Die
        Memory-EINTRAEGE ueberlebten (die Tabelle `memory` steht nicht in der
        Loeschliste), ihr Index-Zaehler nicht. Danach meldete `doctor` nach
        jedem Ingest "-1 indiziert gegen n Eintraege" und "NICHT
        einsatzbereit", ohne dass etwas kaputt war — und konnte den echten
        Fall nicht mehr davon unterscheiden.
        """
        conn = schema.connect(paths.db_path())
        schema.create(conn)
        conn.execute("INSERT OR REPLACE INTO meta (key, value) "
                     "VALUES ('memory_index_count', '58')")
        conn.commit()
        conn.close()

        ingest.run(source=self.schreibe_regeln(MINI))

        conn = schema.connect(paths.db_path())
        try:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='memory_index_count'").fetchone()
            self.assertIsNotNone(row, "Memory-Zaehler vom Regel-Ingest mitgeloescht")
            self.assertEqual(row["value"], "58")
            # Der EIGENE Zaehler dagegen gehoert neu gesetzt, nicht konserviert.
            eigener = conn.execute(
                "SELECT value FROM meta WHERE key='index_count'").fetchone()
            self.assertIsNotNone(eigener)
        finally:
            conn.close()


class TestValidierung(TempDatenTest):
    def test_haengende_beziehung_wird_abgewiesen(self):
        quelle = self.schreibe_regeln(MINI.replace("dst: A-EINS-001", "dst: GIBTS-NICHT"))
        with self.assertRaises(ingest.IngestError) as ctx:
            ingest.run(source=quelle)
        self.assertIn("GIBTS-NICHT", str(ctx.exception))

    def test_doppelte_id_wird_abgewiesen(self):
        quelle = self.schreibe_regeln(MINI.replace("A-ZWEI-001", "A-EINS-001"))
        with self.assertRaises(ingest.IngestError) as ctx:
            ingest.run(source=quelle)
        self.assertIn("Doppelte", str(ctx.exception))

    def test_unbekannte_beziehungsart_wird_abgewiesen(self):
        quelle = self.schreibe_regeln(MINI.replace("SUPPLEMENTS", "MAG_GERNE"))
        with self.assertRaises(ingest.IngestError):
            ingest.run(source=quelle)

    def test_severity_ausserhalb_1_bis_3(self):
        quelle = self.schreibe_regeln(MINI.replace("severity: 2", "severity: 9"))
        with self.assertRaises(ingest.IngestError):
            ingest.run(source=quelle)

    def test_gefaltete_skalare_werden_getrimmt(self):
        quelle = self.schreibe_regeln(
            "rules:\n  - id: B-001\n    domain: b\n    severity: 1\n"
            "    trigger: >\n      Mehrzeiliger\n      Trigger.\n"
            "    statement: kurz\n")
        regeln, _ = ingest.collect(quelle)
        self.assertEqual(regeln[0]["trigger"], "Mehrzeiliger Trigger.")


class TestGoldDatei(unittest.TestCase):
    """Die gelieferte Datei wird unveraendert uebernommen — nur Syntax repariert."""

    # Regeln der Lieferung, die bewusst nicht mehr in der Arbeitsfassung stehen.
    # Diese Liste ist die EINZIGE erlaubte Abweichung nach unten; jede weitere
    # faellt in test_arbeitsfassung_hat_keine_regel_unbemerkt_verloren auf.
    # Wer hier etwas eintraegt, muss es auch im Kopf der Arbeitsfassung
    # begruenden — auch das prueft der Test.
    GESTRICHEN = {"WF-SESSION-001"}

    def test_gold_yaml_laedt_vollstaendig(self):
        """Welche Regeln drinstehen, prueft der Archiv-Abgleich weiter unten.

        Hier stand bis 2026-08-07 zusaetzlich `len(regeln) == 24`. Mit der
        Streichliste waere daraus `24 - len(GESTRICHEN)` geworden — die 24
        an zwei Stellen, die getrennt verrotten koennen. Die Menge deckt der
        andere Test exakt ab; hier bleibt, was er nicht sieht: dass keine ID
        doppelt vorkommt (eine Verdopplung faellt bei einem Mengenvergleich
        nicht auf).
        """
        regeln, _ = ingest.collect(REPO / "rules" / "onboarding.yaml")
        ingest.validate(regeln)
        ids = [r["id"] for r in regeln]
        self.assertEqual(sorted(ids), sorted(set(ids)), "doppelte ID")
        self.assertEqual(sum(r["mandatory"] for r in regeln), 6)

    def test_eingebetteter_fallback_enthaelt_die_gold_mandatory_regeln(self):
        """Der Fallback der Oberflaeche deckt die sechs verbindlichen Regeln der
        Gold-Datei ab. Spaeter hinzugekommene (ENF-INPUT-001) duerfen dazu
        kommen — die genaue Menge prueft test_ui."""
        import re
        regeln, _ = ingest.collect(REPO / "rules" / "onboarding.yaml")
        html = (REPO / "ui" / "regelregister.html").read_text(encoding="utf-8")
        eingebettet = set(re.findall(r'^\{id:"([^"]+)"', html, re.MULTILINE))
        gold_mandatory = {r["id"] for r in regeln if r["mandatory"]}
        self.assertTrue(gold_mandatory <= eingebettet,
                        f"fehlt im Fallback: {gold_mandatory - eingebettet}")

    def test_archiv_ist_unveraendert_und_deshalb_weiter_unparsebar(self):
        """`rules-onboarding.yaml` ist die Lieferung, nicht die Arbeitsfassung.

        Sie laesst sich bis heute nicht parsen — genau der Befund, der in der
        Arbeitsfassung repariert wurde. Dass sie noch danebenliegt, ist der
        Beleg, dass am Archiv nichts angefasst wurde.
        """
        import yaml
        text = (REPO / "rules-onboarding.yaml").read_text(encoding="utf-8")
        with self.assertRaises(yaml.YAMLError):
            yaml.safe_load(text)
        self.assertIn('correct: Ein Commit "refactor: Karten-Rendering', text)

    def test_arbeitsfassung_hat_keine_regel_unbemerkt_verloren(self):
        """Der Archiv-Abgleich bleibt scharf — nur GESTRICHEN darf fehlen.

        Bis 2026-08-07 verlangte dieser Test Gleichheit. Das war richtig,
        solange nie etwas entfiel; mit dem Wegfall von WF-SESSION-001
        (`kimi-proj` — die Laufzeit ging an dem Tag ausser Dienst) waere die
        naheliegende Reparatur gewesen, die Zahl hochzuzaehlen und die
        Mengengleichheit zu lockern. Dann faellt der naechste Verlust nicht
        mehr auf. Stattdessen: die Ausnahme muss namentlich dastehen.
        """
        import re
        archiv = re.findall(r"^  - id: (\S+)",
                            (REPO / "rules-onboarding.yaml").read_text(encoding="utf-8"),
                            re.MULTILINE)
        arbeit, _ = ingest.collect(REPO / "rules" / "onboarding.yaml")
        self.assertEqual(len(archiv), 24)
        self.assertLessEqual(self.GESTRICHEN, set(archiv),
                             "Streichliste nennt eine Regel, die es im Archiv nie gab")
        self.assertEqual(set(archiv) - self.GESTRICHEN, {r["id"] for r in arbeit})

    def test_abweichungen_vom_archiv_sind_im_kopf_begruendet(self):
        """Statt Unveraenderlichkeit: jede Abweichung steht dokumentiert im
        Dateikopf. Den Datenverlust faengt jetzt TestRundlauf ab.

        Jede Streichung muss zusaetzlich namentlich im Kopf auftauchen —
        sonst koennte man eine Regel loeschen, indem man nur die Liste in
        diesem Modul erweitert, und niemand erfuehre den Grund.
        """
        kopf = (REPO / "rules" / "onboarding.yaml").read_text(
            encoding="utf-8").split("rules:")[0]
        self.assertIn("Einfrierung ist aufgehoben", kopf)
        self.assertIn("Abweichungen von der Lieferung", kopf)
        for stichwort in ("Zeile 100", "COMM-BOT-001"):
            self.assertIn(stichwort, kopf)
        for regel in self.GESTRICHEN:
            with self.subTest(gestrichen=regel):
                self.assertIn(regel, kopf)


if __name__ == "__main__":
    unittest.main()
