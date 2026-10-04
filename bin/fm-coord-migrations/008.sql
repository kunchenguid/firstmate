CREATE TABLE IF NOT EXISTS ci_capacity (
  repo TEXT PRIMARY KEY,
  capacity INTEGER NOT NULL CHECK (capacity > 0),
  ttl_seconds INTEGER NOT NULL CHECK (ttl_seconds > 0)
);
CREATE TABLE IF NOT EXISTS ci_heads (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  head_oid TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('queued', 'active')),
  delivered INTEGER NOT NULL DEFAULT 0,
  event_id TEXT REFERENCES events(event_id),
  admitted_at INTEGER,
  UNIQUE (repo, base_ref, batch_id),
  UNIQUE (repo, head_oid)
);
