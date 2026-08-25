"""Session-uebergreifendes Memory: kuratierte Fakten und Entscheidungen.

Gegenstueck zum Regelwerk: Regeln kommen aus versionierten YAML-Dateien und
werden per `ingest` komplett neu gebaut — Memory-Eintraege entstehen zur
Laufzeit (`memory add`), sind append-only und ueberleben jeden Ingest.
Deshalb eigene Tabelle (nicht in schema.reset) und eigener Index
(vectors-memory.hnsw statt vectors.hnsw).

Bewusst kuratiert statt automatisch: was gespeichert wird, entscheidet der
Agent bzw. der Owner (MEM-SAVE-001). Kein LLM in der Schleife, keine zusaetzlichen
API-Kosten — Recall laeuft ueber dasselbe lokale Embedding-Modell wie das
Regel-Retrieval.
"""

from __future__ import annotations

import datetime
import sqlite3
from pathlib import Path

from . import embed, paths, schema

SCHEMA_MEMORY = """
CREATE TABLE IF NOT EXISTS memory (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT,
  text    TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_project ON memory(project);
"""

# Cosine-Distanz, ab der ein Treffer als Rauschen gilt. Gemessen am
# MiniLM-Modell (2026-08-05): thematisch verwandte Paare liegen bei
# 0.30–0.64, themenfremde bei ~1.07 — 0.7 trennt das mit Abstand nach
# beiden Seiten. Lieber einmal nichts liefern als einen falschen "Fakt"
# in den Kontext.
MAX_DISTANZ = 0.7


def connect(db: Path | None = None) -> sqlite3.Connection:
    """Oeffnet die DB und legt die Memory-Tabelle an, falls sie fehlt.

    So bekommt auch ein Bestand, der vor dem Memory-Feature ingested wurde,
    die Tabelle beim ersten memory-Aufruf nachgeruestet — ohne erneuten
    Ingest der Regeln.
    """
    conn = schema.connect(db or paths.db_path())
    conn.executescript(SCHEMA_MEMORY)
    conn.commit()
    return conn


def _projekt(conn: sqlite3.Connection, explizit: str | None,
             cwd: str | Path | None) -> str | None:
    from . import retrieve

    return retrieve.aktives_projekt(conn, explizit, cwd)


def add(text: str, projekt: str | None = None, cwd: str | Path | None = None,
        db: Path | None = None) -> int:
    """Speichert einen Eintrag und haengt seinen Vektor an den Index."""
    import hnswlib

    text = " ".join(text.split())
    if not text:
        raise ValueError("leerer Memory-Text")
    conn = connect(db)
    try:
        aktiv = _projekt(conn, projekt, cwd)
        cur = conn.execute(
            "INSERT INTO memory (project, text, created) VALUES (?,?,?)",
            (aktiv, text, datetime.date.today().isoformat()),
        )
        mid = cur.lastrowid
        gesamt = conn.execute("SELECT count(*) FROM memory").fetchone()[0]

        idx_pfad = paths.memory_index_path()
        index = hnswlib.Index(space="cosine", dim=embed.DIM)
        if idx_pfad.exists():
            index.load_index(str(idx_pfad), max_elements=max(gesamt * 2, 64))
        else:
            index.init_index(max_elements=max(gesamt * 2, 64),
                             ef_construction=200, M=16)
            index.set_ef(64)
        index.add_items(embed.shared().encode([text]), [mid])
        idx_pfad.parent.mkdir(parents=True, exist_ok=True)
        index.save_index(str(idx_pfad))
        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('memory_index_count', ?)",
            (str(gesamt),),
        )
        conn.commit()
        return mid
    finally:
        conn.close()


def reindex(db: Path | None = None) -> dict:
    """Den Memory-Vektorindex aus der Tabelle neu bauen und den Zaehler setzen.

    Gegenstueck zum doctor-Befund "n indiziert gegen m Eintraege". Bis
    2026-08-07 gab es dazu kein Gegenmittel: `memory_index_count` wurde
    ausschliesslich in `add` geschrieben. Ein Befund liess sich also nur
    "heilen", indem man einen neuen Eintrag anlegte — was den bestehenden
    Index nicht anfasst und den Zaehler nur zufaellig wieder passend macht.
    Ein Befund ohne Reparaturweg erzieht dazu, ihn zu ignorieren.

    Baut bewusst komplett neu statt zu ergaenzen: der Anlass ist immer ein
    Index, dem nicht zu trauen ist.
    """
    import hnswlib

    conn = connect(db)
    try:
        rows = conn.execute("SELECT id, text FROM memory ORDER BY id").fetchall()
        idx_pfad = paths.memory_index_path()
        index = hnswlib.Index(space="cosine", dim=embed.DIM)
        index.init_index(max_elements=max(len(rows) * 2, 64),
                         ef_construction=200, M=16)
        index.set_ef(64)
        if rows:
            index.add_items(embed.shared().encode([r["text"] for r in rows]),
                            [r["id"] for r in rows])
        idx_pfad.parent.mkdir(parents=True, exist_ok=True)
        index.save_index(str(idx_pfad))
        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('memory_index_count', ?)",
            (str(len(rows)),),
        )
        conn.commit()
        return {"eintraege": len(rows), "index": idx_pfad}
    finally:
        conn.close()


