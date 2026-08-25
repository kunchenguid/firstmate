"""SQLite-Schema nach regel-retrieval-light.md.

Abweichungen von der Spezifikation (im Report begruendet):
  * rules.project — NULL = global, sonst Projekt-ID. Ohne diese Spalte wuerde
    globales Ranking ueber alle Projekte das Anti-Vermischungs-Protokoll aus
    KERN-KONTEXT §5 brechen ("hoechste Prioritaet").
  * rules.quelle  — Herkunfts-YAML. Ohne sie wuerde `ingest` jede Aenderung
    aus der Weboberflaeche wieder ueberschreiben.
  * Tabelle projects — cwd -> Projekt-ID, beim Ingest aus den Dossier-
    Kopfzeilen geparst statt hartkodiert.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

# Der Bestand ist in der Schreibweise uneinheitlich gewachsen: 122 Regeln
# schreiben ae/oe/ue, 22 echte Umlaute, 8 mischen beides in derselben Regel.
# Fuer die Vektorsuche ist das egal, fuer BM25 nicht — gemessen fand FTS5 eine
# Regel bei der jeweils anderen Schreibweise in 1 von 120 Faellen. Deshalb wird
# fuer den Index und fuer die Suchbegriffe vereinheitlicht; die Anzeigetexte
# bleiben, wie sie sind.
_UMLAUTE = str.maketrans({
    "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss",
    "Ä": "ae", "Ö": "oe", "Ü": "ue",
    "é": "e", "è": "e", "ê": "e", "á": "a", "à": "a", "í": "i", "ó": "o", "ú": "u",
})


def normalisieren(text: str | None) -> str:
    """Vereinheitlichte Schreibung fuer Volltextsuche und Suchbegriffe."""
    return (text or "").translate(_UMLAUTE).lower()


SCHEMA = """
CREATE TABLE IF NOT EXISTS rules (
  id         TEXT PRIMARY KEY,
  domain     TEXT,
  severity   INTEGER,
  mandatory  INTEGER DEFAULT 0,
  trigger    TEXT,
  statement  TEXT,
  violation  TEXT,
  correct    TEXT,
  tags       TEXT,
  confidence REAL DEFAULT 1.0,
  project    TEXT,
  quelle     TEXT
);

-- Bewusst KEIN content=rules: die Tabelle haelt eine schreibweisen-normalisierte
-- Fassung der Texte. Bei external content muessten Index und Inhalt
-- uebereinstimmen — hier sollen sie das gerade nicht.
CREATE VIRTUAL TABLE IF NOT EXISTS rules_fts USING fts5(
  trigger, statement, tags
);

CREATE TABLE IF NOT EXISTS relations (
  src  TEXT REFERENCES rules(id),
  dst  TEXT REFERENCES rules(id),
  kind TEXT CHECK(kind IN ('DEPENDS_ON','CONFLICTS_WITH','SUPPLEMENTS'))
);
CREATE INDEX IF NOT EXISTS idx_rel_src ON relations(src);
CREATE INDEX IF NOT EXISTS idx_rules_project ON rules(project);

CREATE TABLE IF NOT EXISTS projects (
  id        TEXT PRIMARY KEY,
  repo_path TEXT
);

-- Zeile 1 haelt die Zuordnung rowid -> Position im hnswlib-Index fest.
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
"""

FIELDS = (
    "id", "domain", "severity", "mandatory", "trigger", "statement",
    "violation", "correct", "tags", "confidence", "project", "quelle",
)


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def create(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def reset(conn: sqlite3.Connection) -> None:
    """Kompletter Neuaufbau der REGEL-Tabellen — der Ingest ist idempotent.

    `meta` wird bewusst nicht mehr mitgeloescht. Die Tabelle gehoert beiden
    Bestaenden: neben `index_count` (Regeln) steht dort `memory_index_count`,
    und das Memory ueberlebt einen Ingest — `memory` steht aus gutem Grund
    nicht in der Loeschliste.

    Bis 2026-08-07 nahm der Drop den fremden Zaehler trotzdem mit. Folge: nach
    JEDEM `writ-light ingest` meldete `doctor` "-1 indiziert gegen 58
    Eintraege" und damit "NICHT einsatzbereit", obwohl nichts kaputt war.
    Zwei Schaeden. Der offensichtliche ist der Fehlalarm. Der schlimmere ist,
    dass ein Werkzeug, das nach jedem Routinelauf rot leuchtet, nicht mehr
    gelesen wird — und dass der Zaehler danach genau das nicht mehr konnte,
    wofuer er da war: einen wirklich veralteten Memory-Index vom Normalzustand
    unterscheiden. Gesichert durch
    test_ingest.test_ingest_laesst_den_memory_zaehler_stehen.
    """
    conn.executescript(
        "DROP TABLE IF EXISTS rules_fts;"
        "DROP TABLE IF EXISTS relations;"
        "DROP TABLE IF EXISTS rules;"
        "DROP TABLE IF EXISTS projects;"
    )
    conn.commit()
    create(conn)
    # Der eigene Zaehler muss weg: sonst behauptet er nach einem abgebrochenen
    # Ingest eine Indexgroesse, die zu den neuen Regeln nicht mehr passt.
    conn.execute("DELETE FROM meta WHERE key = 'index_count'")
    conn.commit()


def rebuild_fts(conn: sqlite3.Connection) -> None:
    """FTS5 aus rules neu befuellen — mit vereinheitlichter Schreibung.

    Die rowid bleibt die der Regel, damit der Rueckweg ein einfacher JOIN ist.
    """
    conn.execute("DELETE FROM rules_fts")
    conn.executemany(
        "INSERT INTO rules_fts(rowid, trigger, statement, tags) VALUES (?,?,?,?)",
        [(r["rowid"], normalisieren(r["trigger"]), normalisieren(r["statement"]),
          normalisieren(r["tags"]))
         for r in conn.execute("SELECT rowid, trigger, statement, tags FROM rules")],
    )
    conn.commit()
