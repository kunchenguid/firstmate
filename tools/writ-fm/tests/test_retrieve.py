"""M2 — Retrieval: Pipeline, Filter, Budget und die zehn Akzeptanz-Queries."""

from __future__ import annotations

import unittest
from pathlib import Path

from hilfe import MINI, REPO, TempDatenTest

from writ_light import ingest, paths, render, retrieve, schema

# Akzeptanz 3: zehn repraesentative Queries, mindestens je zwei zu git,
# tests und kommunikation. Alle Zielregeln sind bewusst NICHT mandatory —
# eine mandatory-Regel als Ziel wuerde den Injektionspfad pruefen, nicht
# das Ranking.
AKZEPTANZ_QUERIES = [
    ("Meilenstein fertig — darf ich committen?",              "GIT-COMMIT-002",    "git"),
    ("Dritter Fix-Versuch schlägt auch fehl — was jetzt?",    "GIT-FIX-001",       "git"),
    ("Wie formuliere ich die Commit-Message hier?",            "GIT-STYLE-001",     "git"),
    ("Die Testsuite war schon vorher rot",                     "TEST-BASELINE-001", "tests"),
    ("Wie belege ich, dass die UI funktioniert?",              "TEST-ACCEPT-001",   "tests"),
    ("Braucht ein Tippfehler-Fix einen neuen Test?",           "TEST-NEW-001",      "tests"),
    ("Feature fertig — wie sage ich dem Owner Bescheid?",      "COMM-NOTIFY-001",   "kommunikation"),
    ("Nachricht mit [tg]-Präfix angekommen",                   "COMM-TG-001",       "kommunikation"),
    ("Für dieses Projekt gibt es keinen Telegram-Bot",         "COMM-BOT-001",      "kommunikation"),
    ("Der Auftrag ist nur ein Titel ohne Akzeptanzkriterien",  "WF-PROMPT-001",     "workflow"),
]

PROJEKT_YAML = """
project: testprojekt
repo: {repo}
rules:
  - id: TP-MOCK-001
    domain: testprojekt
    severity: 2
    trigger: Ein Test bildet eine externe Quelle nach.
    statement: >
      Mocks fuer Fremdquellen bilden deren echtes Antwortformat nach,
      nicht das erwartete.
    tags: mock, testdaten, fremdquelle
"""

CLAW_YAML = """
rules:
  - id: CLAW-TEST-001
    domain: claw-rolle
    severity: 2
    trigger: >
      Rolle Claw (nicht die ausführende Session): Ein Report liegt vor.
    statement: Die Claw prueft die Belege, bevor sie einen Fix glaubt.
    tags: report, belege, claw
"""


class RegelwerkTest(TempDatenTest):
    """Ingestet das echte Regelwerk in ein Wegwerf-Verzeichnis."""

    quelle = REPO / "rules"

    def setUp(self):
        super().setUp()
        ingest.run(source=self.quelle)

    def mandatory_bestand(self) -> set[str]:
        conn = schema.connect(paths.db_path())
        try:
            return {r["id"] for r in conn.execute("SELECT id FROM rules WHERE mandatory=1")}
        finally:
            conn.close()


class TestAkzeptanzQueries(RegelwerkTest):
    def test_erwartete_regel_in_den_top_5(self):
        fehler = []
        for prompt, erwartet, feld in AKZEPTANZ_QUERIES:
            ids = retrieve.query(prompt, cwd=self.tmp).gerankte_ids()
            if erwartet not in ids[:5]:
                platz = ids.index(erwartet) + 1 if erwartet in ids else "nicht gefunden"
                fehler.append(f"{feld}: {prompt!r} -> {erwartet} auf Platz {platz}")
        self.assertEqual(fehler, [], "\n" + "\n".join(fehler))

    def test_mandatory_immer_vollstaendig_enthalten(self):
        """Getrennte Zusicherung — mandatory umgeht das Ranking.

        Die erwartete Menge kommt aus der Datenbank, nicht als feste Zahl: WELCHE
        Regeln verbindlich sind, nagelt test_korpus an genau einer Stelle fest.
        """
        erwartet = self.mandatory_bestand()
        self.assertGreaterEqual(len(erwartet), 6)
        for prompt, _, _ in AKZEPTANZ_QUERIES:
            ergebnis = retrieve.query(prompt, cwd=self.tmp)
            self.assertEqual({t.regel["id"] for t in ergebnis.mandatory}, erwartet, prompt)

    def test_alle_pflichtfelder_abgedeckt(self):
        felder = [f for _, _, f in AKZEPTANZ_QUERIES]
        for pflicht in ("git", "tests", "kommunikation"):
            self.assertGreaterEqual(felder.count(pflicht), 2, pflicht)

    def test_keine_zielregel_ist_mandatory(self):
        conn = schema.connect(paths.db_path())
        for _, erwartet, _ in AKZEPTANZ_QUERIES:
            row = conn.execute("SELECT mandatory FROM rules WHERE id=?", (erwartet,)).fetchone()
            self.assertIsNotNone(row, erwartet)
            self.assertEqual(row["mandatory"], 0, erwartet)
        conn.close()


