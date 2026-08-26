"""doctor — erkennt einen halb fertigen Ingest."""

from __future__ import annotations

import io
import json
import sqlite3
import unittest
import unittest.mock
from contextlib import redirect_stdout
from pathlib import Path

from hilfe import MINI, TempDatenTest

from writ_light import cli, ingest, paths, schema


class TestDoctor(TempDatenTest):
    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(MINI))

    def lauf(self, verdrahtung=(), installationen=()) -> tuple[int, str]:
        """Verdrahtung UND Installationsvergleich werden hier stummgeschaltet.

        Sonst haengt jeder doctor-Test daran, wie dieser Laptop gerade
        verdrahtet ist: ein fehlender Git-Hook auf einer anderen Maschine
        wuerfe Tests um, die mit Verdrahtung nichts zu tun haben. Sie hat
        eigene Tests mit nachgebautem Heimatverzeichnis (TestVerdrahtung) —
        dort wird sie wirklich ausgefuehrt, nicht weggemockt.

        `installationen()` ist seit 2026-08-08 aus demselben Grund dabei, und
        der Grund ist diesmal gemessen: die Funktion vergleicht die Hooks im
        Repo BYTEWEISE mit denen unter ~/.claude/hooks. Sobald jemand einen
        Hook aendert und noch nicht installiert hat — der Normalzustand
        mitten in einer Aenderung — meldete `test_gesunde_installation…`
        rot, obwohl an der Datenbank nichts fehlt. Vier Tests dieser Klasse
        fielen dadurch um, keiner davon wegen seines eigenen Gegenstands.
        Der Drift selbst bleibt geprueft: die drei Tests weiter unten geben
        ueber diesen Parameter Wegwerf-Dateien vor und pruefen ihn WIRKLICH,
        statt sich auf den Zufallszustand dieses Laptops zu verlassen.
        """
        puffer = io.StringIO()
        with unittest.mock.patch.object(cli, "verdrahtung",
                                        return_value=list(verdrahtung)), \
                unittest.mock.patch.object(cli, "installationen",
                                           return_value=list(installationen)):
            with redirect_stdout(puffer):
                code = cli.main(["doctor"])
        return code, puffer.getvalue()

    def test_fehlende_verdrahtung_macht_doctor_rot(self):
        """Ein nicht eingehaengter Hook ist ein Ausfall, keine Randnotiz."""
        code, text = self.lauf([("SessionStart eingehaengt", False, "kein Hook in x")])
        self.assertEqual(code, 1)
        self.assertIn("NICHT einsatzbereit", text)
        self.assertIn("SessionStart eingehaengt", text)
        self.assertIn("kein Hook in x", text)

    def test_gesunde_installation_ist_einsatzbereit(self):
        code, text = self.lauf()
        self.assertEqual(code, 0, text)
        self.assertIn("einsatzbereit", text)
        self.assertNotIn("NICHT einsatzbereit", text)

    def test_index_der_hinter_der_datenbank_zurueckliegt_faellt_auf(self):
        """Abbruch zwischen write_db und build_index — die Datenbank sieht heil aus."""
        conn = schema.connect(paths.db_path())
        conn.execute("UPDATE meta SET value='1' WHERE key='index_count'")
        conn.commit()
        conn.close()
        code, text = self.lauf()
        self.assertEqual(code, 1)
        self.assertIn("NICHT einsatzbereit", text)
        self.assertIn("1 indiziert gegen 2 Regeln", text)
        self.assertIn("writ-light ingest", text)

    def _loeschen_ohne_fremdschluessel(self, regel_id: str) -> None:
        """Regel loeschen, wie es ein Werkzeug OHNE `PRAGMA foreign_keys` tut.

        Der Schemazwang greift nur, wenn die Pragma gesetzt ist — und die ist
        in SQLite standardmaessig AUS. Genau dagegen sichert der doctor-Check.
        """
        roh = sqlite3.connect(paths.db_path())
        roh.execute(f"DELETE FROM rules WHERE id='{regel_id}'")
        roh.commit()
        roh.close()

    def test_schema_verhindert_das_loeschen_bei_gesetzter_pragma(self):
        """Erste Verteidigungslinie: die Fremdschluessel-Bedingung selbst."""
        conn = schema.connect(paths.db_path())
        with self.assertRaises(sqlite3.IntegrityError):
            conn.execute("DELETE FROM rules WHERE id='A-EINS-001'")
        conn.close()

    def test_haengende_beziehung_faellt_auf(self):
        """Zweite Verteidigungslinie: Regel weg, Beziehung darauf geblieben.

        Die 1-Hop-Expansion findet den Nachbarn dann einfach nicht und liefert
        stumm weniger — ohne diesen Check weist nichts darauf hin.
        """
        self._loeschen_ohne_fremdschluessel("A-EINS-001")
        code, text = self.lauf()
        self.assertEqual(code, 1)
        self.assertIn("1 haengend", text)
        self.assertIn("A-ZWEI-001 -SUPPLEMENTS-> A-EINS-001", text)

    def test_beziehung_mit_verschwundener_quelle_faellt_auf(self):
        self._loeschen_ohne_fremdschluessel("A-ZWEI-001")
        code, text = self.lauf()
        self.assertEqual(code, 1)
        self.assertIn("haengend", text)

    def test_gesunder_bestand_meldet_die_beziehungszahl(self):
        _, text = self.lauf()
        self.assertIn("1 Beziehungen", text)

    def test_veraltete_installierte_kopie_faellt_auf(self):
        """Repo und Wirkort koennen auseinanderlaufen.

        Genau so trug das installierte Kimi-Plugin einmal eine veraltete
        SKILL.md, die behauptete, ein Hook habe die Regeln schon geliefert.
        """
        quelle = self.tmp / "repo-datei.sh"
        ziel = self.tmp / "installiert.sh"
        quelle.write_text("neu\n", encoding="utf-8")
        ziel.write_text("alt\n", encoding="utf-8")
        code, text = self.lauf(installationen=[("Testkopie", quelle, ziel)])
        self.assertEqual(code, 1)
        self.assertIn("Testkopie", text)
        self.assertIn("weicht ab", text)

    def test_gleiche_installierte_kopie_ist_gruen(self):
        """Gegenprobe: ohne sie koennte der Vergleich immer rot melden."""
        quelle = self.tmp / "repo-datei.sh"
        ziel = self.tmp / "installiert.sh"
        quelle.write_text("gleich\n", encoding="utf-8")
        ziel.write_text("gleich\n", encoding="utf-8")
        code, text = self.lauf(installationen=[("Testkopie", quelle, ziel)])
        self.assertEqual(code, 0, text)
        self.assertIn("installiert = Repo", text)

    def test_fehlende_installierte_kopie_faellt_auf(self):
        quelle = self.tmp / "repo-datei.sh"
        quelle.write_text("neu\n", encoding="utf-8")
        code, _ = self.lauf(
            installationen=[("Testkopie", quelle, self.tmp / "gibtsnicht")])
        self.assertEqual(code, 1)

    def test_abgelaufene_frist_erscheint_als_hinweis_ohne_fehler(self):
        """Ein veralteter Regelinhalt ist kein Installationsfehler —
        der Exit-Code bleibt deshalb bewusst 0."""
        quelle = self.schreibe_regeln(
            "rules:\n  - id: Z-FRIST-001\n    domain: z\n    severity: 2\n"
            "    trigger: Der Vertragstermin 2020-01-01 ist zu beachten.\n"
            "    statement: Danach ist die Regel gegenstandslos.\n", "frist.yaml")
        ingest.run(source=quelle)
        code, text = self.lauf()
        self.assertEqual(code, 0)
        self.assertIn("Hinweise", text)
        self.assertIn("Z-FRIST-001", text)
        self.assertIn("2020-01-01", text)

    def test_ohne_abgelaufene_frist_kein_hinweisblock(self):
        code, text = self.lauf()
        self.assertEqual(code, 0)
        self.assertNotIn("Hinweise", text)

    def test_fehlende_quelldatei_wird_uebersprungen(self):
        """Kein Fehlalarm, wenn es die Repo-Seite gar nicht gibt."""
        code, text = self.lauf(
            installationen=[("Testkopie", self.tmp / "weg", self.tmp / "auch-weg")])
        self.assertEqual(code, 0)
        self.assertNotIn("Testkopie", text)

    def test_fehlender_index_zaehler_faellt_auf(self):
        conn = schema.connect(paths.db_path())
        conn.execute("DELETE FROM meta WHERE key='index_count'")
        conn.commit()
        conn.close()
        code, _ = self.lauf()
        self.assertEqual(code, 1)


