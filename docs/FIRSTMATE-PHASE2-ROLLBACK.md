# FirstMate Phase 2 — Rollback

## Backup location (Cerberus)

Latest audit-time backup:

`/home/unifiedops/agentic/firstmate/backups/phase2-20260725-200523`

Contains: commit SHA, branch name, git status/diff, `config/`, key `bin/` snapshots, `data/` + `state/` copy, systemd user units, tool versions. **Secrets (`.env`) are excluded.**

## Rollback script

```bash
ssh cerberus
cd ~/agentic/firstmate
./scripts/rollback-firstmate-phase2.sh
# or pin a backup:
./scripts/rollback-firstmate-phase2.sh backups/phase2-20260725-200523
```

## What rollback does

1. Stops Phase 2 user services if present (does **not** kill the OpenCode primary or unrelated crewmates unless `--stop-workers` is passed).
2. Restores `config/`, Phase 2 scripts under `bin/fm-phase2-*` / `phase2/`, and docs from the backup snapshot where applicable.
3. Moves aside `state/programme.db*` (does not delete) so the pre-Phase-2 markdown backlog remains authoritative.
4. Checks out the recorded pre-Phase-2 commit **only** if `--hard-git` is passed (destructive to uncommitted Phase 2 work — confirmation required).

## What rollback does **not** do

- Force-push or rewrite remote history
- Delete Treehouse worktrees or dirty branches
- Remove no-mistakes daemon
- Reboot the server
- Restore `.env` or credentials

## Manual minimal rollback

```bash
cd ~/agentic/firstmate
systemctl --user stop firstmate-phase2-eventd.service firstmate-phase2-watchdog.service 2>/dev/null || true
mv state/programme.db "state/programme.db.rolled-$(date +%s)" 2>/dev/null || true
git checkout main -- config/ 2>/dev/null || true
# Keep using backlog.md + existing fm-spawn / fm-watch as before
```

## Verify after rollback

```bash
bin/fm-fleet-view.sh | head
test ! -f state/programme.db && echo 'programme db aside OK' || echo 'db still present'
tmux ls
```
