# FirstMate Phase 2 — Environment Audit

**Host:** `cerberus` (Ubuntu 26.04 LTS, kernel 7.0.0-28-generic)  
**Hardware:** Gigabyte Z87X-UD4H desktop · 8 CPU · 22 GiB RAM (~16 GiB available) · `/` 233 G (~48% used, 117 G free) · bulk disks at `/mnt/storage{2,3,4}`  
**Audited:** 2026-07-25  
**Live FirstMate home:** `/home/unifiedops/agentic/firstmate`  
**Git:** `https://github.com/kunchenguid/firstmate.git` @ `5c89d36` (`main`) with local uncommitted Cursor-harness wiring; Phase 2 branch `phase2/durable-programme`

---

## Verdict

FirstMate is **already a capable multi-crew orchestration system** (spawn → Treehouse worktree → harness → watcher → status/turn-end wakes → no-mistakes → PR). Gaps vs the Phase 2 wish-list are mostly **programme-level durability, explicit concurrency scheduling, structured task packets, independent review gate, CI-repair task typing, Playwright persona kit, and systemd supervision** — not a missing spawn/watch core.

**Destructive risk:** none found that blocks continuation. Strategy: **extend** (Phase 2 overlay + SQLite programme registry) rather than replace spawn/watch/Treehouse/no-mistakes.

---

## 1. How a crewmate launches

Entry: `bin/fm-spawn.sh <task-id> <project-dir> [--harness …] [--model …] [--effort …] [--backend …] [--scout]`

1. Resolves backend (`--backend` → `FM_BACKEND` → `config/backend` → detect → **tmux**). This home: `config/backend` = `tmux`.
2. Resolves harness. With `config/crew-dispatch.json` present, crewmate/scout spawns **require explicit `--harness`** (primary consults dispatch rules). Current dispatch: product coding → `cursor` / `model=auto`; trivia → `opencode` / DeepSeek free.
3. Allocates an isolated Treehouse worktree (`treehouse get`); refuses launch if path is not a distinct worktree root.
4. Writes `state/<id>.meta`, installs turn-end signaling, launches harness in a tmux pane.
5. Prints: `spawned <id> harness=… kind=… window=… worktree=…`

Cursor template (local extension on this install): `agent --print --force --trust …; touch state/<id>.turn-ended`.

Startup of the primary: `~/agentic/start-firstmate.sh` → tmux session `firstmate` → OpenCode behind `osc-filter`.

---

## 2. How FirstMate knows a crewmate finished

| Signal | Role |
|--------|------|
| Append to `state/<id>.status` (`done:`, `failed:`, `blocked:`, …) | Captain-relevant wake verbs |
| `state/<id>.turn-ended` | Harness turn ended (hooks / Cursor process exit) |
| `bin/fm-watch.sh` | Blocks until actionable wake; durable `.wake-queue` |
| `bin/fm-classify-lib.sh` + `bin/fm-crew-state.sh` | Classify; no-mistakes run state authoritative when branch/head matches |
| `bin/fm-watch-arm.sh` | Verified arm/reattach of watcher (PID + fresh beacon) |

Status files are **append-only event logs**, not current-state fields. Current state is computed by `fm-crew-state.sh`.

---

## 3. How tasks survive a restart

| Store | Contents |
|-------|----------|
| `data/<id>/brief.md` | Task contract (filled after scaffold) |
| `data/backlog.md` | Task backlog (`.tasks.toml` → markdown backend) |
| `state/<id>.meta` | Endpoint, worktree, harness, PR pointers |
| `state/<id>.status` | Event log |
| `state/.wake-queue` | Durable wakes across process death |
| Treehouse / tmux | Live worktrees and panes |

`bin/fm-session-start.sh` reacquires lock, drains wake queue, reads backlog/meta/status. **Conversation memory is not required** for in-flight crews, but there is **no programme/phase SQLite registry** and no structured state machine with the Phase 2 verb set (`planned` → `merged`, etc.).

---

## 4. How worker failure is detected

- Stale pane / dead agent → watcher stale wake; dead pane without active no-mistakes run → `unknown` (not false-complete).
- Wedge escalation (~240 s default); repeated escalations → `demand-deep-inspection`.
- Watcher liveness: `state/.last-watcher-beat` + lock identity (`fm-watch-arm.sh` / `fm-guard.sh`).
- Away mode: `fm-supervise-daemon.sh` with crash backoff and escalation digest.
- **No explicit per-worker heartbeat file** published by Cursor crewmates; heartbeats are fleet/watcher backstops.

---

## 5. Why only one crewmate appears to run

**There is no fleet-wide `max_workers=1`.** `AGENTS.md` says dispatch isolated work with **no concurrency cap**; serialize only for true semantic/shared-state conflicts. Locks serialize same-task spawn, one watcher per home, one captain session — not distinct workers. Batch spawn (`id=repo` pairs) is supported.

Observed single-crew behaviour is **captain/primary sequential dispatch**, not an engine limit. Treehouse pool currently shows 3 slots for `northscapes-gallery` (2 dirty, 1 available).

---

## 6. Can CI results be read?

**Yes.** `gh` 2.96.0 authenticated as `Gerlionx` with `repo` + `workflow` scopes.

| Tool | Behaviour |
|------|-----------|
| `gh run list` / `gh pr checks` | Live Actions/check reads work |
| `fm-pr-check.sh` | Records PR metadata; arms merge poll |
| `fm-pr-poll.sh` | Silent until exact `merged` |
| no-mistakes `ci` step | Watched via `fm-crew-state.sh` (log markers) |

