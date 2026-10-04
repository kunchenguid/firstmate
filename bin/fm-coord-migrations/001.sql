CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE participants (
  home_id TEXT PRIMARY KEY,
  repos_json TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  boot_id TEXT,
  session_id TEXT
);
CREATE TABLE areas (
  repo TEXT NOT NULL,
  name TEXT NOT NULL,
  paths_json TEXT NOT NULL,
  PRIMARY KEY (repo, name)
);
CREATE TABLE area_aliases (
  repo TEXT NOT NULL,
  alias TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (repo, alias),
  FOREIGN KEY (repo, name) REFERENCES areas(repo, name)
);
CREATE TABLE intents (
  intent_id TEXT PRIMARY KEY,
  home_id TEXT NOT NULL REFERENCES participants(home_id),
  generation INTEGER NOT NULL,
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  base_oid TEXT NOT NULL,
  branch TEXT NOT NULL,
  task_id TEXT NOT NULL,
  issue TEXT,
  pr_url TEXT,
  goal TEXT NOT NULL,
  resources_json TEXT NOT NULL,
  read_dependencies_json TEXT NOT NULL,
  predecessors_json TEXT NOT NULL,
  expected_artifacts_json TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'submitted',
  created_at TEXT NOT NULL
);
CREATE TABLE claims (
  fence INTEGER PRIMARY KEY AUTOINCREMENT,
  claim_id TEXT NOT NULL UNIQUE,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  home_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  version INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active','expired','released','revoked')),
  expires_mono_ns INTEGER NOT NULL,
  boot_id TEXT NOT NULL
);
CREATE INDEX claims_active ON claims(state, intent_id);
CREATE TABLE claim_resources (
  claim_id TEXT NOT NULL REFERENCES claims(claim_id),
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (claim_id, kind, name)
);
CREATE INDEX claim_resources_lookup ON claim_resources(kind, name);
CREATE TABLE branch_owners (
  repo TEXT NOT NULL,
  branch TEXT NOT NULL,
  claim_id TEXT NOT NULL,
  fence INTEGER NOT NULL,
  home_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  PRIMARY KEY (repo, branch)
);
CREATE TABLE allocation_counters (
  repo TEXT NOT NULL,
  namespace TEXT NOT NULL,
  next_number INTEGER NOT NULL,
  PRIMARY KEY (repo, namespace)
);
CREATE TABLE allocations (
  allocation_id TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  namespace TEXT NOT NULL,
  number INTEGER NOT NULL,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  state TEXT NOT NULL DEFAULT 'reserved',
  created_at TEXT NOT NULL,
  UNIQUE (repo, namespace, number)
);
CREATE TABLE heads (
  head_id TEXT PRIMARY KEY,
  intent_id TEXT NOT NULL REFERENCES intents(intent_id),
  head_oid TEXT NOT NULL,
  expected_previous_oid TEXT,
  claim_id TEXT NOT NULL,
  fence INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (intent_id, head_oid)
);
CREATE TABLE requests (
  actor TEXT NOT NULL,
  request_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  digest TEXT NOT NULL,
  result_json TEXT NOT NULL,
  PRIMARY KEY (actor, request_id)
);
CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  request_id TEXT,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE outbox (
  event_id TEXT PRIMARY KEY REFERENCES events(event_id),
  acknowledged_at TEXT
);
