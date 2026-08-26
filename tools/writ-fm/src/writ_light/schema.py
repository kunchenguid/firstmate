"""SQLite-Schema nach regel-retrieval-light.md — plus Regel-Schema v2.

Abweichungen von der Spezifikation (im Report begruendet):
  * rules.project — NULL = global, sonst Projekt-ID. Ohne diese Spalte wuerde
    globales Ranking ueber alle Projekte das Anti-Vermischungs-Protokoll aus
    KERN-KONTEXT §5 brechen ("hoechste Prioritaet").
  * rules.quelle  — Herkunfts-YAML. Ohne sie wuerde `ingest` jede Aenderung
    aus der Weboberflaeche wieder ueberschreiben.
  * Tabelle projects — cwd -> Projekt-ID, beim Ingest aus den Dossier-
    Kopfzeilen geparst statt hartkodiert.

Regel-Schema v2 (Flottenordnung) haengt acht Spalten an. Dieses Modul ist ihr
EINZIGER Eigner: die erlaubten Werte stehen hier, nicht verstreut in Ingest,
Retrieval und Werkzeugen — sonst driften drei Listen auseinander und eine
Regel gilt je nach Leser unterschiedlich.

  geltung         wen die Regel bindet (flotte|firstmate|secondmate|worker|
                  projekt:<name>)
  verbindlichkeit kern = immer zugestellt, kontext = gerankt, hinweis = nur auf
                  ausdrueckliche Nachfrage
  anker           Lnn/HRn — der belegte Fehlerfall, den die Regel verhindert
  nachweis        Herkunft des Wortlauts (grundsatz:<n>|order:O-xxxx|
                  captain-wort:<datum>). Traegt im YAML den Schluessel
                  `quelle`; die SPALTE heisst anders, weil `rules.quelle` seit
                  jeher die Herkunftsdatei haelt und beide Fakten getrennt
                  bleiben muessen (ein Eigner je Fakt). Die Herkunftsdatei
                  laesst sich im YAML mit `herkunftsdatei:` ueberschreiben.
  leser           wer sie liest (hook:<pfad>|tor:<pfad>|werkzeug:<pfad>|
                  retrieval) — eine Regel ohne Leser wirkt nirgends
  verfall         ISO-Datum oder NULL
  leiter          Stufe-4-Begruendung (Pflicht erst fuer Neuaufnahmen nach dem
                  Cutover, deshalb hier optional)
  status          aktiv|abgelaufen|hinweis-abgestuft
"""

from __future__ import annotations

import re
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
  quelle     TEXT,
  -- Regel-Schema v2
  geltung         TEXT,
  verbindlichkeit TEXT,
  anker           TEXT,
  nachweis        TEXT,
  leser           TEXT,
  verfall         TEXT,
  leiter          TEXT,
  status          TEXT DEFAULT 'aktiv'
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
-- Jede Zustellung filtert ueber genau diese drei Spalten (Kern-Block,
-- Geltungsfilter, Verfall). Ohne Index laeuft der Session-Start-Hook bei jedem
-- Start einen Full Scan.
CREATE INDEX IF NOT EXISTS idx_rules_zustellung
  ON rules(status, verbindlichkeit, geltung);

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
    "geltung", "verbindlichkeit", "anker", "nachweis", "leser", "verfall",
    "leiter", "status",
)

# ── Erlaubte Werte des Regel-Schemas v2 ───────────────────────────────────
#
# Feste Rollen und freie Projektbindung stehen getrennt: `projekt:<name>` ist
# offen (jedes registrierte Projekt), die vier Rollen sind es nicht. Ein
# Tippfehler in der Rolle (`workr`) muss auffallen und darf nicht als neue
# Geltung durchgehen — sonst bindet die Regel niemanden und niemand merkt es.
ROLLEN = ("flotte", "firstmate", "secondmate", "worker")
PROJEKT_GELTUNG = re.compile(r"^projekt:[A-Za-z0-9._-]+$")

VERBINDLICHKEITEN = ("kern", "kontext", "hinweis")
STATUS_WERTE = ("aktiv", "abgelaufen", "hinweis-abgestuft")

