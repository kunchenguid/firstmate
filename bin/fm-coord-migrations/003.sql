CREATE TABLE ci_batches (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  head_oid TEXT NOT NULL,
  event_id TEXT NOT NULL REFERENCES events(event_id),
  PRIMARY KEY (repo, base_ref, batch_id)
);
