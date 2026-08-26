"""Memory: Ablage, Projektbindung, Recall, Ueberleben des Ingest."""

from __future__ import annotations

import unittest

from hilfe import MINI, TempDatenTest

from writ_light import hooks, ingest, memory, paths, schema


class MemoryTest(TempDatenTest):
    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(MINI))

    def lege_projekt_an(self, name="testprojekt"):
        conn = schema.connect(paths.db_path())
        try:
            conn.execute(
                "INSERT OR REPLACE INTO projects (id, repo_path) VALUES (?,?)",
                (name, str(self.tmp / "repo")),
            )
            conn.commit()
        finally:
            conn.close()
        (self.tmp / "repo").mkdir(exist_ok=True)
        return self.tmp / "repo"


class TestAblage(MemoryTest):
    def test_add_und_list_rundreise(self):
        mid = memory.add("Deploy laeuft per docker compose auf hetzner")
        self.assertGreaterEqual(mid, 1)
        eintraege = memory.latest()
        self.assertEqual(len(eintraege), 1)
        self.assertEqual(eintraege[0]["text"],
                         "Deploy laeuft per docker compose auf hetzner")
        self.assertTrue(eintraege[0]["created"])

    def test_leerer_text_wird_abgelehnt(self):
        with self.assertRaises(ValueError):
            memory.add("   \n  ")

    def test_index_zaehler_stimmt(self):
        memory.add("erster Eintrag")
        memory.add("zweiter Eintrag")
        conn = schema.connect(paths.db_path())
        try:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='memory_index_count'").fetchone()
            self.assertEqual(row["value"], "2")
        finally:
            conn.close()

    def test_tabelle_wird_bei_altem_bestand_nachgeruestet(self):
        """Ein Bestand aus der Zeit vor dem Memory-Feature kennt die Tabelle
        nicht — memory.connect legt sie an, ohne die Regeln anzufassen."""
        conn = schema.connect(paths.db_path())
        conn.execute("DROP TABLE IF EXISTS memory")
        conn.commit()
        n_regeln = conn.execute("SELECT count(*) FROM rules").fetchone()[0]
        conn.close()
        memory.add("Migrationstest")
        conn = schema.connect(paths.db_path())
        try:
            self.assertEqual(
                conn.execute("SELECT count(*) FROM rules").fetchone()[0], n_regeln)
            self.assertEqual(
                conn.execute("SELECT count(*) FROM memory").fetchone()[0], 1)
        finally:
            conn.close()


class TestProjektbindung(MemoryTest):
    def test_eintrag_bindet_an_projekt_aus_cwd(self):
        repo = self.lege_projekt_an()
        memory.add("projektinterner Fakt", cwd=repo)
        eintraege = memory.latest(cwd=repo)
        self.assertEqual(len(eintraege), 1)
        self.assertEqual(eintraege[0]["project"], "testprojekt")

    def test_anderes_projekt_sieht_den_eintrag_nicht(self):
        repo = self.lege_projekt_an()
        memory.add("Geheimnis von testprojekt", cwd=repo)
        anderes = self.tmp / "anderswo"
        anderes.mkdir()
        self.assertEqual(memory.latest(cwd=anderes), [])
        self.assertEqual(memory.query("Geheimnis", cwd=anderes), [])

    def test_globale_eintraege_sind_ueberall_sichtbar(self):
        repo = self.lege_projekt_an()
        memory.add("globaler Fakt ohne Projekt", cwd=self.tmp / "ohne")
        self.assertEqual(len(memory.latest(cwd=repo)), 1)


class TestRecall(MemoryTest):
    def test_semantisch_verwandtes_wird_gefunden(self):
        memory.add("Die Testsuite laeuft mit unittest, nicht mit pytest")
        treffer = memory.query("wie starte ich die Tests?")
        self.assertEqual(len(treffer), 1)
        self.assertIn("unittest", treffer[0]["text"])

    def test_themenfremdes_liefert_nichts(self):
        memory.add("Die Testsuite laeuft mit unittest, nicht mit pytest")
        self.assertEqual(memory.query("Wettervorhersage fuer morgen"), [])

    def test_recall_ohne_index_ist_leer_statt_fehler(self):
        treffer = memory.query("irgendwas")
        self.assertEqual(treffer, [])


class TestIngestUeberleben(MemoryTest):
    def test_ingest_loescht_das_memory_nicht(self):
        memory.add("muss den Ingest ueberleben")
        ingest.run(source=self.schreibe_regeln(MINI))
        eintraege = memory.latest()
        self.assertEqual(len(eintraege), 1)
        # und der Recall danach noch funktioniert
        self.assertEqual(len(memory.query("ueberleben")), 1)

    def test_ingest_laesst_auch_den_index_zaehler_stehen(self):
        """Der Eintrag ueberlebte den Ingest schon immer, sein Zaehler nicht.

        Bis 2026-08-07 loeschte `schema.reset` die ganze meta-Tabelle. Das
        ergab keinen Datenverlust, aber einen dauerhaft roten `doctor` — und
        damit einen Befund, der nichts mehr unterscheiden konnte.
        """
        memory.add("mit Zaehler")
        ingest.run(source=self.schreibe_regeln(MINI))
        conn = schema.connect(paths.db_path())
        try:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='memory_index_count'").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row, "Zaehler vom Regel-Ingest mitgeloescht")
        self.assertEqual(row["value"], "1")


