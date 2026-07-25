# FirstMate Phase 2 — Operations

## Start / stop / status

```bash
ssh cerberus
cd ~/agentic/firstmate
export FM_HOME=$PWD
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

# Primary (existing)
~/agentic/start-firstmate.sh

# Phase 2 event daemon (optional systemd)
mkdir -p ~/.config/systemd/user
cp phase2/systemd/*.service phase2/systemd/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now firstmate-phase2-eventd.service
systemctl --user enable --now firstmate-phase2-watchdog.timer

# Status
bin/fm-phase2-status.sh
scripts/firstmate-resume.sh

# Stop Phase 2 services only
systemctl --user stop firstmate-phase2-eventd.service firstmate-phase2-watchdog.timer
```

## Programme & tasks

```bash
bin/fm-phase2-registry.sh init
bin/fm-phase2-registry.sh create-programme pilot-collections "Collection submit/approve pilot" --phase pilot
bin/fm-phase2-packet.sh TASK_ID --title "..." --objective "..."
bin/fm-phase2-registry.sh add-task TASK_ID pilot-collections "title" \
  --worker-type frontend_engineer --priority 50 --own 'src/routes/**'
bin/fm-phase2-registry.sh transition TASK_ID ready --reason deps_ok
bin/fm-phase2-schedule.sh --programme pilot-collections
```

## Workers

```bash
# Existing spawn (still authoritative for panes/worktrees)
bin/fm-spawn.sh TASK_ID projects/northscapes-gallery --harness cursor --model auto --effort xhigh
bin/fm-phase2-heartbeat.sh beat TASK_ID
bin/fm-phase2-heartbeat.sh scan --recover
```

## Review / No Mistake / CI

```bash
bin/fm-phase2-review.sh init TASK_ID
bin/fm-phase2-review.sh check TASK_ID
bin/fm-phase2-no-mistake.sh TASK_ID --repo-path "$WORKTREE"
bin/fm-phase2-ci.sh record TASK_ID <sha>
bin/fm-phase2-ci.sh wait TASK_ID --repo Gerlionx/northscapes-gallery
bin/fm-phase2-ci.sh repair TASK_ID --from-run <run-id> --repo Gerlionx/northscapes-gallery
```

## Worktrees

```bash
bin/fm-phase2-worktree.sh create projects/northscapes-gallery TASK_ID frontend
bin/fm-phase2-worktree.sh protect-dirty /path/to/wt
bin/fm-phase2-worktree.sh clean-merged /path/to/wt   # refuses dirty
```

## Resume / ledger / rollback

```bash
scripts/firstmate-resume.sh
scripts/firstmate-ledger-update.sh
scripts/rollback-firstmate-phase2.sh
```

## Polling fallback

```bash
bin/fm-watch-arm.sh
```
