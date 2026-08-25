"""M3 — Eigenschaften des konvertierten Regelwerks."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml
from hilfe import REPO, TempDatenTest

from writ_light import ingest, paths, retrieve, schema

QUELLEN = sorted((REPO / "rules").rglob("*.yaml"))
DOSSIER_DIR = Path.home() / "projects/claw-bridge/kontext/projekte"

# Owner-Entscheid 2026-08-02: nur Dossiers mit Substanz.
ERWARTETE_PROJEKTE = {
    "lensclash", "rag-digital", "cli_dashboard",
    "trooper_ai", "wimmel", "lernplattform", "testlab",
}
BEWUSST_AUSGELASSEN = {"quiz-web", "snacksuite", "dummy", "_VORLAGE"}


class TestQuelldateien(unittest.TestCase):
    def test_alle_dateien_sind_gueltiges_yaml(self):
        for p in QUELLEN:
            with self.subTest(datei=p.name):
                doc = yaml.safe_load(p.read_text(encoding="utf-8"))
                self.assertIn("rules", doc)

    def test_gesamtes_regelwerk_validiert(self):
        regeln, projekte = ingest.collect(REPO / "rules")
        ingest.validate(regeln)
        self.assertGreater(len(regeln), 100)
        self.assertEqual({p["id"] for p in projekte}, ERWARTETE_PROJEKTE)

    def test_ausgelassene_dossiers_haben_keine_datei(self):
        vorhanden = {p.stem for p in (REPO / "rules" / "projekte").glob("*.yaml")}
        self.assertEqual(vorhanden & BEWUSST_AUSGELASSEN, set())

    def test_jedes_beruecksichtigte_dossier_hat_eine_datei(self):
        vorhanden = {p.stem for p in (REPO / "rules" / "projekte").glob("*.yaml")}
        self.assertEqual(vorhanden, ERWARTETE_PROJEKTE)

    def test_projektdateien_tragen_projekt_und_repo(self):
        for p in (REPO / "rules" / "projekte").glob("*.yaml"):
            with self.subTest(datei=p.name):
                doc = yaml.safe_load(p.read_text(encoding="utf-8"))
                self.assertEqual(doc.get("project"), p.stem)
                self.assertTrue(doc.get("repo"), "repo-Zeile fehlt")

    def test_hinterlegte_repo_pfade_existieren(self):
        _, projekte = ingest.collect(REPO / "rules")
        for pr in projekte:
            with self.subTest(projekt=pr["id"]):
                self.assertTrue(Path(pr["repo_path"]).is_dir(), pr["repo_path"])

    def test_repo_pfade_stimmen_mit_den_dossiers_ueberein(self):
        """Gegenprobe an der Quelle: Kopfzeile `Repo: …` des Dossiers."""
        _, projekte = ingest.collect(REPO / "rules")
        nach_id = {p["id"]: p["repo_path"] for p in projekte}
        for projekt, pfad in nach_id.items():
            dossier = DOSSIER_DIR / f"{projekt}.md"
            if not dossier.exists():
                continue
            kopf = dossier.read_text(encoding="utf-8")[:400]
            m = re.search(r"Repo:\s*`?([^`·)\s]+)", kopf)
            if not m:
                continue  # testlab.md hat keine Kopfzeile — Fallback dokumentiert
            with self.subTest(projekt=projekt):
                erwartet = Path(m.group(1).replace("~", str(Path.home()))).resolve()
                self.assertEqual(Path(pfad).resolve(), erwartet)


class TestKonventionen(unittest.TestCase):
    def setUp(self):
        self.regeln, _ = ingest.collect(REPO / "rules")

    def test_ids_folgen_dem_muster(self):
        for r in self.regeln:
            with self.subTest(regel=r["id"]):
                self.assertRegex(r["id"], r"^[A-Z][A-Z0-9]*-[A-Z0-9]+-\d{3}$")

    def test_jede_regel_hat_trigger_und_statement(self):
        for r in self.regeln:
            with self.subTest(regel=r["id"]):
                self.assertTrue(r["trigger"], "trigger leer")
                self.assertTrue(r["statement"], "statement leer")

    def test_mandatory_bleibt_unter_zehn(self):
        """Akzeptanz 4 — Richtwert unter 10 gesamt."""
        mand = [r["id"] for r in self.regeln if r["mandatory"]]
        self.assertLess(len(mand), 10, mand)

    def test_mandatory_ist_gold_datei_plus_eine_beauftragte(self):
        """Jede zusaetzliche Aufnahme muss hier auffallen.

        Der Name sagt "eine beauftragte" — es sind inzwischen zwei; der Name
        bleibt, damit er in der Historie auffindbar bleibt.

        ENF-INPUT-001 (2026-08-02, Prompt-Injection) ist ausdruecklich
        beauftragt; Begruendung in belege/akzeptanz-4-mandatory.md.
        ENF-PLAN-001 (2026-08-08, subagent-driven umsetzen) ist der zweite
        Owner-Entscheid dieser Art; Beleg in belege/e2-mandatory-plan-regel.md.
        Verbindlich ist dort nur die Weichenstellung selbst — WF-SUBAGENT-001
        und WF-MODELL-001 aus derselben Quelle sind es bewusst nicht, das
        sichert test_zuschnitt_und_modellwahl_sind_nicht_verbindlich.
        ENF-QUERY-001 ist 2026-08-05 entfallen: Kimi Code reicht Regeln
        seither per [[hooks]] in config.toml selbst nach (gemessen, siehe
        belege/kimi-hooks-config-toml.md).
        """
        mand = {r["id"] for r in self.regeln if r["mandatory"]}
        gold, _ = ingest.collect(REPO / "rules" / "onboarding.yaml")
        self.assertEqual(
            mand,
            {r["id"] for r in gold if r["mandatory"]}
            | {"ENF-INPUT-001", "ENF-PLAN-001"})

    def test_prompt_injection_regel_ist_verbindlich(self):
        """Sie darf nicht davon abhaengen, dass eingeschleuster Text sie
        zufaellig hochrankt — das waere der Angriff selbst."""
        regel = next(r for r in self.regeln if r["id"] == "ENF-INPUT-001")
        self.assertTrue(regel["mandatory"])
        self.assertEqual(regel["severity"], 3)

    def test_uebergangsregel_ist_abgeloest(self):
        """ENF-QUERY-001 entfiel mit dem config.toml-Hook (2026-08-05) — sie
        darf nicht wieder auftauchen, ohne dass es auffaellt."""
        self.assertNotIn("ENF-QUERY-001", {r["id"] for r in self.regeln})

    def test_override_wege_stehen_ueberall_gleich(self):
        """ENF-OVERRIDE-001 und hooks.OVERRIDE muessen BEIDE Wege nennen.

        Bis 2026-08-07 nannte die Regel `/plugins disable onboarding` — ein
        Plugin, das es in Claude Code nie gab —, der Rahmen dagegen die
        settings.json. Beide landeten im selben Session-Kontext. Seit
        2026-08-08 gibt es zwei Wege: `WRIT_RULES=aus claude` (Alias
        `claude-free`) und das lokale Entfernen des SessionStart-Hooks aus
        `~/.claude/settings.json`. Verschweigt eine der beiden Fassungen
        einen Weg, faellt dieser Test um.

        Geprueft werden nur Zeichenketten, die in BEIDEN Fassungen identisch
        sind. "Uebersicht" gehoert nicht dazu: hooks.py ist ASCII, die Regel
        schreibt echte Umlaute — ein Vergleich darauf wuerde die Schreibweise
        pruefen, nicht die Aussage.
        """
        from writ_light import hooks

        regel = next(r for r in self.regeln if r["id"] == "ENF-OVERRIDE-001")
        for teil in ("settings.json", "WRIT_RULES=aus", "claude-free"):
            with self.subTest(fassung="ENF-OVERRIDE-001", teil=teil):
                self.assertIn(teil, regel["statement"])
        self.assertNotIn("plugins disable", regel["statement"])
        self.assertNotIn("/reload", regel["statement"])
        for teil in ("settings.json", "WRIT_RULES=aus", "claude-free"):
            with self.subTest(fassung="hooks.OVERRIDE", teil=teil):
                self.assertIn(teil, hooks.OVERRIDE)

    def test_zuschnitt_und_modellwahl_sind_nicht_verbindlich(self):
        """Aus plan-arbeit.yaml ist nur die Weichenstellung verbindlich.

        ENF-PLAN-001 entscheidet, DASS subagent-driven umgesetzt wird — wird
        das verpasst, greift keine der beiden anderen je. Zuschnitt und
        Modellwahl sind Handwerk innerhalb dieser Weiche und sollen greifen,
        wenn die Lage passt. Owner-Entscheid 2026-08-08.
        """
        neu = {"WF-SUBAGENT-001", "WF-MODELL-001"}
        vorhanden = {r["id"] for r in self.regeln}
        self.assertEqual(neu - vorhanden, set(), "Regel fehlt im Bestand")
        for r in self.regeln:
            if r["id"] in neu:
                self.assertFalse(r["mandatory"], r["id"])

    def test_neue_regeln_dieser_runde_sind_nicht_verbindlich(self):
        """Handwerksregeln sollen greifen, wenn die Lage passt, nicht immer.

        Die Begruendung war bis 2026-08-07 eine andere: der verbindliche
        Block zahlte aus demselben Topf wie die gerankten Regeln (918 von
        2000 Tokens, belege/e1-budget-messung.md), jede weitere
        mandatory-Regel ging direkt von ihnen ab. Das gilt nicht mehr —
        `budget_anwenden` startet seither mit `verbraucht = 0`, und je
        Eingabe kommen verbindliche Regeln nur noch als ID-Zeile
        (REG-BUDGET-001). Diese fuenf bleiben trotzdem gerankt: sie
        beschreiben Handwerk, nicht Sicherheit.
        """
        neu = {"WF-CWD-001", "WF-PROZESS-001", "LEK-SELBSTPRUEFUNG-001",
               "LEK-HYPOTHESE-001", "REG-SKILL-001"}
        vorhanden = {r["id"] for r in self.regeln}
        self.assertEqual(neu - vorhanden, set(), "Regel fehlt im Bestand")
        for r in self.regeln:
            if r["id"] in neu:
                self.assertFalse(r["mandatory"], r["id"])

    def test_claw_rolle_traegt_den_adressaten_im_trigger(self):
        """Owner-Vorgabe: Trigger beginnt mit der Rollenangabe."""
        claw = [r for r in self.regeln if r["domain"] == retrieve.CLAW_DOMAIN]
        self.assertGreaterEqual(len(claw), 10)
        for r in claw:
            with self.subTest(regel=r["id"]):
                self.assertTrue(
                    r["trigger"].startswith("Rolle Claw (nicht die ausführende Session):"),
                    r["trigger"][:70])
                self.assertTrue(r["id"].startswith("CLAW-"))

    def test_nur_claw_regeln_liegen_in_der_claw_domain(self):
        for r in self.regeln:
            if r["id"].startswith("CLAW-"):
                self.assertEqual(r["domain"], retrieve.CLAW_DOMAIN, r["id"])

    def test_projektregeln_sind_an_ihr_projekt_gebunden(self):
        for r in self.regeln:
            if r["quelle"].startswith("rules/projekte/"):
                with self.subTest(regel=r["id"]):
                    self.assertEqual(r["project"], Path(r["quelle"]).stem)

    def test_globale_regeln_haben_kein_projekt(self):
        for r in self.regeln:
            if not r["quelle"].startswith("rules/projekte/"):
                self.assertIsNone(r["project"], r["id"])

    def test_jede_quelldatei_dokumentiert_ihre_auslassungen(self):
        """Akzeptanz 2 — pro Dokument eine Notiz, was nicht modelliert wurde."""
        for p in QUELLEN:
            if p.name == "onboarding.yaml":
                continue  # geliefert, unveraendert uebernommen
            with self.subTest(datei=p.name):
                kopf = p.read_text(encoding="utf-8").split("rules:")[0]
                self.assertIn("NICHT modelliert", kopf)
                self.assertIn("Quelle", kopf)


class TestKorpusRetrieval(TempDatenTest):
    """Die Akzeptanz-Queries gegen das VOLLE Regelwerk, nicht nur die Gold-Datei."""

    def setUp(self):
        super().setUp()
        ingest.run(source=REPO / "rules")

    def test_akzeptanz_queries_halten_im_vollen_korpus(self):
        from test_retrieve import AKZEPTANZ_QUERIES

        fehler = []
        for prompt, erwartet, feld in AKZEPTANZ_QUERIES:
            ids = retrieve.query(prompt, cwd=self.tmp).gerankte_ids()
            if erwartet not in ids[:5]:
                platz = ids.index(erwartet) + 1 if erwartet in ids else "nicht gefunden"
                fehler.append(f"{feld}: {prompt!r} -> {erwartet} auf Platz {platz}")
        self.assertEqual(fehler, [], "\n" + "\n".join(fehler))

    def test_projektregeln_bleiben_im_eigenen_projekt(self):
        """Anti-Vermischung: dieselbe Query, zwei Repos, getrennte Treffer."""
        frage = "Wie mocke ich eine externe Quelle im Test?"
        rag = retrieve.query(frage, cwd=Path.home() / "projects/rag-digital")
        lens = retrieve.query(frage, cwd=Path.home() / "projects/lensclash")
        self.assertEqual(rag.projekt, "rag-digital")
        self.assertEqual(lens.projekt, "lensclash")
        self.assertIn("RAG-MOCK-001", rag.gerankte_ids())
        self.assertNotIn("RAG-MOCK-001", lens.gerankte_ids())
        self.assertNotIn("LC-MOCK-001", rag.gerankte_ids())

    def test_keine_fremdprojekt_regel_taucht_je_auf(self):
        conn = schema.connect(paths.db_path())
        projekte = [r["id"] for r in conn.execute("SELECT id FROM projects")]
        pfade = {r["id"]: r["repo_path"] for r in conn.execute("SELECT * FROM projects")}
        conn.close()
        for projekt in projekte:
            ergebnis = retrieve.query("Wie gehe ich hier vor?", cwd=pfade[projekt])
            for t in ergebnis.alle:
                p = t.regel["project"]
                with self.subTest(projekt=projekt, regel=t.regel["id"]):
                    self.assertIn(p, (None, projekt))

    def test_claw_regeln_erscheinen_nicht_im_normalbetrieb(self):
        ergebnis = retrieve.query("Wie schmiede ich eine Arbeitsanweisung?", cwd=self.tmp)
        for t in ergebnis.alle:
            self.assertNotEqual(t.regel["domain"], retrieve.CLAW_DOMAIN, t.regel["id"])

    def test_konflikt_beziehung_ist_modelliert(self):
        """CLID-BOT-001 hebt COMM-BOT-001 fuer cli_dashboard auf."""
        conn = schema.connect(paths.db_path())
        row = conn.execute(
            "SELECT * FROM relations WHERE src='CLID-BOT-001' AND kind='CONFLICTS_WITH'"
        ).fetchone()
        conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row["dst"], "COMM-BOT-001")


if __name__ == "__main__":
    unittest.main()
