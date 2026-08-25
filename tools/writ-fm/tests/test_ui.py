"""M5 — UI-Server: API-Vertrag, Roundtrip, YAML-Rueckschreibung."""

from __future__ import annotations

import json
import re
import shutil
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from hilfe import MINI, REPO, TempDatenTest

from writ_light import ingest, paths, ui, yamlio


class ServerTest(TempDatenTest):
    """Startet den echten Server auf einem freien Port gegen ein Wegwerf-Repo."""

    def setUp(self):
        super().setUp()
        self.repo = self.tmp / "repo"
        (self.repo / "rules" / "projekte").mkdir(parents=True)
        (self.repo / "rules" / "global.yaml").write_text(
            "# Quelle: Test\n# NICHT modelliert: nichts\n" + MINI, encoding="utf-8")
        (self.repo / "rules" / "projekte" / "demo.yaml").write_text(
            f"# Quelle: Test\n# NICHT modelliert: nichts\nproject: demo\nrepo: {self.repo}\n"
            "rules:\n  - id: D-EINS-001\n    domain: demo\n    severity: 2\n"
            "    trigger: Eine Demo-Regel wird gebraucht.\n"
            "    statement: Demo-Regeln gehoeren ins Demo-Projekt.\n"
            "    tags: demo\n", encoding="utf-8")
        (self.repo / "ui").mkdir()
        shutil.copyfile(REPO / "ui" / "regelregister.html",
                        self.repo / "ui" / "regelregister.html")

        self._alt_root = paths.REPO_ROOT
        paths.REPO_ROOT = self.repo
        ingest.run(source=self.repo / "rules")

        self.server = ui.starten(leise=True)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        paths.REPO_ROOT = self._alt_root
        super().tearDown()

    def url(self, pfad="/api/rules"):
        return f"http://127.0.0.1:{self.port}{pfad}"

    def get(self, pfad="/api/rules"):
        with urllib.request.urlopen(self.url(pfad)) as r:
            return r.status, r.read()

    def put(self, daten):
        req = urllib.request.Request(
            self.url(), data=json.dumps(daten).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="PUT")
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())