def _erlaubte_ids(conn: sqlite3.Connection, projekt: str | None) -> set[int]:
    if projekt:
        rows = conn.execute(
            "SELECT id FROM memory WHERE project IS NULL OR project = ?",
            (projekt,),
        ).fetchall()
    else:
        rows = conn.execute("SELECT id FROM memory WHERE project IS NULL").fetchall()
    return {r["id"] for r in rows}


def query(prompt: str, limit: int = 3, projekt: str | None = None,
          cwd: str | Path | None = None, db: Path | None = None) -> list[dict]:
    """Semantisch passende Eintraege — nur die des aktiven Projekts (+ globale).

    Gleiche Projektbindung wie beim Regel-Retrieval: ohne sie wuerde das
    Memory eines Projekts in das andere hineinrauschen (KERN-KONTEXT §5).
    """
    idx_pfad = paths.memory_index_path()
    if not idx_pfad.exists():
        return []
    conn = connect(db)
    try:
        gesamt = conn.execute("SELECT count(*) FROM memory").fetchone()[0]
        if not gesamt:
            return []
        aktiv = _projekt(conn, projekt, cwd)
        erlaubt = _erlaubte_ids(conn, aktiv)
        if not erlaubt:
            return []

        import hnswlib

        index = hnswlib.Index(space="cosine", dim=embed.DIM)
        index.load_index(str(idx_pfad), max_elements=max(gesamt * 2, 64))
        index.set_ef(max(64, limit * 4))
        # Grosszuegig suchen, danach filtern — wie bei retrieve.vektor_treffer.
        # k wird zusaetzlich am INDEX gedeckelt, nicht nur an der Tabelle: liegt
        # der Index zurueck (Eintrag direkt in die DB geschrieben, Neubau
        # abgebrochen), wirft hnswlib sonst "Cannot return the results in a
        # contiguous 2D array" statt weniger zu liefern. Der Fehler kam bis
        # 2026-08-07 nirgends an — `hooks._memory_prompt_block` faengt jede
        # Ausnahme ab, das Memory verschwand also KOMPLETT aus dem Block statt
        # nur unvollstaendig zu sein. Reparatur: `writ-light memory reindex`.
        vorhanden = index.get_current_count()
        if not vorhanden:
            return []
        k = min(gesamt, vorhanden, max(limit * 3, 20))
        labels, distanzen = index.knn_query(embed.shared().encode_one(prompt), k=k)

        treffer = []
        for label, dist in zip(labels[0], distanzen[0]):
            mid = int(label)
            if mid in erlaubt and dist <= MAX_DISTANZ:
                treffer.append((mid, float(dist)))
            if len(treffer) >= limit:
                break
        if not treffer:
            return []
        platzhalter = ",".join("?" * len(treffer))
        zeilen = {
            r["id"]: dict(r)
            for r in conn.execute(
                f"SELECT * FROM memory WHERE id IN ({platzhalter})",
                [m for m, _ in treffer],
            )
        }
        return [{**zeilen[mid], "distanz": dist} for mid, dist in treffer
                if mid in zeilen]
    finally:
        conn.close()


def latest(limit: int = 5, projekt: str | None = None,
           cwd: str | Path | None = None, db: Path | None = None) -> list[dict]:
    """Die juengsten Eintraege des aktiven Projekts (+ globale), neueste zuerst."""
    conn = connect(db)
    try:
        aktiv = _projekt(conn, projekt, cwd)
        if aktiv:
            rows = conn.execute(
                "SELECT * FROM memory WHERE project IS NULL OR project = ? "
                "ORDER BY id DESC LIMIT ?",
                (aktiv, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM memory WHERE project IS NULL "
                "ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()
