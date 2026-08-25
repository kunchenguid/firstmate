"""writ-light — Kommandozeile."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import paths


def _cmd_ingest(args) -> int:
    from . import ingest

    quelle = Path(args.quelle).expanduser() if args.quelle else paths.rules_dir()
    stat = ingest.run(source=quelle)
    print(f"Quelle:       {quelle}")
    print(f"Regeln:       {stat['regeln']}  (davon mandatory: {stat['mandatory']})")
    print(f"Beziehungen:  {stat['beziehungen']}")
    print(f"Projekte:     {stat['projekte']}")
    print(f"Vektoren:     {stat['indexiert']}")
    print(f"Datenbank:    {stat['db']}")
    print(f"Index:        {stat['index']}")
    return 0


def _cmd_session_start(args) -> int:
    from . import hooks

    text = hooks.session_start()
    print(hooks.als_json(text) if args.json else text)
    return 0


def _cmd_prompt_regeln(args) -> int:
    """UserPromptSubmit: Hook-JSON von stdin, Regelblock auf stdout."""
    from . import hooks

    prompt, cwd = hooks.eingabe_lesen(sys.stdin.read())
    if not prompt.strip():
        return 0
    text = hooks.prompt_regeln(prompt, cwd=cwd, budget=args.budget)
    print(hooks.als_json(text, "UserPromptSubmit") if args.json else text)
    return 0


def _cmd_query(args) -> int:
    from . import render, retrieve

    ergebnis = retrieve.query(
        args.prompt,
        budget_tokens=args.budget,
        projekt=args.projekt,
        mit_claw=args.rolle == "claw",
        limit=args.limit,
    )
    if args.erklaeren:
        print(render.erklaerung(ergebnis))
    else:
        print(render.block(ergebnis))
    return 0


def _cmd_memory(args) -> int:
    from . import memory

    if args.memory_befehl == "add":
        mid = memory.add(args.text, projekt=args.projekt)
        print(f"Memory #{mid} gespeichert.")
        return 0
    if args.memory_befehl == "reindex":
        stat = memory.reindex()
        print(f"Memory-Index neu gebaut: {stat['eintraege']} Eintraege")
        print(f"Index: {stat['index']}")
        return 0
    if args.memory_befehl == "query":
        treffer = memory.query(args.prompt, limit=args.limit, projekt=args.projekt)
        if not treffer:
            print("(keine passenden Memory-Eintraege)")
            return 0
        for t in treffer:
            print(f"[#{t['id']} {t['created']} dist={t['distanz']:.3f}] {t['text']}")
        return 0
    # list
    eintraege = memory.latest(limit=args.limit, projekt=args.projekt)
    if not eintraege:
        print("(keine Memory-Eintraege)")
        return 0
    for e in eintraege:
        print(f"[#{e['id']} {e['created']}] {e['text']}")
    return 0


def _cmd_modell(args) -> int:
    from . import embed

    ziel = embed.download_model(quantized=not args.fp32)
    print(f"Modell unter: {ziel}")
    print(f"Aktiv:        {embed.model_file().name}")
    return 0


def _cmd_schreibweise(args) -> int:
    """ae/oe/ue in den Anzeigetexten der Regeldateien zu Umlauten."""
    import difflib

    from . import schreibweise

    dateien = sorted(paths.rules_dir().rglob("*.yaml"))
    geaendert, offen = [], set()
    for pfad in dateien:
        alt = pfad.read_text(encoding="utf-8")
        neu = schreibweise.umschreiben(alt)
        offen |= schreibweise.offene_kandidaten(neu)
        if alt == neu:
            continue
        zeilen = sum(1 for z in difflib.unified_diff(
            alt.split("\n"), neu.split("\n"), lineterm="", n=0) if z.startswith("+")
            and not z.startswith("+++"))
        geaendert.append((pfad, zeilen))
        if args.anwenden:
            pfad.write_text(neu, encoding="utf-8")
        elif args.diff:
            for z in difflib.unified_diff(alt.split("\n"), neu.split("\n"),
                                          fromfile=str(pfad), tofile=str(pfad),
                                          lineterm="", n=0):
                print(z)

    print(f"{'Geaendert' if args.anwenden else 'Zu aendern'}: "
          f"{len(geaendert)} von {len(dateien)} Dateien")
    for pfad, n in geaendert:
        print(f"  {pfad.relative_to(paths.REPO_ROOT)}  {n} Zeilen")
    if offen:
        print(f"\nWeder ersetzt noch als Ausnahme gefuehrt ({len(offen)}) — "
              f"beim naechsten Durchgang entscheiden:")
        print("  " + ", ".join(sorted(offen)))
    if args.anwenden:
        print("\nJetzt `writ-light ingest` ausfuehren.")
    return 0


def _cmd_export(args) -> int:
    from . import export

    ziel = Path(args.ziel).expanduser() if args.ziel else paths.REPO_ROOT / "export"
    stat = export.schreiben(ziel, stand=args.stand or _heute())
    print(f"Verzeichnis:  {stat['ziel']}")
    print(f"Regeln:       {stat['regeln']}")
    print(f"Beziehungen:  {stat['beziehungen']}  in {stat['ketten']} Ketten")
    print(f"Dateien:      {', '.join(stat['dateien'])}")
    return 0


def _heute() -> str:
    import datetime

    return datetime.date.today().isoformat()


def _cmd_ui(args) -> int:
    import webbrowser

    from . import ui

    server = ui.starten(port=args.port)
    adresse = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"Regelregister: {adresse}")
    print("Nur localhost, kein Daemon — mit Strg-C beenden.")
    if not args.kein_browser:
        webbrowser.open(adresse)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbeendet")
    finally:
        server.server_close()
    return 0


def _cmd_doctor(args) -> int:
    from . import embed, schema

    ok = True

    def pruefe(label: str, bedingung: bool, detail: str = "") -> None:
        nonlocal ok
        ok = ok and bedingung
        print(f"  [{'ok ' if bedingung else 'FEHLT'}] {label}{'  ' + detail if detail else ''}")

    print("writ-light doctor")
    print(f"  Python:     {sys.version.split()[0]} ({sys.executable})")
    for modul in ("hnswlib", "onnxruntime", "tokenizers", "numpy", "yaml"):
        try:
            __import__(modul)
            pruefe(f"Modul {modul}", True)
        except ImportError as exc:
            pruefe(f"Modul {modul}", False, str(exc))

    mf, tf = embed.model_file(), embed.tokenizer_file()
    pruefe("Modell", mf.exists(), f"{mf} ({mf.stat().st_size / 1e6:.0f} MB)" if mf.exists() else str(mf))
    pruefe("Tokenizer", tf.exists(), str(tf))

    db = paths.db_path()
    pruefe("Datenbank", db.exists(), str(db))
    idx = paths.index_path()
    if db.exists():
        conn = schema.connect(db)
        try:
            n = conn.execute("SELECT count(*) FROM rules").fetchone()[0]
            m = conn.execute("SELECT count(*) FROM rules WHERE mandatory=1").fetchone()[0]
            pruefe("Regeln in der DB", n > 0, f"{n} Regeln, {m} mandatory")
            # `ingest` ersetzt erst die Datenbank und baut danach den Index —
            # ohne umspannende Transaktion. Bricht es dazwischen ab, steht eine
            # heile Datenbank neben einem veralteten Index, und die Vektorsuche
            # liefert stumm zu wenig. Genau die Sorte Fehler, die RAG-STILL-001
            # meint: "leer" und "kaputt" muessen unterscheidbar bleiben.
            row = conn.execute("SELECT value FROM meta WHERE key='index_count'").fetchone()
            indiziert = int(row["value"]) if row else -1
            pruefe("Index deckt die Regeln ab", indiziert == n,
                   f"{indiziert} indiziert gegen {n} Regeln"
                   + ("" if indiziert == n else "  -> `writ-light ingest` erneut laufen lassen"))

            # Regeln zu loeschen ist ein realer Pfad (Weboberflaeche, YAML-Bearbeitung).
            # Bleibt dabei eine Beziehung auf die geloeschte Regel stehen, faellt das
            # nirgends auf: die 1-Hop-Expansion findet den Nachbarn einfach nicht und
            # liefert stumm weniger. Gleiche Klasse wie der index_count-Befund.
            haengend = conn.execute(
                "SELECT rel.src, rel.kind, rel.dst FROM relations rel "
                "LEFT JOIN rules d ON d.id = rel.dst "
                "LEFT JOIN rules s ON s.id = rel.src "
                "WHERE d.id IS NULL OR s.id IS NULL ORDER BY rel.src, rel.dst").fetchall()
            pruefe("Beziehungen zeigen auf vorhandene Regeln", not haengend,
                   f"{len(haengend)} haengend" if haengend
                   else f"{conn.execute('SELECT count(*) FROM relations').fetchone()[0]} Beziehungen")
            for h in haengend[:10]:
                print(f"         {h['src']} -{h['kind']}-> {h['dst']}")
            if len(haengend) > 10:
                print(f"         … und {len(haengend) - 10} weitere")

            # Memory-Tabelle wird erst beim ersten memory-Aufruf angelegt
            # (memory.connect) — bei einem Bestand, der noch keinen Eintrag
            # hat, ist ihr Fehlen also kein Fehler. Gleiche Unterscheidung
            # wie oben: "leer" und "kaputt" muessen trennbar bleiben.
            tabellen = {r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            if "memory" in tabellen:
                mem_n = conn.execute("SELECT count(*) FROM memory").fetchone()[0]
                row = conn.execute(
                    "SELECT value FROM meta WHERE key='memory_index_count'").fetchone()
                mem_idx = int(row["value"]) if row else -1
                pruefe("Memory-Index deckt die Eintraege ab",
                       mem_n == 0 or mem_idx == mem_n,
                       f"{mem_idx} indiziert gegen {mem_n} Eintraege"
                       + ("" if mem_idx == mem_n or mem_n == 0
                          else "  -> naechstes `memory add` repariert den Zaehler nicht; Index pruefen"))
        finally:
            conn.close()
    pruefe("Vektorindex", idx.exists(), str(idx))
    pruefe("Weboberflaeche", paths.ui_html().exists(), str(paths.ui_html()))

    # Die Hook-Skripte liegen zweimal: versioniert im Repo und installiert an
    # ihrem Wirkort. Laufen die auseinander, wirkt eine Fassung, die niemand
    # geprueft hat — genau so trug ein installiertes Plugin einmal eine
    # veraltete SKILL.md, die behauptete, ein Hook habe die Regeln schon geliefert.
    for label, quelle, ziel in installationen():
        if not quelle.exists():
            continue
        pruefe(label, ziel.exists() and _gleich(quelle, ziel),
               "installiert = Repo" if ziel.exists() and _gleich(quelle, ziel)
               else f"{ziel} weicht ab oder fehlt  -> neu installieren")

    # Und die andere Haelfte derselben Frage: wird das Installierte auch
    # aufgerufen? Siehe die Begruendung an `verdrahtung()`.
    for label, zustand, detail in verdrahtung():
        pruefe(label, zustand, detail)

    print("\nErgebnis:", "einsatzbereit" if ok else "NICHT einsatzbereit")

    # Hinweise betreffen den INHALT des Regelwerks, nicht die Installation.
    # Sie aendern den Exit-Code deshalb bewusst nicht: `doctor` beantwortet
    # "laeuft das Werkzeug", nicht "ist jede Regel noch aktuell".
    for zeile in _hinweise(db):
        print(zeile)

    veraltet, fehlend = export_verzug(db)
    if veraltet or fehlend:
        print("\nHinweis: export/ deckt sich nicht mit dem Regelwerk.")
        if veraltet:
            print(f"  {len(veraltet)} Regel(n) nur noch im Export: "
                  + ", ".join(sorted(veraltet)[:5])
                  + (" …" if len(veraltet) > 5 else ""))
        if fehlend:
            print(f"  {len(fehlend)} Regel(n) fehlen im Export: "
                  + ", ".join(sorted(fehlend)[:5])
                  + (" …" if len(fehlend) > 5 else ""))
        print("  -> `writ-light export`, falls der Pruefstand aktuell sein soll")

    # Kein Fehler, ein Hinweis: der Alias `claude-free` senkt die Schwelle,
    # eine Session ohne Regelwerk zu starten. Wie oft das passiert, soll
    # belegt sein statt gefuehlt — deshalb steht die Zahl hier und nicht in
    # der Erinnerung des Owners. Der Exit-Code bleibt davon unberuehrt.
    print(f"\nRegelfreie Starts (letzte 30 Tage): {regelfreie_starts()}"
          "  — Sessions mit WRIT_RULES=aus (Alias `claude-free`)")
    return 0 if ok else 1


def regelfreie_starts(protokoll: Path | None = None, tage: int = 30) -> int:
    """Wie oft in den letzten `tage` Tagen eine Session ohne Regelwerk startete.

    Gezaehlt wird das Protokoll, das `hooks/onboarding.sh` bei JEDEM
    Session-Start fortschreibt: `<zeit>\\t<quelle>` und, wenn `WRIT_RULES` aus
    war, zusaetzlich `regeln=aus`. Das Zusatzfeld haengt hinten an, damit
    aeltere Zeilen weiter lesbar bleiben.

    Der Pfad ist ein Parameter, damit ein Test ein eigenes Protokoll
    unterschieben kann (wie bei `export_verzug`) — sonst waere die Funktion
    nur gegen den echten Rechner pruefbar, und ein Test, der vom Zustand
    dieses Laptops abhaengt, prueft an manchen Tagen etwas anderes als heute.

    Der Standardpfad kommt aus `paths.data_dir()`; das Shell-Skript schreibt
    fest nach `$HOME/.local/share/writ-light`, weil es ohne Python auskommen
    muss. Ohne gesetztes XDG_DATA_HOME ist das dieselbe Datei.

    Kaputte Zeilen werden uebersprungen, nicht geworfen: ein halb geschriebener
    Eintrag (paralleler Session-Start, volle Platte) darf `doctor` nicht
    umbringen — `doctor` ist das Werkzeug, mit dem man Schaden ANSIEHT.
    """
    import datetime

    protokoll = protokoll or paths.data_dir() / "session-start.log"
    try:
        text = protokoll.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0
    grenze = datetime.date.fromisoformat(_heute()) - datetime.timedelta(days=tage)
    treffer = 0
    for zeile in text.splitlines():
        felder = zeile.split("\t")
        if "regeln=aus" not in felder[1:]:
            continue
        try:
            tag = datetime.date.fromisoformat(felder[0][:10])
        except ValueError:
            continue
        if tag >= grenze:
            treffer += 1
    return treffer


def _hinweise(db: Path) -> list[str]:
    if not db.exists():
        return []
    from . import export

    try:
        regeln, _ = export.bestand(db)
    except Exception:
        return []
    abgelaufen = export.abgelaufene_daten(regeln, _heute())
    if not abgelaufen:
        return []
    zeilen = ["", "Hinweise (kein Fehler, aber pruefenswert):",
              f"  {len(abgelaufen)} Regel(n) nennen eine Frist in der Vergangenheit —",
              "  moeglicherweise seitdem gegenstandslos:"]
    for rid, datum, kontext in abgelaufen:
        zeilen.append(f"    {rid} ({datum}): …{kontext.strip()}…")
    return zeilen


def export_verzug(db: Path, export_datei: Path | None = None) -> tuple[set, set]:
    """(nur im Export, nur im Bestand) — verglichen werden Regel-IDs, nicht mtimes.

    `export/` ist ein erzeugtes Verzeichnis fuer die externe Pruefung. Wird es
    nach einer Regelaenderung nicht neu gebaut, liest ein Pruefer Regeln, die
    es nicht mehr gibt — genau die zweite Wahrheit, gegen die das uebrige
    Aufraeumen sich richtet. Am 2026-08-07 stand die gestrichene
    WF-SESSION-001 noch im Export.

    Ueber IDs statt Dateidatum, weil ein `git checkout` alle mtimes neu setzt
    und der Vergleich dann Unsinn meldet. Bewusst nur ein HINWEIS: ob ein
    Pruef-Export den Tagesstand haben muss, entscheidet der Owner, nicht
    `doctor`.
    """
    import re

    from . import schema

    export_datei = export_datei or paths.REPO_ROOT / "export" / "regeln.yaml"
    if not export_datei.exists() or not db.exists():
        return set(), set()
    try:
        im_export = set(re.findall(r"^  - id: (\S+)",
                                   export_datei.read_text(encoding="utf-8"),
                                   re.MULTILINE))
    except OSError:
        return set(), set()
    conn = schema.connect(db)
    try:
        im_bestand = {r["id"] for r in conn.execute("SELECT id FROM rules")}
    finally:
        conn.close()
    return im_export - im_bestand, im_bestand - im_export


def installationen() -> list[tuple[str, Path, Path]]:
    """Was doppelt liegt: versioniert im Repo und installiert am Wirkort."""
    heim = Path.home()
    # Aus derselben Liste wie die Verdrahtungspruefung: ein Hook, der
    # eingehaengt, aber am Wirkort veraltet ist, faellt sonst durch beide
    # Raster. Genau so trug ein installiertes Plugin einmal eine SKILL.md,
    # die etwas behauptete, was der Repo-Stand laengst widerlegt hatte.
    return [(f"Claude-Hook {ereignis}",
             paths.REPO_ROOT / "hooks" / skript,
             heim / ".claude/hooks" / skript)
            for ereignis, skript in EINGEHAENGTE_HOOKS]


def _gleich(a: Path, b: Path) -> bool:
    try:
        return a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def _eingetragene_hooks(settings: Path) -> dict[str, list[str]]:
    """Welche Kommandos haengen in settings.json an welchem Ereignis.

    Fehlt oder bricht die Datei, kommt ein leeres Dict zurueck — dann meldet
    `verdrahtung()` schlicht alles als fehlend, was richtig ist: eine
    unlesbare settings.json haengt genau null Hooks ein.
    """
    import json

    try:
        daten = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    heraus: dict[str, list[str]] = {}
    for ereignis, gruppen in (daten.get("hooks") or {}).items():
        for gruppe in gruppen or []:
            for h in (gruppe or {}).get("hooks") or []:
                if h.get("command"):
                    heraus.setdefault(ereignis, []).append(str(h["command"]))
    return heraus


def _ausfuehrbar(p: Path) -> bool:
    return p.is_file() and os.access(p, os.X_OK)


# Was in ~/.claude/settings.json eingetragen sein MUSS, damit das Regelwerk
# wirkt. Die Liste steht hier und nicht verstreut im Code, weil jeder neue Hook
# sonst installiert, aber ungeprueft bliebe — genau die Luecke, wegen der ein
# totes Plugin jahrelang [ok] meldete.
EINGEHAENGTE_HOOKS = (
    ("SessionStart", "onboarding.sh"),
    ("UserPromptSubmit", "prompt-regeln.sh"),
    # Hiess bis 2026-08-08 git-add-guard.sh und bewacht seitdem zwei Dinge.
    # Der Eintrag zieht MIT der Umbenennung um, obwohl der Wirkort noch die
    # alte Datei traegt: sonst faende `installationen()` die Repo-Seite nicht
    # (`quelle.exists()` -> continue) und der Waechter fiele lautlos aus
    # `doctor` heraus. Ein rotes `doctor` ist hier die richtige Antwort — die
    # Installation steht wirklich aus.
    ("PreToolUse", "bash-guard.sh"),
    ("SessionEnd", "prozess-ledger.sh"),
)


# "nicht uebergeben" muss von "nicht gesetzt" unterscheidbar sein. Mit None fuer
# beides fiele `verdrahtung(git_hooks=None)` auf die echte Git-Konfiguration des
# Laptops zurueck — der Aufrufer koennte den Fall "core.hooksPath fehlt" gar
# nicht ausdruecken, und ein Test mit nachgebautem Heim laese still am System mit.
_ERMITTELN = object()


def verdrahtung(heim: Path | None = None, git_hooks=_ERMITTELN,
                gitleaks_da: bool | None = None) -> list[tuple[str, bool, str]]:
    """Ist das Regelwerk tatsaechlich angeschlossen? — je Zeile (Label, ok, Detail).

    `installationen()` beantwortet eine andere Frage: "liegt am Wirkort
    dieselbe Datei wie im Repo". Das ist nicht dasselbe wie "wird sie
    aufgerufen". Bis 2026-08-07 prueft `doctor` ausschliesslich das erste und
    meldete deshalb zweimal [ok] fuer ein Plugin, dessen Laufzeit die
    hooks.json nie geladen hat — beide Kopien identisch, beide wirkungslos.
    Ein Hook, den niemand eintraegt, ist eine Datei mit Ausfuehrungsrecht und
    sonst nichts.

    Die drei Parameter existieren fuer die Tests: so laesst sich eine
    vollstaendige Umgebung in einem Temp-Verzeichnis nachbauen, statt die
    Funktion beim Pruefen wegzumocken (dann prueft niemand sie selbst).
    """
    heim = heim or Path.home()
    if git_hooks is _ERMITTELN:
        git_hooks = _git_hooks_pfad()
    gitleaks_pfad = shutil.which("gitleaks")
    if gitleaks_da is None:
        gitleaks_da = gitleaks_pfad is not None

    eingetragen = _eingetragene_hooks(heim / ".claude/settings.json")
    zeilen: list[tuple[str, bool, str]] = []

    for ereignis, skript in EINGEHAENGTE_HOOKS:
        ziel = heim / ".claude/hooks" / skript
        genannt = [b for b in eingetragen.get(ereignis, []) if skript in b]
        if not genannt:
            zeilen.append((f"{ereignis} eingehaengt", False,
                           f"kein Hook mit {skript} in {heim}/.claude/settings.json"
                           "  -> hooks/settings-snippet.json eintragen"))
        elif not _ausfuehrbar(ziel):
            zeilen.append((f"{ereignis} eingehaengt", False,
                           f"eingetragen, aber {ziel} fehlt oder ist nicht ausfuehrbar"))
        else:
            zeilen.append((f"{ereignis} eingehaengt", True, str(ziel)))

    # Die beiden Git-Hooks sind die mechanische Seite von ENF-GIT-002 und
    # ENF-SECRET-001. Ohne core.hooksPath liegen sie da und gelten fuer nichts.
    erwartet = heim / ".config/git/hooks"
    zeilen.append(("core.hooksPath gesetzt", git_hooks == erwartet,
                   str(git_hooks) if git_hooks
                   else "nicht gesetzt  -> git config --global core.hooksPath "
                        f"{erwartet}"))
    for name, regel in (("pre-push", "ENF-GIT-002"), ("pre-commit", "ENF-SECRET-001")):
        p = (git_hooks or erwartet) / name
        zeilen.append((f"Git-Hook {name} ({regel})", _ausfuehrbar(p),
                       str(p) if _ausfuehrbar(p) else f"{p} fehlt oder nicht ausfuehrbar"))

    # pre-commit ueberspringt die Pruefung STILL, wenn gitleaks fehlt (bewusst:
    # ein fehlendes Werkzeug soll keinen Commit blockieren). Damit ist das
    # fehlende Binary ein lautloser Verlust des Secret-Scans — genau die Sorte
    # Ausfall, die `doctor` sichtbar machen muss.
    zeilen.append(("gitleaks vorhanden (sonst scannt pre-commit nichts)", gitleaks_da,
                   (gitleaks_pfad or "?") if gitleaks_da
                   else "nicht im PATH  -> hooks/git/README.md"))

    for verzeichnis in sorted(p for p in (paths.REPO_ROOT / "skills").glob("*")
                              if p.is_dir()):
        link = heim / ".claude/skills" / verzeichnis.name
        gelinkt = link.exists() and link.resolve() == verzeichnis.resolve()
        zeilen.append((f"Skill {verzeichnis.name} verlinkt", gelinkt,
                       str(link) if gelinkt
                       else f"{link} fehlt oder zeigt woandershin"
                            f"  -> ln -s {verzeichnis} {link}"))

    return zeilen


def _git_hooks_pfad() -> Path | None:
    try:
        aus = subprocess.run(["git", "config", "--global", "--get", "core.hooksPath"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    pfad = aus.stdout.strip()
    return Path(pfad).expanduser() if pfad else None


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="writ-light",
        description="Regel-Retrieval: relevante Regeln pro Prompt statt Context-Stuffing.",
    )
    sub = p.add_subparsers(dest="befehl", required=True)

    pi = sub.add_parser("ingest", help="YAML-Regeln in SQLite + Vektorindex ueberfuehren")
    pi.add_argument("quelle", nargs="?", help="Verzeichnis oder Datei (Standard: rules/)")
    pi.set_defaults(func=_cmd_ingest)

    ps = sub.add_parser("session-start", help="Verbindliche Regeln fuer den Session-Start")
    ps.add_argument("--json", action="store_true", help="als Hook-Umschlag ausgeben")
    ps.set_defaults(func=_cmd_session_start)

    pp = sub.add_parser("prompt-regeln",
                        help="UserPromptSubmit: Hook-JSON von stdin, Regelblock auf stdout")
    pp.add_argument("--budget", type=int, default=2000)
    pp.add_argument("--json", action="store_true", help="als Hook-Umschlag ausgeben")
    pp.set_defaults(func=_cmd_prompt_regeln)

    pq = sub.add_parser("query", help="Gerankte Regeln zu einem Prompt")
    pq.add_argument("prompt")
    pq.add_argument("--budget", type=int, default=2000, help="Token-Budget (Standard 2000)")
    pq.add_argument("--projekt", help="Projektbindung erzwingen (sonst aus dem cwd)")
    pq.add_argument("--rolle", choices=["session", "claw"], default="session",
                    help="claw = Regeln der Domain claw-rolle mit ausgeben")
    pq.add_argument("--limit", type=int, help="hoechstens n gerankte Regeln")
    pq.add_argument("--erklaeren", action="store_true", help="Ranking-Diagnose statt Regelblock")
    pq.set_defaults(func=_cmd_query)

    pmem = sub.add_parser("memory",
                          help="Session-uebergreifendes Memory (kuratierte Fakten/Entscheidungen)")
    memsub = pmem.add_subparsers(dest="memory_befehl", required=True)
    pma = memsub.add_parser("add", help="Eintrag speichern (projektgebunden, append-only)")
    pma.add_argument("text")
    pma.add_argument("--projekt", help="Projektbindung erzwingen (sonst aus dem cwd)")
    pmq = memsub.add_parser("query", help="Semantisch passende Eintraege finden")
    pmq.add_argument("prompt")
    pmq.add_argument("--limit", type=int, default=3)
    pmq.add_argument("--projekt", help="Projektbindung erzwingen (sonst aus dem cwd)")
    pml = memsub.add_parser("list", help="Juengste Eintraege zeigen")
    pml.add_argument("--limit", type=int, default=10)
    pml.add_argument("--projekt", help="Projektbindung erzwingen (sonst aus dem cwd)")
    memsub.add_parser("reindex",
                      help="Vektorindex neu bauen — Gegenmittel zum doctor-Befund")
    pmem.set_defaults(func=_cmd_memory)

    pm = sub.add_parser("modell-laden", help="Embedding-Modell herunterladen")
    pm.add_argument("--fp32", action="store_true", help="unquantisiertes Modell (470 MB)")
    pm.set_defaults(func=_cmd_modell)

    psw = sub.add_parser("schreibweise",
                         help="ae/oe/ue in den Regeltexten zu Umlauten (Standard: nur zeigen)")
    psw.add_argument("--anwenden", action="store_true", help="Aenderungen schreiben")
    psw.add_argument("--diff", action="store_true", help="vollstaendigen Diff ausgeben")
    psw.set_defaults(func=_cmd_schreibweise)

    pe = sub.add_parser("export", help="Regelwerk fuer eine externe Pruefung ausgeben")
    pe.add_argument("ziel", nargs="?", help="Zielverzeichnis (Standard: export/ im Repo)")
    pe.add_argument("--stand", help="Datumsangabe im Export (Standard: heute)")
    pe.set_defaults(func=_cmd_export)

    pu = sub.add_parser("ui", help="Regelregister im Browser (nur localhost)")
    pu.add_argument("--port", type=int, help="fester Port (Standard: ab 8731 der erste freie)")
    pu.add_argument("--kein-browser", action="store_true", dest="kein_browser",
                    help="Browser nicht automatisch oeffnen")
    pu.set_defaults(func=_cmd_ui)

    pd = sub.add_parser("doctor", help="Installation pruefen")
    pd.set_defaults(func=_cmd_doctor)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