class TestApiLesen(ServerTest):
    def test_bindet_nur_auf_localhost(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def test_startseite_liefert_das_regelregister(self):
        status, koerper = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn(b"Regelregister", koerper)
        self.assertIn(b"/api/rules", koerper)

    def test_get_liefert_alle_regeln_mit_yaml_feldnamen(self):
        status, koerper = self.get()
        self.assertEqual(status, 200)
        daten = json.loads(koerper)
        self.assertEqual(len(daten), 3)
        for feld in ("id", "domain", "severity", "mandatory", "trigger",
                     "statement", "violation", "correct", "tags", "relations"):
            self.assertIn(feld, daten[0])

    def test_mandatory_ist_ein_boolescher_wert(self):
        daten = json.loads(self.get()[1])
        werte = {r["id"]: r["mandatory"] for r in daten}
        self.assertIs(werte["A-ZWEI-001"], True)
        self.assertIs(werte["A-EINS-001"], False)

    def test_beziehungen_kommen_als_liste_von_objekten(self):
        daten = json.loads(self.get()[1])
        rel = {r["id"]: r["relations"] for r in daten}
        self.assertEqual(rel["A-ZWEI-001"], [{"kind": "SUPPLEMENTS", "dst": "A-EINS-001"}])
        self.assertEqual(rel["A-EINS-001"], [])

    def test_pruefexport_knopf_ist_verdrahtet(self):
        html = (REPO / "ui" / "regelregister.html").read_text(encoding="utf-8")
        self.assertIn('id="btnPruefexport"', html)
        self.assertIn('fetch("/api/export", {method:"POST"})', html)

    def test_unbekannter_pfad_gibt_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/gibtsnicht")
        self.assertEqual(ctx.exception.code, 404)


class TestApiSchreiben(ServerTest):
    def test_roundtrip_get_aendern_put_get(self):
        daten = json.loads(self.get()[1])
        for r in daten:
            if r["id"] == "A-EINS-001":
                r["statement"] = "Geaendert ueber die Oberflaeche."
                r["severity"] = 3
        status, antwort = self.put(daten)
        self.assertEqual(status, 200)
        self.assertEqual(antwort["regeln"], 3)

        erneut = {r["id"]: r for r in json.loads(self.get()[1])}
        self.assertEqual(erneut["A-EINS-001"]["statement"], "Geaendert ueber die Oberflaeche.")
        self.assertEqual(erneut["A-EINS-001"]["severity"], 3)

    def test_put_baut_die_indizes_neu(self):
        vorher = paths.index_path().stat().st_mtime_ns
        daten = json.loads(self.get()[1])
        daten[0]["statement"] = "Ein voellig anderer Regeltext ueber Datenbanken."
        self.assertEqual(self.put(daten)[0], 200)
        self.assertNotEqual(paths.index_path().stat().st_mtime_ns, vorher)

        from writ_light import schema
        conn = schema.connect(paths.db_path())
        treffer = conn.execute(
            "SELECT r.id FROM rules_fts f JOIN rules r ON r.rowid=f.rowid "
            "WHERE rules_fts MATCH 'datenbanken'").fetchall()
        conn.close()
        self.assertEqual(len(treffer), 1, "FTS5 wurde nicht neu befuellt")

    def test_put_schreibt_nur_die_geaenderte_datei(self):
        datei = self.repo / "rules" / "projekte" / "demo.yaml"
        andere = self.repo / "rules" / "global.yaml"
        stand_andere = andere.read_text(encoding="utf-8")

        daten = json.loads(self.get()[1])
        for r in daten:
            if r["id"] == "D-EINS-001":
                r["tags"] = "demo, geaendert"
        antwort = self.put(daten)[1]
        self.assertEqual(antwort["dateien"]["geschrieben"], ["rules/projekte/demo.yaml"])
        self.assertIn("demo, geaendert", datei.read_text(encoding="utf-8"))
        self.assertEqual(andere.read_text(encoding="utf-8"), stand_andere,
                         "unbeteiligte Datei wurde umformatiert")

    def test_rueckgeschriebene_datei_bleibt_ingestierbar(self):
        daten = json.loads(self.get()[1])
        for r in daten:
            if r["id"] == "D-EINS-001":
                r["statement"] = 'Mit Doppelpunkt: und "Anfuehrungszeichen" drin.'
        self.assertEqual(self.put(daten)[0], 200)
        regeln, _ = ingest.collect(self.repo / "rules")
        ingest.validate(regeln)
        neu = {r["id"]: r for r in regeln}
        self.assertEqual(neu["D-EINS-001"]["statement"],
                         'Mit Doppelpunkt: und "Anfuehrungszeichen" drin.')

    def test_dateikopf_ueberlebt_das_rueckschreiben(self):
        """Dort steht die Auslassungsnotiz nach Akzeptanz 2."""
        datei = self.repo / "rules" / "projekte" / "demo.yaml"
        daten = json.loads(self.get()[1])
        for r in daten:
            if r["id"] == "D-EINS-001":
                r["tags"] = "geaendert"
        self.put(daten)
        inhalt = datei.read_text(encoding="utf-8")
        self.assertIn("# Quelle: Test", inhalt)
        self.assertIn("# NICHT modelliert", inhalt)
        self.assertIn("project: demo", inhalt)

    def test_projekt_und_quelle_ueberleben_den_roundtrip(self):
        daten = json.loads(self.get()[1])
        self.put(daten)
        neu = {r["id"]: r for r in json.loads(self.get()[1])}
        self.assertEqual(neu["D-EINS-001"]["project"], "demo")
        self.assertEqual(neu["D-EINS-001"]["quelle"], "rules/projekte/demo.yaml")

    def test_neue_regel_aus_der_oberflaeche_landet_in_ui_neu(self):
        daten = json.loads(self.get()[1])
        daten.append({"id": "NEU-TEST-001", "domain": "allgemein", "severity": 2,
                      "mandatory": False, "trigger": "Ein Test legt eine Regel an.",
                      "statement": "Sie landet in rules/ui-neu.yaml.",
                      "violation": "", "correct": "", "tags": "", "relations": []})
        antwort = self.put(daten)[1]
        self.assertIn(yamlio.UI_DATEI, antwort["dateien"]["geschrieben"])
        self.assertTrue((self.repo / yamlio.UI_DATEI).exists())

    def test_geloeschte_regel_kommt_nach_ingest_nicht_zurueck(self):
        daten = [r for r in json.loads(self.get()[1]) if r["id"] != "D-EINS-001"]
        self.assertEqual(self.put(daten)[0], 200)
        regeln, _ = ingest.collect(self.repo / "rules")
        self.assertNotIn("D-EINS-001", [r["id"] for r in regeln])

    def test_haengende_beziehung_wird_abgewiesen(self):
        daten = json.loads(self.get()[1])
        daten[0]["relations"] = [{"kind": "DEPENDS_ON", "dst": "GIBTS-NICHT"}]
        status, antwort = self.put(daten)
        self.assertEqual(status, 400)
        self.assertIn("GIBTS-NICHT", antwort["fehler"])

    def test_abgewiesener_put_laesst_den_bestand_unveraendert(self):
        vorher = json.loads(self.get()[1])
        daten = json.loads(json.dumps(vorher))
        daten[0]["relations"] = [{"kind": "DEPENDS_ON", "dst": "GIBTS-NICHT"}]
        self.put(daten)
        self.assertEqual(json.loads(self.get()[1]), vorher)

    def test_leeres_oder_falsches_json_wird_abgewiesen(self):
        for koerper in ([], {"a": 1}):
            self.assertEqual(self.put(koerper)[0], 400)


class TestPruefExport(ServerTest):
    def post(self, pfad="/api/export"):
        req = urllib.request.Request(self.url(pfad), data=b"", method="POST")
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_export_schreibt_das_verzeichnis(self):
        status, antwort = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(antwort["regeln"], 3)
        ziel = Path(antwort["ziel"])
        self.assertTrue(ziel.is_dir())
        for name in ("README.md", "regeln.md", "ketten.md", "regeln.json", "regeln.yaml"):
            self.assertTrue((ziel / name).exists(), name)

    def test_export_landet_im_repo_verzeichnis(self):
        """Nicht irgendwo — dort, wo `writ-light export` ohne Argument hinschreibt."""
        antwort = self.post()[1]
        self.assertEqual(Path(antwort["ziel"]), self.repo / "export")

    def test_export_spiegelt_gespeicherte_aenderungen(self):
        daten = json.loads(self.get()[1])
        for r in daten:
            if r["id"] == "D-EINS-001":
                r["statement"] = "Nach dem Speichern im Export sichtbar."
        self.put(daten)
        ziel = Path(self.post()[1]["ziel"])
        self.assertIn("Nach dem Speichern im Export sichtbar.",
                      (ziel / "regeln.md").read_text(encoding="utf-8"))

    def test_post_auf_unbekannten_pfad_gibt_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(
                urllib.request.Request(self.url("/api/irgendwas"), data=b"", method="POST"))
        self.assertEqual(ctx.exception.code, 404)


class TestGeschuetzteDatei(unittest.TestCase):
    def test_gold_datei_wird_nicht_zurueckgeschrieben(self):
        self.assertIn("rules/onboarding.yaml", yamlio.GESCHUETZT)

    def test_zurueckschreiben_meldet_die_auslassung(self):
        vorher = [{"id": "X-001", "quelle": "rules/onboarding.yaml", "trigger": "a",
                   "statement": "b", "relations": []}]
        neu = [dict(vorher[0], statement="geaendert")]
        bericht = yamlio.zurueckschreiben(neu, vorher, wurzel=Path("/tmp/gibtsnicht"))
        self.assertEqual(bericht["nur_in_db"], ["rules/onboarding.yaml"])
        self.assertEqual(bericht["geschrieben"], [])


class TestEingebetteterFallback(unittest.TestCase):
    """Einzige am regelregister.html erlaubte Aenderung (Auftrag, Grenzen/Tabus)."""

    def setUp(self):
        self.html = (REPO / "ui" / "regelregister.html").read_text(encoding="utf-8")

    def test_fallback_ist_auf_die_verbindlichen_regeln_gekuerzt(self):
        """Aus den 24 gelieferten Beispieldaten wurde ein knapper Fallback.
        Die genaue Menge prueft der Test darunter."""
        ids = re.findall(r'^\{id:"([^"]+)"', self.html, re.MULTILINE)
        self.assertLess(len(ids), 10)
        self.assertTrue(all(i.startswith("ENF-") for i in ids), ids)

    def test_fallback_enthaelt_alle_verbindlichen_regeln(self):
        """Massstab ist DAUERHAFT verbindlich, nicht bloss verbindlich.

        Bis 2026-08-05 blieb ENF-QUERY-001 bewusst draussen (befristet);
        mit ihrer Ablösung muessen alle verbindlichen Regeln im Fallback
        stehen.
        """
        ids = set(re.findall(r'^\{id:"([^"]+)"', self.html, re.MULTILINE))
        regeln, _ = ingest.collect(REPO / "rules")
        mandatory = {r["id"] for r in regeln if r["mandatory"]}
        self.assertTrue(ids <= mandatory, f"nicht mehr verbindlich: {ids - mandatory}")
        self.assertEqual(mandatory - ids, set(),
                         "dauerhaft verbindliche Regel fehlt im Fallback")
        self.assertIn("ENF-INPUT-001", ids)

    def test_api_anbindung_ist_unveraendert(self):
        for muster in ('fetch("/api/rules"', 'method:"PUT"',
                       'Datenquelle: writ-light (/api/rules)'):
            self.assertIn(muster, self.html)

    FALLBACK_TEXTFELDER = ("trigger", "statement", "violation", "correct", "tags", "domain")

    @staticmethod
    def _embedded_rules(html_pfad: Path) -> list[dict]:
        """Liest EMBEDDED_RULES aus einer regelregister.html per `node`.

        EMBEDDED_RULES ist JS, kein JSON: verschachtelte relations-Objekte,
        gemischte Anfuehrungszeichen (`violation` bei ENF-INPUT-001 hat ein
        `"..."`-Zitat INNERHALB eines doppelt gequoteten Strings), Umlaute.
        Ein Feld-fuer-Feld-Regex muesste all das nachbauen und wuerde bei der
        naechsten Textaenderung leise falsch parsen -- genau der Drift, den
        dieser Test verhindern soll. Die uebrigen Tests dieser Klasse nutzen
        `re.findall`, aber nur um die flache `id` am Zeilenanfang zu greifen;
        hier stehen ganze, mehrfach verschachtelte Objekte auf dem Spiel.
        `node` (lokal v24.18.0 vorhanden) ist die Laufzeit, die dieses
        Literal auch im Browser einliest -- deshalb wird hier ausgewertet
        statt nachgebaut.
        """
        import subprocess

        skript = (
            "const fs=require('fs');"
            "const t=fs.readFileSync(process.argv[1],'utf8');"
            "const m=t.match(/const EMBEDDED_RULES = (\\[[\\s\\S]*?\\n\\]);/);"
            "if(!m){process.stderr.write('EMBEDDED_RULES nicht gefunden');process.exit(1);}"
            "const arr=eval(m[1]);"
            "process.stdout.write(JSON.stringify(arr));"
        )
        ergebnis = subprocess.run(
            ["node", "-e", skript, str(html_pfad)],
            capture_output=True, text=True, check=True)
        return json.loads(ergebnis.stdout)

    @staticmethod
    def _norm(text) -> str:
        """YAML-Folded-Scalars (`>`) falten Zeilenumbrueche/Einrueckung anders
        als der HTML-Einzeiler. Ohne diese Normalisierung waere jeder
        mehrzeilige trigger/statement ein Fehlalarm, der nichts ueber
        inhaltliche Drift aussagt."""
        return re.sub(r"\s+", " ", str(text or "")).strip()

    @staticmethod
    def _relations_menge(relations) -> set[tuple[str, str]]:
        """relations ist eine Liste von Dicts in wechselnder Reihenfolge —
        als sortierte Menge von (kind, dst) vergleichen, nicht als Liste."""
        return {(r["kind"], r["dst"]) for r in (relations or [])}

    @classmethod
    def _diffs_gegen_quelle(cls, html_pfad: Path) -> list[str]:
        """Vergleicht jeden Fallback-Eintrag feldweise gegen ingest.collect().

        Eigene Methode statt Test-Body: dieselbe Pruefung muss fuer die rote
        Gegenprobe auch gegen eine verfaelschte KOPIE der HTML-Datei laufen
        koennen, ohne das Original anzufassen. Rueckgabe: eine Zeile je
        abweichendem Feld mit beiden Seiten im Klartext; leer, wenn alles
        uebereinstimmt.
        """
        fallback = {r["id"]: r for r in cls._embedded_rules(html_pfad)}
        regeln, _ = ingest.collect(REPO / "rules")
        quelle = {r["id"]: r for r in regeln if r["mandatory"]}

        diffs = []
        for rid, eintrag in fallback.items():
            if rid not in quelle:
                diffs.append(f"{rid}: im Fallback, aber nicht (mehr) verbindlich in der Quelle")
                continue
            ref = quelle[rid]

            for feld in cls.FALLBACK_TEXTFELDER:
                a, b = cls._norm(eintrag.get(feld)), cls._norm(ref.get(feld))
                if a != b:
                    diffs.append(f"{rid}.{feld}: Fallback={a!r} != Quelle={b!r}")

            if int(eintrag.get("severity", -1)) != int(ref["severity"]):
                diffs.append(f"{rid}.severity: Fallback={eintrag.get('severity')!r} "
                              f"!= Quelle={ref['severity']!r}")

            if bool(eintrag.get("mandatory")) != bool(ref["mandatory"]):
                diffs.append(f"{rid}.mandatory: Fallback={eintrag.get('mandatory')!r} "
                              f"!= Quelle={bool(ref['mandatory'])!r}")

            rel_a = cls._relations_menge(eintrag.get("relations"))
            rel_b = cls._relations_menge(ref.get("relations"))
            if rel_a != rel_b:
                diffs.append(f"{rid}.relations: Fallback={sorted(rel_a)} "
                              f"!= Quelle={sorted(rel_b)}")
        return diffs

    def test_fallback_felder_stimmen_mit_der_regelquelle_ueberein(self):
        """Nicht nur die ID-Menge (siehe Test darueber), sondern jedes Feld.

        Befund: der Fallback-Text zu ENF-OVERRIDE-001 nannte bis 2026-08-08
        `/plugins disable onboarding` als Override-Weg, obwohl die Regel
        selbst schon am 2026-08-07 korrigiert war -- ein ganzer Tag lang
        unbemerkt, weil `test_fallback_enthaelt_alle_verbindlichen_regeln`
        nur die ID-MENGE prueft. Solange die IDs stimmen, durfte der Text
        beliebig driften. Dieser Test schliesst genau die Luecke: jedes
        Feld jedes Fallback-Eintrags gegen ingest.collect() der Regelquelle.
        """
        diffs = self._diffs_gegen_quelle(REPO / "ui" / "regelregister.html")
        self.assertEqual(diffs, [], "\n" + "\n".join(diffs))


if __name__ == "__main__":
    unittest.main()
