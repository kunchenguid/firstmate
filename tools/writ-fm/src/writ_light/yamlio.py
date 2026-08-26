"""YAML-Rueckschreibung fuer Aenderungen aus der Weboberflaeche.

Ohne sie wuerde der naechste `writ-light ingest` jede Bearbeitung im
Regelregister wieder ueberschreiben — die Datenbank ist ein Aufbau aus
`rules/`, nicht die Quelle.

Das Ausgabeformat entspricht `toYaml()` in `ui/regelregister.html`, damit
Export aus der Oberflaeche und Rueckschreibung dieselbe Datei ergeben.

Der Kopf jeder Datei (alles vor der Zeile `rules:`) bleibt ERHALTEN. Dort
stehen Quellenangabe und die nach Akzeptanz 2 geforderte Notiz, was nicht
als Regel modelliert wurde — regenerierter YAML-Code wuerde beides loeschen.
"""

from __future__ import annotations

import re
from pathlib import Path

from . import paths, schema

# Die gelieferte Gold-Datei wird nicht zurueckgeschrieben: sie traegt
# Abschnittskommentare ZWISCHEN den Regeln, die kein Emitter reproduziert,
# und der Auftrag sagt zu ihr "direkt ingesten, NICHT neu konvertieren".
GESCHUETZT = frozenset({"rules/onboarding.yaml"})

UI_DATEI = "rules/ui-neu.yaml"

SONDERZEICHEN = re.compile(r"""[:#\[\]{}&*!|>'"%@`]""")


def skalar(wert) -> str:
    """YAML-Skalar wie `yStr()` in der Weboberflaeche."""
    s = "" if wert is None else str(wert)
    if s == "":
        return '""'
    if "\n" in s:
        return ">\n      " + s.replace("\n", "\n      ")
    if SONDERZEICHEN.search(s) or s != s.strip():
        return "'" + s.replace("'", "''") + "'"
    return s


# Anker kommen als Liste (Ingest) oder als Zeile (Datenbank) an. Die Lesart
# gehoert zur Spalte und steht deshalb in `schema`; hier nur der gewohnte Name.
anker_liste = schema.anker_liste


def regel_block(r: dict, mit_herkunft: bool = False) -> str:
    """YAML-Block einer Regel.

    `mit_herkunft` schreibt `project` und `herkunftsdatei` mit in die Regel.
    Beim Rueckschreiben in die Herkunftsdatei sind beide implizit — `project`
    steht im Dateikopf, die Herkunftsdatei IST die Datei. In einer Sammeldatei
    (Export) ist nichts davon implizit: ohne die Felder verliert ein Rundlauf
    saemtliche Projektbindungen und die Herkunft, und zwar lautlos.

    `mandatory` wird fuer v2-Regeln nicht mehr geschrieben: dort ist es die
    abgeleitete Schreibweise fuer `verbindlichkeit: kern`, und der Ingest weist
    einen widersprechenden Wert zurueck. Zwei Schreibweisen desselben Fakts in
    derselben Datei waeren die naechste Gelegenheit zum Auseinanderlaufen.

    Eine v1-Regel wird als v1 zurueckgeschrieben (`mandatory`, keine v2-Zeilen).
    Ihre v2-Spalten sind Vorgaben des Legacy-Modus, keine Aussagen; als YAML
    hingeschrieben waeren sie beides zugleich falsch — sie behaupteten eine
    Geltung, die niemand entschieden hat, und die Datei fiele beim naechsten
    Ingest durch die v2-Pruefung (Anker weder gesetzt noch belegt).
    """
    zeilen = [f"  - id: {r['id']}",
              f"    domain: {r.get('domain') or 'allgemein'}",
              f"    severity: {int(r.get('severity') or 2)}"]
    if schema.ist_v1_profil(r):
        if r.get("mandatory"):
            zeilen.append("    mandatory: true")
    else:
        zeilen += [f"    geltung: {skalar(r.get('geltung'))}",
                   f"    verbindlichkeit: {skalar(r.get('verbindlichkeit'))}",
                   f"    leser: {skalar(r.get('leser'))}",
                   f"    status: {skalar(r.get('status') or 'aktiv')}",
                   f"    anker: [{', '.join(anker_liste(r.get('anker')))}]"]
        if r.get("nachweis"):
            zeilen.append(f"    quelle: {skalar(r['nachweis'])}")
        zeilen.append(f"    verfall: {r['verfall'] if r.get('verfall') else 'null'}")
        if r.get("leiter"):
            zeilen.append(f"    leiter: {skalar(r['leiter'])}")
    if mit_herkunft:
        if r.get("project"):
            zeilen.append(f"    project: {r['project']}")
        if r.get("quelle"):
            zeilen.append(f"    herkunftsdatei: {r['quelle']}")
    zeilen.append(f"    trigger: {skalar(r.get('trigger'))}")
    zeilen.append(f"    statement: {skalar(r.get('statement'))}")
    for feld in ("violation", "correct", "tags"):
        if r.get(feld):
            zeilen.append(f"    {feld}: {skalar(r[feld])}")
    if r.get("confidence") not in (None, 1.0):
        zeilen.append(f"    confidence: {r['confidence']}")
    if r.get("relations"):
        zeilen.append("    relations:")
        for rel in r["relations"]:
            zeilen.append(f"      - {{kind: {rel['kind']}, dst: {rel['dst']}}}")
    return "\n".join(zeilen)


