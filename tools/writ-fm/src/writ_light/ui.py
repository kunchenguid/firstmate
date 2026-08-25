"""Lokaler Server fuer das Regelregister (Akzeptanz 7).

Kein Daemon: laeuft nur auf ausdruecklichen Aufruf von `writ-light ui` und
bindet ausschliesslich auf 127.0.0.1.

  GET  /             -> ui/regelregister.html
  GET  /api/rules    -> Array aller Regeln, Feldnamen wie im YAML
  PUT  /api/rules    -> ersetzt den Bestand, baut FTS5 und Vektorindex neu
                        und schreibt die betroffenen YAML-Dateien zurueck
"""

from __future__ import annotations

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import ingest, paths, schema, yamlio

MAX_BODY = 8 * 1024 * 1024
_sperre = threading.Lock()


def export_ziel() -> Path:
    """Wohin der Pruef-Export aus der Oberflaeche schreibt."""
    return paths.REPO_ROOT / "export"


def _heute() -> str:
    import datetime

    return datetime.date.today().isoformat()


# ── Datenbank <-> JSON ────────────────────────────────────────────────────

def regeln_lesen(db: Path | None = None) -> list[dict]:
    conn = schema.connect(db or paths.db_path())
    try:
        beziehungen: dict[str, list[dict]] = {}
        for r in conn.execute("SELECT src, dst, kind FROM relations ORDER BY rowid"):
            beziehungen.setdefault(r["src"], []).append({"kind": r["kind"], "dst": r["dst"]})
        regeln = []
        for row in conn.execute("SELECT * FROM rules ORDER BY rowid"):
            r = dict(row)
            r["mandatory"] = bool(r["mandatory"])
            r["relations"] = beziehungen.get(r["id"], [])
            regeln.append(r)
        return regeln
    finally:
        conn.close()


def _normieren(roh: list) -> list[dict]:
    """Was die Oberflaeche schickt, auf das Datenbankschema abbilden."""
    regeln = []
    for r in roh:
        if not isinstance(r, dict) or not str(r.get("id") or "").strip():
            raise ValueError("Regel ohne id")
        rel = []
        for x in r.get("relations") or []:
            if x.get("kind") not in ingest.VALID_KINDS:
                raise ValueError(f"{r['id']}: unbekannte Beziehungsart {x.get('kind')!r}")
            rel.append({"kind": x["kind"], "dst": x["dst"]})
        regeln.append({
            "id": str(r["id"]).strip(),
            "domain": (r.get("domain") or "allgemein").strip(),
            "severity": int(r.get("severity") or 2),
            "mandatory": 1 if r.get("mandatory") else 0,
            "trigger": (r.get("trigger") or "").strip(),
            "statement": (r.get("statement") or "").strip(),
            "violation": (r.get("violation") or "").strip(),
            "correct": (r.get("correct") or "").strip(),
            "tags": (r.get("tags") or "").strip(),
            # Neuanlagen aus der Oberflaeche kennen diese Felder nicht.
            "confidence": float(r.get("confidence") or 1.0),
            "project": r.get("project") or None,
            "quelle": r.get("quelle") or yamlio.UI_DATEI,
            "relations": rel,
        })
    return regeln


def regeln_schreiben(roh: list, db: Path | None = None) -> dict:
    """Bestand ersetzen, Indizes neu bauen, YAML zurueckschreiben."""
    neu = _normieren(roh)
    ingest.validate(neu)
    db = db or paths.db_path()
    with _sperre:
        vorher = regeln_lesen(db)
        conn = schema.connect(db)
        try:
            projekte = [dict(p) for p in conn.execute("SELECT id, repo_path FROM projects")]
            projekte = [{"id": p["id"], "repo_path": p["repo_path"]} for p in projekte]
            ingest.write_db(conn, neu, projekte)
            anzahl = ingest.build_index(conn, paths.index_path())
        finally:
            conn.close()
        dateien = yamlio.zurueckschreiben(neu, vorher)
    return {"regeln": len(neu), "indexiert": anzahl, "dateien": dateien}


# ── HTTP ──────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = "writ-light"

    def log_message(self, format, *args):  # noqa: A002
        if self.server.leise:
            return
        super().log_message(format, *args)

    def _senden(self, code: int, koerper: bytes, typ: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(koerper)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(koerper)

    def _json(self, code: int, daten) -> None:
        self._senden(code, json.dumps(daten, ensure_ascii=False).encode("utf-8"),
                     "application/json; charset=utf-8")

    def do_GET(self) -> None:
        if self.path.split("?")[0] == "/api/rules":
            try:
                self._json(200, regeln_lesen())
            except Exception as exc:
                self._json(500, {"fehler": str(exc)})
            return
        if self.path.split("?")[0] in ("/", "/index.html", "/regelregister.html"):
            datei = paths.ui_html()
            if not datei.exists():
                self._senden(404, b"regelregister.html fehlt", "text/plain; charset=utf-8")
                return
            self._senden(200, datei.read_bytes(), "text/html; charset=utf-8")
            return
        self._senden(404, b"nicht gefunden", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if self.path.split("?")[0] != "/api/export":
            self._senden(404, b"nicht gefunden", "text/plain; charset=utf-8")
            return
        try:
            from . import export

            with _sperre:
                stat = export.schreiben(export_ziel(), stand=_heute())
            self._json(200, {
                "ziel": str(stat["ziel"]),
                "regeln": stat["regeln"],
                "beziehungen": stat["beziehungen"],
                "ketten": stat["ketten"],
                "dateien": stat["dateien"],
            })
        except Exception as exc:
            self._json(500, {"fehler": str(exc)})

    def do_PUT(self) -> None:
        if self.path.split("?")[0] != "/api/rules":
            self._senden(404, b"nicht gefunden", "text/plain; charset=utf-8")
            return
        laenge = int(self.headers.get("Content-Length") or 0)
        if laenge <= 0 or laenge > MAX_BODY:
            self._json(400, {"fehler": "Koerper fehlt oder ist zu gross"})
            return
        try:
            daten = json.loads(self.rfile.read(laenge).decode("utf-8"))
        except Exception as exc:
            self._json(400, {"fehler": f"kein gueltiges JSON: {exc}"})
            return
        if not isinstance(daten, list) or not daten:
            self._json(400, {"fehler": "Array mit mindestens einer Regel erwartet"})
            return
        try:
            self._json(200, regeln_schreiben(daten))
        except (ValueError, ingest.IngestError) as exc:
            self._json(400, {"fehler": str(exc)})
        except Exception as exc:
            self._json(500, {"fehler": str(exc)})


def freier_port(start: int, versuche: int = 20) -> int:
    for port in range(start, start + versuche):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise OSError(f"Kein freier Port zwischen {start} und {start + versuche - 1}")


def starten(port: int | None = None, leise: bool = False) -> ThreadingHTTPServer:
    """Server nur auf 127.0.0.1 binden — nie auf 0.0.0.0."""
    server = ThreadingHTTPServer(("127.0.0.1", port or freier_port(8731)), Handler)
    server.leise = leise
    return server
