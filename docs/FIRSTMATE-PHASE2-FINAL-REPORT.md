# FirstMate / Agentic Platform — Final Report (2026-07-25)

**Host:** Cerberus (`unifiedops@…:2212`)  
**FirstMate home:** `/home/unifiedops/agentic/firstmate`  
**Branch:** `phase2/durable-programme` @ `cf73f9e` (+ follow-up CI fail-fast)  
**Upstream PR:** https://github.com/kunchenguid/firstmate/pull/1042  
**Fork:** https://github.com/Gerlionx/firstmate  

This report covers **agentic platform / FirstMate improvements only**. A one-commit gallery pilot was used to **prove** the environment; it is **not** the start of Epic Northscapes product delivery.

---

## 1. What the platform was before

Working pieces already present:

- OpenCode primary in tmux (`~/agentic/start-firstmate.sh`, OSC filter)
- Crewmate spawn via `fm-spawn.sh` + Treehouse worktrees
- Watcher (`fm-watch.sh` / `fm-watch-arm.sh`) + turn-end / status wakes
- Harnesses including **Cursor Agent** (`agent --print`, model `auto`) via local dispatch rules
- no-mistakes gate + `gh` auth
- Markdown backlog (`tasks-axi` / `data/backlog.md`)

Gaps that caused “stop after every task / lose state / one worker feel”:

- No programme/phase SQLite authority (chat + backlog prose were easy to treat as truth)
- No structured task packets / AC matrix / RESULT+REVIEW artifacts
- No concurrency scheduler (policy allowed parallel; practice was sequential)
- No Phase 2 ops resume view / ledger
- CI wait could hang forever when a repo has **no GitHub Actions**
- Independent review not first-class outside no-mistakes

---

## 2. What we improved (FirstMate Phase 2 overlay)

### Durable programme control
- SQLite registry: `state/programme.db` (`phase2/lib/registry.py`, `bin/fm-phase2-registry.sh`)
- Atomic status transitions + `transitions` audit log
- States: planned → … → approved/merged + blocked/failed/cancelled
- Resume without chat: `scripts/firstmate-resume.sh`
- Human ledger: `docs/IMPLEMENTATION-EXECUTION-LEDGER.md` (`scripts/firstmate-ledger-update.sh`)

### Durable task packets
- `bin/fm-phase2-packet.sh` → `data/<id>/packet/{TASK,CONTEXT,ACCEPTANCE,FILE-OWNERSHIP,TEST-PLAN,RESULT,REVIEW,STATE}.json`

### Parallel workers (controlled)
- `phase2/config/concurrency.json` — max 3 implementers, 1 reviewer, 1 migration; deploy off
- `bin/fm-phase2-schedule.sh` — deps + file-ownership conflict avoidance

### Events + watchdog
- `bin/fm-phase2-event.sh` + `bin/fm-phase2-eventd.sh` (Unix socket + filesystem queue)
- `bin/fm-phase2-heartbeat.sh` — beat / stale scan / 1–2–3 failure policy
- systemd user units: `firstmate-phase2-eventd.service`, `firstmate-phase2-watchdog.timer`

### Worktrees
- Existing Treehouse kept as primary
- Optional helper: `bin/fm-phase2-worktree.sh` (never auto-delete dirty)

### CI / review / no-mistakes adapters
- `bin/fm-phase2-ci.sh` — record/wait/logs/repair; **now fails fast** if no Actions runs (`exit 4` / `none_configured`)
- `bin/fm-phase2-review.sh` — per-AC REVIEW.md gate
- `bin/fm-phase2-no-mistake.sh` — axi adapter → `NO-MISTAKE.md` (does not pretend if missing)

### Skills + worker profiles
- `phase2/skills/*` (12) and `phase2/profiles/*.json` (10 specialised roles)
- Playwright persona kit stub: `phase2/playwright/`

### Ops + safety
- `bin/fm-phase2-status.sh`
- Backup: `backups/phase2-*` + `scripts/rollback-firstmate-phase2.sh`
- Docs: audit, architecture, operations, recovery, security, CI, no-mistake, skills, profiles, pilot

### Self-tests
- `tests/phase2/run-all.sh` — **16/16 PASS** (registry, deps, schedule conflicts, events, review, resume, etc.)

