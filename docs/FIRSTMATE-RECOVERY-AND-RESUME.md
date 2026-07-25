# FirstMate — Recovery and Resume

## After FirstMate / terminal / process restart

1. SSH to Cerberus and attach tmux: `tmux attach -t firstmate` or `~/agentic/start-firstmate.sh`
2. `cd ~/agentic/firstmate && export FM_HOME=$PWD`
3. `scripts/firstmate-resume.sh` — prints programme, workers, stale, ready, next actions
4. `bin/fm-phase2-heartbeat.sh scan --recover` — applies 1st/2nd/3rd failure policy
5. `bin/fm-watch-arm.sh` — restore polling watcher
6. `systemctl --user start firstmate-phase2-eventd.service` if using eventd
7. `bin/fm-phase2-schedule.sh` — assign next safe ready tasks
8. `scripts/firstmate-ledger-update.sh`

## Authorities

- **Machine:** `state/programme.db`
- **Human:** `docs/IMPLEMENTATION-EXECUTION-LEDGER.md`
- **Compat backlog:** `data/backlog.md` (tasks-axi)
- **Live bindings:** `state/<id>.meta`

Chat history is not required.

## Failure policy

| Failure | Action |
|---------|--------|
| 1st stale/missing heartbeat | Collect context; transition back to `ready` once |
| 2nd | Mark blocked with `next_action=create_repair_task` |
| 3rd | Block permanently for auto-retry; captain intervenes |

Logs, branches, and dirty worktrees are preserved.