class TestZurueckliegenderIndex(TempDatenTest):
    """Der Index kann hinter der Datenbank zurueckliegen — was dann?

    `ingest` schreibt erst die Datenbank und baut danach den Index, ohne
    umspannende Transaktion. Bricht es dazwischen ab, steht eine heile
    Datenbank neben einem zu kleinen Index. Bis 2026-08-07 warf hnswlib in
    diesem Fall ("Cannot return the results in a contiguous 2D array"), und
    `hooks/prompt-regeln.sh` beendet sich bei JEDEM Fehler mit 0 — der ganze
    Regelblock fiel also lautlos aus, obwohl die BM25-Seite noch liefern
    konnte. `doctor` meldet den Verzug, aber erst, wenn jemand ihn aufruft.
    """

    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(MINI))

    def index_verkleinern(self) -> None:
        """Nur EINE Regel im Index lassen, die Datenbank unberuehrt."""
        import hnswlib

        from writ_light import embed

        conn = schema.connect(paths.db_path())
        rid, trig = conn.execute(
            "SELECT rowid, trigger FROM rules ORDER BY rowid").fetchone()
        conn.close()
        index = hnswlib.Index(space="cosine", dim=embed.DIM)
        index.init_index(max_elements=64, ef_construction=200, M=16)
        index.set_ef(64)
        index.add_items(embed.shared().encode([trig]), [rid])
        index.save_index(str(paths.index_path()))

    def test_zu_kleiner_index_kippt_die_suche_nicht(self):
        self.index_verkleinern()
        ergebnis = retrieve.query("Wie melde ich dem Owner etwas?", cwd=self.tmp)
        self.assertTrue(ergebnis.mandatory or ergebnis.gerankt,
                        "Regelblock faellt bei zurueckliegendem Index ganz aus")

    def test_leerer_index_liefert_wenigstens_die_verbindlichen(self):
        """Kein Vektor heisst nicht keine Regeln — mandatory haengt nicht daran."""
        import hnswlib

        from writ_light import embed

        index = hnswlib.Index(space="cosine", dim=embed.DIM)
        index.init_index(max_elements=64, ef_construction=200, M=16)
        index.save_index(str(paths.index_path()))
        ergebnis = retrieve.query("Wie melde ich dem Owner etwas?", cwd=self.tmp)
        self.assertTrue(ergebnis.mandatory)


