"""Pfade der Laufzeit-Artefakte.

Code lebt im Git-Repo, Laufzeit-Daten (DB, Index, Modell) unter XDG.
Alles ueber Umgebungsvariablen ueberschreibbar — die Tests nutzen das.
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
    return Path(override).expanduser() if override else data_dir() / "model"


def rules_dir() -> Path:
    """Standard-Quellverzeichnis der YAML-Regeldateien."""
    override = os.environ.get("WRIT_RULES_DIR")
    return Path(override).expanduser() if override else REPO_ROOT / "rules"


def ui_html() -> Path:
    return REPO_ROOT / "ui" / "regelregister.html"
