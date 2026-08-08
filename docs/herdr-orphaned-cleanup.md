# Orphaned Herdr Presentation Cleanup

## Purpose
Herdr presentation journals accumulate in `state/` as `.herdr-presentation` files. When tasks are abandoned or removed, these journals become orphaned and prevent task IDs from being reused.

## Cleanup Record (2026-08-08)

Removed 6 orphaned Herdr presentation journals that were blocking task-id reuse:

1. `aka77-lavish-design.herdr-presentation` (326B)
2. `aka77-light-dark.herdr-presentation` (317B)
3. `aka77-lightbox-nav.herdr-presentation` (323B)
4. `aka77-restore-fr-pages.herdr-presentation` (335B)
5. `diagnose-decap-cms.herdr-presentation` (323B)
6. `pi-info-color-scout-pi-terminal-status-title-v3-crash-15.herdr-presentation` (437B)

### Associated State Files Removed
Each orphaned journal also had associated watcher state markers that were cleaned up:
- `.hb-surfaced-*` markers (heartbeat surfaced tracking)
- `.seen-*_status` and `.seen-*_turn-ended` markers (watcher seen tracking)

### Verification
- `herdr workspace list --session default` confirms no references to removed task IDs
- Confirmed no orphaned `.meta` or `.status` files remain for these task IDs
- Remaining `.herdr-presentation` files verified to be for active tasks

### Task-ID Reuse Unblocked
Removing these orphaned journals clears the way for these task IDs to be reused in future work.