class TestPipeline(RegelwerkTest):
    def test_fts_escape_baut_oder_verknuepfung(self):
        self.assertEqual(retrieve.fts_escape("Darf ich committen?"),
                         '"darf" OR "committen"')
        self.assertEqual(retrieve.fts_escape("?! ..."), "")
        self.assertEqual(retrieve.fts_escape("Regel regel REGEL"), '"regel"')

    def test_stoppwoerter_fliegen_raus(self):
        """Ohne sie besteht ein deutscher Prompt fuer BM25 groesstenteils aus Rauschen."""
        ausdruck = retrieve.fts_escape("wie sage ich dem Owner Bescheid?")
        for rauschen in ('"wie"', '"ich"', '"dem"'):
            self.assertNotIn(rauschen, ausdruck)
        self.assertIn('"owner"', ausdruck)
        self.assertIn('"bescheid"', ausdruck)

    def test_query_nur_aus_stoppwoertern_kippt_nichts(self):
        self.assertEqual(retrieve.fts_escape("und oder aber"), "")
        ergebnis = retrieve.query("und oder aber", cwd=self.tmp)
        self.assertEqual({t.regel["id"] for t in ergebnis.mandatory}, self.mandatory_bestand())

    def test_kurze_kuerzel_bleiben_erhalten(self):
        """`tg` ist der unterscheidende Term von COMM-TG-001."""
        self.assertIn('"tg"', retrieve.fts_escape("Nachricht mit [tg]-Präfix"))

    def test_kuerzel_traegt_bm25_bei(self):
        rids = retrieve.bm25_treffer(
            schema.connect(paths.db_path()), "[tg]", None, False)
        self.assertTrue(rids, "BM25 findet ueber das Kuerzel tg nichts")

    def test_leere_fts_query_kippt_die_pipeline_nicht(self):
        ergebnis = retrieve.query("?!", cwd=self.tmp)
        self.assertEqual({t.regel["id"] for t in ergebnis.mandatory}, self.mandatory_bestand())

    def test_rrf_normierung(self):
        self.assertAlmostEqual(retrieve._rrf(1), 1.0)
        self.assertEqual(retrieve._rrf(None), 0.0)
        self.assertGreater(retrieve._rrf(1), retrieve._rrf(20))

    def test_beide_signale_schlagen_ein_einzelnes(self):
        """Eine Regel in BM25 UND Vektor rankt vor einer nur aus einem Signal."""
        ergebnis = retrieve.query("Meilenstein fertig — darf ich committen?", cwd=self.tmp)
        oben = ergebnis.gerankt[0]
        self.assertIsNotNone(oben.rang_bm25)
        self.assertIsNotNone(oben.rang_vektor)

    def test_ein_hop_holt_depends_on_nachbarn(self):
        """COMM-INBOX-001 DEPENDS_ON GIT-COMMIT-001 — Nachbar wird angehaengt."""
        conn = schema.connect(paths.db_path())
        nachbarn = conn.execute(
            "SELECT dst FROM relations WHERE src='COMM-INBOX-001' AND kind='DEPENDS_ON'"
        ).fetchall()
        conn.close()
        self.assertEqual([n["dst"] for n in nachbarn], ["GIT-COMMIT-001"])
        ergebnis = retrieve.query("claw-inbox nach dem Commit", cwd=self.tmp)
        self.assertIn("GIT-COMMIT-001", ergebnis.gerankte_ids())

    def test_treffer_sind_ueberschneidungsfrei(self):
        ergebnis = retrieve.query("Commit und Tests und Meldung", cwd=self.tmp)
        ids = ergebnis.ids()
        self.assertEqual(len(ids), len(set(ids)))


KONFLIKT_YAML = """
rules:
  - id: G-REGEL-001
    domain: allgemein
    severity: 2
    trigger: Ein Projekt hat keinen Eintrag in der Zuordnungsdatei.
    statement: Dann den Eintrag anlegen lassen.
    tags: zuordnung, eintrag
  - id: X-AUSNAHME-001
    domain: allgemein
    severity: 2
    trigger: Voellig anderer Wortlaut ohne gemeinsame Begriffe zur allgemeinen Regel.
    statement: Hier gilt das Gegenteil, der Eintrag bleibt bewusst weg.
    tags: sonderfall
    relations:
      - {kind: CONFLICTS_WITH, dst: G-REGEL-001}
"""


