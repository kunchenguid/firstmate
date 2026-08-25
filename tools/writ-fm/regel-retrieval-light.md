# Regel-Retrieval Light — Architektur-Skizze

Ziel: Writ-Funktionalität (relevante Regeln pro Prompt statt Context-Stuffing) ohne Docker, ohne Neo4j, ohne Daemon-Zwang. Zielgröße: < 200 MB RAM, eine einzige SQLite-Datei + ein Index-File.

## Komponenten

```
┌─────────────────────────────────────────────────┐
│  Claude Code Hook (UserPromptSubmit)            │
│  ruft: writ-light query "<user prompt>"         │
└────────────────────┬────────────────────────────┘
                     │
         ┌───────────▼───────────┐
         │   writ-light (CLI)    │   Python, ~300 Zeilen
         ├───────────────────────┤
         │ 1. FTS5 (BM25)        │──┐
         │ 2. hnswlib (Vektor)   │──┼─► RRF-Merge
         │ 3. Relations (1-Hop)  │──┘   + Budget
         │ 4. Mandatory-Regeln   │────► immer dabei
         └───────┬───────┬───────┘
                 │       │
        rules.db │       │ vectors.hnsw
        (SQLite) │       │ (hnswlib-Datei)
                 ▼       ▼
```

**Stack:** Python 3.11+, `sqlite3` (stdlib), `hnswlib`, `onnxruntime` + ein kleines Embedding-Modell. Kein Docker, kein externer Dienst. FTS5 ersetzt Tantivy — SQLite bringt BM25-Ranking von Haus aus mit.

## Datenmodell (SQLite)

```sql
CREATE TABLE rules (
  id         TEXT PRIMARY KEY,   -- z.B. 'RN-SKIA-001'
  domain     TEXT,               -- z.B. 'react-native', 'shader', 'onboarding'
  severity   INTEGER,            -- 1–3
  mandatory  INTEGER DEFAULT 0,  -- 1 = ENF-Regel, umgeht Ranking
  trigger    TEXT,               -- WANN gilt die Regel
  statement  TEXT,               -- die Regel selbst
  violation  TEXT,               -- Negativbeispiel
  correct    TEXT,               -- Positivbeispiel
  tags       TEXT,               -- kommagetrennt
  confidence REAL DEFAULT 1.0
);

-- BM25-Volltextsuche, gespiegelt aus rules
CREATE VIRTUAL TABLE rules_fts USING fts5(
  trigger, statement, tags,
  content=rules, content_rowid=rowid
);

-- Der "Graph": eine simple Beziehungstabelle
CREATE TABLE relations (
  src  TEXT REFERENCES rules(id),
  dst  TEXT REFERENCES rules(id),
  kind TEXT CHECK(kind IN ('DEPENDS_ON','CONFLICTS_WITH','SUPPLEMENTS'))
);
CREATE INDEX idx_rel_src ON relations(src);
```

Das ersetzt Neo4j vollständig: Writ nutzt ohnehin nur einen vorberechneten Adjacency-Cache mit 1-Hop-Nachbarschaft — genau das ist hier ein indizierter JOIN.

## Retrieval-Pipeline

```python
def query(prompt: str, budget_tokens: int = 2000) -> list[Rule]:
    # 1. BM25 über FTS5 (Top 20)
    bm25 = db.execute(
        "SELECT rowid, rank FROM rules_fts WHERE rules_fts MATCH ? "
        "ORDER BY rank LIMIT 20", (fts_escape(prompt),))

    # 2. Vektor-Suche (Top 20)
    vec = hnsw_index.knn_query(embed(prompt), k=20)

    # 3. RRF-Merge (k=60), gewichtet ~ Writ: Vektor 0.6 / BM25 0.2
    #    + severity 0.1 + confidence 0.1
    ranked = rrf_merge(bm25, vec, weights=(0.2, 0.6, 0.1, 0.1))

    # 4. 1-Hop-Expansion: DEPENDS_ON-Nachbarn der Top-3 anhängen
    ranked += neighbors(ranked[:3], kind="DEPENDS_ON")

    # 5. Mandatory-Regeln IMMER voranstellen (ungerankt)
    mandatory = db.execute("SELECT * FROM rules WHERE mandatory=1")

    return apply_budget(mandatory + dedupe(ranked), budget_tokens)
```

## Embeddings

- Modell: `paraphrase-multilingual-MiniLM-L12-v2` als ONNX (~120 MB auf Platte, ~90 MB RAM) — multilingual, da deine Regeln vermutlich Deutsch/Englisch gemischt sind.
- Embedding pro Regel: `trigger + statement` konkateniert, einmalig beim Ingest.
- Index: `hnswlib.Index(space='cosine', dim=384)`, als Datei persistiert. Bei < 10.000 Regeln ist der Index wenige MB groß.

## Betriebsmodi

**Modus A — reines CLI (empfohlen zum Start):** Der Hook ruft das Skript direkt auf. Kaltstart ~1–2 s wegen Modell-Load. Da das LLM pro Turn ohnehin Sekunden braucht, ist das praktisch egal. 0 MB RAM im Leerlauf.

**Modus B — Mini-Daemon (optional, später):** `http.server` oder FastAPI hält Modell + Indizes warm → Antwort < 10 ms. ~150–200 MB dauerhaft. Nur nötig, wenn dich die 1–2 s stören.

