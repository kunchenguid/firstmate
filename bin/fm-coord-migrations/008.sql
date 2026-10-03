CREATE TABLE ci_capacity (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  capacity INTEGER NOT NULL CHECK (capacity > 0),
  PRIMARY KEY (repo, base_ref)
);
CREATE TABLE ci_heads (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  head_oid TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('queued', 'active')),
  delivered INTEGER NOT NULL DEFAULT 0,
  event_id TEXT REFERENCES events(event_id),
  UNIQUE (repo, base_ref, batch_id),
  UNIQUE (repo, base_ref, head_oid)
);
