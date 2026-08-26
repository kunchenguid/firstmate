"""Pfade der FLOTTENSEITE — alles, was ausserhalb dieses Werkzeugs liegt.

`paths.py` gehoert dem Werkzeug (DB, Index, Modell, eigene Regeldateien).
Dieses Modul gehoert dem Repo drumherum: Regelquelle, Verfassung, Ledger,
AGENTS.md, das Abschaffungs-Register und die Gold-Datei des Retrievals.

Getrennt, weil beide Seiten getrennt umziehen: das Werkzeug ist ein Vendor-
Baum unter `tools/writ-fm/`, die Flottendateien liegen im Repo-Wurzelverzeichnis.
Stuende beides in `paths.py`, muesste jeder Umzug einer Seite die andere
mitanfassen.

Jeder Pfad ist ueber eine Umgebungsvariable ersetzbar — die Tests bauen sich
damit eine vollstaendige Flotte im Temp-Verzeichnis, statt gegen den echten
Bestand zu pruefen (ein Test, der vom Zustand dieses Laptops abhaengt, prueft
an manchen Tagen etwas anderes als heute).
"""

from __future__ import annotations

import os
from pathlib import Path

from . import paths

# .../firstmate/tools/writ-fm/src/writ_light/fmpfade.py
#   parents[0] writ_light  [1] src  [2] writ-fm  [3] tools  [4] firstmate
#
# Letzter Rueckfall, wenn weder WRIT_FLOTTE_ROOT noch FM_HOME gesetzt ist:
# der Vendor-Baum liegt im Flotten-Repo, also steht die Wurzel vier Ebenen
# darueber.
_ABGELEITETE_WURZEL = Path(__file__).resolve().parents[4]


def flotte_root() -> Path:
    """Wurzel des Flotten-Repos.

    `FM_HOME` ist derselbe Wert, mit dem `paths.py` die Laufzeitdaten in das
    Heim des Firstmate umzieht — die beiden duerfen nicht auseinanderlaufen,
    sonst laege die Regelquelle in einem anderen Heim als die Datenbank, die
    aus ihr gebaut wird.
    """
    for variable in ("WRIT_FLOTTE_ROOT", "FM_HOME"):
        wert = os.environ.get(variable)
        if wert:
            return Path(wert).expanduser()
    return _ABGELEITETE_WURZEL


def _pfad(variable: str, *teile: str) -> Path:
    override = os.environ.get(variable)
    return Path(override).expanduser() if override else flotte_root().joinpath(*teile)


def regeln_dir() -> Path:
    """Quellverzeichnis des Regelwerks v2 (`regeln/*.yaml`).

    Bewusst KEIN eigener Pfad, sondern eine Weiterleitung: wo die Regeln
    liegen, weiss `paths.rules_dir()` (WRIT_RULES_DIR bzw. $FM_HOME/regeln).
    Zwei Herleitungen desselben Verzeichnisses waeren die zweite Wahrheit,
    an der ein `streich` in die eine Datei schriebe und der Ingest die andere
    liest.
    """
    return paths.rules_dir()


def verfassung_datei() -> Path:
    """Die Deckel: wie viele Kern- und Kontextregeln ueberhaupt existieren duerfen."""
    return _pfad("WRIT_VERFASSUNG", "regeln", "VERFASSUNG.yaml")


def abgeschafft_datei() -> Path:
    """Append-only-Register gestrichener Regeln."""
    return _pfad("WRIT_ABGESCHAFFT", "regeln", "ABGESCHAFFT.md")


def ledger_datei() -> Path:
    """Lehren-Ledger — Heimat der Anker Lnn."""
    return _pfad("WRIT_LEDGER_PATH", "data", "forensik-2026-08", "lehren-ledger.md")


def agents_datei() -> Path:
    """AGENTS.md — Heimat der Anker HRn."""
    return _pfad("WRIT_AGENTS_PATH", "AGENTS.md")


def golden_tsv() -> Path:
    """Gold-Satz des Retrievals; darf fehlen."""
    return _pfad("WRIT_GOLDEN_TSV", "tests", "regel-retrieval-golden.tsv")
