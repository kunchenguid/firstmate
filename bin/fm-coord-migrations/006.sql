ALTER TABLE participants ADD COLUMN host_id TEXT;
ALTER TABLE queue_items ADD COLUMN wrapper_home_id TEXT;
ALTER TABLE queue_items ADD COLUMN wrapper_host_id TEXT;
ALTER TABLE queue_items ADD COLUMN wrapper_local INTEGER;
ALTER TABLE queue_items ADD COLUMN wrapper_exit_attested_at INTEGER;
UPDATE queue_items SET wrapper_home_id=(SELECT home_id FROM intents WHERE intents.intent_id=queue_items.intent_id),wrapper_host_id='legacy-coordinator',wrapper_local=1 WHERE attempt_event_id IS NOT NULL AND wrapper_host_id IS NULL;