class TestExportVerzug(TempDatenTest):
    """`export/` ist eine zweite Wahrheit, sobald es zurueckbleibt.

    Am 2026-08-07 stand die gestrichene WF-SESSION-001 noch im Pruef-Export —
    ein externer Pruefer haette eine Regel gelesen, die es nicht mehr gibt.
    Verglichen werden IDs, nicht Dateidaten: ein `git checkout` setzt alle
    mtimes neu und der Vergleich meldete dann Unsinn.
    """

    def setUp(self):
        super().setUp()
        ingest.run(source=self.schreibe_regeln(MINI))

    def export_schreiben(self, ids) -> None:
        self.datei = self.tmp / "regeln.yaml"
        self.datei.write_text(
            "rules:\n" + "".join(f"  - id: {i}\n    domain: x\n" for i in ids),
            encoding="utf-8")

    def test_deckungsgleicher_export_meldet_nichts(self):
        self.export_schreiben(["A-EINS-001", "A-ZWEI-001"])
        self.assertEqual(cli.export_verzug(paths.db_path(), self.datei),
                         (set(), set()))

    def test_regel_nur_noch_im_export_faellt_auf(self):
        self.export_schreiben(["A-EINS-001", "A-ZWEI-001", "WEG-001"])
        veraltet, fehlend = cli.export_verzug(paths.db_path(), self.datei)
        self.assertEqual(veraltet, {"WEG-001"})
        self.assertEqual(fehlend, set())

    def test_neue_regel_fehlt_im_export(self):
        self.export_schreiben(["A-EINS-001"])
        veraltet, fehlend = cli.export_verzug(paths.db_path(), self.datei)
        self.assertEqual(veraltet, set())
        self.assertEqual(fehlend, {"A-ZWEI-001"})

    def test_fehlender_export_ist_kein_befund(self):
        """Wer nie exportiert hat, hat auch keinen veralteten Export."""
        self.assertEqual(cli.export_verzug(paths.db_path(), self.tmp / "gibtsnicht"),
                         (set(), set()))

    def test_verzug_erscheint_im_doctor_ohne_den_exitcode_zu_kippen(self):
        """Ob ein Pruef-Export den Tagesstand hat, entscheidet der Owner."""
        self.export_schreiben(["A-EINS-001", "A-ZWEI-001", "WEG-001"])
        with unittest.mock.patch.object(cli, "export_verzug",
                                        return_value=({"WEG-001"}, set())):
            puffer = io.StringIO()
            with unittest.mock.patch.object(cli, "verdrahtung", return_value=[]), \
                    unittest.mock.patch.object(cli, "installationen", return_value=[]):
                with redirect_stdout(puffer):
                    code = cli.main(["doctor"])
        self.assertEqual(code, 0)
        self.assertIn("WEG-001", puffer.getvalue())
        self.assertIn("writ-light export", puffer.getvalue())