class TestKonfliktExpansion(TempDatenTest):
    """Ein Konflikt ist symmetrisch, gespeichert wird er nur einmal.

    Findet das Ranking die allgemeine Regel, muss die aufhebende mitkommen —
    sonst haengt es vom Zufall ab, welche der beiden zuerst getroffen wird.
    Befund aus der externen Pruefung vom 2026-08-02.
    """

    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(KONFLIKT_YAML))
        self.conn = schema.connect(paths.db_path())
        self.addCleanup(self.conn.close)

    def _nachbarn(self, start: str, art: str = "CONFLICTS_WITH") -> set[str]:
        """`ein_hop` direkt befragen — sonst prueft man das Ranking mit."""
        regel = dict(self.conn.execute(
            "SELECT rowid, * FROM rules WHERE id=?", (start,)).fetchone())
        treffer = retrieve.ein_hop(
            self.conn, [retrieve.Treffer(regel=regel)], None, False, {start})
        return {t.regel["id"] for t in treffer}

    def test_rueckrichtung_eines_konflikts_wird_expandiert(self):
        """Gespeichert ist X -> G. Von G aus muss X trotzdem gefunden werden."""
        self.assertEqual(self._nachbarn("G-REGEL-001"), {"X-AUSNAHME-001"})

    def test_vorwaertsrichtung_wirkt_weiterhin(self):
        self.assertEqual(self._nachbarn("X-AUSNAHME-001"), {"G-REGEL-001"})

    def test_beide_erscheinen_gemeinsam_in_der_ausgabe(self):
        ids = retrieve.query(
            "Projekt hat keinen Eintrag in der Zuordnungsdatei",
            cwd=self.tmp).gerankte_ids()
        self.assertIn("G-REGEL-001", ids)
        self.assertIn("X-AUSNAHME-001", ids)


class TestSupplementsWirdNichtExpandiert(TempDatenTest):
    """Nur DEPENDS_ON und CONFLICTS_WITH wirken im Retrieval — SUPPLEMENTS ist
    Wissen fuer den Leser, kein Ranking-Signal."""

    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(
            KONFLIKT_YAML.replace("CONFLICTS_WITH", "SUPPLEMENTS")))
        self.conn = schema.connect(paths.db_path())
        self.addCleanup(self.conn.close)

    def test_keine_rueckrichtung(self):
        regel = dict(self.conn.execute(
            "SELECT rowid, * FROM rules WHERE id='G-REGEL-001'").fetchone())
        treffer = retrieve.ein_hop(self.conn, [retrieve.Treffer(regel=regel)],
                                   None, False, {"G-REGEL-001"})
        self.assertEqual(treffer, [])

    def test_auch_keine_vorwaertsrichtung(self):
        regel = dict(self.conn.execute(
            "SELECT rowid, * FROM rules WHERE id='X-AUSNAHME-001'").fetchone())
        treffer = retrieve.ein_hop(self.conn, [retrieve.Treffer(regel=regel)],
                                   None, False, {"X-AUSNAHME-001"})
        self.assertEqual(treffer, [])


class TestKonfliktImBestand(RegelwerkTest):
    def test_das_paar_wird_nie_getrennt_ausgeliefert(self):
        """CLID-BOT-001 hebt COMM-BOT-001 fuer cli_dashboard auf."""
        cwd = Path.home() / "projects/CLI_Dashboard"
        for frage in ("Für dieses Projekt gibt es keinen Telegram-Bot",
                      "kein Bot in bots.conf eingetragen",
                      "claw-bot-request ausführen?"):
            ids = retrieve.query(frage, cwd=cwd).gerankte_ids()
            if "COMM-BOT-001" in ids:
                with self.subTest(frage=frage):
                    self.assertIn("CLID-BOT-001", ids,
                                  "allgemeine Regel ohne die Ausnahme ausgeliefert")

    def test_ausnahme_bleibt_ausserhalb_ihres_projekts_weg(self):
        """Die Rueckrichtung darf den Projektfilter nicht aushebeln."""
        ids = retrieve.query("kein Telegram-Bot fuer dieses Projekt",
                             cwd=Path.home() / "projects/lensclash").gerankte_ids()
        self.assertNotIn("CLID-BOT-001", ids)