## Claude-Code-Integration

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "python ~/.claude/writ-light/query.py"
      }]
    }]
  }
}
```

Das Skript liest den Prompt von stdin (JSON), gibt den Regelblock auf stdout aus — Claude Code injiziert stdout eines UserPromptSubmit-Hooks automatisch als Kontext. Ausgabeformat analog Writ:

```
--- REGELN (4 Treffer + 2 mandatory) ---
[ENF-SEC-001] MANDATORY
RULE: Keine Secrets in Logs oder Commits.
...
--- ENDE REGELN ---
```

## Ingest-Workflow

1. Regel-Prompts → strukturierte YAML/JSON-Dateien (eine Datei pro Domain).
2. `writ-light ingest rules/` — parst, schreibt SQLite, baut FTS5 + hnswlib neu.
3. Idempotent: kompletter Neuaufbau dauert bei ein paar hundert Regeln < 30 s.

## Kimi-Code-Integration (2026-08-05, ausgebaut am 2026-08-07)

**Historisch.** Kimi Code ist am 2026-08-07 auf diesem Laptop außer Dienst
gegangen; Skripte, Plugin und die Fallunterscheidung im Code sind entfernt.
Der Abschnitt bleibt als Protokoll dessen stehen, was gemessen wurde.

Kimi Code lud Plugin-`hooks.json` nicht, wohl aber `[[hooks]]`-Blöcke in
`~/.kimi-code/config.toml` (Events `SessionStart`, `UserPromptSubmit` u. a.).
stdout eines Hooks mit Exit 0 wurde als Kontext übernommen — der JSON-Umschlag
entfiel, die Skripte liefen im Plain-Modus. Kimis Hook-Payload wich ab
(`prompt` als Liste von Content-Parts); das Parsing übernahm
`hooks.eingabe_lesen`. Mit diesem Weg ist die Übergangsregel ENF-QUERY-001
entfallen.

Geblieben ist genau eine Zeile Erbe: `hooks._prompt_text` versteht weiterhin
Content-Parts. Nicht aus Nostalgie — ein Frontend, das dieses Format schickt,
bekäme sonst still einen leeren Prompt und damit die falschen Regeln, statt
zu scheitern.

## Memory (2026-08-05)

Session-übergreifende, kuratierte Fakten (`writ-light memory add/query/list`):

- Eigene Tabelle `memory` in `rules.db` — **nicht** Teil von `schema.reset`,
  damit der Ingest sie nicht mit abräumt; angelegt wird sie bei Bedarf durch
  `memory.connect`, auch bei Altbeständen ohne erneuten Ingest.
  Bis 2026-08-07 galt das nur für die Tabelle, nicht für ihren Zähler:
  `schema.reset` warf `meta` komplett weg und nahm `memory_index_count` mit.
  Kein Datenverlust, aber `doctor` war nach jedem Ingest rot und konnte den
  echten Fall nicht mehr vom Normalzustand unterscheiden. Seither räumt
  `reset` nur den eigenen Schlüssel `index_count` ab.
- Reparaturweg `writ-light memory reindex`: baut den Vektorindex aus der
  Tabelle neu und setzt den Zähler. Ohne ihn hatte der doctor-Befund kein
  Gegenmittel — und ein Befund ohne Gegenmittel erzieht dazu, ihn zu
  überlesen.
- Eigener Vektorindex `vectors-memory.hnsw` (gleiches Embedding-Modell,
  Label = `memory.id`), inkrementell befüllt; Zähler in
  `meta.memory_index_count` (doctor prüft die Deckung).
- Recall nur vektorbasiert mit Cosine-Schwelle 0.7 (gemessen: Verwandtes
  0.30–0.64, Fremdes ~1.07) — lieber kein Treffer als ein falscher.
- Projektbindung wie beim Regel-Retrieval (`retrieve.aktives_projekt`):
  Einträge sind global (`project NULL`) oder an genau ein Projekt gebunden.
- Einbindung: Session-Start zeigt die fünf jüngsten Einträge,
  UserPromptSubmit hängt bis zu drei passende an den Regelblock.
- Bewusst kuratiert (Regeln MEM-SAVE-001/MEM-SEC-001): kein automatisches
  Mitschreiben, keine LLM-Kosten, keine Secrets im Memory.

## Vergleich zu Writ

| | Writ | Light |
|---|---|---|
| RAM | ~2–3 GB (Docker + Neo4j + Daemon) | 0 (CLI) bzw. ~200 MB (Daemon) |
| Abhängigkeiten | Docker, Neo4j, Tantivy, FastAPI | Python + 2 pip-Pakete |
| Graph | Neo4j, Gewicht 0.010 im Ranking | SQL-JOIN, gleicher Effekt |
| Retrieval-Qualität | Vektor + BM25 dominieren | identische Signale |
| Migration | — | Regelformat kompatibel, Wechsel jederzeit möglich |

## Ausbaustufen (später, bei Bedarf)

- Konfidenz-Tracking (Spalte ist schon da) mit Feedback-Kommando
- Abstraktions-Summaries pro Domain für enge Budgets
- CONFLICTS_WITH-Check beim Ingest (SQL-Query statt Neo4j-Gate)