class TestInstallationen(unittest.TestCase):
    """Was `installationen()` selbst verantwortet — wirklich aufgerufen.

    `TestDoctor.lauf()` schaltet die Funktion stumm, und das ist richtig: sonst
    haengt jeder doctor-Test daran, ob der Wirkort dieses Laptops gerade
    synchron ist (er ist es waehrend jeder Aenderung nicht). Damit faellt aber
    die einzige Stelle weg, an der die Funktion ueberhaupt laeuft — und ihre
    gefaehrlichste Eigenschaft ist fail-open: `_cmd_doctor` ueberspringt jeden
    Eintrag, dessen REPO-Seite fehlt (`if not quelle.exists(): continue`).

    Genau das passiert bei einer Umbenennung, die `EINGEHAENGTE_HOOKS` nicht
    nachzieht: der Hook faellt lautlos aus der Pruefung, `doctor` meldet
    weiter [ok], und niemand erfaehrt, dass am Wirkort eine Fassung ohne die
    neuen Sperren liegt. Diese Tests brauchen keinen synchronen Wirkort — sie
    pruefen die Zuordnung, nicht den Kopiervorgang.
    """

    def test_jeder_eingehaengte_hook_hat_eine_ausfuehrbare_repo_datei(self):
        import os

        from writ_light import paths

        eintraege = cli.installationen()
        self.assertEqual(len(eintraege), len(cli.EINGEHAENGTE_HOOKS))
        for (ereignis, skript), (label, quelle, ziel) in zip(cli.EINGEHAENGTE_HOOKS,
                                                             eintraege):
            with self.subTest(hook=skript):
                self.assertEqual(quelle.name, skript)
                self.assertIn(ereignis, label)
                self.assertTrue(quelle.exists(),
                                f"{quelle} fehlt im Repo — `doctor` ueberspringt "
                                f"den Eintrag dann STILL")
                self.assertTrue(os.access(quelle, os.X_OK), f"{quelle} nicht ausfuehrbar")
                self.assertEqual(quelle.parent, paths.REPO_ROOT / "hooks")
                self.assertEqual(ziel, Path.home() / ".claude/hooks" / skript)

    def test_der_waechter_wird_unter_seinem_neuen_namen_gefuehrt(self):
        """Die Umbenennung vom 2026-08-08, an der Stelle, die sie verschlucken kann."""
        namen = {quelle.name for _, quelle, _ in cli.installationen()}
        self.assertIn("bash-guard.sh", namen)
        self.assertNotIn("git-add-guard.sh", namen)

    def test_die_liste_deckt_sich_mit_den_geprueften_ereignissen(self):
        """`installationen()` und `verdrahtung()` muessen dieselben Hooks meinen —
        sonst prueft die eine Haelfte eine Datei, die die andere nicht kennt."""
        aus_liste = [skript for _, skript in cli.EINGEHAENGTE_HOOKS]
        self.assertEqual([q.name for _, q, _ in cli.installationen()], aus_liste)