class TestReindex(MemoryTest):
    """`memory reindex` ist das Gegenmittel zum doctor-Befund.

    Ohne es liess sich ein gemeldeter Index-Verzug nur durch einen neuen
    Eintrag "heilen" — der den bestehenden Index nicht anfasst und den
    Zaehler nur zufaellig wieder passend macht. Ein Befund ohne
    Reparaturweg erzieht dazu, ihn zu ueberlesen.
    """

    def test_reindex_stellt_den_zaehler_wieder_her(self):
        memory.add("erster Eintrag")
        memory.add("zweiter Eintrag")
        conn = schema.connect(paths.db_path())
        conn.execute("DELETE FROM meta WHERE key='memory_index_count'")
        conn.commit()
        conn.close()

        stat = memory.reindex()

        self.assertEqual(stat["eintraege"], 2)
        conn = schema.connect(paths.db_path())
        try:
            row = conn.execute(
                "SELECT value FROM meta WHERE key='memory_index_count'").fetchone()
        finally:
            conn.close()
        self.assertEqual(row["value"], "2")

    def test_recall_funktioniert_nach_dem_neubau(self):
        """Ein Neubau, der den Index leert, waere schlimmer als der Befund."""
        memory.add("Owner testet nachts und zwischendurch")
        memory.add("Suite dauert acht Minuten")
        memory.reindex()
        treffer = memory.query("Wann testet der Owner?")
        self.assertTrue(treffer)
        self.assertIn("nachts", treffer[0]["text"])

    def test_reindex_repariert_einen_index_der_eintraege_verloren_hat(self):
        """Der eigentliche Anlass: Index kleiner als die Tabelle.

        Geprueft wird der INHALT, nicht die Trefferzahl. Vor dem Neubau
        liefert die Suche naemlich sehr wohl etwas — nur eben den falschen
        Eintrag, weil der einzig indizierte noch unter der Distanzschwelle
        liegt. Genau diese Form des Ausfalls ist die gefaehrliche: sie sieht
        aus wie ein Ergebnis.
        """
        memory.add("bleibt im Index")
        conn = schema.connect(paths.db_path())
        conn.execute("INSERT INTO memory (project, text, created) "
                     "VALUES (NULL, 'nachtraeglich eingefuegt', '2026-08-07')")
        conn.commit()
        conn.close()
        vorher = memory.query("nachtraeglich eingefuegt")
        self.assertFalse(any("nachtraeglich" in t["text"] for t in vorher),
                         "unindizierter Eintrag darf nicht auffindbar sein")

        memory.reindex()

        treffer = memory.query("nachtraeglich eingefuegt")
        self.assertTrue(any("nachtraeglich" in t["text"] for t in treffer))

    def test_reindex_auf_leerem_memory_bleibt_ruhig(self):
        stat = memory.reindex()
        self.assertEqual(stat["eintraege"], 0)
        self.assertEqual(memory.query("irgendwas"), [])


class TestHookEinbindung(MemoryTest):
    def test_session_start_zeigt_juengste_eintraege(self):
        memory.add("Owner will Reports auf Deutsch")
        text = hooks.session_start()
        self.assertIn("--- MEMORY", text)
        self.assertIn("Owner will Reports auf Deutsch", text)

    def test_session_start_ohne_eintraege_ohne_memory_block(self):
        text = hooks.session_start()
        self.assertNotIn("--- MEMORY", text)

    def test_prompt_regeln_haengt_passende_eintraege_an(self):
        memory.add("Datenbank-Backup vor jeder Migration")
        text = hooks.prompt_regeln("steht eine Migration an?")
        self.assertIn("--- MEMORY ---", text)
        self.assertIn("Datenbank-Backup", text)


class TestKimiPayload(unittest.TestCase):
    def test_prompt_als_content_parts(self):
        """Kimi Code schickt prompt als Liste von Parts (gemessen 2026-08-05)."""
        roh = ('{"hook_event_name":"UserPromptSubmit","cwd":"/tmp",'
               '"prompt":[{"type":"text","text":"hallo kimi"}]}')
        self.assertEqual(hooks.eingabe_lesen(roh), ("hallo kimi", "/tmp"))

    def test_mehrere_text_parts_werden_verkettet(self):
        roh = ('{"prompt":[{"type":"text","text":"teil eins"},'
               '{"type":"image","data":"..."},'
               '{"type":"text","text":"teil zwei"}]}')
        prompt, _ = hooks.eingabe_lesen(roh)
        self.assertEqual(prompt, "teil eins\nteil zwei")

    def test_claude_string_format_bleibt(self):
        prompt, cwd = hooks.eingabe_lesen('{"prompt":"hallo","cwd":"/tmp"}')
        self.assertEqual((prompt, cwd), ("hallo", "/tmp"))


if __name__ == "__main__":
    unittest.main()