class TestNeueRegelnB4(RegelwerkTest):
    """Akzeptanz B4: drei Queries je neuer Regel, erwartet in den Top 5.

    Nur fuer NICHT verbindliche Regeln. Verbindliche kommen nie ueber das
    Ranking — `bm25_treffer`, `vektor_treffer` und `ein_hop` filtern alle
    drei auf `r.mandatory = 0` (retrieve.py). Fuer sie ist der Nachweis
    `ergebnis.mandatory`, siehe test_plan_regel_kommt_ueber_den_pflichtblock.
    """

    FAELLE = [
        ("WF-DEP-001", ["Soll ich dieses npm-Paket installieren?",
                        "Neue Abhängigkeit ins Projekt aufnehmen",
                        "Ist der Paketname richtig geschrieben?"]),
        ("DB-SICHERUNG-001", ["Migration mit Typänderung steht an",
                              "Darf ich die Tabelle droppen?",
                              "Massen-Update auf der Datenbank fahren"]),
        ("REPORT-REGEL-001", ["Was gehört in den Abschluss-Report?",
                              "Ich habe eine Falle gelernt — wohin damit?",
                              "Report schreiben, was darf nicht fehlen?"]),
        ("LEK-STAND-001", ["Soll ich den gemessenen Wert so in die Regel schreiben?",
                           "Messwert dokumentieren",
                           "Wie halte ich fest, wie alt eine Zahl ist?"]),
        ("WF-SUBAGENT-001", ["Wie schneide ich die Aufträge für die Umsetzer?",
                             "Zwei Agenten arbeiten parallel — wer fährt die Testsuite?",
                             "Drei Agenten sagen dasselbe, reicht das als Beweis?"]),
        ("WF-MODELL-001", ["Welches Modell gebe ich dem Subagenten?",
                           "Muss das Modell im Plan stehen?",
                           "Darf die Gegenprüfung auf einem schwächeren Modell laufen?"]),
    ]

    def test_jede_neue_regel_ist_auffindbar(self):
        fehler = []
        for rid, fragen in self.FAELLE:
            for frage in fragen:
                ids = retrieve.query(frage, cwd=self.tmp).gerankte_ids()
                platz = ids.index(rid) + 1 if rid in ids else None
                if not (platz and platz <= 5):
                    fehler.append(f"{rid}: {frage!r} -> Platz {platz}")
        self.assertEqual(fehler, [], "\n" + "\n".join(fehler))

    def test_kandidatenschnitt_hat_luft_nach_oben(self):
        """Der Kandidatenschnitt ist eine Klippe — er braucht Reserve.

        Eine Regel knapp hinter dem Schnitt verliert ihren Vektorbeitrag
        VOLLSTAENDIG und faellt auf das BM25-Gewicht (0,2) zurueck. Gemessen
        am 2026-08-07: DB-SICHERUNG-001 lag bei "Darf ich die Tabelle
        droppen?" auf gefiltertem Vektorrang 20, also auf der Kante. Fuenf
        neue, voellig unverwandte Regeln schoben sie auf 23 — und damit von
        Platz 2 auf Platz 21. Der Ausfall war lautlos.

        Geprueft wird deshalb nicht die Zahl, sondern der Abstand: bei einem
        kuenstlich knappen Pool muss der Fall wiederkehren, beim
        konfigurierten nicht. Faellt die erste Haelfte um, ist der Schnitt
        keine Klippe mehr und dieser Test darf weg. Faellt die zweite um, ist
        die Reserve aufgebraucht — dann KANDIDATEN erhoehen, nicht den Test.
        """
        frage, regel = "Darf ich die Tabelle droppen?", "DB-SICHERUNG-001"

        def platz(pool):
            alt = (retrieve.vektor_treffer.__defaults__,
                   retrieve.bm25_treffer.__defaults__)
            retrieve.vektor_treffer.__defaults__ = (pool,)
            retrieve.bm25_treffer.__defaults__ = (pool,)
            try:
                ids = retrieve.query(frage, cwd=self.tmp).gerankte_ids()
                return ids.index(regel) + 1 if regel in ids else None
            finally:
                (retrieve.vektor_treffer.__defaults__,
                 retrieve.bm25_treffer.__defaults__) = alt

        self.assertIsNone(platz(20), "Klippe weg — dieser Test ist gegenstandslos")
        p = platz(retrieve.KANDIDATEN)
        self.assertTrue(p and p <= 5,
                        f"Reserve aufgebraucht: {regel} auf Platz {p} bei "
                        f"KANDIDATEN={retrieve.KANDIDATEN}")

    # Dieselben drei Fragen, die eine Session zur Planumsetzung stellt. Als
    # FAELLE-Eintrag waeren sie NICHT erfuellbar: gemessen am 2026-08-08 lag
    # ENF-PLAN-001 bei allen dreien auf "Platz None". Nicht weil die Regel
    # schlecht formuliert waere, sondern weil sie `mandatory: true` ist und
    # das Ranking verbindliche Regeln per SQL ausschliesst. Geprueft wird
    # deshalb der Weg, den sie wirklich nimmt — und zusaetzlich, dass sie im
    # Ranking eben NICHT auftaucht: sonst wuerde ein spaeteres Entfernen von
    # `mandatory` hier stillschweigend durchgehen.
    PLAN_FRAGEN = ["Wie setze ich diesen Plan um?",
                   "Wer schreibt den Code, ich oder ein Subagent?",
                   "Darf ich den Fix als Hauptsitzung selbst schreiben?"]

    def test_plan_regel_kommt_ueber_den_pflichtblock(self):
        for frage in self.PLAN_FRAGEN:
            ergebnis = retrieve.query(frage, cwd=self.tmp)
            with self.subTest(frage=frage):
                self.assertIn("ENF-PLAN-001",
                              {t.regel["id"] for t in ergebnis.mandatory})
                self.assertIn("ENF-PLAN-001", ergebnis.ids())
                self.assertNotIn("ENF-PLAN-001", ergebnis.gerankte_ids())

    def test_prompt_injection_regel_steht_immer_im_block(self):
        for frage in ("irgendein beliebiger Prompt", "committen", "?!"):
            ergebnis = retrieve.query(frage, cwd=self.tmp)
            self.assertIn("ENF-INPUT-001",
                          {t.regel["id"] for t in ergebnis.mandatory}, frage)


