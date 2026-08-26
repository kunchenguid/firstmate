"""Pfade der Laufzeit-Artefakte.

Code lebt im Git-Repo, Laufzeit-Daten (DB, Index, Modell) unter XDG.
Alles ueber Umgebungsvariablen ueberschreibbar — die Tests nutzen das.

Firstmate-Einbettung (Portierung): wenn $FM_HOME gesetzt ist, ziehen
Daten- und Regelverzeichnis dorthin um (state/writ-fm bzw. regeln), ohne
den Standalone-Betrieb (XDG bzw. REPO_ROOT/rules) zu veraendern. Das
Modellverzeichnis bleibt davon unberuehrt und zeigt unconditional auf
~/.local/share/writ-fm/model, sofern kein WRIT_MODEL_DIR gesetzt ist.
"""

from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def data_dir() -> Path:
    """Verzeichnis der Laufzeit-Artefakte (rules.db, vectors.hnsw, model/)."""
    override = os.environ.get("WRIT_DATA_DIR")
    if override:
        return Path(override).expanduser()
    fm_home = os.environ.get("FM_HOME")
    if fm_home:
        return Path(fm_home).expanduser() / "state" / "writ-fm"
    base = os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local/share")
    return Path(base).expanduser() / "writ-light"


def db_path() -> Path:
    return data_dir() / "rules.db"


def index_path() -> Path:
    return data_dir() / "vectors.hnsw"


def memory_index_path() -> Path:
    """Eigener Index fuer Memory-Eintraege — `ingest` baut nur vectors.hnsw neu,
    das Memory muss den Ingest unbeschadet ueberstehen."""
    return data_dir() / "vectors-memory.hnsw"


def model_dir() -> Path:
    override = os.environ.get("WRIT_MODEL_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local/share/writ-fm/model"


def rules_dir() -> Path:
    """Standard-Quellverzeichnis der YAML-Regeldateien."""
    override = os.environ.get("WRIT_RULES_DIR")
    if override:
        return Path(override).expanduser()
    fm_home = os.environ.get("FM_HOME")
    if fm_home:
        return Path(fm_home).expanduser() / "regeln"
    return REPO_ROOT / "rules"


def ui_html() -> Path:
    return REPO_ROOT / "ui" / "regelregister.html"
