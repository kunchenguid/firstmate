"""Regelblock fuer einen Brief an eine Rolle — hart gedeckelt.

Ein Brief geht an ein Harness ohne Hooks: dort gibt es keinen Session-Start,
der Regeln nachreicht, und keine Zustellung je Eingabe. Was hier nicht
drinsteht, sieht der Empfaenger nie. Genau deshalb ist der Deckel hart und
nicht "moeglichst": ein Brief, der auf zwei Bildschirme waechst, wird
ueberflogen, und ueberflogene Regeln wirken wie keine.

Gekuerzt wird von unten — die am schwaechsten gerankte Kontextregel zuerst.
Kernregeln werden NIE gekuerzt: sie sind gesetzt, nicht gerankt. Passt der
Kern allein nicht mehr in den Deckel, sagt der Brief das LAUT, statt eine
verbindliche Regel mitten im Satz abzuschneiden — ein halb zugestellter
Wortlaut ist schlimmer als ein sichtbarer Ueberlauf.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import render, retrieve, verfassung

KOPF = "--- REGELN FUER DEN BRIEF (geltung={geltung}{projekt}) ---"
FUSS = "--- ENDE REGELN ---"


@dataclass
class Brief:
    text: str
    kern: list[str] = field(default_factory=list)
    kontext: list[str] = field(default_factory=list)
    gekappt: list[str] = field(default_factory=list)
    warnungen: list[str] = field(default_factory=list)
    tokens: int = 0


def kontext_lesen(pfad: Path) -> str:
    """Kontextdatei einlesen — fehlt sie, ist das ein Abbruch, kein leerer Brief.

    Ein leerer Kontext liefert stillschweigend die falschen (naemlich
    beliebigen) Kontextregeln. Der Aufrufer soll merken, dass er den Pfad
    falsch geschrieben hat.
    """
    return Path(pfad).expanduser().read_text(encoding="utf-8")


def _zusammensetzen(kopf: str, kern: list[dict], kontext: list[dict],
                    gekappt: list[str], warnungen: list[str]) -> str:
    teile = [kopf, ""]
    for regel in kern + kontext:
        teile.append(render.regel_block(regel))
        teile.append("")
    if gekappt:
        teile.append(f"gekappt: {', '.join(gekappt)}")
    for w in warnungen:
        teile.append(w)
    teile.append(FUSS)
    return "\n".join(teile)


def bauen(kontext_text: str, geltung: str, projekt: str | None = None,
          db: Path | None = None, deckel: dict | None = None) -> Brief:
    """Kern voll, Kontext top-k, Gesamtausgabe auf brief_token_max gekappt."""
    warnungen: list[str] = []
    if deckel is None:
        deckel, warnungen = verfassung.laden()

    ergebnis = retrieve.query(kontext_text, projekt=projekt, geltung=geltung,
                              db=db, deckel=deckel,
                              # Das Token-Budget des Retrievals darf hier nicht
                              # zusaetzlich schneiden: der Deckel dieses Briefs
                              # ist brief_token_max, und zwei Scheren an
                              # derselben Liste ergeben eine Ausgabe, deren
                              # Laenge niemand mehr erklaeren kann.
                              budget_tokens=10 ** 6)
    kern = [t.regel for t in ergebnis.mandatory]
    kontext = [t.regel for t in ergebnis.gerankt]

    kopf = KOPF.format(geltung=geltung, projekt=f", projekt={projekt}" if projekt else "")
    gekappt: list[str] = []
    while True:
        text = _zusammensetzen(kopf, kern, kontext, gekappt, warnungen)
        tokens = verfassung.tokens_schaetzen(text)
        if tokens <= deckel["brief_token_max"] or not kontext:
            break
        gekappt.insert(0, kontext.pop()["id"])

    if tokens > deckel["brief_token_max"]:
        warnungen.append(
            f"WARNUNG: schon die {len(kern)} Kernregeln brauchen {tokens} von "
            f"{deckel['brief_token_max']} Tokens — der Brief geht ungekuerzt raus. "
            f"Kernregeln werden nicht abgeschnitten; zu senken ist der Bestand "
            f"(`fm-regeln streich`) oder der Deckel in regeln/VERFASSUNG.yaml.")
        text = _zusammensetzen(kopf, kern, kontext, gekappt, warnungen)
        tokens = verfassung.tokens_schaetzen(text)

    return Brief(text=text, kern=[r["id"] for r in kern],
                 kontext=[r["id"] for r in kontext], gekappt=gekappt,
                 warnungen=warnungen, tokens=tokens)