class TestRetrievalRegeln(RegelwerkTest):
    """Die RET-Regeln aus der SnackSuite-Session (Owner-Entscheid 2026-08-03)."""

    FAELLE = [
        ("RET-SCHWELLE-001", ["Welche Schwelle für den Relevanzfilter?",
                              "Ab welchem Wert gilt eine Anfrage als passend?"]),
        ("RET-BAENDER-001", ["Was tun, wenn die Anfrage knapp unter der Schwelle liegt?",
                             "Absage oder generieren?"]),
        ("RET-PUFFER-001", ["Wie sichere ich die Schwelle gegen Regression?",
                            "Halteset für das Retrieval"]),
        ("RET-ZENTROID-001", ["Themenliste automatisch wachsen lassen",
                              "Dokument-Zentroide als Arbiter?"]),
        ("RET-PROMPTREGEL-001", ["Der Systemprompt verlangt Quellendeckung",
                                 "Wird die Prompt-Regel geprüft?"]),
        ("RET-KORPUS-001", ["Was gehört in den Index?",
                            "Meine Planungsdokumente tauchen als Quelle auf"]),
        ("RET-FUNDSTELLEN-001", ["Woher weiß der Nutzer, worauf das Ergebnis beruht?"]),
        ("RET-BENCHMARK-001", ["Zwei LLMs für die Aufgabe vergleichen"]),
        ("RET-HEALTH-001", ["health meldet 1287 chunks, stimmt das?"]),
        ("RET-CONFIG-001", ["Welches Modell läuft im Container wirklich?"]),
    ]

    def test_jede_retrieval_regel_ist_auffindbar(self):
        fehler = []
        for rid, fragen in self.FAELLE:
            for frage in fragen:
                ids = retrieve.query(frage, cwd=self.tmp).gerankte_ids()
                platz = ids.index(rid) + 1 if rid in ids else None
                if not (platz and platz <= 5):
                    fehler.append(f"{rid}: {frage!r} -> Platz {platz}")
        self.assertEqual(fehler, [], "\n" + "\n".join(fehler))

    def test_alle_sind_global_und_keine_verbindlich(self):
        conn = schema.connect(paths.db_path())
        try:
            for r in conn.execute("SELECT * FROM rules WHERE domain='retrieval'"):
                self.assertIsNone(r["project"], r["id"])
                self.assertEqual(r["mandatory"], 0, r["id"])
                self.assertTrue(r["id"].startswith("RET-"), r["id"])
        finally:
            conn.close()

    def test_beziehungen_zeigen_nur_auf_globale_regeln(self):
        """Eine globale Regel darf nicht auf eine projektgebundene zeigen —
        der Nachbar waere sonst nur in einem einzigen Projekt sichtbar."""
        conn = schema.connect(paths.db_path())
        try:
            haenger = conn.execute(
                "SELECT rel.src, rel.dst FROM relations rel "
                "JOIN rules s ON s.id = rel.src JOIN rules d ON d.id = rel.dst "
                "WHERE s.domain='retrieval' AND d.project IS NOT NULL").fetchall()
            self.assertEqual([(h["src"], h["dst"]) for h in haenger], [])
        finally:
            conn.close()


