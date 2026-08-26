"""Regel-Schema v2 — Anker, Deckel, Verfall, Streichung, Brief, Hinweise.

Diese Tests laufen OHNE hnswlib, ONNX und Modell: sie pruefen das Regelwerk,
nicht die Vektorsuche (`ingest.run(mit_index=False)`). Das ist Absicht — die
Pruefungen, die einen Bestand vor kaputten Regeln schuetzen, muessen auf einem
frisch aufgesetzten Rechner laufen, sonst laufen sie genau dann nicht, wenn man
sie braucht.

Jeder Test baut sich eine vollstaendige Flotte im Temp-Verzeichnis: eigenes
Ledger, eigene AGENTS.md, eigene VERFASSUNG.yaml. Gegen den echten Bestand zu
pruefen hiesse, an manchen Tagen etwas anderes zu pruefen als heute.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from writ_light import (brief, cli, fmpfade, ingest, retrieve, schema, streich,
                        verfassung)

LEDGER = """\
# Lehren-Ledger (Fixture)

### L01 Gelandet gilt als wirksam
Text.

### L03 Blindes Gruen
Text.
"""

AGENTS = """\
# Flottenordnung (Fixture)
1. **HR1 (untouchable): ...**
2. **HR4 (untouchable): ...**
"""

VERFASSUNG = """\
kern_max: 2
kern_token_max: 400
kontext_max_je_geltung: 3
kontext_max_gesamt: 5
topk: 2
brief_token_max: 120
nogo_zeilen_max_je_brief: 5
"""


def regel(rid: str, **felder) -> str:
    """Eine Regel im Schema v2 — Vorgaben ueberschreibbar."""
    werte = {
        "domain": "alpha",
        "severity": "2",
        "geltung": "flotte",
        "verbindlichkeit": "kontext",
        "leser": "retrieval",
        "anker": "[L01]",
        "status": "aktiv",
        "trigger": f"Ausloeser fuer {rid}.",
        "statement": f"Aussage von {rid}.",
    }
    werte.update({k: v for k, v in felder.items() if v is not None})
    zeilen = [f"  - id: {rid}"]
    zeilen += [f"    {k}: {v}" for k, v in werte.items()]
    return "\n".join(zeilen)


def v1_regel(rid: str, **felder) -> str:
    """Eine Regel im ALTEN Schema — kein einziges Feld aus schema.V2_MARKER."""
    werte = {
        "domain": "alpha",
        "severity": "2",
        "trigger": f"Ausloeser fuer {rid}.",
        "statement": f"Aussage von {rid}.",
        "tags": "alt, bestand",
    }
    werte.update({k: v for k, v in felder.items() if v is not None})
    return "\n".join([f"  - id: {rid}"] + [f"    {k}: {v}" for k, v in werte.items()])


def datei(*bloecke: str, kopf: str = "") -> str:
    return kopf + "rules:\n\n" + "\n\n".join(bloecke) + "\n"


class FlotteTest(unittest.TestCase):
    """Vollstaendige Flotte im Temp-Verzeichnis, inklusive Werkzeug-Datenpfad."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        (self.tmp / "regeln").mkdir()
        (self.tmp / "data").mkdir()
        (self.tmp / "tests").mkdir()
        (self.tmp / "data" / "lehren-ledger.md").write_text(LEDGER, encoding="utf-8")
        (self.tmp / "AGENTS.md").write_text(AGENTS, encoding="utf-8")
        self.verfassung(VERFASSUNG)

        self._alt = {}
        for schluessel, wert in (
            # FM_HOME ist der Schalter, mit dem der Firstmate seinem Werkzeug
            # sein Heim zeigt: `paths.py` legt die Laufzeitdaten dorthin,
            # `fmpfade.py` liest von dort Regeln, Verfassung und Ledger.
            ("FM_HOME", str(self.tmp)),
            ("WRIT_LEDGER_PATH", str(self.tmp / "data" / "lehren-ledger.md")),
            ("WRIT_AGENTS_PATH", str(self.tmp / "AGENTS.md")),
            ("WRIT_DATA_DIR", str(self.tmp / "laufzeit")),
            # Ohne feste Projektbindung liest `aktives_projekt` das cwd des
            # Testlaufs — und damit je nach Startverzeichnis etwas anderes.
            ("WRIT_PROJECT", ""),
        ):
            self._alt[schluessel] = os.environ.get(schluessel)
            if wert:
                os.environ[schluessel] = wert
            else:
                os.environ.pop(schluessel, None)

    def tearDown(self) -> None:
        for schluessel, wert in self._alt.items():
            if wert is None:
                os.environ.pop(schluessel, None)
            else:
                os.environ[schluessel] = wert
        self._tmp.cleanup()

    # ── Hilfen ────────────────────────────────────────────────────────────
    def verfassung(self, text: str | None) -> None:
        pfad = self.tmp / "regeln" / "VERFASSUNG.yaml"
        if text is None:
            pfad.unlink(missing_ok=True)
        else:
            pfad.write_text(text, encoding="utf-8")

    def regeln(self, inhalt: str, name: str = "werk.yaml") -> Path:
        pfad = self.tmp / "regeln" / name
        pfad.write_text(inhalt, encoding="utf-8")
        return pfad

    def ingest(self, heute: str | None = None) -> dict:
        return ingest.run(source=fmpfade.regeln_dir(), mit_index=False, heute=heute)

    def db(self):
        return schema.connect(self.tmp / "laufzeit" / "rules.db")


