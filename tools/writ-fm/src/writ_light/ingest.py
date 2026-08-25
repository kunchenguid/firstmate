"""Ingest: YAML-Regeldateien -> SQLite + FTS5 + hnswlib.

Idempotent: jeder Lauf baut komplett neu auf (Spezifikation, Abschnitt
"Ingest-Workflow"). Eine Regeldatei sieht so aus:

    project: rag-digital          # optional, gilt fuer alle Regeln der Datei
    repo: ~/projects/rag-digital  # optional, fuellt die Tabelle projects
    rules:
      - id: RAG-MOCK-001
        domain: rag-digital
        severity: 2
        trigger: ...
        statement: ...
        relations:
          - {kind: SUPPLEMENTS, dst: LEK-VERIFY-001}
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import yaml

from . import embed, paths, schema

VALID_KINDS = {"DEPENDS_ON", "CONFLICTS_WITH", "SUPPLEMENTS"}


class IngestError(Exception):
    pass


def _clean(value) -> str:
    """Gefaltete YAML-Skalare (`>`) tragen einen Zeilenumbruch am Ende."""
    if value is None:
        return ""
    return str(value).strip()


def load_file(path: Path) -> tuple[list[dict], dict]:
    """Liest eine Regeldatei. Gibt (Regeln, Projekt-Metadaten) zurueck."""
    with path.open(encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict) or "rules" not in doc:
        raise IngestError(f"{path}: Schluessel 'rules' fehlt")

    project = doc.get("project")
    meta = {}
    if project:
        meta = {"id": project, "repo_path": _expand(doc.get("repo"))}

    quelle = _relative(path)
    out = []
    for raw in doc["rules"] or []:
        if not raw.get("id"):
            raise IngestError(f"{path}: Regel ohne id")
        rel = []
        for r in raw.get("relations") or []:
            kind = r.get("kind")
            if kind not in VALID_KINDS:
                raise IngestError(f"{raw['id']}: unbekannte Beziehung {kind!r}")
            rel.append({"kind": kind, "dst": r["dst"]})
        out.append({
            "id": raw["id"].strip(),
            "domain": _clean(raw.get("domain")) or "allgemein",
            "severity": int(raw.get("severity", 2)),
            "mandatory": 1 if raw.get("mandatory") else 0,
            "trigger": _clean(raw.get("trigger")),
            "statement": _clean(raw.get("statement")),
            "violation": _clean(raw.get("violation")),
            "correct": _clean(raw.get("correct")),
            "tags": _clean(raw.get("tags")),
            "confidence": float(raw.get("confidence", 1.0)),
            "project": raw.get("project", project),
            # Eine Regel darf ihre Herkunft selbst mitbringen. Ohne das koennte
            # ein Export, der alle Regeln in EINE Datei schreibt, sie nicht
            # zurueckspielen: alle traegen dann diese eine Datei als Quelle,
            # und gezielte Entfernungen nach Herkunft waeren nicht mehr moeglich.
            "quelle": raw.get("quelle") or quelle,
            "relations": rel,
        })
    return out, meta


def _expand(p) -> str | None:
    return str(Path(str(p)).expanduser()) if p else None


def _relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(paths.REPO_ROOT))
    except ValueError:
        return str(path)


def collect(source: Path) -> tuple[list[dict], list[dict]]:
    """Alle *.yaml unter `source` einlesen (rekursiv, sortiert)."""
    files = sorted(source.rglob("*.yaml")) if source.is_dir() else [source]
    if not files:
        raise IngestError(f"Keine YAML-Dateien unter {source}")
    rules: list[dict] = []
    projects: dict[str, dict] = {}
    for f in files:
        rs, meta = load_file(f)
        rules.extend(rs)
        if meta:
            projects[meta["id"]] = meta
    return rules, list(projects.values())


def validate(rules: list[dict]) -> None:
    ids = [r["id"] for r in rules]
    doppelt = {i for i in ids if ids.count(i) > 1}
    if doppelt:
        raise IngestError(f"Doppelte Regel-IDs: {sorted(doppelt)}")
    bekannt = set(ids)
    for r in rules:
        for rel in r["relations"]:
            if rel["dst"] not in bekannt:
                raise IngestError(
                    f"{r['id']}: Beziehung zeigt auf unbekannte Regel {rel['dst']}"
                )
        if not 1 <= r["severity"] <= 3:
            raise IngestError(f"{r['id']}: severity {r['severity']} ausserhalb 1..3")


def write_db(conn: sqlite3.Connection, rules: list[dict], projects: list[dict]) -> None:
    schema.reset(conn)
    conn.executemany(
        f"INSERT INTO rules ({','.join(schema.FIELDS)}) "
        f"VALUES ({','.join('?' * len(schema.FIELDS))})",
        [tuple(r[f] for f in schema.FIELDS) for r in rules],
    )
    conn.executemany(
        "INSERT INTO relations (src, dst, kind) VALUES (?,?,?)",
        [(r["id"], rel["dst"], rel["kind"]) for r in rules for rel in r["relations"]],
    )
    conn.executemany(
        "INSERT OR REPLACE INTO projects (id, repo_path) VALUES (?,?)",
        [(p["id"], p["repo_path"]) for p in projects],
    )
    conn.commit()
    schema.rebuild_fts(conn)


def build_index(conn: sqlite3.Connection, index_path: Path) -> int:
    """hnswlib-Index aus den Regeln der DB bauen. Label = rules.rowid."""
    import hnswlib

    rows = conn.execute("SELECT rowid, trigger, statement FROM rules ORDER BY rowid").fetchall()
    if not rows:
        raise IngestError("Keine Regeln in der Datenbank — Index waere leer")
    vecs = embed.shared().encode([embed.rule_text(dict(r)) for r in rows])
    index = hnswlib.Index(space="cosine", dim=embed.DIM)
    index.init_index(max_elements=max(len(rows) * 2, 64), ef_construction=200, M=16)
    index.add_items(vecs, [r["rowid"] for r in rows])
    index.set_ef(64)
    index_path.parent.mkdir(parents=True, exist_ok=True)
    index.save_index(str(index_path))
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('index_count', ?)",
        (str(len(rows)),),
    )
    conn.commit()
    return len(rows)


def run(source: Path | None = None, db: Path | None = None,
        index: Path | None = None) -> dict:
    source = source or paths.rules_dir()
    db = db or paths.db_path()
    index = index or paths.index_path()

    rules, projects = collect(source)
    validate(rules)
    conn = schema.connect(db)
    try:
        write_db(conn, rules, projects)
        n = build_index(conn, index)
    finally:
        conn.close()
    return {
        "regeln": len(rules),
        "mandatory": sum(r["mandatory"] for r in rules),
        "beziehungen": sum(len(r["relations"]) for r in rules),
        "projekte": len(projects),
        "indexiert": n,
        "db": db,
        "index": index,
    }