# Wohin eine Streichung fuehren kann. Steht hier und nicht in `streich.py`,
# damit die Kommandozeile die Auswahl anbieten kann, ohne den halben Ingest zu
# laden — und damit es die Liste genau einmal gibt.
STREICH_ZIELE = ("hinweis", "geloescht")

# `retrieval` ist der einzige Leser ohne Pfad: dort liest kein benanntes
# Skript, sondern die Zustellung selbst.
LESER_MIT_PFAD = ("hook", "tor", "werkzeug")
LESER_OHNE_PFAD = ("retrieval",)

ANKER = re.compile(r"^(L\d{2}|HR\d+)$")
NACHWEIS = re.compile(r"^(grundsatz:\d+|order:O-[A-Za-z0-9-]+|captain-wort:\d{4}-\d{2}-\d{2})$")

# ── Schema-Versionierung je Regel ─────────────────────────────────────────
#
# Der Bestand ist zweisprachig und bleibt es: v1-Regeln (id/trigger/statement/
# mandatory/tags/relations) und v2-Regeln (zusaetzlich geltung/verbindlichkeit/
# anker/quelle/leser/verfall/leiter). Welche Fassung gilt, entscheidet die
# einzelne REGEL, nicht ein globaler Schalter — sonst muesste jeder Bestand an
# einem einzigen Tag komplett umziehen, und bis dahin liefe gar nichts.
#
# v2 ist eine Regel, sobald sie EINES dieser Felder traegt, oder sobald ihre
# Datei `schema: v2` auf oberster Ebene deklariert. `status` steht bewusst
# NICHT in der Liste: es hat einen Vorgabewert und wuerde sonst jede Regel
# markieren, die nur ihren Zustand nennt.
V2_MARKER = ("geltung", "verbindlichkeit", "anker", "quelle", "leser",
             "verfall", "leiter")

# Was eine v1-Regel beim Ingest bekommt (Vorgaben des Legacy-Modus, Vertrag
# im Kopf von ingest.py).
V1_GELTUNG = "flotte"
V1_LESER = "retrieval"
V1_STATUS = "aktiv"


def anker_liste(wert) -> list[str]:
    """Anker kommen als Liste (Ingest) oder als Zeile (Datenbank) an.

    Steht hier und nicht in `yamlio`, weil die Kommaschreibweise eine
    Eigenschaft der SPALTE ist — und damit Ingest, Rueckschreibung und
    Schema-Erkennung dieselbe Lesart benutzen.
    """
    if wert is None:
        return []
    if isinstance(wert, str):
        return [t.strip() for t in wert.split(",") if t.strip()]
    return [str(t).strip() for t in wert if str(t).strip()]


def ist_v1_profil(regel) -> bool:
    """Traegt diese Regelzeile GENAU die Vorgaben des Legacy-Modus?

    Der Rueckweg braucht das: aus der Datenbank kommt keine Regel mit ihrem
    YAML zurueck, nur mit ihren Spalten — die Weboberflaeche und der Export
    sehen also keinen Schluessel mehr, an dem die Fassung haenge. Das Profil
    reicht trotzdem eindeutig, denn eine v2-Regel KANN es nicht tragen: v2
    verlangt Anker oder Nachweis, und beides ist hier leer.
    """
    return (
        (regel.get("geltung") or V1_GELTUNG) == V1_GELTUNG
        and (regel.get("verbindlichkeit") or "kontext") in ("kern", "kontext")
        and (regel.get("leser") or V1_LESER) == V1_LESER
        and (regel.get("status") or V1_STATUS) == V1_STATUS
        and not anker_liste(regel.get("anker"))
        and not regel.get("nachweis")
        and not regel.get("verfall")
        and not regel.get("leiter")
    )


def geltung_gueltig(wert: str) -> bool:
    return wert in ROLLEN or bool(PROJEKT_GELTUNG.match(wert or ""))


def leser_gueltig(wert: str) -> bool:
    if wert in LESER_OHNE_PFAD:
        return True
    art, _, pfad = (wert or "").partition(":")
    return art in LESER_MIT_PFAD and bool(pfad.strip())


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
