ALTER TABLE queue_items ADD COLUMN attempt_epoch INTEGER;
ALTER TABLE queue_items ADD COLUMN wrapper_pid INTEGER;
ALTER TABLE queue_items ADD COLUMN wrapper_start TEXT;
ALTER TABLE queue_items ADD COLUMN wrapper_boot TEXT;
