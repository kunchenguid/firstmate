CREATE TABLE IF NOT EXISTS ci_batches (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  head_oid TEXT NOT NULL,
  event_id TEXT NOT NULL REFERENCES events(event_id),
  PRIMARY KEY (repo, base_ref, batch_id)
);
CREATE TABLE IF NOT EXISTS fenced_ci_batches (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  PRIMARY KEY (repo, base_ref, batch_id)
);
ALTER TABLE ci_capacity ADD COLUMN ttl_seconds INTEGER NOT NULL DEFAULT 3600;
CREATE TABLE ci_capacity_v9 (
  repo TEXT PRIMARY KEY,
  capacity INTEGER NOT NULL CHECK (capacity > 0),
  ttl_seconds INTEGER NOT NULL CHECK (ttl_seconds > 0)
);
INSERT INTO ci_capacity_v9(repo,capacity,ttl_seconds) SELECT repo,MAX(capacity),MAX(ttl_seconds) FROM ci_capacity GROUP BY repo;
DROP TABLE ci_capacity;
ALTER TABLE ci_capacity_v9 RENAME TO ci_capacity;
ALTER TABLE ci_heads ADD COLUMN admitted_at INTEGER;
UPDATE ci_heads SET admitted_at=CAST(strftime('%s','now') AS INTEGER) WHERE state='active' AND admitted_at IS NULL;
CREATE TABLE ci_heads_v9 (
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
INSERT OR IGNORE INTO ci_heads_v9(seq,repo,base_ref,batch_id,intent_id,head_oid,state,delivered,event_id,admitted_at) SELECT seq,repo,base_ref,batch_id,intent_id,head_oid,state,delivered,event_id,admitted_at FROM ci_heads ORDER BY seq;
DROP TABLE ci_heads;
ALTER TABLE ci_heads_v9 RENAME TO ci_heads