### Cursor coding path (already started earlier; kept)
- Dispatch: important coding → `harness=cursor model=auto`
- Trivia → OpenCode DeepSeek free

---

## 3. Environment proof (not “building Epic”)

One bounded Cursor crewmate was spawned to prove the stack end-to-end:

| Step | Result |
|------|--------|
| Packet + brief | Done |
| `fm-spawn.sh … --harness cursor --model auto` | Pane + Treehouse worktree |
| Implementation + commit | `257a07d` on `fm/pilot-db-collection` |
| Unit tests | 13/13 green |
| Independent REVIEW.md | All ACs PASS |
| no-mistakes | intent→rebase→review→test→document→lint→**push→PR** |
| PR | https://github.com/Gerlionx/northscapes-gallery/pull/17 |
| GitHub Actions CI | **None configured** on that repo/branch → indefinite wait; **aborted on purpose** |
| Registry close | `pilot-db-collection` → **approved** with `ci_run=none_configured` |

That gallery commit exists only as a **smoke payload**. Remaining pilot-* planned tasks are **not** a mandate to continue product work.

---

## 4. What FirstMate can do now

1. Keep durable programme/task state across restarts (SQLite + resume + ledger)  
2. Spawn isolated Cursor (or OpenCode) crewmates in Treehouse worktrees  
3. Detect turn-end / status / wakes (existing watcher) + Phase 2 events/heartbeats  
4. Schedule up to **3** non-conflicting implementers  
5. Drive independent AC review artifacts  
6. Invoke no-mistakes via adapter and record outcomes  
7. Read GitHub Actions when they exist; **fail fast** when they don’t  
8. Create CI repair task shells when a run id exists  
9. Show ops status / resume next safe actions  
10. Roll back Phase 2 overlay via documented backup script  

---

## 5. What still needs implementing (gaps)

| Gap | Severity | Notes |
|-----|----------|--------|
| Primary OpenCode auto-loop calling Phase 2 schedule after every done | Medium | Scripts exist; primary still must invoke them (or add a thin hook) |
| Gallery (and other product repos) **GitHub Actions** | High for “CI gate” | Without workflows, no-mistakes `ci` step waits forever |
| Wire eventd → primary wake (beyond socket/files) | Low | Polling watcher remains the reliable fallback |
| Full Playwright pilot against live UI | Low for env | Persona kit only; not required for FirstMate readiness |
| Cancel/hold leftover `pilot-*` planned product tasks | Hygiene | Optional — avoid confusing “ready to build Epic” |
| FirstMate primary still on `phase2/durable-programme` branch | Hygiene | Causes worktree-tangle warning; keep Phase 2 on a worktree or merge/checkout strategy |
| Push to upstream `kunchenguid/firstmate` | Process | Done via fork + PR #1042; maintainers must merge |
| systemd linger / boot persistence | Low | User units enabled; confirm `loginctl enable-linger` if needed after reboot |
| Secret-safe worker sandbox beyond profile JSON | Medium | Profiles document denies; not OS-level sandboxing |

---

## 6. Exact operating commands

```bash
ssh cerberus
cd ~/agentic/firstmate
export FM_HOME=$PWD PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

scripts/firstmate-resume.sh
bin/fm-phase2-status.sh
bin/fm-phase2-schedule.sh --programme pilot-collections   # or your programme
bin/fm-spawn.sh <id> projects/<repo> --harness cursor --model auto
bin/fm-watch-arm.sh
bin/fm-phase2-heartbeat.sh beat <id>
scripts/rollback-firstmate-phase2.sh                      # if needed
```

Services:

```bash
systemctl --user status firstmate-phase2-eventd.service
systemctl --user status firstmate-phase2-watchdog.timer
```

---

## 7. Verdict

**FirstMate is substantially improved as an agentic control plane** for long-running multi-crew work: durable state, packets, parallelism controls, review/NM/CI adapters, recovery docs, and a proven Cursor spawn path.

**It is ready to run engineering tasks.**  
**It is not “Epic Northscapes finished,” and you should not treat the leftover pilot task list as a product roadmap until you explicitly start that programme.**

Highest-value next env work (not app features):

1. Add GitHub Actions to product repos so CI gates terminate  
2. Teach the primary a standing order: on `done:` → ledger → schedule → spawn next  
3. Keep FirstMate `main` clean; develop Phase 2 on a dedicated worktree/branch without tangling the primary checkout  