class TestAnker(FlotteTest):
    def test_gruen_anker_steht_im_ledger(self):
        self.regeln(datei(regel("A-001", anker="[L01, L03]")))
        self.assertEqual(self.ingest()["regeln"], 1)

    def test_rot_anker_fehlt_im_ledger(self):
        self.regeln(datei(regel("A-001", anker="[L99]")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("L99", str(ctx.exception))
        self.assertIn("A-001", str(ctx.exception), "Meldung nennt die Regel-ID nicht")
        self.assertIn("werk.yaml", str(ctx.exception), "Meldung nennt die Datei nicht")

    def test_gruen_hardening_anker_steht_in_agents(self):
        self.regeln(datei(regel("A-001", anker="[HR1]")))
        self.assertEqual(self.ingest()["regeln"], 1)

    def test_rot_hardening_anker_fehlt_in_agents(self):
        self.regeln(datei(regel("A-001", anker="[HR9]")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("HR9", str(ctx.exception))

    def test_rot_weder_anker_noch_quelle(self):
        self.regeln(datei(regel("A-001", anker="[]")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("quelle", str(ctx.exception))

    def test_gruen_leerer_anker_mit_quelle(self):
        self.regeln(datei(regel("A-001", anker="[]", quelle="order:O-0018")))
        self.assertEqual(self.ingest()["regeln"], 1)

    def test_rot_quelle_ohne_bekanntes_muster(self):
        self.regeln(datei(regel("A-001", anker="[]", quelle="regeln/werk.yaml")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("grundsatz:", str(ctx.exception))

    def test_ledger_pfad_ist_konfigurierbar(self):
        anderes = self.tmp / "anderes-ledger.md"
        anderes.write_text("### L42 Anderswo\n", encoding="utf-8")
        os.environ["WRIT_LEDGER_PATH"] = str(anderes)
        self.regeln(datei(regel("A-001", anker="[L42]")))
        self.assertEqual(self.ingest()["regeln"], 1)


class TestDeckel(FlotteTest):
    def kern(self, rid: str, **felder) -> str:
        felder.setdefault("verbindlichkeit", "kern")
        felder.setdefault("leser", "tor:bin/fm-abnahme.sh")
        return regel(rid, **felder)

    def test_kern_deckel_bricht_ab_und_nennt_den_ausweg(self):
        self.regeln(datei(*(self.kern(f"K-{i:03d}") for i in range(3))))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        meldung = str(ctx.exception)
        self.assertIn("Kern-Deckel", meldung)
        self.assertIn("fm-regeln streich", meldung, "Sperrmeldung nennt den Ausweg nicht")
        self.assertIn("Herabstufung ist Pflicht", meldung)

    def test_kern_deckel_haelt_genau_am_limit(self):
        self.regeln(datei(*(self.kern(f"K-{i:03d}") for i in range(2))))
        self.assertEqual(self.ingest()["kern"], 2)

    def test_kontext_deckel_gesamt(self):
        self.regeln(datei(*(regel(f"C-{i:03d}", geltung="worker" if i % 2 else "flotte")
                            for i in range(6))))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("Kontext-Deckel", str(ctx.exception))

    def test_kontext_deckel_je_geltung(self):
        self.regeln(datei(*(regel(f"C-{i:03d}", geltung="worker") for i in range(4))))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("geltung=worker", str(ctx.exception))

    def test_kern_verlangt_benannten_leser(self):
        self.regeln(datei(regel("K-001", verbindlichkeit="kern", leser="retrieval")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("benannten Leser", str(ctx.exception))

    def test_zwei_kernregeln_im_konflikt_brechen_ab(self):
        block = self.kern("K-001") + (
            "\n    relations:\n      - {kind: CONFLICTS_WITH, dst: K-002}")
        self.regeln(datei(block, self.kern("K-002")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("CONFLICTS_WITH", str(ctx.exception))

    def test_konflikt_zwischen_kontextregeln_ist_erlaubt(self):
        block = regel("C-001") + (
            "\n    relations:\n      - {kind: CONFLICTS_WITH, dst: C-002}")
        self.regeln(datei(block, regel("C-002")))
        self.assertEqual(self.ingest()["kontext"], 2)

    def test_fehlende_verfassung_warnt_und_nutzt_standard(self):
        self.verfassung(None)
        werte, warnungen = verfassung.laden()
        self.assertEqual(werte, verfassung.STANDARD)
        self.assertTrue(warnungen and "WARNUNG" in warnungen[0])

    def test_kaputte_verfassung_bricht_ab_statt_standard_zu_nehmen(self):
        self.verfassung("kern_max: null\n")
        with self.assertRaises(verfassung.VerfassungsFehler):
            verfassung.laden()


class TestVerfall(FlotteTest):
    def test_abgelaufene_regel_wird_abgestuft_ohne_abbruch(self):
        self.regeln(datei(regel("A-001", verfall="2020-01-01"), regel("A-002")))
        stat = self.ingest(heute="2026-08-25")
        self.assertEqual(stat["abgelaufen"], 1)
        self.assertTrue(any("A-001" in w and "abgelaufen" in w for w in stat["warnungen"]))
        conn = self.db()
        try:
            self.assertEqual(
                conn.execute("SELECT status FROM rules WHERE id='A-001'").fetchone()[0],
                "abgelaufen")
        finally:
            conn.close()

    def test_abgelaufene_regel_wird_nicht_mehr_zugestellt(self):
        self.regeln(datei(regel("A-001", verfall="2020-01-01"), regel("A-002")))
        self.ingest(heute="2026-08-25")
        ergebnis = retrieve.query("Aussage", db=self.tmp / "laufzeit" / "rules.db",
                                  geltung="flotte")
        self.assertNotIn("A-001", ergebnis.ids())

    def test_abgelaufene_kernregel_zaehlt_nicht_gegen_den_deckel(self):
        """Sonst blockiert eine gegenstandslose Regel ihre eigene Nachfolgerin."""
        kern = dict(verbindlichkeit="kern", leser="tor:bin/fm-abnahme.sh")
        self.regeln(datei(regel("K-001", **kern), regel("K-002", **kern),
                          regel("K-003", verfall="2020-01-01", **kern)))
        stat = self.ingest(heute="2026-08-25")
        self.assertEqual(stat["kern"], 2)

    def test_verfall_in_der_zukunft_bleibt_aktiv(self):
        self.regeln(datei(regel("A-001", verfall="2099-01-01")))
        stat = self.ingest(heute="2026-08-25")
        self.assertEqual(stat["abgelaufen"], 0)
        self.assertEqual(stat["warnungen"], [])


class TestStreich(FlotteTest):
    def setUp(self) -> None:
        super().setUp()
        self.regeln(datei(regel("A-001", statement="Erst messen, dann melden."),
                          regel("A-002")))
        self.ingest()
        self.gold = self.tmp / "tests" / "regel-retrieval-golden.tsv"
        self.gold.write_text("frage eins\tA-001\nfrage zwei\tA-002\n", encoding="utf-8")

    def streiche(self, **kwargs):
        kwargs.setdefault("grund", "durch ein Tor ersetzt")
        return streich.streiche(db=self.tmp / "laufzeit" / "rules.db",
                                mit_index=False, **kwargs)

    def test_abstufung_traegt_alle_vier_schritte(self):
        stat = self.streiche(regel_id="A-001")
        self.assertEqual(stat["nach"], "hinweis")

        conn = self.db()
        try:
            zeile = conn.execute(
                "SELECT verbindlichkeit, status FROM rules WHERE id='A-001'").fetchone()
        finally:
            conn.close()
        self.assertEqual((zeile[0], zeile[1]), ("hinweis", "hinweis-abgestuft"))

        register = fmpfade.abgeschafft_datei().read_text(encoding="utf-8")
        self.assertIn("A-001", register)
        self.assertIn("Erst messen, dann melden.", register)
        self.assertIn("Anker: L01", register)
        self.assertIn("Grund: durch ein Tor ersetzt", register)

        self.assertEqual(self.gold.read_text(encoding="utf-8"), "frage zwei\tA-002\n")

    def test_loeschen_entfernt_die_regel_aus_dem_yaml(self):
        self.streiche(regel_id="A-001", nach="geloescht")
        text = (self.tmp / "regeln" / "werk.yaml").read_text(encoding="utf-8")
        self.assertNotIn("A-001", text)
        self.assertIn("A-002", text)

    def test_fehlender_grund_wird_abgewiesen(self):
        with self.assertRaises(streich.StreichFehler):
            streich.streiche("A-001", grund="  ")

    def test_unbekannte_id_aendert_nichts(self):
        vorher = (self.tmp / "regeln" / "werk.yaml").read_text(encoding="utf-8")
        with self.assertRaises(streich.StreichFehler):
            self.streiche(regel_id="GIBTS-NICHT")
        self.assertEqual((self.tmp / "regeln" / "werk.yaml").read_text(encoding="utf-8"),
                         vorher)
        self.assertFalse(fmpfade.abgeschafft_datei().exists())

    def test_fehlschlag_des_ingests_rollt_alles_zurueck(self):
        """A-002 haengt an A-001 — `--nach geloescht` muss komplett zurueckrollen."""
        self.regeln(datei(
            regel("A-001", statement="Erst messen, dann melden."),
            regel("A-002") + "\n    relations:\n      - {kind: DEPENDS_ON, dst: A-001}"))
        self.ingest()
        vorher_yaml = (self.tmp / "regeln" / "werk.yaml").read_text(encoding="utf-8")
        vorher_gold = self.gold.read_text(encoding="utf-8")

        with self.assertRaises(streich.StreichFehler) as ctx:
            self.streiche(regel_id="A-001", nach="geloescht")
        self.assertIn("zurueckgenommen", str(ctx.exception))

        self.assertEqual((self.tmp / "regeln" / "werk.yaml").read_text(encoding="utf-8"),
                         vorher_yaml)
        self.assertEqual(self.gold.read_text(encoding="utf-8"), vorher_gold)
        self.assertFalse(fmpfade.abgeschafft_datei().exists(),
                         "Register-Eintrag ueberlebt einen gescheiterten Ingest")
        conn = self.db()
        try:
            self.assertEqual(
                conn.execute("SELECT count(*) FROM rules WHERE id='A-001'").fetchone()[0], 1)
        finally:
            conn.close()

    def test_register_ist_append_only(self):
        self.streiche(regel_id="A-001")
        self.streiche(regel_id="A-002")
        zeilen = [z for z in fmpfade.abgeschafft_datei().read_text(
            encoding="utf-8").splitlines() if z.startswith("- ")]
        self.assertEqual(len(zeilen), 2)


class TestZustellung(FlotteTest):
    def setUp(self) -> None:
        super().setUp()
        self.dbpfad = self.tmp / "laufzeit" / "rules.db"

    def test_hinweis_erscheint_in_keiner_zustellung(self):
        self.regeln(datei(
            regel("H-001", verbindlichkeit="hinweis", status="hinweis-abgestuft",
                  statement="Abgestufte Aussage ueber Meldungen."),
            regel("C-001", statement="Gerankte Aussage ueber Meldungen.")))
        self.ingest()
        offen = retrieve.query("Meldungen", db=self.dbpfad, geltung="flotte")
        self.assertNotIn("H-001", offen.ids())
        self.assertIn("C-001", offen.ids())

        auch = retrieve.query("Meldungen", db=self.dbpfad, geltung="flotte",
                              auch_hinweise=True)
        self.assertIn("H-001", auch.ids())

    def test_session_start_liefert_nur_kern_der_eigenen_geltung(self):
        kern = dict(verbindlichkeit="kern", leser="tor:bin/fm-abnahme.sh")
        self.regeln(datei(
            regel("K-FLOTTE", geltung="flotte", **kern),
            regel("K-WORKER", geltung="worker", **kern),
            regel("C-001")))
        self.ingest()
        worker = retrieve.nur_kern(db=self.dbpfad, geltung="worker")
        self.assertEqual(sorted(worker.ids()), ["K-FLOTTE", "K-WORKER"])
        erste = retrieve.nur_kern(db=self.dbpfad, geltung="firstmate")
        self.assertEqual(erste.ids(), ["K-FLOTTE"])

    def test_unbekannte_geltung_bricht_laut_ab(self):
        self.regeln(datei(regel("C-001")))
        self.ingest()
        with self.assertRaises(retrieve.ZustellFehler):
            retrieve.nur_kern(db=self.dbpfad, geltung="workr")

    def test_topk_kommt_aus_der_verfassung(self):
        self.regeln(datei(*(regel(f"C-{i:03d}", statement="Meldung an den Kapitaen.")
                            for i in range(3))))
        self.ingest()
        ergebnis = retrieve.query("Meldung", db=self.dbpfad, geltung="flotte")
        self.assertLessEqual(len(ergebnis.gerankt), 2, "topk=2 aus VERFASSUNG.yaml")


class TestBrief(FlotteTest):
    def test_brief_kappt_von_unten_und_nennt_die_gekappten(self):
        # Deckel so, dass Kern plus EINE Kontextregel hineinpassen: sonst
        # pruefte der Test nur, dass nichts zu kappen war.
        self.verfassung(VERFASSUNG.replace("brief_token_max: 120", "brief_token_max: 55"))
        self.regeln(datei(
            regel("K-001", verbindlichkeit="kern", leser="tor:bin/fm-abnahme.sh",
                  statement="Kernaussage zur Meldung an den Kapitaen."),
            *(regel(f"C-{i:03d}",
                    statement=f"'Kontextaussage {i} zur Meldung, ausfuehrlich "
                              f"formuliert, damit sie Platz braucht.'")
              for i in range(3))))
        self.ingest()
        ergebnis = brief.bauen("Meldung an den Kapitaen", geltung="flotte",
                               db=self.tmp / "laufzeit" / "rules.db")
        deckel, _ = verfassung.laden()
        self.assertLessEqual(ergebnis.tokens, deckel["brief_token_max"])
        self.assertIn("K-001", ergebnis.text, "Kernregel darf nie gekappt werden")
        self.assertTrue(ergebnis.gekappt, "nichts gekappt — Deckel wirkt nicht")
        self.assertIn(f"gekappt: {', '.join(ergebnis.gekappt)}", ergebnis.text)

    def test_brief_ohne_kappung_bleibt_vollstaendig(self):
        self.regeln(datei(regel("K-001", verbindlichkeit="kern",
                                leser="tor:bin/fm-abnahme.sh", statement="Kurz.")))
        self.ingest()
        ergebnis = brief.bauen("Meldung", geltung="flotte",
                               db=self.tmp / "laufzeit" / "rules.db")
        self.assertEqual(ergebnis.gekappt, [])
        self.assertNotIn("gekappt:", ergebnis.text)

    def test_brief_meldet_laut_wenn_schon_der_kern_zu_gross_ist(self):
        """Lieber sichtbarer Ueberlauf als eine mitten im Satz abgeschnittene Regel."""
        self.verfassung(VERFASSUNG.replace("brief_token_max: 120", "brief_token_max: 5"))
        self.regeln(datei(regel("K-001", verbindlichkeit="kern",
                                leser="tor:bin/fm-abnahme.sh")))
        self.ingest()
        ergebnis = brief.bauen("Meldung", geltung="flotte",
                               db=self.tmp / "laufzeit" / "rules.db")
        self.assertIn("K-001", ergebnis.text)
        self.assertTrue(any("Kernregeln" in w for w in ergebnis.warnungen))


class TestPflichtfelder(FlotteTest):
    def test_fehlende_geltung_bricht_ab(self):
        self.regeln(datei(regel("A-001", geltung=None).replace(
            "    geltung: flotte\n", "")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("geltung", str(ctx.exception))

    def test_unbekannte_verbindlichkeit_bricht_ab(self):
        self.regeln(datei(regel("A-001", verbindlichkeit="wichtig")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("verbindlichkeit", str(ctx.exception))

    def test_projektgeltung_ist_erlaubt(self):
        self.regeln(datei(regel("A-001", geltung="projekt:lensclash")))
        self.assertEqual(self.ingest()["regeln"], 1)

    def test_mandatory_wird_aus_verbindlichkeit_abgeleitet(self):
        self.regeln(datei(regel("K-001", verbindlichkeit="kern",
                                leser="werkzeug:bin/fm-brief.sh")))
        self.ingest()
        conn = self.db()
        try:
            self.assertEqual(
                conn.execute("SELECT mandatory FROM rules WHERE id='K-001'").fetchone()[0], 1)
        finally:
            conn.close()

    def test_widersprechendes_mandatory_bricht_ab(self):
        self.regeln(datei(regel("A-001", mandatory="true")))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        self.assertIn("mandatory", str(ctx.exception))

    def test_verfassung_datei_wird_nicht_als_regeldatei_gelesen(self):
        self.regeln(datei(regel("A-001")))
        self.assertEqual(self.ingest()["regeln"], 1)


class TestSchemaV1Kompatibilitaet(FlotteTest):
    """Der Kompatibilitaetsvertrag aus dem Kopf von `ingest.py`.

    Das Schema gilt JE REGEL. Eine Regel im alten Format wird weiter
    angenommen, bekommt Vorgaben und bleibt zustellbar — sonst muesste jeder
    Bestand an einem Tag komplett umziehen und waere bis dahin regellos.
    """

    def test_v1_regel_wird_mit_vorgaben_ingestet_und_zugestellt(self):
        self.regeln(datei(v1_regel("ALT-001", mandatory="true"), v1_regel("ALT-002")))
        stat = self.ingest()
        self.assertEqual(stat["regeln"], 2)
        self.assertEqual(stat["legacy"], 2, "Legacy-Modus wird nicht ausgewiesen")

        conn = self.db()
        try:
            zeilen = {r["id"]: dict(r) for r in conn.execute(
                "SELECT id, geltung, verbindlichkeit, anker, nachweis, leser, "
                "verfall, status, mandatory FROM rules")}
        finally:
            conn.close()

        for rid in ("ALT-001", "ALT-002"):
            r = zeilen[rid]
            self.assertEqual(r["geltung"], "flotte", rid)
            self.assertEqual(r["leser"], "retrieval", rid)
            self.assertEqual(r["status"], "aktiv", rid)
            self.assertEqual(r["anker"], "", rid)
            self.assertIsNone(r["nachweis"], rid)
            self.assertIsNone(r["verfall"], rid)
        # `mandatory` fuehrt in v1, `verbindlichkeit` folgt — genau umgekehrt zu v2.
        self.assertEqual((zeilen["ALT-001"]["verbindlichkeit"],
                          zeilen["ALT-001"]["mandatory"]), ("kern", 1))
        self.assertEqual((zeilen["ALT-002"]["verbindlichkeit"],
                          zeilen["ALT-002"]["mandatory"]), ("kontext", 0))

        # Die Vorgaben muessen tragen, nicht nur in der Spalte stehen.
        kern = retrieve.nur_kern(db=self.tmp / "laufzeit" / "rules.db", geltung="worker")
        self.assertEqual(kern.ids(), ["ALT-001"])

    def test_v1_regel_bleibt_von_den_v2_pruefungen_ausgenommen(self):
        """Kern ohne benannten Leser und ohne Anker — in v2 zweimal ein Abbruch.

        Fuer eine v1-Regel sind beide Werte Vorgaben des Werkzeugs. Sie zu
        pruefen hiesse, das Werkzeug seine eigenen Defaults bewerten zu lassen.
        Ebenso zaehlt sie nicht gegen den Kerndeckel (hier: kern_max=2).
        """
        self.regeln(datei(*(v1_regel(f"ALT-{i:03d}", mandatory="true")
                            for i in range(5))))
        stat = self.ingest()
        self.assertEqual(stat["regeln"], 5)
        self.assertEqual(stat["legacy"], 5)

    def test_schema_v2_im_dateikopf_bindet_auch_die_alte_regel(self):
        """Gemischte Datei mit `schema: v2`: die v1-Regel faellt, die v2 nicht."""
        self.regeln(datei(regel("NEU-001"), v1_regel("ALT-001"), kopf="schema: v2\n"))
        with self.assertRaises(ingest.IngestError) as ctx:
            self.ingest()
        meldung = str(ctx.exception)
        self.assertIn("ALT-001", meldung, "Meldung nennt die alte Regel nicht")
        self.assertIn("werk.yaml", meldung, "Meldung nennt die Datei nicht")
        self.assertIn("geltung", meldung)
        self.assertNotIn("NEU-001", meldung, "die v2-Regel derselben Datei ist in Ordnung")

    def test_strikt_v2_weist_die_alte_regel_ab(self):
        self.regeln(datei(regel("NEU-001"), v1_regel("ALT-001")))
        self.assertEqual(self.ingest()["legacy"], 1, "ohne Schalter laeuft der Legacy-Modus")

        with self.assertRaises(ingest.IngestError) as ctx:
            ingest.run(source=fmpfade.regeln_dir(), mit_index=False, strikt_v2=True)
        meldung = str(ctx.exception)
        self.assertIn("ALT-001", meldung, "Meldung nennt die Regel-ID nicht")
        self.assertIn("werk.yaml", meldung, "Meldung nennt die Datei nicht")
        self.assertIn("--strikt-v2", meldung, "Meldung nennt den Schalter nicht")

    def test_strikt_v2_steht_auf_der_kommandozeile(self):
        """`bin/fm-regeln` haengt genau dieses Flag an sein ingest-Subkommando."""
        args = cli.build_parser().parse_args(["ingest", "--strikt-v2"])
        self.assertTrue(args.strikt_v2)
        self.assertFalse(cli.build_parser().parse_args(["ingest"]).strikt_v2)


if __name__ == "__main__":
    unittest.main()
