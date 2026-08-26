"""`streich` — eine Regel abstufen oder entfernen. Ein Kommando, alle Schritte.

Streichen ist der Gegendruck zum Wachstum: ohne ihn reisst der Kern-Deckel beim
naechsten guten Einfall, und die naheliegende Reparatur waere, den Deckel zu
erhoehen. Damit Streichen wirklich benutzt wird, muss es EIN Handgriff sein —
vier Handgriffe (YAML, Register, Gold-Datei, Ingest) macht niemand vollstaendig,
und ein halb gestrichener Bestand ist schlimmer als ein voller: die Regel steht
dann noch in der Gold-Datei, aber nicht mehr im Werk.

Deshalb transaktional. Jede beruehrte Datei wird vorher gesichert und bei jedem
Fehler zurueckgerollt — auch beim Fehler des abschliessenden Ingests. Der haeufige
Fall ist real: `--nach geloescht` bei einer Regel, auf die noch eine Beziehung
zeigt, laesst den Ingest abbrechen. Danach muss der Bestand aussehen wie vorher.

Abgestuft heisst nicht geloescht: eine hinweis-Regel steht weiter im Werk, wird
aber in KEINER Zustellung ausgeliefert (nur ueber `query --auch-hinweise`).
`regeln/ABGESCHAFFT.md` ist append-only und wird nie zugestellt.
"""

from __future__ import annotations

import datetime
import re
from pathlib import Path

from . import fmpfade, ingest, schema, yamlio

KOPF_ABGESCHAFFT = """\
# Abgeschafft

Append-only. Was hier steht, gilt nicht mehr — diese Datei wird NIE zugestellt.
Sie beantwortet genau eine Frage: warum es die Regel nicht mehr gibt.
"""


class StreichFehler(Exception):
    pass


class Transaktion:
    """Alle beruehrten Dateien sichern, bei Fehler alles zurueckrollen.

    Bewusst im Speicher und nicht als Kopie daneben: die Dateien sind klein
    (Regelwerk, Register, Gold-Datei), und eine Sicherungskopie auf der Platte
    waere selbst wieder ein Zustand, der nach einem Absturz aufgeraeumt werden
    muss.
    """

    def __init__(self) -> None:
        self._vorher: dict[Path, str | None] = {}

    def schreibe(self, pfad: Path, inhalt: str) -> None:
        if pfad not in self._vorher:
            self._vorher[pfad] = pfad.read_text(encoding="utf-8") if pfad.exists() else None
        pfad.parent.mkdir(parents=True, exist_ok=True)
        pfad.write_text(inhalt, encoding="utf-8")

    def zuruecknehmen(self) -> None:
        for pfad, inhalt in self._vorher.items():
            if inhalt is None:
                pfad.unlink(missing_ok=True)
            else:
                pfad.write_text(inhalt, encoding="utf-8")
        self._vorher.clear()

    @property
    def dateien(self) -> list[Path]:
        return sorted(self._vorher)


def _heute() -> str:
    return datetime.date.today().isoformat()


def _kurzform(statement: str, laenge: int = 90) -> str:
    text = " ".join((statement or "").split())
    return text if len(text) <= laenge else text[: laenge - 1].rstrip() + "…"


def finde(regel_id: str, quelle: Path) -> tuple[Path, list[dict], dict]:
    """(Datei, alle Regeln dieser Datei, die gesuchte Regel)."""
    for pfad in ingest.regeldateien(quelle):
        regeln, _ = ingest.load_file(pfad)
        for r in regeln:
            if r["id"] == regel_id:
                return pfad, regeln, r
    raise StreichFehler(
        f"Regel {regel_id} steht in keiner Datei unter {quelle} — Tippfehler, oder "
        f"sie ist bereits gestrichen (siehe {fmpfade.abgeschafft_datei()})")


def _eintrag(regel: dict, grund: str, nach: str) -> str:
    anker = ", ".join(yamlio.anker_liste(regel.get("anker"))) or "—"
    zusatz = "" if nach == "hinweis" else " [geloescht]"
    return (f"- {_heute()} {regel['id']} - {_kurzform(regel['statement'])} "
            f"(Anker: {anker}; Grund: {grund}){zusatz}\n")


def _golden_ohne(text: str, regel_id: str) -> str:
    """Zeilen der Gold-Datei entfernen, die diese Regel-ID nennen.

    Ueber Wortgrenzen statt ueber Spaltenpositionen: das TSV-Format der
    Gold-Datei gehoert dem Retrieval-Pruefstand, nicht diesem Kommando. Wer
    hier Spalten annimmt, bricht beim naechsten zusaetzlichen Feld — und zwar
    lautlos, indem er nichts mehr findet.
    """
    muster = re.compile(rf"(?<![\w-]){re.escape(regel_id)}(?![\w-])")
    behalten = [z for z in text.splitlines(keepends=True) if not muster.search(z)]
    return "".join(behalten)


def streiche(regel_id: str, grund: str, nach: str = "hinweis",
             quelle: Path | None = None, db: Path | None = None,
             mit_index: bool = True) -> dict:
    """Abstufen (oder entfernen), eintragen, Gold-Datei saeubern, ingesten."""
    if not (grund or "").strip():
        raise StreichFehler(
            "--grund fehlt. Eine Streichung ohne Grund ist in einem halben Jahr "
            "nicht mehr von einem Versehen zu unterscheiden.")
    if nach not in schema.STREICH_ZIELE:
        raise StreichFehler(
            f"--nach {nach!r} unbekannt — erlaubt: {', '.join(schema.STREICH_ZIELE)}")

    quelle = quelle or fmpfade.regeln_dir()
    pfad, regeln, regel = finde(regel_id, quelle)
    if regel["verbindlichkeit"] == "hinweis" and nach == "hinweis":
        raise StreichFehler(
            f"{regel_id} ist bereits auf hinweis abgestuft — nichts zu tun. "
            f"Zum Entfernen: --nach geloescht")

    eintrag = _eintrag(regel, grund.strip(), nach)
    tx = Transaktion()
    try:
        if nach == "hinweis":
            regel["verbindlichkeit"] = "hinweis"
            regel["status"] = "hinweis-abgestuft"
            regel["mandatory"] = 0
            bleibt = regeln
        else:
            bleibt = [r for r in regeln if r["id"] != regel_id]

        projekt = next((r.get("project") for r in bleibt if r.get("project")), None)
        tx.schreibe(pfad, yamlio.datei_inhalt(pfad, bleibt, projekt))

        register = fmpfade.abgeschafft_datei()
        alt = register.read_text(encoding="utf-8") if register.exists() else KOPF_ABGESCHAFFT
        tx.schreibe(register, alt.rstrip("\n") + "\n" + eintrag)

        gold = fmpfade.golden_tsv()
        if gold.exists():
            tx.schreibe(gold, _golden_ohne(gold.read_text(encoding="utf-8"), regel_id))

        stat = ingest.run(source=quelle, db=db, mit_index=mit_index)
    except Exception as exc:
        tx.zuruecknehmen()
        raise StreichFehler(
            f"Streichung von {regel_id} zurueckgenommen, es wurde nichts geaendert: {exc}"
        ) from exc

    return {
        "id": regel_id,
        "nach": nach,
        "datei": pfad,
        "register": fmpfade.abgeschafft_datei(),
        "eintrag": eintrag.rstrip("\n"),
        "dateien": tx.dateien,
        "ingest": stat,
    }
