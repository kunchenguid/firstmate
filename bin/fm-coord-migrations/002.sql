CREATE TABLE check_manifests (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  version INTEGER NOT NULL,
  checks_json TEXT NOT NULL,
  PRIMARY KEY (repo, base_ref)
);
CREATE TABLE queue_items (
  intent_id TEXT PRIMARY KEY REFERENCES intents(intent_id),
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  head_oid TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('ready','syncing','validating','awaiting-checks','attempting','outcome-unknown','sync-needed','repair-needed','merged','refused')),
  priority INTEGER NOT NULL DEFAULT 0,
  ready_epoch INTEGER NOT NULL,
  base_oid TEXT,
  validation_id TEXT,
  manifest_version INTEGER,
  attempt_event_id TEXT UNIQUE,
  updated_at TEXT NOT NULL
);
CREATE INDEX queue_items_pick ON queue_items(repo,base_ref,state,ready_epoch);
CREATE TABLE integration_slots (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  generation INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('syncing','validating','awaiting-checks','attempting','outcome-unknown')),
  PRIMARY KEY (repo,base_ref)
);
CREATE TABLE integration_generations (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  generation INTEGER NOT NULL,
  PRIMARY KEY (repo,base_ref)
);
CREATE TABLE merge_outcomes (
  attempt_event_id TEXT PRIMARY KEY REFERENCES events(event_id),
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  outcome TEXT NOT NULL CHECK (outcome IN ('merged','refused')),
  merge_oid TEXT,
  observed_base_oid TEXT NOT NULL,
  recorded_at TEXT NOT NULL
);