class TestSchreibweise(RegelwerkTest):
    """Der Bestand mischt ae/oe/ue und echte Umlaute.

    Befund der externen Pruefung vom 2026-08-02: FTS5 fand eine Regel bei der
    jeweils anderen Schreibweise in 3 von 120 Faellen. Nach der
    Vereinheitlichung in 120 von 120 (belege/umlaut-messung.txt).
    """

    def test_normalisieren_deckt_die_deutschen_sonderzeichen_ab(self):
        self.assertEqual(schema.normalisieren("Lösung Prüfung Änderung Straße"),
                         "loesung pruefung aenderung strasse")
        self.assertEqual(schema.normalisieren("ÄÖÜ"), "aeoeue")
        self.assertEqual(schema.normalisieren(None), "")

    def test_suchbegriffe_werden_vereinheitlicht(self):
        self.assertEqual(retrieve.fts_escape("Lösung"), '"loesung"')
        self.assertEqual(retrieve.fts_escape("Loesung"), '"loesung"')

    def test_stoppwoerter_greifen_in_beiden_schreibweisen(self):
        for wort in ("über", "ueber", "für", "fuer", "würde", "wuerde"):
            with self.subTest(wort=wort):
                self.assertEqual(retrieve.fts_escape(wort), "",
                                 f"{wort} haette gefiltert werden muessen")

    def test_beide_schreibweisen_finden_dieselbe_regel(self):
        """LEK-VERIFY-001 schreibt 'messbaren', TEST-ACCEPT-001 'Akzeptanz'."""
        conn = schema.connect(paths.db_path())
        try:
            for a, b in (("Beweis fuer den Fix", "Beweis für den Fix"),
                         ("Aenderung am Verhalten", "Änderung am Verhalten"),
                         ("Pruefung der Belege", "Prüfung der Belege")):
                with self.subTest(paar=(a, b)):
                    self.assertEqual(retrieve.bm25_treffer(conn, a, None, False),
                                     retrieve.bm25_treffer(conn, b, None, False))
        finally:
            conn.close()

    def test_fts_inhalt_ist_normalisiert_die_regel_selbst_nicht(self):
        conn = schema.connect(paths.db_path())
        try:
            row = conn.execute(
                "SELECT rowid FROM rules WHERE statement LIKE '%ä%' OR statement LIKE '%ü%'"
            ).fetchone()
            if row is None:
                self.skipTest("keine Regel mit echten Umlauten im Bestand")
            fts = conn.execute("SELECT statement FROM rules_fts WHERE rowid=?",
                               (row["rowid"],)).fetchone()["statement"]
            echt = conn.execute("SELECT statement FROM rules WHERE rowid=?",
                                (row["rowid"],)).fetchone()["statement"]
            self.assertNotIn("ä", fts)
            self.assertNotIn("ü", fts)
            self.assertTrue(any(u in echt for u in "äü"), "Anzeigetext bleibt unveraendert")
        finally:
            conn.close()


class TestBudget(RegelwerkTest):
    def test_mandatory_ueberleben_ein_winziges_budget(self):
        ergebnis = retrieve.query("committen", budget_tokens=10, cwd=self.tmp)
        self.assertEqual({t.regel["id"] for t in ergebnis.mandatory}, self.mandatory_bestand())
        self.assertEqual(ergebnis.gerankt, [])
        self.assertGreater(ergebnis.weggelassen, 0)

    def test_groesseres_budget_liefert_mehr_regeln(self):
        klein = retrieve.query("committen", budget_tokens=900, cwd=self.tmp)
        gross = retrieve.query("committen", budget_tokens=4000, cwd=self.tmp)
        self.assertLess(len(klein.gerankt), len(gross.gerankt))

    def test_ausgabe_weist_weggelassene_regeln_aus(self):
        ergebnis = retrieve.query("committen", budget_tokens=900, cwd=self.tmp)
        self.assertIn("Token-Budget weggelassen", render.block(ergebnis))


