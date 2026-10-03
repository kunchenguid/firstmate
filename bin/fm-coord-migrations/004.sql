CREATE TABLE fenced_ci_batches (
  repo TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  PRIMARY KEY (repo, base_ref, batch_id)
);
