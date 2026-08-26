"""Messung: findet BM25 eine Regel auch bei der anderen Schreibweise?

Erzeugt den Vorher/Nachher-Beleg zur Umlaut-Normalisierung. Kein Test —
ein Messwerkzeug, aufrufbar mit
`PYTHONPATH=tests:src .venv/bin/python tests/umlaut_messung.py`.

Verfahren: fuer jede Regel die unterscheidenden Woerter suchen, die eine
Umlaut-Variante haben, und dann mit der JEWEILS ANDEREN Schreibweise
suchen. Findet BM25 die Regel dann noch?
"""

from __future__ import annotations

import re
import sys
from collections import Counter

from writ_light import paths, retrieve, schema

UMLAUT_ZU_ASCII = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss",
                   "Ä": "Ae", "Ö": "Oe", "Ü": "Ue"}
ASCII_PAARE = [("ae", "ä"), ("oe", "ö"), ("ue", "ü")]

# Woerter, in denen "ue"/"ae"/"oe" KEIN ersetzter Umlaut ist.
FALSCHE_FREUNDE = {"neue", "neuen", "neuer", "neues", "queue", "que",
                   "aktuelle", "aktuellen", "aktueller", "manuell", "manuelle",
                   "virtuell", "individuell", "eventuell", "sequenz"}


def ascii_form(wort: str) -> str:
    for a, b in UMLAUT_ZU_ASCII.items():
        wort = wort.replace(a, b)
    return wort


def umlaut_form(wort: str) -> str | None:
    """Kehrt ae/oe/ue in Umlaute — nur wenn das plausibel ist."""
    if wort in FALSCHE_FREUNDE:
        return None
    neu = wort
    for a, b in ASCII_PAARE:
        neu = neu.replace(a, b)
    return neu if neu != wort else None


def kandidaten(conn) -> list[tuple[str, str, str]]:
    """(Regel-ID, Suchwort, Gegenschreibweise) fuer alle betroffenen Regeln."""
    # Wie oft kommt ein Wort im Bestand vor? Nur seltene Woerter unterscheiden.
    haeufigkeit = Counter()
    texte = {}
    for r in conn.execute("SELECT id, trigger, statement, tags FROM rules"):
        text = f"{r['trigger']} {r['statement']} {r['tags']}".lower()
        texte[r["id"]] = text
        haeufigkeit.update(set(re.findall(r"\w+", text, flags=re.UNICODE)))

    raus = []
    for rid, text in texte.items():
        for wort in sorted(set(re.findall(r"\w+", text, flags=re.UNICODE))):
            if len(wort) < 5 or haeufigkeit[wort] > 3:
                continue
            if any(u in wort for u in "äöüß"):
                gegen = ascii_form(wort)
            else:
                gegen = umlaut_form(wort)
            if gegen and gegen != wort:
                raus.append((rid, wort, gegen))
                break  # ein Wort je Regel reicht
    return raus


def _tabelle_bauen(conn, name: str, normalisiert: bool) -> None:
    """Zweite FTS-Tabelle mit bzw. ohne Vereinheitlichung — fuer den Vergleich."""
    conn.execute(f"DROP TABLE IF EXISTS {name}")
    conn.execute(f"CREATE VIRTUAL TABLE {name} USING fts5(trigger, statement, tags)")
    fn = schema.normalisieren if normalisiert else (lambda s: (s or "").lower())
    conn.executemany(
        f"INSERT INTO {name}(rowid, trigger, statement, tags) VALUES (?,?,?,?)",
        [(r["rowid"], fn(r["trigger"]), fn(r["statement"]), fn(r["tags"]))
         for r in conn.execute("SELECT rowid, trigger, statement, tags FROM rules")])
    conn.commit()


def messen(conn, tabelle: str, faelle, normalisiert: bool) -> tuple[int, list[str]]:
    """Direkt gegen FTS5 — ohne Projekt- und Rollenfilter.

    Die gehoeren zum Retrieval, nicht zur Frage nach der Schreibweise. Sie
    mitzumessen hat im ersten Anlauf 72 Fehlschlaege vorgetaeuscht, die in
    Wahrheit korrekt gefilterte claw-rolle- und Projektregeln waren.
    """
    treffer, fehl = 0, []
    for rid, wort, gegen in faelle:
        term = schema.normalisieren(gegen) if normalisiert else gegen.lower()
        rows = conn.execute(
            f"SELECT r.id FROM {tabelle} f JOIN rules r ON r.rowid = f.rowid "
            f"WHERE {tabelle} MATCH ?", (f'"{term}"',)).fetchall()
        if rid in {r["id"] for r in rows}:
            treffer += 1
        else:
            fehl.append(f"{rid}: '{wort}' gesucht als '{gegen}'")
    return treffer, fehl


def main() -> int:
    conn = schema.connect(paths.db_path())
    try:
        faelle = kandidaten(conn)
        print("Umlaut-Gegenprobe: findet FTS5 eine Regel bei der ANDEREN Schreibweise?")
        print(f"Grundlage: {len(faelle)} Regeln mit Schreibvarianten "
              f"(je ein unterscheidendes Wort, Haeufigkeit im Bestand <= 3).")
        print("Gemessen direkt gegen FTS5, ohne Projekt- und Rollenfilter — die")
        print("gehoeren zum Retrieval, nicht zur Frage nach der Schreibweise.\n")

        ergebnisse = {}
        for label, tabelle, norm in (("ohne Vereinheitlichung", "_mess_roh", False),
                                     ("mit Vereinheitlichung", "_mess_norm", True)):
            _tabelle_bauen(conn, tabelle, norm)
            treffer, fehl = messen(conn, tabelle, faelle, norm)
            ergebnisse[label] = (treffer, fehl)
            print(f"  {label:24s} {treffer:3d}/{len(faelle)} ({treffer / len(faelle):4.0%})")
            conn.execute(f"DROP TABLE {tabelle}")
        conn.commit()

        vorher = ergebnisse["ohne Vereinheitlichung"][0]
        nachher, fehl = ergebnisse["mit Vereinheitlichung"]
        print(f"\n  Gewinn: +{nachher - vorher} Regeln "
              f"({(nachher - vorher) / len(faelle):.0%} des Pruefsatzes)")
        if fehl:
            print(f"\nAuch danach nicht gefunden ({len(fehl)}):")
            for z in fehl[:10]:
                print(f"  {z}")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