class TestProjektfilter(TempDatenTest):
    def setUp(self):
        super().setUp()
        self.repo = self.tmp / "repo"
        (self.repo / "unter").mkdir(parents=True)
        quelle = self.schreibe_regeln(
            PROJEKT_YAML.format(repo=self.repo), "projekt.yaml")
        (quelle / "global.yaml").write_text(
            "rules:\n  - id: G-MOCK-001\n    domain: tests\n    severity: 2\n"
            "    trigger: Ein Test bildet eine externe Quelle nach.\n"
            "    statement: Externe Quellen im Test immer mocken.\n"
            "    tags: mock, testdaten\n", encoding="utf-8")
        ingest.run(source=quelle)

    def test_projektregel_nur_im_eigenen_repo(self):
        drin = retrieve.query("Wie mocke ich eine externe Quelle?", cwd=self.repo)
        self.assertEqual(drin.projekt, "testprojekt")
        self.assertIn("TP-MOCK-001", drin.gerankte_ids())

    def test_gegenprobe_ausserhalb_des_repos(self):
        draussen = retrieve.query("Wie mocke ich eine externe Quelle?", cwd=self.tmp)
        self.assertIsNone(draussen.projekt)
        self.assertNotIn("TP-MOCK-001", draussen.gerankte_ids())
        self.assertIn("G-MOCK-001", draussen.gerankte_ids())

    def test_unterverzeichnis_zaehlt_zum_projekt(self):
        tief = retrieve.query("mocken", cwd=self.repo / "unter")
        self.assertEqual(tief.projekt, "testprojekt")

    def test_explizite_bindung_schlaegt_das_arbeitsverzeichnis(self):
        erzwungen = retrieve.query("mocken", cwd=self.tmp, projekt="testprojekt")
        self.assertIn("TP-MOCK-001", erzwungen.gerankte_ids())


class TestClawFilter(TempDatenTest):
    def setUp(self):
        super().setUp()
        quelle = self.schreibe_regeln(CLAW_YAML, "claw.yaml")
        (quelle / "normal.yaml").write_text(
            "rules:\n  - id: N-REPORT-001\n    domain: reports\n    severity: 2\n"
            "    trigger: Ein Report wird geschrieben.\n"
            "    statement: Belege pruefen, bevor ein Fix als erledigt gilt.\n"
            "    tags: report, belege\n", encoding="utf-8")
        ingest.run(source=quelle)

    def test_claw_rolle_ist_standardmaessig_ausgeblendet(self):
        ergebnis = retrieve.query("Report mit Belegen pruefen", cwd=self.tmp)
        self.assertNotIn("CLAW-TEST-001", ergebnis.gerankte_ids())
        self.assertIn("N-REPORT-001", ergebnis.gerankte_ids())

    def test_claw_rolle_auf_ausdrueckliche_anfrage(self):
        ergebnis = retrieve.query("Report mit Belegen pruefen", cwd=self.tmp, mit_claw=True)
        self.assertIn("CLAW-TEST-001", ergebnis.gerankte_ids())


class TestAusgabe(RegelwerkTest):
    def test_kopf_und_fuss_wie_spezifiziert(self):
        text = render.block(retrieve.query("committen", cwd=self.tmp))
        self.assertRegex(text, r"^--- REGELN \(\d+ Treffer \+ \d+ mandatory\) ---")
        self.assertTrue(text.rstrip().endswith("--- ENDE REGELN ---"))

    def test_mandatory_wird_markiert_und_steht_vorn(self):
        text = render.block(retrieve.query("committen", cwd=self.tmp))
        erste = text.index("[ENF-")
        self.assertIn("MANDATORY", text[erste:erste + 120])

    def test_regelblock_enthaelt_beide_beispiele(self):
        block = render.regel_block({
            "id": "X-001", "trigger": "T", "statement": "S",
            "violation": "V", "correct": "C", "mandatory": 0})
        self.assertIn("FALSCH: V", block)
        self.assertIn("RICHTIG: C", block)


if __name__ == "__main__":
    unittest.main()