class TestRegelfreieStarts(TempDatenTest):
    """`claude-free` senkt die Schwelle — die Nutzung soll belegt sein.

    Ohne diese Zahl bliebe der Alias unbeobachtet: eine Session ohne Regelwerk
    sieht im Nachhinein aus wie jede andere. Gezaehlt wird das Protokoll, das
    `hooks/onboarding.sh` ohnehin schon schreibt; das Zusatzfeld `regeln=aus`
    haengt hinten an, damit die alten zweispaltigen Zeilen lesbar bleiben.
    """

    def protokoll(self, *zeilen: str) -> Path:
        p = self.tmp / "session-start.log"
        p.write_text("".join(z + "\n" for z in zeilen), encoding="utf-8")
        return p

    def tag(self, vor_tagen: int) -> str:
        import datetime

        d = datetime.date.fromisoformat(cli._heute()) - datetime.timedelta(days=vor_tagen)
        return f"{d.isoformat()}T09:00:00+02:00"

    def test_zaehlt_nur_die_regelfreien_starts(self):
        p = self.protokoll(f"{self.tag(1)}\tstartup",
                           f"{self.tag(1)}\tstartup\tregeln=aus",
                           f"{self.tag(2)}\tcompact\tregeln=aus")
        self.assertEqual(cli.regelfreie_starts(p), 2)

    def test_alte_zeilen_zaehlen_nicht_mehr(self):
        """30 Tage, nicht seit Anbeginn: eine Zahl, die nur waechst, sagt nichts."""
        p = self.protokoll(f"{self.tag(29)}\tstartup\tregeln=aus",
                           f"{self.tag(31)}\tstartup\tregeln=aus")
        self.assertEqual(cli.regelfreie_starts(p), 1)

    def test_kaputte_zeile_wirft_nicht(self):
        """`doctor` ist das Werkzeug, mit dem man Schaden ANSIEHT — es darf an
        einem halb geschriebenen Eintrag nicht selbst zerbrechen."""
        p = self.protokoll("kaputt", "", "\t\t", "keindatum\tstartup\tregeln=aus",
                           f"{self.tag(0)}\tstartup\tregeln=aus")
        self.assertEqual(cli.regelfreie_starts(p), 1)

    def test_leeres_und_fehlendes_protokoll_sind_null(self):
        self.assertEqual(cli.regelfreie_starts(self.protokoll()), 0)
        self.assertEqual(cli.regelfreie_starts(self.tmp / "gibtsnicht"), 0)

    def test_zeile_erscheint_in_der_doctor_ausgabe(self):
        """Eine Zahl, die niemand sieht, ist keine Messung."""
        puffer = io.StringIO()
        with unittest.mock.patch.object(cli, "regelfreie_starts", return_value=7), \
                unittest.mock.patch.object(cli, "verdrahtung", return_value=[]), \
                unittest.mock.patch.object(cli, "installationen", return_value=[]):
            with redirect_stdout(puffer):
                cli.main(["doctor"])
        text = puffer.getvalue()
        self.assertIn("Regelfreie Starts (letzte 30 Tage): 7", text)
        self.assertIn("claude-free", text)