Gap: no first-class **CI-failure → bounded repair task** factory outside the original worker’s no-mistakes loop.

---

## 7. How No Mistake is invoked

- Binary: `/home/unifiedops/.local/bin/no-mistakes` → v1.41.2  
- Agent interface: `no-mistakes axi run|status|logs|respond|abort|sync`  
- Skill: `~/.claude/skills/no-mistakes` / `~/.agents/skills/no-mistakes`  
- Project gate config: `.no-mistakes.yaml` in FirstMate repo; gallery has no-mistakes remotes  
- Delivery modes in `data/projects.md`: `no-mistakes` | `direct-PR` | `local-only`  
- Policy: **same worker** drives the pipeline; FirstMate must not `axi respond` on its behalf  

No separate Phase 2 “adapter CLI” yet that accepts a normalised task packet + stores severity-classified results beside the task.

---

## 8. What can safely be reused

| Component | Reuse |
|-----------|--------|
| `fm-spawn.sh` + Cursor harness | Keep; wrap with Phase 2 scheduler |
| Treehouse worktrees | Keep; optional path alias docs |
| `fm-watch.sh` / arm / classify / crew-state | Keep as polling fallback + completion authority |
| `fm-brief.sh` | Keep; add packet scaffold beside brief |
| tasks-axi (`npx` / `~/.npm-global/bin`, v0.2.3) | Keep for backlog.md; extend with programme SQLite |
| no-mistakes axi | Keep as ship gate |
| `gh` + existing PR poll | Keep; add CI inspect/repair helpers |
| `fm-fleet-view.sh` / bearings | Extend for ops view |
| Gallery Playwright (already in `package.json`) | Reuse for pilot personas |
| systemd user (only no-mistakes daemon today) | Add minimal Phase 2 units if needed |

**Do not replace:** watcher lock semantics, turn-end contracts, Treehouse dirty teardown refusals, no-mistakes ownership rules.

---

## Tool inventory (live)

| Tool | Status |
|------|--------|
| git 2.53 / gh 2.96 / jq / tmux 3.6 | OK |
| node v22.23.1 / python 3.14.4 / docker 29.6.2 | OK |
| cursor-agent `2026.07.23-e383d2b` | OK (logged in) |
| OpenCode 1.18.5 | OK (primary) |
| Treehouse v2.1.0 | OK |
| no-mistakes v1.41.2 | OK |
| tasks-axi 0.2.3 | Installed under `~/.npm-global/bin` (not always on bare SSH PATH) |
| Herdr | Not installed (tmux backend in use) |
| Playwright CLI | Not on PATH; **present as gallery dependency** |
| sqlite3 CLI | Not installed; **Python `sqlite3` module available** |
| Cron / FM systemd units | None for FirstMate controller/watcher |

---

## Existing skills / plugins / MCP

**FirstMate `.agents/skills/`:** afk, ahoy, ask-user-authority, bearings, bootstrap-diagnostics, decision-hold-lifecycle, diagnostic-reasoning, firstmate-codexapp, firstmate-coding-guidelines, firstmate-orca, fmx-respond, harness-adapters, project-management, secondmate-provisioning, stow, stuck-crewmate-recovery, updatefirstmate.

**User skills:** no-mistakes, tasks-axi, gh-axi, gnhf, axi, quota-axi, chrome-devtools-axi, lavish, acpx.

**Plugins:** OpenCode FM plugins under `.opencode/`; no-mistakes gate; no Epic-domain skills yet (Gelato/Stripe/etc.).

---

## Target project notes (`northscapes-gallery`)

- Remote: `Gerlionx/northscapes-gallery`  
- Scripts: lint, format, test, smoke, db migrate/seed, build  
- Playwright: already a dependency  
- Dirty Treehouse worktrees present — preserve; do not auto-destroy  

---

## Phase 2 gap map

| Wish-list item | Today | Phase 2 plan |
|----------------|-------|--------------|
| Programme/phase SQLite registry | Markdown backlog only | Add `state/programme.db` + CLI |
| Task packets (`TASK.md` … `STATE.json`) | `brief.md` only | Scaffold under `data/<id>/packet/` |
| Explicit states + atomic transitions | Event log + backlog states | SQLite transitions + audit log |
| Max 3 implementers / ownership scheduler | No cap | Configurable scheduler wrapper |
| Worker heartbeats | Watcher/fleet only | Heartbeat files + stale policy |
| Local completion events | turn-end + wake-queue | Idempotent `state/events/` + optional socket |
| Independent review | Forbidden by default outside NM | Captain-requested Phase 2 reviewer profile |
| CI repair tasks | Inside NM worker | Explicit repair task factory |
| Playwright personas | App deps only | Shared persona kit + one pilot |
| No Mistake adapter | Direct axi | Thin adapter CLI → packet report |
| systemd supervision | None for FM | Optional user units for watcher/eventd |
| Ops dashboard | fleet-view | `fm-phase2-status` |
| Self-test suite | Upstream tests | `tests/phase2/*.sh` |
| Controlled pilot | — | Collection submit/approve slice |

---

## Architecture conflict (documented, not a stop)

Upstream `AGENTS.md` treats **no-mistakes as the review authority** and discourages a separate reviewer by default. Phase 2 **independent review** is implemented as an **optional programme gate** (captain-enabled) that produces `REVIEW.md` before/alongside no-mistakes — not as a silent override of the ship pipeline.

---

## Continue?

**Yes.** No reboot, no public webhook, no production deploy, no force-push required. Next: backup + rollback docs, then implement the Phase 2 overlay on branch `phase2/durable-programme`.