def _kopf(pfad: Path, projekt: str | None) -> str:
    """Vorhandenen Dateikopf uebernehmen, sonst einen erzeugen."""
    if pfad.exists():
        text = pfad.read_text(encoding="utf-8")
        m = re.search(r"^rules:\s*$", text, flags=re.MULTILINE)
        if m:
            return text[:m.start()].rstrip("\n") + "\n\n"
    kopf = "# Aus dem Regelregister angelegt bzw. dort bearbeitet.\n"
    if projekt:
        kopf += f"project: {projekt}\n"
    return kopf + "\n"


def datei_inhalt(pfad: Path, regeln: list[dict], projekt: str | None = None) -> str:
    """Vollstaendiger Dateiinhalt — getrennt vom Schreiben, damit `streich` den
    Text durch seine Transaktion schicken kann statt an ihr vorbei."""
    kopf = _kopf(pfad, projekt)
    if not regeln:
        # Eine Datei mit Kopf, aber ohne `rules:` liesse den naechsten Ingest
        # LAUT ueber sie stolpern ("Schluessel 'rules' fehlt").
        return kopf + "rules: []\n"
    return kopf + "rules:\n\n" + "\n\n".join(regel_block(r) for r in regeln) + "\n"


def schreibe_datei(pfad: Path, regeln: list[dict], projekt: str | None = None) -> None:
    pfad.parent.mkdir(parents=True, exist_ok=True)
    pfad.write_text(datei_inhalt(pfad, regeln, projekt), encoding="utf-8")


TEXTFELDER = ("id", "domain", "trigger", "statement", "violation",
              "correct", "tags", "project",
              # Schema v2 — ohne diese Felder haelte der Vergleich zwei Regeln
              # fuer gleich, die verschieden zugestellt werden.
              "geltung", "verbindlichkeit", "nachweis", "leser", "verfall",
              "leiter", "status")


def _signatur(regeln: list[dict]) -> list[tuple]:
    """Vergleichbare Form einer Regelgruppe — Reihenfolge zaehlt mit.

    Die Werte muessen typrichtig vereinheitlicht werden: aus der Datenbank
    kommt `mandatory` als bool, aus einem PUT als 0/1. Ein reiner
    str()-Vergleich haelte sonst jede Datei mit einer verbindlichen Regel
    fuer veraendert und schriebe sie bei jedem Speichern neu.
    """
    return [
        tuple((f, str(r.get(f) or "")) for f in TEXTFELDER)
        + (int(r.get("severity") or 2), bool(r.get("mandatory")))
        + (tuple(anker_liste(r.get("anker"))),)
        + (tuple(sorted((x["kind"], x["dst"]) for x in (r.get("relations") or []))),)
        for r in regeln
    ]


def _gruppieren(regeln: list[dict]) -> dict[str, list[dict]]:
    nach_datei: dict[str, list[dict]] = {}
    for r in regeln:
        nach_datei.setdefault(r.get("quelle") or UI_DATEI, []).append(r)
    return nach_datei


def zurueckschreiben(neu: list[dict], vorher: list[dict],
                     wurzel: Path | None = None) -> dict:
    """Nur die Dateien neu schreiben, deren Regelbestand sich geaendert hat.

    Ohne diesen Vergleich formatierte jeder Speichervorgang das komplette
    Verzeichnis `rules/` um, auch wenn nur eine einzige Regel bearbeitet wurde.
    """
    wurzel = wurzel or paths.REPO_ROOT
    jetzt, alt = _gruppieren(neu), _gruppieren(vorher)

    geschrieben, geleert, geschuetzt_betroffen = [], [], []
    for quelle in sorted(set(jetzt) | set(alt)):
        gruppe, frueher = jetzt.get(quelle, []), alt.get(quelle, [])
        if _signatur(gruppe) == _signatur(frueher):
            continue
        if quelle in GESCHUETZT:
            geschuetzt_betroffen.append(quelle)
            continue
        pfad = wurzel / quelle
        projekt = next((r.get("project") for r in gruppe if r.get("project")), None)
        schreibe_datei(pfad, gruppe, projekt)
        (geleert if not gruppe else geschrieben).append(quelle)

    return {
        "geschrieben": geschrieben,
        "geleert": geleert,
        "nur_in_db": geschuetzt_betroffen,
    }