class TestVerdrahtung(TempDatenTest):
    """Die andere Haelfte der Frage: wird das Installierte auch aufgerufen?

    `installationen()` vergleicht Dateien. Bis 2026-08-07 war das alles, was
    `doctor` prueft — und es meldete zweimal [ok] fuer ein Plugin, dessen
    Laufzeit die hooks.json nie geladen hat: beide Kopien identisch, beide
    wirkungslos. Diese Tests bauen ein Heimatverzeichnis nach, statt die
    Funktion wegzumocken; sonst prueft niemand sie selbst.
    """

    def heim_bauen(self, *, weglassen=(), ausfuehrbar=True) -> Path:
        """Ein vollstaendig verdrahtetes Heim — abzueglich `weglassen`.

        Die Hook-Liste kommt aus `cli.EINGEHAENGTE_HOOKS`, nicht aus einer
        Kopie hier: sonst prueft dieser Test nach dem naechsten neuen Hook
        eine Verdrahtung, die es so nicht mehr gibt.
        """
        import shutil

        heim = self.tmp / "heim"
        # Mehrfach aufrufbar: die Verdrahtungstests bauen je subTest neu.
        shutil.rmtree(heim, ignore_errors=True)
        (heim / ".claude/hooks").mkdir(parents=True)
        eintraege = {}
        for ereignis, skript in cli.EINGEHAENGTE_HOOKS:
            datei = heim / ".claude/hooks" / skript
            datei.write_text("#!/bin/sh\n", encoding="utf-8")
            datei.chmod(0o755 if ausfuehrbar else 0o644)
            if ereignis not in weglassen:
                eintraege[ereignis] = [{"hooks": [{"type": "command",
                                                   "command": str(datei)}]}]
        (heim / ".claude/settings.json").write_text(
            json.dumps({"hooks": eintraege}), encoding="utf-8")

        git_hooks = heim / ".config/git/hooks"
        git_hooks.mkdir(parents=True)
        for name in ("pre-push", "pre-commit"):
            p = git_hooks / name
            p.write_text("#!/bin/sh\n", encoding="utf-8")
            p.chmod(0o755)

        skills = heim / ".claude/skills"
        skills.mkdir(parents=True)
        for verzeichnis in (paths.REPO_ROOT / "skills").glob("*"):
            if verzeichnis.is_dir():
                (skills / verzeichnis.name).symlink_to(verzeichnis)
        return heim

    def pruefen(self, heim: Path, **kw) -> dict[str, tuple[bool, str]]:
        zeilen = cli.verdrahtung(heim=heim,
                                 git_hooks=kw.pop("git_hooks",
                                                  heim / ".config/git/hooks"),
                                 gitleaks_da=kw.pop("gitleaks_da", True))
        return {label: (ok, detail) for label, ok, detail in zeilen}

    def test_vollstaendige_verdrahtung_ist_durchweg_gruen(self):
        ergebnis = self.pruefen(self.heim_bauen())
        rot = {k: v for k, v in ergebnis.items() if not v[0]}
        self.assertEqual(rot, {})
        for ereignis, _ in cli.EINGEHAENGTE_HOOKS:
            self.assertIn(f"{ereignis} eingehaengt", ergebnis)
        self.assertIn("core.hooksPath gesetzt", ergebnis)

    def test_nicht_eingetragener_hook_faellt_auf(self):
        """Der Fall, den die Dateigleichheit nicht sieht: Datei da, nicht verdrahtet."""
        for ereignis, _ in cli.EINGEHAENGTE_HOOKS:
            with self.subTest(ereignis=ereignis):
                ergebnis = self.pruefen(self.heim_bauen(weglassen=(ereignis,)))
                ok, detail = ergebnis[f"{ereignis} eingehaengt"]
                self.assertFalse(ok)
                self.assertIn("settings.json", detail)
                # Die uebrigen bleiben gruen — der Befund ist nicht ansteckend.
                for anderes, _ in cli.EINGEHAENGTE_HOOKS:
                    if anderes != ereignis:
                        self.assertTrue(ergebnis[f"{anderes} eingehaengt"][0], anderes)

    def test_eingetragen_aber_nicht_ausfuehrbar_faellt_auf(self):
        ergebnis = self.pruefen(self.heim_bauen(ausfuehrbar=False))
        ok, detail = ergebnis["SessionStart eingehaengt"]
        self.assertFalse(ok)
        self.assertIn("nicht ausfuehrbar", detail)

    def test_kaputte_settings_json_meldet_alles_als_nicht_eingehaengt(self):
        heim = self.heim_bauen()
        (heim / ".claude/settings.json").write_text("{kein json", encoding="utf-8")
        ergebnis = self.pruefen(heim)
        self.assertFalse(ergebnis["SessionStart eingehaengt"][0])
        self.assertFalse(ergebnis["UserPromptSubmit eingehaengt"][0])

    def test_fehlender_hooks_pfad_faellt_auf(self):
        ergebnis = self.pruefen(self.heim_bauen(), git_hooks=None)
        ok, detail = ergebnis["core.hooksPath gesetzt"]
        self.assertFalse(ok)
        self.assertIn("git config --global", detail)

    def test_fehlender_git_hook_faellt_auf(self):
        heim = self.heim_bauen()
        (heim / ".config/git/hooks/pre-push").unlink()
        ergebnis = self.pruefen(heim)
        self.assertFalse(ergebnis["Git-Hook pre-push (ENF-GIT-002)"][0])
        self.assertTrue(ergebnis["Git-Hook pre-commit (ENF-SECRET-001)"][0])

    def test_fehlendes_gitleaks_faellt_auf(self):
        """pre-commit ueberspringt die Pruefung STILL — genau deshalb hier laut."""
        ergebnis = self.pruefen(self.heim_bauen(), gitleaks_da=False)
        label = "gitleaks vorhanden (sonst scannt pre-commit nichts)"
        self.assertFalse(ergebnis[label][0])

    def test_nicht_verlinkter_skill_faellt_auf(self):
        heim = self.heim_bauen()
        for link in (heim / ".claude/skills").iterdir():
            link.unlink()
            name = link.name
            break
        ergebnis = self.pruefen(heim)
        self.assertFalse(ergebnis[f"Skill {name} verlinkt"][0])

    def test_skill_link_auf_etwas_anderes_faellt_auf(self):
        """Ein Link, der irgendwohin zeigt, ist schlimmer als keiner."""
        heim = self.heim_bauen()
        link = next((heim / ".claude/skills").iterdir())
        name = link.name
        link.unlink()
        woanders = self.tmp / "woanders"
        woanders.mkdir()
        link.symlink_to(woanders)
        ergebnis = self.pruefen(heim)
        self.assertFalse(ergebnis[f"Skill {name} verlinkt"][0])


if __name__ == "__main__":
    unittest.main()
