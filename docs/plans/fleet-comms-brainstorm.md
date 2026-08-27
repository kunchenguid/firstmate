# Fleet Comms — Inter-Agent Communication over cmux

**The win:** agents that ping each other the moment work lands — no polling, no captain babysitting, no Stone asking "is it done yet." Native Claude Code teams behavior (SendMessage, done-notifications, named agents), rebuilt on cmux so it works across the *whole fleet* of long-lived terminal sessions, not just subagents inside one process.

---

## Why cmux can carry this (recon verdict: green)

cmux already ships the hard parts. We only build a thin layer on top.

| Need | cmux primitive (confirmed live) |
|---|---|
| Message delivery into an agent | `cmux send --workspace <id> "<text>"` + `send-key` |
| Real-time "agent finished" signal | event bus: `agent.hook.Stop` / `PreToolUse` / lifecycle events, per session+workspace |
| Durable, resumable event tail | `cmux events --reconnect --cursor-file <path> --category agent` (JSONL, seq cursors, survives restarts) |
| Who is running / idle / needs input | hook session store `~/.cmuxterm/<agent>-hook-sessions.json` (lifecycle: running/idle/needsInput) |
| Barriers / signals | `cmux wait-for -S <name> [--timeout]` (tmux-style) |
| Fleet dashboard | `set-status`, `set-progress`, `log`, Feed (`cmux feed tui`), notifications |
| Name → target resolution | `agent.resolve_delivery_target` RPC exists natively — investigate before writing our own |

One caveat to design around: **agent hibernation** — idle background agents can be SIGTERM'd and lazily resumed. Delivery must survive that (see mailboxes).

## The architecture: `cortana-bus` — one CLI + one postmaster daemon

Transport layer only. Tickets (Ticket Fabric) stay the work contract; the bus is how contracts move.

### 1. Universal addressing — every terminal is on the bus, day one

**Any terminal can talk to any terminal. No enrollment.** cmux already makes this true at the transport level: `cmux send` reaches any workspace/surface on the socket, and every cmux terminal knows its own identity for free (`CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` are auto-set). So the address space is cmux's own — names are optional sugar on top:

- **Base addresses (always work):** `workspace:N`, `surface:N`, tab title, or cwd match (`cortana-bus send @~/trench-os "..."`). Postmaster builds the directory from `cmux tree` + hook sessions — zero registration required.
- **Names (sugar):** `cortana-bus name <name>` claims a friendly handle (Cortana's dispatch does it automatically for crew). Auto-GC when the workspace closes.
- **Discovery:** `cortana-bus who` — live directory of *every* terminal: handle (if any), agent CLI + lifecycle (if hooked), cwd, workspace title. Any terminal can enumerate and target any other; a random shell you opened by hand is a first-class peer.
- **Sender identity** comes from the caller's own env + socket, never from message text — so a receiving agent can trust the `from:` line.

**Delivery adapts to what the target is** (postmaster picks the mode):

| Target type | How the message lands |
|---|---|
| Hooked agent CLI (claude, codex, +14 more) | mailbox + `[bus]` envelope injected when idle (§2) |
| Plain shell | mailbox + zsh `precmd` hook prints `You have fleet mail (2) — cortana-bus read` at the next prompt (never blind-inject — text typed at a shell prompt would *execute*) |
| Human-attended / focused terminal | `cmux notify` (Feed) + status badge on the workspace |

(That shell mode is Unix `write`/`wall` reborn for the agent age — and it means Stone's own terminals send and receive with the same verbs.)

### 2. Direct messages — the SendMessage equivalent

- `cortana-bus send <agent> "<text>"` — payload written to the target's **mailbox** (a file), then a one-line envelope injected into their terminal: `[bus] msg <id> from <sender> — cortana-bus read <id>`.
- **Why mailbox + pointer, not raw injection:** long payloads don't get mangled through a pty, messages survive hibernation/restart, and context stays clean (zero-noise doctrine — the agent reads the payload only when it acts on it).
- **Idle-aware delivery:** postmaster injects only when the target's lifecycle is `idle`. Injecting mid-turn corrupts an in-flight prompt. Queue until their `Stop` event fires, then deliver. A separate `--interrupt` lane (Esc first) exists for captain-only aborts.

### 3. Done-pings — the headline feature

Two modes, because `Stop` fires at every *turn* end, not *task* end:

- **Explicit (preferred, gate-honest):** finishing agent runs `cortana-bus done <ticket> --status green` — postmaster fans out to whoever registered interest. Fits gate discipline: "done" is claimed only after gates are green.
- **Armed watch (fallback):** `cortana-bus on-idle <agent> --notify me` — one-shot; postmaster fires when that agent's next Stop event lands, then disarms. For watching agents that don't know the protocol (Codex, etc. — hooks are installed for 16 agent CLIs, so Stop events flow for all of them).

Result: secondmate dispatches 3 crewmates, arms watches, goes idle at zero token burn. Each crewmate's completion *wakes* the secondmate with a pointer to results. That's the native-teams task-notification loop, fleet-wide.

### 4. Pub/sub channels

`cortana-bus sub <topic>` / `cortana-bus pub <topic> "<msg>"`. Topics like `build:trenchos`, `alerts`, `captain`. Postmaster fans out to subscribers' mailboxes. Broadcast = a topic every agent subscribes to at register time.

### 5. Request/reply + barriers

- Every message has an id; `cortana-bus reply <id> "<text>"` correlates. `cortana-bus ask <agent> "<q>" --wait --timeout 300` blocks the sender's shell until reply (or times out) — synchronous when you need it.
- Barriers: "wake me when all 3 are done" — postmaster counts done-events per group, or thin wrapper on `cmux wait-for`.

### 6. Reliability — at-least-once with acks

Terminal injection can be lost (compaction, hibernation, a stray keystroke). So: agent acks on read (`cortana-bus read` acks implicitly); postmaster re-injects unacked envelopes after the target's next idle, N retries, then escalates to captain. Every message is JSONL-logged → full replayable fleet transcript.

### 7. Human layer — Stone sees everything, is bothered rarely

- Every done-ping optionally mirrors to `cmux notify` (Feed) — proactive-pinging doctrine satisfied by machinery, not memory.
- `cortana-bus tap` = live wiretap of all fleet traffic; feeds the mission-control dashboard and Hermes session observability (this is the JSON feed that build wanted).
- Per no-supervision-narration: routine ticks stay silent; only outcomes/failures escalate to Stone (Feed → Hermes → Telegram).

## Two tiers, one fabric: native teams *inside* panes, cortana-bus *between* them

Every cmux pane running Claude Code can use the **native agent teams feature** internally — named teammates, SendMessage, automatic task notifications — with zero cortana-bus involvement (`cmux claude-teams` wrapper already exists for exactly this launch). So the fleet is **fractal**:

- **Inside a pane:** a secondmate spins up its own named team in-process. Cheapest possible comms (no pty injection, no daemon hop), instant task notifications, shared session context. This is the right tool whenever the collaborators live and die with that session.
- **Between panes:** cortana-bus. The moment communication crosses a pane, a harness (Codex ↔ Claude), a lifetime (survive a restart), or a machine (VPS lanes), it goes on the bus.
- **Any depth can reach the bus:** an in-process teammate has Bash, so it can call `cortana-bus send` itself — a specialist three levels deep inside pane A can ping pane B directly without climbing back up through its captain. The bus is the fleet's shared backplane, reachable from anywhere.
- **Model lanes compose at every depth:** a Sonnet crewmate spawns its own Sonnet/Haiku subagents inline for recon and digestion, keeping cheap work on cheap lanes *inside* its pane; only distilled conclusions ever cross the bus. Lane discipline (Codex = mechanical, Sonnet = digestion, Opus/Fable = judgment) isn't a top-level rule — it recurses. Each pane is a cost-contained cell: token burn stays local, signal travels.

**Routing rule (one line for the skill leaf):** same-session collaborators → native teams; short-lived fan-out → subagents; anything that crosses a pane, harness, lifetime, or machine → cortana-bus.

**Mission Control sees inside the panes for free.** The Claude Code wrapper already bridges hook events (PreToolUse/Stop, per session id) onto the cmux event bus — including teammates' activity. So the fleet graph can render each pane as an expandable node: click a secondmate, see its in-process team working underneath. Depth-of-field observability with zero extra instrumentation.

## The VPS tier — sandboxed, parallel, disposable

The Mac is the bridge; sbx1 (and the VPS pool) is the engine room. Same bus, same Mission Control — heavy lifting moves off-glass.

**Sandboxing = speed.** On sbx1, crewmates run inside Docker containers (Docker verified working, claude installed) with full permissions safely caged — no approval prompts, no permission-churn retries, no blast radius. A permission prompt is a round trip *and* wasted tokens; a sandbox eliminates the whole class. Bake a **golden image** (deps + harness + hooks + cortana-bus satellite) once; every run starts as an instant clean room. cmux's own `vm snapshot`/`fork` commands are the managed-cloud version of the same move — sbx1 is the sovereign lane, cmux vm the burst lane.

**Parallel runs = free on flat lanes.** Ralph-loop / worktree parallelism relocates to containers: N runs on one ticket (best-of-N, judge picks) or N tickets at once. Run the parallelism on the **Codex flat plan — marginal cost $0**, so width is pure speed. Metered API models never fan out; they only judge.

**Headless by default.** VPS crewmates are `claude -p` / `codex exec` runs inside containers (clean-room doctrine — no OMC deps), not interactive panes. A thin wrapper emits `cortana-bus done <ticket> --status <gate-result>` on exit; results sync back as files/branches. No pty, no idle session. When Stone wants to watch one live, `cmux ssh-tmux sbx1` attaches a real pane — spectating is opt-in, not the default cost.

**Bus reach:** V1 = ssh relay (`cortana-bus send` on sbx1 pipes over ssh to the Mac socket); later a bus-satellite with store-and-forward if links flap. `cmux remotes` already models the routes; Mission Control gets a **Lanes screen**: sbx1 load, container matrix, per-run gate status, $/lane.

**Minimize presence — both meanings:**
- *Machine presence:* Mac hosts only judgment sessions + the postmaster + the glass. Mechanical burn, disk churn, and 20-agent fan-outs live on the VPS; Mac hibernation pressure disappears.
- *Model presence:* no agent exists while it isn't working. Containers spawn per ticket and die on done — zero idling sessions holding context and burning attention. The fleet's resting state is **one postmaster + a dashboard**, everything else materializes on demand.
- *Stone's presence:* event-driven wakes, batched digests (afk-mode), and the attention strip mean the system runs unattended and interrupts only on outcomes, failures, or approvals.

**The token thesis, stated once:** tokens are spent where judgment lives and nowhere else. Recon/digestion → cheap subagents inside panes; mechanical width → flat-rate sandboxes; transport → files and pointer envelopes, never re-narration; wakes → events, never polling; Opus/Fable → wakes only when gates are green or a decision is queued.

## The Nightly Optimizer — the fleet gets cheaper and faster while Stone sleeps

Everything above leaves perfect exhaust: bus JSONL, cmux event log, Claude/Codex transcripts (with per-turn token counts), the ticket ledger, postmaster telemetry. A nightly cron (extend the existing 3:17am context auditor's slot — one canonical nightly window, not a second daemon) turns that exhaust into a scorecard and then into **config patches**. Measure → diagnose → patch → verify → report.

**The four gauges (computed from transcripts + logs, no new instrumentation):**

| Gauge | What it actually measures |
|---|---|
| **Signal/noise** | % of bus envelopes that led to action vs never-read/duplicate pings; % of context tokens spent on decisions/diffs vs re-narration and status chatter; captain wakes that produced a decision vs no-op wakes |
| **Speed** | ticket cycle time (lease→green), dispatch→first-token latency, delivery lag (agent finished → waiter woke), permission-prompt stalls, retry counts |
| **Presence** | idle-session-minutes (alive but not working), Mac-vs-VPS load split, Stone interrupts/day, notifications sent vs acted on |
| **Tokens** | **tokens per green ticket** (the north-star unit economic), spend by lane vs lane doctrine (Opus caught doing mechanical work = violation flag), repeated file re-reads (= missing canonical doc), compaction events, Codex flat-plan saturation % (paid for — use it) |

**What it's allowed to fix autonomously** (cheap lane does the digestion — headless Sonnet `claude -p` sweeps over transcripts on sbx1; Opus/Fable judges only the final patch set):

- CLAUDE.md / skill-leaf wording that provably causes repeated confusion (mined from stuck-crewmate and re-ask patterns)
- Permission allowlists — the same approval granted 5× yesterday becomes an allowlist entry tonight
- Lane routing rules — task shapes that kept escalating to expensive models get re-routed down
- Postmaster tuning — retry windows, digest batching, delivery timing that showed lag
- Golden image — a dep installed at runtime 3× gets baked into the sandbox image

**Guardrails (this is gate discipline turned on ourselves):** every change is a git commit in the config repo with evidence linked; applied as a **canary** — if the next night's gauges regress, it auto-reverts. Hard fences it never crosses: credentials, anything outward-facing, money paths, and eval-before-install (it may *propose* new tooling, never install it). Risky ideas queue as proposals in the attention strip instead of self-applying.

**The morning digest** (Feed + Telegram, dopamine format): yesterday's tokens-per-green-ticket vs trend, the top noise source it killed, changes applied (revert armed), proposals awaiting your call. Mission Control gets a **Nightly screen** with the four gauges as trend lines — config treated as code, with the metrics as its test suite. Every night the whole system gets a little cheaper, a little faster, a little quieter.

## Extra ideas beyond the ask (the "think harder" list)

1. **Watchdog for free.** Postmaster already sees lifecycle. Agent in `needsInput` > 10 min, or zero events > N min while "running" → auto-ping captain with workspace ref. Stuck agents stop dying silently.
2. **Injection = prompt injection surface.** Only postmaster-formatted `[bus]` envelopes; a `fleet-comms` skill leaf in ~/stone-skills teaches every crewmate the verbs and that `[bus]` lines are fleet traffic, *not* Stone speaking. Sender identity comes from the registry, not from the message text.
3. **Hybrid with native teams.** Inside one Claude Code session, native subagents/teams (`cmux claude-teams` wrapper exists) stay cheapest. The bus is for *cross-session* comms — captain↔secondmate↔crewmate across workspaces, mixed harnesses, mixed machines.
4. **Remote reach.** `CMUX_SOCKET_PATH` + ssh port-forward = same bus verbs from VPS sandboxes (sbx1, factory lanes). One protocol, Mac + cloud.
5. **Ticket Fabric fusion.** `cortana-bus done <ticket>` closes the loop with fm-tickets leases: message carries the ticket id, postmaster updates the ledger, waiter gets ticket-out. Transport and contract snap together instead of being two builds.
6. **Status blackboard.** Agents `cortana-bus status "<one-liner>"` → mirrors to `cmux set-status` (visible in sidebar per workspace) + a fleet STATE file Cortana reads on "status?" — reconciliation sweeps become a file read.
7. **Priority lanes.** `--priority urgent` jumps the mailbox queue and may interrupt; default lane never interrupts a turn. Maps to ADW hotfix lane.
8. **Turn-budget guard.** Postmaster counts Stop events per agent per hour; runaway loops (agent ping-ponging with itself) trip a breaker and page the captain. Cheap insurance against infinite agent-to-agent chatter.

## Mission Control — the frontend

The bus makes every message, lifecycle change, and done-event a structured JSONL record with a seq cursor. That means the frontend is *cheap*: it's a rendering of data the postmaster already has. No second collector, no scraping terminals.

**Where it lives:** postmaster grows a localhost-only HTTP listener — static single-page UI + an SSE stream + a small JSON API. Opened as a **cmux browser surface** (`cortana-bus mc` → `cmux browser open http://localhost:<port>`), pinned as its own Mission Control workspace. The panel lives inside the same cockpit as the fleet — no Electron app, no separate window. And because the cmux browser is scriptable, agents can screenshot/read the panel too.

**The screens:**

1. **Fleet graph (the money view).** Live node graph — captain → secondmates → crewmates → specialists. Node color = lifecycle (green running / grey idle / amber needsInput / red stuck). **Edges pulse when messages flow.** This is the GRAPH made literal — you watch tickets and pings move through the fleet in real time. Click a node → cmux focuses that terminal (`select-workspace` over the socket). Panel-to-terminal deep links everywhere.
2. **Wiretap.** Scrolling live feed of all bus traffic, filter by agent/topic/message type; click to expand payloads. `cortana-bus tap`, but visual.
3. **Ticket board.** Kanban over the Ticket Fabric ledger: queued → leased → gates-running → green/red. Each card links to its workspace and its gate evidence.
4. **Attention strip.** The watchdog's output as a queue: "2 agents need input, 1 stuck 14 min, 1 gate red." The panel's job is to make *silence trustworthy* — nothing in the strip means nothing needs you.
5. **Blackboard + telemetry.** Per-agent one-liner status and progress bars (mirrors `set-status`/`set-progress`), turns/hour per agent, budget-breaker state, lane usage (Codex flat vs API).
6. **Replay.** Everything is seq-ordered JSONL — scrub back through the day and watch a build happen: who pinged whom, where it stalled. Post-mortems become a slider drag.

**Not read-only — a command deck.** Compose a message to any terminal from the panel, interrupt/steer a stuck agent, approve a hotfix pre-build or a gate exception, arm a done-watch — every action calls the same code paths as the CLI verbs, so the panel can never do anything the bus can't.

**Convergences (this panel was already on the roadmap three times):**
- It **is** the mc dashboard from the Hermes session-observability build — the postmaster API is the "Hermes JSON feed" that plan wanted; Hermes just consumes the same SSE stream.
- Served over Tailscale it becomes **pocket mission control** on the phone, pairing with Hermes/Telegram pings.
- Long-term it's the natural shell for **Voice Cockpit v2** — waveform + teleprompter mounts as another panel screen; you talk to the fleet from the same glass.

## ADW doctrine — code is free, agents are not

Everything above eventually ships as an ADW, and the dividing rule is: **deterministic code for control flow, agents only where judgment lives.**

- A node in the graph defaults to **code**; an agent node must justify itself (writing the diff, interpreting a spec, judging quality). Gates are *always* code — exit codes decide accept, never an LLM.
- The fix loop is code, not conversation: `while gates red → pipe the failing gate output into the builder → builder edits → rerun gates`. The script loops; the agent only writes fixes. Token spend scales with *fixes needed*, not with *iterations run*.
- Routing, retries, timeouts, done-detection, escalation thresholds: code. cortana-bus makes this natural — an ADW script can `on-idle` an agent, read its ticket-out, run the gate, and decide the next edge without a single judgment token.
- The dev cycle being run manually on this very build (spec → fresh-context builder → gate watch → independent verify → loop findings back) is the prototype: once the shape stabilizes, it gets codified as an `adws/` script and the orchestrator stops spending tokens on supervision entirely.

## What NOT to build

- No sockets/servers/gRPC — files + cmux socket only, clean-room per token discipline (no OMC deps).
- No message broker daemon zoo — **one** postmaster process (launchd), everything else is the `cortana-bus` CLI touching flat files.
- No polling loops anywhere — the event bus with `--cursor-file` is push-based and durable; that's the whole point.

## Build order (each slice independently shippable, gate-verified)

1. **V1 — directory (`who`) + any-to-any send/read (all three delivery modes) + armed done-watch.** The 80% win: every terminal can message every terminal, and agents wake on completion. ~1 crewmate day.
2. **V2 — acks/retries, pub/sub, explicit `done`, Feed mirroring + Mission Control read-only** (SSE listener, fleet graph, wiretap, attention strip in a cmux browser pane).
3. **V3 — barriers, watchdog, ticket fusion, budget breaker + VPS lane** (golden image on sbx1, headless container crewmates with ssh bus relay, best-of-N on the Codex flat plan) **+ Mission Control command deck** (compose/steer/approve, ticket board, Lanes screen, replay, Tailscale/phone).
4. **V4 — Nightly Optimizer** (extend the 3:17am slot): four-gauge scorecard from transcripts + logs, canary config patches with next-day auto-revert, morning digest, MC Nightly screen.

Open question to test in V1: does `cmux send` to a hibernated workspace auto-resume the agent, or does postmaster need to trigger resume first? (Determines whether mailbox-park-and-wait needs a resume kick.)

**Decisions (locked 2026-08-06):** name = **cortana-bus**; home = **~/firstmate** (`bin/cortana-bus` + postmaster alongside the existing fleet scripts — easiest, no new repo to wire). V1 greenlit.

---

*Receipts: all cmux primitives verified live on this Mac 2026-08-06 — `cmux --help`, `cmux capabilities` (incl. `agent.resolve_delivery_target`), live `cmux events` tail showing `agent.hook.PreToolUse`/`feed.item.received` with seq cursors, and agent-hooks docs (16 agent CLIs bridged, lifecycle store at `~/.cmuxterm/*-hook-sessions.json`, hibernation semantics).*
